import { cleanup, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DirectoryLoadMore, type DirectoryLoadMoreProps } from "../components/DirectoryLoadMore";

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

function props(overrides: Partial<DirectoryLoadMoreProps> = {}): DirectoryLoadMoreProps {
  return {
    loading: false,
    error: null,
    hasMore: true,
    invalidated: false,
    loadMore: vi.fn(async () => {}),
    refresh: vi.fn(async () => {}),
    ...overrides,
  };
}

describe("DirectoryLoadMore", () => {
  it("侧栏完整目录没有空页尾，分页中保留状态框，完成后移除；长信息流默认仍保留", () => {
    const initial = props({ retainCompletedSpace: false, hasMore: false });
    const { rerender } = render(<DirectoryLoadMore {...initial} />);
    expect(document.querySelector(".directory-load-more")).toBeNull();
    rerender(<DirectoryLoadMore {...initial} hasMore loading />);
    expect(screen.getByRole("status")).toHaveAttribute("aria-busy", "true");
    rerender(<DirectoryLoadMore {...initial} />);
    expect(document.querySelector(".directory-load-more")).toBeNull();
    rerender(<DirectoryLoadMore {...initial} retainCompletedSpace />);
    expect(document.querySelector(".directory-load-more")).not.toBeNull();
  });
  it("分页、错误静默隐藏、加载和终页保持同一个页尾占位", () => {
    const initial = props();
    const { rerender } = render(<DirectoryLoadMore {...initial} />);
    expect(screen.getByRole("button", { name: "加载更多" })).toBeInTheDocument();

    // bcb00dc 起错误静默：页尾整体隐藏（无错误文案、无重试按钮）
    const error = "下一页加载失败，已加载的房间仍可查看。".repeat(12);
    rerender(<DirectoryLoadMore {...initial} error={error} />);
    expect(document.querySelector(".directory-load-more")).toBeNull();
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "重试" })).not.toBeInTheDocument();
    expect(initial.loadMore).not.toHaveBeenCalled();
    expect(initial.refresh).not.toHaveBeenCalled();

    // 错误清除后页尾重新出现（错误隐藏会卸载/重建页尾；加载与终页保持同一节点）
    rerender(<DirectoryLoadMore {...initial} error={null} />);
    const restored = document.querySelector(".directory-load-more")!;
    expect(restored).not.toBeNull();
    expect(screen.getByRole("button", { name: "加载更多" })).toBeInTheDocument();

    rerender(<DirectoryLoadMore {...initial} loading />);
    expect(document.querySelector(".directory-load-more")).toBe(restored);
    expect(restored).toHaveAttribute("aria-busy", "true");
    expect(screen.queryByRole("button")).not.toBeInTheDocument();

    rerender(<DirectoryLoadMore {...initial} hasMore={false} />);
    expect(document.querySelector(".directory-load-more")).toBe(restored);
    expect(restored).toHaveAttribute("aria-busy", "false");
    expect(restored).toBeEmptyDOMElement();
  });

  it("初次失败静默隐藏，已失效目录自动刷新恢复", () => {
    const initial = props({ hasMore: false, error: "加载失败" });
    const { rerender } = render(<DirectoryLoadMore {...initial} />);
    // bcb00dc 起错误静默：无重试按钮，不触发任何请求
    expect(document.querySelector(".directory-load-more")).toBeNull();
    expect(initial.refresh).not.toHaveBeenCalled();
    expect(initial.loadMore).not.toHaveBeenCalled();

    // invalidated → 自动 refresh（不再显示"列表有更新"按钮，显示刷新中状态）
    rerender(<DirectoryLoadMore {...initial} hasMore invalidated error={null} />);
    expect(initial.refresh).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole("button", { name: "列表有更新，刷新后继续加载" })).not.toBeInTheDocument();
    expect(screen.getByRole("status", { name: "正在刷新列表" })).toBeInTheDocument();
    expect(initial.loadMore).not.toHaveBeenCalled();
    // 刷新完成（invalidated 清除）→ 恢复正常加载更多
    rerender(<DirectoryLoadMore {...initial} hasMore error={null} />);
    expect(screen.getByRole("button", { name: "加载更多" })).toBeInTheDocument();
  });

  it("加载与空终页不缩矮；后续尺寸增长继续保留并清理观察器", () => {
    // bcb00dc 起错误静默隐藏页尾，不再有"长错误撑高"场景；保留加载/终页不缩矮契约。
    let height = 80;
    let resize: ResizeObserverCallback | undefined;
    const disconnect = vi.fn();
    vi.spyOn(HTMLElement.prototype, "offsetHeight", "get").mockImplementation(() => height);
    vi.stubGlobal("ResizeObserver", class {
      observe = vi.fn();
      unobserve = vi.fn();
      disconnect = disconnect;
      constructor(callback: ResizeObserverCallback) { resize = callback; }
    });
    const initial = props();
    const { rerender, unmount } = render(<DirectoryLoadMore {...initial} />);
    const footer = document.querySelector<HTMLElement>(".directory-load-more")!;
    expect(footer.style.minHeight).toBe("80px");

    height = 184;
    rerender(<DirectoryLoadMore {...initial} loading />);
    expect(footer.style.minHeight).toBe("184px");
    height = 80;
    rerender(<DirectoryLoadMore {...initial} hasMore={false} />);
    expect(footer.style.minHeight).toBe("184px");
    height = 220;
    resize!([], {} as ResizeObserver);
    expect(footer.style.minHeight).toBe("220px");
    unmount();
    expect(disconnect).toHaveBeenCalledTimes(1);
  });

  it("错误、进行中、游标失效及终页均停止自动加载，恢复后重新观察同一页尾", () => {
    const observers: Array<{ emit: () => void; disconnect: ReturnType<typeof vi.fn> }> = [];
    vi.stubGlobal("IntersectionObserver", class {
      observe = vi.fn();
      unobserve = vi.fn();
      disconnect = vi.fn();
      constructor(callback: IntersectionObserverCallback) {
        observers.push({
          emit: () => callback([{ isIntersecting: true } as IntersectionObserverEntry], this as unknown as IntersectionObserver),
          disconnect: this.disconnect,
        });
      }
    });
    const initial = props();
    const { rerender, unmount } = render(<DirectoryLoadMore {...initial} />);
    expect(observers).toHaveLength(1);
    observers[0].emit();
    expect(initial.loadMore).toHaveBeenCalledTimes(1);

    rerender(<DirectoryLoadMore {...initial} error="稍后重试" />);
    expect(observers[0].disconnect).toHaveBeenCalledTimes(1);
    rerender(<DirectoryLoadMore {...initial} loading />);
    rerender(<DirectoryLoadMore {...initial} invalidated />);
    rerender(<DirectoryLoadMore {...initial} hasMore={false} />);
    expect(observers).toHaveLength(1);
    expect(initial.loadMore).toHaveBeenCalledTimes(1);

    rerender(<DirectoryLoadMore {...initial} />);
    expect(observers).toHaveLength(2);
    unmount();
    expect(observers[1].disconnect).toHaveBeenCalledTimes(1);
  });
});
