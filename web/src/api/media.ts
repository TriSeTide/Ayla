/**
 * 媒体 URL、descriptor 与受控上传 API（M5-2.1）。
 */
import { API_PREFIX, apiRequest } from "./client";
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
  max_bytes: number;
  expires_at: string;
}

interface UploadCompleteResult {
  media_id: string;
  descriptor: MediaDescriptor;
}

/* ---------- 头像本地校验（M5-2.1） ---------- */

/** 头像大小上限（与后端 MEDIA_MAX_IMAGE_BYTES=10MB 一致） */
export const AVATAR_MAX_BYTES = 10 * 1024 * 1024;

/** 允许的头像位图类型（与后端 media/services ALLOWED_MIME["image"] 对齐） */
const AVATAR_TYPES = new Set(["image/png", "image/jpeg", "image/gif", "image/webp"]);

/**
 * 选择阶段本地校验：类型（位图）+ 大小（≤10MB）。
 * 合法返回 null，否则返回可展示的错误文案；服务端三步上传仍会二次校验。
 */
export function validateAvatarFile(file: File): string | null {
  if (!AVATAR_TYPES.has(file.type)) return "仅支持 PNG/JPEG/GIF/WebP 图片";
  if (file.size <= 0) return "图片内容为空";
  if (file.size > AVATAR_MAX_BYTES) return "图片超过 10MB 大小限制";
  return null;
}

/** 三步受控上传；失败会抛出并由调用方保留原输入，不伪造消息发送成功。 */
export async function uploadMediaFile(file: File, kind: MediaKind): Promise<UploadCompleteResult> {
  // MIME 规范化：MediaRecorder 输出可能带 codec 参数（如 audio/webm;codecs=opus），
  // 后端 allowlist 只匹配基础类型，上传取分号前主类型（audio/webm）。
  const mime = (file.type || "application/octet-stream").split(";")[0].trim();
  const session = await apiRequest<UploadSession>("/media/uploads", {
    method: "POST",
    body: { kind, expected_size: file.size, mime_type: mime },
  });
  if (file.size > session.max_bytes) throw new Error("文件超过允许大小");
  await apiRequest<{ detail: string }>(`/media/uploads/${seg(session.upload_id)}`, {
    method: "PUT",
    body: file,
    headers: { "Content-Type": mime },
  });
  return apiRequest<UploadCompleteResult>(`/media/uploads/${seg(session.upload_id)}:complete`, {
    method: "POST",
  });
}
