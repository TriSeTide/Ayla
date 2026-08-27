/**
 * AppShell 与壳层配置测试（F1）：
 * - resolveModule / resolveFabAction / isImmersiveRoute 纯函数路由映射（含需求 §3.5 全表）；
 * - 窄屏渲染 BottomTabs + MessageFAB（无 TopNav）、宽屏渲染 TopNav（无 BottomTabs）；
 * - 直播沉浸路由不渲染 chrome；群聊聊天子界面无 FAB；
 * - CreateFAB 动作面板：场景动作提示步骤、次级「创建群聊」打开建群对话框。
 */
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AppShell } from "../layout/AppShell";
import {
  isGroupScene,
  isLiveRoomRoute,
  isMessagesRoute,
  isPrimaryNavRoute,
  isPrivateChatRoute,
  resolveCornerFabs,
  resolveFabAction,
  resolveModule,
} from "../layout/shellConfig";
import { useAuthStore } from "../stores/auth";
import { useBadgesStore } from "../stores/badges";
import { useShellStore } from "../stores/shell";

// 快捷消息栏由 AppShell 独立渲染；shell 测试用轻量替身验证开关/解耦，不触发其内部 API
vi.mock("../components/chat/QuickMessagesSheet", () => ({
  QuickMessagesSheet: () => <div data-testid="quick-messages-sheet" />,
}));

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
    removeEventListener: (_t: string, cb: (e: { matches: boolean }) => void) =>
      listeners.delete(cb),
  };
  vi.stubGlobal("matchMedia", vi.fn(() => mql));
}

