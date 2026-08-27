/**
 * MediaContent —— M5-2.1 媒体真实渲染。
 *
 * 渲染规则（契约：backend/apps/media/serializers.py MediaObjectSerializer）：
 * - image/emoji：直接渲染原图 content（缩略图是 320px JPEG 静帧，会压画质且
 *   让 GIF 动图变静图；ResourceImage 按 media_id 全局缓存，不产生重复请求）；
 * - video：海报帧封面（thumbnail 签名缩略图直连秒出；无海报降级 <video>
 *   首帧预览）+ 播放键覆盖层，点击进查看器预览/保存；
 * - voice：波形 + 进度条（可拖）+ 时长 + 播放（content）；全局同时只播一条；
 * - file：文件名 + 大小 + 下载（content）；
 * - descriptor 未就绪（WS 帧只带 media_id）→ 骨架占位并异步补拉；
 * - 加载失败 / 未知类型 → 占位 + 重试；
 * - 全部 URL 经 api/media.ts 构造，禁止裸拼接。
 */
import { useCallback, useEffect, useRef, useState } from "react";
import type { CSSProperties } from "react";
import {
  fetchMediaDescriptor,
  formatBytes,
  formatDuration,
  getSignedMediaUrl,
  mediaContentUrl,
  resolveMediaPath,
  warmUpVideoElement,
} from "../../api/media";
import { apiRequestBlob, API_PREFIX } from "../../api/client";
import type { ChatMessage, MediaDescriptor, MediaSegment } from "../../api/types";
import { useMessageStore } from "../../stores/message";
import { useAuthStore } from "../../stores/auth";
import { goUserProfile } from "../../utils/navigation";
import { mentionLabel } from "../../utils/segment";
import {
  claimAudioPlayback,
  releaseAudioPlayback,
} from "../../utils/mediaPlayback";
import { ResourceImage } from "../ResourceImage";
import { ImageViewer } from "./ImageViewer";
import { IconDownload, IconFile, IconImage, IconMic, IconPause, IconPlay, IconRetry } from "../icons";

/** 媒体消息内的文字说明（content 在媒体消息中是说明文字/文件名） */
function caption(msg: ChatMessage): string {
  return msg.content?.trim() ?? "";
}

/* ---------- 占位 ---------- */

function MediaPlaceholder({
  state,
  label,
  onRetry,
}: {
  state: "loading" | "error" | "unknown";
  label: string;
  onRetry?: () => void;
}) {
  if (state === "loading") {
    return (
      <div className="media-placeholder" role="status" aria-label={`${label}加载中`}>
        <span className="skeleton" style={{ width: 36, height: 36, borderRadius: 10 }} />
        <span>{label}加载中…</span>
      </div>
    );
  }
  return (
    <div className="media-placeholder failed">
      <span>{state === "unknown" ? `暂不支持的${label}类型` : `${label}加载失败`}</span>
      {onRetry && state !== "unknown" && (
        <button type="button" className="media-retry" onClick={onRetry}>
          <IconRetry width={12} height={12} style={{ verticalAlign: "-2px", marginRight: 4 }} />
          重试
        </button>
      )}
    </div>
  );
}

/* ---------- 图片 / 表情 / 视频 ---------- */

/** 发送即占最终大框：按媒体宽高比计算最终显示尺寸（max 320 约束、不放大），
 * 容器一开始就占满最终尺寸，媒体加载后填充不改变高度——避免「小框被撑大向下挤」。
 * 注意：不能用 `width: min(dw,100%)`——在无内容 shrink-to-fit 容器里 100% 解析为 0，
 * aspect-ratio 失效（实测 w=0 h=0）；要用明确像素 width + max-width:100%（窄屏收缩）。 */
function mediaFrameStyle(media: MediaDescriptor, fixed?: { width: number; height: number }): CSSProperties {
  if (fixed) return { width: fixed.width, height: fixed.height } as CSSProperties;
  const w = media.width ?? 0;
  const h = media.height ?? 0;
  if (w > 0 && h > 0) {
    const scale = Math.min(320 / w, 320 / h, 1); // 1 = 不放大（小图保持原尺寸）
    const dw = Math.round(w * scale);
    const dh = Math.round(h * scale);
    return { width: `${dw}px`, maxWidth: "100%", aspectRatio: `${dw} / ${dh}` } as CSSProperties;
  }
  return { width: "320px", maxWidth: "100%", aspectRatio: "4 / 3" } as CSSProperties;
}

