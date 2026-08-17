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

/** 三步受控上传；失败会抛出并由调用方保留原输入，不伪造消息发送成功。 */
export async function uploadMediaFile(file: File, kind: MediaKind): Promise<UploadCompleteResult> {
  const session = await apiRequest<UploadSession>("/media/uploads", {
    method: "POST",
    body: { kind, expected_size: file.size, mime_type: file.type || "application/octet-stream" },
  });
  if (file.size > session.max_bytes) throw new Error("文件超过允许大小");
  await apiRequest<{ detail: string }>(`/media/uploads/${seg(session.upload_id)}`, {
    method: "PUT",
    body: file,
    headers: { "Content-Type": file.type || "application/octet-stream" },
  });
  return apiRequest<UploadCompleteResult>(`/media/uploads/${seg(session.upload_id)}:complete`, {
    method: "POST",
  });
}
