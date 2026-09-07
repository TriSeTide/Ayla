/**
 * GroupVoice 测试（F5 R-G8）：按 groupId 请求服务端白名单过滤后的分页目录。
 * mock voiceApi.listVoiceChannelsPage + VoiceChannelPanel/useVoiceChannel 的媒体链不触发
 * （列表态 currentChannelId=null，join 才触发）。
 * 房内态：mock VoiceRoomBody 为 onLeave 桩，聚焦 GroupVoice 的 handleLeave
 * （房主离开被拦截 / 非房主正常离开）。
 */
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MemoryRouter, Route, Routes, useParams } from "react-router-dom";
import * as voiceApi from "../api/voice";
import type { UserPublic, VoiceChannelDescriptor } from "../api/types";
import { useAuthStore } from "../stores/auth";
import { useVoiceStore } from "../stores/voice";
import { GroupVoice } from "../pages/group/GroupVoice";
import { disposeDirectoryTracking } from "../stores/directory";

vi.mock("../api/voice", () => ({
  listVoiceChannels: vi.fn(),
  listVoiceChannelsPage: vi.fn(),
  getVoiceChannel: vi.fn(),
  listVoiceChannelMembers: vi.fn(),
  joinVoiceChannel: vi.fn(),
  leaveVoiceChannel: vi.fn(),
  heartbeatVoiceChannel: vi.fn(),
  createVoiceChannel: vi.fn(),
  listVoiceChatMessagesPage: vi.fn().mockResolvedValue({ results: [], next_cursor: null, has_more: false, total: 0 }),
  sendVoiceChatMessage: vi.fn(),
}));
const originalAnimate = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "animate");
let animatedCards: Array<{ node: HTMLElement; delay: number | undefined }>;

vi.mock("../api/elysia", () => ({
  getElysiaProfile: vi.fn().mockResolvedValue({ enabled: false, user: null }),
}));

vi.mock("../components/voice/VoiceRoomBody", () => ({
  VoiceRoomBody: (props: { channelName: string; onLeave: () => void; onRejoin: () => void; livekit: string; connectionError?: string | null }) => (
    <div>
      <span>{props.channelName}</span>
      <button type="button" onClick={props.onLeave}>
        离开频道
      </button>
      {props.connectionError && <div role="alert">{props.connectionError}</div>}
      {props.livekit === "failed" && <button type="button" onClick={props.onRejoin}>重新加入</button>}
    </div>
  ),
}));

const SELF: UserPublic = {
  id: "o1",
  username: "me",
  nickname: "我",
  avatar: "",
  signature: "",
  status: "online",
  online: true,
  date_joined: "2026-01-01T00:00:00Z",
};

function ch(id: string, group: string | null, name = id): VoiceChannelDescriptor {
  return {
    id,
    name,
    room_name: `room_${id}`,
    owner_id: "o1",
    member_count: 1,
    visibility: group ? "group" : "public",
    group,
    group_name: group ? "目标群" : null,
    allowed_group_ids: group ? [group] : [],
    mine: false,
    created_at: "2026-01-01T00:00:00Z",
  };
}

function mockChannels(channels: VoiceChannelDescriptor[]) {
  vi.mocked(voiceApi.listVoiceChannels).mockResolvedValue(channels);
  vi.mocked(voiceApi.listVoiceChannelsPage).mockImplementation(async (params) => {
    const results = channels.filter((item) => !params?.groupId || (item.allowed_group_ids ?? []).includes(params.groupId));
    return { results, next_cursor: null, has_more: false, total: results.length, total_member_count: results.reduce((sum, item) => sum + item.member_count, 0) };
  });
  vi.mocked(voiceApi.getVoiceChannel).mockImplementation(async (id) => {
    const channel = channels.find((item) => item.id === id);
    if (!channel) throw new Error("语音房不存在");
    return channel;
  });
}

