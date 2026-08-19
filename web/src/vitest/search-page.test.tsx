/**
 * SearchPage 测试（F9 + 顶栏复用）：
 * - 窄屏渲染搜索输入态顶栏（左返回 + 搜索框自动聚焦），无独立 search-input-wrap；
 * - 顶栏输入词回车 → URL ?q= 驱动搜索 → 结果分组显示；
 * - URL ?q= 直接进入自动搜索；
 * - 历史 chips 点击 → URL 更新；
 * - 宽屏不渲染 NarrowTopBar（由 AppShell TopNav 承载搜索框）。
 */
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { search } from "../api/search";
import { applyToGroup } from "../api/chat";
import type { SearchResults } from "../api/types";
import { SearchPage } from "../pages/SearchPage";
import { useAuthStore } from "../stores/auth";
import { useSearchStore } from "../stores/search";

vi.mock("../api/search", () => ({ search: vi.fn() }));
vi.mock("../api/chat", () => ({ applyToGroup: vi.fn() }));

const NARROW = "(max-width: 768px)";

function mockMatchMedia(narrow: boolean) {
  let matches = narrow;
  const listeners = new Set<(e: { matches: boolean }) => void>();
  const mql = {
    get matches() {
      return matches;
    },
    media: NARROW,
    onchange: null,
    addEventListener: (_t: string, cb: (e: { matches: boolean }) => void) => listeners.add(cb),
    removeEventListener: (_t: string, cb: (e: { matches: boolean }) => void) => listeners.delete(cb),
  };
  vi.stubGlobal("matchMedia", vi.fn(() => mql));
}

const currentUser = {
  id: "u1",
  username: "alice",
  nickname: "爱丽丝",
  avatar: "",
  signature: "",
  status: "online",
  online: true,
  date_joined: "2026-01-01T00:00:00Z",
};

function resultFor(q: string): SearchResults {
  void q;
  return {
    users: { total: 1, items: [{ id: "u2", username: "bob", nickname: "小樱", avatar: "", signature: "", status: "offline", online: false, date_joined: "2026-01-01T00:00:00Z" }] },
    groups: { total: 1, items: [{ id: "g1", type: "group", title: "冰樱研究所", join_policy: "application", created_at: "2026-01-01T00:00:00Z" }] },
    posts: { total: 0, items: [] },
    lives: { total: 0, items: [] },
    games: { total: 0, items: [] },
  };
}

/** 只含一个群的搜索结果；joinPolicy 缺省=旧数据（无 join_policy 字段） */
function groupResult(joinPolicy?: "public" | "application"): SearchResults {
  return {
    users: { total: 0, items: [] },
    groups: {
      total: 1,
      items: [
        {
          id: "g1",
          type: "group",
          title: "冰樱研究所",
          ...(joinPolicy ? { join_policy: joinPolicy } : {}),
          created_at: "2026-01-01T00:00:00Z",
        },
      ],
    },
    posts: { total: 0, items: [] },
    lives: { total: 0, items: [] },
    games: { total: 0, items: [] },
  };
}

