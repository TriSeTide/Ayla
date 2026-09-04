/**
 * FullScreenSwipeBack —— 窄屏全屏右滑返回包装（复用 useEdgeSwipeBack from:'full'）。
 *
 * 语义（与私聊/群外详情等统一，用户拍板 2026-09-04：全站统一「全屏右滑 + 跟手平移 +
 * 松手返回」，底层淡入不再保留）：
 * - 全屏任意位置右滑：当前内容 1:1 跟手右移（framer-motion x），松手过阈值 onBack，
 *   否则 200ms 回弹；快速滑（速度 ≥0.3px/ms）即使位移不足也返回。
 * - 方向锁（useSwipe）：垂直滚动优先，axis="y" 完全不跟手、原生滚动照常（不 preventDefault）；
 *   点击无位移不误触。
 * - 群内场景不启用：调用方传 enabled=false 或不用本组件（群内用群场景顶部导航返回）。
 *
 * 用法：把当前页面内容包进本组件，onBack 传该页面的返回回调（navigate(-1) 或固定路由）。
 * 注意：本组件是 motion.div，需撑满高度（默认 height:100%），内部页面自带滚动。
 */
import { motion } from "framer-motion";
import type { ReactNode } from "react";
import { useEdgeSwipeBack } from "../../hooks/useEdgeSwipeBack";

export interface FullScreenSwipeBackProps {
  /** 松手过阈值/快速滑后调用的返回回调 */
  onBack: () => void;
  /** 是否启用（窄屏传 isNarrow；宽屏/群内传 false 关闭手势） */
  enabled?: boolean;
  /** 透传到 motion.div 的 className（用于撑满/布局） */
  className?: string;
  children: ReactNode;
}

export function FullScreenSwipeBack({
  onBack,
  enabled = true,
  className,
  children,
}: FullScreenSwipeBackProps) {
  const { handlers, x } = useEdgeSwipeBack({ onBack, from: "full", enabled });
  return (
    <motion.div
      className={className ? `fullscreen-swipe-back ${className}` : "fullscreen-swipe-back"}
      style={{ x }}
      {...handlers}
    >
      {children}
    </motion.div>
  );
}
