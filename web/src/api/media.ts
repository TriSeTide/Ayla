/**
 * 媒体 URL、descriptor 与受控上传 API（M5-2.1 / M7）。
 */
import { API_PREFIX, ApiError, apiRequest } from "./client";
import { useAuthStore } from "../stores/auth";
import type { MediaDescriptor, MediaKind } from "./types";

function seg(mediaId: string): string {
  return encodeURIComponent(mediaId);
}

export function mediaContentUrl(mediaId: string): string {
  return `${API_PREFIX}/media/${seg(mediaId)}/content`;
}

/* ---------- 签名直连 URL（流式播放，替代全量 blob 下载） ---------- */

interface SignedUrlEntry {
  url: string;
  /** 过期时间戳（秒）；到期前 60s 主动重签 */
  expiresAt: number;
  inflight?: Promise<string>;
}

// media_id → 签名 URL 缓存（模块级，页面生命周期内复用）
const signedUrlCache = new Map<string, SignedUrlEntry>();

/**
 * 获取媒体内容的短时签名 URL（<img>/<video> 直接 src 引用）。
 * 浏览器原生 Range 流式加载/播放：视频首帧秒出、拖动即点即播、
 * 图片渐进解码——不再 apiRequestBlob 全量下载进内存。
 * 缓存至到期前 60s，同一媒体+变体并发请求只签发一次。
 * @param variant "thumb" = 气泡缩略图（几 KB~百 KB）；缺省 = original（查看器/保存）
 */
export async function getSignedMediaUrl(
  mediaId: string,
  variant?: "thumb",
): Promise<string> {
  const cacheKey = variant ? `${mediaId}|${variant}` : mediaId;
  const cached = signedUrlCache.get(cacheKey);
  const now = Date.now() / 1000;
  if (cached && cached.expiresAt - 60 > now) return cached.url;
  if (cached?.inflight) return cached.inflight;

  const inflight = apiRequest<{ url: string; expires_at: number }>(
    `/media/${seg(mediaId)}:sign`,
    { method: "POST", body: variant ? { variant } : undefined },
  )
    .then((r) => {
      const url = toSameOriginMinio(r.url);
      signedUrlCache.set(cacheKey, { url, expiresAt: r.expires_at });
      return url;
    })
    .catch((err) => {
      // 失败清缓存允许下次重试
      signedUrlCache.delete(cacheKey);
      throw err;
    });
  signedUrlCache.set(cacheKey, { url: "", expiresAt: now, inflight });
  return inflight;
}

/** 失效缓存（401/加载失败时调用，下次重签） */
export function invalidateSignedMediaUrl(mediaId: string): void {
  for (const k of [...signedUrlCache.keys()]) {
    if (k === mediaId || k.startsWith(`${mediaId}|`)) signedUrlCache.delete(k);
  }
}

/** 删除自己上传的媒体（对象存储 original/thumbnail + 记录），孤儿即时回收 */
export function deleteMedia(mediaId: string): Promise<void> {
  return apiRequest<void>(`/media/${seg(mediaId)}`, { method: "DELETE" });
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
  /** 预签名直传 URL：浏览器 PUT 直打对象存储，数据面旁路应用服务器 */
  presigned_url: string;
}

export interface UploadCompleteResult {
  media_id: string;
  descriptor: MediaDescriptor;
  /** 上传会话 id：移除媒体时可调 DELETE 清理对象存储 */
  upload_id: string;
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

/** 上传进度回调数据（字节；total 可能为 0/不精确） */
export interface UploadProgress {
  loaded: number;
  total: number;
}

/**
 * 预签名绝对 URL → 同源代理路径（/minio → MinIO，Vite/反代统一转发）：
 * 数据面统一同源，规避浏览器跨源与专用网络访问策略差异。
 * 签名基于对象存储 host 计算，代理 changeOrigin 保持 Host 一致，校验不受影响。
 */
function toSameOriginMinio(presignedUrl: string): string {
  return presignedUrl.replace(/^https?:\/\/[^/]+/i, "/minio");
}

export interface UploadMediaOptions {
  /** 上传进度回调（XHR upload.onprogress，按字节） */
  onProgress?: (p: UploadProgress) => void;
  /** 取消信号：abort 时中断 XHR 并通知后端删除临时存储（「取消」按钮） */
  signal?: AbortSignal;
}

/**
 * XHR 直传对象存储（PUT 预签名 URL）：数据面完全旁路应用服务器——
 * 大文件不再被 ASGI 全量吞进内存、也不占用同步执行线程。
 * 预签名 URL 自带鉴权，不可再附加 Authorization（会破坏签名）；
 * signal 中断 → abort XHR，并 fire-and-forget 调 DELETE 清理临时对象与会话（幂等）。
 */
function putBinary(presignedUrl: string, uploadId: string, file: File, mime: string, opts: UploadMediaOptions): Promise<void> {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("PUT", toSameOriginMinio(presignedUrl));
    xhr.setRequestHeader("Content-Type", mime);
    const onAbort = () => xhr.abort();
    const clean = () => opts.signal?.removeEventListener("abort", onAbort);
    opts.signal?.addEventListener("abort", onAbort, { once: true });
    xhr.upload.onprogress = (e) => {
      if (e.lengthComputable && opts.onProgress) {
        opts.onProgress({ loaded: e.loaded, total: e.total });
      }
    };
    xhr.onload = () => {
      clean();
      if (xhr.status >= 200 && xhr.status < 300) {
        resolve();
      } else {
        reject(new ApiError(xhr.status, `上传失败（${xhr.status}）`));
      }
    };
    xhr.onerror = () => {
      clean();
      reject(new Error("网络错误，上传中断"));
    };
    xhr.onabort = () => {
      clean();
      // 用户取消：清理服务端临时存储（不阻塞本错误抛出）
      if (opts.signal?.aborted) {
        void apiRequest(`/media/uploads/${seg(uploadId)}`, { method: "DELETE" }).catch(() => {});
      }
      reject(new DOMException("上传已取消", "AbortError"));
    };
    xhr.send(file);
  });
}

