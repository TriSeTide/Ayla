/**
 * useScrollRestore —— 列表返回滚动位置恢复（方案 §4-U14，同模式封装）。
 *
 * 语义：
 * - 离开列表（组件卸载）时，把滚动容器当前 scrollTop 存入模块级内存（key 隔离）；
 * - 再次挂载时，若存在记录（scrollTop > 0），`useLayoutEffect` 在首次绘制前恢复位置；
 * - 返回 `restoring` 供调用方判断「本次是恢复进入而非首次进入」，用于跳过入场
 *   stagger（§7：滚动恢复与入场动画互斥，动画只在真正首次进入播）。
 *
 * 注意：
 * - scrollTop 是「瞬态恢复数据」，用模块级 Map 存储即可（不驱动 UI 重渲染，无需
 *   zustand store；游标/列表数据仍由各功能 store 权威缓存——本 hook 只负责滚动位置）。
 * - `restoring` 在本次挂载生命周期内保持稳定（useState 惰性初始化），保证恢复路径
 *   全程禁用 stagger，避免「恢复后重挂 reveal-item 再播动画」。
 */
import { useEffect, useLayoutEffect, useState } from "react";

const scrollMemory = new Map<string, number>();

/** 清空滚动位置内存（测试隔离用）。 */
export function clearScrollMemory(): void {
  scrollMemory.clear();
}

/**
 * @param key  列表唯一键（如 "live-hub"、"posts-feed"），跨路由保持稳定。
 * @param ref  滚动容器的 ref（scrollTop 的宿主元素）。
 * @returns { restoring } 本次挂载是否执行了滚动恢复。
 */
export function useScrollRestore(
  key: string,
  ref: { current: HTMLElement | null },
): { restoring: boolean } {
  const [restoring] = useState<boolean>(() => (scrollMemory.get(key) ?? 0) > 0);

  // 首次绘制前恢复（避免恢复前内容闪到顶部）；restoring 路径下调用方已禁 stagger。
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const saved = scrollMemory.get(key);
    if (saved && saved > 0) {
      el.scrollTop = saved;
    }
  }, [key, ref]);

  // 实时记录 scrollTop：离开（卸载）时内存已是最新，cleanup 再兜底一次。
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const onScroll = () => {
      scrollMemory.set(key, el.scrollTop);
    };
    el.addEventListener("scroll", onScroll, { passive: true });
    return () => {
      scrollMemory.set(key, el.scrollTop);
      el.removeEventListener("scroll", onScroll);
    };
  }, [key, ref]);

  return { restoring };
}
