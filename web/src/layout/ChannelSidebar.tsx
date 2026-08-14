/**
 * ChannelSidebar —— 宽屏频道侧栏（design.md §12.4，布局文档 §3.2）。
 *
 * 240–280px 玻璃：群名头（点击进群信息 R-G9 入口）+ 五场景项
 * （聊天/语音/直播/帖子/桌游，选中 rgba(157,191,230,0.35) 胶囊底）+ 返回主页（无，宽屏本就在主页）。
 * 状态标识（语音在麦人数/直播 LIVE/帖子未读）随 F4/F5/F6 接入，F3 不渲染。
 */
import { Link } from "react-router-dom";
import { IconChat, IconGame, IconMic, IconPost, IconVideo } from "../components/icons";
import type { GroupScene } from "../stores/group";

const SCENE_META: Array<{ key: GroupScene; label: string; icon: typeof IconMic }> = [
  { key: "chat", label: "聊天", icon: IconChat },
  { key: "voice", label: "语音", icon: IconMic },
  { key: "live", label: "直播", icon: IconVideo },
  { key: "posts", label: "帖子", icon: IconPost },
  { key: "games", label: "桌游", icon: IconGame },
];

export function ChannelSidebar({
  group,
  groupName,
  activeScene,
  onSelectScene,
  onOpenInfo,
}: {
  group: { id: string };
  groupName: string;
  activeScene: GroupScene;
  onSelectScene: (scene: GroupScene) => void;
  onOpenInfo: () => void;
}) {
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
              </button>
            </li>
          );
        })}
      </ul>
      {/* 群信息入口固定于底部（等价窄屏群头像进入群信息的语义） */}
      <Link className="channel-sidebar-info" to={`/group/${group.id}/info`}>
        <span>群信息</span>
      </Link>
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
