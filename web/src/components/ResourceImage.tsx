import { useCallback, useEffect, useLayoutEffect, useState } from "react";
import type { CSSProperties, ReactNode } from "react";
import { API_PREFIX } from "../api/client";
import {
  getSignedMediaUrlState,
  invalidateSignedMediaUrl,
  MediaExpiredError,
} from "../api/media";

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
 * 聊天媒体两级过期（docs/architecture/media-storage-expiration.md）：
 * - 完全过期（阶段 2）→ 「已过期」占位（灰底 + 文字，不裂图、不重试）；
 * - 原图过期（阶段 1，original 自动降级缩略图）→ expiredBadge 开启时叠加
 *   「原图已过期」角标（聊天气泡/查看器用；资产类媒体永不触发降级）。
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
  expiredBadge = false,
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
  /** 原图已过期（阶段 1 降级）时叠加「原图已过期」角标（聊天场景） */
  expiredBadge?: boolean;
}) {
  const mediaId = extractMediaId(src);
  // Empty alt marks decorative images (avatars/row covers). Their containing
  // control keeps its primary action even when the decoration cannot load.
  const decorative = alt === "";
  const [resolvedSrc, setResolvedSrc] = useState<string | null>(mediaId ? null : src);
  const [failed, setFailed] = useState(false);
  const [expired, setExpired] = useState(false);
  const [originalExpired, setOriginalExpired] = useState(false);
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
    setExpired(false);
    setOriginalExpired(false);

    if (!mediaId) {
      // 外部资源 / 非媒体路径直接使用
      setResolvedSrc(src);
      return () => {
        cancelled = true;
      };
    }

    setResolvedSrc(null);
    void getSignedMediaUrlState(mediaId, variant)
      .then((result) => {
        if (!cancelled) {
          setResolvedSrc(result.url);
          setOriginalExpired(result.originalExpired);
        }
      })
      .catch((err) => {
        if (cancelled) return;
        if (err instanceof MediaExpiredError) {
          // 完全过期：媒体已永久删除，重试无意义 → 占位不裂图
          setExpired(true);
        } else {
          setFailed(true);
        }
      });

    return () => {
      cancelled = true;
    };
  }, [src, mediaId, variant, retry]);

  if (expired) {
    // 「已过期」占位（灰底 + 文字）：与「加载失败重试」区分，媒体已永久删除
    if (decorative) return <span ref={bindHost} aria-hidden="true">{fallback}</span>;
    return (
      <span className="resource-image-expired" ref={bindHost} role="status">
        已过期
      </span>
    );
  }

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
    <>
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
      {originalExpired && expiredBadge && (
        <span className="resource-image-expired-badge" aria-label="原图已过期">
          原图已过期
        </span>
      )}
    </>
  );
}
