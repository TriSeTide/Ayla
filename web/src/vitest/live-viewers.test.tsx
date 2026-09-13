/**
 * 直播间在看人数 / 在看观众条 / 名单弹层 契约测试（需求）。
 *
 * 覆盖：
 * - `liveViewerBadge`：只在播 + 服务端给出人数时展示，`null`（presence 不可用）不渲染；
 * - `LiveChannelCard` / `LiveChannelRail`：列表项人数角标（群内群外列表共用）；
 * - `LiveViewerStrip`：一排圆形（人数 + 头像 + ……）、整排可点开名单、未知人数不渲染；
 * - `LiveViewerSheet`：宽屏居中 / 窄屏 60% 上滑（同一 CreateSheet 配方）、
 *   行点击跳个人主页、503 明示"读不到"而不是空名单；
 * - live store：`setViewers` / `patchViewerCount` 只作用于目标频道，且不改排序依据；
 * - chat WS `live.viewers.changed`：只 patch 人数，不触发 REST 对账。
 */
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { LiveChannelDescriptor, LiveViewerItem } from "../api/types";
import { LiveChannelCard } from "../components/live/LiveChannelCard";
import { LiveChannelRail } from "../components/live/LiveChannelRail";
import { LiveViewerStrip } from "../components/live/LiveViewerStrip";
import * as liveApi from "../api/live";
import * as navigation from "../utils/navigation";
import { useLiveStore } from "../stores/live";
import { useAuthStore } from "../stores/auth";
import { formatViewerCount, liveViewerBadge } from "../utils/liveViewers";

vi.mock("../api/live", () => ({
  getLiveChannelViewers: vi.fn(),
  // ws/chat.ts 的 live.channel.* 对账路径需要这两个；本测试只发 viewers 帧，不应被调用
  getLiveChannel: vi.fn(),
  getLiveChannelStatus: vi.fn(),
}));
vi.mock("../api/elysia", () => ({
  getElysiaProfile: vi.fn().mockResolvedValue({ enabled: false, user: null }),
}));
vi.mock("../utils/navigation", () => ({
  goUserProfile: vi.fn(),
  navigateTo: vi.fn(),
  registerNavigate: vi.fn(),
}));
// chat WS 连接会拉徽标/订阅基线：mock 掉，保持测试自洽（与 ws-chat.test.ts 同款）
vi.mock("../api/accounts", () => ({
  getBadges: vi.fn().mockResolvedValue({
    private_unread: 0,
    group_unread: 0,
    friend_requests: 0,
    group_invites: 0,
    join_requests_pending: 0,
  }),
}));
vi.mock("../api/chat", () => ({
  getGroupPresence: vi.fn().mockResolvedValue({ presences: {} }),
  listConversationSubscriptionsPage: vi
    .fn()
    .mockResolvedValue({ results: [], total: 0, has_more: false, next_cursor: null }),
  getConversationSummary: vi.fn().mockRejectedValue(new Error("fixture unknown")),
  markMessageRead: vi.fn().mockResolvedValue({ detail: "ok" }),
}));

function liveCh(overrides: Partial<LiveChannelDescriptor> = {}): LiveChannelDescriptor {
  return {
    id: 1,
    title: "直播间",
    status: "live",
    visibility: "public",
    group: null,
    group_name: null,
    owner_id: "u1",
    owner_nickname: "主播",
    is_owner: false,
    stream_key: null,
    rtmp_url: null,
    hls_url: "hls://1",
    flv_url: "flv://1",
    started_at: null,
    ended_at: null,
    created_at: "2026-01-01T00:00:00Z",
    ...overrides,
  };
}

const watchers: LiveViewerItem[] = [
  { user_id: "u1", nickname: "小冰", avatar: "" },
  { user_id: "u2", nickname: "小樱", avatar: "" },
];

beforeEach(() => {
  vi.mocked(liveApi.getLiveChannelViewers).mockResolvedValue({
    channel_id: 1,
    count: 2,
    has_more: false,
    viewers: watchers,
  });
  useLiveStore.getState().reset();
  useAuthStore.setState({ currentUser: null });
});

afterEach(() => {
  vi.clearAllMocks();
});

