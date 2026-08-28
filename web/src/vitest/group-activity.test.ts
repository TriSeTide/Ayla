/**
 * groupActivity 单元测试（M5 群"新内容"排序与事件描述）：
 * - hasGroupActivity：窗口内任一事件（消息/开播/语音房/桌游房/帖）即"新内容"；
 * - sortGroupsByActivity：置顶优先 → 有新内容按最近事件时间新→旧 → 无新内容保持稳定；
 * - 事件文本：消息=「发送者：内容」等。
 */
import { renderHook } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import type {
  LiveChannelDescriptor,
  Post,
  VoiceChannelDescriptor,
} from "../api/types";
import {
  hasGroupActivity,
  sortGroupsByActivity,
  useGroupActivityMap,
  useGroupCarouselSlides,
  type GroupActivity,
  type NewEvent,
} from "../components/home/groupActivity";
import { useBoardgameStore } from "../stores/boardgame";
import { useChatStore } from "../stores/chat";
import { useLiveStore } from "../stores/live";
import { usePostsStore } from "../stores/posts";
import { useVoiceStore } from "../stores/voice";

function group(id: string, isPinned = false) {
  return { id, is_pinned: isPinned };
}

function event(at: number, kind: NewEvent["kind"] = "message", text = "x"): NewEvent {
  return { kind, at, text };
}

function act(lastNewAt = 0, lastEvent: NewEvent | null = null): GroupActivity {
  return { lastNewAt, lastEvent };
}

describe("hasGroupActivity", () => {
  it("窗口内任一事件即新内容；无事件为 false", () => {
    expect(hasGroupActivity(act(1_000_000, event(1_000_000, "voice")))).toBe(true);
    expect(hasGroupActivity(act(1_000_000, event(1_000_000, "message")))).toBe(true);
    expect(hasGroupActivity(act(0, null))).toBe(false);
  });
});

describe("sortGroupsByActivity", () => {
  it("无新内容时保持传入顺序（稳定）", () => {
    const list = [group("a"), group("b"), group("c")];
    const key = () => act();
    const sorted = sortGroupsByActivity(list, key);
    expect(sorted.map((g) => g.id)).toEqual(["a", "b", "c"]);
  });

  it("有新内容的群排到无新内容群之前，组内按最近事件时间降序", () => {
    const now = 1_000_000;
    const list = [
      group("a"), // 无新内容
      group("b"), // 新语音房（较早）
      group("c"), // 无新内容
      group("d"), // 新开播（较晚）
      group("e"), // 无新内容
    ];
    const key = (g: { id: string }) => {
      if (g.id === "b") return act(now - 5_000, event(now - 5_000, "voice"));
      if (g.id === "d") return act(now - 1_000, event(now - 1_000, "live"));
      return act();
    };
    const sorted = sortGroupsByActivity(list, key);
    expect(sorted.map((g) => g.id)).toEqual(["d", "b", "a", "c", "e"]);
  });

  it("新消息（最后一条消息，含自己的）参与排序", () => {
    const now = 1_000_000;
    const list = [group("a"), group("b")];
    const key = (g: { id: string }) =>
      g.id === "b" ? act(now - 10_000, event(now - 10_000, "message", "我：你好")) : act();
    const sorted = sortGroupsByActivity(list, key);
    expect(sorted.map((g) => g.id)).toEqual(["b", "a"]);
  });

  it("置顶组在最前，组内亦按新内容时间排；非置顶组同规则", () => {
    const now = 1_000_000;
    const list = [
      group("a"), // 无新内容
      group("p1", true), // 置顶 + 新语音房（较早）
      group("b"), // 无新内容
      group("p2", true), // 置顶 + 新开播（较晚）
      group("c"), // 无新内容
    ];
    const key = (g: { id: string }) => {
      if (g.id === "p1") return act(now - 5_000, event(now - 5_000, "voice"));
      if (g.id === "p2") return act(now - 1_000, event(now - 1_000, "live"));
      return act();
    };
    const sorted = sortGroupsByActivity(list, key);
    // 置顶组：p2(live 新) 在 p1(voice 旧) 前；非置顶组全无新内容，保持原顺序 a,b,c
    expect(sorted.map((g) => g.id)).toEqual(["p2", "p1", "a", "b", "c"]);
  });

  it("新帖事件同样参与排序", () => {
    const now = 1_000_000;
    const list = [group("a"), group("b")];
    const key = (g: { id: string }) =>
      g.id === "b"
        ? act(now - 1_000, event(now - 1_000, "post", "阿蓝 发了新帖 你好"))
        : act();
    const sorted = sortGroupsByActivity(list, key);
    expect(sorted.map((g) => g.id)).toEqual(["b", "a"]);
  });
});

