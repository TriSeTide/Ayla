/**
 * shell 全局状态（F4）：壳层 chrome 的跨路由动画状态 + 全局覆盖层开关。
 *
 * bottomTabsLeaving：窄屏直播间进房动画——底栏下滑走（translateY 0→100%，
 * 200ms ease-in，R-L2/§2.5 方向纪律，与进群动画"上移"相反）。
 * 由 LiveRoomPage 进房置 true、退房复位；AppShell 读它驱动 BottomTabs transform。
 *
 * quickMessagesOpen：红点快捷消息栏（QuickMessagesSheet）开关。存 store 而非
 * QuickMessageFab 内部的原因（R-QM bug 修复）：快捷栏打开后若红点归零（打开会话
 * 标已读 → messageBadge=0），QuickMessageFab 会因 `messageBadge>0` 被卸载，若 open
 * 状态在其内部则快捷栏被连带关闭。提升到 store 后，快捷栏由 AppShell 独立渲染、
 * 只随手动关闭（遮罩/ESC/关闭钮）卸载，不受红点消失影响。
 */
import { create } from "zustand";

interface ShellState {
  bottomTabsLeaving: boolean;
  setBottomTabsLeaving: (leaving: boolean) => void;
  quickMessagesOpen: boolean;
  setQuickMessagesOpen: (open: boolean) => void;
}

export const useShellStore = create<ShellState>((set) => ({
  bottomTabsLeaving: false,
  setBottomTabsLeaving: (bottomTabsLeaving) => set({ bottomTabsLeaving }),
  quickMessagesOpen: false,
  setQuickMessagesOpen: (quickMessagesOpen) => set({ quickMessagesOpen }),
}));
