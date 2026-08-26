/**
 * useMasonryColumns —— 双列等宽错排瀑布流（方案 §4-U2）。
 *
 * 语义：把一维列表 items 分配到 N 列（宽屏帖子流 N=2，窄屏 N=1），列宽一致、
 * 高度随内容错落。新 item 按「当前较矮列优先」插入；每列高度由 ResizeObserver
 * 实测（offsetHeight，不受 reveal 的 opacity/transform 影响），用于下一次分配决策。
 *
 * 稳定性约束（配合 U14 滚动进度恢复）：
 * - item → 列 的分配一旦确定就锁定，永不因高度测量而重排（避免视觉跳动与
 *   恢复错位）；
 * - 分配记忆存模块级 Map（按 memoryKey 隔离），跨组件卸载/重挂载（进详情→返回）
 *   恢复，保证返回时列布局与离开时一致，scrollTop 才能精确恢复。
 *
 * 预估增量：同批新 item（如翻页一页）尚无实测高度，分配后给该列加一个
 * ESTIMATED_ITEM_HEIGHT 预估，使同批交错分配；渲染后 RO 用真实列高覆盖修正。
 */
import { useEffect, useMemo, useRef } from "react";

/** 新帖无实测高度时的预估卡高（px），仅用于同批分配的临时决策。 */
const ESTIMATED_ITEM_HEIGHT = 320;

/** 模块级分配记忆：memoryKey → (itemKey → columnIndex)。跨挂载恢复。 */
const columnMemory = new Map<string, Map<string | number, number>>();

/** 清空分配记忆（测试隔离用）。 */
export function clearMasonryMemory(): void {
  columnMemory.clear();
}

export function useMasonryColumns<T>(
  items: T[],
  columnCount: number,
  getKey: (item: T) => string | number,
  memoryKey: string,
): {
  /** 按列分组后的 item 列表；长度恒等于 columnCount。 */
  columns: T[][];
  /** 每列的 ref 回调（供 ResizeObserver 量高挂载），长度恒等于 columnCount。 */
  columnRefs: ((el: HTMLDivElement | null) => void)[];
} {
  // 分配记忆（跨挂载持久化，返回时恢复列布局）。
  // 记忆按「memoryKey + columnCount」隔离：断点切换（单列↔双列）不继承旧分配——
  // 单列时代全部 item 记在 col0，列数变 2 后 col0 是合法索引、越界检查拦不住，
  // 会把所有卡挤进一列（2026-08-26 实测：col=[20,0]）。
  const scopedKey = `${memoryKey}:${columnCount}`;
  const assignment = useMemo(() => {
    let m = columnMemory.get(scopedKey);
    if (!m) {
      m = new Map<string | number, number>();
      columnMemory.set(scopedKey, m);
    }
    return m;
  }, [scopedKey]);

  // 每列实测累计高度（RO 更新；分配决策只在此读最新值）。
  // 列数变化时重置（旧列高属于旧布局，RO 实测会很快覆盖）。
  const colHeights = useRef<number[]>(Array.from({ length: columnCount }, () => 0));
  if (colHeights.current.length !== columnCount) {
    colHeights.current = Array.from({ length: columnCount }, () => 0);
  }

  // 列容器 DOM（RO 观察目标）
  const colEls = useRef<(HTMLDivElement | null)[]>([]);

  // getKey 经 ref 转发，避免调用方内联函数引用变化触发无谓重算
  const getKeyRef = useRef(getKey);
  getKeyRef.current = getKey;

  // 分配：新 item 插较矮列（预估增量），已分配 item 保持原列（含 columnCount 越界重分配）
  const columns = useMemo(() => {
    const cols: T[][] = Array.from({ length: columnCount }, () => []);
    // 确保高度数组长度对齐 columnCount（断点切换时）
    const heights = colHeights.current;
    while (heights.length < columnCount) heights.push(0);
    if (heights.length > columnCount) heights.length = columnCount;

    // 清理已不存在的 item 分配（刷新/reset 后 id 集合变化）
    const liveKeys = new Set<string | number>();
    for (const item of items) liveKeys.add(getKeyRef.current(item));
    for (const k of [...assignment.keys()]) {
      if (!liveKeys.has(k)) assignment.delete(k);
    }

    for (const item of items) {
      const k = getKeyRef.current(item);
      let c = assignment.get(k);
      if (c === undefined || c >= columnCount) {
        // 新 item（或断点切换后越界）：插入当前最矮列
        let shortest = 0;
        for (let i = 1; i < columnCount; i++) {
          if (heights[i] < heights[shortest]) shortest = i;
        }
        c = shortest;
        assignment.set(k, c);
        // 预估增量：让同批新 item 交错而非堆同一列
        heights[c] += ESTIMATED_ITEM_HEIGHT;
      }
      cols[c].push(item);
    }
    return cols;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [items, columnCount, assignment]);

  // ResizeObserver 量每列真实高度（单列/无 RO 环境跳过）
  useEffect(() => {
    if (columnCount <= 1 || typeof ResizeObserver === "undefined") return;
    const ro = new ResizeObserver(() => {
      colHeights.current = colEls.current.map((el) => el?.offsetHeight ?? 0);
    });
    for (let i = 0; i < columnCount; i++) {
      const el = colEls.current[i];
      if (el) ro.observe(el);
    }
    return () => ro.disconnect();
  }, [columnCount]);

  // 每列 ref 回调（稳定引用，避免每 render 重建）
  const columnRefs = useMemo(
    () =>
      Array.from({ length: columnCount }, (_, i) => (el: HTMLDivElement | null) => {
        colEls.current[i] = el;
      }),
    [columnCount],
  );

  return { columns, columnRefs };
}