function ImageMedia({
  msg,
  media,
  isEmoji,
}: {
  msg: ChatMessage;
  media: MediaDescriptor;
  isEmoji: boolean;
}) {
  const label = isEmoji ? "表情" : "图片";
  // 气泡内用缩略图（320px JPEG，几 KB~百 KB 级）——QQ 同款策略，多图/大图不再卡顿；
  // 点击进查看器才加载原图。GIF 例外：缩略图是静帧会丢动图，气泡仍走原图。
  const isGif = media.mime_type === "image/gif";
  const src =
    !isEmoji && !isGif && media.thumbnail
      ? media.thumbnail
      : mediaContentUrl(media.media_id);
  const [viewerOpen, setViewerOpen] = useState(false);

  return (
    <>
      <div className="media-frame media-frame-image" style={mediaFrameStyle(media, isEmoji ? { width: 96, height: 96 } : undefined)}>
        <button
          type="button"
          className="media-frame-open"
          onClick={() => setViewerOpen(true)}
          aria-label={`查看${label}原图`}
          title="点击查看原图"
        >
          <ResourceImage
            src={src}
            alt={caption(msg) || label}
            className={isEmoji ? "media-emoji" : "media-image"}
            loading="lazy"
            fallback={<span className="media-frame-skeleton" />}
            variant={src.includes("/thumbnail") ? "thumb" : undefined}
          />
        </button>
      </div>
      {viewerOpen && (
        <ImageViewer
          media={media}
          alt={caption(msg) || label}
          onClose={() => setViewerOpen(false)}
        />
      )}
    </>
  );
}

/* ---------- 视频 ---------- */

/**
 * 视频帧块（群聊/私信气泡）：本地预览（乐观消息）或服务端媒体封面。
 *
 * 秒开策略（与帖子侧 PostVideoCover 同一事实）：
 * - 服务端视频有海报帧（thumbnail，上传时前端抽首帧回传）→ 渲染签名缩略图
 *   <img> 封面，零视频元数据拉流，封面秒出；点击进查看器播放；
 * - 无海报帧（存量/抽帧失败）→ 降级 <video preload=metadata> 首帧预览；
 * - hover/tap 预热 original 签名 URL（模块缓存），点击打开查看器时零往返。
 */