function renderShell(path: string, narrow: boolean) {
  mockMatchMedia(narrow);
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route element={<AppShell />}>
          <Route path="/home" element={<div>主页内容</div>} />
          <Route path="/voice" element={<div>语音内容</div>} />
          <Route path="/voice/:channelId" element={<div>语音房内容</div>} />
          <Route path="/live" element={<div>直播内容</div>} />
          <Route path="/live/:channelId" element={<div>直播间内容</div>} />
          <Route path="/live/start/:channelId" element={<div>开播控制台</div>} />
          <Route path="/posts" element={<div>帖子内容</div>} />
          <Route path="/games" element={<div>桌游内容</div>} />
          <Route path="/messages" element={<div>消息内容</div>} />
          <Route path="/search" element={<div>搜索内容</div>} />
          <Route path="/profile" element={<div>个人内容</div>} />
          <Route path="/group/:id" element={<div>群聊内容</div>} />
          <Route path="/group/:id/:scene" element={<div>群子场景</div>} />
          <Route path="/chat" element={<div>聊天内容</div>} />
          <Route path="/chat/:conversationId" element={<div>私聊内容</div>} />
        </Route>
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
  // 默认无红点（messageBadge=0）；红点场景测试单独 setState
  useBadgesStore.setState({ badges: null });
  // 快捷消息栏默认关闭
  useShellStore.setState({ quickMessagesOpen: false });
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

/* ---------- 纯函数：模块归属 ---------- */

describe("resolveModule", () => {
  const cases: Array<[string, string | null]> = [
    ["/home", "home"],
    ["/group/g1", "home"],
    ["/group/g1/live", "home"],
    ["/chat/c1", null], // 私聊窗口无模块高亮
    ["/voice", "voice"],
    ["/live", "live"],
    ["/live/42", "live"],
    ["/posts", "posts"],
    ["/posts/p1", "posts"],
    ["/games", "games"],
    ["/messages", null],
    ["/search", null],
    ["/profile", null],
  ];
  it.each(cases)("%s → %s", (path, expected) => {
    expect(resolveModule(path)).toBe(expected);
  });
});

/* ---------- 纯函数：FAB 匹配（需求 §3.5 全表） ---------- */

describe("resolveFabAction", () => {
  it("一级 tab 与群内子场景映射正确", () => {
    expect(resolveFabAction("/home")).toMatchObject({ key: "create-group", handler: "group" });
    expect(resolveFabAction("/voice")?.key).toBe("create-voice");
    expect(resolveFabAction("/live")?.key).toBe("create-live");
    expect(resolveFabAction("/posts")?.key).toBe("create-post");
    expect(resolveFabAction("/games")?.key).toBe("create-game");

    expect(resolveFabAction("/group/g1/voice")).toMatchObject({ key: "group-voice", groupId: "g1" });
    expect(resolveFabAction("/group/g1/live")).toBeNull();
    // 群内帖子发帖走底部输入框（R-P2 关键差异），FAB 隐藏
    expect(resolveFabAction("/group/g1/posts")).toBeNull();
    expect(resolveFabAction("/group/g1/games")).toMatchObject({ key: "group-game", groupId: "g1" });
  });

  it("聊天子界面、群信息、直播间、消息、搜索、个人页无 FAB", () => {
    expect(resolveFabAction("/group/g1")).toBeNull();
    expect(resolveFabAction("/group/g1/info")).toBeNull();
    expect(resolveFabAction("/live/42")).toBeNull();
    expect(resolveFabAction("/messages")).toBeNull();
    expect(resolveFabAction("/search")).toBeNull();
    expect(resolveFabAction("/profile")).toBeNull();
    expect(resolveFabAction("/chat/c1")).toBeNull();
  });
});

describe("resolveCornerFabs", () => {
  it("宽屏：群外列表渲染刷新 + 回顶（右下堆叠）", () => {
    for (const path of ["/live", "/posts", "/voice", "/games"]) {
      expect(resolveCornerFabs(path, false)).toEqual({
        refresh: true,
        refreshPosition: "corner",
        scrollTop: true,
      });
    }
  });

  it("宽屏：群内帖子/语音/桌游渲染刷新 + 回顶；群聊聊天与群内直播不渲染", () => {
    for (const path of ["/group/g1/posts", "/group/g1/voice", "/group/g1/games"]) {
      expect(resolveCornerFabs(path, false)).toEqual({
        refresh: true,
        refreshPosition: "corner",
        scrollTop: true,
      });
    }
    for (const path of ["/group/g1", "/group/g1/live"]) {
      expect(resolveCornerFabs(path, false)).toEqual({
        refresh: false,
        refreshPosition: "corner",
        scrollTop: false,
      });
    }
  });

  it("宽屏：私信列表刷新键放左下、无回顶", () => {
    expect(resolveCornerFabs("/messages", false)).toEqual({
      refresh: true,
      refreshPosition: "bottom-left",
      scrollTop: false,
    });
  });

  it("窄屏：列表页渲染回顶键、不渲染刷新键（刷新由上拉手势提供）", () => {
    for (const path of ["/live", "/posts", "/voice", "/games", "/group/g1/posts", "/group/g1/voice", "/group/g1/games"]) {
      expect(resolveCornerFabs(path, true)).toEqual({
        refresh: false,
        refreshPosition: "corner",
        scrollTop: true,
      });
    }
    // 主页/消息/群聊聊天窄屏不渲染回顶键
    for (const path of ["/home", "/messages", "/group/g1"]) {
      expect(resolveCornerFabs(path, true).scrollTop).toBe(false);
    }
  });
});

describe("isLiveRoomRoute", () => {
  it("直播间路由命中，大厅与其它路由不命中", () => {
    expect(isLiveRoomRoute("/live/42")).toBe(true);
    expect(isLiveRoomRoute("/live/start/42")).toBe(true);
    // /live/start 无独立新建界面，会被 /live/:channelId 兜底捕获（channelId="start"）
    expect(isLiveRoomRoute("/live/start")).toBe(true);
    expect(isLiveRoomRoute("/live")).toBe(false);
    expect(isLiveRoomRoute("/home")).toBe(false);
  });
});

describe("isPrimaryNavRoute", () => {
  it("五个一级导航页命中，子路由/群聊/私聊/消息等不命中", () => {
    expect(isPrimaryNavRoute("/group")).toBe(true);
    expect(isPrimaryNavRoute("/home")).toBe(true);
    expect(isPrimaryNavRoute("/voice")).toBe(true);
    expect(isPrimaryNavRoute("/live")).toBe(true);
    expect(isPrimaryNavRoute("/posts")).toBe(true);
    expect(isPrimaryNavRoute("/games")).toBe(true);

    // 子路由、群聊场景、私聊、消息中心、二级页均非「一级导航页」
    expect(isPrimaryNavRoute("/voice/v1")).toBe(false);
    expect(isPrimaryNavRoute("/live/42")).toBe(false);
    expect(isPrimaryNavRoute("/posts/p1")).toBe(false);
    expect(isPrimaryNavRoute("/posts/mine")).toBe(false);
    expect(isPrimaryNavRoute("/group/g1")).toBe(false);
    expect(isPrimaryNavRoute("/chat/c1")).toBe(false);
    expect(isPrimaryNavRoute("/messages")).toBe(false);
    expect(isPrimaryNavRoute("/search")).toBe(false);
    expect(isPrimaryNavRoute("/profile")).toBe(false);
  });
});

/* ---------- AppShell 两形态 ---------- */

describe("AppShell", () => {
  it("窄屏渲染 BottomTabs 五 tab 与 MessageFAB，不渲染 TopNav", () => {
    renderShell("/home", true);
    expect(screen.getByRole("navigation", { name: "主导航" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "语音" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "直播" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "主页" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "帖子" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "桌游" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "消息" })).toBeInTheDocument();
    expect(screen.queryByRole("navigation", { name: "一级模块" })).not.toBeInTheDocument();
  });

  it("窄屏当前模块高亮（aria-current=page）", () => {
    renderShell("/posts", true);
    expect(screen.getByRole("link", { name: "帖子" })).toHaveAttribute("aria-current", "page");
    expect(screen.getByRole("link", { name: "语音" })).not.toHaveAttribute("aria-current");
  });

  it("宽屏渲染 TopNav（一级模块 + 当前指示），不渲染 BottomTabs/MessageFAB", () => {
    renderShell("/live", false);
    expect(screen.getByRole("navigation", { name: "一级模块" })).toBeInTheDocument();
    const live = screen.getByRole("link", { name: "直播" });
    expect(live).toHaveAttribute("aria-current", "page");
    expect(screen.queryByRole("navigation", { name: "主导航" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "消息" })).not.toBeInTheDocument();
  });

  it("窄屏直播间：底栏下滑走进房动画（BottomTabs 仍在，带 leaving transform），无 FAB", () => {
    renderShell("/live/42", true);
    expect(screen.getByText("直播间内容")).toBeInTheDocument();
    // 进房动画前底栏仍在 DOM（下滑走后视口外，F4）；FAB 直播间隐藏
    expect(screen.getByRole("navigation", { name: "主导航" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "创建直播间" })).not.toBeInTheDocument();
  });

  it("群聊聊天子界面不渲染 FAB（窄屏）", () => {
    renderShell("/group/g1", true);
    expect(screen.getByText("群聊内容")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /创建|开播|发帖/ })).not.toBeInTheDocument();
  });

  it("群内语音房详情窄屏不渲染底部导航栏", () => {
    expect(isGroupScene("/group/g1/voice/v1")).toBe(true);
    renderShell("/group/g1/voice/v1", true);
    expect(screen.queryByRole("navigation", { name: "主导航" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "消息" })).not.toBeInTheDocument();
  });

  it("一级语音房窄屏：进房动画前底栏仍在 DOM（下滑走后视口外，与直播间同序），无创建 FAB", () => {
    renderShell("/voice/v1", true);
    expect(screen.getByText("语音房内容")).toBeInTheDocument();
    // 进房动画前底栏仍在 DOM（下滑走后视口外，与直播间/帖子详情同序）
    expect(screen.getByRole("navigation", { name: "主导航" })).toBeInTheDocument();
    // 语音房属「其它页面」：无红点不显示左下角按钮（R-QM）
    expect(screen.queryByRole("button", { name: "消息" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "创建语音房" })).not.toBeInTheDocument();
  });

  it("语音房返回大厅路由恢复底栏导航", () => {
    renderShell("/voice", true);
    expect(screen.getByRole("navigation", { name: "主导航" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "消息" })).toBeInTheDocument();
  });

  it("宽屏列表渲染右下角浮层按钮组（ScrollTopFab + RefreshFab），窄屏列表只渲染回顶键", () => {
    renderShell("/live", false);
    // ScrollTopFab 初始隐藏（aria-hidden=true，accessible name 被清空），用 class 选择器验证存在
    expect(document.querySelector(".corner-fab-scroll-top")).not.toBeNull();
    expect(screen.getByRole("button", { name: "刷新当前页" })).toBeInTheDocument();
    cleanup();

    renderShell("/live", true);
    expect(document.querySelector(".corner-fab-scroll-top")).not.toBeNull();
    expect(screen.queryByRole("button", { name: "刷新当前页" })).not.toBeInTheDocument();
  });

  it("宽屏群聊聊天页与群内直播不渲染浮层按钮组", () => {
    for (const path of ["/group/g1", "/group/g1/live"]) {
      renderShell(path, false);
      expect(document.querySelector(".corner-fab-scroll-top")).toBeNull();
      expect(document.querySelector(".corner-fab-refresh")).toBeNull();
      cleanup();
    }
  });

  it("宽屏私信列表刷新键放左下（无回顶键）", () => {
    renderShell("/messages", false);
    expect(document.querySelector(".corner-fab-refresh.is-bottom-left")).not.toBeNull();
    expect(document.querySelector(".corner-fab-scroll-top")).toBeNull();
    cleanup();
  });
});

