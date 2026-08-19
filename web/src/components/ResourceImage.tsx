import { useEffect, useState } from "react";
import type { CSSProperties, ReactNode } from "react";
import { API_PREFIX, apiRequestBlob } from "../api/client";

const MEDIA_PATH_PREFIX = `${API_PREFIX}/media/`;

// 全局 blob URL 缓存：避免同一 media_id 重复请求和创建 blob URL
const blobCache = new Map<string, string>();

/**
 * 从媒体 URL 提取 media_id 作为缓存 key，提升缓存鲁棒性。
 * 例如：/api/v1/media/abc123/content → abc123
 */
function getCacheKey(src: string): string {
  if (src.startsWith(MEDIA_PATH_PREFIX)) {
    // 匹配 /media/{media_id}/ 模式
    const match = src.match(/\/media\/([^/]+)\//);
    return match ? match[1] : src;
  }
  return src;
}

/**
 * 统一图片加载事实：内部媒体通过带 Bearer 的 fetch 读取，避免 <img src>
 * 丢失 Authorization 导致 content 接口返回 401；外部资源仍直接交给浏览器加载。
 * loading/error 不吞掉内容，失败可显式重试。
 * 
 * 性能优化（图片加载慢问题修复）：
 * - 全局缓存 blob URL：同一 media_id 只请求一次，后续复用
 * - 缓存 key 使用 media_id 而非完整 URL，提升缓存鲁棒性
 * - blob URL 不再自动 revoke，由缓存管理生命周期
 * 
 * 竞态条件修复（刷新后首个群头像加载失败）：
 * - 使用 media_id 作为缓存 key，避免 URL 变化导致缓存失效
 * - 配合 chat store 防重复加载机制，避免组件重渲染导致 blob URL 失效
 */
export function ResourceImage({
  src,
  alt,
  className,
  style,
  width,
  height,
  loading = "lazy",
  onReady,
  fallback,
}: {
  src: string;
  alt: string;
  className?: string;
  style?: CSSProperties;
  width?: number;
  height?: number;
  loading?: "eager" | "lazy";
  onReady?: () => void;
  fallback?: ReactNode;
}) {
  const [resolvedSrc, setResolvedSrc] = useState<string | null>(
    src.startsWith(MEDIA_PATH_PREFIX) ? null : src,
  );
  const [failed, setFailed] = useState(false);
  const [retry, setRetry] = useState(0);

  useEffect(() => {
    let cancelled = false;
    setFailed(false);

    if (!src.startsWith(MEDIA_PATH_PREFIX)) {
      setResolvedSrc(src);
      return () => {
        cancelled = true;
      };
    }

    // 检查缓存：使用 media_id 作为 key，命中则直接使用，避免重复请求
    const cacheKey = getCacheKey(src);
    const cached = blobCache.get(cacheKey);
    if (cached) {
      setResolvedSrc(cached);
      return () => {
        cancelled = true;
      };
    }

    setResolvedSrc(null);
    // apiRequestBlob 接收 API_PREFIX 之后的相对路径，避免客户端重复拼接 /api/v1。
    void apiRequestBlob(src.slice(API_PREFIX.length))
      .then((blob) => {
        if (cancelled) return;
        const objectUrl = URL.createObjectURL(blob);
        // 写入缓存供后续复用（使用 media_id 作为 key）
        blobCache.set(cacheKey, objectUrl);
        setResolvedSrc(objectUrl);
      })
      .catch(() => {
        if (!cancelled) setFailed(true);
      });

    // 清理时不再 revoke blob URL（由缓存管理生命周期）
    return () => {
      cancelled = true;
    };
  }, [src, retry]);

  if (failed) {
    return (
      <span className="resource-image-failed-wrap">
        {fallback ?? (
          <button
            type="button"
            className="resource-image-fallback"
            onClick={() => {
              setFailed(false);
              setRetry((value) => value + 1);
            }}
          >
            图片加载失败，点击重试
          </button>
        )}
      </span>
    );
  }

  if (!resolvedSrc) return <span className="resource-image-loading">{fallback}</span>;

  return (
    <img
      key={`${resolvedSrc}:${retry}`}
      src={resolvedSrc}
      alt={alt}
      className={className}
      style={style}
      width={width}
      height={height}
      loading={loading}
      onLoad={onReady}
      onError={() => setFailed(true)}
    />
  );
}