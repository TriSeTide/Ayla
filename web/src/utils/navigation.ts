/**
 * 全局导航单例（供无 Router 上下文的子组件跳转使用）。
 *
 * 背景：VoiceMemberRow / PrivateChatPane / MessageList 等组件可能在测试中
 * 被无 <Router> 包裹直接渲染，直接用 useNavigate() 会在渲染期抛
 * "useNavigate() may be used only in the context of a <Router>"。
 *
 * 方案：组件不在渲染期调用 hook，改为点击时调用本模块的 navigateTo；
 * 由 App 顶层（Router 内）通过 <NavigateBridge/> 注册真正的 navigate 函数。
 * 测试环境未注册时 navigateTo 静默 no-op，不抛错。
 */
import type { NavigateFunction } from "react-router-dom";

let navigateFn: NavigateFunction | null = null;

export function registerNavigate(fn: NavigateFunction): void {
  navigateFn = fn;
}

export function navigateTo(path: string): void {
  navigateFn?.(path);
}

/** 头像点击跳个人主页：自己 → /profile；他人 → /user/:id */
export function goUserProfile(
  currentUserId: string | null | undefined,
  targetUserId: string | null | undefined,
): void {
  if (!targetUserId) return;
  if (currentUserId && String(currentUserId) === String(targetUserId)) {
    navigateTo("/profile");
  } else {
    navigateTo(`/user/${encodeURIComponent(targetUserId)}`);
  }
}