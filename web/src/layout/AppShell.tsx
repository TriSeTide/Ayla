/**
 * AppShell —— 响应式外壳（F1 基座，开发文档 §2.1/§2.3）。
 *
 * - useMediaQuery(NARROW_QUERY) 二选一渲染：
 *   窄屏（≤768px）：内容 + BottomTabs（五 tab，主页居中凸起）+ MessageFAB + CreateFAB；
 *   宽屏（>768px）：TopNav 常驻 + 内容 + CreateFAB。
 * - 沉浸式路由（直播间整页，isImmersiveRoute）不渲染任何 chrome。
 * - chrome 显隐与 FAB 动作由 shellConfig 纯函数决定（路由匹配，不维护第二份导航状态）。
 *
 * 后续步骤挂点：F3 进群动画（底栏上移到顶部）、F4 进房动画（底栏下滑走）、
 * F8 badges 红点（BottomTabs.badges / MessageFab.unread / TopNav.messageBadge）。
 */
import { Outlet, useLocation } from "react-router-dom";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { BottomTabs } from "./BottomTabs";
import { CreateFab } from "./CreateFab";
import { MessageFab } from "./MessageFab";
import { TopNav } from "./TopNav";
import { isImmersiveRoute, resolveFabAction, resolveModule } from "./shellConfig";

export function AppShell() {
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const { pathname } = useLocation();

  const moduleKey = resolveModule(pathname);
  const fabAction = resolveFabAction(pathname);

  if (isImmersiveRoute(pathname)) {
    return (
      <div className="app-shell" data-form={isNarrow ? "narrow" : "wide"} data-chrome="none">
        <main className="app-shell-content">
          <Outlet />
        </main>
      </div>
    );
  }

  return (
    <div className="app-shell" data-form={isNarrow ? "narrow" : "wide"}>
      {isNarrow ? null : <TopNav moduleKey={moduleKey} />}
      <main className="app-shell-content">
        <Outlet />
      </main>
      {isNarrow ? (
        <>
          <MessageFab />
          <BottomTabs moduleKey={moduleKey} />
        </>
      ) : null}
      {fabAction ? <CreateFab action={fabAction} /> : null}
    </div>
  );
}
