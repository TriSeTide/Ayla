/**
 * HomePage 测试（F2）：
 * - 窄屏：空态引导 / 卡片网格 / 列表切换 / 失败重试；
 * - 宽屏：重定向最近群（无历史第一个群）/ 无群空态引导。
 */
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as chatApi from "../api/chat";
import type { ConversationSummary } from "../api/types";
import { HomePage } from "../pages/HomePage";
import { useAuthStore } from "../stores/auth";
import { useChatStore } from "../stores/chat";
import { useHomeStore } from "../stores/home";

vi.mock("../api/chat", () => ({
  listConversations: vi.fn(),
  fetchHighlights: vi.fn(),
}));

function mockMatchMedia(narrow: boolean) {
  let matches = narrow;
  const listeners = new Set<(e: { matches: boolean }) => void>();
  const mql = {
    get matches() {
      return matches;
    },
    addEventListener: (_t: string, cb: (e: { matches: boolean }) => void) => listeners.add(cb),
    removeEventListener: (_t: string, cb: (e: { matches: boolean }) => void) => listeners.delete(cb),
  };
  vi.stubGlobal("matchMedia", vi.fn(() => mql));
}

function groupConv(id: string, title: string, unread = 0): ConversationSummary {
  return {
    id,
    type: "group",
    title,
    announcement: "",
    owner_id: "o1",
    members: [],
    my_role: "member",
    member_count: 3,
    unread_count: unread,
    created_at: "2026-01-01T00:00:00Z",
    peer: null,
  };
}

function renderHome(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="/home" element={<HomePage />} />
        <Route path="/group/:id" element={<div>群聊场景</div>} />
        <Route path="/chat" element={<div>聊天页</div>} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  useAuthStore.setState({
    accessToken: "acc",
    currentUser: {
      id: "u1",
      username: "alice",
      nickname: "爱丽丝",
      avatar: "",
      signature: "",
      status: "online",
      online: true,
      date_joined: new Date().toISOString(),
    },
  });
  useChatStore.setState({ conversations: [], loading: false, error: null });
  useHomeStore.setState({ layout: "card", recentGroupId: null });
  vi.mocked(chatApi.fetchHighlights).mockResolvedValue({});
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.clearAllMocks();
  useChatStore.setState({ conversations: [], loading: false, error: null });
});

describe("HomePage 窄屏", () => {
  it("无群 → 空态引导（创建 + 搜索发现群）", async () => {
    mockMatchMedia(true);
    vi.mocked(chatApi.listConversations).mockResolvedValue([]);
    renderHome("/home");
    await waitFor(() => expect(screen.getByText("创建你的第一个群")).toBeInTheDocument());
    expect(screen.getByRole("button", { name: "创建群聊" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "搜索发现群" })).toBeInTheDocument();
  });

  it("有群 → 卡片网格渲染群名", async () => {
    mockMatchMedia(true);
    vi.mocked(chatApi.listConversations).mockResolvedValue([groupConv("1", "测试群", 2)]);
    renderHome("/home");
    await waitFor(() => expect(screen.getByText("测试群")).toBeInTheDocument());
  });

  it("切换列表布局 → 渲染列表项", async () => {
    mockMatchMedia(true);
    vi.mocked(chatApi.listConversations).mockResolvedValue([groupConv("1", "测试群")]);
    renderHome("/home");
    await waitFor(() => expect(screen.getByText("测试群")).toBeInTheDocument());
    screen.getByRole("button", { name: "列表布局" }).click();
    // 列表项 aria-label
    expect(screen.getByRole("button", { name: "进入群聊 测试群" })).toBeInTheDocument();
    expect(useHomeStore.getState().layout).toBe("list");
  });

  it("列表加载失败 → 失败文案 + 重试", async () => {
    mockMatchMedia(true);
    vi.mocked(chatApi.listConversations).mockRejectedValue(new Error("网络错误"));
    renderHome("/home");
    await waitFor(() => expect(screen.getByRole("alert")).toBeInTheDocument());
    expect(screen.getByRole("button", { name: "重试" })).toBeInTheDocument();
  });
});

describe("HomePage 宽屏重定向", () => {
  it("有群 → 重定向 /group/<第一个群>", async () => {
    mockMatchMedia(false);
    vi.mocked(chatApi.listConversations).mockResolvedValue([groupConv("1", "测试群"), groupConv("2", "另一个")]);
    renderHome("/home");
    await waitFor(() => expect(screen.getByText("群聊场景")).toBeInTheDocument());
  });

  it("有最近访问群 → 重定向该群", async () => {
    mockMatchMedia(false);
    useHomeStore.setState({ recentGroupId: "2" });
    vi.mocked(chatApi.listConversations).mockResolvedValue([groupConv("1", "测试群"), groupConv("2", "另一个")]);
    renderHome("/home");
    await waitFor(() => expect(screen.getByText("群聊场景")).toBeInTheDocument());
  });

  it("无群 → 宽屏空态引导", async () => {
    mockMatchMedia(false);
    vi.mocked(chatApi.listConversations).mockResolvedValue([]);
    renderHome("/home");
    await waitFor(() => expect(screen.getByText("还没有加入群聊")).toBeInTheDocument());
  });
});
