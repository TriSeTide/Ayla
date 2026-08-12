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
import type { ChatMessage, MediaDescriptor } from "../../api/types";
import { useMessageStore } from "../../stores/message";
import { IconDownload, IconFile, IconImage, IconMic, IconPause, IconPlay, IconRetry } from "../icons";

type LoadState = "loading" | "ready" | "error";

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
  const [state, setState] = useState<LoadState>("loading");
  const [retryKey, setRetryKey] = useState(0);

  if (state === "error") {
    return (
      <MediaPlaceholder
        state="error"
        label={label}
        onRetry={() => {
          setState("loading");
          setRetryKey((k) => k + 1);
        }}
      />
    );
  }

  const imgStyle: CSSProperties = state === "loading" ? { visibility: "hidden" } : {};
  return (
    <div className="media-frame">
      {state === "loading" && (
        <span
          className="skeleton"
          style={
            isEmoji
              ? { width: 96, height: 96 }
              : { width: media.width ? Math.min(media.width, 320) : 240, height: 180 }
          }
        />
      )}
      <img
        key={retryKey}
        className={isEmoji ? "media-emoji" : "media-image"}
        style={imgStyle}
        src={src}
        alt={caption(msg) || label}
        loading="lazy"
        onLoad={() => setState("ready")}
        onError={() => setState("error")}
      />
    </div>
  );
}

/* ---------- 语音 ---------- */

function VoiceMedia({ media }: { media: MediaDescriptor }) {
  const wave = resolveMediaPath(media.waveform);
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const [playing, setPlaying] = useState(false);
  const [waveFailed, setWaveFailed] = useState(false);
  const duration = formatDuration(media.duration);

  const toggle = () => {
    if (!audioRef.current) {
      const audio = new Audio(mediaContentUrl(media.media_id));
      audio.addEventListener("ended", () => setPlaying(false));
      audio.addEventListener("error", () => setPlaying(false));
      audioRef.current = audio;
    }
    const audio = audioRef.current;
    if (playing) {
      audio.pause();
      setPlaying(false);
    } else {
      void audio.play().then(() => setPlaying(true)).catch(() => setPlaying(false));
    }
  };

  return (
    <div className="voice-card">
      <button
        type="button"
        className="voice-play"
        onClick={toggle}
        aria-label={playing ? "暂停语音" : "播放语音"}
      >
        {playing ? <IconPause width={16} height={16} /> : <IconPlay width={16} height={16} />}
      </button>
      {wave && !waveFailed ? (
        <img
          className="voice-wave"
          src={wave}
          alt="语音波形"
          onError={() => setWaveFailed(true)}
        />
      ) : (
        <span className="voice-wave" style={{ display: "grid", placeItems: "center" }}>
          <IconMic width={18} height={18} />
        </span>
      )}
      {duration && <span className="voice-duration">{duration}</span>}
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
