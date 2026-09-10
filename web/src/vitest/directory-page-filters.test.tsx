/**
 * 语音/直播/桌游 三个一级页面的分类选项卡契约测试（方案：语音直播帖子桌游-分类选项卡改造）：
 * - tablist 选项与 URL ?type= 同步（与收藏/搜索一致）；
 * - 各 tab 过滤契约（公开/好友/有人/在播/停播/我的/等待中/对局中）；
 *   好友 = 作者是好友（friendIds），非 visibility=friends；
 * - 每 tab 独立加载（filter 进 directory key，切 tab 自动拉取该 tab 第一页）；
 * - tab 切换内容区重挂载（key=scope）+ 各 tab 独立滚动位置（useScrollRestore）；
 * - 侧栏 header 统计（decor 粉色 64px 由 directory-filters.css 统一，此处断言文案）。
 */
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes, useLocation } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as boardgameApi from "../api/boardgame";
import { listLiveChannelsPage } from "../api/live";
import * as usersApi from "../api/users";
import * as voiceApi from "../api/voice";
import type { GameRoom, LiveChannelDescriptor, VoiceChannelDescriptor } from "../api/types";
import { GamesHubPage } from "../pages/GamesHubPage";
import { LiveHubPage } from "../pages/LiveHubPage";
import { VoiceHubPage } from "../pages/VoiceHubPage";
import { useAuthStore } from "../stores/auth";
import { useBoardgameStore } from "../stores/boardgame";
import { useLiveStore } from "../stores/live";
import { useShellStore } from "../stores/shell";
import { useSocialStore } from "../stores/social";
import { useVoiceStore } from "../stores/voice";
import { disposeDirectoryTracking } from "../stores/directory";
import { clearScrollMemory, saveScrollPosition } from "../hooks/useScrollRestore";

/* ---------------- 语音 ---------------- */

vi.mock("../api/elysia", () => ({
  getElysiaProfile: async () => ({ enabled: false, user: null }),
}));
vi.mock("../api/voice", async () => {
  const actual = await vi.importActual<typeof import("../api/voice")>("../api/voice");
  return { ...actual, listVoiceChannelsPage: vi.fn() };
});
vi.mock("../ws/voice", () => ({ voiceWS: { connect: vi.fn(), disconnect: vi.fn() } }));
vi.mock("../hooks/useVoiceChannel", () => ({
  useVoiceChannel: () => ({
    currentChannelId: null,
    livekit: "idle",
    joining: false,
    error: null,
    clearError: vi.fn(),
    join: vi.fn(),
    leave: vi.fn(),
    toggleMic: vi.fn(),
    setMemberVolume: vi.fn(),
    setMemberLocallyMuted: vi.fn(),
    setLocalVolume: vi.fn(),
    resetLocal: vi.fn(),
  }),
}));
vi.mock("../components/voice/VoiceRoomBody", () => ({ VoiceRoomBody: () => null }));
vi.mock("../components/voice/VoiceChannelList", () => ({
  VoiceChannelList: ({ channels }: { channels: VoiceChannelDescriptor[] }) => (
    <div data-testid="voice-hub-list">
      {channels.map((c) => (
        <div key={c.id} className="voice-channel-card-wrap" data-channel-id={c.id}>{c.name}</div>
      ))}
    </div>
  ),
}));

/* ---------------- 直播 ---------------- */

vi.mock("../api/live", () => ({
  listLiveChannelsPage: vi.fn(),
  listLiveChannels: vi.fn(),
}));
vi.mock("../api/users", () => ({
  ensureUser: async () => [],
  listFriendsPage: vi.fn(),
}));
vi.mock("../components/live/LiveHall", () => ({
  LiveHall: ({ channels }: { channels: LiveChannelDescriptor[] }) => (
    <div data-testid="live-hall">
      {channels.map((c) => <span key={c.id} data-channel-id={c.id}>{c.title}</span>)}
    </div>
  ),
}));

/* ---------------- 桌游 ---------------- */

vi.mock("../api/boardgame", () => ({
  listGameRoomsPage: vi.fn(),
  getGameRoom: vi.fn(),
  joinGameRoom: vi.fn(),
}));
vi.mock("../components/FavoriteButton", () => ({ FavoriteButton: () => null }));

/* ---------------- 数据工厂 ---------------- */

