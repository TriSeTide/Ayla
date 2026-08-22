/**
 * ImageViewer —— 聊天图片/视频全屏查看器（QQ 式点击打开 + 可保存）。
 *
 * 视觉（design.md §6 模态层级）：indigo 压暗遮罩 + 玻璃质感关闭钮，
 * 原图/视频 object-fit contain 居中；底部玻璃胶囊操作条（保存 + 多图计数）。
 * 行为：ESC / 点击遮罩空白关闭；打开即 focus 关闭按钮（键盘可达）；←/→ 切换多图。
 * 图片经 ResourceImage 加载（Bearer 鉴权 + blob 缓存，与气泡共享缓存秒开）；
 * 视频渲染 <video controls autoPlay>（气泡内仅首帧+播放键，此处完整预览）；
 * 保存走 apiRequestBlob → objectURL 触发下载（浏览器原生下载不带 token）。
 * 乐观消息（未上传）的本地预览（localUrl）只展示，不可保存。
 */
import { useCallback, useEffect, useRef, useState } from "react";
import type { MediaDescriptor } from "../../api/types";
import { apiRequestBlob } from "../../api/client";
import { mediaContentUrl } from "../../api/media";
import { ResourceImage } from "../ResourceImage";
import { IconClose, IconDownload } from "../icons";

/** 查看器条目：服务端媒体或乐观本地预览 */
export interface ViewerItem {
  media: MediaDescriptor | null;
  /** 乐观消息本地预览（未上传；只展示不保存） */
  localUrl?: string;
  /** 本地预览为视频（服务端媒体按 media.kind 判断） */
  isVideo?: boolean;
  alt: string;
}

/** MIME → 下载扩展名 */
function extFromMime(mime: string): string {
  const table: Record<string, string> = {
    "image/png": "png",
    "image/jpeg": "jpg",
    "image/jpg": "jpg",
    "image/pjpeg": "jpg",
    "image/gif": "gif",
    "image/webp": "webp",
    "image/avif": "avif",
    "image/heic": "heic",
    "image/heif": "heif",
    "image/bmp": "bmp",
    "image/x-ms-bmp": "bmp",
    "image/tiff": "tiff",
    "image/x-icon": "ico",
    "image/vnd.microsoft.icon": "ico",
    "image/svg+xml": "svg",
    "video/mp4": "mp4",
    "video/webm": "webm",
    "video/quicktime": "mov",
    "video/x-m4v": "m4v",
    "video/x-matroska": "mkv",
    "video/3gpp": "3gp",
    "video/3gpp2": "3g2",
  };
  return table[mime] ?? (mime.startsWith("video/") ? "mp4" : "png");
}

/** 触发浏览器保存二进制（内部媒体需带 Bearer 拉取） */
async function downloadMedia(media: MediaDescriptor): Promise<void> {
  const blob = await apiRequestBlob(
    mediaContentUrl(media.media_id).replace(/^\/api\/v1/, ""),
  );
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  const prefix = media.kind === "video" ? "ayla-video" : "ayla-image";
  a.download = `${prefix}-${media.media_id.slice(0, 8)}.${extFromMime(media.mime_type)}`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  // 给浏览器一点时间启动下载再回收 objectURL
  window.setTimeout(() => URL.revokeObjectURL(url), 4000);
}

/** 查看器内视频播放器：带 Bearer 拉 blob，完整 controls + 自动播放 */
function VideoPlayer({ media }: { media: MediaDescriptor }) {
  const [src, setSrc] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let cancelled = false;
    let url: string | null = null;
    apiRequestBlob(mediaContentUrl(media.media_id).replace(/^\/api\/v1/, ""))
      .then((blob) => {
        if (cancelled) return;
        url = URL.createObjectURL(blob);
        setSrc(url);
      })
      .catch(() => {
        if (!cancelled) setFailed(true);
      });
    return () => {
      cancelled = true;
      if (url) URL.revokeObjectURL(url);
    };
  }, [media.media_id]);

  if (failed) return <span className="image-viewer-fallback">视频加载失败</span>;
  if (!src) return <span className="media-frame-skeleton image-viewer-video-skeleton" />;
  return (
    <video
      src={src}
      className="image-viewer-video"
      controls
      autoPlay
      playsInline
    />
  );
}

