/**
 * DanmakuList —— 弹幕列表（M5-4，文档 §4.4）。
 *
 * 实时 + 历史合并渲染（store 保证按 id 去重、升序、定长）；
 * 纯文本原样渲染（React 默认转义，禁止 dangerouslySetInnerHTML）；
 * 用户上翻时新弹幕不强制滚动，显示"有新弹幕"浮动提示，点击跳底；
 * 图片弹幕：ResourceImage 签名加载（不破图），点击打开 ImageViewer 放大
 * （与聊天界面一致）；图片固定 96×64 尺寸，加载前后高度一致，不撑高列表
 * 导致滚动条错位。
 * 发送者头像光环：懒加载发送者资料（缓存），presence store 实时判定在线
 * （隐身用户强制离线，不泄漏光环）。
 */
import { useEffect, useState } from "react";
import type { DanmakuItem, MediaDescriptor, UserPublic } from "../../api/types";
import { ensureUser, getCachedUser } from "../../api/users";
import { mediaContentUrl, resolveMediaPath } from "../../api/media";
import { usePresenceStore } from "../../stores/presence";
import { presenceOnline, withLiveStatus } from "../../utils/displayStatus";
import { Avatar } from "../Avatar";
import { ResourceImage } from "../ResourceImage";
import { ImageViewer } from "../chat/ImageViewer";
import { goUserProfile } from "../../utils/navigation";

function DanmakuItem({
  item,
  onOpenImage,
}: {
  item: DanmakuItem;
  onOpenImage: (media: MediaDescriptor, alt: string) => void;
}) {
  const [senderUser, setSenderUser] = useState<UserPublic | null>(() =>
    item.sender.user_id ? getCachedUser(item.sender.user_id) : null,
  );
  useEffect(() => {
    if (!item.sender.user_id || senderUser) return;
    let cancelled = false;
    void ensureUser(item.sender.user_id).then((u) => {
      if (!cancelled && u) setSenderUser(u);
    });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [item.sender.user_id]);
  const onlineUsers = usePresenceStore((s) => s.users);
  const onlineStatuses = usePresenceStore((s) => s.statuses);
  const senderOnline = presenceOnline(onlineUsers, withLiveStatus(onlineStatuses, senderUser));

  return (
    <div className="danmaku-item">
      <Avatar
        label={item.sender.nickname}
        size={20}
        online={senderOnline}
        imageUrl={item.sender.avatar || null}
        onClick={() => goUserProfile(null, item.sender.user_id)}
        ariaLabel={`查看 ${item.sender.nickname} 的个人主页`}
      />
      <span className="danmaku-sender">{item.sender.nickname}：</span>
      <span className="danmaku-content">
        {item.media_id && item.media ? (
          <button
            type="button"
            className="danmaku-image-open"
            onClick={() =>
              onOpenImage(item.media as MediaDescriptor, item.content || "弹幕图片")
            }
            aria-label="查看弹幕图片"
            title="点击查看大图"
          >
            <ResourceImage
              src={resolveMediaPath(item.media.thumbnail) ?? mediaContentUrl(item.media_id)}
              alt={item.content || "弹幕图片"}
              className="danmaku-image"
              loading="lazy"
              fallback={<span className="skeleton danmaku-image-skeleton" />}
            />
          </button>
        ) : null}
        {item.content && item.content !== "图片" ? item.content : null}
      </span>
    </div>
  );
}

export function DanmakuList({
  danmaku,
  listRef,
  hasNewBelow,
  onScrollToBottom,
  onUserScroll,
}: {
  danmaku: DanmakuItem[];
  listRef: React.MutableRefObject<HTMLDivElement | null>;
  hasNewBelow: boolean;
  onScrollToBottom: () => void;
  /** 列表滚动上报（useDanmaku.handleListScroll）：stick 底部跟随/新弹幕提示的判定源 */
  onUserScroll?: () => void;
}) {
  const [viewer, setViewer] = useState<{ media: MediaDescriptor; alt: string } | null>(null);

  return (
    <div className="danmaku-wrap">
      <div className="danmaku-list" ref={listRef} onScroll={onUserScroll}>
        {danmaku.length === 0 ? (
          <div className="danmaku-empty">还没有弹幕，来说点什么吧</div>
        ) : (
          danmaku.map((item) => (
            <DanmakuItem
              key={item.id}
              item={item}
              onOpenImage={(media, alt) => setViewer({ media, alt })}
            />
          ))
        )}
      </div>
      {hasNewBelow && (
        <button
          type="button"
          className="danmaku-new-hint"
          onClick={onScrollToBottom}
        >
          有新弹幕 ↓
        </button>
      )}
      {viewer && (
        <ImageViewer
          media={viewer.media}
          alt={viewer.alt}
          onClose={() => setViewer(null)}
        />
      )}
    </div>
  );
}
