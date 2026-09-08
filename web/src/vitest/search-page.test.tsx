/**
 * SearchPage 测试（F9）：
 * - URL ?q= 直接进入自动搜索 → 结果分组显示；
 * - 历史 chips 点击 → URL 更新；
 * - 五类分组空态 / 群结果申请弹窗（申请制/公开/旧数据）；
 * - 窄屏顶栏（NarrowTopBar search variant）已抽取到 AppShell，本页不再渲染
 *   （其交互测试见 shell.test.tsx）。
 */
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes, useNavigate } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { searchPages, type SearchPageResults } from "../api/search";
import { applyToGroup } from "../api/chat";
import { getSignedMediaUrl } from "../api/media";

import { SearchPage, clearSearchPageMemory } from "../pages/SearchPage";
import { useAuthStore } from "../stores/auth";
import { useSearchStore } from "../stores/search";
import { useChatStore } from "../stores/chat";
import { goUserProfile } from "../utils/navigation";
import { clearScrollMemory } from "../hooks/useScrollRestore";
const originalAnimate = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "animate");
const searchWS = vi.hoisted(() => ({ handler: null as ((frame: unknown) => void) | null }));
vi.mock("../ws/chat", () => ({ chatWS: {
  onFrame: vi.fn((handler: (frame: unknown) => void) => { searchWS.handler = handler; return vi.fn(); }),
  disconnect: vi.fn(),
} }));

