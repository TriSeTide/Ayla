/**
 * 媒体 URL、descriptor 与受控上传 API（M5-2.1）。
 */
import { API_PREFIX, ApiError, apiRequest } from "./client";
import type { MediaDescriptor, MediaKind } from "./types";

function seg(mediaId: string): string {
  return encodeURIComponent(mediaId);
}

export function mediaContentUrl(mediaId: string): string {
  return `${API_PREFIX}/media/${seg(mediaId)}/content`;
}

export function resolveMediaPath(path: string | null | undefined): string | null {
  if (!path) return null;
  if (path.startsWith(`${API_PREFIX}/media/`)) return path;
  return null;
}

export function fetchMediaDescriptor(mediaId: string) {
  return apiRequest<MediaDescriptor>(`/media/${seg(mediaId)}/`);
}

export function formatBytes(size: number): string {
  if (!Number.isFinite(size) || size < 0) return "";
  if (size < 1024) return `${size} B`;
  if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`;
  return `${(size / (1024 * 1024)).toFixed(1)} MB`;
}

export function formatDuration(seconds: number | null | undefined): string {
  if (seconds == null || !Number.isFinite(seconds)) return "";
  const total = Math.max(0, Math.round(seconds));
  return `${Math.floor(total / 60)}:${(total % 60).toString().padStart(2, "0")}`;
}

interface UploadSession {
  upload_id: string;
  kind: MediaKind;
  /** 该 kind 大小上限（字节）；null = 不设上限（图片/语音默认放开） */
  max_bytes: number | null;
  expires_at: string;
}

interface UploadCompleteResult {
  media_id: string;
  descriptor: MediaDescriptor;
}

/* ---------- 图片本地校验 ---------- */

/**
 * 允许的图片类型（与后端 media/services ALLOWED_MIME["image"] 对齐）。
 * 覆盖常见位图 + 现代格式（AVIF/HEIC/HEIF）+ 传统格式（BMP/TIFF/ICO/SVG），
 * 以及浏览器/系统可能上报的别名（image/jpg、image/pjpeg）。
 */
export const IMAGE_TYPES = new Set([
  "image/png",
  "image/jpeg",
  "image/jpg",
  "image/pjpeg",
  "image/gif",
  "image/webp",
  "image/avif",
  "image/heic",
  "image/heif",
  "image/heix",
  "image/bmp",
  "image/x-ms-bmp",
  "image/tiff",
  "image/x-icon",
  "image/vnd.microsoft.icon",
  "image/svg+xml",
]);

/** 图片大小不设上限（后端 MEDIA_MAX_IMAGE_BYTES=0 同步放开）；仅校验类型与非空。 */
export const IMAGE_UNSUPPORTED_MESSAGE =
  "仅支持图片文件（PNG/JPEG/GIF/WebP/AVIF/HEIC/BMP/TIFF/ICO/SVG）";

/**
 * 允许的视频类型（与后端 ALLOWED_MIME["video"] 对齐）：MP4/WebM/MOV/M4V/MKV/3GP。
 * 大小不设上限（MEDIA_MAX_VIDEO_BYTES=0）；浏览器可内联播放的格式优先。
 */
export const VIDEO_TYPES = new Set([
  "video/mp4",
  "video/webm",
  "video/quicktime",
  "video/x-m4v",
  "video/x-matroska",
  "video/3gpp",
  "video/3gpp2",
]);

export const VIDEO_UNSUPPORTED_MESSAGE = "仅支持视频文件（MP4/WebM/MOV/M4V/MKV/3GP）";

/**
 * 选择阶段本地校验：类型（图片或视频白名单）+ 非空；不限制大小。
 * 合法返回 null；kind 给出可上传的媒体种类，供聊天发送分流
 * （本入口只会产生 image/video 两种消息）。
 */
export function validateMediaFile(file: File): { error: string | null; kind: "image" | "video" } {
  const mime = (file.type || "").split(";")[0].trim();
  if (IMAGE_TYPES.has(mime)) {
    return { error: file.size <= 0 ? "文件内容为空" : null, kind: "image" };
  }
  if (VIDEO_TYPES.has(mime)) {
    return { error: file.size <= 0 ? "文件内容为空" : null, kind: "video" };
  }
  return { error: "仅支持图片（PNG/JPEG/GIF/WebP/AVIF/HEIC/BMP/TIFF/ICO/SVG）或视频（MP4/WebM/MOV 等）", kind: "image" };
}

/**
 * 选择阶段本地校验：类型（白名单）+ 非空；不限制大小。
 * 合法返回 null，否则返回可展示的错误文案；服务端三步上传仍会二次校验。
 */
export function validateImageFile(file: File): string | null {
  if (!IMAGE_TYPES.has(file.type)) return IMAGE_UNSUPPORTED_MESSAGE;
  if (file.size <= 0) return "图片内容为空";
  return null;
}

/** 三步受控上传；失败会抛出并由调用方保留原输入，不伪造消息发送成功。 */
export async function uploadMediaFile(file: File, kind: MediaKind): Promise<UploadCompleteResult> {
  // MIME 规范化：MediaRecorder 输出可能带 codec 参数（如 audio/webm;codecs=opus），
  // 后端 allowlist 只匹配基础类型，上传取分号前主类型（audio/webm）。
  const mime = (file.type || "application/octet-stream").split(";")[0].trim();
  let session: UploadSession;
  try {
    session = await apiRequest<UploadSession>("/media/uploads", {
      method: "POST",
      body: { kind, expected_size: file.size, mime_type: mime },
    });
  } catch (e) {
    if (e instanceof ApiError && e.status === 413) {
      throw new Error("文件超过允许的大小上限");
    }
    throw e;
  }
  // max_bytes=null 表示该类别不设上限；有上限时提前拦截并展示具体数值
  if (session.max_bytes != null && file.size > session.max_bytes) {
    throw new Error(`文件超过大小上限（${formatBytes(session.max_bytes)}）`);
  }
  await apiRequest<{ detail: string }>(`/media/uploads/${seg(session.upload_id)}`, {
    method: "PUT",
    body: file,
    headers: { "Content-Type": mime },
  });
  return apiRequest<UploadCompleteResult>(`/media/uploads/${seg(session.upload_id)}:complete`, {
    method: "POST",
  });
}
