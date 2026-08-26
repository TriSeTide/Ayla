/**
 * useScrollRestore —— 列表返回滚动位置恢复（方案 §4-U14，同模式封装）。
 *
 * 语义：
 * - 滚动时把 scrollTop 实时写入模块级 Map（key 隔离）；
 * - 页面卸载或 active 变 false 时，保存「最后一次真实滚动事件值」，绝不重新读取
 *   退出动画中的 DOM scrollTop——AnimatePresence 延迟卸载阶段 DOM 可能已归零，读取它会
 *   把正确记忆覆盖成 0；
 * - 再挂载或 active 重新变 true 后，在内容 ready 时用 useLayoutEffect 恢复，并在下一帧
 *   再补一次（防列表/瀑布流同一提交里的尺寸落定晚于首次赋值）；
 * - restoring 表示本次列表激活是否命中历史位置，调用方据此禁 reveal stagger。
 *
 * active 用于「组件不卸载、只切换列表/详情 DOM」的场景（如 GroupPosts）；ready 表示
 * 列表内容已经渲染到滚动容器，避免空骨架阶段把 scrollTop clamp 回 0。
 */
import { useEffect, useLayoutEffect, useRef, useState } from "react";

const scrollMemory = new Map<string, number>();

/** 清空滚动位置内存（测试隔离用）。 */
export function clearScrollMemory(): void {
  scrollMemory.clear();
}

/**
 * 在路由/详情切换前同步保存当前位置。
 *
 * AnimatePresence 的退出 cleanup 发生时间不由列表组件掌控；详情入口在滚动容器仍存在时
 * 显式调用本函数，保证群内/群外都以用户点击瞬间的位置为权威记录。
 */
export function saveScrollPosition(key: string, el: HTMLElement | null): void {
  if (!el) return;
  scrollMemory.set(key, el.scrollTop);
}

export interface ScrollRestoreOptions {
  /** 当前是否渲染列表滚动容器；详情分支时传 false。 */
  active?: boolean;
  /** 列表内容是否已就绪并形成可恢复高度。 */
  ready?: boolean;
}

/**
 * @param key  列表唯一键（如 "live-hub"、"posts-feed"、"group-posts:54"）。
 * @param ref  滚动容器的 ref（scrollTop 的宿主元素）。
 * @param options active/ready 生命周期控制；缺省均为 true。
 */
export function useScrollRestore(
  key: string,
  ref: { current: HTMLElement | null },
  options: ScrollRestoreOptions = {},
): { restoring: boolean } {
  const active = options.active ?? true;
  const ready = options.ready ?? true;
  const [restoring, setRestoring] = useState<boolean>(
    () => active && (scrollMemory.get(key) ?? 0) > 0,
  );
  // 只由真实 scroll 事件更新；退出 cleanup 保存此值，不读可能已归零的退出 DOM。
  const latestTopRef = useRef(scrollMemory.get(key) ?? 0);
  const restoreRafRef = useRef<number | null>(null);

  useLayoutEffect(() => {
    if (!active) {
      setRestoring(false);
      return;
    }
    const saved = scrollMemory.get(key) ?? 0;
    latestTopRef.current = saved;
    setRestoring(saved > 0);
    if (!ready || saved <= 0) return;

    const el = ref.current;
    if (!el) return;
    el.scrollTop = saved;
    // 下一帧再补一次：同一提交中的瀑布流/列表列高可能在 layout effect 后才最终落定。
    restoreRafRef.current = requestAnimationFrame(() => {
      const current = ref.current;
      if (current && active) current.scrollTop = saved;
      restoreRafRef.current = null;
    });
    return () => {
      if (restoreRafRef.current != null) {
        cancelAnimationFrame(restoreRafRef.current);
        restoreRafRef.current = null;
      }
    };
  }, [active, key, ready, ref]);

  useEffect(() => {
    if (!active) return;
    const el = ref.current;
    if (!el) return;

    // 首次无历史时从当前 DOM 起步；有历史时保留已恢复值，避免 effect 初始化覆盖。
    if (!scrollMemory.has(key)) latestTopRef.current = el.scrollTop;
    const onScroll = () => {
      latestTopRef.current = el.scrollTop;
      scrollMemory.set(key, latestTopRef.current);
    };
    el.addEventListener("scroll", onScroll, { passive: true });
    return () => {
      // scroll 事件和详情入口的 saveScrollPosition 已即时写入 memory；cleanup 仅卸监听。
      // 不要在这里写回 latestTopRef：路由/退出阶段可能比显式保存更晚，反而覆盖最新位置。
      el.removeEventListener("scroll", onScroll);
    };
  }, [active, key, ref]);

  return { restoring };
}