/* ---------- AppShell 窄屏顶栏（NarrowTopBar，抽取自各页面） ---------- */

describe("AppShell 窄屏顶栏（NarrowTopBar）", () => {
  it("窄屏 /search 渲染搜索态顶栏（输入框 + 返回键）", () => {
    renderShell("/search", true);
    expect(screen.getByRole("textbox", { name: "全局搜索" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "返回" })).toBeInTheDocument();
  });

  it("窄屏 /search 清除键：有文本时显示，点击清空", () => {
    renderShell("/search?q=冰樱", true);
    const input = screen.getByRole("textbox", { name: "全局搜索" }) as HTMLInputElement;
    expect(input.value).toBe("冰樱");
    const clearBtn = screen.getByRole("button", { name: "清除搜索" });
    expect(clearBtn).toBeInTheDocument();
    fireEvent.click(clearBtn);
    expect(input.value).toBe("");
    expect(screen.queryByRole("button", { name: "清除搜索" })).not.toBeInTheDocument();
  });

  it("窄屏 /search 确认键存在（提交搜索，与回车同通道）", () => {
    renderShell("/search", true);
    const input = screen.getByRole("textbox", { name: "全局搜索" }) as HTMLInputElement;
    fireEvent.change(input, { target: { value: "冰樱" } });
    expect(screen.getByRole("button", { name: "搜索" })).toBeInTheDocument();
  });

  it("窄屏一级列表页（/voice）渲染默认态顶栏（头像 + 搜索胶囊）", () => {
    renderShell("/voice", true);
    expect(screen.getByRole("link", { name: "个人主页" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "全局搜索" })).toBeInTheDocument();
  });

  it("窄屏群场景/私聊/沉浸路由不渲染 NarrowTopBar", () => {
    for (const path of ["/group/g1", "/chat/c1", "/live/42"]) {
      const { unmount } = renderShell(path, true);
      expect(screen.queryByRole("button", { name: "返回" })).not.toBeInTheDocument();
      expect(screen.queryByRole("textbox", { name: "全局搜索" })).not.toBeInTheDocument();
      unmount();
    }
  });

  it("宽屏不渲染 NarrowTopBar（顶栏为 TopNav，无返回键）", () => {
    renderShell("/search", false);
    expect(screen.queryByRole("button", { name: "返回" })).not.toBeInTheDocument();
  });
});