function voiceChannel(id: string, name: string, ownerId: string, memberCount: number, visibility: VoiceChannelDescriptor["visibility"]): VoiceChannelDescriptor {
  return {
    id, name, room_name: `room-${id}`, owner_id: ownerId, member_count: memberCount,
    visibility, group: null, group_name: null, mine: false,
    created_at: "2026-01-01T00:00:00Z",
  };
}

function liveChannel(id: number, title: string, ownerId: string, status: LiveChannelDescriptor["status"], visibility: LiveChannelDescriptor["visibility"], isOwner: boolean): LiveChannelDescriptor {
  return {
    id, title, status, owner_id: ownerId, owner_nickname: null, is_owner: isOwner,
    visibility, group: null, group_name: null, stream_key: null, rtmp_url: null,
    hls_url: "", flv_url: "", started_at: null, ended_at: null, created_at: "2026-01-01T00:00:00Z",
  };
}

function gameRoom(id: number, name: string, ownerId: string, visibility: GameRoom["visibility"], status: GameRoom["status"], isOwner: boolean): GameRoom {
  return {
    id, name, owner: {} as GameRoom["owner"], owner_id: ownerId, visibility,
    group: null, group_name: null, allowed_group_ids: [], game_type: "boardgame",
    status, members: [], member_count: 0, is_owner: isOwner, is_member: false,
    created_at: "2026-01-01T00:00:00Z",
  };
}

function LocationProbe() {
  const location = useLocation();
  return <div data-testid="location">{location.search}</div>;
}

function visibleIds(testId: string): string[] {
  return Array.from(document.querySelectorAll(`[data-testid="${testId}"] [data-channel-id]`))
    .map((el) => el.getAttribute("data-channel-id")!);
}

function renderVoice(entry = "/voice") {
  return render(
    <MemoryRouter initialEntries={[entry]}>
      <LocationProbe />
      <Routes>
        <Route path="/voice" element={<VoiceHubPage />} />
        <Route path="/voice/:channelId" element={<VoiceHubPage />} />
      </Routes>
    </MemoryRouter>,
  );
}

function renderLive(entry = "/live") {
  return render(
    <MemoryRouter initialEntries={[entry]}>
      <LocationProbe />
      <Routes>
        <Route path="/live" element={<LiveHubPage />} />
      </Routes>
    </MemoryRouter>,
  );
}

function renderGames(entry = "/games") {
  return render(
    <MemoryRouter initialEntries={[entry]}>
      <LocationProbe />
      <Routes>
        <Route path="/games" element={<GamesHubPage />} />
        <Route path="/games/:roomId" element={<GamesHubPage />} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  disposeDirectoryTracking();
  clearScrollMemory();
  useVoiceStore.getState().reset();
  useLiveStore.getState().reset();
  useBoardgameStore.getState().reset();
  useSocialStore.getState().reset();
  useShellStore.setState({ refreshCallback: null, bottomTabsLeaving: false });
  useAuthStore.setState({
    accessToken: "acc",
    currentUser: {
      id: "u1", username: "alice", nickname: "爱丽丝", avatar: "", signature: "",
      status: "online", online: true, date_joined: "2026-01-01T00:00:00Z",
    },
  });
  // 好友列表：u2 是 u1 的好友（好友 tab = 作者是好友）
  vi.mocked(usersApi.listFriendsPage).mockResolvedValue({
    results: [{ id: 1, user: { id: "u2", username: "bob", nickname: "鲍勃", avatar: "", signature: "", status: "auto", online: false, date_joined: "2026-01-01T00:00:00Z" }, created_at: "2026-01-01T00:00:00Z" }],
    next_cursor: null, has_more: false, total: 1,
  });
});

afterEach(() => {
  cleanup();
  disposeDirectoryTracking();
  vi.clearAllMocks();
  useVoiceStore.getState().reset();
  useLiveStore.getState().reset();
  useBoardgameStore.getState().reset();
  useSocialStore.getState().reset();
  useShellStore.setState({ refreshCallback: null, bottomTabsLeaving: false });
});

