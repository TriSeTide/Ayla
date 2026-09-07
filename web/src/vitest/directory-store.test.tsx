import { act, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as liveApi from "../api/live";
import * as voiceApi from "../api/voice";
import * as gameApi from "../api/boardgame";
import type { DirectoryPage } from "../api/directory";
import type { ChatServerFrame, LiveChannelDescriptor, VoiceChannelDescriptor } from "../api/types";
import { useDirectoryPage } from "../hooks/useDirectoryPage";
import { directoryKey, disposeDirectoryTracking, loadDirectory, useDirectoryStore } from "../stores/directory";
import { useLiveStore } from "../stores/live";
import { useVoiceStore } from "../stores/voice";
import { useBoardgameStore } from "../stores/boardgame";

const frames = vi.hoisted(() => ({ handlers: new Set<(frame: ChatServerFrame) => void>() }));
vi.mock("../ws/chat", () => ({ chatWS: { onFrame: (handler: (frame: ChatServerFrame) => void) => {
  frames.handlers.add(handler);
  return () => frames.handlers.delete(handler);
} } }));
vi.mock("../api/live", async (original) => ({ ...await original<typeof liveApi>(), listLiveChannelsPage: vi.fn() }));
vi.mock("../api/voice", async (original) => ({ ...await original<typeof voiceApi>(), listVoiceChannelsPage: vi.fn() }));
vi.mock("../api/boardgame", async (original) => ({ ...await original<typeof gameApi>(), listGameRoomsPage: vi.fn() }));

function live(id: number, extra: Partial<LiveChannelDescriptor> = {}): LiveChannelDescriptor {
  return { id, title: `直播${id}`, status: "idle", owner_id: "owner", owner_nickname: null, is_owner: false, visibility: "public",
    group: null, group_name: null, allowed_group_ids: ["1", "2"], stream_key: null, rtmp_url: null,
    hls_url: "", flv_url: "", started_at: null, ended_at: null, created_at: "2026-01-01T00:00:00Z", ...extra };
}
function voice(id: string, count = 1): VoiceChannelDescriptor {
  return { id, name: `语音${id}`, owner_id: "owner", room_name: id, visibility: "public", group: null,
    group_name: null, allowed_group_ids: ["1"], member_count: count, mine: false,
    last_occupied_at: "2026-01-01T00:00:00Z", last_vacant_at: null, created_at: "2026-01-01T00:00:00Z" };
}
function page<T>(results: T[], next_cursor: string | null = null, total = results.length): DirectoryPage<T> {
  return { results, next_cursor, has_more: next_cursor != null, total };
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
const read = (groupId?: string) => useDirectoryStore.getState().records[directoryKey("live", { groupId })];

beforeEach(() => {
  disposeDirectoryTracking();
  useLiveStore.getState().reset();
  useVoiceStore.getState().reset();
  useBoardgameStore.getState().reset();
  vi.clearAllMocks();
  vi.mocked(liveApi.listLiveChannelsPage).mockReset().mockResolvedValue(page([]));
  vi.mocked(voiceApi.listVoiceChannelsPage).mockReset().mockResolvedValue(page([]));
  vi.mocked(gameApi.listGameRoomsPage).mockReset().mockResolvedValue(page([]));
});
afterEach(() => disposeDirectoryTracking());

describe("query-specific bounded directories", () => {
  it("coalesces bootstrap/visible-page first requests and appends in server order without moving old IDs", async () => {
    const first = deferred<DirectoryPage<LiveChannelDescriptor>>();
    vi.mocked(liveApi.listLiveChannelsPage).mockReturnValueOnce(first.promise);
    const a = loadDirectory("live");
    const b = loadDirectory("live");
    expect(b).toBe(a);
    expect(liveApi.listLiveChannelsPage).toHaveBeenCalledTimes(1);
    expect(liveApi.listLiveChannelsPage).toHaveBeenCalledWith({ limit: 20, cursor: null });
    first.resolve(page([live(8), live(3)], "cursor-a", 4));
    await a;
    vi.mocked(liveApi.listLiveChannelsPage).mockResolvedValueOnce(page([live(3, { title: "更新标题" }), live(7)], "cursor-b", 4));
    await loadDirectory("live", {}, "more");
    expect(read().items.map((item) => item.id)).toEqual([8, 3, 7]);
    expect((read().items[1] as LiveChannelDescriptor).title).toBe("更新标题");
    expect(read().nextCursor).toBe("cursor-b");
    await loadDirectory("live");
    expect(liveApi.listLiveChannelsPage).toHaveBeenCalledTimes(2);
    expect(read().items).toHaveLength(3);
  });

  it("keeps independent group/only-live query pages and merges detail cache instead of replacing it", async () => {
    useLiveStore.getState().upsertChannel(live(99));
    vi.mocked(liveApi.listLiveChannelsPage).mockResolvedValueOnce(page([live(1)])).mockResolvedValueOnce(page([live(2)]));
    await loadDirectory("live", { groupId: "1" });
    await loadDirectory("live", { groupId: "2" });
    expect(read("1").items.map((item) => item.id)).toEqual([1]);
    expect(read("2").items.map((item) => item.id)).toEqual([2]);
    expect(useLiveStore.getState().channels.map((item) => item.id).sort()).toEqual([1, 2, 99]);
    expect(directoryKey("live", { onlyLive: true })).not.toBe(directoryKey("live"));
    // A legacy filtered cache replacement is not proof that unrelated items were deleted.
    useLiveStore.getState().setChannels([live(99)]);
    expect(read("1").items.map((item) => item.id)).toEqual([1]);
    expect(read("1").invalidated).toBe(false);
  });

  it("refresh supersedes an older append without clearing visible cards during the request", async () => {
    vi.mocked(liveApi.listLiveChannelsPage).mockResolvedValueOnce(page([live(1)], "old"));
    await loadDirectory("live");
    const more = deferred<DirectoryPage<LiveChannelDescriptor>>();
    vi.mocked(liveApi.listLiveChannelsPage).mockReturnValueOnce(more.promise);
    const appendTask = loadDirectory("live", {}, "more");
    const fresh = deferred<DirectoryPage<LiveChannelDescriptor>>();
    vi.mocked(liveApi.listLiveChannelsPage).mockReturnValueOnce(fresh.promise);
    const refreshTask = loadDirectory("live", {}, "refresh");
    expect(read().items[0].id).toBe(1);
    fresh.resolve(page([live(9)], "new"));
    await refreshTask;
    more.resolve(page([live(2)], "stale"));
    await appendTask;
    expect(read().items.map((item) => item.id)).toEqual([9]);
    expect(read().nextCursor).toBe("new");
    expect(useLiveStore.getState().channels.some((item) => item.id === 2)).toBe(false);
  });

  it("reset permits the same account/query to load again and rejects the old in-flight occurrence", async () => {
    const old = deferred<DirectoryPage<LiveChannelDescriptor>>();
    vi.mocked(liveApi.listLiveChannelsPage).mockReturnValueOnce(old.promise);
    const oldTask = loadDirectory("live");
    useDirectoryStore.getState().reset();
    const fresh = deferred<DirectoryPage<LiveChannelDescriptor>>();
    vi.mocked(liveApi.listLiveChannelsPage).mockReturnValueOnce(fresh.promise);
    const freshTask = loadDirectory("live");
    expect(liveApi.listLiveChannelsPage).toHaveBeenCalledTimes(2);
    old.resolve(page([live(1)]));
    await oldTask;
    expect(read().loading).toBe(true);
    expect(read().items).toEqual([]);
    fresh.resolve(page([live(2)]));
    await freshTask;
    expect(read().items.map((item) => item.id)).toEqual([2]);
  });

  it.each([false, true])("known metadata/activity preserves immediate ordering and usable pagination (partial=%s)", async (partial) => {
    vi.mocked(voiceApi.listVoiceChannelsPage).mockResolvedValueOnce({ ...page([voice("1", 2), voice("2")], partial ? "next" : null, partial ? 25 : 2), total_member_count: 64 });
    await loadDirectory("voice", { groupId: "1" });
    const key = directoryKey("voice", { groupId: "1" });
    useVoiceStore.getState().patchChannel("1", { name: "改名", member_count: 3 });
    expect(useDirectoryStore.getState().records[key].invalidated).toBe(false);
    expect(useDirectoryStore.getState().records[key].totalMemberCount).toBe(65);
    useVoiceStore.getState().patchChannel("1", { member_count: 0, last_vacant_at: "2026-02-01T00:00:00Z" });
    const record = useDirectoryStore.getState().records[key];
    expect(record.items.map((item) => item.id)).toEqual(["2", "1"]);
    expect(record.totalMemberCount).toBe(62);
    expect(record.invalidated).toBe(false);
    expect(record.mutationRevision).toBe(0);
    if (partial) vi.mocked(voiceApi.listVoiceChannelsPage).mockResolvedValueOnce({ ...page([voice("3")]), total_member_count: 62 });
    await loadDirectory("voice", { groupId: "1" }, "more");
    expect(voiceApi.listVoiceChannelsPage).toHaveBeenCalledTimes(partial ? 2 : 1);
    if (partial) {
      expect(voiceApi.listVoiceChannelsPage).toHaveBeenLastCalledWith({ groupId: "1", limit: 20, cursor: "next" });
      expect(useDirectoryStore.getState().records[key].items.map((item) => item.id)).toEqual(["2", "1", "3"]);
    }
  });

  it("a late append duplicate cannot roll back activity received after its request began", async () => {
    vi.mocked(voiceApi.listVoiceChannelsPage).mockResolvedValueOnce({ ...page([voice("1", 0), voice("2", 0)], "next", 3), total_member_count: 0 });
    await loadDirectory("voice", { groupId: "1" });
    const next = deferred<DirectoryPage<VoiceChannelDescriptor>>();
    vi.mocked(voiceApi.listVoiceChannelsPage).mockReturnValueOnce(next.promise);
    const task = loadDirectory("voice", { groupId: "1" }, "more");
    useVoiceStore.getState().patchChannel("2", { member_count: 1, last_occupied_at: "2026-09-08T10:00:00Z" });
    const key = directoryKey("voice", { groupId: "1" });
    expect(useDirectoryStore.getState().records[key].items.map((item) => item.id)).toEqual(["2", "1"]);
    next.resolve({ ...page([voice("2", 0), voice("3", 0)]), total_member_count: 0 });
    await task;
    const record = useDirectoryStore.getState().records[key];
    expect(record.items.map((item) => item.id)).toEqual(["2", "1", "3"]);
    expect(record.items[0]).toMatchObject({ member_count: 1, last_occupied_at: "2026-09-08T10:00:00Z" });
    expect(useVoiceStore.getState().channels.find((item) => item.id === "2")?.member_count).toBe(1);
    expect(record.totalMemberCount).toBe(1);
    expect(record.invalidated).toBe(false);
  });

  it.each(["deleted", "scope-changed"])("a late page cannot restore a room that was %s during its request", async (change) => {
    vi.mocked(voiceApi.listVoiceChannelsPage).mockResolvedValueOnce({ ...page([voice("1")], "next", 2), total_member_count: 1 });
    await loadDirectory("voice", { groupId: "1" });
    const next = deferred<DirectoryPage<VoiceChannelDescriptor>>();
    vi.mocked(voiceApi.listVoiceChannelsPage).mockReturnValueOnce(next.promise);
    const task = loadDirectory("voice", { groupId: "1" }, "more");
    if (change === "deleted") {
      useVoiceStore.getState().removeChannel("1");
      frames.handlers.forEach((handler) => handler({ type: "voice.channel.deleted", data: { channel_id: "1" } }));
    } else useVoiceStore.getState().patchChannel("1", { allowed_group_ids: ["2"] });
    next.resolve({ ...page([voice("1"), voice("2", 0)]), total_member_count: 1 });
    await task;
    const record = useDirectoryStore.getState().records[directoryKey("voice", { groupId: "1" })];
    expect(record.items.map((item) => item.id)).toEqual(["2"]);
    expect(record.totalMemberCount).toBe(0);
    expect(record.invalidated).toBe(true);
    if (change === "deleted") expect(useVoiceStore.getState().channels.some((item) => item.id === "1")).toBe(false);
    else expect(useVoiceStore.getState().channels.find((item) => item.id === "1")?.allowed_group_ids).toEqual(["2"]);
  });

  it.each([false, true])("creation/deletion affects only the resolved descriptor's queries (partial=%s)", async (partial) => {
    const other = { ...voice("2"), allowed_group_ids: ["2"] };
    vi.mocked(voiceApi.listVoiceChannelsPage)
      .mockResolvedValueOnce({ ...page([voice("1")], partial ? "next-1" : null, partial ? 20 : 1), total_member_count: 1 })
      .mockResolvedValueOnce({ ...page([other], partial ? "next-2" : null, partial ? 20 : 1), total_member_count: 1 });
    await loadDirectory("voice", { groupId: "1" });
    await loadDirectory("voice", { groupId: "2" });
    const key1 = directoryKey("voice", { groupId: "1" });
    const key2 = directoryKey("voice", { groupId: "2" });
    const send = (frame: ChatServerFrame) => frames.handlers.forEach((handler) => handler(frame));
    send({ type: "voice.channel.created", data: { channel_id: "3" } });
    expect(useDirectoryStore.getState().records[key1].invalidated).toBe(false);
    useVoiceStore.getState().upsertChannel(voice("3", 2));
    expect(useDirectoryStore.getState().records[key1].invalidated).toBe(partial);
    expect(useDirectoryStore.getState().records[key1].items.some((item) => item.id === "3")).toBe(!partial);
    expect(useDirectoryStore.getState().records[key1].totalMemberCount).toBe(3);
    expect(useDirectoryStore.getState().records[key2].invalidated).toBe(false);
    expect(useDirectoryStore.getState().records[key2].totalMemberCount).toBe(1);
    // Production removes the cache record before dispatching the notification handlers.
    useVoiceStore.getState().removeChannel("1");
    send({ type: "voice.channel.deleted", data: { channel_id: "1" } });
    expect(useDirectoryStore.getState().records[key1].items.some((item) => item.id === "1")).toBe(false);
    expect(useDirectoryStore.getState().records[key1].totalMemberCount).toBe(2);
    expect(useDirectoryStore.getState().records[key2].invalidated).toBe(false);
    expect(useDirectoryStore.getState().records[key2].total).toBe(partial ? 20 : 1);
    const retainedTotal = useDirectoryStore.getState().records[key1].total;
    send({ type: "voice.channel.deleted", data: { channel_id: "1" } });
    send({ type: "voice.channel.deleted", data: { channel_id: "unknown-other-group" } });
    expect(useDirectoryStore.getState().records[key1].total).toBe(retainedTotal);
    expect(useDirectoryStore.getState().records[key2].invalidated).toBe(false);
  });

  it("reset and expired creation hints cannot populate a later complete query", async () => {
    const send = (id: string) => frames.handlers.forEach((handler) => handler({ type: "voice.channel.created", data: { channel_id: id } }));
    vi.mocked(voiceApi.listVoiceChannelsPage).mockResolvedValue({ ...page([voice("1")]), total_member_count: 1 });
    await loadDirectory("voice", { groupId: "1" });
    send("2");
    useDirectoryStore.getState().reset();
    await loadDirectory("voice", { groupId: "1" });
    useVoiceStore.getState().upsertChannel(voice("2"));
    const key = directoryKey("voice", { groupId: "1" });
    expect(useDirectoryStore.getState().records[key].items.map((item) => item.id)).toEqual(["1"]);
    const now = Date.now();
    const clock = vi.spyOn(Date, "now").mockReturnValue(now);
    send("3");
    clock.mockReturnValue(now + 60_001);
    useVoiceStore.getState().upsertChannel(voice("3"));
    expect(useDirectoryStore.getState().records[key].items.map((item) => item.id)).toEqual(["1"]);
    clock.mockRestore();
  });

  it("explicit deletion removes only that item; changing a cache subset never implies deletion", async () => {
    vi.mocked(liveApi.listLiveChannelsPage).mockResolvedValueOnce(page([live(1), live(2)], "next"));
    await loadDirectory("live");
    for (const handler of frames.handlers) handler({ type: "live.channel.deleted", data: { channel_id: 1 } } as ChatServerFrame);
    expect(read().items.map((item) => item.id)).toEqual([2]);
    expect(read().invalidated).toBe(true);
  });

  it("append failure keeps cards/cursor, scrolling does not retry until the explicit action", async () => {
    vi.mocked(liveApi.listLiveChannelsPage).mockResolvedValueOnce(page([live(1)], "next"));
    await loadDirectory("live");
    vi.mocked(liveApi.listLiveChannelsPage).mockRejectedValueOnce(new Error("offline"));
    const { result, unmount } = renderHook(() => useDirectoryPage("live"));
    await act(async () => { await result.current.loadMore(); });
    expect(read().error).toBe("offline");
    expect(read().nextCursor).toBe("next");
    expect(read().items.map((item) => item.id)).toEqual([1]);
    act(() => result.current.onScroll({ scrollHeight: 100, clientHeight: 100, scrollTop: 0 } as HTMLElement));
    expect(liveApi.listLiveChannelsPage).toHaveBeenCalledTimes(2);
    vi.mocked(liveApi.listLiveChannelsPage).mockResolvedValueOnce(page([live(2)]));
    await act(async () => { await result.current.loadMore(); });
    expect(read().items.map((item) => item.id)).toEqual([1, 2]);
    expect(read().error).toBeNull();
    unmount();
  });

  it("rejects a non-advancing cursor without claiming a page was consumed", async () => {
    vi.mocked(liveApi.listLiveChannelsPage).mockResolvedValueOnce(page([live(1)], "same"));
    await loadDirectory("live");
    vi.mocked(liveApi.listLiveChannelsPage).mockResolvedValueOnce(page([live(2)], "same"));
    await loadDirectory("live", {}, "more");
    expect(read().items.map((item) => item.id)).toEqual([1]);
    expect(read().nextCursor).toBe("same");
    expect(read().error).toContain("游标");
  });
});