/* ---------- CreateFAB 交互 ---------- */

describe("CreateFab", () => {
  it("发帖 FAB（F6 已接线）点加号直接打开 PostEditor 表单", async () => {
    renderShell("/posts", true);
    fireEvent.click(screen.getByRole("button", { name: "发帖" }));
    expect(screen.getByPlaceholderText("正文（必填）")).toBeInTheDocument();
  });

  it("FAB 无面板气泡：各界面只渲染各自创建表单，无「创建群聊」次级项", async () => {
    renderShell("/posts", true);
    fireEvent.click(screen.getByRole("button", { name: "发帖" }));
    // 直接是 PostEditor 表单，无动作面板菜单
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    expect(screen.queryByRole("menuitem", { name: "创建群聊" })).not.toBeInTheDocument();
  });

  it("群内语音有创建 FAB（eb8e5ff 恢复 group-voice handler）", () => {
    renderShell("/group/g1/voice", true);
    expect(screen.getByRole("button", { name: "创建群内语音房" })).toBeInTheDocument();
  });

  it("群内直播不显示右下角加号（创建入口在直播侧栏）", () => {
    renderShell("/group/g1/live", true);
    expect(screen.queryByRole("button", { name: /创建|开播|发帖/ })).not.toBeInTheDocument();
  });

  it("主页 FAB 点加号直接打开建群对话框（R-F3 已接线，无面板）", async () => {
    renderShell("/home", true);
    fireEvent.click(screen.getByRole("button", { name: "创建群聊" }));
    // 点加号直接打开建群对话框（不再有动作面板/次级项）
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    await waitFor(() =>
      expect(screen.getByRole("dialog", { name: "创建群聊" })).toBeInTheDocument(),
    );
    expect(screen.getByPlaceholderText("群名（必填）")).toBeInTheDocument();
  });
});

