/**
 * GroupCarousel 轮播测试：无动态回退、IntersectionObserver 启停、reduced-motion 静态。
 */
import { act, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { GroupHighlight } from "../api/types";
import { GroupCarousel } from "../components/home/GroupCarousel";

function hl(over: Partial<GroupHighlight> = {}): GroupHighlight {
  return {
    type: "post",
    title: "动态标题",
    cover_url: null,
    target_url: "/posts/1",
    created_at: "2026-01-01T00:00:00Z",
    ...over,
  };
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
  it("无动态 → 回退群头像", () => {
    mockMatchMedia(false);
    render(<GroupCarousel highlights={[]} groupName="测试群" />);
    expect(screen.getByLabelText("测试群 暂无动态")).toBeInTheDocument();
  });

  it("有动态 → 渲染封面与指示点", () => {
    mockMatchMedia(false);
    render(
      <GroupCarousel highlights={[hl(), hl({ type: "live", title: "直播" })]} groupName="测试群" />,
    );
    expect(screen.getByText("动态标题")).toBeInTheDocument();
  });

  it("点击封面触发 onOpen（当前 slide）", () => {
    mockMatchMedia(false);
    const onOpen = vi.fn();
    render(<GroupCarousel highlights={[hl()]} groupName="测试群" onOpen={onOpen} />);
    screen.getByRole("button", { name: "打开动态：动态标题" }).click();
    expect(onOpen).toHaveBeenCalledWith(expect.objectContaining({ title: "动态标题" }));
  });

  it("IntersectionObserver 进视口 + 计时器推进 → 切到下一 slide", async () => {
    mockMatchMedia(false);
    const io = mockIntersectionObserver(true);
    render(
      <GroupCarousel highlights={[hl({ title: "A" }), hl({ title: "B" })]} groupName="测试群" />,
    );
    await act(async () => {
      io.fire(); // 进视口 → 可见 → 建立计时器
    });
    await act(async () => {
      vi.advanceTimersByTime(3000);
    });
    // 切换后当前 slide 可聚焦（tabIndex=0），另一个 slide 退到 -1
    expect(screen.getByRole("button", { name: "打开动态：B" })).toHaveAttribute("tabindex", "0");
    const aSlide = document.querySelector('[aria-label="打开动态：A"]');
    expect(aSlide).not.toBeNull();
    expect(aSlide!.getAttribute("tabindex")).toBe("-1");
  });

  it("reduced-motion 时不自动轮播", async () => {
    mockMatchMedia(true);
    const io = mockIntersectionObserver(true);
    render(
      <GroupCarousel highlights={[hl({ title: "A" }), hl({ title: "B" })]} groupName="测试群" />,
    );
    await act(async () => {
      io.fire();
    });
    await act(async () => {
      vi.advanceTimersByTime(9000);
    });
    expect(screen.getByRole("button", { name: "打开动态：A" })).toHaveAttribute("tabindex", "0");
  });
});
