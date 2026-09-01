/**
 * 在线状态显示规则（任务 06：在线 → 自动）。
 *
 * 两层数据源：
 * - User.status（用户选择的模式：auto/dnd/away/invisible，REST 快照）；
 * - 实时在线（Redis presence：WS presence.update 增量 + REST online 快照）。
 *
 * 显示 = f(status, 实时在线)：auto 跟随实时，dnd/away/invisible 固定文案。
 * 后端 UserPublicSerializer.display_status 是权威快照；本工具用于
 * presence 实时事件到达时合并两层，避免各组件复制规则。
 */
import type { UserPublic } from "../api/types";
import { usePresenceStore } from "../stores/presence";

/** 纯规则函数：给定模式与实时在线布尔，返回对外显示文案。 */
export function displayStatusOf(
  user: Pick<UserPublic, "status"> | null | undefined,
  online: boolean,
): string {
  switch (user?.status) {
    case "dnd":
      return "勿扰";
    case "away":
      return "离开";
    case "invisible":
      return "离线";
    default:
      // auto（及未知旧值兜底）：跟随实时在线
      return online ? "在线" : "离线";
  }
}

/**
 * 实时在线判定（纯函数，供循环内/列表场景直接读 store 映射）：
 * presence store 已知状态优先（WS 增量权威），无记录时回退 REST 快照
 * user.online（登录前就在线的用户、WS 未连接场景）。
 * 隐身用户强制离线：运行中切换隐身不产生 WS 事件，旧「online」记录必须不泄漏。
 */
export function presenceOnline(
  users: Record<string, string>,
  user: Pick<UserPublic, "id" | "status" | "online"> | null | undefined,
): boolean {
  if (user?.status === "invisible") return false;
  const known = user ? users[user.id] : undefined;
  if (known != null) return known === "online";
  return user?.online ?? false;
}

/**
 * 实时在线判定（hook 形式）：订阅 presence store，WS 事件到达时组件自动重渲染。
 */
export function usePresenceOnline(
  user: Pick<UserPublic, "id" | "status" | "online"> | null | undefined,
): boolean {
  const users = usePresenceStore((s) => s.users);
  return presenceOnline(users, user);
}

/** 组合：对外显示文案（实时）。 */
export function useDisplayStatus(
  user: Pick<UserPublic, "id" | "status" | "online"> | null | undefined,
): string {
  return displayStatusOf(user, usePresenceOnline(user));
}
