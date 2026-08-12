/**
 * ElysiaEntry —— 爱莉入口卡（会话列表顶部）。
 *
 * - 视觉：樱粉渐变底 + grape 字 + 爱莉专属光环（辉光归属爱莉身份，design.md §2）；
 * - 点击进入与爱莉 profile user 的私聊会话；
 * - 前端不生成爱莉第一人称内容（AGENTS.md §4.1）；display_name 仅 UI 展示。
 */
import type { ElysiaProfile } from "../../api/types";
import { Avatar } from "../Avatar";

export function ElysiaEntry({
  profile,
  onEnter,
}: {
  profile: ElysiaProfile;
  onEnter: () => void;
}) {
  const name = profile.display_name || "爱莉";
  return (
    <button type="button" className="elysia-entry" onClick={onEnter}>
      <Avatar label={name} size={40} online={profile.enabled} isElysia />
      <span className="elysia-entry-info">
        <span className="elysia-entry-name">{name}</span>
        <span className="elysia-entry-sub">{profile.enabled ? "在线 · 与她聊天" : "已停用"}</span>
      </span>
      <span className="elysia-entry-arrow" aria-hidden="true">
        ›
      </span>
    </button>
  );
}
