/**
 * ImageViewer —— 聊天图片/视频全屏查看器（QQ 式点击打开 + 可保存）。
 *
 * 视觉（design.md §6 模态层级）：indigo 压暗遮罩 + 玻璃质感关闭钮，
 * 原图/视频 object-fit contain 居中；底部玻璃胶囊操作条（保存）。
 * 行为：ESC / 点击遮罩空白关闭；打开即 focus 关闭按钮（键盘可达）。
 * 图片经 ResourceImage 加载（Bearer 鉴权 + blob 缓存，与气泡共享缓存秒开）；
 * 视频渲染 <video controls autoPlay>（气泡内仅首帧+播放键，此处完整预览）；
 * 保存走 apiRequestBlob → objectURL 触发下载（浏览器原生下载不带 token）。
 */
import { useEffect, useRef, useState } from "react";
import type { MediaDescriptor } from "../../api/types";
import { apiRequestBlob } from "../../api/client";
import { mediaContentUrl } from "../../api/media";
import { ResourceImage } from "../ResourceImage";
import { IconClose, IconDownload } from "../icons";

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

export function ImageViewer({
  media,
  alt,
  onClose,
}: {
  media: MediaDescriptor;
  alt: string;
  onClose: () => void;
}) {
  const closeRef = useRef<HTMLButtonElement | null>(null);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  // ESC 关闭 + 打开时焦点落关闭按钮（键盘可达）
  useEffect(() => {
    closeRef.current?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const save = async () => {
    if (saving) return;
    setSaving(true);
    setSaveError(null);
    try {
      await downloadMedia(media);
    } catch {
      setSaveError("保存失败，请重试");
    } finally {
      setSaving(false);
    }
  };

  return (
    <div
      className="image-viewer"
      role="dialog"
      aria-modal="true"
      aria-label={alt ? `图片查看：${alt}` : "图片查看"}
      onClick={onClose}
    >
      <button
        ref={closeRef}
        type="button"
        className="image-viewer-close"
        onClick={onClose}
        aria-label="关闭图片查看"
      >
        <IconClose width={20} height={20} />
      </button>
      <div className="image-viewer-stage" onClick={(e) => e.stopPropagation()}>
        {media.kind === "video" ? (
          <VideoPlayer media={media} />
        ) : (
          <ResourceImage
            src={mediaContentUrl(media.media_id)}
            alt={alt || "图片原图"}
            className="image-viewer-img"
            loading="eager"
            fallback={<span className="image-viewer-fallback">图片加载失败</span>}
          />
        )}
      </div>
      <div className="image-viewer-actions" onClick={(e) => e.stopPropagation()}>
        {saveError && (
          <span className="image-viewer-save-error" role="alert">
            {saveError}
          </span>
        )}
        <button
          type="button"
          className="btn btn-glow image-viewer-save"
          onClick={() => void save()}
          disabled={saving}
        >
          <IconDownload width={16} height={16} />
          {saving ? "保存中…" : "保存图片"}
        </button>
      </div>
    </div>
  );
}
