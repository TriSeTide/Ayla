/**
 * ChannelSidebar —— 宽屏频道侧栏（design.md §12.4，布局文档 §3.2）。
 *
 * 240–280px 玻璃：群名头（点击进群信息 R-G9 入口）+ 五场景项
 * （聊天/语音/直播/帖子/桌游，选中 rgba(157,191,230,0.35) 胶囊底）+ 返回主页（无，宽屏本就在主页）。
 * 状态标识（语音在麦人数/直播 LIVE/帖子未读）随 F4/F5/F6 接入，F3 不渲染。
 * 群信息入口仅群名头一处（R-G9），侧栏底部不再放重复入口。
 */
import { IconChat, IconGame, IconMic, IconPost, IconVideo } from "../components/icons";
import type { GroupScene } from "../stores/group";
import { useGroupStore } from "../stores/group";
import { useVoiceStore } from "../stores/voice";
import { useLiveStore } from "../stores/live";
import { useChatStore } from "../stores/chat";

const SCENE_META: Array<{ key: GroupScene; label: string; icon: typeof IconMic }> = [
  { key: "chat", label: "聊天", icon: IconChat },
  { key: "voice", label: "语音", icon: IconMic },
  { key: "live", label: "直播", icon: IconVideo },
  { key: "posts", label: "帖子", icon: IconPost },
  { key: "games", label: "桌游", icon: IconGame },
];

export function ChannelSidebar({
  groupName,
  activeScene,
  onSelectScene,
  onOpenInfo,
}: {
  groupName: string;
  activeScene: GroupScene;
  onSelectScene: (scene: GroupScene) => void;
  onOpenInfo: () => void;
}) {
  const currentGroupId = useGroupStore((state) => state.currentGroupId);
  const voiceCount = useVoiceStore((state) => state.channels
    .filter((channel) => (channel.allowed_group_ids ?? []).some((id) => String(id) === String(currentGroupId)))
    .reduce((sum, channel) => sum + (channel.member_count || 0), 0));
  const hasLive = useLiveStore((state) => state.channels
    .some((channel) => (channel.allowed_group_ids ?? []).some((id) => String(id) === String(currentGroupId)) && channel.status === "live"));
  // 群内未读帖子数（浏览与已读同源）：>0 时帖子场景项显示红点
  const postUnread = useChatStore((state) => state.conversations
    .find((c) => c.id === currentGroupId)?.post_unread_count ?? 0);

  return (
    <aside className="channel-sidebar" aria-label="群内场景">
      <button type="button" className="channel-sidebar-head" onClick={onOpenInfo}>
        <span className="channel-sidebar-title">{groupName}</span>
        <Chevron />
      </button>
      <ul className="channel-sidebar-list">
        {SCENE_META.map((s) => {
          const Icon = s.icon;
          const active = activeScene === s.key;
          return (
            <li key={s.key}>
              <button
                type="button"
                className={`channel-scene ${active ? "is-active" : ""}`}
                onClick={() => onSelectScene(s.key)}
                aria-current={active ? "true" : undefined}
              >
                <Icon width={20} height={20} />
                <span>{s.label}</span>
                {s.key === "voice" && voiceCount > 0 && <span className="channel-scene-status">{voiceCount}</span>}
                {s.key === "live" && hasLive && <span className="channel-scene-status">LIVE</span>}
                {s.key === "posts" && postUnread > 0 && (
                  <span
                    className="channel-scene-status channel-scene-posts-badge"
                    aria-label={`${postUnread} 条未读帖子`}
                    title="有未读帖子"
                  >
                    {postUnread > 99 ? "99+" : postUnread}
                  </span>
                )}
              </button>
            </li>
          );
        })}
      </ul>
    </aside>
  );
}

function Chevron() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="m9 6 6 6-6 6" />
    </svg>
  );
}
