/**
 * MediaContent —— M5-2.1 媒体真实渲染。
 *
 * 渲染规则（契约：backend/apps/media/serializers.py MediaObjectSerializer）：
 * - image/emoji：缩略图 descriptor.thumbnail（/api/v1/media/{id}/thumbnail）；
 *   无缩略图回退原图 content 端点；emoji 无缩略图时同样回退 content；
 * - voice：波形 descriptor.waveform（/api/v1/media/{id}/waveform）+ 时长 + 播放（content）；
 * - file：文件名 + 大小 + 下载（content）；
 * - descriptor 未就绪（WS 帧只带 media_id）→ 骨架占位并异步补拉；
 * - 加载失败 / 未知类型 → 占位 + 重试；
 * - 全部 URL 经 api/media.ts 构造，禁止裸拼接。
 */
import { useEffect, useRef, useState } from "react";
import type { CSSProperties } from "react";
import {
  fetchMediaDescriptor,
  formatBytes,
  formatDuration,
  mediaContentUrl,
  resolveMediaPath,
} from "../../api/media";
import { apiRequestBlob, API_PREFIX } from "../../api/client";
import type { ChatMessage, MediaDescriptor } from "../../api/types";
import { useMessageStore } from "../../stores/message";
import { ResourceImage } from "../ResourceImage";
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

/* ---------- 图片 / 表情 ---------- */

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
  // 优先缩略图；emoji 无缩略图时回退原图 content
  const thumb = resolveMediaPath(media.thumbnail);
  const src = thumb ?? mediaContentUrl(media.media_id);

  // 发送即占最终大框：按原图宽高比计算最终显示尺寸（max 320 约束、不放大），
  // 容器一开始就占满最终尺寸，图片加载后填充不改变高度——避免「小框被撑大向下挤」。
  // 注意：不能用 `width: min(dw,100%)`——在无内容 shrink-to-fit 容器里 100% 解析为 0，
  // aspect-ratio 失效（实测 w=0 h=0）；要用明确像素 width + max-width:100%（窄屏收缩）。
  const frameStyle = (() => {
    if (isEmoji) return { width: 96, height: 96 } as CSSProperties;
    const w = media.width ?? 0;
    const h = media.height ?? 0;
    if (w > 0 && h > 0) {
      const scale = Math.min(320 / w, 320 / h, 1); // 1 = 不放大（小图保持原尺寸）
      const dw = Math.round(w * scale);
      const dh = Math.round(h * scale);
      return { width: `${dw}px`, maxWidth: "100%", aspectRatio: `${dw} / ${dh}` } as CSSProperties;
    }
    return { width: "320px", maxWidth: "100%", aspectRatio: "4 / 3" } as CSSProperties;
  })();

  return (
    <div className="media-frame media-frame-image" style={frameStyle}>
      <ResourceImage
        src={src}
        alt={caption(msg) || label}
        className={isEmoji ? "media-emoji" : "media-image"}
        loading="lazy"
        fallback={<span className="media-frame-skeleton" />}
      />
    </div>
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
  const duration = formatDuration(media.duration);

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
      audio.addEventListener("ended", () => setPlaying(false));
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
      return;
    }
    const audio = audioRef.current ?? (await ensureAudio());
    if (!audio) return;
    void audio.play().then(() => setPlaying(true)).catch(() => setPlaying(false));
  };

  // 卸载释放 object URL
  useEffect(() => {
    return () => {
      if (objectUrlRef.current) URL.revokeObjectURL(objectUrlRef.current);
    };
  }, []);

  return (
    <div className="voice-card">
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
      {duration && <span className="voice-duration">{duration}</span>}
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
  );
}

/* ---------- 文件 ---------- */

function FileMedia({ msg, media }: { msg: ChatMessage; media: MediaDescriptor }) {
  // 契约：file 消息的文件名在 content 字段（后端 CreateMessageSerializer 约定）
  const name = caption(msg) || "附件";
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
        href={mediaContentUrl(media.media_id)}
        download={name}
        aria-label={`下载 ${name}`}
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
    kind === "image" ? "图片" : kind === "emoji" ? "表情" : kind === "voice" ? "语音" : "文件";

  if (kind !== "image" && kind !== "emoji" && kind !== "voice" && kind !== "file") {
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
