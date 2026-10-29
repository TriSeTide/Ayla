/// AppShell —— 响应式外壳（web `layout/AppShell.tsx` 164 行的等价物）。
///
/// ## 双形态（`useMediaQuery(NARROW_QUERY)` 的等价物 = `AylaBreakpoints.isNarrow`）
/// · **窄屏（≤768）**：内容 + BottomTabs（五 tab）+ MessageFab / QuickMessageFab + CreateFab；
///   窄屏顶栏（web `NarrowTopBar`）只在 `aylaIsNarrowTopBarRoute` 的路由上渲染，
///   由同一个 [AylaTopNav] 的 `variant` 表达（home / search / favorites 三档）。
/// · **宽屏（>768）**：TopNav 常驻 + 内容 + CreateFab + 右下浮层按钮组。
///
/// ## 底栏的两种挂载（`shell.css:77–94`）
/// · 常规：留在 flex 流里（`.bottom-tabs { flex: none; height: 64 + safe }`）⇒ 占位、内容区让出高度；
/// · `bottomTabsLeaving`（窄屏进直播间 / 语音房 / 帖子详情时由页面置位）：语义等于
///   `[data-fixed=true]` —— 脱离流、固定到底部并 `translateY(100%)`（200ms ease-in），
///   此时内容区吃满全高。Flutter 用「Column 里撤掉 + Stack 里 `AnimatedSlide` 叠一层」表达。
///
/// ## 浮动小窗 / 悬浮球**都不在应用内渲染了**（2026-10-31 用户明确要求）
/// 用户原话：「应用内不会再存在任何浮层，不再存在原本那个悬浮球浮层，也不会存在直播小窗浮层，
/// 取而代之的是创建时就脱离应用的、显示在其他应用之上的悬浮窗，外观和交互完全没有区别」。
///
/// ⇒ 两个浮层的**渲染宿主**都搬到了第二个 engine 的独立窗口
/// （`windows/runner/live_window.cpp` + `lib/widgets/shell/overlay_window_app.dart` +
/// `lib/widgets/live/live_window_surface.dart`），widget 树仍是同一份代码。
/// 本文件只保留**数据投影**：
/// - 悬浮球：[_SessionActivityHost] 算出「当前有哪些会话」⇒ 推给窗口外悬浮球窗口；
/// - 直播小窗：[_LiveMiniPlayerHost] 不再 build `AylaLiveMiniPlayer`，而是把
///   `miniPlayer` 投影成窗口外小窗的开关（`openLiveWindow`）。
///
/// 平台不支持（iOS / Web / 未实现的原生）时这两个宿主**什么都不渲染** ——
/// 用户的要求是"不要应用内浮层"，所以这里**不再**回落到 App 内浮层。
///
/// ## 红点快捷消息栏（`AppShell.tsx:158–161`，2026-10 接线）
/// 窄屏 + `shell.quickMessagesOpen` ⇒ 渲染 `AylaQuickMessagesHost`（取数 + 两 tab 面板 +
/// 内联私聊全在 `pages/quick_messages_support.dart`）；关闭回写
/// `shellUiProvider.setQuickMessagesOpen(false)`。开合由 Fab 触发、状态在全局 store
/// （**红点归零不关闭** —— web 注释里的 R-QM bug 修复）。
///
/// ## 未接线项（第 1 批登记，见 13 号文档）
/// · ~~`QuickMessagesSheet` 的实际面板内容~~ ✅ **2026-10 已接线**
///   （`pages/quick_messages_support.dart`：[ShellUiState.quickMessagesOpen] 驱动渲染，
///   Fab 按它暂停半贴计时 —— 两条链路现已闭环）；
/// · ~~未读聚合 `messageBadge`~~ ✅ **2026-09-28 消息域批次已接线**：`state/badges_state.dart` +
///   `state/chat_providers.dart`（`GET /me/badges/`；进入即拉 + 纯 WS 事件驱动，**无周期轮询**）；
/// · `ServerRail` / `ChannelSidebar`：web 的 AppShell **不渲染**它们 —— 它们是宽屏主页
///   （`GroupPage` 三列）的内部装配，属第 2 批。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../pages/group_page.dart' show AylaGroupBackHandler, aylaGroupBackHandler;
import '../pages/quick_messages_support.dart' show AylaQuickMessagesHost;
import '../router/shell_config.dart';
import '../state/auth_bootstrap.dart';
import '../state/auth_state.dart';
import '../state/chat_providers.dart' show badgesProvider;
import '../state/live_state.dart';
import '../state/room_providers.dart'
    show liveStateProvider, sessionActivityProvider;
import '../state/session_activity_state.dart'
    show AylaActivityKind, AylaActivityRecord, AylaSessionActivityStore;
import '../core/platform/detached_live.dart';
import '../core/update/update_controller.dart'
    show AylaUpdateCheckResult, AylaUpdateController;
import '../state/update_providers.dart';
import '../state/shell_state.dart';
import '../theme/app_icons.dart';
import '../theme/buttons.dart';
import '../theme/tokens.dart';
import '../widgets/base/dialogs.dart' show AylaConfirmDialog;
import '../widgets/motion/gestures.dart' show AylaPrimaryNavPage;
import '../widgets/shell/bottom_tabs.dart';
import '../widgets/shell/fab.dart';
import '../widgets/shell/create_sheet.dart' show AylaRootOverlay;
import '../widgets/shell/overlay_window_app.dart'
    show AylaOverlayKind, AylaOverlayPayload;
import '../widgets/shell/session_activity.dart';
import '../widgets/shell/top_nav.dart';
import 'app_back.dart';
import 'create_sheet_forms.dart';


