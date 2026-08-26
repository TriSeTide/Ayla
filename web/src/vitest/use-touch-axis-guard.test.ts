/**
 * useTouchAxisGuard / decideAxisPreventDefault 测试：起步定轴与浏览器滚动让位判定。
 */
import { describe, expect, it } from "vitest";
import { AXIS_GUARD_SLOP, decideAxisPreventDefault } from "../hooks/useTouchAxisGuard";

describe("decideAxisPreventDefault", () => {
  it("未达 slop → null（继续观察，不干预）", () => {
    expect(decideAxisPreventDefault(3, 2, "x")).toBeNull();
    expect(decideAxisPreventDefault(0, 0, "x")).toBeNull();
  });

  it(`默认 slop = ${AXIS_GUARD_SLOP}px（必须小于浏览器手势 slop 才能赢得竞速）`, () => {
    expect(AXIS_GUARD_SLOP).toBeLessThan(8);
  });

  it("横轴占优且保护轴为 x → true（拦下浏览器垂直滚动，drag 接管）", () => {
    // 模拟真机横滑：水平大幅领先，垂直只有抖动
    expect(decideAxisPreventDefault(12, 4, "x")).toBe(true);
    expect(decideAxisPreventDefault(-30, 10, "x")).toBe(true);
  });

  it("竖轴占优且保护轴为 x → false（让位给浏览器正常滚动）", () => {
    expect(decideAxisPreventDefault(5, 20, "x")).toBe(false);
    expect(decideAxisPreventDefault(-6, 25, "x")).toBe(false);
  });

  it("两轴相等 → 按 x 胜出（>= 语义，与 useSwipe lockAxis 一致）", () => {
    expect(decideAxisPreventDefault(6, 6, "x")).toBe(true);
    expect(decideAxisPreventDefault(6, 6, "y")).toBe(false);
  });

  it("axis=y 对称：竖向占优拦截、横向占优让位（当前纵向 pager 无需挂载，契约留档）", () => {
    expect(decideAxisPreventDefault(4, 15, "y")).toBe(true);
    expect(decideAxisPreventDefault(15, 4, "y")).toBe(false);
  });

  it("恰好达到 slop 即定轴", () => {
    expect(decideAxisPreventDefault(AXIS_GUARD_SLOP, 0, "x")).toBe(true);
    expect(decideAxisPreventDefault(0, AXIS_GUARD_SLOP, "x")).toBe(false);
  });

  it("自定义 slop 生效", () => {
    expect(decideAxisPreventDefault(8, 1, "x", 10)).toBeNull();
    expect(decideAxisPreventDefault(12, 1, "x", 10)).toBe(true);
  });
});
