/**
 * PullToRefresh 测试（方案 §3.3）：
 * - dampPull：阻尼递增、封顶；
 * - createPullTracker（纯状态机）：canPull / 跟手 / 阈值 / 上滑归零 / cancel；
 * - 组件（reduced-motion，避开 framer-motion animate 与 timer 的不确定性）：
 *   渲染 children、下拉过阈值触发 onRefresh、不足阈值不触发、disabled 不响应。
 */
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createPullTracker, dampPull, PullToRefresh } from "../components/motion/PullToRefresh";

function mockReduced(reduced: boolean) {
  vi.stubGlobal(
    "matchMedia",
    vi.fn(() => ({
      get matches() {
        return reduced;
      },
      addEventListener: () => {},
      removeEventListener: () => {},
    })),
  );
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("dampPull", () => {
  it("dy<=0 → 0", () => {
    expect(dampPull(0)).toBe(0);
    expect(dampPull(-10)).toBe(0);
  });

  it("阻尼递增且封顶 maxPull", () => {
    expect(dampPull(64)).toBeGreaterThan(0);
    expect(dampPull(64)).toBeLessThan(64); // 视觉位移 < 手指位移
    expect(dampPull(1000)).toBeLessThanOrEqual(96); // 封顶
    // 阻尼递增：位移翻倍时视觉增量递减
    const a = dampPull(40);
    const b = dampPull(80);
    expect(b - a).toBeLessThan(a);
  });
});

describe("createPullTracker", () => {
  function makeTracker(canPull: () => boolean) {
    const onOffsetChange = vi.fn();
    const onPullEnd = vi.fn();
    const onPullCancel = vi.fn();
    const tracker = createPullTracker({
      threshold: 64,
      canPull,
      onOffsetChange,
      onPullEnd,
      onPullCancel,
    });
    return { tracker, onOffsetChange, onPullEnd, onPullCancel };
  }

  it("canPull=false → 不跟踪", () => {
    const { tracker, onOffsetChange } = makeTracker(() => false);
    tracker.start(0);
    expect(tracker.isTracking()).toBe(false);
    tracker.move(80);
    expect(onOffsetChange).not.toHaveBeenCalled();
  });

  it("canPull=true → 下拉跟手，过阈值松手 onPullEnd(true)", () => {
    const { tracker, onOffsetChange, onPullEnd } = makeTracker(() => true);
    tracker.start(0);
    tracker.move(80);
    expect(tracker.isTracking()).toBe(true);
    expect(onOffsetChange).toHaveBeenLastCalledWith(dampPull(80));
    tracker.end(80);
    expect(onPullEnd).toHaveBeenCalledWith(true);
  });

  it("不足阈值 → onPullEnd(false)", () => {
    const { tracker, onPullEnd } = makeTracker(() => true);
    tracker.start(0);
    tracker.move(40);
    tracker.end(40);
    expect(onPullEnd).toHaveBeenCalledWith(false);
  });

  it("上滑（dy<=0）→ 位移归零", () => {
    const { tracker, onOffsetChange } = makeTracker(() => true);
    tracker.start(0);
    tracker.move(50);
    tracker.move(-10);
    expect(onOffsetChange).toHaveBeenLastCalledWith(0);
  });

  it("cancel → onPullCancel 且不再跟踪", () => {
    const { tracker, onPullCancel } = makeTracker(() => true);
    tracker.start(0);
    tracker.move(50);
    tracker.cancel();
    expect(onPullCancel).toHaveBeenCalledTimes(1);
    expect(tracker.isTracking()).toBe(false);
  });
});

describe("PullToRefresh 组件（reduced-motion）", () => {
  function renderPTR(props: Partial<React.ComponentProps<typeof PullToRefresh>> = {}) {
    const onRefresh = props.onRefresh ?? vi.fn().mockResolvedValue(undefined);
    const utils = render(
      <PullToRefresh onRefresh={onRefresh} isAtTop={() => true} {...props}>
        <div>列表内容</div>
      </PullToRefresh>,
    );
    const wrap = utils.container.firstChild as HTMLElement;
    return { onRefresh, wrap };
  }

  it("渲染 children", () => {
    mockReduced(true);
    renderPTR();
    expect(screen.getByText("列表内容")).toBeInTheDocument();
  });

  it("下拉过阈值 → 调用 onRefresh", async () => {
    mockReduced(true);
    const { onRefresh, wrap } = renderPTR();
    fireEvent.touchStart(wrap, { touches: [{ clientX: 0, clientY: 0 }] });
    fireEvent.touchMove(wrap, { touches: [{ clientX: 0, clientY: 80 }] });
    fireEvent.touchEnd(wrap, { changedTouches: [{ clientX: 0, clientY: 80 }] });
    await waitFor(() => expect(onRefresh).toHaveBeenCalledTimes(1));
  });

  it("不足阈值 → 不调用 onRefresh", () => {
    mockReduced(true);
    const { onRefresh, wrap } = renderPTR();
    fireEvent.touchStart(wrap, { touches: [{ clientX: 0, clientY: 0 }] });
    fireEvent.touchMove(wrap, { touches: [{ clientX: 0, clientY: 40 }] });
    fireEvent.touchEnd(wrap, { changedTouches: [{ clientX: 0, clientY: 40 }] });
    expect(onRefresh).not.toHaveBeenCalled();
  });

  it("disabled → 不响应下拉", () => {
    mockReduced(true);
    const { onRefresh, wrap } = renderPTR({ disabled: true });
    fireEvent.touchStart(wrap, { touches: [{ clientX: 0, clientY: 0 }] });
    fireEvent.touchMove(wrap, { touches: [{ clientX: 0, clientY: 80 }] });
    fireEvent.touchEnd(wrap, { changedTouches: [{ clientX: 0, clientY: 80 }] });
    expect(onRefresh).not.toHaveBeenCalled();
  });
});
