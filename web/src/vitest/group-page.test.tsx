/**
 * GroupPage 测试（F3）：
 * - 窄屏默认聊天子界面；群头像两级点击（chat→info，非 chat→chat）；
 * - 宽屏三列（ServerRail + ChannelSidebar + 内容区）切群/切场景。
 * GroupChat / GroupInfo mock 成轻量组件（避免聊天 WS/API 链路），
 * 聚焦容器/导航/两级点击语义。
 */
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ConversationSummary } from "../api/types";
import { GroupPage } from "../pages/GroupPage";
import { useChatStore } from "../stores/chat";
import { useGroupStore } from "../stores/group";

vi.mock("../pages/group/GroupChat", () => ({
  GroupChat: () => <div>群聊内容区</div>,
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
vi.mock("../api/chat", () => ({
  getConversation: vi.fn(),
  listConversations: vi.fn().mockResolvedValue([]),
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

function renderGroup(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="/home" element={<div>主页内容</div>} />
        <Route path="/group/:id" element={<GroupPage />} />
        <Route path="/group/:id/:scene" element={<GroupPage />} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  useChatStore.setState({
    conversations: [groupConv("1", "测试群"), groupConv("2", "另个群")],
  });
  useGroupStore.getState().reset();
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.clearAllMocks();
  useChatStore.setState({ conversations: [] });
  useGroupStore.getState().reset();
});

describe("GroupPage 窄屏", () => {
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
});

describe("GroupPage 宽屏", () => {
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
    // 进入群 1 即 openConversation 清其未读（语义正确）；另个群未读徽标保留
    const badge = document.querySelector(".server-item-badge");
    expect(badge?.textContent).toBe("5");
  });

  it("频道侧栏切场景 → 内容区切换", async () => {
    mockMatchMedia(false);
    renderGroup("/group/1");
    screen.getByRole("button", { name: /直播/ }).click();
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
});
