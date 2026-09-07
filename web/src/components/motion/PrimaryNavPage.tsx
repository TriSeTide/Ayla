/**
 * PrimaryNavPage —— 窄屏一级五页横滑转场容器（方案 §3.1）。
 *
 * 与 GroupPage 群内横滑（§2.2，M1b 已落地）同款：motion.div `drag="x"` +
 * dragConstraints={0} + dragElastic（跟手 + 边缘阻尼 + 松手回弹），onDragEnd 松手
 * 判定统一走 useSwipeCommit（净位移 >1/3 宽优先 + 同向甩动补充 + 方向锁让位，
 * pointercancel 不判定）切换相邻一级页（navigate）；切换用 AnimatePresence
 * (custom=direction) + Auroraqua variants（enter ±20px→0 / exit ∓20px→透明），direction 由
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
import { useCallback, useMemo, useRef } from "react";
import { motion } from "framer-motion";
import type { PanHandler, PanInfo } from "framer-motion";
import type { ReactNode } from "react";
import { PRIMARY_TAB_PATHS } from "../../layout/shellConfig";
import { resolveSwipeCommit } from "../../hooks/useSwipeCommit";
import { useTouchAxisGuard } from "../../hooks/useTouchAxisGuard";
import { usePrefersReducedMotion } from "../../hooks/usePrefersReducedMotion";
import { useMotionDrag } from "../../hooks/useMotionDrag";
import { directionalVariants } from "./auroraquaMotion";
/** drag 约束（钉在原点，配合 dragElastic 提供边缘阻尼 + 松手回弹） */
const DRAG_CONSTRAINTS = { left: 0, right: 0 };
/** 跟手弹性：0.8 = 80% 跟手 + 20% 边缘阻尼（接近 1:1，避免拖过头） */
const DRAG_ELASTIC = 0.8;

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
  const reduced = usePrefersReducedMotion();
  const pageRef = useRef<HTMLDivElement>(null);
  // 横滑轴守卫：起步 slop 内横轴占优时压制浏览器垂直滚动接管（touch-action: pan-y
  // 下真机斜向起手会被 pointercancel 提前杀死 drag，见 useTouchAxisGuard）
  useTouchAxisGuard(pageRef, "x");

  const variants = useMemo(() => directionalVariants(reduced), [reduced]);

  // 松手判定（useSwipeCommit 公共层）：净位移(>1/3 宽)优先 + 同向甩动补充 + 方向锁让位；
  // pointercancel（系统取消，手指未松开）不算松手决策；否则 dragElastic 自动回弹到 0
  const handleDragEnd: PanHandler = useCallback(
    (event, info: PanInfo) => {
      if (event.type === "pointercancel") return;
      const width = pageRef.current?.clientWidth ?? 375;
      const normalized = pathname === "/home" ? "/group" : pathname;
      const idx = PRIMARY_TAB_PATHS.indexOf(normalized);
      if (idx < 0) return;
      const commit = resolveSwipeCommit({
        net: info.offset.x,
        cross: info.offset.y,
        velocity: info.velocity.x,
        size: width,
      });
      if (commit === 0) return;
      onNavigate(
        PRIMARY_TAB_PATHS[(idx + commit + PRIMARY_TAB_PATHS.length) % PRIMARY_TAB_PATHS.length],
      );
    },
    [pathname, onNavigate],
  );

  const canDrag = !reduced;
  const drag = useMotionDrag(canDrag, handleDragEnd);

  return (
    <motion.div
      className="page-transition primary-nav-page"
      custom={direction}
      variants={variants}
      initial="enter"
      animate="center"
      exit="exit"
      style={{ pointerEvents: drag.present ? undefined : "none" }}
    >
      {/* Drag must not stop the route animation or use its entering x as an origin. */}
      <motion.div
        ref={pageRef}
        className="primary-nav-drag"
        inherit={false}
        drag={drag.allowed ? "x" : false}
        dragControls={drag.controls}
        style={{ x: drag.offset }}
        dragConstraints={DRAG_CONSTRAINTS}
        dragSnapToOrigin
        dragElastic={DRAG_ELASTIC}
        dragMomentum={false}
        onDragStart={drag.onDragStart}
        onDragEnd={drag.onDragEnd}
      >
        {children}
      </motion.div>
    </motion.div>
  );
}
