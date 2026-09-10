/**
 * TopNav 宽屏搜索（U10 + 清除键）：
 * - 输入文本 → 清除键出现，点击清空并保持聚焦；
 * - 输入文本 → 内联下拉按六类分组渲染（组头 Micro Tag + 每组 ≤3 + 查看更多）。
 */
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { MemoryRouter, Route, Routes, useLocation, useNavigate } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { search } from "../api/search";
import type { SearchResults } from "../api/types";
import { AppShell } from "../layout/AppShell";
import { useAuthStore } from "../stores/auth";
import { useBadgesStore } from "../stores/badges";
import { useShellStore } from "../stores/shell";

vi.mock("../api/search", () => ({ search: vi.fn() }));
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

function SearchRouteProbe() {
  const location = useLocation();
  const navigate = useNavigate();
  const change = (key: string, value: string) => {
    const params = new URLSearchParams(location.search);
    params.set(key, value);
    navigate({ pathname: "/search", search: `?${params}` });
  };
  return <><output data-testid="search-location" data-path={location.pathname}>{location.search}</output>
    <button onClick={() => change("type", "user")}>只换筛选</button>
    <button onClick={() => change("q", "历史关键词")}>读取历史关键词</button></>;
}

function renderWide(path: string, narrow = false) {
  mockMatchMedia(narrow);
  return render(
    <MemoryRouter initialEntries={[path]}>
      <SearchRouteProbe />
      <Routes>
        <Route element={<AppShell />}>
          <Route path="/home" element={<div>主页内容</div>} />
          <Route path="/search" element={<div>搜索内容</div>} />
        </Route>
      </Routes>
    </MemoryRouter>,
  );
}

/** 六类都有结果；用户组 total=5（>3）触发「查看更多」 */
const sixGroups = {
  users: {
    total: 5,
    items: [
      { id: "u1", username: "bob", nickname: "小樱", avatar: "", online: true },
      { id: "u2", username: "cat", nickname: "小桃", avatar: "", online: false },
      { id: "u3", username: "dog", nickname: "小兰", avatar: "", online: true },
    ],
  },
  groups: {
    total: 1,
    items: [{ id: "g1", type: "group", title: "冰樱研究所", join_policy: "application", created_at: "2026-01-01T00:00:00Z" }],
  },
  posts: {
    total: 2,
    items: [
      { id: "p1", title: "第一帖", body: "内容一" },
      { id: "p2", title: "", body: "只有正文的第二帖" },
    ],
  },
  lives: { total: 1, items: [{ id: "l1", title: "深夜直播" }] },
  voices: { total: 1, items: [{ id: "v1", name: "深夜语音" }] },
  games: { total: 1, items: [{ id: "game1", name: "狼人杀" }] },
} as unknown as SearchResults;

const emptyResults: SearchResults = {
  users: { total: 0, items: [] },
  groups: { total: 0, items: [] },
  posts: { total: 0, items: [] },
  lives: { total: 0, items: [] },
  voices: { total: 0, items: [] },
  games: { total: 0, items: [] },
};

