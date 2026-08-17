import { useEffect, useState } from "react";
import type { CSSProperties, ReactNode } from "react";
import { API_PREFIX, apiRequestBlob } from "../api/client";

const MEDIA_PATH_PREFIX = `${API_PREFIX}/media/`;

/**
 * 统一图片加载事实：内部媒体通过带 Bearer 的 fetch 读取，避免 <img src>
 * 丢失 Authorization 导致 content 接口返回 401；外部资源仍直接交给浏览器加载。
 * loading/error 不吞掉内容，失败可显式重试。
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
    let objectUrl: string | null = null;
    setFailed(false);

    if (!src.startsWith(MEDIA_PATH_PREFIX)) {
      setResolvedSrc(src);
      return () => {
        cancelled = true;
      };
    }

    setResolvedSrc(null);
    // apiRequestBlob 接收 API_PREFIX 之后的相对路径，避免客户端重复拼接 /api/v1。
    void apiRequestBlob(src.slice(API_PREFIX.length))
      .then((blob) => {
        if (cancelled) return;
        objectUrl = URL.createObjectURL(blob);
        setResolvedSrc(objectUrl);
      })
      .catch(() => {
        if (!cancelled) setFailed(true);
      });

    return () => {
      cancelled = true;
      if (objectUrl) URL.revokeObjectURL(objectUrl);
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