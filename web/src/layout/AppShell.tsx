/**
 * AppShell —— 响应式外壳（F1 基座，F3/F4 扩展）。
 *
 * - useMediaQuery(NARROW_QUERY) 二选一渲染：
 *   窄屏（≤768px）：内容 + BottomTabs（五 tab）+ MessageFAB + CreateFAB；
 *   宽屏（>768px）：TopNav 常驻 + 内容 + CreateFAB。
 * - 窄屏群场景（/group/:id[:/scene]）：GroupPage 自渲染顶部导航条（进群动画=底栏上移），壳层不出底栏（F3）。
 * - 窄屏直播间、语音房与帖子详情：底栏**下滑走**，对应输入框延迟滑入（shell store 驱动，方向与进群相反）。
 * - 宽屏直播间：TopNav 常驻 + 视频主区 + 弹幕侧列（非整屏）。
 * - 窄屏左下角按钮（R-QM）：五个一级导航页常态显示 MessageFAB（跳 /messages）；
 *   /messages 页显示「返回主页」；其余页面仅在有红点时显示 QuickMessageFAB（就地弹快捷消息栏）。
 */
import { useEffect } from "react";
import { Outlet, matchPath, useLocation } from "react-router-dom";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { useBadgesStore } from "../stores/badges";
import { useShellStore } from "../stores/shell";
import { BottomTabs } from "./BottomTabs";
import { CreateFab } from "./CreateFab";
import { MessageFab } from "./MessageFab";
import { QuickMessageFab } from "./QuickMessageFab";
import { QuickMessagesSheet } from "../components/chat/QuickMessagesSheet";
import { SessionActivityIndicator } from "./SessionActivityIndicator";
import { RealtimeStatusBanner } from "./RealtimeStatusBanner";
import { TopNav } from "./TopNav";
import { isGroupScene, isMessagesRoute, isPrimaryNavRoute, isPrivateChatRoute, resolveFabAction, resolveModule } from "./shellConfig";

const BADGES_POLL_INTERVAL_MS = 30_000;

export function AppShell() {
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const { pathname } = useLocation();
  const bottomTabsLeaving = useShellStore((s) => s.bottomTabsLeaving);
  const quickMessagesOpen = useShellStore((s) => s.quickMessagesOpen);
  const badges = useBadgesStore((s) => s.badges);

  const moduleKey = resolveModule(pathname);
  const fabAction = resolveFabAction(pathname);
  const groupSceneNarrow = isNarrow && isGroupScene(pathname);
  // 私聊聊天窄屏：底部有输入框，不渲染底栏/消息入口（需求：下方有输入框时不能有导航栏）
  const privateChatNarrow = isNarrow && isPrivateChatRoute(pathname);
  // 消息中心窄屏：左下角消息入口变为返回主页
  const messagesNarrow = isNarrow && matchPath({ path: "/messages", end: true }, pathname) != null;
  // 五个一级导航页：左下角私信按钮常态显示、点击跳 /messages（R-QM）
  const primaryNavNarrow = isNarrow && isPrimaryNavRoute(pathname);

  // 全站未读聚合：进入即拉 + 断线降级 30s 轮询（R-N4；WS 推送后置）
  useEffect(() => {
    void useBadgesStore.getState().fetch();
    const timer = setInterval(() => void useBadgesStore.getState().fetch(), BADGES_POLL_INTERVAL_MS);
    return () => clearInterval(timer);
  }, []);

  const messageBadge = badges
    ? badges.private_unread + badges.friend_requests + badges.group_invites + badges.join_requests_pending
    : 0;

  // 窄屏进入直播间、语音房或帖子详情：底栏下滑走（translateY 0→100%，200ms ease-in）。
  const leavingStyle = {
    transform: `translateY(${bottomTabsLeaving ? "100%" : "0"})`,
    transition: "transform 200ms ease-in",
  };

  return (
    <div className="app-shell" data-form={isNarrow ? "narrow" : "wide"}>
      {isNarrow ? null : <TopNav moduleKey={moduleKey} messagesActive={isMessagesRoute(pathname)} messageBadge={messageBadge} />}
      <main className="app-shell-content">
        <Outlet />
      </main>
      <SessionActivityIndicator />
      <RealtimeStatusBanner />
      {isNarrow && !groupSceneNarrow && !privateChatNarrow ? (
        <BottomTabs
          moduleKey={moduleKey}
          style={leavingStyle}
          dataFixed={bottomTabsLeaving}
        />
      ) : null}
      {isNarrow && primaryNavNarrow ? (
        <MessageFab unread={messageBadge} />
      ) : isNarrow && messagesNarrow ? (
        <MessageFab backHome />
      ) : isNarrow && !privateChatNarrow && messageBadge > 0 ? (
        <QuickMessageFab unread={messageBadge} />
      ) : null}
      {fabAction ? <CreateFab action={fabAction} /> : null}
      {/* 红点快捷消息栏：由 shell store 独立控制，只随手动关闭卸载（红点归零不关闭） */}
      {isNarrow && quickMessagesOpen ? (
        <QuickMessagesSheet onClose={() => useShellStore.getState().setQuickMessagesOpen(false)} />
      ) : null}
    </div>
  );
}
