/**
 * useSwipeCommit —— framer-motion drag 松手切换判定（公共层，三处 pager 共用）。
 *
 * 背景（2026-08-26 手势修复）：群内五子横滑（GroupPage §2.2）、一级五页横滑
 * （PrimaryNavPage §3.1）、直播间上下滑（LiveRoomBody §2.5）此前各自内联
 * 「offset 超 1/3 容器 || velocity 超 0.3」判定，存在共性问题：
 *
 * 1. **速度单位错**：framer-motion `PanInfo.velocity` 的单位是 px/s（源码
 *    PanSession 内 millisecondsToSeconds 归一），旧代码按 px/ms 设计的 0.3
 *    实际是 0.3px/s ≈ 零——任何松手/取消瞬间的微小速度都满足，OR 条件把
 *    净位移阈值架空，「轻扫即切」。
 * 2. **pointercancel 也走 onDragEnd**：真机竖向滚动时浏览器按 touch-action
 *    接管并发 pointercancel，framer-motion 照常结束 session 并回调
 *    onDragEnd——用户手指未松开就被判了一次「松手」，叠加 (1) 即「还没松手
 *    就切页」+「竖刷误切」。因此调用方必须先过滤
 *    `event.type === "pointercancel"`（系统取消 ≠ 用户松手决策，回弹不判定）。
 * 3. **无方向锁让位**：净位移交叉轴占优（竖刷歪一点）时不该让位给切页判定。
 * 4. **甩动无最小距离下限**：快速回拉归位时瞬时速度很大，若无下限会被误判。
 *
 * 本模块把松手判定抽成单一纯函数 resolveSwipeCommit，对齐 useSwipe /
 * useEdgeSwipeBack 的「方向锁 / 阈值 / 可取消」语义：
 * - 主判定：主轴净位移（按下→松手的 info.offset）≥ 主阈值（容器 1/3）→ 切换；
 * - 补充：同向甩动（速度 ≥ flickVelocity 且净位移 ≥ minFlickDistance）→ 切换；
 * - 方向锁让位：交叉轴净位移 ≥ 主轴净位移 → 一律不切；
 * - 其余情况回弹不切换（划回原地净位移归零自然不切）。
 *
 * 配套建议：调用处 motion.div 加 `dragDirectionLock`（起手 slop 定轴后另一轴
 * 钉 0，跟手阶段也不横移）；`dragMomentum={false}` + dragConstraints={0} 保持
 * 松手回弹由 elastic 自动完成。
 */

/** 甩动速度阈值（px/s ≈ 0.3px/ms；注意 framer-motion velocity 单位是 px/s） */
export const SWIPE_FLICK_VELOCITY = 300;

/** 甩动最小净位移（px）：低于此距离即使速度快也不算甩动（防高速微动/回拉误判） */
export const SWIPE_MIN_FLICK_DISTANCE = 40;

/** 松手判定结果：1=正向切换（x 左滑 / y 上滑 → next）、-1=反向（→ prev）、0=回弹不切 */
export type SwipeCommitDirection = 1 | -1 | 0;

export interface SwipeCommitInput {
  /** 主轴净位移（x 向右 / y 向下为正，px） */
  net: number;
  /** 交叉轴净位移（px） */
  cross: number;
  /** 主轴松手速度（px/s，framer-motion PanInfo.velocity 语义） */
  velocity: number;
  /** 容器主轴尺寸（px），默认阈值按 size/3 计 */
  size: number;
}

export interface SwipeCommitOptions {
  /** 主阈值（px），默认 size/3 */
  threshold?: number;
  /** 甩动速度阈值（px/s），默认 SWIPE_FLICK_VELOCITY */
  flickVelocity?: number;
  /** 甩动最小净位移（px），默认 SWIPE_MIN_FLICK_DISTANCE */
  minFlickDistance?: number;
}

/**
 * 松手切换判定（纯函数，供单测与三处 pager 复用）。
 *
 * @param input 按下到松手的净位移/速度快照（framer-motion onDragEnd 的 info）
 * @param options 可覆写阈值；测试外的常规调用使用默认值即可
 */
export function resolveSwipeCommit(
  { net, cross, velocity, size }: SwipeCommitInput,
  options: SwipeCommitOptions = {},
): SwipeCommitDirection {
  // 方向锁让位（useSwipe lockAxis 同思路的松手版）：交叉轴净位移占优，
  // 本次手势属于垂直滚动/另一轴，不让位给切页判定。
  if (Math.abs(cross) >= Math.abs(net)) return 0;

  const distance = Math.abs(net);
  const forward = net < 0; // x 左滑 / y 上滑 → next

  // 主判定：净位移过阈值即切（慢拖到位也切，不看速度）
  if (distance >= (options.threshold ?? size / 3)) return forward ? 1 : -1;

  // 补充判定：同向快速甩动（速度达标 + 有意义的最小位移 + 方向一致）
  const flickVelocity = options.flickVelocity ?? SWIPE_FLICK_VELOCITY;
  const minFlickDistance = options.minFlickDistance ?? SWIPE_MIN_FLICK_DISTANCE;
  if (
    distance >= minFlickDistance &&
    Math.abs(velocity) >= flickVelocity &&
    Math.sign(velocity) === Math.sign(net)
  ) {
    return forward ? 1 : -1;
  }
  return 0;
}