function VideoFrame({
  media,
  localUrl,
  onOpen,
  style,
  ariaLabel = "查看视频",
}: {
  media?: MediaDescriptor | null;
  /** 乐观消息本地预览（未上传，直接使用） */
  localUrl?: string;
  onOpen: () => void;
  style?: CSSProperties;
  ariaLabel?: string;
}) {
  const [videoSrc, setVideoSrc] = useState<string | null>(localUrl ?? null);
  const [failed, setFailed] = useState(false);
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const hasPoster = Boolean(media?.thumbnail);

  // hover/tap 预热：签 URL 并创建 detached <video> 开始缓冲——点击打开查看器
  // 时直接接管已缓冲元素，起播缓冲与点击决策时间窗重叠（点开即播）
  const warmUpOriginal = () => {
    if (media && !localUrl) warmUpVideoElement(media.media_id);
  };

  // 本地预览直接可用；服务端无海报帧的降级路径才签 original 拉首帧
  useEffect(() => {
    if (localUrl) {
      setFailed(false);
      setVideoSrc(localUrl);
      return;
    }
    setVideoSrc(null);
    if (!media) {
      setFailed(true);
      return;
    }
    if (hasPoster) return;
    let cancelled = false;
    setFailed(false);
    getSignedMediaUrl(media.media_id)
      .then((url) => {
        if (!cancelled) setVideoSrc(url);
      })
      .catch(() => {
        if (!cancelled) setFailed(true);
      });
    return () => {
      cancelled = true;
    };
  }, [media, localUrl]);

  // 部分浏览器 preload=metadata 不渲染首帧：微 seek 触发首帧解码
  const onLoadedData = () => {
    const v = videoRef.current;
    if (v && v.currentTime < 0.01) {
      try {
        v.currentTime = 0.001;
      } catch {
        // 未就绪时 seek 抛错可忽略（首帧由浏览器自行渲染）
      }
    }
  };

  const playBadge = (
    <span className="video-play-badge" aria-hidden="true">
      <IconPlay width={22} height={22} />
    </span>
  );

  return (
    <div className="media-frame media-frame-video" style={style} onPointerEnter={warmUpOriginal}>
      {localUrl ? (
        <button
          type="button"
          className="media-frame-open"
          onClick={onOpen}
          aria-label={ariaLabel}
          title="点击放大预览"
        >
          <video
            src={localUrl}
            className="media-video"
            preload="metadata"
            muted
            playsInline
            tabIndex={-1}
          />
          {playBadge}
        </button>
      ) : media && hasPoster ? (
        <button
          type="button"
          className="media-frame-open"
          onClick={onOpen}
          aria-label={ariaLabel}
          title="点击放大预览"
        >
          {/* 海报帧封面直连秒出（object-fit cover 由 .media-video 提供） */}
          <ResourceImage
            src={media.thumbnail!}
            variant="thumb"
            alt=""
            className="media-video"
            loading="lazy"
            fallback={<span className="media-frame-skeleton" />}
          />
          {playBadge}
        </button>
      ) : videoSrc ? (
        <button
          type="button"
          className="media-frame-open"
          onClick={onOpen}
          aria-label={ariaLabel}
          title="点击放大预览"
        >
          {/* 气泡内仅展示首帧+播放键（禁交互）；完整预览在查看器中 */}
          <video
            ref={videoRef}
            src={videoSrc}
            className="media-video"
            preload="metadata"
            muted
            playsInline
            tabIndex={-1}
            onLoadedData={onLoadedData}
          />
          {playBadge}
        </button>
      ) : failed ? (
        <span className="video-load-failed">视频加载失败</span>
      ) : (
        <span className="media-frame-skeleton" />
      )}
    </div>
  );
}

function VideoMedia({ msg, media }: { msg: ChatMessage; media: MediaDescriptor }) {
  const [viewerOpen, setViewerOpen] = useState(false);
  return (
    <>
      <VideoFrame media={media} onOpen={() => setViewerOpen(true)} style={mediaFrameStyle(media)} />
      {viewerOpen && (
        <ImageViewer
          media={media}
          alt={caption(msg) || "视频"}
          onClose={() => setViewerOpen(false)}
        />
      )}
    </>
  );
}

/* ---------- 图文混排（type=mixed + segments） ---------- */

/**
 * 混排消息渲染：text 段流式文本 + image/video 段媒体块（多图自动换行成网格）。
 * 乐观消息（pending）的媒体段 media 缺失 → 用 localMedia 本地预览渲染；
 * 点击任一媒体段打开共享查看器（同消息内 image/video 可左右切换）。
 */
