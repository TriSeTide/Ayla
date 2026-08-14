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
import { Outlet, useLocation } from "react-router-dom";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { useShellStore } from "../stores/shell";
import { BottomTabs } from "./BottomTabs";
import { CreateFab } from "./CreateFab";
import { MessageFab } from "./MessageFab";
import { TopNav } from "./TopNav";
import { isGroupScene, isPostDetailRoute, resolveFabAction, resolveModule } from "./shellConfig";

export function AppShell() {
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const { pathname } = useLocation();
  const bottomTabsLeaving = useShellStore((s) => s.bottomTabsLeaving);

  const moduleKey = resolveModule(pathname);
  const fabAction = resolveFabAction(pathname);
  const groupSceneNarrow = isNarrow && isGroupScene(pathname);
  // 帖子详情窄屏：底栏原位替换为评论输入框（R-P3）
  const postDetailNarrow = isNarrow && isPostDetailRoute(pathname);

  // 窄屏进房动画（直播间/语音房，F4/F5）：底栏下滑走（translateY 0→100%，200ms ease-in）
  // 由 LiveRoomPage / 语音房进房调 shell store 驱动，与进群动画"上移"相反。
  const leavingStyle = {
    transform: `translateY(${bottomTabsLeaving ? "100%" : "0"})`,
    transition: "transform 200ms ease-in",
  };

  return (
    <div className="app-shell" data-form={isNarrow ? "narrow" : "wide"}>
      {isNarrow ? null : <TopNav moduleKey={moduleKey} />}
      <main className="app-shell-content">
        <Outlet />
      </main>
      {isNarrow && !groupSceneNarrow && !postDetailNarrow ? (
        <>
          <MessageFab style={leavingStyle} />
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
