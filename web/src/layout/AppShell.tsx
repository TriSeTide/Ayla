/**
 * AppShell —— 响应式外壳（F1 基座，F3/F4 扩展）。
 *
 * - useMediaQuery(NARROW_QUERY) 二选一渲染：
 *   窄屏（≤768px）：内容 + BottomTabs（五 tab）+ MessageFAB + CreateFAB；
 *   宽屏（>768px）：TopNav 常驻 + 内容 + CreateFAB。
 * - 窄屏群场景（/group/:id[:/scene]）：GroupPage 自渲染顶部导航条（进群动画=底栏上移），壳层不出底栏（F3）。
 * - 窄屏直播间（/live/:channelId）：底栏**下滑走**进房动画（shell store 驱动，F4，方向与进群相反）。
 * - 宽屏直播间：TopNav 常驻 + 视频主区 + 弹幕侧列（非整屏）。
 */
import { useEffect } from "react";
import { Outlet, matchPath, useLocation } from "react-router-dom";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { useBadgesStore } from "../stores/badges";
import { useShellStore } from "../stores/shell";
import { BottomTabs } from "./BottomTabs";
import { CreateFab } from "./CreateFab";
import { MessageFab } from "./MessageFab";
import { SessionActivityIndicator } from "./SessionActivityIndicator";
import { RealtimeStatusBanner } from "./RealtimeStatusBanner";
import { TopNav } from "./TopNav";
import { isGroupScene, isMessagesRoute, isPostDetailRoute, isPrivateChatRoute, resolveFabAction, resolveModule } from "./shellConfig";

const BADGES_POLL_INTERVAL_MS = 30_000;

export function AppShell() {
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const { pathname } = useLocation();
  const bottomTabsLeaving = useShellStore((s) => s.bottomTabsLeaving);
  const badges = useBadgesStore((s) => s.badges);

  const moduleKey = resolveModule(pathname);
  const fabAction = resolveFabAction(pathname);
  const groupSceneNarrow = isNarrow && isGroupScene(pathname);
  // 帖子详情窄屏：底栏原位替换为评论输入框（R-P3）
  const postDetailNarrow = isNarrow && isPostDetailRoute(pathname);
  // 私聊聊天窄屏：底部有输入框，不渲染底栏/消息入口（需求：下方有输入框时不能有导航栏）
  const privateChatNarrow = isNarrow && isPrivateChatRoute(pathname);
  // 消息中心窄屏：左下角消息入口变为返回主页
  const messagesNarrow = isNarrow && matchPath({ path: "/messages", end: true }, pathname) != null;

  // 全站未读聚合：进入即拉 + 断线降级 30s 轮询（R-N4；WS 推送后置）
  useEffect(() => {
    void useBadgesStore.getState().fetch();
    const timer = setInterval(() => void useBadgesStore.getState().fetch(), BADGES_POLL_INTERVAL_MS);
    return () => clearInterval(timer);
  }, []);

  const messageBadge = badges
    ? badges.private_unread + badges.friend_requests + badges.group_invites + badges.join_requests_pending
    : 0;

  // 窄屏进房动画（直播间/语音房，F4/F5）：底栏下滑走（translateY 0→100%，200ms ease-in）
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
      {isNarrow && !groupSceneNarrow && !postDetailNarrow && !privateChatNarrow ? (
        <>
          <MessageFab style={leavingStyle} unread={messageBadge} backHome={messagesNarrow} />
          <BottomTabs
            moduleKey={moduleKey}
            style={leavingStyle}
            dataFixed={bottomTabsLeaving}
          />
        </>
      ) : null}
      {fabAction ? <CreateFab action={fabAction} /> : null}
    </div>
  );
}
