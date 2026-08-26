/**
 * DanmakuList —— 弹幕列表（M5-4，文档 §4.4）。
 *
 * 实时 + 历史合并渲染（store 保证按 id 去重、升序、定长）；
 * 纯文本原样渲染（React 默认转义，禁止 dangerouslySetInnerHTML）；
 * 用户上翻时新弹幕不强制滚动，显示"有新弹幕"浮动提示，点击跳底。
 */
import type { DanmakuItem } from "../../api/types";
import { mediaContentUrl, resolveMediaPath } from "../../api/media";
import { Avatar } from "../Avatar";
import { ResourceImage } from "../ResourceImage";
import { goUserProfile } from "../../utils/navigation";

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
  return (
    <div className="danmaku-wrap">
      <div className="danmaku-list" ref={listRef} onScroll={onUserScroll}>
        {danmaku.length === 0 ? (
          <div className="danmaku-empty">还没有弹幕，来说点什么吧</div>
        ) : (
          danmaku.map((item) => (
            <div key={item.id} className="danmaku-item">
              <Avatar
                label={item.sender.nickname}
                size={20}
                imageUrl={item.sender.avatar || null}
                onClick={() => goUserProfile(null, item.sender.user_id)}
                ariaLabel={`查看 ${item.sender.nickname} 的个人主页`}
              />
              <span className="danmaku-sender">{item.sender.nickname}：</span>
              <span className="danmaku-content">
                {item.media_id && item.media ? (
                  <ResourceImage
                    src={resolveMediaPath(item.media.thumbnail) ?? mediaContentUrl(item.media_id)}
                    alt={item.content || "弹幕图片"}
                    className="danmaku-image"
                    loading="lazy"
                    fallback={<span className="skeleton" style={{ width: 96, height: 64, borderRadius: 8 }} />}
                  />
                ) : null}
                {item.content && item.content !== "图片" ? item.content : null}
              </span>
            </div>
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
    </div>
  );
}