/* ---------- 需求：宽屏消息选中 / 窄屏消息页返回主页 / 私聊无底栏 ---------- */

describe("isMessagesRoute / isPrivateChatRoute", () => {
  it("消息中心与私聊窗口命中消息路由，其它不命中", () => {
    expect(isMessagesRoute("/messages")).toBe(true);
    expect(isMessagesRoute("/chat/c1")).toBe(true);
    expect(isMessagesRoute("/home")).toBe(false);
    expect(isMessagesRoute("/group/g1")).toBe(false);
    expect(isMessagesRoute("/search")).toBe(false);
  });

  it("私聊聊天路由仅命中 /chat/:id", () => {
    expect(isPrivateChatRoute("/chat/c1")).toBe(true);
    expect(isPrivateChatRoute("/messages")).toBe(false);
    expect(isPrivateChatRoute("/home")).toBe(false);
  });
});

describe("AppShell 消息导航（需求）", () => {
  it("宽屏 TopNav 消息项在 /messages 选中（aria-current + is-active）", () => {
    renderShell("/messages", false);
    const msg = screen.getByRole("link", { name: "消息" });
    expect(msg).toHaveAttribute("aria-current", "true");
    expect(msg.className).toContain("is-active");
  });

  it("宽屏 TopNav 消息项在 /chat/:id 私聊窗口选中", () => {
    renderShell("/chat/c1", false);
    const msg = screen.getByRole("link", { name: "消息" });
    expect(msg).toHaveAttribute("aria-current", "true");
    expect(msg.className).toContain("is-active");
  });

  it("宽屏其它页消息项不选中", () => {
    renderShell("/home", false);
    const msg = screen.getByRole("link", { name: "消息" });
    expect(msg).not.toHaveAttribute("aria-current");
    expect(msg.className).not.toContain("is-active");
  });

  it("窄屏消息中心左下角按钮变为返回主页（无消息入口）", () => {
    renderShell("/messages", true);
    expect(screen.getByRole("button", { name: "返回主页" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "消息" })).not.toBeInTheDocument();
  });

  it("窄屏非消息页左下角仍是消息入口", () => {
    renderShell("/home", true);
    expect(screen.getByRole("button", { name: "消息" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "返回主页" })).not.toBeInTheDocument();
  });

  it("窄屏私聊窗口（/chat/:id）不渲染 BottomTabs 与 MessageFab（下方有输入框无导航栏）", () => {
    renderShell("/chat/c1", true);
    expect(screen.queryByRole("navigation", { name: "主导航" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "消息" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "返回主页" })).not.toBeInTheDocument();
  });

  it("窄屏消息中心仍渲染 BottomTabs（五 tab 可导航）", () => {
    renderShell("/messages", true);
    expect(screen.getByRole("navigation", { name: "主导航" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "主页" })).toBeInTheDocument();
  });
});

