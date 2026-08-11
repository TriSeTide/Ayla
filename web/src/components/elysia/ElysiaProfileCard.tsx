/**
 * ElysiaProfileCard：爱莉资料卡（M5-6 入口占位，文档 §4.8）。
 *
 * - 会话列表顶部展示"爱莉"入口卡；
 * - 点击进入爱莉会话（= 与爱莉 profile user 的私聊会话，走 /conversations/private/）。
 * - 前端不生成爱莉第一人称内容（AGENTS.md §4.1）；display_name 仅 UI 展示。
 */
import type { ElysiaProfile } from "../../api/types";

export function ElysiaProfileCard({
  profile,
  onEnter,
}: {
  profile: ElysiaProfile;
  onEnter: () => void;
}) {
  return (
    <button className="elysia-card" onClick={onEnter}>
      <span className="elysia-avatar">爱</span>
      <span className="elysia-info">
        <span className="elysia-name">{profile.display_name || "爱莉"}</span>
        <span className="elysia-sub">{profile.enabled ? "在线 · 与爱莉聊天" : "已停用"}</span>
      </span>
      <span className="elysia-arrow">›</span>
    </button>
  );
}
