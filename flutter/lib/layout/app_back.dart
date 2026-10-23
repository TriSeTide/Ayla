/// 手机返回键的统一策略（web 没有等价物 —— 浏览器外壳代劳；Flutter 必须自己做）。
///
/// ## 为什么需要这一层（2026-10-20 实测的完整机制链）
///
/// `MaterialApp.router(routerConfig: goRouter)` 下，**返回键到不了页面级 PopScope**：
///
/// 1. `go_router` 的 `GoRouter` 自带 `RootBackButtonDispatcher`
///    （`go_router-14.8.1/lib/src/router.dart:186`），`Router.withConfig` 会把它交给
///    `Router`（`flutter/lib/src/widgets/router.dart:389–402`），`_RouterState.initState`
///    再 `addCallback(_handleBackButtonDispatcherNotification)`（同文件 621 行）
///    ⇒ **确实有** observer 在听 popRoute；
/// 2. 但那个回调只做一件事：`routerDelegate.popRoute()`（同文件 805–810）；
/// 3. go_router 的实现是 `navigatorKey.currentState.maybePop()`
///    （`go_router-14.8.1/lib/src/delegate.dart:57–77`）—— 而 `navigatorKey` 是
///    **顶层** Navigator，页面里 `PopScope` 挂在 **shell 内层** Navigator 的 route 上；
///    顶层 `canPop()` 为 false ⇒ `maybePop()` 直接返回 false，**根本不进内层 Navigator**
///    ⇒ 页面级 `PopScope.onPopInvokedWithResult` **一次都不会触发**
///    （本轮探针实测：`veto=0`；而直接对内层 `NavigatorState.maybePop()` 调一下
///    `veto=1` —— 证明 PopScope 本身是好的，只是没人调它）；
/// 4. `WidgetsBinding.handlePopRoute` 拿到 false ⇒ 视为「没人处理」⇒
///    **直接 `SystemNavigator.pop()` 把 App 关掉**
///    （`flutter/lib/src/widgets/binding.dart:1113–1136`）。
///
/// 实测读数（本轮探针，`tester.binding.handlePopRoute()` + `SystemChannels.platform` mock）：
///
/// | 起点 | 修复前 | 期望 |
/// |---|---|---|
/// | `/group`（一级主页） | `SystemNavigator.pop`（**直接退出**） | 第一次提示、第二次才退 |
/// | `/favorites`（二级页） | `SystemNavigator.pop`（**直接退出**） | 回 `/group` |
/// | `/group/g1`（群场景） | `SystemNavigator.pop`（**直接退出**） | 回群列表 |
/// | push 进 `/posts/1` | 正常 pop 回 `/group` | 不变 |
///
/// ⚠️ **另一条被这条链挡住的既有实现**：`GroupPage` 早已挂
/// `PopScope(canPop: false, onPopInvokedWithResult: 三级兜底)`（`pages/group_page.dart:680–692`），
/// 但按第 3 条它**在真机上从未生效过**。本件必须把「群页三级兜底」的语义一并接住
///（见 [_AylaBackButtonHostState._handle] 的第 ① 档），否则修好返回键反而会让群页丢掉逐级回退。
///
/// ## 挂载方式
/// `BackButtonListener`（`flutter/lib/src/widgets/router.dart:1178`）必须是 **Router 的后代**
/// （它 `Router.of(context)`；挂在 `MaterialApp.builder` 里会抛
/// `Router operation requested with a context that does not include a Router`），
/// 且要**抢在** `RootBackButtonDispatcher` 那个 callback 之前 —— 它内部会
/// `createChildBackButtonDispatcher()..addCallback(...)..takePriority()`（同文件 1195–1205），
/// dispatcher 先问 children ⇒ 本件先于 delegate 拿到返回键（实测确认）。
/// ⇒ 挂在 [AppShell] 的 `build` 根部（= `ShellRoute.builder` 的返回，天然在 Router 内）。
///
/// ## 为什么不是「拦截后自己 pop」
/// `BackButtonListener` 的回调返回 **true** ⇒ dispatcher 短路、不再调 `delegate.popRoute()`；
/// 返回 **false** ⇒ 回落给 go_router 自己 pop（实测确认）。
/// ⇒ 本件只在**自己真的要处理**时返回 true，其余交回框架（不重复发明 pop 逻辑）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 「再按一次退出应用」的提示文案（逐字对齐用户需求；测试按此常量断言）。
const String kAylaExitHintText = '再按一次退出应用';