function MixedMedia({ msg }: { msg: ChatMessage }) {
  const currentUserId = useAuthStore((s) => s.currentUser?.id ?? null);
  const segments = msg.segments ?? [];
  const localMedia = msg.localMedia ?? [];
  // 媒体段（image/video）用于查看器多图切换；mention 段单独渲染，不参与媒体序列
  const mediaSegs = segments.filter(
    (s): s is Extract<MediaSegment, { type: "image" | "video" }> =>
      s.type === "image" || s.type === "video",
  );
  const [openIdx, setOpenIdx] = useState<number | null>(null);

  // 第 i 个媒体段对应的本地预览（乐观消息；与 segments 媒体段按序对应）
  let mediaCursor = 0;

  const localFor = () => {
    const l = mediaCursor < localMedia.length ? localMedia[mediaCursor] : undefined;
    mediaCursor += 1;
    return l;
  };

  if (segments.length === 0) {
    return <MediaPlaceholder state="unknown" label="图文消息" />;
  }

  // 乐观消息本地预览 URL 由组件生命周期管理：仅组件卸载时 revoke（空 deps），
  // 避免 sendOptimistic 在替换渲染前 revoke 造成「上传中空白图」竞态。
  const localUrls = useRef<string[]>([]);
  localUrls.current = (msg.localMedia ?? []).map((m) => m.url);
  useEffect(() => {
    return () => {
      for (const u of localUrls.current) URL.revokeObjectURL(u);
    };
  }, []);

  return (
    <>
      <div className="mixed-flow">
        {segments.map((seg, i) => {
          if (seg.type === "text") {
            return (
              <span key={i} className="mixed-text">
                {seg.text}
              </span>
            );
          }
          if (seg.type === "mention") {
            // @Token（M8）：高亮胶囊；「@我」加 glow 描边；点击进个人主页
            const isMe = currentUserId != null && seg.user_id === currentUserId;
            const label = mentionLabel(seg);
            return (
              <button
                key={i}
                type="button"
                className={`mention-token${isMe ? " is-me" : ""}`}
                onClick={() => goUserProfile(currentUserId, seg.user_id)}
                aria-label={`@${label}`}
                title={`@${label}`}
              >
                @{label}
              </button>
            );
          }
          if (seg.type === "image") {
            const local = localFor();
            const segIdx = mediaSegs.indexOf(seg);
            // 气泡内用缩略图（GIF 例外保动图），点击进查看器看原图；
            // 乐观阶段 seg.media 为 null → 走本地预览分支，此处不可解引用
            const isSegGif = seg.media?.mime_type === "image/gif";
            const hasThumb = !!seg.media && !isSegGif && !!seg.media.thumbnail;
            return (
              <button
                key={i}
                type="button"
                className="media-frame-open mixed-img"
                onClick={() => setOpenIdx(segIdx)}
                aria-label="查看图片"
                title="点击查看原图"
              >
                {seg.media ? (
                  <ResourceImage
                    src={hasThumb && seg.media.thumbnail ? seg.media.thumbnail : mediaContentUrl(seg.media.media_id)}
                    alt="图片"
                    className="mixed-img-media"
                    loading="lazy"
                    fallback={<span className="media-frame-skeleton" />}
                    variant={hasThumb ? "thumb" : undefined}
                  />
                ) : local ? (
                  <img src={local.url} alt="图片" className="mixed-img-media" />
                ) : (
                  <span className="media-frame-skeleton" />
                )}
              </button>
            );
          }
          // video 段
          const local = localFor();
          const segIdx = mediaSegs.indexOf(seg);
          return (
            <VideoFrame
              key={i}
              media={seg.media}
              localUrl={local?.url}
              onOpen={() => setOpenIdx(segIdx)}
              ariaLabel="查看视频"
              style={{ width: 240, maxWidth: "100%", aspectRatio: "4 / 3" }}
            />
          );
        })}
      </div>
      {openIdx != null && (
        <ImageViewer
          items={mediaSegs.map((s, idx) => ({
            media: s.media ?? null,
            localUrl: idx < localMedia.length ? localMedia[idx].url : undefined,
            isVideo: s.type === "video",
            alt: s.type === "video" ? "视频" : "图片",
          }))}
          initialIndex={openIdx}
          onClose={() => setOpenIdx(null)}
        />
      )}
    </>
  );
}

/* ---------- 语音 ---------- */

