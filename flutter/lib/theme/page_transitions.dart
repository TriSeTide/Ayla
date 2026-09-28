/// 页面转场（web `components/motion/PageTransition.tsx` 的**原生等价物**）。
///
/// ## 📌 先看清 web 到底有几条路由会走这里（2026-09-28 逐行核对 `AppShell.tsx:61–74`）
///
/// web **有**通用路由转场（`PageTransition.tsx` + `AppShell.tsx:113–128` 的 `AnimatePresence`），
/// 但它被 `panelOwned` 判定挡掉了**绝大多数**路由 —— `initial` 即终值、`transition.duration = 0`：
///
/// | 路由 | 通用转场 | 动画实际由谁承担 |
/// |---|---|---|
/// | `/group`（HomePage） | ✅ **播**（整页淡入 + y+20 + scale .95 / 500ms） | 无（该页无内部整页编排） |
/// | `/posts/mine`（MinePostsRoute） | ✅ **播** | 无 |
/// | `/group/:id…`（群场景一族） | ❌ 不播 | 页面内：侧栏 `auroraqua-sidebar-in` / 面板 `panel-from-right` |
/// | `/voice` `/live` `/posts` `/games` `/favorites` `/search` `/profile` | ❌ 不播 | 页面内：同上（`/profile` = 两列左右滑入） |
/// | `/messages` `/chat/:id` | ❌ 不播 | 页面内：`ConversationTransition` / 面板编排 |
/// | `/live/:id` `/live/start/:id` `/voice/:id` `/games/:id` `/user/:userId` `/posts/:postId` | ❌ 不播 | 页面内：各自的 panel 编排 |
/// | `/login` `/register` | ❌（在 `AppShell` **之外**，连容器都没有） | 无 |
///
/// ⇒ 宽屏下**只有 `/group` 与 `/posts/mine` 两条**真正用到通用转场；用户的印象
/// 「所有动画都是页面专属动画」与 web 的**实际观感**一致（那 2 条恰好是最少被注意到的两个列表页）。
///
/// ## 为什么必须在 Navigator 层做（2026-09-28 实测）
/// 早前的实现把转场放在 widget 层（`AylaPageSwap` 在 Stack 里保留旧页 + `AylaPageTransition`），
/// 有两个致命问题：
/// 1. **新旧页并存必须由 Navigator 管** —— go_router 的 `ShellRoute` 的 `child` **就是**
///    shell 的 `_CustomNavigator`（`builder.dart:287`），它的 key 是
///    `GlobalObjectKey(navigatorKey.hashCode)`，**故意用同一个 GlobalKey 让新旧 page 复用同一个
///    Element**。widget 层再保留一份 ⇒ `Multiple widgets used the same GlobalKey`；
/// 2. 调用方写 `builder: (ctx) => AylaPageTransition(child: widget.child)` 时闭包读到的是**当前**的
///    `widget.child` ⇒ **新页被渲染进旧页槽位**，观感就是「旧页淡出时叠着一份一模一样的新页」
///    （用户截图里的重影）。
///
/// 而 `PageTransitionsBuilder.buildTransitions` 天然是「新旧页并存、各播各的」：
/// `animation` = 本页进场、`secondaryAnimation` = 本页被新页覆盖 ⇒ 与 web 的
/// `AnimatePresence sync + .page-transition absolute`（手动 popLayout）**同语义**。
///
/// ## 参数（逐条对齐 tsx 84–104）
/// · 普通路由进场：`opacity 0→1` + `y +20→0` + `scale .95→1`，**500ms** `cubic-bezier(0,0,.58,1)`；
/// · 搜索页进场：`y −20→0`（内容自顶栏下方滑出）；
/// · 群页 / `prefers-reduced-motion`：**只 opacity**（无位移无缩放）；
/// · `panelOwned`（群场景 / 消息中心 / 各详情页…，见 `AppShell.tsx:61–74`）：**整页不动**
///   （面板自编排，外层立即归位）；
/// · 退场（被新页覆盖）：`opacity → 0`，**300ms** `cubic-bezier(.42,0,.58,1)`；
/// · **登录 / 注册**：web 里它们在 `AppShell` **之外**（`App.tsx:57–58` 是顶层 `Route`）
///   ⇒ **完全没有转场**。
///
/// ## ⚠️ 当前状态：**未接线**（2026-09-28 用户裁决）
///
/// 用户要求「先把所有页面切换动画都删掉，目前只有个人主页页面有动画」⇒
/// `buildAylaTheme()` 的 `pageTransitionsTheme` 当前用**直通** builder
/// （`_AylaNoPageTransition`），本文件的分档实现**暂时不生效**。
///
/// **保留它的原因**：它已经把 web 的全部分档写全了（panelOwned / 群页 / 搜索页 /
/// `/login` `/register` 无转场 / reduced / name 为空直通），等页面做齐、确实需要整页过渡时，
/// 把 `app_theme.dart` 那六个平台换成本件即可 —— 注意**必须取代平台默认、不能并存**。
///
/// ## 公开面
/// `AylaPageTransitionsBuilder` · `aylaIsTransitionFreePath`
library;

