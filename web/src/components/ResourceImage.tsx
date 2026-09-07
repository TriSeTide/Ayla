import { useCallback, useEffect, useLayoutEffect, useState } from "react";
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
  variant,
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
  /** 签发变体："thumb" = 缩略图（气泡用）；缺省 = 原图（查看器/保存） */
  variant?: "thumb";
}) {
  const mediaId = extractMediaId(src);
  // Empty alt marks decorative images (avatars/row covers). Their containing
  // control keeps its primary action even when the decoration cannot load.
  const decorative = alt === "";
  const [resolvedSrc, setResolvedSrc] = useState<string | null>(mediaId ? null : src);
  const [failed, setFailed] = useState(false);
  const [retry, setRetry] = useState(0);
  const [enclosingControl, setEnclosingControl] = useState<HTMLElement | null>(null);
  const bindHost = useCallback((node: HTMLElement | null) => {
    if (node) setEnclosingControl(node.parentElement?.closest<HTMLElement>("button,a[href],[role=button]") ?? null);
  }, []);
  const retryImage = useCallback(() => {
    if (mediaId) invalidateSignedMediaUrl(mediaId);
    setFailed(false);
    setRetry((value) => value + 1);
  }, [mediaId]);

  // Image cards already own a native button or link. While their image has
  // failed, that same control retries it; nesting another interactive element
  // would produce invalid markup and could also open the viewer on retry.
  useLayoutEffect(() => {
    if (!failed || !enclosingControl || decorative) return;
    const previousLabel = enclosingControl.getAttribute("aria-label");
    const retryLabel = `${alt}：图片加载失败，重试`;
    const onRetry = (event: MouseEvent) => {
      event.preventDefault();
      event.stopImmediatePropagation();
      retryImage();
    };
    enclosingControl.setAttribute("aria-label", retryLabel);
    enclosingControl.addEventListener("click", onRetry, true);
    return () => {
      enclosingControl.removeEventListener("click", onRetry, true);
      if (enclosingControl.getAttribute("aria-label") === retryLabel) {
        if (previousLabel == null) enclosingControl.removeAttribute("aria-label");
        else enclosingControl.setAttribute("aria-label", previousLabel);
      }
    };
  }, [failed, enclosingControl, alt, decorative, retryImage]);

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
    void getSignedMediaUrl(mediaId, variant)
      .then((url) => {
        if (!cancelled) setResolvedSrc(url);
      })
      .catch(() => {
        if (!cancelled) setFailed(true);
      });

    return () => {
      cancelled = true;
    };
  }, [src, mediaId, variant, retry]);

  if (failed) {
    if (decorative) return <span ref={bindHost} aria-hidden="true">{fallback}</span>;
    return (
      <span className="resource-image-failed-wrap" ref={bindHost}>
        {fallback}
        {enclosingControl ? (
          <span className="resource-image-fallback" role="status">图片加载失败，点击重试</span>
        ) : (
          <button
            type="button"
            className="resource-image-fallback"
            aria-label={`${alt}：图片加载失败，重试`}
            onClick={(event) => { event.stopPropagation(); retryImage(); }}
          >
            图片加载失败，点击重试
          </button>
        )}
      </span>
    );
  }

  if (!resolvedSrc) return <span className="resource-image-loading" ref={bindHost}>{fallback}</span>;

  return (
    <img
      ref={bindHost}
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