beforeEach(() => {
  vi.mocked(search).mockResolvedValue(emptyResults);
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
  useBadgesStore.setState({ badges: null });
  useShellStore.setState({ quickMessagesOpen: false });
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("TopNav 宽屏搜索（U10 + 清除键）", () => {
  it.each([false, true])("已选分类的关键词提交与清空保留类型（narrow=%s）", (narrow) => {
    renderWide("/search?q=冰樱&type=post", narrow);
    const input = screen.getByRole("textbox", { name: "全局搜索" });
    expect(input).toHaveValue("冰樱");
    fireEvent.change(input, { target: { value: "  新关键词  " } });
    fireEvent.submit(screen.getByRole("search"));
    let params = new URLSearchParams(screen.getByTestId("search-location").textContent!);
    expect(params.get("q")).toBe("新关键词");
    expect(params.get("type")).toBe("post");
    expect(input).toHaveValue("新关键词");
    fireEvent.click(screen.getByRole("button", { name: "清除搜索" }));
    params = new URLSearchParams(screen.getByTestId("search-location").textContent!);
    expect(params.has("q")).toBe(false);
    expect(params.get("type")).toBe("post");
    expect(input).toHaveValue("");
    expect(input).toHaveFocus();
  });

  it.each([false, true])("仅筛选变化不覆盖未提交草稿，URL关键词变化同步输入（narrow=%s）", (narrow) => {
    renderWide("/search?q=冰樱&type=post", narrow);
    const input = screen.getByRole("textbox", { name: "全局搜索" });
    fireEvent.change(input, { target: { value: "未提交的新草稿" } });
    fireEvent.click(screen.getByRole("button", { name: "只换筛选" }));
    expect(input).toHaveValue("未提交的新草稿");
    fireEvent.click(screen.getByRole("button", { name: "读取历史关键词" }));
    expect(input).toHaveValue("历史关键词");
  });

  it.each([false, true])("提交时不传播非法分类（narrow=%s）", (narrow) => {
    renderWide("/search?q=冰樱&type=invalid", narrow);
    fireEvent.submit(screen.getByRole("search"));
    expect(new URLSearchParams(screen.getByTestId("search-location").textContent!).has("type")).toBe(false);
  });

  it("其他页面的新搜索默认全部，不读取其他页面的q/type", () => {
    renderWide("/home?q=别处关键词&type=post");
    const input = screen.getByRole("textbox", { name: "全局搜索" });
    expect(input).toHaveValue("");
    fireEvent.change(input, { target: { value: "新搜索" } });
    fireEvent.submit(screen.getByRole("search"));
    const target = screen.getByTestId("search-location");
    expect(target).toHaveAttribute("data-path", "/search");
    expect(new URLSearchParams(target.textContent!).get("q")).toBe("新搜索");
    expect(new URLSearchParams(target.textContent!).has("type")).toBe(false);
  });

  it("点击右侧放大镜提交钮进搜索页（与回车同通道）", () => {
    renderWide("/home");
    const input = screen.getByRole("textbox", { name: "全局搜索" });
    fireEvent.change(input, { target: { value: "冰樱" } });
    fireEvent.click(screen.getByRole("button", { name: "搜索" }));
    const target = screen.getByTestId("search-location");
    expect(target).toHaveAttribute("data-path", "/search");
    expect(new URLSearchParams(target.textContent!).get("q")).toBe("冰樱");
    expect(new URLSearchParams(target.textContent!).has("type")).toBe(false);
  });

  it("搜索页点击提交钮保留已选分类", () => {
    renderWide("/search?q=冰樱&type=post");
    fireEvent.click(screen.getByRole("button", { name: "搜索" }));
    const params = new URLSearchParams(screen.getByTestId("search-location").textContent!);
    expect(params.get("q")).toBe("冰樱");
    expect(params.get("type")).toBe("post");
  });

  it("输入文本显示清除键，点击清空并保持聚焦", () => {
    renderWide("/home");
    const input = screen.getByRole("textbox", { name: "全局搜索" }) as HTMLInputElement;
    fireEvent.change(input, { target: { value: "冰" } });
    const clearBtn = screen.getByRole("button", { name: "清除搜索" });
    expect(clearBtn).toBeInTheDocument();
    fireEvent.click(clearBtn);
    expect(input.value).toBe("");
    expect(document.activeElement).toBe(input);
    // 清空后无结果，下拉不显示
    expect(screen.queryByRole("listbox")).not.toBeInTheDocument();
  });

  it("输入文本 → 内联下拉按六类分组渲染（组头 + 查看更多）", async () => {
    vi.mocked(search).mockResolvedValue(sixGroups);
    renderWide("/home");
    const input = screen.getByRole("textbox", { name: "全局搜索" });
    input.focus();
    fireEvent.change(input, { target: { value: "冰樱" } });
    await waitFor(() => {
      expect(screen.getByRole("listbox")).toBeInTheDocument();
    });
    const panel = screen.getByRole("listbox");
    // 六个组头（Micro Tag 大写语义）；限定在下拉面板内避免与 TopNav 一级模块文字冲突
    expect(within(panel).getByText("用户")).toBeInTheDocument();
    expect(within(panel).getByText("群聊")).toBeInTheDocument();
    expect(within(panel).getByText("帖子")).toBeInTheDocument();
    expect(within(panel).getByText("直播间")).toBeInTheDocument();
    expect(within(panel).getByText("语音房")).toBeInTheDocument();
    expect(within(panel).getByText("桌游室")).toBeInTheDocument();
    // 用户组 total=5 > 3 → 显示「查看更多」
    expect(within(panel).getByText("查看更多")).toBeInTheDocument();
    // 结果行仍在（分组内）
    expect(within(panel).getByText("小樱")).toBeInTheDocument();
  });

  it("总数 ≤3 的组不显示「查看更多」", async () => {
    vi.mocked(search).mockResolvedValue({
      ...sixGroups,
      users: { total: 1, items: [{ id: "u1", username: "bob", nickname: "小樱", avatar: "", online: true }] },
    } as unknown as SearchResults);
    renderWide("/home");
    const input = screen.getByRole("textbox", { name: "全局搜索" });
    input.focus();
    fireEvent.change(input, { target: { value: "冰樱" } });
    await waitFor(() => {
      expect(screen.getByRole("listbox")).toBeInTheDocument();
    });
    expect(screen.queryByText("查看更多")).not.toBeInTheDocument();
  });
});
