/**
 * LiveRoomBody 窄屏上下滑切换测试（方案 §2.5）：
 * - 沉浸式窄屏（观看态）渲染滑动单元（视频 + 弹幕列表整体滑动），无封面预览卡；
 * - 切换后播放组件单实例（仅当前槽一个 video）；
 * - 宽屏与开播控制台窄屏不渲染滑动单元（保持固定播放器 / 整页滚动）。
 */
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { LiveChannelDescriptor } from "../api/types";
import { LiveRoomBody } from "../components/live/LiveRoomBody";
import { useLiveStore } from "../stores/live";
import { liveSessionRuntime } from "../runtime/liveSessionRuntime";

const liveOwner = vi.hoisted(() => ({ videoRef: { current: null as HTMLVideoElement | null } }));
const originalAnimate = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "animate");
let mediaAnimations: Array<{ node: HTMLElement; frames: Keyframe[]; options: KeyframeAnimationOptions; cancel: ReturnType<typeof vi.fn> }>;

vi.mock("../hooks/useLiveRoom", () => ({
  useLiveRoom: () => ({
    loading: false,
    error: null,
    playerError: null,
    retryPlayer: vi.fn(),
    refreshPlayer: vi.fn(),
    // LivePlayer 改造后 video 元素由外部持有：mock 提供真实元素供迁移进容器
    videoRef: liveOwner.videoRef,
  }),
}));

vi.mock("../runtime/liveSessionRuntime", () => ({
  liveSessionRuntime: {
    attachVideoTo: vi.fn((host: HTMLElement) => {
      if (liveOwner.videoRef.current) host.appendChild(liveOwner.videoRef.current);
    }),
    stashVideo: vi.fn(() => liveOwner.videoRef.current?.remove()),
  },
}));

vi.mock("../api/chat", () => ({ listConversations: vi.fn().mockResolvedValue([]) }));

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
  vi.clearAllMocks();
  liveOwner.videoRef.current = document.createElement("video");
  matchMediaMock();
  useLiveStore.getState().reset();
  mediaAnimations = [];
  Object.defineProperty(HTMLElement.prototype, "animate", { configurable: true, value: function(this: HTMLElement, frames: Keyframe[], options: KeyframeAnimationOptions) {
    const animation = { node: this, frames, options, cancel: vi.fn() };
    mediaAnimations.push(animation);
    return { cancel: animation.cancel };
  } });
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  vi.clearAllMocks();
  if (originalAnimate) Object.defineProperty(HTMLElement.prototype, "animate", originalAnimate);
  else Reflect.deleteProperty(HTMLElement.prototype, "animate");
});