describe("useGroupCarouselSlides（群卡片状态轮播数据）", () => {
  afterEach(() => {
    useLiveStore.getState().reset();
    useVoiceStore.getState().reset();
    usePostsStore.getState().reset();
    useBoardgameStore.getState().reset();
  });

  function voiceChannel(
    groupId: string,
    memberCount: number,
    id = "v1",
  ): VoiceChannelDescriptor {
    return {
      id,
      name: "语音房",
      room_name: "room1",
      owner_id: "o1",
      owner_nickname: "小樱",
      member_count: memberCount,
      visibility: "group",
      group: groupId,
      group_name: null,
      allowed_group_ids: [groupId],
      allowed_group_names: [],
      mine: false,
      created_at: new Date().toISOString(),
    };
  }

  function liveChannel(groupId: string, status: LiveChannelDescriptor["status"]): LiveChannelDescriptor {
    return {
      id: 1,
      title: "直播标题",
      status,
      owner_id: "o2",
      owner_nickname: "阿蓝",
      is_owner: false,
      visibility: "group",
      group: groupId,
      group_name: null,
      allowed_group_ids: [groupId],
      allowed_group_names: [],
      stream_key: null,
      rtmp_url: null,
      hls_url: "",
      flv_url: "",
      started_at: new Date().toISOString(),
      ended_at: null,
      created_at: new Date().toISOString(),
    };
  }

  function post(groupId: string, createdAt: string, title: string, withImage: boolean): Post {
    return {
      id: 100,
      author: { id: "a", username: "a", nickname: "a", avatar: "", signature: "", status: "online", online: true, date_joined: "" },
      author_id: "a",
      title,
      body: "",
      visibility: "group",
      group: groupId,
      group_name: null,
      allowed_group_ids: [groupId],
      allowed_group_names: [],
      images: withImage
        ? [{ id: 1, media: { media_id: "m1", kind: "image", mime_type: "image/png", size: 1, status: "ready", width: null, height: null, duration: null, thumbnail: "/api/v1/media/m1/thumbnail", waveform: null, created_at: "" }, order: 0 }]
        : [],
      comment_count: 0,
      is_author: false,
      created_at: createdAt,
      updated_at: createdAt,
    };
  }

  it("无状态 → 空列表", () => {
    const { result } = renderHook(() => useGroupCarouselSlides());
    expect(result.current("g1", 0)).toEqual([]);
  });

  it("有未读 + 有人在语音 → 第一张消息+语音合卡（含房间名）", () => {
    useVoiceStore.getState().setChannels([voiceChannel("g1", 3)]);
    const { result } = renderHook(() => useGroupCarouselSlides());
    const slides = result.current("g1", 5);
    expect(slides[0]).toEqual({
      kind: "message-voice",
      newMessageCount: 5,
      voiceRooms: [{ name: "语音房", memberCount: 3 }],
    });
  });

  it("只有未读（无人语音）→ 无语音房间但仍生成合卡", () => {
    const { result } = renderHook(() => useGroupCarouselSlides());
    const slides = result.current("g1", 2);
    expect(slides).toEqual([{ kind: "message-voice", newMessageCount: 2, voiceRooms: [] }]);
  });

  it("语音房 member_count=0 → 不视为有人", () => {
    useVoiceStore.getState().setChannels([voiceChannel("g1", 0)]);
    const { result } = renderHook(() => useGroupCarouselSlides());
    expect(result.current("g1", 0)).toEqual([]);
  });

  it("多语音房按人数降序、最多 3 个", () => {
    useVoiceStore.getState().setChannels([
      voiceChannel("g1", 1, "v1"),
      voiceChannel("g1", 5, "v2"),
      voiceChannel("g1", 3, "v3"),
      voiceChannel("g1", 2, "v4"),
    ]);
    const { result } = renderHook(() => useGroupCarouselSlides());
    const slide = result.current("g1", 0)[0];
    expect(slide.kind).toBe("message-voice");
    if (slide.kind === "message-voice") {
      expect(slide.voiceRooms.map((r) => r.memberCount)).toEqual([5, 3, 2]);
      expect(slide.voiceRooms).toHaveLength(3);
    }
  });

  it("每个在播直播间生成一张直播卡", () => {
    useLiveStore.getState().setChannels([
      liveChannel("g1", "live"),
      liveChannel("g1", "live"),
    ]);
    const { result } = renderHook(() => useGroupCarouselSlides());
    const liveSlides = result.current("g1", 0).filter((s) => s.kind === "live");
    expect(liveSlides).toHaveLength(2);
    expect(liveSlides[0]).toEqual({ kind: "live", host: "阿蓝", title: "直播标题", cover: null });
  });

  it("窗口内最新一帖生成帖子卡（有图取缩略图 + 含正文）", () => {
    usePostsStore.getState().setPage(
      [post("g1", new Date().toISOString(), "最新帖", true)],
      null,
      false,
    );
    const { result } = renderHook(() => useGroupCarouselSlides());
    const slides = result.current("g1", 0);
    expect(slides).toHaveLength(1);
    expect(slides[0]).toEqual({
      kind: "post",
      title: "最新帖",
      body: "",
      image: "/api/v1/media/m1/thumbnail",
    });
  });

  it("轮播顺序：消息+语音 → 直播 → 帖子", () => {
    useVoiceStore.getState().setChannels([voiceChannel("g1", 2)]);
    useLiveStore.getState().setChannels([liveChannel("g1", "live")]);
    usePostsStore.getState().setPage(
      [post("g1", new Date().toISOString(), "帖", false)],
      null,
      false,
    );
    const { result } = renderHook(() => useGroupCarouselSlides());
    const slides = result.current("g1", 4);
    expect(slides.map((s) => s.kind)).toEqual(["message-voice", "live", "post"]);
  });
});