describe("VoiceHubPage 分类选项卡", () => {
  // u1=自己，u2=好友，u3=非好友
  const v1 = voiceChannel("v1", "我的公开房", "u1", 2, "public");
  const v2 = voiceChannel("v2", "好友好友房", "u2", 0, "friends");
  const v3 = voiceChannel("v3", "路人公开房", "u3", 0, "public");
  const v4 = voiceChannel("v4", "好友公开房", "u2", 1, "public");

  beforeEach(() => {
    vi.mocked(voiceApi.listVoiceChannelsPage).mockResolvedValue({
      results: [v1, v2, v3, v4], next_cursor: null, has_more: false, total: 4, total_member_count: 3,
    });
  });

  it("五个选项卡齐全；各 tab 过滤契约（公开/好友/有人/我的）", async () => {
    renderVoice();
    await screen.findByTestId("voice-hub-list");
    const tabs = screen.getByRole("tablist", { name: "语音分类" });
    expect(Array.from(tabs.querySelectorAll("[role=tab]")).map((t) => t.textContent)).toEqual(["全部", "公开", "好友", "有人", "我的"]);
    expect(visibleIds("voice-hub-list")).toEqual(["v1", "v2", "v3", "v4"]);

    fireEvent.click(screen.getByRole("tab", { name: "公开" }));
    await waitFor(() => expect(visibleIds("voice-hub-list")).toEqual(["v1", "v3", "v4"]));
    // 好友 = 作者是好友（u2 的 public/friends 都算），非 visibility=friends
    fireEvent.click(screen.getByRole("tab", { name: "好友" }));
    await waitFor(() => expect(visibleIds("voice-hub-list")).toEqual(["v2", "v4"]));
    fireEvent.click(screen.getByRole("tab", { name: "有人" }));
    await waitFor(() => expect(visibleIds("voice-hub-list")).toEqual(["v1", "v4"]));
    fireEvent.click(screen.getByRole("tab", { name: "我的" }));
    await waitFor(() => expect(visibleIds("voice-hub-list")).toEqual(["v1"]));
  });

  it("每 tab 独立加载：切 tab 自动拉取该 tab 第一页，切回缓存不重拉", async () => {
    renderVoice();
    await screen.findByTestId("voice-hub-list");
    expect(voiceApi.listVoiceChannelsPage).toHaveBeenCalledTimes(1);
    fireEvent.click(screen.getByRole("tab", { name: "公开" }));
    await waitFor(() => expect(voiceApi.listVoiceChannelsPage).toHaveBeenCalledTimes(2));
    fireEvent.click(screen.getByRole("tab", { name: "全部" }));
    await waitFor(() => expect(screen.getByRole("tab", { name: "全部" })).toHaveAttribute("aria-selected", "true"));
    // 切回「全部」：缓存命中（60s 内），不重拉
    expect(voiceApi.listVoiceChannelsPage).toHaveBeenCalledTimes(2);
  });

  it("切换 tab 后手动刷新（RefreshFAB 通道）刷新当前 tab 并重播入场动画", async () => {
    const previousAnimate = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "animate");
    const animated: HTMLElement[] = [];
    Object.defineProperty(HTMLElement.prototype, "animate", { configurable: true, value: function (this: HTMLElement) {
      animated.push(this);
      return { cancel: vi.fn(), onfinish: null };
    } });
    try {
      renderVoice();
      await screen.findByTestId("voice-hub-list");
      const callsBefore = vi.mocked(voiceApi.listVoiceChannelsPage).mock.calls.length;
      // 切 tab 前预置「公开」tab 的历史滚动记录 → 切过去后 restoring=true（抑制入场动画）
      const scrollOwner = document.createElement("div");
      scrollOwner.scrollTop = 120;
      saveScrollPosition("voice-hub:public", scrollOwner);
      fireEvent.click(screen.getByRole("tab", { name: "公开" }));
      await waitFor(() => expect(voiceApi.listVoiceChannelsPage).toHaveBeenCalledTimes(callsBefore + 1));
      expect(voiceApi.listVoiceChannelsPage).toHaveBeenLastCalledWith(expect.objectContaining({ visibility: "public" }));
      animated.length = 0;
      await act(async () => { await useShellStore.getState().refreshCallback!(); });
      // restoring=true（命中历史位置）时刷新仍须重播已入场卡片
      expect(animated.map((node) => node.getAttribute("data-channel-id")).filter(Boolean).length)
        .toBeGreaterThan(0);
    } finally {
      if (previousAnimate) Object.defineProperty(HTMLElement.prototype, "animate", previousAnimate);
      else Reflect.deleteProperty(HTMLElement.prototype, "animate");
    }
  });

  it("各 tab 传后端过滤参数（visibility/friends/occupied/owner），不依赖「全部」分页进度", async () => {
    renderVoice();
    await screen.findByTestId("voice-hub-list");
    fireEvent.click(screen.getByRole("tab", { name: "公开" }));
    await waitFor(() => expect(voiceApi.listVoiceChannelsPage).toHaveBeenLastCalledWith(expect.objectContaining({ visibility: "public" })));
    fireEvent.click(screen.getByRole("tab", { name: "好友" }));
    await waitFor(() => expect(voiceApi.listVoiceChannelsPage).toHaveBeenLastCalledWith(expect.objectContaining({ friends: true })));
    fireEvent.click(screen.getByRole("tab", { name: "有人" }));
    await waitFor(() => expect(voiceApi.listVoiceChannelsPage).toHaveBeenLastCalledWith(expect.objectContaining({ occupied: true })));
    fireEvent.click(screen.getByRole("tab", { name: "我的" }));
    await waitFor(() => expect(voiceApi.listVoiceChannelsPage).toHaveBeenLastCalledWith(expect.objectContaining({ owner: "u1" })));
  });

  it("tab 切换写入 URL ?type=；侧栏 header 显示房间/人数统计", async () => {
    renderVoice();
    await screen.findByTestId("voice-hub-list");
    expect(screen.getByText("4 房间在线 · 3 人在聊")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("tab", { name: "有人" }));
    expect(screen.getByTestId("location")).toHaveTextContent("type=occupied");
    fireEvent.click(screen.getByRole("tab", { name: "全部" }));
    expect(screen.getByTestId("location")).toHaveTextContent("");
  });

  it("tab 切换内容区重挂载，各 tab 独立滚动位置", async () => {
    const { container } = renderVoice();
    await screen.findByTestId("voice-hub-list");
    const allScroll = container.querySelector<HTMLElement>(".voice-content")!;
    allScroll.scrollTop = 120;
    fireEvent.scroll(allScroll);
    fireEvent.click(screen.getByRole("tab", { name: "公开" }));
    await waitFor(() => expect(screen.getByRole("tab", { name: "公开" })).toHaveAttribute("aria-selected", "true"));
    const publicScroll = container.querySelector<HTMLElement>(".voice-content")!;
    expect(publicScroll).not.toBe(allScroll);
    expect(publicScroll.scrollTop).toBe(0);
    publicScroll.scrollTop = 60;
    fireEvent.scroll(publicScroll);
    fireEvent.click(screen.getByRole("tab", { name: "全部" }));
    await waitFor(() => expect(screen.getByRole("tab", { name: "全部" })).toHaveAttribute("aria-selected", "true"));
    expect(container.querySelector<HTMLElement>(".voice-content")!.scrollTop).toBe(120);
    fireEvent.click(screen.getByRole("tab", { name: "公开" }));
    await waitFor(() => expect(screen.getByRole("tab", { name: "公开" })).toHaveAttribute("aria-selected", "true"));
    expect(container.querySelector<HTMLElement>(".voice-content")!.scrollTop).toBe(60);
  });
});

