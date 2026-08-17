import { useState } from "react";
import type { CSSProperties, ReactNode } from "react";

/** 统一图片加载事实：loading/error 不吞掉内容，失败可显式重试。 */
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
  const [failed, setFailed] = useState(false);
  const [retry, setRetry] = useState(0);
  if (failed) {
    return (
      <span className="resource-image-failed-wrap">
        {fallback ?? <button type="button" className="resource-image-fallback" onClick={() => { setFailed(false); setRetry((value) => value + 1); }}>图片加载失败，点击重试</button>}
      </span>
    );
  }
  return <img key={retry} src={src} alt={alt} className={className} style={style} width={width} height={height} loading={loading} onLoad={onReady} onError={() => setFailed(true)} />;
}