import 'package:flutter/material.dart';

import '../router/shell_config.dart';
import 'tokens.dart';

/// 该路径**不做任何页面转场**（web：登录 / 注册在 `AppShell` 外，无转场容器）。
///
/// `route.settings.name` 由 go_router 设为匹配到的路径（可能带 query，故用前缀判定）。
bool aylaIsTransitionFreePath(String? name) {
  if (name == null || name.isEmpty) return false;
  final String path = name.split('?').first;
  return path == '/login' || path == '/register';
}

/// 页面转场 builder（theme 级唯一 owner）。
class AylaPageTransitionsBuilder extends PageTransitionsBuilder {
  const AylaPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final String? name = route.settings.name;
    // ⚠️ **无名路由一律直通**：go_router 在初始帧 / 重定向帧会给出 `settings.name == null`
    // （实测），此时既判不出 panelOwned 也判不出群页/搜索页 —— 与其猜一个档位，
    // 不如不动画（宁可少一段动画，也不给错误的路由强加位移）。
    // 未实现页（`PendingPage`）走 `NoTransitionPage`，根本不会进到这里。
    if (name == null || name.isEmpty) return child;
    // 登录 / 注册：无转场（web 顶层 Route，不在 AppShell 内）⇒ 左侧品牌区**完全不动**
    if (aylaIsTransitionFreePath(name)) return child;
    // reduced-motion：直接终值（tsx 87–88 / 103 的 reduced 分支）
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) return child;

    final String pathname = name; // 上面已保证 name 非空
    // panelOwned：整页不动画（面板自编排）
    if (pathname.isNotEmpty && aylaPanelOwnedPath(pathname)) return child;

    // 群页判定与 `kAylaGroupPatterns` 同源（`shell_config.dart` 的 `aylaIsGroupScene`）。
    final bool groupScene = pathname.isNotEmpty && aylaIsGroupScene(pathname);
    final bool search = pathname == '/search';
    final bool displacement = !groupScene;

    final Animation<double> enter = CurvedAnimation(
      parent: animation,
      curve: AylaCurves.auroraquaEaseOut,
    );
    final Animation<double> exit = CurvedAnimation(
      parent: secondaryAnimation,
      curve: AylaCurves.auroraquaEaseInOut,
    );

    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[enter, exit]),
      builder: (BuildContext context, Widget? inner) {
        final double v = enter.value;
        // 被新页覆盖时淡出（旧页只淡出、不位移 —— tsx 103 的 exit 只有 opacity）
        final double opacity = v * (1 - exit.value);
        if (!displacement) {
          return Opacity(opacity: opacity, child: inner);
        }
        final double fromY = search
            ? -AylaPageTransitionMetrics.distance
            : AylaPageTransitionMetrics.distance;
        return Opacity(
          opacity: opacity,
          child: Transform.translate(
            offset: Offset(0, fromY * (1 - v)),
            child: Transform.scale(
              scale: AylaPageTransitionMetrics.fadeScale +
                  (1 - AylaPageTransitionMetrics.fadeScale) * v,
              child: inner,
            ),
          ),
        );
      },
      child: child,
    );
  }
}

/// 转场度量（与 web `auroraquaMotion.ts` 同值；`AylaPageTransition` 的常量同源）。
abstract final class AylaPageTransitionMetrics {
  /// `AURORAQUA_MOTION.distance` = 20。
  static const double distance = 20;

  /// `AURORAQUA_MOTION.fadeScale` = 0.95。
  static const double fadeScale = 0.95;

  /// `fadeDuration` = 500ms（进场）。
  static const Duration fadeDuration = Duration(milliseconds: 500);

  /// `auroraquaRouteTransition` = 300ms（退场）。
  static const Duration exitDuration = Duration(milliseconds: 300);
}