describe("LiveHubPage 分类选项卡", () => {
  // u1=自己，u2=好友，u3=非好友
  const l1 = liveChannel(1, "我的在播", "u1", "live", "public", true);
  const l2 = liveChannel(2, "好友停播", "u2", "idle", "friends", false);
  const l3 = liveChannel(3, "路人停播", "u3", "idle", "public", false);
  const l4 = liveChannel(4, "好友在播", "u2", "live", "public", false);

  beforeEach(() => {
    vi.mocked(listLiveChannelsPage).mockResolvedValue({
      results: [l1, l2, l3, l4], next_cursor: null, has_more: false, total: 4,
    });
  });

  it("六个选项卡齐全；各 tab 过滤契约（在播/公开/好友/停播/我的）", async () => {
    renderLive();
    await screen.findByTestId("live-hall");
    const tabs = screen.getByRole("tablist", { name: "直播分类" });
    expect(Array.from(tabs.querySelectorAll("[role=tab]")).map((t) => t.textContent)).toEqual(["全部", "在播", "公开", "好友", "停播", "我的"]);
    expect(visibleIds("live-hall")).toEqual(["1", "2", "3", "4"]);

    fireEvent.click(screen.getByRole("tab", { name: "在播" }));
    await waitFor(() => expect(visibleIds("live-hall")).toEqual(["1", "4"]));
    fireEvent.click(screen.getByRole("tab", { name: "公开" }));
    await waitFor(() => expect(visibleIds("live-hall")).toEqual(["1", "3", "4"]));
    // 好友 = 作者是好友（u2 的 public/friends 都算），非 visibility=friends
    fireEvent.click(screen.getByRole("tab", { name: "好友" }));
    await waitFor(() => expect(visibleIds("live-hall")).toEqual(["2", "4"]));
    fireEvent.click(screen.getByRole("tab", { name: "停播" }));
    await waitFor(() => expect(visibleIds("live-hall")).toEqual(["2", "3"]));
    fireEvent.click(screen.getByRole("tab", { name: "我的" }));
    await waitFor(() => expect(visibleIds("live-hall")).toEqual(["1"]));
  });

  it("「我的」tab 用后端 owner 过滤（owner=当前用户）", async () => {
    renderLive();
    await screen.findByTestId("live-hall");
    fireEvent.click(screen.getByRole("tab", { name: "我的" }));
    await waitFor(() => expect(listLiveChannelsPage).toHaveBeenLastCalledWith(
      expect.objectContaining({ owner: "u1" }),
    ));
  });

  it("各 tab 传后端过滤参数（status/visibility/friends/owner），不依赖「全部」分页进度", async () => {
    renderLive();
    await screen.findByTestId("live-hall");
    fireEvent.click(screen.getByRole("tab", { name: "在播" }));
    await waitFor(() => expect(listLiveChannelsPage).toHaveBeenLastCalledWith(expect.objectContaining({ status: "live" })));
    fireEvent.click(screen.getByRole("tab", { name: "公开" }));
    await waitFor(() => expect(listLiveChannelsPage).toHaveBeenLastCalledWith(expect.objectContaining({ visibility: "public" })));
    fireEvent.click(screen.getByRole("tab", { name: "好友" }));
    await waitFor(() => expect(listLiveChannelsPage).toHaveBeenLastCalledWith(expect.objectContaining({ friends: true })));
    fireEvent.click(screen.getByRole("tab", { name: "停播" }));
    await waitFor(() => expect(listLiveChannelsPage).toHaveBeenLastCalledWith(expect.objectContaining({ status: "offline" })));
    fireEvent.click(screen.getByRole("tab", { name: "我的" }));
    await waitFor(() => expect(listLiveChannelsPage).toHaveBeenLastCalledWith(expect.objectContaining({ owner: "u1" })));
  });

  it("tab 切换写入 URL ?type=；侧栏 header 显示直播间/在播统计", async () => {
    renderLive();
    await screen.findByTestId("live-hall");
    expect(screen.getByText("4 直播间 · 2 在播")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("tab", { name: "停播" }));
    expect(screen.getByTestId("location")).toHaveTextContent("type=offline");
    fireEvent.click(screen.getByRole("tab", { name: "全部" }));
    expect(screen.getByTestId("location")).toHaveTextContent("");
  });
});

