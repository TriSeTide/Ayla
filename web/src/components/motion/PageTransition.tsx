/**
 * PageTransition —— 全局路由切换转场（方案 §2.1 / design.md §7）。
 *
 * - AppShell 内容区用 AnimatePresence(mode="sync") + 本组件作 keyed 子元素，
 *   配合 .page-transition 的 absolute 定位（CSS 手动 popLayout，新旧页重叠转场）：
 *   路由切换时新页浮入（opacity 0→1 + y 20px→0，200ms ease-out）、旧页淡出
 *   （opacity→0，150ms ease-in，退出快于进入，design.md §7）。
 *   （不用 AnimatePresence popLayout：其 layout projection 会接管 transform，吞掉 y 位移）
 * - 群页（/group/:id 及子场景）进入用「无位移淡入」：GroupPage 自带进群编排
 *   （useEnterGroupAnimation 顶栏上移），全局再浮入会双重位移——群页进入用现有编排、
 *   退出仍走全局淡出（方案 §2.1 注意）。
 * - prefers-reduced-motion：只留透明度渐变（进入淡入 / 退出淡出），关闭位移（§7）。
 * - 时长/曲线对齐 tokens.css：--ease-out = cubic-bezier(.22,.61,.36,1)、
 *   --ease-in = cubic-bezier(.4,0,1,1)；framer-motion 用等价 4 元组。
 */
import { motion } from "framer-motion";
import { matchPath } from "react-router-dom";
import { useState } from "react";
import type { ReactNode } from "react";

/** 等价 tokens.css --ease-out / --ease-in（framer-motion ease 需 cubic-bezier 元组） */
const EASE_OUT: [number, number, number, number] = [0.22, 0.61, 0.36, 1];
const EASE_IN: [number, number, number, number] = [0.4, 0, 1, 1];

const ENTER_DURATION = 0.2; // 200ms ease-out（design.md §7 面板进出 200-300ms）
const EXIT_DURATION = 0.15; // 150ms ease-in（退出快于进入）
const RISE_DISTANCE = 20; // 进入位移（px）：默认浮入 +20 从下往上 / 搜索展开 -20 从上往下

/** 群页路由模式（与 shellConfig.isGroupScene 同源；此处需返回 groupId 供 key 归一化） */
const GROUP_PATTERNS = [
  "/group/:id",
  "/group/:id/:scene",
  "/group/:id/posts/:postId",
  "/group/:id/voice/:voiceChannelId",
];

function matchGroupId(pathname: string): string | null {
  for (const pattern of GROUP_PATTERNS) {
    const m = matchPath({ path: pattern, end: true }, pathname);
    if (m?.params.id) return m.params.id;
  }
  return null;
}

/**
 * 路由转场 key：
 * - 群页所有变体归一为 `/group/:id`，避免群内场景切换
 *   （/group/:id → /group/:id/posts 等）触发整页重挂载 + 进群编排重跑；
 * - 直播间详情归一为 `/live/room`，避免直播间上下滑切换（/live/:id → /live/:id）
 *   触发整页重挂载（底栏滑出动画复位）；进入/退出直播间（/live ↔ /live/:id）
 *   仍走整页转场；
 * - 其余路由用原始 pathname。
 */
const LIVE_ROOM_PATTERN = "/live/:id";

export function resolvePageKey(pathname: string): string {
  const groupId = matchGroupId(pathname);
  if (groupId) return `/group/${groupId}`;
  const live = matchPath({ path: LIVE_ROOM_PATTERN, end: true }, pathname);
  if (live?.params.id && live.params.id !== "start") return "/live/room";
  return pathname;
}

function prefersReducedMotion(): boolean {
  return (
    typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches
  );
}

const variants = {
  enter: {
    opacity: 1,
    y: 0,
    transition: { duration: ENTER_DURATION, ease: EASE_OUT },
  },
  exit: {
    opacity: 0,
    transition: { duration: EXIT_DURATION, ease: EASE_IN },
  },
};

export function PageTransition({
  pathname,
  children,
}: {
  pathname: string;
  children: ReactNode;
}) {
  // 惰性同步读取（非 effect）：reduced-motion 用户在首帧即无位移，避免一帧浮入闪跳
  const [reduced] = useState(prefersReducedMotion);
  const isGroup = matchGroupId(pathname) != null;
  const isSearch = matchPath({ path: "/search", end: true }, pathname) != null;
  // 进入：普通路由浮入（y +20px→0，从下往上）；搜索页从上往下展开（y -20px→0，
  // 顶栏固定不动、内容自顶栏下方滑出）；群页 / reduced-motion 仅淡入（无位移）
  const initial: { opacity: number; y?: number } =
    reduced || isGroup
      ? { opacity: 0 }
      : { opacity: 0, y: isSearch ? -RISE_DISTANCE : RISE_DISTANCE };

  return (
    <motion.div
      className="page-transition"
      initial={initial}
      animate="enter"
      exit="exit"
      variants={variants}
    >
      {children}
    </motion.div>
  );
}
