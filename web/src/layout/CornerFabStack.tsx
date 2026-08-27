/**
 * CornerFabStack —— 右下角浮层按钮组（方案 §3.4）。
 *
 * 垂直堆叠（自下而上，用户 2026-08-26 拍板）：CreateFAB（56px，已有，独立挂载于
 * AppShell）→ RefreshFab（44px ⟳）→ ScrollTopFab（44px ↑）。本组件只承载 CreateFAB
 * 之上的两个次级玻璃圆钮，用 .corner-fab-stack 固定容器（gap 12px，bottom 避让
 * CreateFAB，水平居中对齐 CreateFAB）垂直堆叠。
 * flex column 从上到下排列，故 JSX 顺序：ScrollTopFab（上）→ RefreshFab（下）。
 */
import { RefreshFab } from "./RefreshFab";
import { ScrollTopFab } from "./ScrollTopFab";

export function CornerFabStack({
  refresh,
  scrollTop,
}: {
  refresh: boolean;
  scrollTop: boolean;
}) {
  return (
    <div className="corner-fab-stack">
      {scrollTop && <ScrollTopFab />}
      {refresh && <RefreshFab />}
    </div>
  );
}