describe("liveViewerBadge 语义", () => {
  it("只在播 + 人数可读时给数值；未知不回落为 0", () => {
    expect(liveViewerBadge({ status: "live", viewer_count: 3 })).toBe(3);
    expect(liveViewerBadge({ status: "live", viewer_count: 0 })).toBe(0);
    // presence 存储不可用 → null（读不到 ≠ 没人看）
    expect(liveViewerBadge({ status: "live", viewer_count: null })).toBeNull();
    expect(liveViewerBadge({ status: "live" })).toBeNull();
    // 未在播的房间不算"在看直播"
    expect(liveViewerBadge({ status: "idle", viewer_count: 3 })).toBeNull();
    expect(liveViewerBadge({ status: "ended", viewer_count: 3 })).toBeNull();
  });

  it("大数用紧凑写法，不截断语义", () => {
    expect(formatViewerCount(0)).toBe("0");
    expect(formatViewerCount(999)).toBe("999");
    expect(formatViewerCount(1200)).toBe("1.2k");
    expect(formatViewerCount(53000)).toBe("53k");
  });
});

describe("直播列表项人数角标（群内群外列表共用）", () => {
  it("大厅卡片：在播且有读数时显示小人图标 + 数字", () => {
    render(<LiveChannelCard channel={liveCh({ viewer_count: 12 })} onEnter={vi.fn()} />);
    expect(screen.getByLabelText("12 人在看")).toBeInTheDocument();
  });

  it("大厅卡片：0 人是真实读数照常显示；未知 / 未在播不显示", () => {
    const { unmount } = render(
      <LiveChannelCard channel={liveCh({ viewer_count: 0 })} onEnter={vi.fn()} />,
    );
    expect(screen.getByLabelText("0 人在看")).toBeInTheDocument();
    unmount();

    const unknown = render(
      <LiveChannelCard channel={liveCh({ viewer_count: null })} onEnter={vi.fn()} />,
    );
    expect(screen.queryByLabelText(/人在看/)).toBeNull();
    unknown.unmount();

    render(
      <LiveChannelCard channel={liveCh({ status: "idle", viewer_count: 5 })} onEnter={vi.fn()} />,
    );
    expect(screen.queryByLabelText(/人在看/)).toBeNull();
  });

  it("侧栏直播项：标题右侧显示人数", () => {
    render(
      <LiveChannelRail
        channels={[liveCh({ id: 2, title: "第二场", viewer_count: 7 })]}
        currentId={2}
        onSelect={vi.fn()}
        collapsed={false}
        onToggle={vi.fn()}
        onBack={vi.fn()}
        showBack
      />,
    );
    expect(screen.getByLabelText("7 人在看")).toBeInTheDocument();
  });
});

describe("LiveViewerStrip（视频下方在看观众条）", () => {
  it("渲染人数 + 头像 + 三圆点「更多」，整排可点开名单", async () => {
    const { container } = render(
      <LiveViewerStrip channelId={1} count={2} viewers={watchers} />,
    );
    const strip = screen.getByRole("button", { name: "正在观看 2 人，查看完整名单" });
    expect(strip).toBeInTheDocument();
    expect(container.querySelector(".live-viewer-strip-num")?.textContent).toBe("2");
    // 头像复用现有 Avatar 组件（在线光环）
    expect(container.querySelectorAll(".live-viewer-strip-avatars .avatar-halo")).toHaveLength(2);
    // 排尾是经典「更多」三圆点图标按钮（不是文本省略号）
    const more = container.querySelector(".live-viewer-strip-more");
    expect(more?.querySelector("svg")).not.toBeNull();
    expect(more?.textContent).toBe("");

    fireEvent.click(strip);
    expect(await screen.findByRole("dialog", { name: "正在观看 · 2 人" })).toBeInTheDocument();
  });

  it("人数未知仍占位（高度恒定，禁止画面跳变）：显示 –，不冒充 0", () => {
    const { container } = render(
      <LiveViewerStrip channelId={1} count={null} viewers={[]} />,
    );
    const strip = container.querySelector(".live-viewer-strip");
    expect(strip).not.toBeNull();
    expect(strip?.classList.contains("is-unknown")).toBe(true);
    expect(container.querySelector(".live-viewer-strip-num")?.textContent).toBe("–");
    expect(container.querySelectorAll(".live-viewer-strip-avatars .avatar-halo")).toHaveLength(0);
  });

  it("0 人是真实读数：显示 0，无头像，仍有「更多」入口", () => {
    const { container } = render(
      <LiveViewerStrip channelId={1} count={0} viewers={[]} />,
    );
    expect(container.querySelector(".live-viewer-strip-num")?.textContent).toBe("0");
    expect(container.querySelectorAll(".live-viewer-strip-avatars .avatar-halo")).toHaveLength(0);
    expect(container.querySelector(".live-viewer-strip-more svg")).not.toBeNull();
  });

  it("纯展示：本组件不自行拉数据（进房快照由 liveSessionRuntime 写入 store）", () => {
    render(<LiveViewerStrip channelId={1} count={2} viewers={watchers} />);
    expect(liveApi.getLiveChannelViewers).not.toHaveBeenCalled();
  });

  it("人数未知时也不请求：未知 ≠ 0 人在看", () => {
    render(<LiveViewerStrip channelId={1} count={null} viewers={[]} />);
    expect(liveApi.getLiveChannelViewers).not.toHaveBeenCalled();
  });
});