/* ---------- 左下角按钮显示策略（R-QM） ---------- */

describe("AppShell 左下角按钮（R-QM）", () => {
  it("五个一级导航页常态显示消息按钮（跳 /messages）", () => {
    // /home 代表主页一级导航页（/group 重定向 /home 无独立测试路由）
    for (const path of ["/home", "/voice", "/live", "/posts", "/games"]) {
      const { unmount } = renderShell(path, true);
      expect(screen.getByRole("button", { name: "消息" })).toBeInTheDocument();
      unmount();
    }
  });

  it("/messages 页左下角为返回主页按钮，无消息入口", () => {
    renderShell("/messages", true);
    expect(screen.getByRole("button", { name: "返回主页" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "消息" })).not.toBeInTheDocument();
  });

  it("其它页面无红点不显示左下角按钮（搜索/个人/群聊）", () => {
    for (const path of ["/search", "/profile", "/group/g1"]) {
      const { unmount } = renderShell(path, true);
      expect(screen.queryByRole("button", { name: /消息|返回主页/ })).not.toBeInTheDocument();
      unmount();
    }
  });

  it("其它页面有红点显示快捷消息按钮（群聊场景也显示）", () => {
    useBadgesStore.setState({
      badges: {
        private_unread: 2,
        group_unread: 0,
        friend_requests: 0,
        group_invites: 0,
        join_requests_pending: 0,
      },
    });
    renderShell("/group/g1", true);
    expect(screen.getByRole("button", { name: "消息，2 条未读" })).toBeInTheDocument();
  });

  it("私聊窗口不显示左下角按钮（即使有红点）", () => {
    useBadgesStore.setState({
      badges: {
        private_unread: 2,
        group_unread: 0,
        friend_requests: 0,
        group_invites: 0,
        join_requests_pending: 0,
      },
    });
    renderShell("/chat/c1", true);
    expect(screen.queryByRole("button", { name: /消息|返回主页/ })).not.toBeInTheDocument();
  });

  it("快捷栏打开后红点归零不自动关闭（只手动关闭）", () => {
    useBadgesStore.setState({
      badges: {
        private_unread: 2,
        group_unread: 0,
        friend_requests: 0,
        group_invites: 0,
        join_requests_pending: 0,
      },
    });
    renderShell("/group/g1", true);
    // 点击快捷按钮 → 打开快捷消息栏
    act(() => {
      fireEvent.click(screen.getByRole("button", { name: "消息，2 条未读" }));
    });
    expect(screen.getByTestId("quick-messages-sheet")).toBeInTheDocument();

    // 打开会话标已读 → 红点归零 → 快捷按钮消失，但快捷栏保持打开（只随手动关闭卸载）
    act(() => {
      useBadgesStore.setState({ badges: null });
    });
    expect(screen.queryByRole("button", { name: /消息/ })).not.toBeInTheDocument();
    expect(screen.getByTestId("quick-messages-sheet")).toBeInTheDocument();
  });
});