function VoiceMedia({ media }: { media: MediaDescriptor }) {
  const wave = resolveMediaPath(media.waveform);
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const objectUrlRef = useRef<string | null>(null);
  const [playing, setPlaying] = useState(false);
  const [loadingAudio, setLoadingAudio] = useState(false);
  const [audioError, setAudioError] = useState(false);
  /** 总时长：descriptor 为准；波形派生失败（null）时由音频 metadata 兜底 */
  const [duration, setDuration] = useState<number | null>(media.duration ?? null);
  const [current, setCurrent] = useState(0);

  /**
   * 全局停止回调（稳定引用，供互斥注册表 claim/release）：
   * 暂停 + 进度归零 + UI 复位。被其他语音抢占或自身结束时都会走到这里。
   */
  const stopPlayback = useCallback(() => {
    const audio = audioRef.current;
    if (audio) {
      audio.pause();
      try {
        audio.currentTime = 0;
      } catch {
        // 未加载完成时 seek 可能抛错，忽略即可
      }
    }
    setPlaying(false);
    setCurrent(0);
    releaseAudioPlayback(stopPlayback);
  }, []);

  const ensureAudio = async (): Promise<HTMLAudioElement | null> => {
    if (audioRef.current) return audioRef.current;
    setLoadingAudio(true);
    setAudioError(false);
    try {
      // 内部媒体须带 Bearer 鉴权读取（原生 Audio 不会携带 token → 403）
      const blob = await apiRequestBlob(mediaContentUrl(media.media_id).slice(API_PREFIX.length));
      const url = URL.createObjectURL(blob);
      objectUrlRef.current = url;
      const audio = new Audio(url);
      audio.addEventListener("loadedmetadata", () => {
        if (Number.isFinite(audio.duration) && audio.duration > 0) {
          setDuration(audio.duration);
        }
      });
      audio.addEventListener("timeupdate", () => setCurrent(audio.currentTime));
      audio.addEventListener("ended", stopPlayback);
      audio.addEventListener("error", () => {
        setPlaying(false);
        setAudioError(true);
      });
      audioRef.current = audio;
      return audio;
    } catch {
      setAudioError(true);
      return null;
    } finally {
      setLoadingAudio(false);
    }
  };

  const toggle = async () => {
    if (playing && audioRef.current) {
      audioRef.current.pause();
      setPlaying(false);
      releaseAudioPlayback(stopPlayback);
      return;
    }
    const audio = audioRef.current ?? (await ensureAudio());
    if (!audio) return;
    // 先抢占全局播放位：其他正在播放的语音会被 stopPlayback 停止并复位
    claimAudioPlayback(stopPlayback);
    void audio.play().then(() => setPlaying(true)).catch(() => {
      setPlaying(false);
      releaseAudioPlayback(stopPlayback);
    });
  };

  /** 拖动进度条 seek */
  const onSeek = (value: number) => {
    const audio = audioRef.current;
    if (!audio || !Number.isFinite(value)) return;
    try {
      audio.currentTime = value;
    } catch {
      return;
    }
    setCurrent(value);
  };

  // 卸载释放 object URL 并注销播放位
  useEffect(() => {
    return () => {
      stopPlayback();
      if (objectUrlRef.current) URL.revokeObjectURL(objectUrlRef.current);
    };
  }, [stopPlayback]);

  const total = duration != null && duration > 0 ? duration : null;
  const seekable = audioRef.current != null && total != null;

  return (
    <div className="voice-card">
      <div className="voice-card-main">
        <button
          type="button"
          className="voice-play"
          onClick={() => void toggle()}
          disabled={loadingAudio}
          aria-label={playing ? "暂停语音" : loadingAudio ? "语音加载中" : "播放语音"}
        >
          {loadingAudio ? (
            <span className="skeleton" style={{ width: 14, height: 14, borderRadius: 4 }} />
          ) : playing ? (
            <IconPause width={16} height={16} />
          ) : (
            <IconPlay width={16} height={16} />
          )}
        </button>
        {wave ? (
          <ResourceImage
            src={wave}
            alt="语音波形"
            className="voice-wave"
            loading="lazy"
            fallback={
              <span className="voice-wave" style={{ display: "grid", placeItems: "center" }}>
                <IconMic width={18} height={18} />
              </span>
            }
          />
        ) : (
          <span className="voice-wave" style={{ display: "grid", placeItems: "center" }}>
            <IconMic width={18} height={18} />
          </span>
        )}
        <span className="voice-duration">{formatDuration(total ?? 0)}</span>
        {audioError && (
          <button
            type="button"
            className="media-retry"
            onClick={() => {
              setAudioError(false);
              audioRef.current = null;
              void toggle();
            }}
          >
            重试
          </button>
        )}
      </div>
      <div className="voice-seek-row">
        <input
          type="range"
          className="voice-seek"
          min={0}
          max={total ?? 0}
          step={0.1}
          value={Math.min(current, total ?? current)}
          disabled={!seekable}
          onChange={(e) => onSeek(Number(e.target.value))}
          aria-label="语音播放进度"
        />
        <span className="voice-cur">{formatDuration(current)}</span>
      </div>
    </div>
  );
}

/* ---------- 文件 ---------- */

