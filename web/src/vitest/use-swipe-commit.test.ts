/**
 * resolveSwipeCommit 松手切换判定测试（useSwipeCommit 公共层）。
 *
 * 覆盖 2026-08-26 手势修复的四个目标行为：
 * - 净位移不足阈值 → 回弹不切；
 * - 方向锁让位：交叉轴（垂直滚动）净位移占优 → 不切；
 * - 划回原地（净位移≈0）→ 即使松手瞬间速度大也不切；
 * - 同向快速甩动（速度达标 + 最小位移）→ 切。
 */
import { describe, expect, it } from "vitest";
import {
  SWIPE_FLICK_VELOCITY,
  SWIPE_MIN_FLICK_DISTANCE,
  resolveSwipeCommit,
} from "../hooks/useSwipeCommit";

/** 横滑基准容器宽 375（主阈值 = 125px） */
const W = 375;

describe("resolveSwipeCommit 主判定（净位移过阈值）", () => {
  it("左滑净位移 >1/3 宽 → 1（切 next），慢速也切", () => {
    expect(resolveSwipeCommit({ net: -130, cross: 0, velocity: -10, size: W })).toBe(1);
    expect(resolveSwipeCommit({ net: -200, cross: 20, velocity: 0, size: W })).toBe(1);
  });

  it("右滑净位移 >1/3 宽 → -1（切 prev）", () => {
    expect(resolveSwipeCommit({ net: 130, cross: 0, velocity: 10, size: W })).toBe(-1);
  });

  it("恰好等于主阈值 → 切（>= 语义，与 useSwipe 阈值一致）", () => {
    expect(resolveSwipeCommit({ net: -(W / 3), cross: 0, velocity: 0, size: W })).toBe(1);
    expect(resolveSwipeCommit({ net: W / 3, cross: 0, velocity: 0, size: W })).toBe(-1);
  });

  it("竖向 pager：上滑净位移 >1/3 高 → 1（切 next 直播间）", () => {
    expect(resolveSwipeCommit({ net: -250, cross: 0, velocity: -100, size: 600 })).toBe(1);
    expect(resolveSwipeCommit({ net: 250, cross: 0, velocity: 100, size: 600 })).toBe(-1);
  });
});

describe("resolveSwipeCommit 净位移不足 → 不切", () => {
  it("轻扫一点（位移 < 阈值）且速度未达标 → 0（回归「太灵敏」）", () => {
    // 旧实现里 velocity 单位错当 px/ms，0.3px/s ≈ 任何微小速度都触发
    expect(resolveSwipeCommit({ net: -30, cross: 5, velocity: -80, size: W })).toBe(0);
    expect(resolveSwipeCommit({ net: 40, cross: -8, velocity: 120, size: W })).toBe(0);
  });

  it("划回原地（净位移≈0）→ 无论松手瞬时速度多大都不切", () => {
    // 往左又往右拉回起点：净位移归零，只有结束瞬间的反向速度
    expect(resolveSwipeCommit({ net: -3, cross: 2, velocity: 900, size: W })).toBe(0);
    expect(resolveSwipeCommit({ net: 2, cross: -1, velocity: -900, size: W })).toBe(0);
  });

  it("速度反向（与净位移异号）→ 不能作为该方向甩动的证据 → 0", () => {
    expect(
      resolveSwipeCommit({
        net: -60,
        cross: 0,
        velocity: 500, // 向右的回拉速度，不能支持「向左甩」
        size: W,
      }),
    ).toBe(0);
  });
});

describe("resolveSwipeCommit 同向甩动补充判定", () => {
  it(`同向速度 ≥ ${SWIPE_FLICK_VELOCITY}px/s 且位移 ≥ ${SWIPE_MIN_FLICK_DISTANCE}px → 切`, () => {
    expect(resolveSwipeCommit({ net: -60, cross: 5, velocity: -450, size: W })).toBe(1);
    expect(resolveSwipeCommit({ net: 60, cross: -5, velocity: 450, size: W })).toBe(-1);
  });

  it("速度达标但位移 < 最小甩动距离 → 0（防高速微动误判）", () => {
    expect(
      resolveSwipeCommit({ net: -(SWIPE_MIN_FLICK_DISTANCE - 1), cross: 0, velocity: -800, size: W }),
    ).toBe(0);
  });

  it("位移达标但速度略低于阈值 → 0（慢拖必须靠净位移过阈值）", () => {
    expect(
      resolveSwipeCommit({ net: -(SWIPE_MIN_FLICK_DISTANCE + 10), cross: 0, velocity: -299, size: W }),
    ).toBe(0);
  });
});

describe("resolveSwipeCommit 方向锁让位", () => {
  it("交叉轴净位移占优（竖刷歪一点）→ 即使主轴过阈值也不切", () => {
    // 竖向刷列表时 x 抖动 130px 但 y 已滚 260px → 让位给滚动
    expect(resolveSwipeCommit({ net: -130, cross: 260, velocity: -400, size: W })).toBe(0);
    expect(resolveSwipeCommit({ net: 140, cross: -180, velocity: 300, size: W })).toBe(0);
  });

  it("交叉轴与主轴相等 → 让位不切（>= 语义）", () => {
    expect(resolveSwipeCommit({ net: -150, cross: 150, velocity: 0, size: W })).toBe(0);
  });

  it("竖向 pager 的方向锁：横向抖动占优时不上下切", () => {
    expect(resolveSwipeCommit({ net: -220, cross: 240, velocity: -350, size: 600 })).toBe(0);
  });
});

describe("resolveSwipeCommit 可覆写选项", () => {
  it("自定义 threshold / flickVelocity / minFlickDistance 生效", () => {
    const input = { net: -90, cross: 0, velocity: -100, size: 600 };
    expect(resolveSwipeCommit(input)).toBe(0); // 默认阈值 200 不切
    expect(resolveSwipeCommit(input, { threshold: 80 })).toBe(1); // 过自定义阈值即切
    expect(
      resolveSwipeCommit(input, { flickVelocity: 90, minFlickDistance: 80 }),
    ).toBe(1); // 作为甩动切
  });
});