describe("LiveRoomBody 窄屏上下滑切换（§2.5）", () => {
  it.each([false, true])("宽屏切房重播视频bottom/弹幕right，hideRail=%s不增视频挂卸", async (hideRail) => {
    useLiveStore.getState().setCurrentChannel(ch(1));
    useLiveStore.getState().setSrsStatus("live");
    const props = { isNarrow: false, hideRail, channels: [ch(1), ch(2), ch(3)], onSelect: vi.fn(), onBack: vi.fn(), inputEntered: true };
    const { container, rerender } = render(<LiveRoomBody {...props} channelId={1} channel={ch(1)} />);
    const stage = container.querySelector(".live-room-stage");
    const side = container.querySelector(".live-room-side");
    const host = container.querySelector(".live-player");
    const video = container.querySelector("video");
    expect(mediaAnimations).toHaveLength(2);
    expect(mediaAnimations[0].node).toBe(stage);
    expect(mediaAnimations[0].frames[0]).toEqual({ opacity: 0, transform: "translate(0px, 20px)" });
    expect(mediaAnimations[1].node).toBe(side);
    expect(mediaAnimations[1].frames[0]).toEqual({ opacity: 0, transform: "translate(20px, 0px)" });
    rerender(<LiveRoomBody {...props} channelId={2} channel={ch(2)} />);
    rerender(<LiveRoomBody {...props} channelId={3} channel={ch(3)} />);
    expect(mediaAnimations).toHaveLength(6);
    expect(mediaAnimations.slice(0, 4).every((animation) => animation.cancel.mock.calls.length === 1)).toBe(true);
    expect(mediaAnimations[4].node).toBe(stage);
    expect(mediaAnimations[5].node).toBe(side);
    expect(mediaAnimations[4].options.duration).toBe(300);
    expect(container.querySelector(".live-room-stage")).toBe(stage);
    expect(container.querySelector(".live-room-side")).toBe(side);
    expect(container.querySelector(".live-player")).toBe(host);
    expect(container.querySelector("video")).toBe(video);
    expect(liveSessionRuntime.attachVideoTo).toHaveBeenCalledTimes(1);
    expect(liveSessionRuntime.stashVideo).not.toHaveBeenCalled();
    await waitFor(() => expect(container.querySelector('[data-live-header-owner="3"]')).not.toBeNull());
  });

  it("窄屏覆盖侧栏从右进入，展开时播放器与视频节点不变", async () => {
    const { container } = render(<LiveRoomBody channelId={1} channel={ch(1)} isNarrow channels={[ch(1), ch(2)]} onSelect={vi.fn()} onBack={vi.fn()} inputEntered />);
    const video = container.querySelector("video");
    const host = container.querySelector(".live-player");
    fireEvent.click(screen.getByRole("button", { name: "打开直播间列表" }));
    const rail = container.querySelector<HTMLElement>(".live-room-rail-overlay > .live-rail")!;
    expect(rail.style.transform).toContain("translateX(20px)");
    await waitFor(() => expect(rail.style.transform).toBe("none"));
    expect(container.querySelector("video")).toBe(video);
    expect(container.querySelector(".live-player")).toBe(host);
    expect(liveSessionRuntime.attachVideoTo).toHaveBeenCalledTimes(1);
    expect(liveSessionRuntime.stashVideo).not.toHaveBeenCalled();
  });

  it("窄屏顶栏从顶部进入，底部输入不叠100%位移，视频手势层保持原位", async () => {
    useLiveStore.getState().setCurrentChannel(ch(1));
    useLiveStore.getState().setSrsStatus("live");
    const { container } = render(<LiveRoomBody channelId={1} channel={ch(1)} isNarrow channels={[ch(1)]} onSelect={vi.fn()} onBack={vi.fn()} inputEntered={false} />);
    const head = container.querySelector<HTMLElement>(".live-room-head")!;
    expect(head.style.transform).toContain("translateY(-20px)");
    expect(container.querySelector(".live-room-input")).toHaveStyle({ transform: "translateY(0)", transition: "none" });
    expect(container.querySelector<HTMLElement>(".live-room-swipe")!.style.transform).not.toContain("translate");
    expect(container.querySelectorAll("video")).toHaveLength(1);
    await waitFor(() => expect(head.style.transform).toBe("none"));
  });
  it("宽屏顶栏旧退新入，快切只显示最新标题且不改动 runtime 注入的视频", async () => {
    const channels = [ch(1), ch(2), ch(3)];
    const props = { isNarrow: false, channels, onSelect: vi.fn(), onBack: vi.fn(), inputEntered: true };
    useLiveStore.getState().setCurrentChannel(ch(1));
    useLiveStore.getState().setSrsStatus("live");
    const { container, rerender } = render(<LiveRoomBody {...props} channelId={1} channel={ch(1)} />);
    const first = container.querySelector<HTMLElement>(".live-room-head")!;
    const video = container.querySelector("video");
    const host = container.querySelector(".live-player");
    expect(first.style.transform).toContain("translateY(-20px)");
    await waitFor(() => expect(first.style.opacity).toBe("1"));
    rerender(<LiveRoomBody {...props} channelId={2} channel={ch(2)} />);
    expect(first).toHaveAttribute("inert");
    expect(first).toHaveAttribute("data-motion-state", "exiting");
    expect(container.querySelector('[data-live-header-owner="2"]')).toBeNull();
    rerender(<LiveRoomBody {...props} channelId={3} channel={ch(3)} />);
    await waitFor(() => expect(container.querySelector('[data-live-header-owner="3"]')).not.toBeNull());
    expect(container.querySelector('[data-live-header-owner="2"]')).toBeNull();
    expect(first).not.toBeInTheDocument();
    expect(container.querySelectorAll(".live-room-head")).toHaveLength(1);
    expect(container.querySelector("video")).toBe(video);
    expect(container.querySelector(".live-player")).toBe(host);
    expect(liveSessionRuntime.attachVideoTo).toHaveBeenCalledTimes(1);
    expect(liveSessionRuntime.stashVideo).not.toHaveBeenCalled();
  });

  it("reduced-motion 换房的顶栏直接归位且不创建第二播放器", async () => {
    vi.stubGlobal("matchMedia", vi.fn((query: string) => ({ matches: query.includes("prefers-reduced-motion"), addEventListener: vi.fn(), removeEventListener: vi.fn() })));
    const channels = [ch(1), ch(2)];
    const props = { isNarrow: false, channels, onSelect: vi.fn(), onBack: vi.fn(), inputEntered: true };
    const { container, rerender } = render(<LiveRoomBody {...props} channelId={1} channel={ch(1)} />);
    const host = container.querySelector(".live-player");
    rerender(<LiveRoomBody {...props} channelId={2} channel={ch(2)} />);
    await waitFor(() => expect(container.querySelector('[data-live-header-owner="2"]')).not.toBeNull());
    expect(container.querySelector<HTMLElement>(".live-room-head")!.style.transform).toBe("none");
    expect(container.querySelectorAll(".live-player")).toHaveLength(1);
    expect(container.querySelector(".live-player")).toBe(host);
  });
  it("频道属性变化保留播放器 host；给定同一个注入视频时动效不额外挂卸", () => {
    const channels = [ch(1), ch(2)];
    const props = { isNarrow: false, channels, onSelect: vi.fn(), onBack: vi.fn(), inputEntered: true };
    useLiveStore.getState().setCurrentChannel(ch(1));
    useLiveStore.getState().setSrsStatus("live");
    const { container, rerender } = render(<LiveRoomBody {...props} channelId={1} channel={ch(1)} />);
    const host = container.querySelector(".live-player");
    const video = container.querySelector("video");
    // 此 fixture 固定 runtime.videoRef，只隔离验证动效没有额外挂卸；
    // 真实频道 owner 可以按原媒体协议接替 video，本测试不约束那条生命周期。
    expect(video).toBe(liveOwner.videoRef.current);
    act(() => useLiveStore.getState().setCurrentChannel(ch(2)));
    rerender(<LiveRoomBody {...props} channelId={2} channel={ch(2)} />);
    expect(container.querySelector(".live-player")).toBe(host);
    expect(container.querySelector("video")).toBe(video);
    expect(container.querySelectorAll("video")).toHaveLength(1);
    expect(container.querySelectorAll(".live-player")).toHaveLength(1);
  });
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

  it("开播控制台窄屏不渲染滑动单元（整页滚动，不上下滑）", async () => {
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
    await act(async () => {});
  });
});
