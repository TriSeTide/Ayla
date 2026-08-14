/**
 * group 全局状态（F3）：群聊场景的单一导航状态源。
 *
 * - activeScene：当前群内子场景（chat/live/voice/posts/games/info）；
 *   群头像两级点击（R-G4）与输入框显隐（R-G5）都读这一份状态，禁止第二份导航状态。
 * - currentGroupId：当前所在群（ServerRail 高亮 / 场景内容数据归属）。
 *
 * 与 URL 的关系：路由 /group/:id[:/scene] 是场景的可分享表现；
 * GroupPage 在 route param 变化时同步 activeScene（单一 effect），切换场景走
 * setActiveScene + navigate（store 是交互事实源，URL 是回显）。
 */
import { create } from "zustand";

export type GroupScene = "chat" | "live" | "voice" | "posts" | "games" | "info";

/** 窄屏五子界面横向顺序：语音 | 直播 | 聊天 | 帖子 | 桌游（聊天居中默认，R-G3） */
export const GROUP_SCENE_ORDER: GroupScene[] = ["voice", "live", "chat", "posts", "games"];

interface GroupState {
  activeScene: GroupScene;
  currentGroupId: string | null;

  setActiveScene: (scene: GroupScene) => void;
  setCurrentGroup: (groupId: string | null) => void;
  reset: () => void;
}

export const useGroupStore = create<GroupState>((set) => ({
  activeScene: "chat",
  currentGroupId: null,

  setActiveScene: (activeScene) => set({ activeScene }),
  setCurrentGroup: (currentGroupId) => set({ currentGroupId }),
  reset: () => set({ activeScene: "chat", currentGroupId: null }),
}));
