import { useAuthStore } from "../stores/auth";
import * as chatApi from "../api/chat";
import { disposeSocialTracking, updateSocialItems } from "../stores/social";
/**
 * GroupPage 测试（F3）：
 * - 窄屏默认聊天子界面；群头像两级点击（chat→info，非 chat→chat）；
 * - 宽屏三列（ServerRail + ChannelSidebar + 内容区）切群/切场景。
 * GroupChat / GroupInfo mock 成轻量组件（避免聊天 WS/API 链路），
 * 聚焦容器/导航/两级点击语义。
 */
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { useEffect } from "react";
import { motion, useIsPresent } from "framer-motion";
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ConversationSummary } from "../api/types";
import { GroupPage } from "../pages/GroupPage";
import { PageTransition, resolvePageKey } from "../components/motion/PageTransition";
import { panelVariants } from "../components/motion/auroraquaMotion";
import { useChatStore } from "../stores/chat";
import { useGroupStore } from "../stores/group";
import { disposeDirectoryTracking } from "../stores/directory";

vi.mock("../pages/group/GroupChat", () => ({
  GroupChat: function MockGroupChat({ groupId, panelMotion = false }: { groupId: string; panelMotion?: boolean }) {
    const present = useIsPresent();
    const active = !panelMotion || present;
    useEffect(() => {
      if (!active) return;
      useChatStore.getState().openConversation(groupId);
      return () => {
        if (useChatStore.getState().activeConversationId === groupId) useChatStore.getState().closeConversation();
      };
    }, [groupId, active]);
    return <motion.div data-group-id={groupId} inherit={panelMotion} variants={panelMotion ? panelVariants(false, "right", "left") : undefined}>群聊内容区<input aria-label="群聊草稿" defaultValue="" disabled={!active} /></motion.div>;
  },
}));
vi.mock("../pages/group/GroupInfo", () => ({
  GroupInfo: () => <div>群信息界面</div>,
}));
vi.mock("../pages/group/GroupLive", () => ({
  GroupLive: () => <div>群内直播内容</div>,
}));
vi.mock("../pages/group/GroupVoice", () => ({
  GroupVoice: () => <div>群内语音内容</div>,
}));
vi.mock("../pages/group/GroupGames", () => ({
  GroupGames: () => <div>群内桌游内容</div>,
}));
vi.mock("../pages/group/GroupPosts", () => ({
  GroupPosts: () => <div>群内帖子内容</div>,
}));
vi.mock("../api/chat", () => ({
  listConversationsPage: vi.fn(async (params: { type?: string }) => { const all = await chatApi.listConversations(); const results = all.filter((row) => !params.type || params.type === "all" || row.type === params.type); return { results, total: results.length, has_more: false, next_cursor: null }; }),
  getConversationMetadata: vi.fn((id: string) => chatApi.getConversation(id)),
  getConversationSummary: vi.fn(async (id: string) => ({ ...await chatApi.getConversation(id), peer: null })),
  listSubgroupsPage: vi.fn(async () => ({ results: [], total: 0, has_more: false, next_cursor: null, default: null })),
  getConversation: vi.fn(),
  listConversations: vi.fn(async () => useChatStore.getState().conversations),
  listSubgroups: vi.fn().mockResolvedValue([]),
}));
vi.mock("../api/voice", async () => ({
  ...(await vi.importActual<typeof import("../api/voice")>("../api/voice")),
  listVoiceChannelsPage: vi.fn(async () => ({ results: [], next_cursor: null, has_more: false, total: 0, total_member_count: 0 })),
}));
vi.mock("../api/live", async () => ({
  ...(await vi.importActual<typeof import("../api/live")>("../api/live")),
  listLiveChannelsPage: vi.fn(async () => ({ results: [], next_cursor: null, has_more: false, total: 0 })),
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
  return mql;
}

function groupConv(id: string, title: string): ConversationSummary {
  return {
    id,
    type: "group",
    title,
    announcement: "",
    avatar: "",
    owner_id: "o1",
    members: [],
    my_role: "owner",
    member_count: 3,
    unread_count: 0,
    created_at: "2026-01-01T00:00:00Z",
    peer: null,
  };
}

function WideGroupFrame() {
  const { pathname } = useLocation();
  return <PageTransition key={resolvePageKey(pathname, true)} pathname={pathname} panelOwned><GroupPage /></PageTransition>;
}

function renderGroup(path: string, sharedWideShell = false) {
  updateSocialItems("conversations", { type: "group" }, useChatStore.getState().conversations);
  const page = sharedWideShell ? <WideGroupFrame /> : <GroupPage />;
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="/home" element={<div>主页内容</div>} />
        <Route path="/group" element={<div>主页内容</div>} />
        <Route path="/group/:id" element={page} />
        <Route path="/group/:id/:scene" element={page} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  disposeSocialTracking();
  useAuthStore.setState({ currentUser: { id: "me", username: "me", nickname: "", avatar: "", signature: "", status: "auto", online: false, date_joined: "" }, accessToken: "test" });
  disposeDirectoryTracking();
  useChatStore.setState({
    conversations: [groupConv("1", "测试群"), groupConv("2", "另个群")],
  });
  useGroupStore.getState().reset();
});

afterEach(() => {
  cleanup();
  disposeDirectoryTracking();
  vi.unstubAllGlobals();
  vi.useRealTimers();
  vi.clearAllMocks();
  useChatStore.setState({ conversations: [] });
  useGroupStore.getState().reset();
});

describe("GroupPage 窄屏", () => {
  it("导航条在原底栏位置可见并升至顶部，内容外壳中性且保留独立手势层", async () => {
    vi.stubGlobal("matchMedia", vi.fn((query: string) => ({ matches: query === "(max-width: 768px)", addEventListener: vi.fn(), removeEventListener: vi.fn() })));
    renderGroup("/group/1");
    const tabs = document.querySelector<HTMLElement>(".group-top-tabs")!;
    expect(tabs.style.translate).toBe("0 calc(100dvh - 64px - env(safe-area-inset-bottom, 0px))");
    expect(tabs.style.transform).toBe("translateY(0)");
    expect(tabs.style.opacity).toBe("1");
    expect(tabs.style.transition).toContain("translate 300ms var(--auroraqua-ease-out)");
    expect(document.querySelector<HTMLElement>(".group-scene-enter")!.style.transform).toBe("");
    expect(document.querySelector<HTMLElement>(".group-scene-inner")!.style.transform).not.toContain("translate");
    expect(document.querySelector(".group-scene-drag")).not.toBeNull();
    await waitFor(() => expect(tabs.style.translate).toBe("0 0"));
    expect(tabs.style.opacity).toBe("1");
    expect(document.querySelector(".group-top-tabs")).toBe(tabs);
    fireEvent.click(screen.getByRole("button", { name: "直播" }));
    await waitFor(() => expect(screen.getByText("群内直播内容")).toBeInTheDocument());
    expect(document.querySelector(".group-top-tabs")).toBe(tabs);
    expect(tabs.style.translate).toBe("0 0");
  });

  it("减少动态时导航条首帧直接位于顶部且可见", () => {
    mockMatchMedia(true);
    renderGroup("/group/1");
    const tabs = document.querySelector<HTMLElement>(".group-top-tabs")!;
    expect(tabs.style.translate).toBe("none");
    expect(tabs.style.transform).toBe("translateY(0)");
    expect(tabs.style.opacity).toBe("1");
    expect(tabs.style.transition).toBe("none");
  });
  it("默认 chat 子界面渲染群聊内容区", () => {
    mockMatchMedia(true);
    renderGroup("/group/1");
    expect(screen.getByText("群聊内容区")).toBeInTheDocument();
  });

  it("非 chat 子界面：live/voice/games 渲染对应子界面", () => {
    mockMatchMedia(true);
    useGroupStore.getState().reset();
    const first = renderGroup("/group/1/live");
    expect(screen.getByText("群内直播内容")).toBeInTheDocument();
    first.unmount();

    const second = renderGroup("/group/1/voice");
    expect(screen.getByText("群内语音内容")).toBeInTheDocument();
    second.unmount();

    renderGroup("/group/1/games");
    expect(screen.getByText("群内桌游内容")).toBeInTheDocument();
  });

  it("群头像两级点击：非 chat 场景点群头像 → 回聊天", async () => {
    mockMatchMedia(true);
    renderGroup("/group/1/live");
    screen.getByRole("button", { name: "群头像：测试群" }).click();
    await waitFor(() => expect(screen.getByText("群聊内容区")).toBeInTheDocument());
  });

  it("群头像两级点击：chat 场景点群头像 → 进群信息", async () => {
    mockMatchMedia(true);
    renderGroup("/group/1");
    screen.getByRole("button", { name: "群头像：测试群" }).click();
    await waitFor(() => expect(screen.getByText("群信息界面")).toBeInTheDocument());
  });

  it("下拉顶部导航条超过阈值 → 返回主页（R-G6）", async () => {
    mockMatchMedia(true);
    renderGroup("/group/1");
    const tabs = document.querySelector(".group-top-tabs");
    expect(tabs).not.toBeNull();

    // 模拟下拉：start(100,0) → move(100,90)（dy=90 > 80 阈值）→ end
    fireEvent.touchStart(tabs!, { touches: [{ clientX: 100, clientY: 0 }] });
    fireEvent.touchMove(tabs!, { touches: [{ clientX: 100, clientY: 90 }] });
    fireEvent.touchEnd(tabs!, { changedTouches: [{ clientX: 100, clientY: 90 }] });

    await waitFor(() => expect(screen.getByText("主页内容")).toBeInTheDocument());
  });

  it("下拉未过阈值 → 吸附回原状态，不返回主页", async () => {
    mockMatchMedia(true);
    renderGroup("/group/1");
    const tabs = document.querySelector(".group-top-tabs")!;
    fireEvent.touchStart(tabs, { touches: [{ clientX: 100, clientY: 0 }] });
    fireEvent.touchMove(tabs, { touches: [{ clientX: 100, clientY: 40 }] });
    fireEvent.touchEnd(tabs, { changedTouches: [{ clientX: 100, clientY: 40 }] });

    // 仍停留群聊，未跳主页
    expect(screen.getByText("群聊内容区")).toBeInTheDocument();
    expect(screen.queryByText("主页内容")).not.toBeInTheDocument();
  });

  it("偏好切换取消旧下拉；reduced-motion 下新下拉仍可无位移动画返回主页", () => {
    vi.useFakeTimers();
    let reduced = false;
    const listeners = new Set<() => void>();
    const motionQuery = {
      get matches() { return reduced; },
      addEventListener: (_event: string, listener: () => void) => listeners.add(listener),
      removeEventListener: (_event: string, listener: () => void) => listeners.delete(listener),
    };
    const narrowQuery = { matches: true, addEventListener: vi.fn(), removeEventListener: vi.fn() };
    vi.stubGlobal("matchMedia", vi.fn((query: string) =>
      query.includes("prefers-reduced-motion") ? motionQuery : narrowQuery,
    ));
    renderGroup("/group/1");
    const tabs = document.querySelector(".group-top-tabs")!;
    fireEvent.touchStart(tabs, { touches: [{ clientX: 100, clientY: 0 }] });
    fireEvent.touchMove(tabs, { touches: [{ clientX: 100, clientY: 90 }] });
    act(() => { reduced = true; listeners.forEach((listener) => listener()); });
    fireEvent.touchEnd(tabs, { changedTouches: [{ clientX: 100, clientY: 90 }] });
    act(() => vi.advanceTimersByTime(300));
    expect(screen.getByText("群聊内容区")).toBeInTheDocument();
    expect(screen.queryByText("主页内容")).not.toBeInTheDocument();

    fireEvent.touchStart(tabs, { touches: [{ clientX: 100, clientY: 0 }] });
    fireEvent.touchMove(tabs, { touches: [{ clientX: 100, clientY: 90 }] });
    fireEvent.touchEnd(tabs, { changedTouches: [{ clientX: 100, clientY: 90 }] });
    act(() => vi.advanceTimersByTime(300));
    expect(screen.getByText("主页内容")).toBeInTheDocument();
  });
});

describe("GroupPage 宽屏", () => {
  it("切群保持服务器栏和频道占位，旧面板先退出再挂新群并重置草稿及弹窗", async () => {
    mockMatchMedia(false);
    renderGroup("/group/1", true);
    const rail = screen.getByRole("navigation", { name: "我的群" });
    const sidebar = screen.getByRole("complementary", { name: "群内场景" });
    const sidebarSlot = sidebar.parentElement;
    const firstGroupButton = screen.getByRole("button", { name: "切换到群聊 测试群" });
    const secondGroupButton = screen.getByRole("button", { name: "切换到群聊 另个群" });
    const firstDraft = screen.getByRole("textbox", { name: "群聊草稿" });
    fireEvent.change(firstDraft, { target: { value: "只属于第一个群的草稿" } });
    fireEvent.click(screen.getByRole("button", { name: "编辑" }));
    fireEvent.click(screen.getByRole("button", { name: "添加子群" }));
    expect(screen.getByRole("dialog", { name: "添加子群" })).toBeInTheDocument();
    fireEvent.click(secondGroupButton);
    expect(sidebar).toHaveAttribute("inert");
    expect(firstDraft).toBeDisabled();
    expect(useChatStore.getState().activeConversationId).toBeNull();
    expect(screen.queryByRole("dialog", { name: "添加子群" })).not.toBeInTheDocument();
    await waitFor(() => expect(useGroupStore.getState().currentGroupId).toBe("2"));
    expect(screen.getByRole("navigation", { name: "我的群" })).toBe(rail);
    await waitFor(() => expect(screen.getByRole("complementary", { name: "群内场景" })).toHaveAttribute("data-group-owner", "2"));
    expect(screen.getByRole("complementary", { name: "群内场景" })).not.toBe(sidebar);
    expect(screen.getByRole("complementary", { name: "群内场景" }).parentElement).toBe(sidebarSlot);
    expect(screen.getByRole("button", { name: "切换到群聊 测试群" })).toBe(firstGroupButton);
    expect(screen.getByRole("button", { name: "切换到群聊 另个群" })).toHaveAttribute("aria-current", "true");
    const secondDraft = await screen.findByRole("textbox", { name: "群聊草稿" });
    expect(secondDraft).not.toBe(firstDraft);
    expect(secondDraft).toHaveValue("");
    expect(screen.queryByRole("dialog", { name: "添加子群" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "退出编辑" })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "编辑" })).toBeInTheDocument();
  });

  it("渲染服务器栏 + 频道侧栏 + 内容区", () => {
    mockMatchMedia(false);
    renderGroup("/group/1");
    expect(screen.getByRole("navigation", { name: "我的群" })).toBeInTheDocument();
    expect(screen.getByRole("complementary", { name: "群内场景" })).toBeInTheDocument();
    expect(screen.getByText("群聊内容区")).toBeInTheDocument();
  });

  it("服务器栏显示群头像（含未读）", () => {
    mockMatchMedia(false);
    useChatStore.setState({
      conversations: [
        { ...groupConv("1", "测试群"), unread_count: 3 },
        { ...groupConv("2", "另个群"), unread_count: 5 },
      ],
    });
    renderGroup("/group/1");
    expect(screen.getByRole("button", { name: "切换到群聊 测试群" })).toBeInTheDocument();
    // 进入群 1 仍保持未读状态，由聊天消息区的定位标签承接；另个群未读徽标保留
    const badges = Array.from(document.querySelectorAll(".server-item-badge"));
    expect(badges.map((badge) => badge.textContent)).toEqual(["3", "5"]);
  });

  it("频道侧栏切场景 → 内容区切换", async () => {
    mockMatchMedia(false);
    renderGroup("/group/1");
    screen.getByRole("button", { name: "直播" }).click();
    await waitFor(() => expect(screen.getByText("群内直播内容")).toBeInTheDocument());
  });

  it("服务器栏底部加号 → 打开建群对话框（需求：左下角头像键改创建群聊加号）", async () => {
    mockMatchMedia(false);
    renderGroup("/group/1");
    const createBtn = screen.getByRole("button", { name: "创建群聊" });
    expect(createBtn).toBeInTheDocument();
    // 无旧的用户头像卡（左下角不再渲染头像键）
    expect(document.querySelector(".server-user")).toBeNull();
    createBtn.click();
    await waitFor(() => expect(screen.getByRole("dialog", { name: "创建群聊" })).toBeInTheDocument());
    // 建群对话框已打开（群名必填输入框）
    expect(document.querySelector('input[placeholder*="群名"]')).not.toBeNull();
  });

  it("服务器栏底部加号打开的建群对话框可关闭", async () => {
    mockMatchMedia(false);
    renderGroup("/group/1");
    screen.getByRole("button", { name: "创建群聊" }).click();
    await waitFor(() => expect(screen.getByRole("dialog", { name: "创建群聊" })).toBeInTheDocument());
    fireEvent.click(screen.getByRole("button", { name: "关闭" }));
    await waitFor(() =>
      expect(document.querySelector(".group-create-dialog")).not.toBeInTheDocument(),
    );
  });

  it("非 chat 子场景不持有 activeConversationId（群内其他界面不自动已读）", async () => {
    mockMatchMedia(false);
    useChatStore.setState({ conversations: [groupConv("1", "测试群")] });
    renderGroup("/group/1");
    // 聊天场景持有 activeId
    expect(useChatStore.getState().activeConversationId).toBe("1");
    // 切到帖子场景 → activeId 清空，新消息进未读而不是自动已读
    await waitFor(() => expect(screen.getByRole("button", { name: "帖子" })).toBeInTheDocument());
    fireEvent.click(screen.getByRole("button", { name: "帖子" }));
    await waitFor(() => expect(useGroupStore.getState().activeScene).toBe("posts"));
    expect(useChatStore.getState().activeConversationId).toBeNull();
    // 切回聊天场景 → activeId 恢复
    fireEvent.click(screen.getByRole("button", { name: "聊天" }));
    await waitFor(() => expect(useGroupStore.getState().activeScene).toBe("chat"));
    expect(useChatStore.getState().activeConversationId).toBe("1");
  });
});