class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.child});

  /// 路由出口（go_router 的 `ShellRoute` 传入）。
  final Widget child;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  /// 顶栏搜索框的受控值。
  String _searchQuery = '';

  /// 上一次构建的 pathname（窄屏一级 tab 的切换方向由它算出）。
  String? _prevPathname;

  /// **本次**路由切换的方向（1 / -1 / 0）—— 一级 tab 顺序索引差。
  ///
  /// 事实源：web `usePrimaryNavSwipeDirection.ts:42–50` —— 在 render 阶段更新 ref
  /// （不 setState），挂载首帧为 `0`。Flutter 侧同法在 [build] 里更新：
  /// 本字段只被同一次 build 的下文读取，即便 AppShell 因其它订阅重建，
  /// pathname 未变也不会重算（与 web 的 ref 语义一致）。
  int _navDirection = 0;

  @override
  void initState() {
    super.initState();
    // 全站未读聚合：进入即拉 + 纯 WS 事件驱动（web `AppShell.tsx:86–91`，无周期轮询）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(badgesProvider).fetch());
    });
  }

  /// 创建浮层是否打开（`.create-fab` 的落点）。
  bool _createSheetOpen = false;

  void _logout() {
    // 顺序对齐 web `useAuth.logout`：断 WS → 清令牌 → appInit.reset（回登录由路由守卫接）。
    //
    // ⚠️ 实现已**抽到 `state/auth_bootstrap.dart:aylaLogout`**（2026-10-01）：401 过期路径
    // （`main.dart` 的 `onSessionExpired`）原本另抄了一份同样的链，两条路径合一份避免漂移。
    //
    // ⚠️ **不删已保存凭据**：用户勾了「记住密码」就应当下次打开仍是回填好、可直接点登录的样子；
    // 想彻底忘记 ⇒ 在登录页取消「记住密码」（`AylaAuthPrefsStore.save(rememberPassword:false)`）。
    aylaLogout(ref);
  }

  void _onMenuSelected(AylaTopNavMenuAction action) {
    switch (action) {
      case AylaTopNavMenuAction.profile:
        context.go('/profile');
      case AylaTopNavMenuAction.favorites:
        context.go('/favorites');
      case AylaTopNavMenuAction.checkUpdates:
        unawaited(_checkForUpdates());
      case AylaTopNavMenuAction.logout:
        _logout();
    }
  }

  /// 窄屏顶栏返回键（search / favorites 两档共用）—— web `NarrowTopBar.tsx:69–78` 的
  /// `onClick={() => navigate(-1)}` 的等价物。
  ///
  /// ## 为什么不能裸 `context.pop()`（2026-10 用户实报「收藏页左上角返回键无法点击」）
  /// web 的 `navigate(-1)` 是**浏览器历史回退**：没有历史时它是 no-op，界面上永远不出错。
  /// Flutter 侧的等价物必须显式判栈：`GoRouter.of(context).pop()` 在栈底会
  /// **抛 `GoError: There is nothing to pop`**（`go_router-14.8.1/lib/src/delegate.dart:98–104`），
  /// 而本回调是在按钮的手势里调用的 ⇒ 异常被吞掉、界面**完全没反应**。
  ///
  /// 触发路径就是「更多」菜单：`_onMenuSelected` 的收藏档走 `context.go('/favorites')`
  /// （**替换**当前路由，web `NarrowTopBar.tsx:116` 的 `navigate("/favorites")` 同理 ——
  /// 从一级页进收藏页时栈只有一层）⇒ 一点返回就抛。
  ///
  /// ## 口径 = 库内既有的「能回退就回退，栈底回一级主页」
  /// 与 `favorites_page.dart:602` / `search_page.dart:1338` / `profile_page.dart:614`
  /// 三处一字不差（宽屏目录返回键、搜索页返回、个人页返回）。`/group` 是窄屏一级主页
  /// （`shell_config.dart:182` 的 `aylaIsNarrowTopBarRoute` 首个路径）。
  void _narrowBack() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/group');
    }
  }

  /// 手动检查客户端更新（「更多」菜单入口；发现新版本时由全局宿主弹窗）。
  ///
  /// 与登录后的自动检查共用同一 controller；失败/已是最新用 SnackBar 明确反馈
  ///（自动检查则静默，不打扰登录流程）。
  Future<void> _checkForUpdates() async {
    final AylaUpdateController controller = ref.read(updateControllerProvider);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final AylaUpdateCheckResult result = await controller.checkManually();
      if (!mounted) return;
      if (result.hasUpdate) return; // 弹窗由 AylaUpdateHost 渲染
      final String message = result.failed
          ? '检查更新失败：${result.error ?? '未知错误'}'
          : result.degraded
          ? '更新服务暂不可用，请稍后再试'
          : '当前已是最新版本';
      messenger.showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('检查更新失败：$error')));
    }
  }

  /// 创建浮层内容 —— 按 `fabAction.handler` 分支（web `CreateFab.tsx:56–114`）。
  ///
  /// **五个 handler 全部接线**：`group` / `voice` / `live` / `post` / `game` 分别对应
  /// [aylaCreateFormFor] 的五条分支（`layout/create_sheet_forms.dart` —— 分派与测试
  /// 共用同一事实源）；本方法只负责把「关浮层」的 [close] 传进去。
  ///
  /// 未知 handler 由 [aylaCreateFormFor] 显式兜底（占位文案写明 key / handler /
  /// plannedStep），不静默。
  Widget _createSheet(AylaFabAction fabAction) {
    void close() => setState(() => _createSheetOpen = false);
    return aylaCreateFormFor(fabAction, onClose: close);
  }

  @override
  Widget build(BuildContext context) {
    final String pathname = GoRouterState.of(context).uri.path;
    // ---- 窄屏一级 tab 的切换方向（web `AppShell.tsx:75` + `usePrimaryNavSwipeDirection`）----
    // 挂载首帧 / 同页重建都不重算；只有 pathname 真的变了才算一次切换。
    if (_prevPathname != pathname) {
      final String? prev = _prevPathname;
      _navDirection =
          prev == null ? 0 : aylaPrimaryTabDirection(prev, pathname);
      _prevPathname = pathname;
    }
    final bool isNarrow =
        AylaBreakpoints.isNarrow(MediaQuery.sizeOf(context).width);
    final AylaPrimaryModule? moduleKey = aylaResolveModule(pathname);
    final AylaFabAction? fabAction = aylaResolveFabAction(pathname);
    final AylaCornerFabConfig cornerFabs =
        aylaResolveCornerFabs(pathname, isNarrow);
    final bool groupSceneNarrow = isNarrow && aylaIsGroupScene(pathname);
    final bool privateChatNarrow =
        isNarrow && aylaIsPrivateChatRoute(pathname);
    final bool messagesNarrow = isNarrow && aylaMatches('/messages', pathname);
    final bool primaryNavNarrow =
        isNarrow && aylaIsPrimaryNavRoute(pathname);
    final ShellUiState shell = ref.watch(shellUiProvider);
    final AuthUser? user = ref.watch(authNotifierProvider).user;
    // 全站未读聚合（web `AppShell.tsx:93–95`：private_unread + 三路认证，**不含** mention_unread）。
    // 未取到 ⇒ 0（红点无法表达「未知」；store 侧仍保持 null，见 `state/badges_state.dart`）。
    final int messageBadge = ref.watch(badgesProvider).messageBadge;
    final bool bottomTabsLeaving = shell.bottomTabsLeaving;
    final bool showBottomTabs = isNarrow && !groupSceneNarrow && !privateChatNarrow;
    // ---- 窄屏浮动小窗（`AppShell.tsx:46 / 131–132`）----
    // `select` 只在小窗档变化时重建壳层：弹幕/在看人数等高频 notify 不会把整个 shell 拖进重建。
    final AylaLiveMiniPlayerState? liveMiniPlayer =
        ref.watch(liveStateProvider.select((AylaLiveState s) => s.miniPlayer));

    // ---- 顶栏（`AppShell.tsx:105–109`）----
    final String? narrowVariant = !isNarrow || !aylaIsNarrowTopBarRoute(pathname)
        ? null
        : aylaMatches('/search', pathname)
            ? 'search'
            : aylaMatches('/favorites', pathname)
                ? 'favorites'
                : 'default';
    final Widget userAvatarFreeTopNav = AylaTopNav(
      module: moduleKey,
      messagesActive: aylaIsMessagesRoute(pathname),
      messageBadge: messageBadge,
      userName: user?.nickname ?? '',
      userAvatarUrl: user?.avatar,
      userOnline: user?.online ?? false,
      // 传 id ⇒ 顶栏头像自订阅 presence。
      // 此前只传 userOnline（REST 快照）⇒ 自己上下线/切隐身时顶栏光环不动。
      userId: user?.id,
      searchQuery: _searchQuery,
      onSearchChanged: (String v) => setState(() => _searchQuery = v),
      onSearchSubmitted: (String q) =>
          context.push('/search?q=${Uri.encodeComponent(q)}'),
      onSearchCleared: () => setState(() => _searchQuery = ''),
      onAvatarTap: () => context.go('/profile'),
      onMessagesTap: () => context.go('/messages'),
      onLogoTap: () => context.go('/group'),
      onModuleTap: (AylaPrimaryModule m) => context.go(m.path),
      onMenuSelected: _onMenuSelected,
    );
    Widget? topBar;
    if (isNarrow && narrowVariant == 'search') {
      topBar = AylaTopNav(
        variant: AylaTopNavVariant.search,
        searchQuery: _searchQuery,
        onSearchChanged: (String v) => setState(() => _searchQuery = v),
        onSearchSubmitted: (String q) =>
            context.push('/search?q=${Uri.encodeComponent(q)}'),
        onSearchCleared: () => setState(() => _searchQuery = ''),
        onMenuSelected: _onMenuSelected,
        onBack: _narrowBack,
      );
    } else if (isNarrow && narrowVariant == 'favorites') {
      topBar = AylaTopNav(
        variant: AylaTopNavVariant.favorites,
        onMenuSelected: _onMenuSelected,
        // ⚠️ **不得裸 `context.pop()`**：从「更多」菜单 `go('/favorites')` 进来时栈只有一层，
        // 裸 pop 抛 `GoError: There is nothing to pop` 且被手势吞掉 ⇒ 键看起来没反应
        //（2026-10 用户实报）。判栈逻辑统一在 [_narrowBack]。
        onBack: _narrowBack,
      );
    } else if (isNarrow && narrowVariant == 'default') {
      topBar = AylaTopNav(
        variant: AylaTopNavVariant.home,
        userName: user?.nickname ?? '',
        userAvatarUrl: user?.avatar,
        userOnline: user?.online ?? false,
        // 窄屏同宽屏：传 id 让头像自订阅 presence。
        userId: user?.id,
        onAvatarTap: () => context.go('/profile'),
        onSearchFieldTap: () => context.push('/search'),
        onMenuSelected: _onMenuSelected,
      );
    } else if (!isNarrow) {
      topBar = userAvatarFreeTopNav;
    }


    // ---- 内容区（`.app-shell-content`）----
    // ⚠️ **转场不在这里做**（2026-09-28 修的第二个根因）：页面转场的唯一 owner 是
    // `theme/page_transitions.dart` 的 [AylaPageTransitionsBuilder]（Navigator 层）——
    // 它天然表达 web `AnimatePresence mode="sync"` 的「新旧页并存、各播各的」。
    // 曾经在这里用 `AylaPageSwap` 保留旧页，结果是：
    // ① go_router 的 ShellRoute child **就是** shell navigator（key 是
    //    `GlobalObjectKey(navigatorKey.hashCode)`，靠同一 GlobalKey 复用 Element）⇒
    //    保留旧页会 `Multiple widgets used the same GlobalKey`；
    // ② 用 `builder` 时闭包读到的是当前 child ⇒ 旧槽里放的是**新页副本**（截图重影）。
    final Widget content = widget.child;

    // ---- 窄屏一级五页横滑（`AppShell.tsx:113–128`：`primaryTabNarrow ? PrimaryNavPage : PageTransition`）----
    // 逐条对齐：
    // · 判据 `primaryTabNarrow = isNarrow && isPrimaryTabPath(pathname)`（`AppShell.tsx:60`）；
    // · `direction` = 一级 tab 顺序索引差（`usePrimaryNavSwipeDirection.ts:29–35`），0 ⇒ 只淡入淡出；
    // · `onNavigate` 的落点 `(idx + step + len) % len`（`PrimaryNavPage.tsx:71–73`）——
    //   **与底部 tab 点击同一条路径**（`context.go(path)`，见上方 `bottomTabs()` 的 `onSelect`）；
    // · 宽屏（含宽屏的既有 PageTransition 路径）**不挂该手势** —— `AppShell.tsx:114` 是二选一分支。
    //
    // ⚠️ 与 web 的结构差异（登记）：web 给 `PrimaryNavPage` 传 `key={pathname}` ⇒
    // 每次切换重挂实例（旧实例由 `AnimatePresence` 保管退场、新实例从 0 起）；
    // Flutter 侧不能在外层带 key（`ShellRoute` 的 child **就是** shell navigator，
    // 其 `GlobalObjectKey(navigatorKey.hashCode)` 被故意复用，见 `app_router.dart:93–122`
    // 与 `theme/page_transitions.dart:21–34`）⇒ 用 `replayKey: pathname` 表达「重播」语义。
    final bool primaryTabNarrow = isNarrow && aylaIsPrimaryTabPath(pathname);
    final Widget shellContent = primaryTabNarrow
        ? AylaPrimaryNavPage(
            direction: _navDirection,
            replayKey: pathname,
            onNavigate: (int step) {
              final int index = aylaPrimaryTabIndex(pathname);
              if (index < 0) return;
              final int count = aylaPrimaryTabOrder.length;
              context.go(
                aylaPrimaryTabOrder[(index + step + count) % count].path,
              );
            },
            child: content,
          )
        : content;

    final EdgeInsets safe = MediaQuery.paddingOf(context);
    final double fabBottomNarrow = 64 + safe.bottom + 12;

    Widget bottomTabs() => AylaBottomTabs(
          module: moduleKey,
          onSelect: (AylaPrimaryModule m) => context.go(m.path),
        );

    // ---- 系统返回键（2026-10-20）----
    //
    // 挂在这里而不是 main.dart 的 MaterialApp.builder：`BackButtonListener` 内部是
    // `Router.of(context)`，builder 的 context 在 Router **之外** ⇒ 会抛
    // `Router operation requested with a context that does not include a Router`。
    // AppShell 是 `ShellRoute.builder` 的返回，天然是 Router 的后代（实测）。
    //
    // 机制链、修复前的实测读数（任何页面按返回都直接 SystemNavigator.pop 退出）
    // 与本件的分档判据全部写在 `layout/app_back.dart` 的文件头。
    return AylaBackButtonHost(
      pathname: pathname,
      canPop: context.canPop(),
      onGoHome: () {
        aylaClearEntryOrigin();
        context.go(kAylaHomePath);
      },
      // 回「上一级页面」（路由栈空且记得来源时）—— web navigate(-1) 的等价物。
      // 不在这里 clear：takeEntryOrigin 已消费过本次来源。
      onGoToOrigin: (String origin) => context.go(origin),
      // 群页的三级兜底必须由活着的那一个 GroupPage State 执行（场景历史栈是它的私有
      // 状态）；它挂载时把处理器登记到模块级 [aylaGroupBackHandler]。
      onGroupBack: () async {
        final AylaGroupBackHandler? handler = aylaGroupBackHandler;
        if (handler == null) {
          // 群页尚未挂好（切页瞬间）⇒ 保守回群列表，绝不交回系统（会退出 App）。
          context.go(kAylaHomePath);
          return true;
        }
        return handler();
      },
      child: Stack(
      children: <Widget>[
        Column(
          children: <Widget>[
            if (topBar != null) topBar,
            Expanded(child: ClipRect(child: shellContent)),
            if (showBottomTabs && !bottomTabsLeaving) bottomTabs(),
          ],
        ),
        // 底栏离场态：脱离流 + 下滑 100%（200ms ease-in，`shell.css:99–101`）
        if (showBottomTabs && bottomTabsLeaving)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: AnimatedSlide(
                offset: const Offset(0, 1),
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeIn,
                child: bottomTabs(),
              ),
            ),
          ),
        // ---- 窄屏左下角消息入口（`AppShell.tsx:140–146`）----
        // 图标 **24×24**（两档同值）：`MessageFab.tsx:29`（backHome）/ `:40`（消息）
        // 都是 `<Icon … width={24} height={24} />`，而 `.message-fab`（shell.css:423–439，
        // 全仓唯一命中、无 @media 覆写）不含任何 svg 尺寸声明 ⇒ CSS 层不缩放。
        // 同件的快捷消息档早已按此传 24（fab.dart 的 AylaQuickMessageFab，带同源注释）。
        if (isNarrow && primaryNavNarrow)
          Positioned(
            left: 16,
            bottom: fabBottomNarrow,
            child: AylaMessageFab(
              icon: AylaIcon(aylaIconByName('iconMessage')!, size: 24),
              onPressed: () => context.go('/messages'),
              semanticLabel: '消息',
            ),
          )
        else if (isNarrow && messagesNarrow)
          Positioned(
            left: 16,
            bottom: fabBottomNarrow,
            child: AylaMessageFab(
              // backHome 变体：**IconHome**（`MessageFab.tsx:21–31` —— `if (backHome)` 返回
              // `<IconHome width={24} height={24} />`，aria-label「返回主页」）。
              // 原写 iconBack 是 glyph 选错（2026-09-29 用户实报「返回主页图标使用错误」）。
              icon: AylaIcon(aylaIconByName('iconHome')!, size: 24),
              onPressed: () => context.go('/group'),
              semanticLabel: '返回主页',
            ),
          )
        else if (isNarrow && !privateChatNarrow && messageBadge > 0)
          Positioned(
            left: 16,
            bottom: fabBottomNarrow,
            child: AylaQuickMessageFab(
              unread: messageBadge,
              quickMessagesOpen: shell.quickMessagesOpen,
              onOpenQuickMessages: () =>
                  ref.read(shellUiProvider.notifier).setQuickMessagesOpen(true),
            ),
          ),
        // ---- 创建 FAB（右下）----
        if (fabAction != null)
          Positioned(
            right: isNarrow ? 16 : 32,
            bottom: isNarrow ? fabBottomNarrow : 32,
            child: AylaCreateFab(
              // 图标 24（`CreateFab.tsx:71` 的 `<IconPlus width={24} height={24} />`；
              // `.create-fab` 同样无 svg 尺寸覆写）—— 与消息档同源的漏参，一并按 web 收口。
              icon: AylaIcon(aylaIconByName('iconPlus')!, size: 24),
              semanticLabel: fabAction.label,
              onPressed: () => setState(() => _createSheetOpen = true),
            ),
          ),
        // ---- 宽屏浮层按钮组（`AppShell.tsx:149–157`）----
        if (cornerFabs.refresh &&
            cornerFabs.refreshPosition == AylaRefreshFabPosition.corner)
          AylaCornerFabStack(
            refresh: cornerFabs.refresh,
            scrollTop: cornerFabs.scrollTop,
            onRefresh: shell.refreshCallback,
          ),
        // ⚠️ **不要再包一层 Positioned**：`AylaRefreshFab` 的 bottomLeft 档
        // **自身就返回 `Positioned(left: 32, bottom: 32)`**（`fab.dart` 的
        // `.corner-fab-refresh.is-bottom-left` 定位）。外层再包一个 Positioned 会让
        // 同一 RenderObject 收到两份 StackParentData ⇒
        // `Incorrect use of ParentDataWidget`（2026-09-29 由 router_test 的动态探测
        // 走到 `/messages`（宽屏 = bottomLeft 档）时抓到；此前探测总在前一条路由
        // 提前返回而没被触发）。
        if (cornerFabs.refresh &&
            cornerFabs.refreshPosition == AylaRefreshFabPosition.bottomLeft)
          AylaRefreshFab(
            position: AylaRefreshFabPosition.bottomLeft,
            onRefresh: shell.refreshCallback,
          ),
        // ⚠️ **不要再包一层 `Positioned`**：`AylaScrollTopFab` 的 narrow 档**自身就返回
        // `Positioned`**（`fab.dart:418–428`：`right` 16 / 22（stacked）、`bottom` 64 + safe + 12
        // （stacked 再 +68）= `shell.css:762–773` 的 `.is-narrow` / `.is-narrow.is-stacked`）。
        // 外层再包一个 Positioned 会让同一 RenderObject 收到两份 `StackParentData` ⇒
        // `Incorrect use of ParentDataWidget`：窄屏（≤768）走到 `/group/:id/posts`、
        // `/group/:id/voice`、`/group/:id/games`（`shellConfig` 的 `aylaNarrowScrollTopPaths`）
        // 即触发 —— 与上一轮宽屏 `bottomLeft` 的 `AylaRefreshFab` 同一坑，本轮一并收口。
        if (isNarrow && cornerFabs.scrollTop)
          AylaScrollTopFab(
            position: AylaScrollTopFabPosition.narrow,
            stacked: fabAction != null,
          ),
        // ---- 会话活动悬浮球（`AppShell.tsx:130`；无会话时组件自己不渲染）----
        // ⚠️ **必须传实参**：本件是「参数注入型」，两个会话为 null 时它自己
        // `SizedBox.shrink()`（等价 tsx 135 的 `if (!showVoice && !showLive) return null`）
        // ⇒ 少传一次就等于整个悬浮球在真实运行时**恒不出现**（2026-10 实测的漏接线）。
        // 判定搬进 [`_SessionActivityHost`]：那里只订阅「活动态档案 + 四个 auth 字段 +
        // pathname」，索引变化只重建这一件，不波及整棵壳层。
        //
        // ⚠️⚠️ **层序不能只按"web 里组件出现的先后"直觉摆**：web 的 z-index 是
        // FAB 族 40 < 底栏 50 < **悬浮球 55** < 小窗 60（`shell.css:463–465` 的注释原文：
        // 「高于顶栏常驻层 50（返回直播/语音房入口不被顶栏遮挡），仍低于直播小窗 60」），
        // 而消息/创建 FAB 只有 40 ⇒ 悬浮球必须排在**两个 FAB 之后**。本 `Stack` 里
        // 同层按声明顺序叠放，排在它们之前会被 44px 的球（含收起态贴边区）盖住入口。
        const _SessionActivityHost(),
        // ---- 直播小窗（**窗口外**，2026-10-31 起不再在应用内渲染）----
        // 用户原话：「不会存在直播小窗浮层，取而代之的是创建时就脱离应用的悬浮窗」。
        // 所以这里只保留**数据投影**：`miniPlayer` 出现 ⇒ 打开窗口外小窗；
        // 消失 ⇒ 关掉它。widget 本体仍是同一份 `AylaLiveMiniPlayer`（跑在第二引擎里）。
        //
        // ## 平台分工（能力边界，如实登记）
        // - **Windows**：`aylaEnterDetachedLive` 走 `openLiveWindow` ⇒ 第二引擎 + 置顶透明窗，
        //   里面 build 同一份 `AylaLiveMiniPlayer`（含 media_kit 那一路 HLS）。
        // - **Android**：第二引擎**不注册任何插件**（见 `OverlayFlutterHost.kt` 文件头），
        //   放不了 media_kit 视频面；Android 的「视频离开应用」由**既有 Android PiP** 承担
        //   （`enterPip`，系统原生画中画）。此时本件拿到 `ok=false` ⇒ 不打开窗口外小窗，
        //   但**会话与观看登记继续**（PiP 是同一 Activity 同一 engine）。
        //   叠加层那边仍然显示**同一个悬浮球组**（含直播球，点一下回房）——
        //   这是用户「用现有悬浮球」那条需求的直接实现。
        //
        // 无渲染子级 ⇒ 本件不占 `Stack` 的任何位置（也不再有 z 60 的层序问题）。
        _LiveMiniPlayerHost(
          mini: liveMiniPlayer,
          onOpenRoom: () => context.go(liveMiniPlayer!.sourceRoute),
        ),
        // ---- 客户端更新弹窗（登录后自动检查的呈现面；层级高于 FAB/小窗）----
        const AylaUpdateHost(),
        // ---- 创建浮层（`.create-fab` 的落点）----
        if (_createSheetOpen && fabAction != null) _createSheet(fabAction),
        // ---- 红点快捷消息栏（`AppShell.tsx:158–161`）----
        //
        // web 原文：`{isNarrow && quickMessagesOpen ? <QuickMessagesSheet
        // onClose={() => useShellStore.getState().setQuickMessagesOpen(false)} /> : null}`
        // —— 放在壳层**最后一个**子级（DOM 里也是最后一项），层级 = `.quick-messages-overlay
        // { position: fixed; inset: 0; z-index: 70 }`（messages.css 343–347），
        // 与创建浮层同档 70、按 DOM 顺序压在它之后。
        //
        // 状态归 `shellUiProvider`（web `stores/shell.ts` 同）：**红点归零不关闭**
        // （打开会话标已读会让 QuickMessageFab 因 `messageBadge > 0` 被卸载，若 open 在
        // Fab 内部则面板被连带关掉 —— 这正是 web 注释里写明的 R-QM bug 修复）。
        if (isNarrow && shell.quickMessagesOpen)
          AylaQuickMessagesHost(
            onClose: () =>
                ref.read(shellUiProvider.notifier).setQuickMessagesOpen(false),
          ),
      ],
      ),
    );
  }
}

