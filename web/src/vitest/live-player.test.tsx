/**
 * LivePlayer 交互测试（直播体验增量）：
 * - live：渲染 video 无原生控制条（无 controls），渲染左下「跳到最新」刷新键 + 右下「全屏」键；
 * - 点刷新键 → onRefresh 回调 + 进入旋转动画（is-spinning）；
 * - 点全屏键 → requestFullscreen；支持画中画时点画中画键 → requestPictureInPicture，不支持不渲染；
 * - idle 占位：默认「主播未开播」，乐观已开播「等待推流信号…」；
 * - playerError：渲染「播放失败 + 重试」，点重试 → onRetry。
 */
import { afterEach, describe, expect, it, vi } from "vitest";
import { act, fireEvent, render, screen } from "@testing-library/react";
import { LivePlayer } from "../components/live/LivePlayer";

type VideoRef = { current: HTMLVideoElement | null };

function renderPlayer(
  overrides: Partial<Parameters<typeof LivePlayer>[0]> = {},
) {
  // LivePlayer 改造后 video 元素由外部（runtime）持有：测试提供真实元素供迁移进容器
  const videoRef: VideoRef = { current: document.createElement("video") };
  const props = {
    srsStatus: "live" as const,
    optimisticStatus: "live" as const,
    playerError: null,
    videoRef,
    onRetry: vi.fn(),
    onRefresh: vi.fn(),
    // 模拟 runtime.attachVideoTo：把 video 原子移入宿主容器
    onVideoHostMount: vi.fn((host: HTMLElement) => {
      if (videoRef.current) host.appendChild(videoRef.current);
    }),
    onVideoHostUnmount: vi.fn(),
    ...overrides,
  };
  const utils = render(<LivePlayer {...props} />);
  return { ...utils, videoRef, props };
}

afterEach(() => {
  // 恢复可能被 defineProperty 改动的媒体/文档 API，避免跨用例污染
  Reflect.deleteProperty(HTMLVideoElement.prototype, "requestPictureInPicture");
  Reflect.deleteProperty(HTMLVideoElement.prototype, "webkitEnterFullscreen");
  Reflect.deleteProperty(HTMLDivElement.prototype, "requestFullscreen");
  Reflect.deleteProperty(document, "pictureInPictureEnabled");
  Reflect.deleteProperty(document, "pictureInPictureElement");
});

describe("LivePlayer", () => {
  it("live 状态渲染 video 且无原生控制条，并渲染刷新键与全屏键", () => {
    const { container, props } = renderPlayer();
    // video 由外部持有并原子移入容器（useLayoutEffect 挂载时）
    const video = container.querySelector("video");
    expect(video).toBeTruthy();
    expect(video?.hasAttribute("controls")).toBe(false);
    expect(props.onVideoHostMount).toHaveBeenCalled();
    expect(screen.getByLabelText("跳到最新画面")).toBeTruthy();
    expect(screen.getByLabelText("全屏")).toBeTruthy();
  });

  it("点击刷新键触发 onRefresh 并进入旋转动画", () => {
    const { props } = renderPlayer();
    const btn = screen.getByLabelText("跳到最新画面");
    fireEvent.click(btn);
    expect(props.onRefresh).toHaveBeenCalledTimes(1);
    expect(btn.classList.contains("is-spinning")).toBe(true);
  });

  it("点击全屏键触发 requestFullscreen", () => {
    const fs = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(HTMLDivElement.prototype, "requestFullscreen", {
      configurable: true,
      value: fs,
    });
    renderPlayer();
    fireEvent.click(screen.getByLabelText("全屏"));
    expect(fs).toHaveBeenCalledTimes(1);
  });

  it("不支持画中画时不渲染画中画键", () => {
    Object.defineProperty(document, "pictureInPictureEnabled", {
      configurable: true,
      get: () => false,
    });
    renderPlayer();
    expect(screen.queryByLabelText("画中画")).toBeNull();
  });

  it("支持画中画时渲染画中画键，点击调 requestPictureInPicture", () => {
    const pip = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(HTMLVideoElement.prototype, "requestPictureInPicture", {
      configurable: true,
      value: pip,
    });
    Object.defineProperty(document, "pictureInPictureEnabled", {
      configurable: true,
      get: () => true,
    });
    Object.defineProperty(document, "pictureInPictureElement", {
      configurable: true,
      get: () => null,
    });

    renderPlayer();
    fireEvent.click(screen.getByLabelText("画中画"));
    expect(pip).toHaveBeenCalledTimes(1);
  });

  it("idle 状态渲染「主播未开播」占位", () => {
    renderPlayer({ srsStatus: "idle", optimisticStatus: null });
    expect(screen.getByText("主播未开播")).toBeTruthy();
    expect(screen.queryByLabelText("跳到最新画面")).toBeNull();
  });

  it("idle + 乐观已开播渲染「等待推流信号…」", () => {
    renderPlayer({ srsStatus: "idle", optimisticStatus: "live" });
    expect(screen.getByText("等待推流信号…")).toBeTruthy();
  });

  it("playerError 渲染「播放失败 + 重试」，点重试触发 onRetry", () => {
    const { props } = renderPlayer({ srsStatus: "live", playerError: "boom" });
    expect(screen.getByText("播放失败")).toBeTruthy();
    fireEvent.click(screen.getByText("重试"));
    expect(props.onRetry).toHaveBeenCalledTimes(1);
  });

  it("触屏点播放器显示控制层，3 秒无操作自动隐藏", () => {
    vi.useFakeTimers();
    const { container } = renderPlayer();
    const player = container.querySelector(".live-player");
    const controls = container.querySelector(".live-player-controls");
    expect(player).toBeTruthy();
    expect(controls).toBeTruthy();

    // 点击播放器唤醒显示控制层（触屏 tap 语义；video 由 runtime 持有不可点击）
    expect(controls?.classList.contains("is-visible")).toBe(false);
    fireEvent.click(player!);
    expect(controls?.classList.contains("is-visible")).toBe(true);

    // 3 秒无操作 → 自动隐藏
    act(() => {
      vi.advanceTimersByTime(3000);
    });
    expect(controls?.classList.contains("is-visible")).toBe(false);
    vi.useRealTimers();
  });

  it("iOS：全屏走 webkitEnterFullscreen（原生视频全屏自动横屏）", () => {
    const enter = vi.fn();
    Object.defineProperty(HTMLVideoElement.prototype, "webkitEnterFullscreen", {
      configurable: true,
      value: enter,
    });
    renderPlayer();
    fireEvent.click(screen.getByLabelText("全屏"));
    expect(enter).toHaveBeenCalledTimes(1);
  });
});