function FileMedia({ msg, media }: { msg: ChatMessage; media: MediaDescriptor }) {
  // 契约：file 消息的文件名在 content 字段（后端 CreateMessageSerializer 约定）
  const name = caption(msg) || "附件";
  // 原生 <a> 下载不带 Authorization：挂载即签短时 URL（同源 download 属性生效）
  const [href, setHref] = useState<string | null>(null);
  useEffect(() => {
    let cancelled = false;
    getSignedMediaUrl(media.media_id)
      .then((url) => {
        if (!cancelled) setHref(url);
      })
      .catch(() => {
        // 签名失败保持 null：点击时提示
      });
    return () => {
      cancelled = true;
    };
  }, [media.media_id]);

  return (
    <div className="file-card">
      <span className="file-icon">
        <IconFile width={20} height={20} />
      </span>
      <span className="file-info">
        <span className="file-name" title={name}>
          {name}
        </span>
        <span className="file-size">{formatBytes(media.size)}</span>
      </span>
      <a
        className="file-download"
        href={href ?? undefined}
        download={name}
        aria-label={`下载 ${name}`}
        onClick={(e) => {
          if (!href) {
            e.preventDefault();
            window.setTimeout(() => window.alert("附件准备中，请稍后再试"), 0);
          }
        }}
      >
        <IconDownload width={16} height={16} />
      </a>
    </div>
  );
}

/* ---------- 入口：descriptor 归一 + 类型分派 ---------- */

export function MediaContent({ msg }: { msg: ChatMessage }) {
  const kind = msg.type;
  const [media, setMedia] = useState<MediaDescriptor | null>(msg.media ?? null);
  const [failed, setFailed] = useState(false);
  const [retryKey, setRetryKey] = useState(0);
  const mergeMedia = useMessageStore((s) => s.mergeMedia);

  // 跟随 store 中消息的 media 更新（mergeMedia 合并后重新渲染）
  useEffect(() => {
    if (msg.media) {
      setMedia(msg.media);
      setFailed(false);
    }
  }, [msg.media]);

  // 换消息（复用组件实例）时重置拉取状态
  useEffect(() => {
    setMedia(msg.media ?? null);
    setFailed(false);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [msg.id]);

  // WS 帧路径：只有 media_id 字符串 → 异步补拉 descriptor
  useEffect(() => {
    if (media || failed) return;
    const mediaId = msg.media_id;
    if (!mediaId || typeof mediaId !== "string") {
      // 媒体消息既无 descriptor 也无 media_id：无法渲染
      setFailed(true);
      return;
    }
    let cancelled = false;
    fetchMediaDescriptor(mediaId)
      .then((desc) => {
        if (cancelled) return;
        setMedia(desc);
        // 合并进 store，避免滚动重渲染重复拉取
        mergeMedia(msg.conversation_id, msg.id, desc);
      })
      .catch(() => {
        if (!cancelled) setFailed(true);
      });
    return () => {
      cancelled = true;
    };
  }, [media, failed, retryKey, msg.media_id, msg.conversation_id, msg.id, mergeMedia]);

  const typeLabel =
    kind === "image" ? "图片" : kind === "emoji" ? "表情" : kind === "voice" ? "语音" : kind === "video" ? "视频" : kind === "mixed" ? "图文消息" : "文件";

  // 图文混排：按 segments 渲染（text/image/video 段），无需单媒体 descriptor
  if (kind === "mixed") {
    return <MixedMedia msg={msg} />;
  }

  if (kind !== "image" && kind !== "emoji" && kind !== "voice" && kind !== "file" && kind !== "video") {
    return <MediaPlaceholder state="unknown" label="媒体" />;
  }

  if (failed) {
    return (
      <MediaPlaceholder
        state="error"
        label={typeLabel}
        onRetry={() => {
          setFailed(false);
          setRetryKey((k) => k + 1);
        }}
      />
    );
  }

  if (!media) {
    return <MediaPlaceholder state="loading" label={typeLabel} />;
  }

  switch (kind) {
    case "image":
      return <ImageMedia msg={msg} media={media} isEmoji={false} />;
    case "emoji":
      return <ImageMedia msg={msg} media={media} isEmoji={true} />;
    case "video":
      return <VideoMedia msg={msg} media={media} />;
    case "voice":
      return <VoiceMedia media={media} />;
    case "file":
      return <FileMedia msg={msg} media={media} />;
  }
}

/** 消息列表里的媒体类型图标（占位/未知场景用） */
export function mediaTypeIcon(type: string) {
  switch (type) {
    case "image":
    case "emoji":
      return <IconImage width={16} height={16} />;
    case "voice":
      return <IconMic width={16} height={16} />;
    default:
      return <IconFile width={16} height={16} />;
  }
}
