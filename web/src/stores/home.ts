/**
 * home 全局状态（F2）：主页布局偏好（卡片/列表，localStorage 持久化）。
 *
 * - layout: "card" | "list"，需求 R-H4「选择持久化」；
 * - 最近访问群（宽屏 /home 重定向用，定稿决策）：recent_group_id 存 localStorage
 *   （无历史取第一个群；F2 只落地偏好 + 最近群存储，重定向逻辑在 HomePage）。
 *
 * 布局偏好影响窄屏主页；宽屏主页 = 三列群聊界面（无卡片/列表网格）。
 */
import { create } from "zustand";

const LAYOUT_KEY = "ayla.home.layout";
const RECENT_GROUP_KEY = "ayla.home.recent_group";

export type HomeLayout = "card" | "list";

function readLayout(): HomeLayout {
  try {
    const v = localStorage.getItem(LAYOUT_KEY);
    return v === "list" ? "list" : "card";
  } catch {
    return "card";
  }
}

function writeLayout(v: HomeLayout) {
  try {
    localStorage.setItem(LAYOUT_KEY, v);
  } catch {
    // 存储不可用时忽略（如隐私模式）
  }
}

function readRecentGroup(): string | null {
  try {
    return localStorage.getItem(RECENT_GROUP_KEY);
  } catch {
    return null;
  }
}

function writeRecentGroup(id: string | null) {
  try {
    if (id) localStorage.setItem(RECENT_GROUP_KEY, id);
    else localStorage.removeItem(RECENT_GROUP_KEY);
  } catch {
    // 忽略
  }
}

interface HomeState {
  layout: HomeLayout;
  recentGroupId: string | null;

  setLayout: (layout: HomeLayout) => void;
  /** 记录最近访问群（进入 /group/:id 时调用；宽屏 /home 重定向据此定位） */
  setRecentGroup: (id: string | null) => void;
}

export const useHomeStore = create<HomeState>((set) => ({
  layout: readLayout(),
  recentGroupId: readRecentGroup(),

  setLayout: (layout) => {
    writeLayout(layout);
    set({ layout });
  },

  setRecentGroup: (id) => {
    writeRecentGroup(id);
    set({ recentGroupId: id });
  },
}));