describe("GamesHubPage 分类选项卡", () => {
  // u1=自己，u2=好友，u3=非好友
  const g1 = gameRoom(1, "我的等待房", "u1", "public", "waiting", true);
  const g2 = gameRoom(2, "好友对局房", "u2", "friends", "playing", false);
  const g3 = gameRoom(3, "路人对局房", "u3", "public", "playing", false);
  const g4 = gameRoom(4, "好友等待房", "u2", "public", "waiting", false);

  beforeEach(() => {
    vi.mocked(boardgameApi.listGameRoomsPage).mockResolvedValue({
      results: [g1, g2, g3, g4], next_cursor: null, has_more: false, total: 4,
    });
  });

  it("六个选项卡齐全；各 tab 过滤契约（公开/好友/我的/等待中/对局中）", async () => {
    renderGames();
    await screen.findByText("我的等待房");
    const tabs = screen.getByRole("tablist", { name: "桌游分类" });
    expect(Array.from(tabs.querySelectorAll("[role=tab]")).map((t) => t.textContent)).toEqual(["全部", "公开", "好友", "我的", "等待中", "对局中"]);
    expect(screen.getByText("我的等待房")).toBeInTheDocument();
    expect(screen.getByText("好友对局房")).toBeInTheDocument();
    expect(screen.getByText("路人对局房")).toBeInTheDocument();
    expect(screen.getByText("好友等待房")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("tab", { name: "公开" }));
    await waitFor(() => expect(screen.getByText("我的等待房")).toBeInTheDocument());
    expect(screen.queryByText("好友对局房")).not.toBeInTheDocument();
    expect(screen.getByText("路人对局房")).toBeInTheDocument();
    expect(screen.getByText("好友等待房")).toBeInTheDocument();
    // 好友 = 作者是好友（u2 的 public/friends 都算），非 visibility=friends
    fireEvent.click(screen.getByRole("tab", { name: "好友" }));
    await waitFor(() => expect(screen.getByText("好友对局房")).toBeInTheDocument());
    expect(screen.queryByText("我的等待房")).not.toBeInTheDocument();
    expect(screen.queryByText("路人对局房")).not.toBeInTheDocument();
    expect(screen.getByText("好友等待房")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("tab", { name: "我的" }));
    await waitFor(() => expect(screen.getByText("我的等待房")).toBeInTheDocument());
    expect(screen.queryByText("好友对局房")).not.toBeInTheDocument();
    expect(screen.queryByText("路人对局房")).not.toBeInTheDocument();
    expect(screen.queryByText("好友等待房")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("tab", { name: "等待中" }));
    await waitFor(() => expect(screen.getByText("我的等待房")).toBeInTheDocument());
    expect(screen.queryByText("好友对局房")).not.toBeInTheDocument();
    expect(screen.queryByText("路人对局房")).not.toBeInTheDocument();
    expect(screen.getByText("好友等待房")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("tab", { name: "对局中" }));
    await waitFor(() => expect(screen.getByText("好友对局房")).toBeInTheDocument());
    expect(screen.queryByText("我的等待房")).not.toBeInTheDocument();
    expect(screen.queryByText("路人对局房")).toBeInTheDocument();
    expect(screen.queryByText("好友等待房")).not.toBeInTheDocument();
  });

  it("「我的」tab 用后端 owner 过滤（owner=当前用户）", async () => {
    renderGames();
    await screen.findByText("我的等待房");
    fireEvent.click(screen.getByRole("tab", { name: "我的" }));
    await waitFor(() => expect(boardgameApi.listGameRoomsPage).toHaveBeenLastCalledWith(
      expect.objectContaining({ owner: "u1" }),
    ));
  });

  it("各 tab 传后端过滤参数（visibility/friends/status/owner），不依赖「全部」分页进度", async () => {
    renderGames();
    await screen.findByText("我的等待房");
    fireEvent.click(screen.getByRole("tab", { name: "公开" }));
    await waitFor(() => expect(boardgameApi.listGameRoomsPage).toHaveBeenLastCalledWith(expect.objectContaining({ visibility: "public" })));
    fireEvent.click(screen.getByRole("tab", { name: "好友" }));
    await waitFor(() => expect(boardgameApi.listGameRoomsPage).toHaveBeenLastCalledWith(expect.objectContaining({ friends: true })));
    fireEvent.click(screen.getByRole("tab", { name: "等待中" }));
    await waitFor(() => expect(boardgameApi.listGameRoomsPage).toHaveBeenLastCalledWith(expect.objectContaining({ status: "waiting" })));
    fireEvent.click(screen.getByRole("tab", { name: "对局中" }));
    await waitFor(() => expect(boardgameApi.listGameRoomsPage).toHaveBeenLastCalledWith(expect.objectContaining({ status: "playing" })));
    fireEvent.click(screen.getByRole("tab", { name: "我的" }));
    await waitFor(() => expect(boardgameApi.listGameRoomsPage).toHaveBeenLastCalledWith(expect.objectContaining({ owner: "u1" })));
  });

  it("tab 切换写入 URL ?type=；侧栏 header 显示房间统计", async () => {
    renderGames();
    await screen.findByText("我的等待房");
    expect(screen.getByText("4 个房间")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("tab", { name: "对局中" }));
    expect(screen.getByTestId("location")).toHaveTextContent("type=playing");
    fireEvent.click(screen.getByRole("tab", { name: "全部" }));
    expect(screen.getByTestId("location")).toHaveTextContent("");
  });
});
