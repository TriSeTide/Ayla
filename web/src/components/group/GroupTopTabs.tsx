/**
 * GroupTopTabs —— 窄屏群场景顶部导航条（R-G1：底栏上移到顶部后的形态）。
 *
 * 五槽：语音 | 直播 | 群头像（居中）| 帖子 | 桌游（顺序 R-G3，聊天居中）。
 * - 四 tab 点击 = 切换该群对应子界面（等价左右滑动）；
 * - 群头像点击 = 两级语义（R-G4），由父级 onAvatarClick 分支处理，本组件不判断；
 * - 5 小圆点指示当前子界面（仅非聊天子界面显示，布局文档 §2.3）。
 *
 * enterStyle 由 useEnterGroupAnimation 提供（translateY 上移 + transition）；
 * 下拉回主页（R-G6）手势 handlers 由父级注入，展开到整个导航条区域。
 */
import type { CSSProperties, TouchEvent as ReactTouchEvent } from "react";
import { Avatar } from "../Avatar";
import { IconGame, IconPost, IconVideo, IconMic } from "../icons";
import type { GroupScene } from "../../stores/group";
import { useGroupStore } from "../../stores/group";
import { useChatStore } from "../../stores/chat";

const TABS: Array<{ scene: GroupScene; label: string; icon: typeof IconMic }> = [
  { scene: "voice", label: "语音", icon: IconMic },
  { scene: "live", label: "直播", icon: IconVideo },
  { scene: "posts", label: "帖子", icon: IconPost },
  { scene: "games", label: "桌游", icon: IconGame },
];

export interface PullHandlers {
  onTouchStart: (e: ReactTouchEvent) => void;
  onTouchMove: (e: ReactTouchEvent) => void;
  onTouchEnd: (e: ReactTouchEvent) => void;
  onTouchCancel: () => void;
}

export function GroupTopTabs({
  groupName,
  avatar,
  activeScene,
  onSelectScene,
  onAvatarClick,
  style,
  pullHandlers,
}: {
  groupName: string;
  /** 群头像（媒体 content URL，可选） */
  avatar?: string;
  activeScene: GroupScene;
  onSelectScene: (scene: GroupScene) => void;
  onAvatarClick: () => void;
  /** 进群动画 + 下拉跟手/退场 transform + transition（父级注入） */
  style?: CSSProperties;
  /** 下拉回主页（R-G6）手势 handlers，绑定到整个导航条区域 */
  pullHandlers?: PullHandlers;
}) {
  const showDots = activeScene !== "chat" && activeScene !== "info";
  // 群内未读帖子数（浏览与已读同源）：>0 时帖子 tab 显示红点
  const currentGroupId = useGroupStore((s) => s.currentGroupId);
  const postUnread = useChatStore((s) => s.conversations
    .find((c) => c.id === currentGroupId)?.post_unread_count ?? 0);

  return (
    <div className="group-top-tabs" style={style} {...pullHandlers}>
      <nav className="group-top-nav" aria-label="群内场景">
        <ul className="group-top-list">
          {TABS.slice(0, 2).map((t) => {
            const Icon = t.icon;
            const active = activeScene === t.scene;
            return (
              <li key={t.scene} className="group-top-item">
                <button
                  type="button"
                  className={`group-top-btn ${active ? "is-active" : ""}`}
                  onClick={() => onSelectScene(t.scene)}
                  aria-current={active ? "true" : undefined}
                >
                  <Icon width={22} height={22} />
                  <span>{t.label}</span>
                </button>
              </li>
            );
          })}

          {/* 中央群头像槽位（原"主页"位置形变为群头像，R-G1） */}
          <li className="group-top-item group-top-avatar">
            <button
              type="button"
              className="group-top-avatar-btn"
              onClick={onAvatarClick}
              aria-label={`群头像：${groupName}`}
            >
              <Avatar label={groupName} size={48} online imageUrl={avatar || null} />
            </button>
          </li>

          {TABS.slice(2).map((t) => {
            const Icon = t.icon;
            const active = activeScene === t.scene;
            return (
              <li key={t.scene} className="group-top-item">
                <button
                  type="button"
                  className={`group-top-btn ${active ? "is-active" : ""}`}
                  onClick={() => onSelectScene(t.scene)}
                  aria-current={active ? "true" : undefined}
                >
                  <Icon width={22} height={22} />
                  <span>{t.label}</span>
                  {t.scene === "posts" && postUnread > 0 && (
                    <span
                      className="group-top-dot-badge"
                      aria-label={`${postUnread} 条未读帖子`}
                      title="有未读帖子"
                    />
                  )}
                </button>
              </li>
            );
          })}
        </ul>
      </nav>
      {showDots && (
        <div className="group-top-dots" aria-hidden="true">
          {["voice", "live", "chat", "posts", "games"].map((s) => (
            <span key={s} className={`group-top-dot ${activeScene === s ? "is-active" : ""}`} />
          ))}
        </div>
      )}
    </div>
  );
}
