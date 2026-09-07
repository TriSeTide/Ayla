/**
 * PageTransition —— 全局路由切换转场（方案 §2.1 / design.md §7）。
 *
 * - AppShell 内容区用 AnimatePresence(mode="sync") + 本组件作 keyed 子元素，
 *   配合 .page-transition 的 absolute 定位（CSS 手动 popLayout，新旧页重叠转场）：
 *   新页沿用上下文方向，并采用 Auroraqua FadeInCard 的 .95→1 缩放与 500ms easeOut；
 *   旧页淡出采用 Auroraqua route 的 300ms easeInOut。
 *   （不用 AnimatePresence popLayout：其 layout projection 会接管 transform，吞掉 y 位移）
 * - 群页及其他 panelOwned 界面在窄宽屏均由各面板编排，外层立即归位；
 *   退出保留 300ms 淡出。未指定分区 owner 的群页调用方保留无位移淡入。
 * - prefers-reduced-motion：关闭位移，并立即切换最终透明度（§7）。
 * - 参数与来源集中在 auroraquaMotion.ts，保持 Ayla 原色与路由身份。
 */
import { motion } from "framer-motion";
import { matchPath } from "react-router-dom";
import type { ReactNode } from "react";
import { usePrefersReducedMotion } from "../../hooks/usePrefersReducedMotion";
import { AURORAQUA_MOTION, auroraquaRouteTransition } from "./auroraquaMotion";

/** 群页路由模式（与 shellConfig.isGroupScene 同源；此处需返回 groupId 供 key 归一化） */
const GROUP_PATTERNS = [
  "/group/:id",
  "/group/:id/:scene",
  "/group/:id/posts/:postId",
  "/group/:id/voice/:voiceChannelId",
  "/group/:id/live/:liveChannelId",
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
 *   宽屏进一步共享群工作区外壳，群服务器栏保持同一 owner，频道面板及内容依次退出/进入；
 * - 宽屏私聊详情共享外壳，会话列表保持挂载，右侧由 ConversationTransition 独占切换；
 * - 直播间详情归一为 `/live/room`，避免直播间上下滑切换（/live/:id → /live/:id）
 *   触发整页重挂载（底栏滑出动画复位）；进入/退出直播间（/live ↔ /live/:id）
 *   仍保留页面生命周期，进入由独立面板编排，手势层保持原位移所有权；
 * - 开播控制台归一为 `/live/start`：侧栏切频道（/live/start/:id → /live/start/:id'）
 *   不触发整页重挂载——否则 AnimatePresence(mode="sync") 新旧两页并存，
 *   旧页卸载 cleanup 的 liveSessionRuntime.leave() 会清掉新页刚建立的会话
 *   （alive/channelId/clearCurrent/断 WS），新页 enterAsync 的 alive 检查提前
 *   return，channel 永不设置，控制台退化成普通直播间且弹幕断开（2026-09-06 事故）；
 * - 其余路由用原始 pathname。
 */
const LIVE_ROOM_PATTERN = "/live/:id";
const LIVE_STUDIO_PATTERN = "/live/start/:channelId";

export function resolvePageKey(pathname: string, wideGroupShell = false): string {
  const groupId = matchGroupId(pathname);
  if (groupId) return wideGroupShell ? "wide-group-shell" : `/group/${groupId}`;
  if (wideGroupShell && matchPath({ path: "/chat/:conversationId", end: true }, pathname)) {
    return "wide-private-chat-shell";
  }
  const live = matchPath({ path: LIVE_ROOM_PATTERN, end: true }, pathname);
  if (live?.params.id && live.params.id !== "start") return "/live/room";
  const studio = matchPath({ path: LIVE_STUDIO_PATTERN, end: true }, pathname);
  if (studio) return "/live/start";
  return pathname;
}

export function PageTransition({
  pathname,
  children,
  panelOwned = false,
}: {
  pathname: string;
  children: ReactNode;
  /** Panels animate independently; this page must not move the same content again. */
  panelOwned?: boolean;
}) {
  const reduced = usePrefersReducedMotion();
  const isGroup = matchGroupId(pathname) != null;
  const isSearch = matchPath({ path: "/search", end: true }, pathname) != null;
  // 进入：普通路由浮入（y +20px→0，从下往上）；搜索页从上往下展开（y -20px→0，
  // 顶栏固定不动、内容自顶栏下方滑出）；群页 / reduced-motion 仅淡入（无位移）
  const initial =
    panelOwned
      ? { opacity: 1, x: 0, y: 0, scale: 1 }
      : reduced || isGroup
      ? { opacity: 0 }
      : {
          opacity: 0,
          y: isSearch ? -AURORAQUA_MOTION.distance : AURORAQUA_MOTION.distance,
          scale: AURORAQUA_MOTION.fadeScale,
        };
  const variants = {
    enter: {
      opacity: 1,
      y: 0,
      scale: 1,
      transition: reduced || panelOwned
        ? { duration: 0 }
        : { duration: AURORAQUA_MOTION.fadeDuration, ease: AURORAQUA_MOTION.easeOut },
    },
    exit: { opacity: 0, transition: reduced ? { duration: 0 } : auroraquaRouteTransition },
  };

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
