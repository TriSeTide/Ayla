/**
 * shell 全局状态（F4）：壳层 chrome 的跨路由动画状态。
 *
 * bottomTabsLeaving：窄屏直播间进房动画——底栏下滑走（translateY 0→100%，
 * 200ms ease-in，R-L2/§2.5 方向纪律，与进群动画"上移"相反）。
 * 由 LiveRoomPage 进房置 true、退房复位；AppShell 读它驱动 BottomTabs transform。
 */
import { create } from "zustand";

interface ShellState {
  bottomTabsLeaving: boolean;
  setBottomTabsLeaving: (leaving: boolean) => void;
}

export const useShellStore = create<ShellState>((set) => ({
  bottomTabsLeaving: false,
  setBottomTabsLeaving: (bottomTabsLeaving) => set({ bottomTabsLeaving }),
}));