describe("LiveViewerSheet（在看名单）", () => {
  it("按权限拉完整名单，渲染头像 + 昵称，点击整行跳个人主页", async () => {
    useAuthStore.setState({ currentUser: { id: "me" } as never });
    render(<LiveViewerStrip channelId={1} count={2} viewers={watchers} />);
    fireEvent.click(screen.getByRole("button", { name: "正在观看 2 人，查看完整名单" }));

    const row = await screen.findByRole("button", { name: "查看 小冰 的个人主页" });
    expect(screen.getByText("小樱")).toBeInTheDocument();

    fireEvent.click(row);
    expect(navigation.goUserProfile).toHaveBeenCalledWith("me", "u1");
    // 点击后关闭弹层
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
  });

  it("名单被上限截断时提示只显示前 N 位", async () => {
    vi.mocked(liveApi.getLiveChannelViewers).mockResolvedValue({
      channel_id: 1,
      count: 200,
      has_more: true,
      viewers: watchers,
    });
    render(<LiveViewerStrip channelId={1} count={200} viewers={watchers} />);
    fireEvent.click(screen.getByRole("button", { name: "正在观看 200 人，查看完整名单" }));
    expect(await screen.findByText("仅显示前 2 位")).toBeInTheDocument();
  });

  it("presence 存储不可用（503）→ 明示读不到并提供重试，不冒充空名单", async () => {
    vi.mocked(liveApi.getLiveChannelViewers).mockRejectedValue(new Error("暂时读不到在看名单"));
    render(<LiveViewerStrip channelId={1} count={1} viewers={[]} />);
    fireEvent.click(screen.getByRole("button", { name: "正在观看 1 人，查看完整名单" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("暂时读不到在看名单");
    expect(screen.queryByText("还没有人在看")).toBeNull();
    expect(screen.getByRole("button", { name: "重试" })).toBeInTheDocument();
  });

  it("弹层挂在 body（portal）：侧栏 backdrop-filter 不裁剪弹层", async () => {
    render(<LiveViewerStrip channelId={1} count={2} viewers={watchers} />);
    fireEvent.click(screen.getByRole("button", { name: "正在观看 2 人，查看完整名单" }));
    const dialog = await screen.findByRole("dialog");
    expect(dialog.closest(".create-sheet-overlay")?.parentElement).toBe(document.body);
    // 名单卡片带专属类（窄屏 60% 高由该类的媒体查询接管）
    expect(dialog.classList.contains("live-viewer-sheet-card")).toBe(true);
  });
});

describe("live store 在看人数投影", () => {
  const other = liveCh({ id: 2, title: "别的房间", status: "idle", viewer_count: 1 });

  it("patchViewerCount：同时更新当前直播间与列表项；不改排序依据", () => {
    useLiveStore.getState().setChannels([liveCh({ id: 1, viewer_count: 1 }), other]);
    useLiveStore.getState().setCurrentChannel(liveCh({ id: 1, viewer_count: 1 }));

    useLiveStore.getState().patchViewerCount(1, 9);
    const state = useLiveStore.getState();
    expect(state.current.viewerCount).toBe(9);
    expect(state.channels.find((c) => c.id === 1)?.viewer_count).toBe(9);
    // 其他频道不受影响
    expect(state.channels.find((c) => c.id === 2)?.viewer_count).toBe(1);
  });

  it("patchViewerCount 不凭空插入未加载的频道", () => {
    useLiveStore.getState().setChannels([other]);
    useLiveStore.getState().patchViewerCount(999, 4);
    expect(useLiveStore.getState().channels).toHaveLength(1);
  });

  it("setViewers 只接受当前直播间的读数（切台竞态防御）", () => {
    useLiveStore.getState().setCurrentChannel(liveCh({ id: 1 }));
    useLiveStore.getState().setViewers(2, 5, watchers);
    expect(useLiveStore.getState().current.viewerCount).toBeNull();

    useLiveStore.getState().setViewers(1, 5, watchers);
    expect(useLiveStore.getState().current.viewerCount).toBe(5);
    expect(useLiveStore.getState().current.viewers).toHaveLength(2);
  });

  it("clearCurrent 复位在看读数", () => {
    useLiveStore.getState().setCurrentChannel(liveCh({ id: 1 }));
    useLiveStore.getState().setViewers(1, 5, watchers);
    useLiveStore.getState().clearCurrent();
    expect(useLiveStore.getState().current.viewerCount).toBeNull();
    expect(useLiveStore.getState().current.viewers).toEqual([]);
  });
});

/* ---------- chat WS：live.viewers.changed 只 patch 人数 ---------- */

type WSInstance = {
  readyState: number;
  send: ReturnType<typeof vi.fn>;
  close: ReturnType<typeof vi.fn>;
  _open: () => void;
  _message: (data: string) => void;
};

let instances: WSInstance[] = [];

class MockWebSocket {
  static OPEN = 1;
  static CONNECTING = 0;
  static CLOSED = 3;
  readyState = MockWebSocket.CONNECTING;
  onopen: (() => void) | null = null;
  onmessage: ((ev: { data: string }) => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;
  send = vi.fn();
  close = vi.fn();
  _open = () => {
    this.readyState = MockWebSocket.OPEN;
    this.onopen?.();
  };
  _message = (data: string) => this.onmessage?.({ data });
  constructor(_url: string) {
    const self = this as unknown as WSInstance;
    instances.push(self);
    setTimeout(() => self._open(), 0);
  }
}

describe("chat WS live.viewers.changed", () => {
  beforeEach(() => {
    instances = [];
    vi.stubGlobal("WebSocket", MockWebSocket);
    vi.useFakeTimers();
    useAuthStore.setState({ accessToken: "acc", refreshToken: "ref", currentUser: null });
    useLiveStore.getState().reset();
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it("只 patch 人数，不触发 REST 对账、不改变列表成员", async () => {
    const getChannel = vi.spyOn(liveApi, "getLiveChannel");
    useLiveStore.getState().setChannels([liveCh({ id: 7, viewer_count: 1 })]);
    useLiveStore.getState().setCurrentChannel(liveCh({ id: 7, viewer_count: 1 }));

    const { ChatWSClient } = await import("../ws/chat");
    const client = new ChatWSClient();
    client.connect();
    vi.runOnlyPendingTimers();
    instances[0]._message(
      JSON.stringify({ type: "live.viewers.changed", data: { channel_id: 7, viewer_count: 6 } }),
    );

    expect(useLiveStore.getState().current.viewerCount).toBe(6);
    expect(useLiveStore.getState().channels[0].viewer_count).toBe(6);
    expect(useLiveStore.getState().channels).toHaveLength(1);
    expect(getChannel).not.toHaveBeenCalled();
    client.disconnect();
  });

  it("未知频道（不可见/未加载）静默忽略", async () => {
    useLiveStore.getState().setChannels([liveCh({ id: 7, viewer_count: 1 })]);
    const { ChatWSClient } = await import("../ws/chat");
    const client = new ChatWSClient();
    client.connect();
    vi.runOnlyPendingTimers();
    instances[0]._message(
      JSON.stringify({ type: "live.viewers.changed", data: { channel_id: 999, viewer_count: 3 } }),
    );
    expect(useLiveStore.getState().channels).toHaveLength(1);
    expect(useLiveStore.getState().channels[0].viewer_count).toBe(1);
    client.disconnect();
  });
});