vi.mock("../api/search", () => ({ searchPages: vi.fn() }));
vi.mock("../api/chat", () => ({ applyToGroup: vi.fn() }));
vi.mock("../api/media", () => ({ getSignedMediaUrl: vi.fn(), invalidateSignedMediaUrl: vi.fn() }));
vi.mock("../utils/navigation", () => ({ goUserProfile: vi.fn() }));
vi.mock("../components/UserProfileCard", () => ({
  UserProfileCard: ({ user, onClose }: { user: { nickname: string }; onClose: () => void }) => (
    <div role="dialog" aria-label={`${user.nickname} 资料`}><button onClick={onClose}>关闭资料</button></div>
  ),
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

function resultFor(q: string): SearchPageResults {
  void q;
  return {
    users: { next_cursor: null, has_more: false, total: 1, items: [{ id: "u2", username: "bob", nickname: "小樱", avatar: "", signature: "", status: "auto", online: false, date_joined: "2026-01-01T00:00:00Z" }] },
    groups: { next_cursor: null, has_more: false, total: 1, items: [{ id: "g1", type: "group", title: "冰樱研究所", join_policy: "application", created_at: "2026-01-01T00:00:00Z" }] },
    posts: { next_cursor: null, has_more: false, total: 0, items: [] },
    lives: { next_cursor: null, has_more: false, total: 0, items: [] },
    games: { next_cursor: null, has_more: false, total: 0, items: [] },
  };
}

/** 只含一个群的搜索结果；joinPolicy 缺省=旧数据（无 join_policy 字段） */
function groupResult(joinPolicy?: "public" | "application"): SearchPageResults & { groups: NonNullable<SearchPageResults["groups"]> } {
  return {
    users: { next_cursor: null, has_more: false, total: 0, items: [] },
    groups: {
      next_cursor: null, has_more: false, total: 1,
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
    posts: { next_cursor: null, has_more: false, total: 0, items: [] },
    lives: { next_cursor: null, has_more: false, total: 0, items: [] },
    games: { next_cursor: null, has_more: false, total: 0, items: [] },
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
  clearSearchPageMemory();
  clearScrollMemory();
  vi.mocked(searchPages).mockReset().mockResolvedValue(resultFor("冰樱"));
  vi.mocked(applyToGroup).mockResolvedValue({} as never);
  vi.mocked(getSignedMediaUrl).mockResolvedValue("/fixtures/signed-group-avatar.png");
  useAuthStore.setState({ currentUser });
  useSearchStore.setState({ history: [] });
  useChatStore.setState({ conversations: [] });
  searchWS.handler = null;
  localStorage.clear();
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((complete) => { resolve = complete; });
  return { promise, resolve };
}
function QueryControls() {
  const navigate = useNavigate();
  return <><button onClick={() => navigate("/search?q=新关键词")}>换查询</button>
    <button onClick={() => navigate("/search")}>清空查询</button>
    <button onClick={() => navigate("/detail")}>打开详情</button>
    <button onClick={() => navigate(-1)}>返回搜索</button></>;
}
function renderSearchControls(motion = false) {
  mockMatchMedia(true);
  if (motion) vi.stubGlobal("matchMedia", vi.fn((query: string) => ({ matches: query === NARROW, addEventListener: vi.fn(), removeEventListener: vi.fn() })));
  return render(<MemoryRouter initialEntries={["/search?q=冰樱"]}>
    <QueryControls /><Routes><Route path="/search" element={<SearchPage />} /><Route path="/detail" element={<div>详情内容</div>} /></Routes>
  </MemoryRouter>);
}

describe("搜索分组游标分页", () => {
  it.each([
    ["user", "用户", "users"], ["group", "群聊", "groups"], ["post", "帖子", "posts"],
    ["live", "直播间", "lives"], ["game", "桌游室", "games"],
  ] as const)("直达 %s 分类只展示本类，使用20条类型分页", async (type, label, key) => {
    const { container } = renderSearch(`/search?q=冰樱&type=${type}`, false);
    await waitFor(() => expect(screen.queryByText("搜索中…")).not.toBeInTheDocument());
    expect(searchPages).toHaveBeenCalledWith({ q: "冰樱", types: [type], limit: 20 });
    expect(screen.getByRole("tab", { name: label })).toHaveAttribute("aria-selected", "true");
    expect(screen.getByRole("tabpanel", { name: label })).toHaveAttribute("data-search-filter", type);
    expect(screen.getAllByRole("tab")).toHaveLength(6);
    // 分组标题已按需求移除（左侧栏选项卡即分类标识），只验证本类分组存在
    expect(container.querySelectorAll(".search-group")).toHaveLength(resultFor("")[key]!.total ? 1 : 0);
    expect(container.querySelector(".search-content .search-filters")).toBeNull();
  });

  it("分类各自保存分页和滚动，首次进入归零、切回恢复且不重拉", async () => {
    const all = resultFor("冰樱");
    all.users = { ...all.users!, next_cursor: "all-u1", has_more: true };
    vi.mocked(searchPages).mockResolvedValueOnce(all).mockResolvedValueOnce({ users: {
      ...all.users, next_cursor: "all-u2", items: [{ ...all.users.items[0], id: "u3", nickname: "全部第二页" }],
    } }).mockResolvedValueOnce({ users: { ...all.users, next_cursor: "type-u1",
      items: [{ ...all.users.items[0], id: "u4", nickname: "用户分类第一页" }],
    } });
    const { container } = renderSearch("/search?q=冰樱", false);
    await screen.findByText("小樱");
    fireEvent.click(screen.getByRole("button", { name: "加载更多用户" }));
    await screen.findByText("全部第二页");
    const allScroll = container.querySelector<HTMLElement>(".search-content")!;
    const filters = screen.getByRole("tablist", { name: "搜索分类" });
    allScroll.scrollTop = 410;
    fireEvent.click(screen.getByRole("tab", { name: "用户" }));
    await screen.findByText("用户分类第一页");
    const userScroll = container.querySelector<HTMLElement>(".search-content")!;
    expect(userScroll).not.toBe(allScroll);
    expect(userScroll.scrollTop).toBe(0);
    expect(screen.queryByText("全部第二页")).not.toBeInTheDocument();
    userScroll.scrollTop = 130;
    fireEvent.click(screen.getByRole("tab", { name: "全部" }));
    await screen.findByText("全部第二页");
    expect(container.querySelector<HTMLElement>(".search-content")!.scrollTop).toBe(410);
    fireEvent.click(screen.getByRole("tab", { name: "用户" }));
    await screen.findByText("用户分类第一页");
    expect(container.querySelector<HTMLElement>(".search-content")!.scrollTop).toBe(130);
    expect(screen.getByRole("tablist", { name: "搜索分类" })).toBe(filters);
    expect(searchPages).toHaveBeenCalledTimes(3);
    vi.mocked(searchPages).mockResolvedValueOnce({ users: { ...all.users, has_more: false, next_cursor: null, items: [] } });
    fireEvent.click(screen.getByRole("button", { name: "加载更多用户" }));
    await waitFor(() => expect(searchPages).toHaveBeenLastCalledWith({ q: "冰樱", types: ["user"], limit: 20, cursor: "type-u1" }));
  });

  it("快速分类切换丢弃旧分类迟到响应，当前错误重试仍使用本类", async () => {
    const previous = deferred<SearchPageResults>();
    vi.mocked(searchPages).mockReturnValueOnce(previous.promise).mockRejectedValueOnce(new Error("群聊首屏失败"))
      .mockResolvedValueOnce(groupResult());
    renderSearch("/search?q=冰樱&type=user", true);
    fireEvent.click(screen.getByRole("tab", { name: "群聊" }));
    await screen.findByText("群聊首屏失败");
    await act(async () => previous.resolve(resultFor("冰樱")));
    expect(screen.queryByText("小樱")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "重试搜索" }));
    await screen.findByRole("button", { name: /冰樱研究所/ });
    expect(searchPages).toHaveBeenLastCalledWith({ q: "冰樱", types: ["group"], limit: 20 });
    expect(screen.getByRole("tab", { name: "群聊" })).toHaveAttribute("aria-selected", "true");
  });

  it("成员事件继续自动刷新当前分类，并使其他已缓存分类在返回时自动刷新", async () => {
    const before = groupResult();
    before.groups.items[0].is_member = false;
    const after = groupResult();
    after.groups.items[0].is_member = true;
    vi.mocked(searchPages).mockResolvedValueOnce(before).mockResolvedValueOnce({ users: resultFor("").users })
      .mockResolvedValueOnce({ users: resultFor("").users }).mockResolvedValueOnce(after);
    renderSearch("/search?q=冰樱&type=group", true);
    await screen.findByRole("button", { name: /冰樱研究所 申请入群/ });
    fireEvent.click(screen.getByRole("tab", { name: "用户" }));
    await screen.findByText("小樱");
    act(() => searchWS.handler?.({ type: "group.joined", conversation: { id: "g1" } }));
    await waitFor(() => expect(searchPages).toHaveBeenCalledTimes(3));
    fireEvent.click(screen.getByRole("tab", { name: "群聊" }));
    await screen.findByRole("button", { name: /冰樱研究所 已加入/ });
    expect(searchPages).toHaveBeenCalledTimes(4);
    expect(searchPages).toHaveBeenLastCalledWith({ q: "冰樱", types: ["group"], limit: 20 });
    expect(screen.queryByRole("button", { name: /已更新|重新搜索/ })).not.toBeInTheDocument();
  });

  it.each([true, false])("筛选键盘方向与布局一致并保留焦点（narrow=%s）", async (narrow) => {
    renderSearch("/search", narrow);
    const all = screen.getByRole("tab", { name: "全部" });
    expect(screen.getByRole("tablist", { name: "搜索分类" })).toHaveAttribute("aria-orientation", narrow ? "horizontal" : "vertical");
    all.focus();
    fireEvent.keyDown(all, { key: narrow ? "ArrowRight" : "ArrowDown" });
    const user = screen.getByRole("tab", { name: "用户" });
    expect(user).toHaveFocus();
    expect(user).toHaveAttribute("aria-selected", "true");
    expect(user).toHaveAttribute("tabindex", "0");
    fireEvent.keyDown(user, { key: "End" });
    expect(screen.getByRole("tab", { name: "桌游室" })).toHaveFocus();
    fireEvent.keyDown(screen.getByRole("tab", { name: "桌游室" }), { key: "Home" });
    expect(all).toHaveFocus();
    expect(all).toHaveAttribute("aria-selected", "true");
    expect(searchPages).not.toHaveBeenCalled();
  });

  it("群目录未加载该群时仍按服务端is_member显示已加入并直接进群", async () => {
    const result = groupResult("application");
    result.groups.items[0].is_member = true;
    vi.mocked(searchPages).mockResolvedValueOnce(result);
    renderSearch("/search?q=冰樱", true);
    const joined = await screen.findByRole("button", { name: /冰樱研究所 已加入/ });
    expect(useChatStore.getState().conversations).toEqual([]);
    fireEvent.click(joined);
    await waitFor(() => expect(screen.queryByText("冰樱研究所")).not.toBeInTheDocument());
    expect(applyToGroup).not.toHaveBeenCalled();
  });

  it("请求期间入群事实不被迟到is_member=false覆盖，离群事件更新本人按钮", async () => {
    const pending = deferred<SearchPageResults>();
    const response = groupResult("application");
    response.groups.items[0].is_member = false;
    const joined = groupResult("application");
    joined.groups.items[0].is_member = true;
    vi.mocked(searchPages).mockReturnValueOnce(pending.promise).mockResolvedValueOnce(joined).mockResolvedValueOnce(response);
    renderSearchControls();
    act(() => searchWS.handler?.({ type: "group.joined", conversation: { id: "g1" } }));
    await act(async () => pending.resolve(response));
    expect(screen.getByRole("button", { name: /冰樱研究所 已加入/ })).toBeInTheDocument();
    await act(async () => searchWS.handler?.({ type: "group.member.left", data: { conversation_id: "g1", member_id: "u1" } }));
    expect(screen.getByRole("button", { name: /冰樱研究所 申请入群/ })).toBeInTheDocument();
  });
  it("各组独立请求自己的cursor，追加去重且其他组和原DOM保持", async () => {
    const first = resultFor("冰樱");
    first.users = { ...first.users!, has_more: true, next_cursor: "users-one", total: 2 };
    first.groups = { ...first.groups!, has_more: true, next_cursor: "groups-one", total: 2 };
    const users = deferred<SearchPageResults>();
    const groups = deferred<SearchPageResults>();
    vi.mocked(searchPages).mockResolvedValueOnce(first).mockReturnValueOnce(users.promise).mockReturnValueOnce(groups.promise);
    const { container } = renderSearchControls();
    const retained = await screen.findByRole("button", { name: "小樱" });
    const retainedGroup = screen.getByRole("button", { name: /冰樱研究所/ });
    const scroll = container.querySelector<HTMLElement>(".search-content")!;
    scroll.scrollTop = 330;
    fireEvent.click(screen.getByRole("button", { name: "加载更多用户" }));
    expect(screen.getByRole("button", { name: "加载更多群聊" })).not.toBeDisabled();
    fireEvent.click(screen.getByRole("button", { name: "加载更多群聊" }));
    await act(async () => groups.resolve({ groups: { ...first.groups!, has_more: false, next_cursor: null,
      items: [...first.groups!.items, { ...first.groups!.items[0], id: "g2", title: "追加群聊" }] } }));
    await act(async () => users.resolve({ users: { ...first.users!, has_more: false, next_cursor: null,
      items: [...first.users!.items, { ...first.users!.items[0], id: "u3", nickname: "追加用户" }] } }));
    expect(searchPages).toHaveBeenNthCalledWith(2, { q: "冰樱", types: ["user"], limit: 20, cursor: "users-one" });
    expect(searchPages).toHaveBeenNthCalledWith(3, { q: "冰樱", types: ["group"], limit: 20, cursor: "groups-one" });
    expect(screen.getByRole("button", { name: "小樱" })).toBe(retained);
    expect(screen.getByRole("button", { name: /冰樱研究所/ })).toBe(retainedGroup);
    expect(container.querySelectorAll(".search-user-row")).toHaveLength(2);
    expect(container.querySelectorAll(".search-group-row")).toHaveLength(2);
    expect(scroll.scrollTop).toBe(330);
    expect(screen.queryByRole("button", { name: "加载更多用户" })).not.toBeInTheDocument();
  });

  it("单组续页失败保留首屏，重试携带原游标", async () => {
    const first = resultFor("冰樱");
    first.users = { ...first.users!, has_more: true, next_cursor: "retry-users" };
    vi.mocked(searchPages).mockResolvedValueOnce(first).mockRejectedValueOnce(new Error("用户续页失败"))
      .mockResolvedValueOnce({ users: { ...first.users, has_more: false, next_cursor: null,
        items: [{ ...first.users.items[0], id: "u3", nickname: "重试用户" }] } });
    renderSearchControls();
    const retained = await screen.findByRole("button", { name: "小樱" });
    fireEvent.click(screen.getByRole("button", { name: "加载更多用户" }));
    await screen.findByText("用户续页失败");
    expect(screen.getByRole("button", { name: "小樱" })).toBe(retained);
    fireEvent.click(screen.getByRole("button", { name: "重试加载用户" }));
    await screen.findByText("重试用户");
    expect(vi.mocked(searchPages).mock.calls.slice(1)).toEqual([
      [{ q: "冰樱", types: ["user"], limit: 20, cursor: "retry-users" }],
      [{ q: "冰樱", types: ["user"], limit: 20, cursor: "retry-users" }],
    ]);
  });

  it("查询变更会隔离上一查询正在加载的后页", async () => {
    const first = resultFor("冰樱");
    first.users = { ...first.users!, has_more: true, next_cursor: "old-query-cursor" };
    const next = resultFor("新关键词");
    next.users!.items = [{ ...next.users!.items[0], nickname: "新查询用户" }];
    const previous = deferred<SearchPageResults>();
    vi.mocked(searchPages).mockResolvedValueOnce(first).mockReturnValueOnce(previous.promise).mockResolvedValueOnce(next);
    renderSearchControls();
    await screen.findByText("小樱");
    fireEvent.click(screen.getByRole("button", { name: "加载更多用户" }));
    fireEvent.click(screen.getByRole("button", { name: "换查询" }));
    await screen.findByText("新查询用户");
    await act(async () => previous.resolve({ users: { ...first.users!, has_more: false, next_cursor: null,
      items: [{ ...first.users!.items[0], id: "u-late", nickname: "旧查询迟到用户" }] } }));
    expect(screen.queryByText("旧查询迟到用户")).not.toBeInTheDocument();
    expect(screen.getByText("新查询用户")).toBeInTheDocument();
  });

  it("清空查询时正在等待的首屏不能重新显示", async () => {
    const previous = deferred<SearchPageResults>();
    vi.mocked(searchPages).mockReturnValueOnce(previous.promise);
    renderSearchControls();
    fireEvent.click(screen.getByRole("button", { name: "清空查询" }));
    await act(async () => previous.resolve(resultFor("冰樱")));
    expect(screen.queryByText("小樱")).not.toBeInTheDocument();
    expect(screen.queryByText("搜索中…")).not.toBeInTheDocument();
  });

  it("账号切换后的旧响应不能覆盖新账号搜索结果", async () => {
    const previous = deferred<SearchPageResults>();
    const next = resultFor("冰樱");
    next.users!.items = [{ ...next.users!.items[0], nickname: "新账号结果" }];
    vi.mocked(searchPages).mockReturnValueOnce(previous.promise).mockResolvedValueOnce(next);
    renderSearchControls();
    act(() => useAuthStore.setState({ currentUser: { ...currentUser, id: "new-account" } }));
    await screen.findByText("新账号结果");
    await act(async () => previous.resolve(resultFor("冰樱")));
    expect(screen.queryByText("小樱")).not.toBeInTheDocument();
    expect(screen.getByText("新账号结果")).toBeInTheDocument();
  });

  it("详情返回恢复各组全部已加载项、滚动和下一游标", async () => {
    const animated: HTMLElement[] = [];
    Object.defineProperty(HTMLElement.prototype, "animate", { configurable: true, value: function(this: HTMLElement) {
      if (this.matches(".search-row")) animated.push(this);
      return { cancel: vi.fn(), onfinish: null };
    } });
    const first = resultFor("冰樱");
    first.users = { ...first.users!, has_more: true, next_cursor: "u-c1" };
    vi.mocked(searchPages).mockResolvedValueOnce(first).mockResolvedValueOnce({ users: { ...first.users,
      next_cursor: "u-c2", items: [{ ...first.users.items[0], id: "u3", nickname: "第二页用户" }] } })
      .mockResolvedValueOnce({ users: { ...first.users, next_cursor: null, has_more: false,
        items: [{ ...first.users.items[0], id: "u4", nickname: "第三页用户" }] } });
    const { container } = renderSearchControls(true);
    await screen.findByText("小樱");
    fireEvent.click(screen.getByRole("button", { name: "加载更多用户" }));
    await screen.findByText("第二页用户");
    expect(animated).toHaveLength(3);
    const scroll = container.querySelector<HTMLElement>(".search-content")!;
    scroll.scrollTop = 420;
    fireEvent.scroll(scroll);
    fireEvent.click(screen.getByRole("button", { name: "打开详情" }));
    await screen.findByText("详情内容");
    fireEvent.click(screen.getByRole("button", { name: "返回搜索" }));
    await screen.findByText("第二页用户");
    expect(searchPages).toHaveBeenCalledTimes(2);
    expect(container.querySelector<HTMLElement>(".search-content")!.scrollTop).toBe(420);
    expect(animated).toHaveLength(3);
    fireEvent.click(screen.getByRole("button", { name: "加载更多用户" }));
    await screen.findByText("第三页用户");
    expect(searchPages).toHaveBeenLastCalledWith({ q: "冰樱", types: ["user"], limit: 20, cursor: "u-c2" });
    expect(animated).toHaveLength(4);
  });
});

afterEach(() => {
  if (originalAnimate) Object.defineProperty(HTMLElement.prototype, "animate", originalAnimate);
  else Reflect.deleteProperty(HTMLElement.prototype, "animate");
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("SearchPage 顶栏复用（F9）", () => {
  it("SearchPage 内不渲染 NarrowTopBar（顶栏已抽取到 AppShell，含搜索输入态）", () => {
    renderSearch("/search", true);
    expect(screen.queryByRole("textbox", { name: "全局搜索" })).toBeNull();
    expect(screen.queryByRole("button", { name: "返回" })).toBeNull();
  });

  it("URL ?q= 直接进入 → 自动搜索并显示结果", async () => {
    renderSearch("/search?q=冰樱", true);
    await waitFor(() => {
      expect(screen.getByText("小樱")).toBeInTheDocument();
    });
    expect(searchPages).toHaveBeenCalledWith(expect.objectContaining({ q: "冰樱" }));
  });

  it("用户头像与详情是并列入口，无嵌套button，点击各自保留原行为", async () => {
    renderSearch("/search?q=冰樱", true);
    const avatar = await screen.findByRole("button", { name: "查看 小樱 的个人主页" });
    const row = avatar.closest(".search-user-row")!;
    expect(row.tagName).toBe("DIV");
    expect(row.querySelector("button button")).toBeNull();
    const main = screen.getByRole("button", { name: "小樱" });
    expect(main.parentElement).toBe(row);
    expect(avatar.parentElement).toBe(row);
    fireEvent.click(avatar);
    expect(goUserProfile).toHaveBeenCalledWith("u1", "u2");
    expect(screen.queryByRole("dialog", { name: "小樱 资料" })).not.toBeInTheDocument();
    fireEvent.click(main);
    expect(screen.getByRole("dialog", { name: "小樱 资料" })).toBeInTheDocument();
    expect(goUserProfile).toHaveBeenCalledTimes(1);
  });

  it("群结果使用返回的真实头像，加载失败回退首字且仍可申请入群", async () => {
    const result = groupResult("application");
    result.groups.items[0].avatar = "/api/v1/media/search-group-avatar/content";
    vi.mocked(searchPages).mockResolvedValue(result);
    renderSearch("/search?q=冰樱", false);

    const row = await screen.findByRole("button", { name: /冰樱研究所/ });
    await waitFor(() => expect(row.querySelector("img")).toHaveAttribute("src", "/fixtures/signed-group-avatar.png"));
    expect(getSignedMediaUrl).toHaveBeenCalledWith("search-group-avatar", undefined);
    expect(row.querySelector("button")).toBeNull();

    fireEvent.error(row.querySelector("img")!);
    expect(row.querySelector(".avatar-core")).toHaveTextContent("冰");
    expect(row.querySelector("img")).toBeNull();
    fireEvent.click(row);
    expect(screen.getByRole("dialog", { name: "申请加入「冰樱研究所」" })).toBeInTheDocument();
  });

  it.each([undefined, ""])("旧响应或空头像 %s 显示群名首字", async (avatar) => {
    const result = groupResult("public");
    if (avatar !== undefined) result.groups.items[0].avatar = avatar;
    vi.mocked(searchPages).mockResolvedValue(result);
    renderSearch("/search?q=冰樱", true);

    const row = await screen.findByRole("button", { name: /冰樱研究所/ });
    expect(row.querySelector(".avatar-core")).toHaveTextContent("冰");
    expect(row.querySelector("img")).toBeNull();
    expect(getSignedMediaUrl).not.toHaveBeenCalled();
  });

  it("历史 chips 点击 → 更新 URL q 并触发搜索", async () => {
    useSearchStore.setState({ history: ["冰樱", "爱莉"] });
    renderSearch("/search", true);
    fireEvent.click(screen.getByRole("button", { name: "冰樱" }));
    await waitFor(() => {
      expect(screen.getByText("小樱")).toBeInTheDocument();
    });
    expect(searchPages).toHaveBeenCalledWith(expect.objectContaining({ q: "冰樱" }));
  });

  it("有结果后点击「清空」移除历史（无 q 态回到历史空）", async () => {
    useSearchStore.setState({ history: ["冰樱"] });
    renderSearch("/search", true);
    fireEvent.click(screen.getByRole("button", { name: "清空" }));
    expect(useSearchStore.getState().history).toEqual([]);
  });

  it("五类分组全空时显示「未找到」空态（不空白）", async () => {
    vi.mocked(searchPages).mockResolvedValue({
      users: { next_cursor: null, has_more: false, total: 0, items: [] },
      groups: { next_cursor: null, has_more: false, total: 0, items: [] },
      posts: { next_cursor: null, has_more: false, total: 0, items: [] },
      lives: { next_cursor: null, has_more: false, total: 0, items: [] },
      games: { next_cursor: null, has_more: false, total: 0, items: [] },
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
    vi.mocked(searchPages).mockResolvedValue(groupResult("public"));
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
    vi.mocked(searchPages).mockResolvedValue(groupResult());
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
