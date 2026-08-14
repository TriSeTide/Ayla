/**
 * AppShell 与壳层配置测试（F1）：
 * - resolveModule / resolveFabAction / isImmersiveRoute 纯函数路由映射（含需求 §3.5 全表）；
 * - 窄屏渲染 BottomTabs + MessageFAB（无 TopNav）、宽屏渲染 TopNav（无 BottomTabs）；
 * - 直播沉浸路由不渲染 chrome；群聊聊天子界面无 FAB；
 * - CreateFAB 动作面板：场景动作提示步骤、次级「创建群聊」跳转 /chat。
 */
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AppShell } from "../layout/AppShell";
import {
  isLiveRoomRoute,
  resolveFabAction,
  resolveModule,
} from "../layout/shellConfig";
import { useAuthStore } from "../stores/auth";

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
          <Route path="/live" element={<div>直播内容</div>} />
          <Route path="/live/:channelId" element={<div>直播间内容</div>} />
          <Route path="/posts" element={<div>帖子内容</div>} />
          <Route path="/games" element={<div>桌游内容</div>} />
          <Route path="/messages" element={<div>消息内容</div>} />
          <Route path="/search" element={<div>搜索内容</div>} />
          <Route path="/profile" element={<div>个人内容</div>} />
          <Route path="/group/:id" element={<div>群聊内容</div>} />
          <Route path="/group/:id/:scene" element={<div>群子场景</div>} />
          <Route path="/chat" element={<div>聊天内容</div>} />
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
});

afterEach(() => {
  vi.unstubAllGlobals();
});

/* ---------- 纯函数：模块归属 ---------- */

describe("resolveModule", () => {
  const cases: Array<[string, string | null]> = [
    ["/home", "home"],
    ["/group/g1", "home"],
    ["/group/g1/live", "home"],
    ["/chat", "home"],
    ["/chat/c1", "home"],
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
    expect(resolveFabAction("/home")?.key).toBe("create-group");
    expect(resolveFabAction("/voice")?.key).toBe("create-voice");
    expect(resolveFabAction("/live")?.key).toBe("create-live");
    expect(resolveFabAction("/posts")?.key).toBe("create-post");
    expect(resolveFabAction("/games")?.key).toBe("create-game");

    expect(resolveFabAction("/group/g1/voice")).toMatchObject({ key: "group-voice", groupId: "g1" });
    expect(resolveFabAction("/group/g1/live")).toMatchObject({ key: "group-live", groupId: "g1" });
    expect(resolveFabAction("/group/g1/posts")).toMatchObject({ key: "group-post", groupId: "g1" });
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

describe("isLiveRoomRoute", () => {
  it("直播间路由命中，大厅与其它路由不命中", () => {
    expect(isLiveRoomRoute("/live/42")).toBe(true);
    expect(isLiveRoomRoute("/live")).toBe(false);
    expect(isLiveRoomRoute("/home")).toBe(false);
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
});

/* ---------- CreateFAB 交互 ---------- */

describe("CreateFab", () => {
  it("主页 FAB 弹面板：场景动作提示步骤", async () => {
    renderShell("/posts", true);
    fireEvent.click(screen.getByRole("button", { name: "发帖" }));
    const item = screen.getByRole("menuitem", { name: /发帖/ });
    fireEvent.click(item);
    await waitFor(() =>
      expect(screen.getByRole("status")).toHaveTextContent("「发帖」表单将随 F6 步骤落地"),
    );
  });

  it("面板含次级「创建群聊」，点击跳转 /chat", async () => {
    renderShell("/posts", true);
    fireEvent.click(screen.getByRole("button", { name: "发帖" }));
    fireEvent.click(screen.getByRole("menuitem", { name: "创建群聊" }));
    await waitFor(() => expect(screen.getByText("聊天内容")).toBeInTheDocument());
  });

  it("群内开播（F4 已接线）面板渲染创建直播间表单", async () => {
    renderShell("/group/g1/live", true);
    fireEvent.click(screen.getByRole("button", { name: "群内开播" }));
    // F4 起 group-live 动作渲染 LiveCreate 真表单（非 hint 提示）
    expect(screen.getByPlaceholderText("给直播间起个标题")).toBeInTheDocument();
  });
});
