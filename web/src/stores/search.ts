/**
 * search 全局状态（F9）：搜索历史记录（localStorage 持久化）。
 *
 * history：最近搜索词（去重、栈顶最新、上限 10）；可清空（R-S 搜索页历史 chips）。
 */
import { create } from "zustand";

const HISTORY_KEY = "ayla.search.history";
const MAX_HISTORY = 10;

function readHistory(): string[] {
  try {
    const raw = localStorage.getItem(HISTORY_KEY);
    if (!raw) return [];
    const list = JSON.parse(raw);
    return Array.isArray(list) ? list.filter((x) => typeof x === "string").slice(0, MAX_HISTORY) : [];
  } catch {
    return [];
  }
}

function writeHistory(list: string[]) {
  try {
    localStorage.setItem(HISTORY_KEY, JSON.stringify(list));
  } catch {
    // 存储不可用时忽略
  }
}

interface SearchState {
  history: string[];
  /** 记录一次搜索（去重置顶） */
  pushHistory: (q: string) => void;
  clearHistory: () => void;
}

export const useSearchStore = create<SearchState>((set, get) => ({
  history: readHistory(),

  pushHistory: (q) => {
    const trimmed = q.trim();
    if (!trimmed) return;
    const next = [trimmed, ...get().history.filter((h) => h !== trimmed)].slice(0, MAX_HISTORY);
    writeHistory(next);
    set({ history: next });
  },

  clearHistory: () => {
    writeHistory([]);
    set({ history: [] });
  },
}));
