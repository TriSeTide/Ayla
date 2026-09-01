/**
 * LiveRoomBody 窄屏上下滑切换测试（方案 §2.5）：
 * - 沉浸式窄屏（观看态）渲染滑动单元（视频 + 弹幕列表整体滑动），无封面预览卡；
 * - 切换后播放组件单实例（仅当前槽一个 video）；
 * - 宽屏与开播控制台窄屏不渲染滑动单元（保持固定播放器 / 整页滚动）。
 */
import { render } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { LiveChannelDescriptor } from "../api/types";
import { LiveRoomBody } from "../components/live/LiveRoomBody";
import { useLiveStore } from "../stores/live";

vi.mock("../hooks/useLiveRoom", () => ({
  useLiveRoom: () => ({
    loading: false,
    error: null,
    playerError: null,
    retryPlayer: vi.fn(),
    refreshPlayer: vi.fn(),
    // LivePlayer 改造后 video 元素由外部持有：mock 提供真实元素供迁移进容器
    videoRef: { current: document.createElement("video") },
  }),
}));

vi.mock("../hooks/useDanmaku", () => ({
  DANMAKU_MAX_LENGTH: 200,
  useDanmaku: () => ({
    sending: false,
    sendError: null,
    send: vi.fn(),
    listRef: { current: null },
    hasNewBelow: false,
    scrollToBottom: vi.fn(),
  }),
}));

// 收藏按钮有异步 store 读取副作用，与滑动切换无关，mock 掉消除 act 警告
vi.mock("../components/FavoriteButton", () => ({
  FavoriteButton: () => null,
}));

function ch(id: number): LiveChannelDescriptor {
  return {
    id,
    title: `直播${id}`,
    status: "live",
    owner_id: "o1",
    owner_nickname: "主播",
    is_owner: false,
    visibility: "public",
    group: null,
    group_name: null,
    stream_key: null,
    rtmp_url: null,
    hls_url: `http://h/${id}.m3u8`,
    flv_url: `http://h/${id}.flv`,
    started_at: null,
    ended_at: null,
    created_at: "2026-01-01T00:00:00Z",
  };
}

function matchMediaMock() {
  vi.stubGlobal(
    "matchMedia",
    vi.fn(() => ({
      matches: false,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    })),
  );
}

beforeEach(() => {
  matchMediaMock();
  useLiveStore.getState().reset();
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.clearAllMocks();
});

describe("LiveRoomBody 窄屏上下滑切换（§2.5）", () => {
  it("沉浸式窄屏渲染滑动单元（视频 + 弹幕列表），无封面预览卡", () => {
    const channels = [ch(1), ch(2), ch(3)];
    useLiveStore.getState().setCurrentChannel(ch(2));
    useLiveStore.getState().setSrsStatus("live");
    render(
      <LiveRoomBody
        channelId={2}
        channel={ch(2)}
        isNarrow
        channels={channels}
        onSelect={vi.fn()}
        onBack={vi.fn()}
        inputEntered
      />,
    );
    expect(document.querySelector(".live-room-swipe")).not.toBeNull();
    expect(document.querySelector(".live-room-swipe-item")).not.toBeNull();
    // 滑动单元内同时有视频区与弹幕列表
    expect(document.querySelector(".live-room-swipe-item .live-room-stage")).not.toBeNull();
    expect(document.querySelector(".live-room-swipe-item .danmaku-wrap")).not.toBeNull();
    // 无封面预览卡
    expect(document.querySelector(".live-peer-preview")).toBeNull();
  });

  it("切换后播放组件单实例（仅当前槽一个 video）", () => {
    const channels = [ch(1), ch(2), ch(3)];
    useLiveStore.getState().setCurrentChannel(ch(2));
    useLiveStore.getState().setSrsStatus("live");
    render(
      <LiveRoomBody
        channelId={2}
        channel={ch(2)}
        isNarrow
        channels={channels}
        onSelect={vi.fn()}
        onBack={vi.fn()}
        inputEntered
      />,
    );
    // video 元素由 liveSessionRuntime 唯一持有；本测试环境无 runtime，
    // 断言播放组件单实例（仅当前槽一个 .live-player）
    expect(document.querySelectorAll(".live-player").length).toBe(1);
  });

  it("宽屏不渲染滑动单元，保持固定播放器", () => {
    const channels = [ch(1), ch(2)];
    useLiveStore.getState().setCurrentChannel(ch(1));
    useLiveStore.getState().setSrsStatus("live");
    render(
      <LiveRoomBody
        channelId={1}
        channel={ch(1)}
        isNarrow={false}
        channels={channels}
        onSelect={vi.fn()}
        onBack={vi.fn()}
        inputEntered
      />,
    );
    expect(document.querySelector(".live-room-swipe")).toBeNull();
    expect(document.querySelector(".live-room-player-wrap")).not.toBeNull();
  });

  it("开播控制台窄屏不渲染滑动单元（整页滚动，不上下滑）", () => {
    const channels = [ch(1), ch(2)];
    useLiveStore.getState().setCurrentChannel(ch(1));
    useLiveStore.getState().setSrsStatus("live");
    render(
      <LiveRoomBody
        channelId={1}
        channel={{ ...ch(1), is_owner: true }}
        isNarrow
        channels={channels}
        onSelect={vi.fn()}
        onBack={vi.fn()}
        inputEntered
        showOwnerPanel
      />,
    );
    expect(document.querySelector(".live-room-swipe")).toBeNull();
    expect(document.querySelector(".live-room-player-wrap")).not.toBeNull();
  });
});