beforeEach(() => {
  disposeDirectoryTracking();
  vi.stubGlobal(
    "matchMedia",
    vi.fn((query: string) => ({ matches: query === "(max-width: 768px)", addEventListener: vi.fn(), removeEventListener: vi.fn() })),
  );
  useVoiceStore.getState().reset();
  useAuthStore.setState({ currentUser: null, accessToken: "group-voice-session" });
  vi.mocked(voiceApi.joinVoiceChannel).mockReset().mockRejectedValue(new Error("测试隔离媒体连接"));
  vi.mocked(voiceApi.leaveVoiceChannel).mockReset().mockResolvedValue({ left: true });
  animatedCards = [];
  Object.defineProperty(HTMLElement.prototype, "animate", { configurable: true, value: function(this: HTMLElement, _frames: Keyframe[], options: KeyframeAnimationOptions) {
    if (this.matches(".voice-channel-card-wrap")) animatedCards.push({ node: this, delay: options.delay });
    return { cancel: vi.fn(), onfinish: null };
  } });
});

afterEach(() => {
  cleanup();
  disposeDirectoryTracking();
  vi.unstubAllGlobals();
  vi.clearAllMocks();
  useVoiceStore.getState().reset();
  useAuthStore.setState({ currentUser: null, accessToken: null });
  if (originalAnimate) Object.defineProperty(HTMLElement.prototype, "animate", originalAnimate);
  else Reflect.deleteProperty(HTMLElement.prototype, "animate");
});