/// 跨页面媒体会话悬浮球宿主（web `AppShell.tsx:130` 的 `<SessionActivityIndicator />`）。
///
/// ## 为什么要有这一层
/// web 的组件**自己**读 `useAuthStore` / `useSessionActivityStore` / `useLocation`；
/// Flutter 侧的组件是「展示型 + 注入」约定（见 `widgets/shell/session_activity.dart` 文件头），
/// 判定必须由调用方给出。放在壳层的一个**独立子件**里而不是内联进 `build`，是为了让
/// 「索引变化 ⇒ 重建」的影响面**只有这一件**：整棵 `AppShell` 不该因为进出语音房而重建。
///
/// 订阅面 = 活动态档案（[sessionActivityProvider]）＋当前用户的四个媒体字段
/// （`is_in_voice` / `voice_room_id` / `is_live` / `live_room_id`）＋ pathname。
/// 前三样是 web 组件自己订阅的同一份事实，第四样是它的 `useLocation()`。
class _SessionActivityHost extends ConsumerStatefulWidget {
  const _SessionActivityHost();

  @override
  ConsumerState<_SessionActivityHost> createState() =>
      _SessionActivityHostState();
}

/// 悬浮球宿主的可变面（2026-10-31 起是「窗口外浮层的同步器」）。
///
/// ## 用户定稿（逐字）
/// 「**不要造轮子！用现有的悬浮球和直播小窗**」
/// 「悬浮球不应该重新做一个出来，而是直接原来的浮层悬浮球直接扔出应用窗口外」
/// 「应用内不会再存在任何浮层……取而代之的是创建时就脱离应用的、显示在其他应用之上的
/// 悬浮窗，外观和交互完全没有区别」
///
/// ⇒ 本件**不再**在应用内渲染球组，也**没有**任何「脱离」按钮：
/// 它只做一件事 —— 把「当前有哪些会话」算成 [AylaOverlayPayload] 推给
/// **第二个引擎的叠加层**（Windows：置顶透明窗；Android：TYPE_APPLICATION_OVERLAY）。
///
/// 三个状态位：
/// - [_ballWindowOpen]：系统层浮层当前是否已打开（以原生回执为准，不用「推过」猜）；
/// - [_overlayGuideOpen]：Android 未授予「显示在其他应用上层」时的引导弹层；
/// - [_busy]：正在等平台返回（防重入 —— `showBall` 会建第二引擎，很慢）。
///
/// **离开 App 后仍要能点回会话** ⇒ 监听 [AylaDetachedLiveEvents]：
/// `ballTap` → `context.go(sourceRoute)`；`ballClosed` → 复位「已打开」认知。
class _SessionActivityHostState extends ConsumerState<_SessionActivityHost> {
  /// 原生事件订阅（`ballTap` / `ballClosed`）。
  StreamSubscription<AylaDetachedLiveEvent>? _events;

