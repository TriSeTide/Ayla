/**
 * HomePage 测试（F2）：
 * - 窄屏：空态引导 / 卡片网格 / 列表切换 / 失败重试；
 * - 宽屏：重定向最近群（无历史第一个群）/ 无群空态引导 + 创建对话框弹出。
 */
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { AnimatePresence } from "framer-motion";
import { Link, MemoryRouter, Route, Routes, useLocation, useOutlet } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as chatApi from "../api/chat";
import type { ConversationSummary } from "../api/types";
import { HomePage } from "../pages/HomePage";
import { PageTransition } from "../components/motion/PageTransition";
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
    avatar: "",
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
  it("自动进入最近群后的旧 Home 在退出期间不能把新导航拉回群聊", async () => {
    mockMatchMedia(false);
    let resolveList!: (list: ConversationSummary[]) => void;
    vi.mocked(chatApi.listConversations).mockReturnValue(new Promise((resolve) => { resolveList = resolve; }));
    function Shell() {
      const { pathname } = useLocation();
      const outlet = useOutlet();
      return <><Link to="/profile">打开个人页</Link><output>{pathname}</output><AnimatePresence mode="sync"><PageTransition key={pathname} pathname={pathname}>{outlet}</PageTransition></AnimatePresence></>;
    }
    const { container } = render(<MemoryRouter initialEntries={["/home"]}><Routes><Route element={<Shell />}><Route path="/home" element={<HomePage />} /><Route path="/group/:id" element={<div>群聊场景</div>} /><Route path="/profile" element={<div>个人页内容</div>} /></Route></Routes></MemoryRouter>);
    // 让 Home 真实呈现一帧后再收到数据；opacity 已经为 0 的页面会立即完成淡出，
    // 那种 fixture 没有需要验证的退出窗口。
    await waitFor(() => expect(container.querySelector<HTMLElement>(".page-transition")!.style.opacity).toBe("1"));
    await act(async () => resolveList([groupConv("1", "测试群")]));
    await screen.findByText("群聊场景");
    expect(container.querySelectorAll(".page-transition").length).toBeGreaterThan(1);
    fireEvent.click(screen.getByRole("link", { name: "打开个人页" }));
    expect(screen.getByRole("status")).toHaveTextContent("/profile");
    await waitFor(() => expect(container.querySelectorAll(".page-transition")).toHaveLength(1));
    expect(screen.getByRole("status")).toHaveTextContent("/profile");
    expect(screen.getByText("个人页内容")).toBeInTheDocument();
  });
  it("会话请求未完成时显示骨架，确认空列表后才展示无群引导", async () => {
    mockMatchMedia(false);
    let resolveList!: (list: ConversationSummary[]) => void;
    vi.mocked(chatApi.listConversations).mockReturnValue(new Promise((resolve) => { resolveList = resolve; }));
    renderHome("/home");

    expect(screen.getByRole("status", { name: "正在加载群聊" }).querySelector(".skeleton")).not.toBeNull();
    expect(screen.queryByText("还没有加入群聊")).not.toBeInTheDocument();
    expect(screen.queryByText("群聊场景")).not.toBeInTheDocument();
    await act(async () => resolveList([]));
    expect(screen.queryByRole("status", { name: "正在加载群聊" })).not.toBeInTheDocument();
    expect(screen.getByText("还没有加入群聊")).toBeInTheDocument();
  });

  it("骨架等待结束拿到群后仍自动进入群聊", async () => {
    mockMatchMedia(false);
    let resolveList!: (list: ConversationSummary[]) => void;
    vi.mocked(chatApi.listConversations).mockReturnValue(new Promise((resolve) => { resolveList = resolve; }));
    renderHome("/home");

    expect(screen.getByRole("status", { name: "正在加载群聊" })).toBeInTheDocument();
    await act(async () => resolveList([groupConv("1", "测试群")]));
    expect(screen.getByText("群聊场景")).toBeInTheDocument();
    expect(screen.queryByText("还没有加入群聊")).not.toBeInTheDocument();
  });

  it("加载或重试失败显示错误并结束骨架，不冒充没有群", async () => {
    mockMatchMedia(false);
    vi.mocked(chatApi.listConversations).mockRejectedValueOnce(new Error("网络错误"));
    renderHome("/home");
    expect(await screen.findByRole("alert")).toHaveTextContent("网络错误");
    expect(screen.queryByText("还没有加入群聊")).not.toBeInTheDocument();

    let rejectList!: (reason: Error) => void;
    vi.mocked(chatApi.listConversations).mockReturnValue(new Promise((_resolve, reject) => { rejectList = reject; }));
    fireEvent.click(screen.getByRole("button", { name: "重试" }));
    expect(screen.getByRole("status", { name: "正在加载群聊" })).toBeInTheDocument();
    await act(async () => rejectList(new Error("再次失败")));
    expect(screen.getByRole("alert")).toHaveTextContent("再次失败");
    expect(useChatStore.getState().loading).toBe(false);
    expect(screen.queryByRole("status", { name: "正在加载群聊" })).not.toBeInTheDocument();
  });

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

  it("无群 → 点击「创建你的第一个群」弹出创建对话框，可关闭", async () => {
    mockMatchMedia(false);
    vi.mocked(chatApi.listConversations).mockResolvedValue([]);
    renderHome("/home");
    await waitFor(() => expect(screen.getByText("还没有加入群聊")).toBeInTheDocument());
    fireEvent.click(screen.getByRole("button", { name: "创建你的第一个群" }));
    expect(screen.getByRole("dialog", { name: "创建群聊" })).toBeInTheDocument();
    // 关闭对话框 → 回到空态
    fireEvent.click(screen.getByRole("button", { name: "关闭" }));
    expect(screen.queryByRole("dialog", { name: "创建群聊" })).not.toBeInTheDocument();
  });
});