describe("useGroupActivityMap（单调排序时间戳合并）", () => {
  afterEach(() => {
    useLiveStore.getState().reset();
    useVoiceStore.getState().reset();
    usePostsStore.getState().reset();
    useBoardgameStore.getState().reset();
    useChatStore.getState().reset();
  });

  function liveChannel(groupId: string, status: LiveChannelDescriptor["status"]): LiveChannelDescriptor {
    return {
      id: 1,
      title: "直播标题",
      status,
      owner_id: "o2",
      owner_nickname: "阿蓝",
      is_owner: false,
      visibility: "group",
      group: groupId,
      group_name: null,
      allowed_group_ids: [groupId],
      allowed_group_names: [],
      stream_key: null,
      rtmp_url: null,
      hls_url: "",
      flv_url: "",
      started_at: new Date().toISOString(),
      ended_at: null,
      created_at: new Date().toISOString(),
    };
  }

  it("无任何推导内容时，bump 时间戳仍驱动排序时间", () => {
    useChatStore.getState().bumpGroupActivity("g1", 5_000_000);
    const { result } = renderHook(() => useGroupActivityMap());
    const activity = result.current("g1", null);
    expect(activity.lastNewAt).toBe(5_000_000);
    expect(activity.lastEvent).toBeNull();
  });

  it("bump 时间戳与推导时间取 max：下播后推导回退但 bump 保留，不往回排", () => {
    // 开播中 → 推导出 started_at 新内容
    useLiveStore.getState().setChannels([liveChannel("g1", "live")]);
    const { result } = renderHook(() => useGroupActivityMap());
    const liveAt = result.current("g1", null).lastNewAt;
    expect(liveAt).toBeGreaterThan(0);

    // 开播时收到新内容 → bump（比 started_at 更大）
    const bumped = liveAt + 60_000;
    useChatStore.getState().bumpGroupActivity("g1", bumped);

    // 下播（status=ended）→ live 不再计入推导，但 bump 保留
    useLiveStore.getState().setChannels([liveChannel("g1", "ended")]);
    const { result: r2 } = renderHook(() => useGroupActivityMap());
    expect(r2.current("g1", null).lastNewAt).toBe(bumped);
  });
});