  /// 上一次推给窗口外悬浮球的 payload（null = 还没推过）。
  ///
  /// 用它做**去重**：`build` 会因为活动态索引 / auth 字段的任意变化重跑，
  /// 而通道往返是有成本的（序列化 + 跨引擎消息），只在投影真的变了才推。
  String? _lastPushedBallPayload;

  /// 窗口外悬浮球当前是否已打开（原生回执为准）。
  ///
  /// **不能**用「上次推成功」当已打开：用户可能从系统层把它关掉了
  /// （`onBallClosed`），或者根本没开成（平台不支持 / 原生失败）。
  bool _ballWindowOpen = false;

  /// 正在等通道返回（防连点 / 防重入）。
  bool _busy = false;

  /// Android 未授予「显示在其他应用上层」时的引导弹层。
  bool _overlayGuideOpen = false;

  @override
  void initState() {
    super.initState();
    _events = AylaDetachedLiveEvents.instance.stream.listen(_onDetachedEvent);
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    // 壳层卸载（登出 / 应用退出）⇒ 别把悬浮球窗口留在桌面上。
    if (_ballWindowOpen) {
      _ballWindowOpen = false;
      unawaited(aylaHideDetachedBall());
    }
    super.dispose();
  }

  /// 原生 → Dart：悬浮球被点 / 被关。
  void _onDetachedEvent(AylaDetachedLiveEvent event) {
    switch (event.kind) {
      case AylaDetachedLiveEventKind.ballTap:
        // 点球 = 回房。路由合法才 go（原生侧理论上不会传空，空串仍要防）。
        final String route = event.sourceRoute;
        if (route.isNotEmpty && mounted) context.go(route);
      case AylaDetachedLiveEventKind.ballClosed:
        // 用户从系统层关掉了球（Android 通知栏「关闭」/ Windows 关窗）⇒ 清掉
        // 「窗口外悬浮球已打开」的本地认知，下一次会话变化要能重开它
        // （否则 Windows 上用户关掉球以后它就再也不出现了）。
        _ballWindowOpen = false;
        _lastPushedBallPayload = null;
      case AylaDetachedLiveEventKind.pipChanged:
      case AylaDetachedLiveEventKind.liveWindowClosed:
        // PiP / 独立直播窗归 task-2 / task-4；本件不消费。
        break;
    }
  }

