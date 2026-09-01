/**
 * LiveMiniPlayer 契约测试（任务 05：直播适配手机端小窗）。
 *
 * 覆盖：
 * - miniPlayer 非空 → 渲染小窗（含关闭按钮）；null → 不渲染；
 * - 点击小窗主体 → navigate(sourceRoute) 回直播间；
 * - 点击关闭 → liveSessionRuntime.leave()（完整销毁）；
 * - 拖动（位移超阈值）→ 位置更新，且拖动结束的合成 click 不触发返回；
 * - 挂载时把 runtime video 元素迁移进小窗容器。
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import { LiveMiniPlayer } from "../components/live/LiveMiniPlayer";
import { useLiveStore } from "../stores/live";
import { liveSessionRuntime } from "../runtime/liveSessionRuntime";

const navigate = vi.fn();

vi.mock("react-router-dom", () => ({
  useNavigate: () => navigate,
}));

/** jsdom 的 PointerEvent 未实现 pointerId/pointerType 等属性，stub 一个完整实现 */
class MockPointerEvent extends MouseEvent {
  pointerId: number;
  pointerType: string;
  constructor(type: string, init: PointerEventInit = {}) {
    super(type, init);
    this.pointerId = init.pointerId ?? 0;
    this.pointerType = init.pointerType ?? "mouse";
  }
}

vi.mock("../runtime/liveSessionRuntime", () => ({
  liveSessionRuntime: {
    attachVideoTo: vi.fn(),
    detachMiniPlayer: vi.fn(),
    leave: vi.fn(),
  },
}));

import type { LiveChannelDescriptor } from "../api/types";

const channel: LiveChannelDescriptor = {
  id: 7,
  title: "测试直播间",
  status: "live",
  owner_id: "o1",
  owner_nickname: "主播",
  is_owner: false,
  visibility: "public",
  group: null,
  group_name: null,
  stream_key: null,
  rtmp_url: null,
  hls_url: "http://h/7.m3u8",
  flv_url: "http://h/7.flv",
  started_at: null,
  ended_at: null,
  created_at: "2026-01-01T00:00:00Z",
};

beforeEach(() => {
  vi.stubGlobal("PointerEvent", MockPointerEvent);
  useLiveStore.getState().reset();
  navigate.mockClear();
  vi.mocked(liveSessionRuntime.leave).mockClear();
  vi.mocked(liveSessionRuntime.attachVideoTo).mockClear();
  vi.mocked(liveSessionRuntime.detachMiniPlayer).mockClear();
});

afterEach(() => {
  useLiveStore.getState().setMiniPlayer(null);
  vi.unstubAllGlobals();
});

describe("LiveMiniPlayer", () => {
  it("miniPlayer 非空 → 渲染小窗与关闭按钮；null → 不渲染", () => {
    const { container, rerender } = render(<LiveMiniPlayer />);
    expect(container.querySelector(".live-mini-player")).toBeNull();

    useLiveStore.getState().setMiniPlayer({
      channelId: 7,
      channel,
      sourceRoute: "/live/7",
    });
    rerender(<LiveMiniPlayer />);
    expect(container.querySelector(".live-mini-player")).not.toBeNull();
    expect(screen.getByLabelText("关闭小窗")).toBeTruthy();
    expect(screen.getByLabelText("返回直播间")).toBeTruthy();
  });

  it("挂载时把 video 原子移入小窗容器，卸载时移回暂存", () => {
    useLiveStore.getState().setMiniPlayer({
      channelId: 7,
      channel,
      sourceRoute: "/live/7",
    });
    const { container, unmount } = render(<LiveMiniPlayer />);
    const wrap = container.querySelector(".live-mini-player-video-wrap");
    expect(liveSessionRuntime.attachVideoTo).toHaveBeenCalledWith(wrap);
    unmount();
    expect(liveSessionRuntime.detachMiniPlayer).toHaveBeenCalled();
  });

  it("点击小窗主体 → navigate(sourceRoute) 回直播间", () => {
    useLiveStore.getState().setMiniPlayer({
      channelId: 7,
      channel,
      sourceRoute: "/live/7",
    });
    render(<LiveMiniPlayer />);
    fireEvent.click(screen.getByLabelText("返回直播间"));
    expect(navigate).toHaveBeenCalledWith("/live/7");
  });

  it("点击关闭 → liveSessionRuntime.leave()（完整销毁）", () => {
    useLiveStore.getState().setMiniPlayer({
      channelId: 7,
      channel,
      sourceRoute: "/live/7",
    });
    render(<LiveMiniPlayer />);
    fireEvent.click(screen.getByLabelText("关闭小窗"));
    expect(liveSessionRuntime.leave).toHaveBeenCalledTimes(1);
    // 关闭按钮不触发返回
    expect(navigate).not.toHaveBeenCalled();
  });

  it("拖动（位移超阈值）→ 位置更新，且拖动结束的合成 click 不触发返回", () => {
    useLiveStore.getState().setMiniPlayer({
      channelId: 7,
      channel,
      sourceRoute: "/live/7",
    });
    const { container } = render(<LiveMiniPlayer />);
    const el = container.querySelector(".live-mini-player") as HTMLElement;
    const before = el.style.left;
    fireEvent.pointerDown(el, { pointerId: 1, clientX: 100, clientY: 100, pointerType: "touch" });
    fireEvent.pointerMove(el, { pointerId: 1, clientX: 140, clientY: 130 });
    fireEvent.pointerUp(el, { pointerId: 1 });
    expect(el.style.left).not.toBe(before);
    expect(el.style.top).not.toBe("");
    // 拖动结束后的合成 click：只消费抑制标记，不触发返回
    fireEvent.click(el);
    expect(navigate).not.toHaveBeenCalled();
  });

  it("位移未超阈值 → 视为点击，触发返回", () => {
    useLiveStore.getState().setMiniPlayer({
      channelId: 7,
      channel,
      sourceRoute: "/live/7",
    });
    const { container } = render(<LiveMiniPlayer />);
    const el = container.querySelector(".live-mini-player") as HTMLElement;
    fireEvent.pointerDown(el, { pointerId: 1, clientX: 100, clientY: 100, pointerType: "touch" });
    fireEvent.pointerMove(el, { pointerId: 1, clientX: 102, clientY: 101 });
    fireEvent.pointerUp(el, { pointerId: 1 });
    fireEvent.click(el);
    expect(navigate).toHaveBeenCalledWith("/live/7");
  });
});
