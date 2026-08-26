/**
 * usePagerTouchRouter 路由判定测试：视频区直切 / 弹幕区滚动优先 / 边界接力。
 */
import { describe, expect, it } from "vitest";
import {
  PAGER_AXIS_SLOP,
  decidePagerRoute,
  listScrollState,
} from "../hooks/usePagerTouchRouter";

describe("decidePagerRoute 定轴", () => {
  it(`未达 slop(${PAGER_AXIS_SLOP}px) → idle（继续观察）`, () => {
    expect(decidePagerRoute(0, -6, true, true, false)).toBe("idle");
    expect(decidePagerRoute(0, 0, false, false, false)).toBe("idle");
  });

  it("横向占优 → idle（水平让位，不参与切台路由）", () => {
    expect(decidePagerRoute(-30, -10, false, false, true)).toBe("idle");
    expect(decidePagerRoute(25, 12, true, false, false)).toBe("idle");
  });

  it("恰好等于 slop 即定轴", () => {
    expect(decidePagerRoute(0, -8, true, true, false)).toBe("drag");
  });
});

describe("decidePagerRoute 区域分流", () => {
  it("视频区起手竖划 → 直接 drag（跟手切台）", () => {
    expect(decidePagerRoute(0, -40, false, false, false)).toBe("drag");
    expect(decidePagerRoute(5, 60, false, true, true)).toBe("drag");
  });

  it("弹幕区未到底时上拉 → scroll（列表滚动优先）", () => {
    expect(decidePagerRoute(0, -50, true, true, true)).toBe("scroll");
  });

  it("弹幕区已到底仍上拉 → drag（接力切下一个直播间）", () => {
    expect(decidePagerRoute(0, -50, true, true, false)).toBe("drag");
  });

  it("弹幕区未到顶时下拉 → scroll", () => {
    expect(decidePagerRoute(0, 50, true, true, true)).toBe("scroll");
  });

  it("弹幕区已到顶仍下拉 → drag（接力切上一个直播间）", () => {
    expect(decidePagerRoute(0, 50, true, false, false)).toBe("drag");
  });

  it("弹幕区到顶但继续上拉 → scroll（方向上还有内容）", () => {
    // 到顶只封死「下拉」，上拉仍应滚列表
    expect(decidePagerRoute(0, -50, true, false, true)).toBe("scroll");
  });
});

describe("listScrollState 边界计算", () => {
  it("顶部：canScrollUp=false、canScrollDown=true（内容超高）", () => {
    expect(listScrollState(0, 1000, 300)).toEqual({ canScrollUp: false, canScrollDown: true });
  });

  it("底部：canScrollUp=true、canScrollDown=false", () => {
    expect(listScrollState(700, 1000, 300)).toEqual({ canScrollUp: true, canScrollDown: false });
  });

  it("中间：两方向都可滚", () => {
    expect(listScrollState(350, 1000, 300)).toEqual({ canScrollUp: true, canScrollDown: true });
  });

  it("内容不足一屏（maxScroll=0）：双向都不可滚 → 上拉/下拉都接力切台", () => {
    expect(listScrollState(0, 200, 300)).toEqual({ canScrollUp: false, canScrollDown: false });
  });
});
