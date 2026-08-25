/**
 * PostVideoCover —— 帖子视频封面块（信息流卡片 + 详情页共用）。
 *
 * 性能契约（秒开）：上传时前端已抽首帧经 POST /media/{id}:poster 回传，
 * 存为 thumbnail 派生（QQ 同款封面）。descriptor.thumbnail 非空时一律渲染
 * 签名缩略图（320px JPEG 直连，<img> 原生加载渐进解码）——封面秒出且零解码
 * 开销，信息流 N 个视频卡从「N 条视频元数据拉流」变成「N 张小图」，不再挂
 * <video> 元素；点击才进查看器真正播放。
 *
 * thumbnail 为 null（存量视频 / 浏览器抽帧失败）降级 SignedVideo 首帧预览，
 * 行为与历史版本一致。
 */
import { useEffect } from "react";
import type { MediaDescriptor } from "../../api/types";
import { warmUpVideoElement } from "../../api/media";
import { ResourceImage } from "../ResourceImage";
import { SignedVideo } from "../SignedVideo";

export function PostVideoCover({
  media,
  className,
  ariaLabel,
  warmUp = false,
}: {
  media: MediaDescriptor;
  className?: string;
  ariaLabel?: string;
  /** 详情页浏览中传 true：挂载即创建 detached <video> 预热缓冲（签 URL +
   *  preload=auto 拉起播段），点击进查看器时直接接管已缓冲元素——点开即播；
   *  信息流卡片保持 false（避免 N 个卡片并发拉视频数据） */
  warmUp?: boolean;
}) {
  useEffect(() => {
    if (!warmUp) return;
    warmUpVideoElement(media.media_id);
  }, [warmUp, media.media_id]);

  if (media.thumbnail) {
    return (
      <ResourceImage
        src={media.thumbnail}
        variant="thumb"
        alt={ariaLabel || "帖子视频封面"}
        className={className}
      />
    );
  }
  return (
    <SignedVideo mediaId={media.media_id} className={className} ariaLabel={ariaLabel} />
  );
}
