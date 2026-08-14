/**
 * useMediaQuery —— 响应式断点 hook（matchMedia 订阅，change 时触发重渲染）。
 *
 * AppShell 用它在两种形态间二选一渲染（开发文档 §2.3）：
 *   useMediaQuery(NARROW_QUERY) → 窄屏 BottomTabs 系 / 宽屏 TopNav 系。
 * 断点体系沿用 design.md §9（480 / 768 / 1024 / 1440），形态分界线 = 768px。
 *
 * 环境无 matchMedia（如 jsdom 未 mock）时返回 false（视为宽屏），不抛错。
 */
import { useCallback, useSyncExternalStore } from "react";

/** 形态分界：≤768px 窄屏（design.md §9） */
export const NARROW_QUERY = "(max-width: 768px)";

export function useMediaQuery(query: string): boolean {
  const subscribe = useCallback(
    (onChange: () => void) => {
      if (typeof window.matchMedia !== "function") return () => {};
      const mql = window.matchMedia(query);
      mql.addEventListener("change", onChange);
      return () => mql.removeEventListener("change", onChange);
    },
    [query],
  );

  const getSnapshot = useCallback(
    () =>
      typeof window.matchMedia === "function" ? window.matchMedia(query).matches : false,
    [query],
  );

  return useSyncExternalStore(subscribe, getSnapshot);
}
