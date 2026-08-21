/**
 * GroupCarousel 轮播测试：无状态回退、三类卡渲染、IntersectionObserver 启停、reduced-motion 静态。
 */
import { act, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { GroupCarouselSlide } from "../components/home/groupActivity";
import { GroupCarousel } from "../components/home/GroupCarousel";

function msgVoice(
  over: Partial<Extract<GroupCarouselSlide, { kind: "message-voice" }>> = {},
): GroupCarouselSlide {
  return {
    kind: "message-voice",
    newMessageCount: 5,
    voiceRooms: [{ name: "夜聊", memberCount: 3 }],
    ...over,
  };
}
function live(
  over: Partial<Extract<GroupCarouselSlide, { kind: "live" }>> = {},
): GroupCarouselSlide {
  return { kind: "live", host: "小樱", title: "直播标题", cover: null, ...over };
}
function post(
  over: Partial<Extract<GroupCarouselSlide, { kind: "post" }>> = {},
): GroupCarouselSlide {
  return { kind: "post", title: "帖子标题", body: "帖子正文内容", image: null, ...over };
}

function mockMatchMedia(reduced: boolean) {
  let matches = reduced;
  const listeners = new Set<(e: { matches: boolean }) => void>();
  const mql = {
    get matches() {
      return matches;
    },
    addEventListener: (_t: string, cb: (e: { matches: boolean }) => void) => listeners.add(cb),
    removeEventListener: (_t: string, cb: (e: { matches: boolean }) => void) => listeners.delete(cb),
  };
  vi.stubGlobal("matchMedia", vi.fn(() => mql));
  return mql;
}

function mockIntersectionObserver(intersecting: boolean) {
  let callback: IntersectionObserverCallback | null = null;
  class IO {
    constructor(cb: IntersectionObserverCallback) {
      callback = cb;
    }
    observe() {}
    disconnect() {}
    unobserve() {}
    takeRecords() {
      return [];
    }
  }
  vi.stubGlobal("IntersectionObserver", IO);
  return {
    fire() {
      callback?.(
        [{ isIntersecting: intersecting } as IntersectionObserverEntry],
        {} as IntersectionObserver,
      );
    },
  };
}

beforeEach(() => {
  vi.useFakeTimers();
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

describe("GroupCarousel", () => {
  it("无状态 → 回退群头像", () => {
    mockMatchMedia(false);
    render(<GroupCarousel slides={[]} groupName="测试群" />);
    expect(screen.getByLabelText("测试群 暂无动态")).toBeInTheDocument();
  });

  it("消息+语音卡：两行文本均显示（含房间名）", () => {
    mockMatchMedia(false);
    render(<GroupCarousel slides={[msgVoice()]} groupName="测试群" />);
    expect(screen.getByText("5条新消息")).toBeInTheDocument();
    expect(screen.getByText("3人在夜聊连麦")).toBeInTheDocument();
  });

  it("消息+语音卡：多房间逐行显示", () => {
    mockMatchMedia(false);
    render(
      <GroupCarousel
        slides={[
          msgVoice({
            voiceRooms: [
              { name: "夜聊", memberCount: 3 },
              { name: "开黑", memberCount: 2 },
            ],
          }),
        ]}
        groupName="测试群"
      />,
    );
    expect(screen.getByText("3人在夜聊连麦")).toBeInTheDocument();
    expect(screen.getByText("2人在开黑连麦")).toBeInTheDocument();
  });

  it("消息+语音卡：只有新消息时，语音行不渲染", () => {
    mockMatchMedia(false);
    render(
      <GroupCarousel slides={[msgVoice({ voiceRooms: [] })]} groupName="测试群" />,
    );
    expect(screen.getByText("5条新消息")).toBeInTheDocument();
    expect(screen.queryByText(/人在.*连麦/)).not.toBeInTheDocument();
  });

  it("直播卡：显示主播 在直播 标题", () => {
    mockMatchMedia(false);
    render(<GroupCarousel slides={[live()]} groupName="测试群" />);
    expect(screen.getByText("小樱 在直播 直播标题")).toBeInTheDocument();
  });

  it("帖子卡：显示有新帖 + 标题 + 正文", () => {
    mockMatchMedia(false);
    render(<GroupCarousel slides={[post()]} groupName="测试群" />);
    expect(screen.getByText("有新帖")).toBeInTheDocument();
    expect(screen.getByText("帖子标题")).toBeInTheDocument();
    expect(screen.getByText("帖子正文内容")).toBeInTheDocument();
  });

  it("IntersectionObserver 进视口 + 计时器推进 → 切到下一 slide（指示点激活）", async () => {
    mockMatchMedia(false);
    const io = mockIntersectionObserver(true);
    render(
      <GroupCarousel slides={[msgVoice(), live()]} groupName="测试群" />,
    );
    await act(async () => {
      io.fire();
    });
    await act(async () => {
      vi.advanceTimersByTime(3000);
    });
    const dots = document.querySelectorAll(".group-carousel-dot");
    expect(dots).toHaveLength(2);
    expect(dots[1]).toHaveClass("is-active");
  });

  it("reduced-motion 时不自动轮播", async () => {
    mockMatchMedia(true);
    const io = mockIntersectionObserver(true);
    render(
      <GroupCarousel slides={[msgVoice(), live()]} groupName="测试群" />,
    );
    await act(async () => {
      io.fire();
    });
    await act(async () => {
      vi.advanceTimersByTime(9000);
    });
    const dots = document.querySelectorAll(".group-carousel-dot");
    expect(dots[0]).toHaveClass("is-active");
  });
});
