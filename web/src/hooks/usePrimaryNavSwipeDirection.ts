/**
 * usePrimaryNavSwipeDirection —— 窄屏一级五页横滑方向计算（方案 §3.1）。
 *
 * direction 由切换前后一级路由在 tab 顺序（语音 → 直播 → 主页 → 帖子 → 桌游，
 * 即 shellConfig.PRIMARY_TAB_PATHS）的索引差计算：
 * - 1：新 tab 索引更大（左滑切下一个），新页从右滑入、旧页向左滑出；
 * - -1：新 tab 索引更小（右滑切上一个），新页从左滑入、旧页向右滑出；
 * - 0：非一级页之间切换（或同页），无横向位移，走普通淡入淡出。
 *
 * 抽成纯函数 primaryTabDirection（可单测）+ hook 绑定（跟踪 pathname 变化给出
 * 本次切换的方向），供 AppShell 的 AnimatePresence `custom` 使用。与群内
 * useSceneSwipeDirection（方案 §2.2）同构。
 */
import { useRef } from "react";
import { PRIMARY_TAB_PATHS } from "../layout/shellConfig";

/** pathname 在一级 tab 顺序里的索引；/home 是 /group 的兼容别名，归主页索引；非一级页返回 -1。 */
export function primaryTabIndex(pathname: string): number {
  if (pathname === "/home") return PRIMARY_TAB_PATHS.indexOf("/group");
  return PRIMARY_TAB_PATHS.indexOf(pathname);
}

/** 是否一级 tab 路由（精确匹配；/home 兼容别名视为主页）。 */
export function isPrimaryTabPath(pathname: string): boolean {
  return pathname === "/home" || PRIMARY_TAB_PATHS.includes(pathname);
}

/** 由 from→to 的索引差求切换方向；任一端非一级页时返回 0（无横向位移）。 */
export function primaryTabDirection(from: string, to: string): 1 | -1 | 0 {
  const fi = primaryTabIndex(from);
  const ti = primaryTabIndex(to);
  if (fi < 0 || ti < 0) return 0;
  const diff = ti - fi;
  return diff > 0 ? 1 : diff < 0 ? -1 : 0;
}

/**
 * 跟踪 pathname 变化，返回"本次切换"的 direction。
 * 挂载首帧（无切换）返回 0；render 阶段更新 ref 是惯用做法（不触发 setState），
 * StrictMode 双跑第二次 prev 已等于 pathname，direction 不变（与 useSceneSwipeDirection 同）。
 */
export function usePrimaryNavSwipeDirection(pathname: string): 1 | -1 | 0 {
  const prevRef = useRef(pathname);
  const directionRef = useRef<1 | -1 | 0>(0);
  if (prevRef.current !== pathname) {
    directionRef.current = primaryTabDirection(prevRef.current, pathname);
    prevRef.current = pathname;
  }
  return directionRef.current;
}
