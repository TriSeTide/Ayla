/**
 * SignedVideo —— 帖子视频首帧预览块（签名 URL 直连流式播放）。
 *
 * 与 chat 侧 VideoFrame 同一事实：<video src> 用短时签名 URL 直连对象存储，
 * 原生 Range 流式加载（preload=metadata 秒出首帧、拖动即点即播）。
 *
 * 关键契约：MediaDescriptor.thumbnail 是派生封面对象路径（/api/v1/media/{id}/thumbnail，
 * JPEG 静帧）——图片缩略图与视频海报帧共用；绝不能作为 <video src>。
 * 此前帖子卡把该路径塞给 video 导致视频无源可播（黑块），本组件按 media_id
 * 签发 original 视频 URL。
 *
 * 定位：无海报帧视频（存量 / 浏览器抽帧失败）的首帧预览降级路径。
 * 有海报帧的封面渲染走 PostVideoCover（<img> 秒出，不挂 video 元素）。
 */
import { useEffect, useState } from "react";
import { getSignedMediaUrl, invalidateSignedMediaUrl } from "../api/media";

export function SignedVideo({
  mediaId,
  className,
  controls = false,
  ariaLabel,
}: {
  mediaId: string;
  className?: string;
  /** 详情页内联播放传 true（完整控制条）；卡片首帧预览保持 false（静音） */
  controls?: boolean;
  ariaLabel?: string;
}) {
  const [src, setSrc] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);
  const [retry, setRetry] = useState(0);

  useEffect(() => {
    let cancelled = false;
    setFailed(false);
    setSrc(null);
    getSignedMediaUrl(mediaId)
      .then((url) => {
        if (!cancelled) setSrc(url);
      })
      .catch(() => {
        if (!cancelled) setFailed(true);
      });
    return () => {
      cancelled = true;
    };
  }, [mediaId, retry]);

  if (failed) {
    return (
      <span className="resource-image-failed-wrap">
        <button
          type="button"
          className="resource-image-fallback"
          onClick={() => {
            invalidateSignedMediaUrl(mediaId);
            setRetry((v) => v + 1);
          }}
        >
          视频加载失败，点击重试
        </button>
      </span>
    );
  }

  if (!src) {
    return (
      <span
        className={`skeleton ${className ?? ""}`}
        style={{ display: "block", width: "100%", height: "100%" }}
        role="status"
        aria-label="视频加载中"
      />
    );
  }

  return (
    <video
      key={src}
      src={`${src}#t=0.1`}
      className={className}
      muted={!controls}
      playsInline
      preload="metadata"
      controls={controls}
      aria-label={ariaLabel}
    />
  );
}