/** 本地预览（乐观消息，未上传）：图片或视频原样展示 */
function LocalPreview({ item }: { item: ViewerItem }) {
  if (item.isVideo) {
    return (
      <video src={item.localUrl} className="image-viewer-video" controls playsInline />
    );
  }
  return <img src={item.localUrl} alt={item.alt} className="image-viewer-img" />;
}

export function ImageViewer({
  media,
  alt,
  items,
  initialIndex = 0,
  onClose,
}: {
  /** 单条目模式（兼容旧调用） */
  media?: MediaDescriptor | null;
  alt?: string;
  /** 多条目模式：同消息的图片/视频列表（左上右切换） */
  items?: ViewerItem[];
  initialIndex?: number;
  onClose: () => void;
}) {
  const list: ViewerItem[] =
    items && items.length > 0
      ? items
      : [{ media: media ?? null, alt: alt ?? "图片" }];
  const [index, setIndex] = useState(Math.min(Math.max(initialIndex, 0), list.length - 1));
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState(false);
  const closeRef = useRef<HTMLButtonElement | null>(null);

  const current = list[index];
  const isLocal = current.localUrl != null && current.media == null;

  const close = useCallback(() => onClose(), [onClose]);

  useEffect(() => {
    closeRef.current?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
      if (e.key === "ArrowLeft") setIndex((i) => Math.max(0, i - 1));
      if (e.key === "ArrowRight") setIndex((i) => Math.min(list.length - 1, i + 1));
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose, list.length]);

  const save = async () => {
    if (!current.media || saving) return;
    setSaving(true);
    setSaveError(false);
    try {
      await downloadMedia(current.media);
    } catch {
      setSaveError(true);
    } finally {
      setSaving(false);
    }
  };

  return (
    <div
      className="image-viewer"
      role="dialog"
      aria-modal="true"
      aria-label={list.length > 1 ? `图片查看：${index + 1}/${list.length}` : alt ? `图片查看：${alt}` : "图片查看"}
      onClick={close}
    >
      <button
        type="button"
        className="image-viewer-close"
        onClick={close}
        aria-label="关闭查看"
        ref={closeRef}
      >
        <IconClose width={22} height={22} />
      </button>
      <div className="image-viewer-stage" onClick={(e) => e.stopPropagation()}>
        {current.localUrl && current.media == null ? (
          <LocalPreview item={current} />
        ) : current.media?.kind === "video" ? (
          <VideoPlayer media={current.media} />
        ) : current.media ? (
          <ResourceImage
            src={mediaContentUrl(current.media.media_id)}
            alt={current.alt || "图片原图"}
            className="image-viewer-img"
            loading="eager"
            fallback={<span className="image-viewer-fallback">图片加载失败</span>}
          />
        ) : (
          <span className="image-viewer-fallback">媒体不可用</span>
        )}
      </div>
      {list.length > 1 && (
        <>
          <button
            type="button"
            className="image-viewer-nav prev"
            onClick={(e) => {
              e.stopPropagation();
              setIndex((i) => Math.max(0, i - 1));
            }}
            aria-label="上一张"
            disabled={index === 0}
          >
            ‹
          </button>
          <button
            type="button"
            className="image-viewer-nav next"
            onClick={(e) => {
              e.stopPropagation();
              setIndex((i) => Math.min(list.length - 1, i + 1));
            }}
            aria-label="下一张"
            disabled={index === list.length - 1}
          >
            ›
          </button>
        </>
      )}
      <div className="image-viewer-actions" onClick={(e) => e.stopPropagation()}>
        {list.length > 1 && <span className="image-viewer-counter">{index + 1}/{list.length}</span>}
        <button
          type="button"
          className="image-viewer-save"
          onClick={() => void save()}
          disabled={saving || isLocal || !current.media}
        >
          <IconDownload width={16} height={16} style={{ verticalAlign: "-2px", marginRight: 6 }} />
          {saving ? "保存中…" : isLocal ? "发送后可保存" : "保存"}
        </button>
      </div>
      {saveError && (
        <div className="image-viewer-error" role="alert">保存失败，请重试</div>
      )}
    </div>
  );
}
