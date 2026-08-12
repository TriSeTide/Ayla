/**
 * 媒体 URL 与 descriptor API（M5-2.1）。
 *
 * 契约来源：backend/apps/media/{serializers,views,urls}.py
 * - descriptor.thumbnail / .waveform 是后端给出的相对路径
 *   （`/api/v1/media/{id}/thumbnail|waveform`），content 端点同形；
 * - 全部 URL 由本模块集中构造：media_id 一律 encodeURIComponent，
 *   组件内禁止手写 `/api/v1/media/...` 字符串，禁止裸 URL 拼接。
 */
import { API_PREFIX, apiRequest } from "./client";
import type { MediaDescriptor } from "./types";

function seg(mediaId: string): string {
  return encodeURIComponent(mediaId);
}

/** 原内容端点（file 下载 / 语音播放 / 图片原图） */
export function mediaContentUrl(mediaId: string): string {
  return `${API_PREFIX}/media/${seg(mediaId)}/content`;
}

/** descriptor 路径解析：只接受本应用内 /api/v1/media/ 相对路径，其余拒绝 */
export function resolveMediaPath(path: string | null | undefined): string | null {
  if (!path) return null;
  if (path.startsWith(`${API_PREFIX}/media/`)) return path;
  return null;
}

/** GET /media/{id}/ —— 拉取 descriptor（WS 帧只带 media_id 字符串时补拉） */
export function fetchMediaDescriptor(mediaId: string) {
  return apiRequest<MediaDescriptor>(`/media/${seg(mediaId)}/`);
}

/** 人类可读文件大小 */
export function formatBytes(size: number): string {
  if (!Number.isFinite(size) || size < 0) return "";
  if (size < 1024) return `${size} B`;
  if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`;
  return `${(size / (1024 * 1024)).toFixed(1)} MB`;
}

/** 语音时长 mm:ss */
export function formatDuration(seconds: number | null | undefined): string {
  if (seconds == null || !Number.isFinite(seconds)) return "";
  const total = Math.max(0, Math.round(seconds));
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m}:${s.toString().padStart(2, "0")}`;
}