/// 退出前的第二次确认窗口（Android 惯例 2s）。
const Duration kAylaExitConfirmWindow = Duration(seconds: 2);

/// 一级主页路由（窄屏返回键的收敛点）。
const String kAylaHomePath = '/group';

/// 一级主页的兼容别名（`app_router.dart` 把 `/home` 重定向到 `/group`，见 `shell_config.dart:84`）。
const String kAylaHomeAliasPath = '/home';

/// 真正退出应用的动作（可注入，便于测试 —— 仿 `core/update/update_exit.dart` 的写法）。
typedef AylaAppExit = Future<void> Function();

/// 生产用：`SystemNavigator.pop()`（Android 结束 Activity；桌面上关闭窗口）。
Future<void> aylaSystemExit() => SystemNavigator.pop();

/// 返回键策略的**纯状态机**（不碰 BuildContext，可单测）。
///
/// 只负责「一级主页上连按两次」这一个判据。
class AylaExitConfirm {
  AylaExitConfirm({this.window = kAylaExitConfirmWindow});

  /// 两次返回之间的有效窗口。
  final Duration window;

  /// 上一次「第一次返回」的时刻（null = 当前没有待确认的退出）。
  DateTime? _armedAt;

  /// 供测试注入时钟（生产恒 null ⇒ 用 [DateTime.now]）。
  DateTime Function()? clock;

  DateTime _now() => (clock ?? DateTime.now)();

  /// 记录一次「在主页按了返回」；返回 **true = 窗口内第二次 ⇒ 应当真的退出**。
  ///
  /// 每次调用都会重新计时（与 Android 惯例一致：过期后再按仍是「第一次」）。
  bool consume() {
    final DateTime now = _now();
    final DateTime? armed = _armedAt;
    final bool shouldExit =
        armed != null && now.difference(armed) <= window;
    _armedAt = shouldExit ? null : now;
    return shouldExit;
  }

  /// 清掉待确认状态（离开主页时调用，避免跨页误退）。
  void reset() => _armedAt = null;

  /// 当前是否处于「已提示、等待第二次」的窗口内（测试用）。
  bool get armed => _armedAt != null;
}

/// 逐级返回的档位（自上而下，先命中者胜）。
enum AylaBackAction {
  /// 有可 pop 的路由（详情 / 二级页）⇒ 交回框架 `context.pop()`。
  popRoute,

  /// 群场景（`GroupPage` 承担返回）⇒ 交回框架，由本件复刻它的三级兜底。
  groupScene,

  /// 不在主页 ⇒ 回一级主页 `context.go('/group')`。
  goHome,

  /// 已在主页 ⇒ 走「再按一次退出」。
  homeExit,
}

/// 判定：给定「是否还能 pop」与「当前路径」⇒ 该走哪一档。
///
/// ⚠️ 这个函数是**契约**（有定向单测），不要把它内联回 widget。
///
/// ## 顺序为什么是「群场景 → 能 pop → 回主页 → 双击退出」
/// 群场景**必须排在 `canPop` 之前**，这是照抄 `group_page.dart` 原 PopScope 的优先级：
/// ```dart
/// if (_popScene()) return;                       // ① 场景历史栈
/// if (context.canPop()) { context.pop(); return; } // ② 路由栈
/// context.go('/group');                          // ③ 回群列表
/// ```
/// 第 ① 档（场景历史）**与路由栈无关** —— 用户在群内 chat → voice 切过场景后，
/// 即便路由栈还能 pop，返回键也必须先退回上一个**场景**而不是弹掉整页。
/// 若把 `canPop` 判在前面，这条既有语义就丢了（本轮实测过：会直接跳过场景栈）。
/// ⇒ 群场景一律交给 [AylaBackButtonHost.onGroupBack]（由活着的那一个 GroupPage 执行
/// 上面那三级），本函数不为它做进一步分档。
AylaBackAction aylaBackActionFor({
  required bool canPop,
  required String pathname,
}) {
  // 群场景：5 条群路由都由 `GroupPage` 承担（见 `group_page.dart` 的 `_handleSystemBack`）。
  if (_isGroupScene(pathname)) return AylaBackAction.groupScene;
  if (canPop) return AylaBackAction.popRoute;
  if (pathname != kAylaHomePath && pathname != kAylaHomeAliasPath) {
    return AylaBackAction.goHome;
  }
  return AylaBackAction.homeExit;
}