describe("GroupVoice 范围（仅该群）", () => {
  it("直达房间先等详情和本群白名单确认，再且仅调用一次 join", async () => {
    let finishDetail!: (channel: VoiceChannelDescriptor) => void;
    const detail = new Promise<VoiceChannelDescriptor>((resolve) => { finishDetail = resolve; });
    vi.mocked(voiceApi.getVoiceChannel).mockReturnValue(detail);
    // 此测试只验证授权完成后的选择边界，REST 失败阻止媒体连接。
    vi.mocked(voiceApi.joinVoiceChannel).mockRejectedValue(new Error("测试隔离媒体连接"));
    render(<MemoryRouter><GroupVoice groupId="g1" routeChannelId="deferred" onExit={vi.fn()} /></MemoryRouter>);
    await waitFor(() => expect(voiceApi.getVoiceChannel).toHaveBeenCalledWith("deferred"));
    expect(voiceApi.joinVoiceChannel).not.toHaveBeenCalled();
    expect(screen.queryByRole("button", { name: "离开频道" })).not.toBeInTheDocument();
    await act(async () => { finishDetail(ch("deferred", "g1", "已确认的语音房")); await detail; });
    await waitFor(() => expect(voiceApi.joinVoiceChannel).toHaveBeenCalledWith("deferred"));
    expect(voiceApi.joinVoiceChannel).toHaveBeenCalledTimes(1);
    act(() => useVoiceStore.getState().patchChannel("deferred", { name: "已确认的语音房更新" }));
    expect(voiceApi.joinVoiceChannel).toHaveBeenCalledTimes(1);
  });

  it("直达详情不在本群 allowed_group_ids 中时显示错误且绝不 join", async () => {
    vi.mocked(voiceApi.getVoiceChannel).mockResolvedValue(ch("foreign", "other", "别群语音房"));
    render(<MemoryRouter><GroupVoice groupId="g1" routeChannelId="foreign" onExit={vi.fn()} /></MemoryRouter>);
    expect(await screen.findByText("该语音房不在本群可见范围内")).toBeInTheDocument();
    expect(voiceApi.joinVoiceChannel).not.toHaveBeenCalled();
    expect(screen.queryByRole("button", { name: "离开频道" })).not.toBeInTheDocument();
    expect(useVoiceStore.getState().channels.some((channel) => channel.id === "foreign")).toBe(false);
  });

  it("目标房加入失败显示可重试错误，重试绑定路由房而非仍连接的旧房", async () => {
    mockChannels([ch("A", "g1", "旧房"), ch("B", "g1", "目标房")]);
    useVoiceStore.setState({ channels: [ch("A", "g1"), ch("B", "g1", "目标房")], currentChannelId: "A", livekit: "connected" });
    vi.mocked(voiceApi.joinVoiceChannel).mockRejectedValue(new Error("目标房加入失败"));
    render(<MemoryRouter><GroupVoice groupId="g1" routeChannelId="B" onExit={vi.fn()} /></MemoryRouter>);
    expect(await screen.findByRole("alert")).toHaveTextContent("目标房加入失败");
    expect(useVoiceStore.getState().currentChannelId).toBe("A");
    fireEvent.click(screen.getByRole("button", { name: "重新加入" }));
    await waitFor(() => expect(voiceApi.joinVoiceChannel).toHaveBeenCalledTimes(2));
    expect(vi.mocked(voiceApi.joinVoiceChannel).mock.calls).toEqual([["B"], ["B"]]);
  });

  it("请求本群分页目录，只展示服务端返回的本群语音房", async () => {
    mockChannels([
      ch("v1", "g1", "本群语音"),
      ch("v2", "g1", "本群语音2"),
      ch("v3", null, "公开语音"),
      ch("v4", "g9", "其它群"),
    ]);
    render(<MemoryRouter><GroupVoice groupId="g1" onExit={vi.fn()} /></MemoryRouter>);
    await waitFor(() => expect(screen.getByText("本群语音")).toBeInTheDocument());
    expect(screen.getByRole("heading", { name: "群内语音房" })).toBeInTheDocument();
    expect(document.querySelector(".group-scene-head")).not.toBeNull();
    expect(screen.getByText("本群语音2")).toBeInTheDocument();
    // 异步首批就绪后由列表 owner 为新增节点播放 stagger。
    const cards = document.querySelectorAll(".voice-channel-card-wrap");
    expect(cards).toHaveLength(2);
    expect(voiceApi.listVoiceChannelsPage).toHaveBeenCalledWith({ groupId: "g1", onlyLive: undefined, limit: 20, cursor: null });
    expect(animatedCards.map((item) => item.node)).toEqual(Array.from(cards));
    expect(animatedCards.map((item) => item.delay)).toEqual([0, 50]);
    expect(screen.queryByText("公开语音")).not.toBeInTheDocument();
    expect(screen.queryByText("其它群")).not.toBeInTheDocument();
  });

  it("多群白名单语音房（group=null + 白名单 13/14/15）出现在每个被选群的群内页", async () => {
    const multi = ch("mv1", null, "多群语音");
    multi.allowed_group_ids = ["13", "14", "15"];
    mockChannels([multi]);
    for (const gid of ["13", "14", "15"]) {
      const { unmount } = render(
        <MemoryRouter><GroupVoice groupId={gid} onExit={vi.fn()} /></MemoryRouter>,
      );
      await waitFor(() => expect(screen.getByText("多群语音")).toBeInTheDocument());
      expect(voiceApi.listVoiceChannelsPage).toHaveBeenCalledWith({ groupId: gid, onlyLive: undefined, limit: 20, cursor: null });
      unmount();
    }
  });

  it("多群白名单语音房不进其它群/公开房混入本群列表", async () => {
    const multi = ch("mv1", null, "多群语音");
    multi.allowed_group_ids = ["13", "14", "15"];
    mockChannels([
      multi,
      ch("vx", "9", "其它群语音"),
      ch("vpub", null, "公开语音"),
    ]);
    render(<MemoryRouter><GroupVoice groupId="13" onExit={vi.fn()} /></MemoryRouter>);
    await waitFor(() => expect(screen.getByText("多群语音")).toBeInTheDocument());
    expect(screen.queryByText("其它群语音")).not.toBeInTheDocument();
    expect(screen.queryByText("公开语音")).not.toBeInTheDocument();
  });

  it("多群白名单语音房在群内 URL 下可进入房内视图", async () => {
    const multi = ch("mv1", null, "多群语音");
    multi.allowed_group_ids = ["13", "14", "15"];
    mockChannels([multi]);
    useVoiceStore.setState({ currentChannelId: "mv1" });
    render(
      <MemoryRouter>
        <GroupVoice groupId="13" routeChannelId="mv1" onExit={vi.fn()} />
      </MemoryRouter>,
    );
    // VoiceRoomBody mock 渲染 channelName + 离开频道按钮 → 房内视图
    await waitFor(() => expect(screen.getByText("多群语音")).toBeInTheDocument());
    expect(screen.getByRole("button", { name: "离开频道" })).toBeInTheDocument();
  });

  it("本群无语音房 → 空态引导", async () => {
    mockChannels([ch("v3", null, "公开语音")]);
    render(<MemoryRouter><GroupVoice groupId="g1" onExit={vi.fn()} /></MemoryRouter>);
    await waitFor(() => expect(screen.getByText("群内还没有语音房")).toBeInTheDocument());
    // 群内建语音房入口在壳层 CreateFAB（shellConfig group-voice handler），空态仅提供返回聊天
    expect(screen.getByRole("button", { name: "返回聊天" })).toBeInTheDocument();
  });

  it("房主点离开频道 → 直接 leave 并离开", async () => {
    mockChannels([ch("v1", "g1", "本群语音")]);
    vi.mocked(voiceApi.leaveVoiceChannel).mockResolvedValue({ left: true });
    useVoiceStore.setState({ currentChannelId: "v1" });
    useAuthStore.setState({ currentUser: SELF });
    // SELF.id === "o1" === 频道 owner_id → 房主；当前行为房主与非房主一样直接 leave，
    // 不弹确认框。用真实路由渲染：navigate 回列表（无 :voiceChannelId 段）后房内态消失
    function RouteGroupVoice() {
      const { id, voiceChannelId } = useParams<{ id: string; voiceChannelId?: string }>();
      return <GroupVoice groupId={id ?? ""} routeChannelId={voiceChannelId} onExit={vi.fn()} />;
    }
    render(
      <MemoryRouter initialEntries={["/group/g1/voice/v1"]}>
        <Routes>
          <Route path="/group/:id/voice/:voiceChannelId" element={<RouteGroupVoice />} />
        </Routes>
      </MemoryRouter>,
    );
    await waitFor(() => expect(screen.getByText("本群语音")).toBeInTheDocument());

    fireEvent.click(screen.getByRole("button", { name: "离开频道" }));

    await waitFor(() => expect(voiceApi.leaveVoiceChannel).toHaveBeenCalledWith("v1", "group-voice-session"));
    // 已导航回群内语音列表（房内视图消失，离开按钮不再存在）
    await waitFor(() =>
      expect(screen.queryByRole("button", { name: "离开频道" })).not.toBeInTheDocument(),
    );
  });

  it("非房主点离开频道 → 正常调 leave/ 并离开", async () => {
    const confirmSpy = vi.spyOn(window, "confirm").mockReturnValue(true);
    mockChannels([ch("v1", "g1", "本群语音")]);
    vi.mocked(voiceApi.leaveVoiceChannel).mockResolvedValue({ left: true });
    useVoiceStore.setState({ currentChannelId: "v1" });
    useAuthStore.setState({ currentUser: { ...SELF, id: "other" } });
    // 用真实路由渲染：navigate 回列表（无 :voiceChannelId 段）后房内态消失
    function RouteGroupVoice() {
      const { id, voiceChannelId } = useParams<{ id: string; voiceChannelId?: string }>();
      return <GroupVoice groupId={id ?? ""} routeChannelId={voiceChannelId} onExit={vi.fn()} />;
    }
    render(
      <MemoryRouter initialEntries={["/group/g1/voice/v1"]}>
        <Routes>
          <Route path="/group/:id/voice/:voiceChannelId" element={<RouteGroupVoice />} />
        </Routes>
      </MemoryRouter>,
    );
    await waitFor(() => expect(screen.getByText("本群语音")).toBeInTheDocument());

    fireEvent.click(screen.getByRole("button", { name: "离开频道" }));

    expect(confirmSpy).not.toHaveBeenCalled();
    await waitFor(() => expect(voiceApi.leaveVoiceChannel).toHaveBeenCalledWith("v1", "group-voice-session"));
    // 已导航回群内语音列表（房内视图消失，离开按钮不再存在）
    await waitFor(() =>
      expect(screen.queryByRole("button", { name: "离开频道" })).not.toBeInTheDocument(),
    );
    confirmSpy.mockRestore();
  });
});
