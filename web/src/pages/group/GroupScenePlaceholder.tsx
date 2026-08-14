/**
 * GroupScenePlaceholder —— 群内子场景占位（live/voice/posts/games，F3）。
 *
 * F3 只落地聊天子界面；直播(F4)/语音(F5)/帖子(F6)/桌游(F7)子界面本体由对应步骤
 * 在 `pages/group/` 下替换本占位。占位明确标注落地步骤，不伪造内容。
 */
import type { GroupScene } from "../../stores/group";

const SCENE_META: Record<string, { title: string; step: string; desc: string }> = {
  live: { title: "群内直播", step: "F4", desc: "直接进入该群直播间，上下滑切换（范围仅该群）" },
  voice: { title: "群内语音", step: "F5", desc: "该群语音房卡片列表，点卡片进房间" },
  posts: { title: "群内帖子", step: "F6", desc: "该群帖子流 + 输入框发帖（区别于一级 tab 的 FAB 发帖）" },
  games: { title: "群内桌游", step: "F7", desc: "该群桌游室卡片列表，点卡片进房间" },
};

export function GroupScenePlaceholder({ scene }: { scene: GroupScene }) {
  const meta = SCENE_META[scene] ?? { title: "子场景", step: "F3", desc: "" };
  return (
    <div className="group-scene-placeholder">
      <h3 className="placeholder-title">{meta.title}</h3>
      <p className="placeholder-desc">{meta.desc}</p>
      <span className="placeholder-step">{meta.step}</span>
    </div>
  );
}