/** 三步受控上传；失败会抛出并由调用方保留原输入，不伪造消息发送成功。
 *  建会话与 complete 走 apiRequest；二进制经预签名 URL 直传对象存储。 */
export async function uploadMediaFile(
  file: File,
  kind: MediaKind,
  opts: UploadMediaOptions = {},
): Promise<UploadCompleteResult> {
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
  if (!session.presigned_url) {
    throw new Error("后端未返回直传地址");
  }
  await putBinary(session.presigned_url, session.upload_id, file, mime, opts);
  const result = await apiRequest<UploadCompleteResult>(`/media/uploads/${seg(session.upload_id)}:complete`, {
    method: "POST",
  });
  // 视频自动捕获首帧海报回传（QQ 同款封面图）：卡片/列表直接显示画面，
  // 不依赖 <video> 元素加载解码（moov 尾置视频首帧黑块问题的根治）。
  // 失败不阻塞上传结果（海报缺失仅影响封面展示）。
  if (kind === "video") {
    try {
      const poster = await captureVideoPoster(file);
      await uploadPoster(result.media_id, poster);
      result.descriptor = { ...result.descriptor, thumbnail: `/api/v1/media/${result.media_id}/thumbnail` };
    } catch {
      // 海报失败静默：封面缺失不影响视频本体
    }
  }
  // 附带 upload_id：调用方移除媒体时可调 DELETE 清理对象存储（孤儿回收）
  return { ...result, upload_id: session.upload_id };
}

/** 从视频文件捕获 0.1s 处首帧，输出 JPEG Blob（宽边压到 640px）。 */
async function captureVideoPoster(file: File): Promise<Blob> {
  const url = URL.createObjectURL(file);
  try {
    const video = document.createElement("video");
    video.muted = true;
    video.playsInline = true;
    video.preload = "auto";
    video.src = url;
    await new Promise<void>((resolve, reject) => {
      const timer = window.setTimeout(() => reject(new Error("poster timeout")), 15000);
      video.onloadeddata = () => {
        window.clearTimeout(timer);
        resolve();
      };
      video.onerror = () => {
        window.clearTimeout(timer);
        reject(new Error("video load error"));
      };
    });
    // seek 到 0.1s 确保解码出真实首帧
    await new Promise<void>((resolve) => {
      const done = () => resolve();
      video.onseeked = done;
      try {
        video.currentTime = 0.1;
      } catch {
        done();
      }
    });
    const scale = Math.min(1, 640 / Math.max(video.videoWidth || 640, 1));
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round((video.videoWidth || 640) * scale));
    canvas.height = Math.max(1, Math.round((video.videoHeight || 360) * scale));
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("no 2d context");
    ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
    const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/jpeg", 85));
    if (!blob) throw new Error("canvas toBlob failed");
    return blob;
  } finally {
    URL.revokeObjectURL(url);
  }
}

/** 上传视频海报帧到 :poster 端点（JPEG ≤2MB，仅上传者本人）。 */
async function uploadPoster(mediaId: string, blob: Blob): Promise<void> {
  const { accessToken } = useAuthStore.getState();
  const r = await fetch(`${API_PREFIX}/media/${seg(mediaId)}:poster`, {
    method: "POST",
    headers: {
      "Content-Type": "image/jpeg",
      ...(accessToken ? { Authorization: `Bearer ${accessToken}` } : {}),
    },
    body: blob,
  });
  if (!r.ok) throw new Error(`poster upload failed (${r.status})`);
}
