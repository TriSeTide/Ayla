import { act, fireEvent, render, renderHook, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as liveApi from "../api/live";
import * as voiceApi from "../api/voice";
import * as gameApi from "../api/boardgame";
import type { GameRoom, LiveChannelDescriptor } from "../api/types";
import { useOwnedLiveDirectory } from "../hooks/useOwnedLiveDirectory";
import { useDanmaku } from "../hooks/useDanmaku";
import { useAuthStore } from "../stores/auth";
import { useLiveStore } from "../stores/live";
import { useVoiceStore } from "../stores/voice";
import { VoiceChannelPanel } from "../components/voice/VoiceChannelPanel";
import { GameRoomPlaceholder } from "../components/boardgame/GameRoomPlaceholder";

const events = vi.hoisted(() => ({ chat: new Set<(frame: any) => void>(), voice: new Set<(frame: any) => void>() }));
vi.mock("../ws/chat", () => ({ chatWS: { onFrame: (handler: (frame: any) => void) => { events.chat.add(handler); return () => events.chat.delete(handler); } } }));
vi.mock("../ws/voice", () => ({ voiceWS: { onFrame: (handler: (frame: any) => void) => { events.voice.add(handler); return () => events.voice.delete(handler); } } }));
vi.mock("../api/live", () => ({ listLiveChannelsPage: vi.fn(), listDanmakuPage: vi.fn(), sendDanmaku: vi.fn() }));
vi.mock("../api/voice", () => ({ listVoiceChannelMembersPage: vi.fn(), actionVoiceMember: vi.fn() }));
vi.mock("../api/boardgame", () => ({ listGameRoomMembersPage: vi.fn(), actionGameMember: vi.fn() }));
vi.mock("../runtime/liveSessionRuntime", () => ({ liveSessionRuntime: { onHistoryInvalidated: vi.fn(() => () => {}) } }));
vi.mock("../components/FavoriteButton", () => ({ FavoriteButton: () => null }));
vi.mock("../components/voice/VoiceControls", () => ({ VoiceControls: () => null }));
vi.mock("../components/voice/VoiceMemberRow", () => ({ VoiceMemberRow: ({ member }: any) => <span>{member.user_id}:{member.volume}</span> }));

function channel(id: number, owner = "me"): LiveChannelDescriptor {
  return { id, owner_id: owner, title: `room ${id}`, status: "idle", created_at: "2026-09-08T00:00:00Z", started_at: null, ended_at: null } as LiveChannelDescriptor;
}
function paged<T>(results: T[], cursor: string | null = null, total = results.length) {
  return { results, next_cursor: cursor, has_more: cursor !== null, total };
}
const member = (id: number) => ({ id, user_id: `u${id}`, joined_at: "2026-09-08T00:00:00Z", last_seen_at: "2026-09-08T00:00:00Z" });
const danmaku = (id: number) => ({ id: String(id), content: `d${id}`, created_at: "2026-09-08T00:00:00Z", media_id: null,
  sender: { user_id: "viewer", nickname: "viewer", avatar: "" } });

beforeEach(() => {
  vi.clearAllMocks();
  useAuthStore.setState({ currentUser: { id: "me" } as never });
  useLiveStore.getState().reset(); useVoiceStore.getState().reset();
});
afterEach(() => { events.chat.clear(); events.voice.clear(); });

describe("owned live directory", () => {
  it("filters owner before paging and never treats the global store as a complete catalog", async () => {
    useLiveStore.getState().setChannels([channel(90, "someone")]);
    vi.mocked(liveApi.listLiveChannelsPage).mockResolvedValueOnce(paged([channel(1)], "next", 2))
      .mockResolvedValueOnce(paged([channel(2)], null, 2));
    const { result } = renderHook(() => useOwnedLiveDirectory());
    await waitFor(() => expect(result.current.loaded).toBe(true));
    expect(liveApi.listLiveChannelsPage).toHaveBeenCalledWith({ owner: "me", cursor: null, limit: 20 });
    await act(() => result.current.loadMore());
    expect(result.current.items.map((row) => row.id)).toEqual([1, 2]);
  });

  it("deletion during an in-flight next page cannot revive the deleted room", async () => {
    let resolve!: (value: ReturnType<typeof paged<LiveChannelDescriptor>>) => void;
    vi.mocked(liveApi.listLiveChannelsPage).mockResolvedValueOnce(paged([channel(1)], "next", 2))
      .mockImplementationOnce(() => new Promise((yes) => { resolve = yes; }));
    const { result } = renderHook(() => useOwnedLiveDirectory());
    await waitFor(() => expect(result.current.loaded).toBe(true));
    act(() => { void result.current.loadMore(); });
    act(() => { events.chat.forEach((emit) => emit({ type: "live.channel.deleted", data: { channel_id: 1 } })); });
    await act(async () => resolve(paged([channel(1), channel(2)])));
    expect(result.current.items).toEqual([]);
    expect(result.current.invalidated).toBe(true);
    expect(result.current.error).toContain("已更新");
  });
});

describe("visible member pages", () => {
  it("voice rows page separately from the complete runtime count and keep local volume", async () => {
    const runtimeMembers = Array.from({ length: 23 }, (_, index) => ({ ...member(index + 1), muted: false, volume: 70, locallyMuted: false, audioLevel: 0 }));
    useVoiceStore.getState().enterChannel("v1", runtimeMembers);
    vi.mocked(voiceApi.listVoiceChannelMembersPage).mockResolvedValueOnce(paged([member(1)], "next", 23))
      .mockResolvedValueOnce(paged([member(23)], null, 23));
    render(<VoiceChannelPanel channelId="v1" channelName="room" ownerId="me" livekit="connected" elysiaProfile={null}
      onToggleMic={vi.fn()} onLeave={vi.fn()} onRejoin={vi.fn()} onVolumeChange={vi.fn()} onLocalVolumeChange={vi.fn()} onToggleMemberMuted={vi.fn()} />);
    await waitFor(() => expect(screen.getByText("u1:70")).toBeInTheDocument());
    expect(screen.getByText("23 人")).toBeInTheDocument();
    expect(screen.queryByText("u23:70")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "加载更多" }));
    await waitFor(() => expect(screen.getByText("u23:70")).toBeInTheDocument());
    expect(Object.keys(useVoiceStore.getState().members)).toHaveLength(23);
  });

  it("keeps the self row visible when the first page omits it (≥20 members or join race)", async () => {
    const runtimeMembers = Array.from({ length: 23 }, (_, index) => ({ ...member(index + 1), muted: false, volume: 70, locallyMuted: false, audioLevel: 0 }));
    // 自己也在频道里（store 对账含自己，joined_at 最新排最后）
    runtimeMembers.push({ ...member(99), user_id: "me", muted: false, volume: 100, locallyMuted: false, audioLevel: 0 });
    useVoiceStore.getState().enterChannel("v1", runtimeMembers);
    // 第一页不含自己（自己排最后）；强制刷新后第一页仍不含自己（≥20 人场景）
    vi.mocked(voiceApi.listVoiceChannelMembersPage)
      .mockResolvedValueOnce(paged([member(1)], "next", 24))
      .mockResolvedValueOnce(paged([member(1)], "next", 24));
    render(<VoiceChannelPanel channelId="v1" channelName="room" ownerId="me" livekit="connected" elysiaProfile={null}
      onToggleMic={vi.fn()} onLeave={vi.fn()} onRejoin={vi.fn()} onVolumeChange={vi.fn()} onLocalVolumeChange={vi.fn()} onToggleMemberMuted={vi.fn()} />);
    await waitFor(() => expect(screen.getByText("u1:70")).toBeInTheDocument());
    // 自己不在第一页也必须可见（渲染兜底置顶）
    expect(screen.getByText("me:100")).toBeInTheDocument();
    // 进入房间后强制刷新一次成员列表
    await waitFor(() => expect(voiceApi.listVoiceChannelMembersPage).toHaveBeenCalledTimes(2));
  });

  it("game ownership actions can address a member outside the embedded preview", async () => {
    const room = { id: "g1", name: "game", is_owner: true, owner_id: "me", owner: { username: "owner" },
      is_member: true, member_count: 23, members: [], created_at: "" } as unknown as GameRoom;
    const gm = (id: number) => ({ ...member(id), id: String(id), room_id: "g1", seat: id, user: { id: `u${id}`, username: `user ${id}` } });
    vi.mocked(gameApi.listGameRoomMembersPage).mockResolvedValueOnce(paged([gm(1)] as never[], "next", 23))
      .mockResolvedValueOnce(paged([gm(23)] as never[], null, 23)).mockResolvedValueOnce(paged([gm(1)] as never[], null, 22));
    vi.mocked(gameApi.actionGameMember).mockResolvedValue({ ...room, member_count: 22 });
    render(<GameRoomPlaceholder room={room} onLeave={vi.fn()} onBack={vi.fn()} />);
    await waitFor(() => expect(screen.getByText("user 1")).toBeInTheDocument());
    fireEvent.click(screen.getByRole("button", { name: "加载更多" }));
    await waitFor(() => expect(screen.getByText("user 23")).toBeInTheDocument());
    const row = screen.getByText("user 23").parentElement!;
    fireEvent.click(row.querySelector("button")!);
    await waitFor(() => expect(gameApi.actionGameMember).toHaveBeenCalledWith("g1", "u23", "kick"));
    await waitFor(() => expect(screen.queryByText("user 23")).not.toBeInTheDocument());
  });

  it("switching game rooms accepts the new first page and discards a late old-room page", async () => {
    const room = { id: 1, name: "game one", is_owner: true, owner_id: "me", owner: { username: "owner" },
      is_member: true, member_count: 21, members: [], created_at: "" } as unknown as GameRoom;
    const gm = (id: number, roomId: number) => ({ ...member(id), id: String(id), room_id: roomId, seat: id,
      user: { id: `u${id}`, username: `user ${id}` } });
    let resolveOld!: (value: ReturnType<typeof paged<never>>) => void;
    vi.mocked(gameApi.listGameRoomMembersPage)
      .mockImplementationOnce(() => new Promise((resolve) => { resolveOld = resolve; }))
      .mockResolvedValueOnce(paged([gm(42, 2)] as never[]));
    const { rerender } = render(<GameRoomPlaceholder room={room} onLeave={vi.fn()} onBack={vi.fn()} />);
    await waitFor(() => expect(gameApi.listGameRoomMembersPage).toHaveBeenCalledWith(1, { cursor: null, limit: 20 }));
    rerender(<GameRoomPlaceholder room={{ ...room, id: 2, name: "game two", member_count: 1 }} onLeave={vi.fn()} onBack={vi.fn()} />);
    await waitFor(() => expect(screen.getByText("user 42")).toBeInTheDocument());
    await act(async () => resolveOld(paged([gm(1, 1)] as never[])));
    expect(screen.queryByText("user 1")).not.toBeInTheDocument();
    expect(screen.queryByText("成员列表已更新，请刷新后继续")).not.toBeInTheDocument();
    expect(screen.getByText("user 42")).toBeInTheDocument();
  });
});

