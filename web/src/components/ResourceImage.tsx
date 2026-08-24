import { useEffect, useState } from "react";
import type { CSSProperties, ReactNode } from "react";
import { API_PREFIX } from "../api/client";
import { getSignedMediaUrl, invalidateSignedMediaUrl } from "../api/media";

const MEDIA_PATH_PREFIX = `${API_PREFIX}/media/`;

/** 从媒体 URL 提取 media_id；非媒体路径返回 null（外部资源直接加载） */
function extractMediaId(src: string): string | null {
  if (src.startsWith(MEDIA_PATH_PREFIX)) {
    const match = src.match(/\/media\/([^/]+)\//);
    return match ? match[1] : null;
  }
  return null;
}

/**
 * 统一图片加载事实：
 * - 内部媒体：短时签名 URL 直连（<img src> 原生加载）→ 浏览器渐进解码 +
 *   HTTP 缓存（Cache-Control private），前端不再 fetch 全量 blob 占内存；
 * - 外部资源：直接交给浏览器。
 * 失败不吞掉内容，显式重试（重签 URL）。
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
  const mediaId = extractMediaId(src);
  const [resolvedSrc, setResolvedSrc] = useState<string | null>(mediaId ? null : src);
  const [failed, setFailed] = useState(false);
  const [retry, setRetry] = useState(0);

  useEffect(() => {
    let cancelled = false;
    setFailed(false);

    if (!mediaId) {
      // 外部资源 / 非媒体路径直接使用
      setResolvedSrc(src);
      return () => {
        cancelled = true;
      };
    }

    setResolvedSrc(null);
    void getSignedMediaUrl(mediaId)
      .then((url) => {
        if (!cancelled) setResolvedSrc(url);
      })
      .catch(() => {
        if (!cancelled) setFailed(true);
      });

    return () => {
      cancelled = true;
    };
  }, [src, mediaId, retry]);

  if (failed) {
    return (
      <span className="resource-image-failed-wrap">
        {fallback ?? (
          <button
            type="button"
            className="resource-image-fallback"
            onClick={() => {
              if (mediaId) invalidateSignedMediaUrl(mediaId);
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