function renderSearch(initialEntry: string, narrow: boolean) {
  mockMatchMedia(narrow);
  return render(
    <MemoryRouter initialEntries={[initialEntry]}>
      <Routes>
        <Route path="/search" element={<SearchPage />} />
        <Route path="/group/:id" element={<div>群聊</div>} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  vi.mocked(search).mockResolvedValue(resultFor("冰樱"));
  vi.mocked(applyToGroup).mockResolvedValue({} as never);
  useAuthStore.setState({ currentUser });
  useSearchStore.setState({ history: [] });
  localStorage.clear();
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("SearchPage 顶栏复用（F9）", () => {
  it("窄屏渲染搜索输入态顶栏：左返回 + 搜索框自动聚焦，无独立 search-input-wrap", () => {
    renderSearch("/search", true);
    // 顶栏搜索输入框（自动聚焦）
    const input = screen.getByRole("textbox", { name: "全局搜索" }) as HTMLInputElement;
    expect(input).toBeInTheDocument();
    expect(document.activeElement).toBe(input);
    // 左返回
    expect(screen.getByRole("button", { name: "返回" })).toBeInTheDocument();
    // 不再有独立搜索框
    expect(document.querySelector(".search-input-wrap")).toBeNull();
  });

  it("宽屏不渲染 NarrowTopBar（搜索框由 AppShell TopNav 承载）", () => {
    renderSearch("/search", false);
    expect(screen.queryByRole("textbox", { name: "全局搜索" })).toBeNull();
    expect(screen.queryByRole("button", { name: "返回" })).toBeNull();
  });

  it("顶栏输入词回车 → URL ?q= 驱动搜索 → 显示结果分组", async () => {
    renderSearch("/search", true);
    const input = screen.getByRole("textbox", { name: "全局搜索" });
    fireEvent.change(input, { target: { value: "冰樱" } });
    fireEvent.submit(input.closest("form")!);
    await waitFor(() => {
      expect(screen.getByText("小樱")).toBeInTheDocument();
    });
    expect(search).toHaveBeenCalledWith(expect.objectContaining({ q: "冰樱" }));
  });

  it("URL ?q= 直接进入 → 自动搜索并显示结果", async () => {
    renderSearch("/search?q=冰樱", true);
    await waitFor(() => {
      expect(screen.getByText("小樱")).toBeInTheDocument();
    });
    expect(search).toHaveBeenCalledWith(expect.objectContaining({ q: "冰樱" }));
  });

  it("历史 chips 点击 → 更新 URL q 并触发搜索", async () => {
    useSearchStore.setState({ history: ["冰樱", "爱莉"] });
    renderSearch("/search", true);
    fireEvent.click(screen.getByRole("button", { name: "冰樱" }));
    await waitFor(() => {
      expect(screen.getByText("小樱")).toBeInTheDocument();
    });
    expect(search).toHaveBeenCalledWith(expect.objectContaining({ q: "冰樱" }));
  });

  it("有结果后点击「清空」移除历史（无 q 态回到历史空）", async () => {
    useSearchStore.setState({ history: ["冰樱"] });
    renderSearch("/search", true);
    fireEvent.click(screen.getByRole("button", { name: "清空" }));
    expect(useSearchStore.getState().history).toEqual([]);
  });

  it("五类分组全空时显示「未找到」空态（不空白）", async () => {
    vi.mocked(search).mockResolvedValue({
      users: { total: 0, items: [] },
      groups: { total: 0, items: [] },
      posts: { total: 0, items: [] },
      lives: { total: 0, items: [] },
      games: { total: 0, items: [] },
    });
    renderSearch("/search?q=不存在的词", true);
    await waitFor(() => {
      expect(screen.getByText(/未找到/)).toBeInTheDocument();
    });
    expect(screen.getByText(/不存在的词/)).toBeInTheDocument();
  });


  it("点击群搜索结果打开申请弹窗（申请制）：显示申请制说明，发送留言后显示等待审核", async () => {
    renderSearch("/search?q=冰樱", true);
    await waitFor(() => expect(screen.getByText("冰樱研究所")).toBeInTheDocument());
    fireEvent.click(screen.getByRole("button", { name: /冰樱研究所/ }));
    expect(screen.getByRole("dialog", { name: "申请加入「冰樱研究所」" })).toBeInTheDocument();
    expect(screen.getByText("这是一个申请制群聊，群主或管理员同意后才能入群。")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "发送入群申请" })).toBeInTheDocument();
    fireEvent.change(screen.getByRole("textbox", { name: "给群主留言" }), { target: { value: "想和大家一起交流" } });
    fireEvent.click(screen.getByRole("button", { name: "发送入群申请" }));
    await waitFor(() => expect(screen.getByText("申请已发送")).toBeInTheDocument());
    expect(applyToGroup).toHaveBeenCalledWith("g1", "想和大家一起交流");
  });

  it("公开群（join_policy=public）：显示公开说明与「直接加入」，成功后直接进入群聊", async () => {
    vi.mocked(search).mockResolvedValue(groupResult("public"));
    vi.mocked(applyToGroup).mockResolvedValue({ status: "accepted", conversation_id: "25" } as never);
    renderSearch("/search?q=冰樱", true);
    await waitFor(() => expect(screen.getByText("冰樱研究所")).toBeInTheDocument());
    fireEvent.click(screen.getByRole("button", { name: /冰樱研究所/ }));
    expect(screen.getByRole("dialog", { name: "加入「冰樱研究所」" })).toBeInTheDocument();
    expect(screen.getByText("这是一个公开群聊，点击即可直接加入。")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "直接加入" }));
    await waitFor(() => expect(screen.getByText("群聊")).toBeInTheDocument());
    expect(screen.queryByRole("dialog")).toBeNull();
    expect(screen.queryByText("申请已发送")).not.toBeInTheDocument();
    expect(applyToGroup).toHaveBeenCalledWith("g1", "");
  });

  it("join_policy 缺失（旧数据）时按申请制兜底：申请制文案 + 发送入群申请", async () => {
    vi.mocked(search).mockResolvedValue(groupResult());
    renderSearch("/search?q=冰樱", true);
    await waitFor(() => expect(screen.getByText("冰樱研究所")).toBeInTheDocument());
    fireEvent.click(screen.getByRole("button", { name: /冰樱研究所/ }));
    expect(screen.getByRole("dialog", { name: "申请加入「冰樱研究所」" })).toBeInTheDocument();
    expect(screen.getByText("这是一个申请制群聊，群主或管理员同意后才能入群。")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "发送入群申请" })).toBeInTheDocument();
  });

  it("有部分结果时不显示无结果空态", async () => {
    // 默认 resultFor 只带 users（其余 total=0），不应出现空态
    renderSearch("/search?q=冰樱", true);
    await waitFor(() => {
      expect(screen.getByText("小樱")).toBeInTheDocument();
    });
    expect(screen.queryByText(/未找到/)).not.toBeInTheDocument();
  });
});