/// 是否群场景路由（与 `router/shell_config.dart:163–172` 的 `aylaIsGroupScene` 同源口径：
/// `/group/:id` 及其四种带尾段的形式）。
///
/// 本件在 `layout/`，**不 import shell_config**：那边决定 Page key 与底栏显隐，
/// 语义不同；这里只判「返回键归谁」。两边若将来分歧，以 `shell_config` 为路由事实源。
bool _isGroupScene(String pathname) {
  final List<String> seg =
      pathname.split('/').where((String s) => s.isNotEmpty).toList();
  return seg.length >= 2 && seg.first == 'group';
}

/// 返回键宿主：挂在 [AppShell] 根部（Router 后代），统一处理系统返回。
///
/// 事实源与机制链见本文件头。web 无等价物：浏览器返回键 = 历史回退，
/// 关标签页由浏览器 chrome 负责；Flutter 必须自己接住，否则 `SystemNavigator.pop`
/// 会把 App 直接关掉（实测见文件头表格）。
class AylaBackButtonHost extends StatefulWidget {
  const AylaBackButtonHost({
    super.key,
    required this.child,
    required this.pathname,
    required this.canPop,
    required this.onGoHome,
    required this.onGroupBack,
    this.exit = aylaSystemExit,
    this.showHint,
  });

  /// 内容（壳层）。
  final Widget child;

  /// 当前路由路径（判据输入；由调用方从 `GoRouterState.of(context).uri.path` 取）。
  final String pathname;

  /// 当前路由栈能不能 pop（由调用方 `context.canPop()` 求值后传入）。
  final bool canPop;

  /// 回一级主页（由调用方 `context.go('/group')` —— 需要 BuildContext，故注入）。
  final VoidCallback onGoHome;

  /// 群场景回退（由调用方注入 `GroupPage` 的同一套三级兜底）。
  ///
  /// 返回 **true = 本次已处理**（不再落到系统）；false = 已回主页、仍应让系统退出。
  final Future<bool> Function() onGroupBack;

  /// 真正退出（生产 = `SystemNavigator.pop()`；测试注入记录器）。
  final AylaAppExit exit;

  /// 提示呈现（生产 = SnackBar；测试注入记录器）。
  final void Function(BuildContext context, String message)? showHint;

  @override
  State<AylaBackButtonHost> createState() => _AylaBackButtonHostState();
}

class _AylaBackButtonHostState extends State<AylaBackButtonHost> {
  final AylaExitConfirm _confirm = AylaExitConfirm();

  @override
  void didUpdateWidget(covariant AylaBackButtonHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换了页面 ⇒ 上一次的「待退出」作废（否则在主页按一下、去别页逛一圈再回主页
    // 按一下就退，与用户预期不符）。
    if (oldWidget.pathname != widget.pathname) _confirm.reset();
  }

  void _defaultHint(BuildContext context, String message) {
    // web 无此件（浏览器代劳）；措辞按用户需求逐字。
    // 用 ScaffoldMessenger 而不自绘：库内「检查更新」两处失败提示同款
    // （`layout/app_shell.dart:147/150`），保持全站提示语言一致。
    final ScaffoldMessengerState? messenger =
        ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(milliseconds: 1800),
      ));
  }

  Future<bool> _handle() async {
    switch (aylaBackActionFor(
      canPop: widget.canPop,
      pathname: widget.pathname,
    )) {
      case AylaBackAction.popRoute:
        // 交回 go_router 自己 pop（不重复实现）。
        return false;
      case AylaBackAction.groupScene:
        // 群页的三级兜底在本件复刻（页面自己的 PopScope 到不了，见文件头第 3 条）。
        // 由调用方注入 —— 它拿着 GroupPage 的场景历史栈与 groupId。
        return widget.onGroupBack();
      case AylaBackAction.goHome:
        _confirm.reset();
        widget.onGoHome();
        return true;
      case AylaBackAction.homeExit:
        if (_confirm.consume()) {
          await widget.exit();
          return true;
        }
        if (!mounted) return true;
        (widget.showHint ?? _defaultHint)(context, kAylaExitHintText);
        return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return BackButtonListener(
      onBackButtonPressed: _handle,
      child: widget.child,
    );
  }
}