describe("danmaku realtime and historical projections", () => {
  it("rejects stale sender callbacks before HTTP after room or account changes", async () => {
    vi.mocked(liveApi.listDanmakuPage).mockResolvedValue(paged([]));
    vi.mocked(liveApi.sendDanmaku).mockResolvedValue(danmaku(1));
    const { result, rerender } = renderHook(({ id }) => useDanmaku(id), { initialProps: { id: 7 } });
    const oldRoomSend = result.current.send;
    rerender({ id: 8 });
    expect(await oldRoomSend("旧房上传结束", "old-media")).toBe(false);
    const oldAccountSend = result.current.send;
    act(() => useAuthStore.setState({ currentUser: { id: "other-account" } as never }));
    expect(await oldAccountSend("旧账号上传结束", "old-media")).toBe(false);
    expect(liveApi.sendDanmaku).not.toHaveBeenCalled();
    await act(async () => { expect(await result.current.send("新房新账号")).toBe(true); });
    expect(liveApi.sendDanmaku).toHaveBeenCalledWith(8, "新房新账号", undefined);
  });

  it("observes a new id even while the runtime queue length stays at 500, and never writes fetched history to it", async () => {
    useLiveStore.getState().setCurrentChannel(channel(7));
    useLiveStore.setState((state) => ({ current: { ...state.current, danmaku: Array.from({ length: 500 }, (_, i) => danmaku(i + 1)) } }));
    vi.mocked(liveApi.listDanmakuPage).mockResolvedValueOnce(paged([danmaku(490)], "old", 600))
      .mockResolvedValueOnce(paged([danmaku(-1)], null, 600));
    const { result } = renderHook(() => useDanmaku(7));
    await waitFor(() => expect(result.current.danmaku.at(-1)?.id).toBe("500"));
    act(() => useLiveStore.getState().appendDanmaku(danmaku(501)));
    await waitFor(() => expect(result.current.danmaku.at(-1)?.id).toBe("501"));
    expect(useLiveStore.getState().current.danmaku).toHaveLength(500);
    await act(() => result.current.history.loadOlder());
    expect(result.current.danmaku[0].id).toBe("-1");
    expect(useLiveStore.getState().current.danmaku.some((row) => row.id === "-1")).toBe(false);
  });
});
