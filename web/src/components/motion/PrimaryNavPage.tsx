/**
 * PrimaryNavPage —— 窄屏一级五页横滑转场容器（方案 §3.1）。
 *
 * 与 GroupPage 群内横滑（§2.2，M1b 已落地）同款：motion.div `drag="x"` +
 * dragConstraints={0} + dragElastic（跟手 + 边缘阻尼 + 松手回弹），onDragEnd 按
 * 位移(>1/3 宽) + 速度判定切换相邻一级页（navigate）；切换用 AnimatePresence
 * (custom=direction) + variants（enter ±40%→0 / exit ∓30%→透明），direction 由
 * 一级 tab 顺序索引差计算（usePrimaryNavSwipeDirection）。单页挂载（AnimatePresence
 * 保管退出中的旧实例，动画完即卸载，重组件不并排常挂）。
 *
 * 与 PageTransition（§2.1）协同避免双重动画：一级页之间切换走本组件横滑
 * （不叠加 PageTransition 的 y 浮入）；一级页 ↔ 非一级页切换时 direction=0 →
 * 本组件仅淡入/淡出（无横向位移），进出动画语义不变。
 *
 * 布局复用 .page-transition（absolute inset:0，shell.css）——同为 AppShell 内容区
 * 转场容器，横滑位移超出视口部分由 .app-shell-content 的 overflow:hidden 裁剪。
 * prefers-reduced-motion 下 drag 关闭，只留透明度渐变（design.md §7）。
 */
import { useCallback, useMemo, useRef, useState } from "react";
import { motion } from "framer-motion";
import type { PanInfo } from "framer-motion";
import type { ReactNode } from "react";
import { PRIMARY_TAB_PATHS } from "../../layout/shellConfig";

/** 等价 tokens.css --ease-out / --ease-in（framer-motion ease 需 cubic-bezier 元组） */
const EASE_OUT: [number, number, number, number] = [0.22, 0.61, 0.36, 1];
const EASE_IN: [number, number, number, number] = [0.4, 0, 1, 1];

/** 横滑切换：滑入/滑出 250ms ease-out（design.md §7 面板进出 200-300ms） */
const SLIDE_DURATION = 0.25;
/** 快速滑速度阈值 px/ms（≈300px/s，与群内横滑同款） */
const FLICK_VELOCITY = 0.3;
/** drag 约束（钉在原点，配合 dragElastic 提供边缘阻尼 + 松手回弹） */
const DRAG_CONSTRAINTS = { left: 0, right: 0 };
/** 跟手弹性：0.8 = 80% 跟手 + 20% 边缘阻尼（接近 1:1，避免拖过头） */
const DRAG_ELASTIC = 0.8;

function prefersReducedMotion(): boolean {
  return (
    typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches
  );
}

export function PrimaryNavPage({
  pathname,
  direction,
  onNavigate,
  children,
}: {
  pathname: string;
  /** 本次切换方向（usePrimaryNavSwipeDirection 输出，1/-1/0） */
  direction: 1 | -1 | 0;
  onNavigate: (path: string) => void;
  children: ReactNode;
}) {
  // 惰性同步读取 reduced-motion（非 effect）：用户首帧即无位移，避免一帧浮入闪跳
  const [reduced] = useState(prefersReducedMotion);
  const pageRef = useRef<HTMLDivElement>(null);

  // 转场变体：reduced-motion 直切（仅透明度）；否则横滑方向变体（enter ±40%→0 / exit ∓30%→透明）
  const variants = useMemo(
    () =>
      reduced
        ? {
            enter: { opacity: 1 },
            center: { opacity: 1 },
            exit: { opacity: 0 },
          }
        : {
            enter: (dir: number) => ({
              x: dir === 0 ? 0 : `${dir * 40}%`,
              opacity: 1,
              transition: { duration: SLIDE_DURATION, ease: EASE_OUT },
            }),
            center: { x: 0, opacity: 1 },
            exit: (dir: number) => ({
              x: dir === 0 ? 0 : `${dir * -30}%`,
              opacity: 0,
              transition: { duration: SLIDE_DURATION, ease: EASE_IN },
            }),
          },
    [reduced],
  );

  // 位移(>1/3 宽) + 速度判定切换相邻一级页；否则 dragElastic 自动回弹到 0
  const handleDragEnd = useCallback(
    (_event: unknown, info: PanInfo) => {
      const width = pageRef.current?.clientWidth ?? 375;
      const threshold = width / 3;
      const normalized = pathname === "/home" ? "/group" : pathname;
      const idx = PRIMARY_TAB_PATHS.indexOf(normalized);
      if (idx < 0) return;
      if (info.offset.x < -threshold || info.velocity.x < -FLICK_VELOCITY) {
        onNavigate(PRIMARY_TAB_PATHS[(idx + 1) % PRIMARY_TAB_PATHS.length]);
      } else if (info.offset.x > threshold || info.velocity.x > FLICK_VELOCITY) {
        onNavigate(
          PRIMARY_TAB_PATHS[(idx - 1 + PRIMARY_TAB_PATHS.length) % PRIMARY_TAB_PATHS.length],
        );
      }
    },
    [pathname, onNavigate],
  );

  const canDrag = !reduced;

  return (
    <motion.div
      ref={pageRef}
      className="page-transition primary-nav-page"
      custom={direction}
      variants={variants}
      initial="enter"
      animate="center"
      exit="exit"
      drag={canDrag ? "x" : false}
      dragConstraints={DRAG_CONSTRAINTS}
      dragElastic={DRAG_ELASTIC}
      dragMomentum={false}
      onDragEnd={handleDragEnd}
    >
      {children}
    </motion.div>
  );
}