  /// 把「当前有哪些会话」推给**窗口外**的悬浮球窗口（Windows / Android 的唯一渲染宿主）。
  ///
  /// 语义 = 「同步」而不是「开关」：
  /// - 有会话且窗口没开 ⇒ `showBall`（原生负责建窗 + 建第二引擎）；
  /// - 有会话且窗口已开 ⇒ `updateBall`（只推新投影，不重建窗口）；
  /// - 无会话且窗口已开 ⇒ `hideBall`（会话都结束了，浮层没有存在意义）；
  /// - 无会话且窗口没开 ⇒ 什么都不做。
  Future<void> _syncDetachedBall(AylaOverlayPayload payload) async {
    if (!aylaDetachedBallPlatformSupported) return;
    final String encoded = payload.encode();
    if (payload.hasAnySession) {
      if (_ballWindowOpen) {
        if (encoded == _lastPushedBallPayload) return;
        _lastPushedBallPayload = encoded;
        final bool delivered = await aylaUpdateDetachedBall(payload: encoded);
        if (!delivered) {
          // 窗口在推送途中被用户关掉了（原生侧 onBallClosed 可能还没到）：
          // 直接重开，避免「球永远不再出现」。
          _ballWindowOpen = false;
          _lastPushedBallPayload = null;
        }
        return;
      }
      if (_busy) return;
      _busy = true;
      final bool liveFirst = payload.liveSessionId.isNotEmpty;
      final AylaDetachedBallResult result = await aylaShowDetachedBall(
        kind: liveFirst
            ? AylaActivityKind.live.name
            : AylaActivityKind.voice.name,
        sessionId: liveFirst ? payload.liveSessionId : payload.voiceSessionId,
        title: liveFirst ? payload.liveTitle : payload.voiceTitle,
        sourceRoute: liveFirst ? payload.liveRoute : payload.voiceRoute,
        payload: encoded,
      );
      _busy = false;
      if (!mounted) return;
      if (result == AylaDetachedBallResult.shown) {
        _ballWindowOpen = true;
        _lastPushedBallPayload = encoded;
        return;
      }
      // 没开成：明确告知（不静默），并把去重基线清掉，下一次变化还会再试。
      _lastPushedBallPayload = null;
      if (result == AylaDetachedBallResult.permissionRequired) {
        // Android 未授予「显示在其他应用上层」：弹明确引导（Windows 不会走到这里）。
        // ⚠️ 去重：未授权时 `_ballWindowOpen` 恒为 false，每次会话变化都会重试
        // ⇒ 不判重会把引导弹层刷成无限循环。
        if (!_overlayGuideOpen) setState(() => _overlayGuideOpen = true);
      } else if (result == AylaDetachedBallResult.failed) {
        _toast('窗口外悬浮球打开失败，请稍后重试。');
      }
      return;
    }
    // 没有会话了。
    if (!_ballWindowOpen) return;
    _ballWindowOpen = false;
    _lastPushedBallPayload = null;
    await aylaHideDetachedBall();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final String pathname = GoRouterState.of(context).uri.path;
    // 三个订阅面逐条对齐 tsx：`useAuthStore` 的四个字段（它只读这四个）、
    // `useSessionActivityStore` 的两条记录、`useLocation()` 的 pathname。
    final AuthUser? user = ref.watch(authNotifierProvider.select(
      (AuthState s) => s.user,
    ));
    // 活动态索引是模块级单例（普通 `Provider` 只做注入，见 `state/room_providers.dart`）
    // ⇒ 用 `ListenableBuilder` 订阅，重建范围仅限本件。
    final AylaSessionActivityStore activity =
        ref.read(sessionActivityProvider);
    return ListenableBuilder(
      listenable: activity,
      builder: (BuildContext context, Widget? child) {
        // tsx 34–39：`is_in_voice && voice_room_id != null` ⇒ 取 id（否则整条为空）。
        final String? voiceId =
            user != null && user.isInVoice && user.voiceRoomId != null
                ? user.voiceRoomId
                : null;
        final String? liveId =
            user != null && user.isLive && user.liveRoomId != null
                ? user.liveRoomId
                : null;
        final AylaActivitySession? voice = voiceId == null
            ? null
            : _activitySession(
                record: activity.voiceSession,
                sessionId: voiceId,
                fallbackRoute: '/voice/${Uri.encodeComponent(voiceId)}',
                fallbackTitle: '语音房',
              );
        final AylaActivitySession? live = liveId == null
            ? null
            : _activitySession(
                record: activity.liveSession,
                sessionId: liveId,
                fallbackRoute: '/live/start/${Uri.encodeComponent(liveId)}',
                fallbackTitle: '直播间',
              );
        // tsx 71–82 的两条隐藏判定：
        // · 语音球在**语音房自己的路由**上隐藏（群内语音是 `sourceRoute` 那条）；
        // · 直播球在**对应开播控制台**上隐藏 —— 注意它用 `/live/start/:id` 硬拼，
        //   而不是 `sourceRoute`（web 原话），所以群内直播进控制台后直播球仍在。
        final bool onVoiceRoom = voice != null &&
            (pathname == '/voice/${Uri.encodeComponent(voice.sessionId)}' ||
                pathname == voice.sourceRoute);
        final bool onLiveConsole = live != null &&
            pathname ==
                '/live/start/${Uri.encodeComponent(live.sessionId)}';
        // tsx 81–82：`showVoice` / `showLive`（`null` ⇒ 组件少渲染那个球）。
        final AylaActivitySession? shownVoice =
            voice != null && !onVoiceRoom ? voice : null;
        final AylaActivitySession? shownLive =
            live != null && !onLiveConsole ? live : null;

        // ---- 窗口外悬浮球（Windows + Android）----
        //
        // 用户原话：「应用内不会再存在任何浮层，不再存在原本那个悬浮球浮层……
        // 取而代之的是创建时就脱离应用的、显示在其他应用之上的悬浮窗，
        // 外观和交互完全没有区别」。
        //
        // 所以这两个平台上**不再**在应用内 build `AylaSessionActivityIndicator`：
        // 同一份组件改由第二个引擎在**透明叠加层**里 build
        // - Windows：`windows/runner/live_window.cpp`（WS_EX_TOPMOST + 逐像素透明）
        // - Android：`OverlayFlutterHost.kt`（TYPE_APPLICATION_OVERLAY + TRANSLUCENT）
        // 两边都走 `widgets/shell/overlay_window_app.dart` 的同一棵树。
        // 本件只负责算「该显示哪些球」并推过去。
        //
        // iOS / Web 保持原样在应用内渲染 —— 它们**没有任何**跨应用悬浮窗口 API
        // （iOS 无系统 API；Web 更无），这是能力边界，不伪装成已实现。
        final bool detachedBall = !kIsWeb &&
            (defaultTargetPlatform == TargetPlatform.windows ||
                defaultTargetPlatform == TargetPlatform.android) &&
            aylaDetachedBallPlatformSupported;
        if (detachedBall) {
          // 推的**不是** `shownVoice` / `shownLive`，而是完整的 `voice` / `live`：
          // 窗口外悬浮球是常驻浮层，不该跟着「本页是否隐藏该球」闪烁
          // （用户进语音房时应用内那一份按 tsx 隐藏，但系统层上的球不该消失）。
          final AylaOverlayPayload payload = AylaOverlayPayload(
            kind: AylaOverlayKind.activityBall,
            voiceKind: voice?.kind.name ?? '',
            voiceSessionId: voice?.sessionId ?? '',
            voiceTitle: voice?.title ?? '',
            voiceRoute: voice?.sourceRoute ?? '',
            liveKind: live?.kind.name ?? '',
            liveSessionId: live?.sessionId ?? '',
            liveTitle: live?.title ?? '',
            liveRoute: live?.sourceRoute ?? '',
          );
          // ⚠️ 必须在**构建之外**发通道调用：`showBall` 会建第二个 engine，
          // 在 build 里 await 会卡住首帧。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            unawaited(_syncDetachedBall(payload));
          });
        }

        // 应用内那一份：Windows / Android 上**不渲染**（渲染宿主在窗口外）。
        final AylaSessionActivityIndicator indicator =
            AylaSessionActivityIndicator(
          voice: shownVoice,
          live: shownLive,
          // tsx 148 / 159：`navigate(session.sourceRoute || 兜底路由)` ——
          // 兜底已在 [_activitySession] 里拼好，这里直接用。
          onOpenSession: (AylaActivitySession session) =>
              context.go(session.sourceRoute),
        );
        return Stack(
          children: <Widget>[
            if (!detachedBall) indicator,
            // Android「显示在其他应用上层」授权引导（**没有运行时弹窗**，只能跳系统设置页
            // ⇒ 必须给明确引导，不能静默失败）。复用库内确认弹层 + 根 Overlay：
            // 遮罩要铺满整视口，挂在壳层 Stack 里会被顶栏挡住 —— 与 `voice_support.dart:1496`
            // 同一条实测结论。
            if (_overlayGuideOpen)
              AylaRootOverlay(
                builder: (BuildContext _) => AylaConfirmDialog(
                  title: '需要「显示在其他应用上层」权限',
                  message: '脱离应用后，语音/直播悬浮球要显示在其它应用之上，'
                      '需要你在系统设置里允许 Ayla 显示在其他应用上层。'
                      '点「去设置」后会打开系统设置页，请找到「Ayla」并打开该开关，'
                      '然后回到 Ayla 再点一次脱离键。',
                  confirmLabel: '去设置',
                  cancelLabel: '暂不',
                  onClose: () => setState(() => _overlayGuideOpen = false),
                  onConfirm: () {
                    setState(() => _overlayGuideOpen = false);
                    unawaited(aylaOpenOverlayPermissionSettings());
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}
/// 把「会话活动索引的记录」投影成悬浮球要的会话（web `SessionActivityIndicator.tsx:41–68`）。
///
/// 逐条复刻 tsx 的三元链：
/// 1. 索引里已经有该 id 的记录 ⇒ **整条沿用**（title / sourceRoute 都用索引里的真实值）；
/// 2. 索引缺这条（或 id 对不上）⇒ 现场造兜底投影：`title` 是字面量、`sourceRoute`
///    是按 id 拼出来的兜底路由（tsx 49 / 63），status 固定 `connected`。
///
/// ⚠️ 索引里剩下的 `status` / `lastError` / `owner` / `updatedAt` **到不了 UI** ——
/// web 的组件只把 `title` / `sourceRoute` / `sessionId` 传下去（tsx 148–161）。
/// 这是 web 的真实口径，不是这里漏了字段；`AylaActivityRecord` 保留完整字段是为了
/// 对齐索引自身的状态机语义（详见 `state/session_activity_state.dart` 文件头）。
AylaActivitySession _activitySession({
  required AylaActivityRecord? record,
  required String sessionId,
  required String fallbackRoute,
  required String fallbackTitle,
}) {
  if (record != null && record.sessionId == sessionId) {
    return AylaActivitySession(
      sessionId: record.sessionId,
      sourceRoute: record.sourceRoute,
      title: record.title,
    );
  }
  return AylaActivitySession(
    sessionId: sessionId,
    sourceRoute: fallbackRoute,
    title: fallbackTitle,
  );
}

/// 直播小窗宿主 —— **窗口外小窗的开关**（2026-10-31 起不再在应用内渲染）。
///
/// ## 为什么不再 build `AylaLiveMiniPlayer`
/// 用户原话：「不会存在直播小窗浮层，取而代之的是创建时就脱离应用的、显示在其他应用之上的
/// 悬浮窗，外观和交互完全没有区别」。
/// ⇒ widget 树搬到第二个 engine（`widgets/live/live_window_surface.dart` 的
/// `AylaDetachedMiniPlayerHost`，build 的仍是**同一个** `AylaLiveMiniPlayer`），
/// 本件退化成「`miniPlayer` 出现 ⇒ 打开窗口外小窗；消失 ⇒ 关掉它」的**同步器**。
///
/// ## 为什么仍然是个 widget（而不是一个纯监听器）
/// 它天然挂在 `AppShell` 的 `build` 里 ⇒ 能在「`miniPlayer` 变化」这一刻拿到最新的
/// `mini`，不需要额外的全局注册表；并且它**返回零尺寸**（`SizedBox.shrink`），
/// 不参与 `Stack` 的层序（应用内不再有任何浮层）。
///
/// ## 同步语义
/// - `mini != null` 且窗口没开 ⇒ `openLiveWindow`（带归一后的 HLS 地址 + 标题）；
/// - `mini != null` 且窗口已开 ⇒ 只更新标题/地址（切台）；
/// - `mini == null` 且窗口已开 ⇒ `closeLiveWindow`。
///
/// 原生侧「用户关掉小窗」会回 `onLiveWindowClosed` ⇒ 清掉本地认知，
/// 下一次 `miniPlayer` 变化还能重开（不会「关一次就再也不出现」）。
class _LiveMiniPlayerHost extends StatefulWidget {
  const _LiveMiniPlayerHost({required this.mini, required this.onOpenRoom});

  /// 小窗 UI 投影（`AylaLiveState.miniPlayer`）；null = 没有小窗。
  final AylaLiveMiniPlayerState? mini;

  /// 点小窗主体 → 回直播间（由原生侧 `activateMain` 触发）。
  final VoidCallback onOpenRoom;

  @override
  State<_LiveMiniPlayerHost> createState() => _LiveMiniPlayerHostState();
}

class _LiveMiniPlayerHostState extends State<_LiveMiniPlayerHost> {
  /// 窗口外小窗当前是否已打开（以原生回执为准）。
  bool _open = false;

  /// 正在打开 / 关闭中（防重入：`show` 会建第二个 engine，很慢）。
  bool _busy = false;

  /// 上一次成功打开时的频道 id / 播放地址（切台或换地址才需要重开窗口）。
  String? _openedChannelId;
  String? _openedUrl;

  /// 原生事件订阅（`liveWindowClosed`）。
  StreamSubscription<AylaDetachedLiveEvent>? _events;

  @override
  void initState() {
    super.initState();
    _events = AylaDetachedLiveEvents.instance.stream.listen(
      (AylaDetachedLiveEvent e) {
        if (e.kind != AylaDetachedLiveEventKind.liveWindowClosed) return;
        // 用户关掉了窗口外小窗 ⇒ 清本地认知。**不销毁会话**：会话归
        // `live_support.dart` 管（它自己也收到这条事件去重新接管画面）。
        _open = false;
        _openedChannelId = null;
        _openedUrl = null;
      },
    );
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    if (_open) {
      _open = false;
      unawaited(aylaCloseDetachedLive());
    }
    super.dispose();
  }

  /// 把「该不该有窗口外小窗」同步给原生（幂等；只在真的变化时才发通道调用）。
  Future<void> _sync() async {
    if (_busy) return;
    final AylaLiveMiniPlayerState? mini = widget.mini;
    if (mini == null) {
      if (!_open) return;
      _busy = true;
      _open = false;
      _openedChannelId = null;
      _openedUrl = null;
      await aylaCloseDetachedLive();
      _busy = false;
      return;
    }
    // 平台不支持（iOS / Web / 原生未实现）：明确降级 —— 应用内不再有浮层，
    // 所以这里什么都不做（不静默伪装成「已脱离」，也不偷偷把 App 内小窗加回来）。
    if (!aylaDetachedLivePlatformSupported) return;
    final String? url = mini.channel?.hlsUrl ?? mini.channel?.flvUrl;
    final String channelId = mini.channelId;
    if (_open && _openedChannelId == channelId && _openedUrl == url) {
      return; // 同一个频道、同一路地址：不需要任何动作。
    }
    _busy = true;
    final bool ok = await aylaEnterDetachedLive(
      channelId: channelId,
      title: mini.title,
      playUrl: url,
    );
    _busy = false;
    if (!mounted) return;
    _open = ok;
    _openedChannelId = ok ? channelId : null;
    _openedUrl = ok ? url : null;
  }

  @override
  Widget build(BuildContext context) {
    // 通道调用必须在构建之外：`openLiveWindow` 会建第二个 engine，
    // 在 build 里 await 会卡住首帧。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_sync());
    });
    // 应用内不再渲染任何浮层 ⇒ 零尺寸（不占 `Stack` 的位置）。
    return const SizedBox.shrink();
  }
}
