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
/// ## 未接线项（第 1 批登记，见 13 号文档）
/// · `LiveMiniPlayer`（`useLiveStore.miniPlayer`）—— 属 live 会话运行时批次；
/// · `QuickMessagesSheet` 的实际面板内容（私信 / 申请列表）—— 属消息域批次
///   （[ShellUiState.quickMessagesOpen] 已就位，Fab 已按它暂停半贴计时）；
/// · ~~未读聚合 `messageBadge`~~ ✅ **2026-09-28 消息域批次已接线**：`state/badges_state.dart` +
///   `state/chat_providers.dart`（`GET /me/badges/`；进入即拉 + 纯 WS 事件驱动，**无周期轮询**）；
/// · `ServerRail` / `ChannelSidebar`：web 的 AppShell **不渲染**它们 —— 它们是宽屏主页
///   （`GroupPage` 三列）的内部装配，属第 2 批。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/app_init.dart';
import '../core/ws/ws_manager.dart';
import '../router/shell_config.dart';
import '../state/auth_state.dart';
import '../state/chat_providers.dart';
import '../state/room_providers.dart';
import '../state/shell_state.dart';
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/buttons.dart';
import '../theme/tokens.dart';
import '../widgets/shell/bottom_tabs.dart';
import '../widgets/shell/create_sheet.dart';
import '../widgets/shell/fab.dart';
import '../widgets/shell/session_activity.dart';
import '../widgets/shell/top_nav.dart';


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
    wsManager?.disconnectAll();
    // 消息域：断开 chat 通道 owner 并清空会话/消息/红点/通知状态（各 store 的 reset）。
    aylaStopChatWs(ref);
    // 房内域：解绑目录帧桥 + 断开 voice/live 两通道 + 清房内状态（同 401 过期路径）。
    aylaStopRooms(ref);
    AppInit.instance.reset();
    ref.read(authNotifierProvider.notifier).clear();
  }

  void _onMenuSelected(AylaTopNavMenuAction action) {
    switch (action) {
      case AylaTopNavMenuAction.profile:
        context.go('/profile');
      case AylaTopNavMenuAction.favorites:
        context.go('/favorites');
      case AylaTopNavMenuAction.logout:
        _logout();
    }
  }

  @override
  Widget build(BuildContext context) {
    final String pathname = GoRouterState.of(context).uri.path;
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
      searchQuery: _searchQuery,
      onSearchChanged: (String v) => setState(() => _searchQuery = v),
      onSearchSubmitted: (String q) =>
          context.go('/search?q=${Uri.encodeComponent(q)}'),
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
            context.go('/search?q=${Uri.encodeComponent(q)}'),
        onSearchCleared: () => setState(() => _searchQuery = ''),
        onMenuSelected: _onMenuSelected,
        onBack: () => context.pop(),
      );
    } else if (isNarrow && narrowVariant == 'favorites') {
      topBar = AylaTopNav(
        variant: AylaTopNavVariant.favorites,
        onMenuSelected: _onMenuSelected,
        onBack: () => context.pop(),
      );
    } else if (isNarrow && narrowVariant == 'default') {
      topBar = AylaTopNav(
        variant: AylaTopNavVariant.home,
        userName: user?.nickname ?? '',
        userAvatarUrl: user?.avatar,
        userOnline: user?.online ?? false,
        onAvatarTap: () => context.go('/profile'),
        onSearchFieldTap: () => context.go('/search'),
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

    final EdgeInsets safe = MediaQuery.paddingOf(context);
    final double fabBottomNarrow = 64 + safe.bottom + 12;

    Widget bottomTabs() => AylaBottomTabs(
          module: moduleKey,
          onSelect: (AylaPrimaryModule m) => context.go(m.path),
        );

    return Stack(
      children: <Widget>[
        Column(
          children: <Widget>[
            if (topBar != null) topBar,
            Expanded(child: ClipRect(child: content)),
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
        // ---- 会话活动悬浮球（`AppShell.tsx:130`；无会话时组件自己不渲染）----
        const AylaSessionActivityIndicator(),
        // ---- 窄屏左下角消息入口（`AppShell.tsx:140–146`）----
        if (isNarrow && primaryNavNarrow)
          Positioned(
            left: 16,
            bottom: fabBottomNarrow,
            child: AylaMessageFab(
              icon: AylaIcon(aylaIconByName('iconMessage')!),
              onPressed: () => context.go('/messages'),
              semanticLabel: '消息',
            ),
          )
        else if (isNarrow && messagesNarrow)
          Positioned(
            left: 16,
            bottom: fabBottomNarrow,
            child: AylaMessageFab(
              icon: AylaIcon(aylaIconByName('iconBack')!),
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
              icon: AylaIcon(aylaIconByName('iconPlus')!),
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
        if (cornerFabs.refresh &&
            cornerFabs.refreshPosition == AylaRefreshFabPosition.bottomLeft)
          Positioned(
            left: 16,
            bottom: 32,
            child: AylaRefreshFab(
              position: AylaRefreshFabPosition.bottomLeft,
              onRefresh: shell.refreshCallback,
            ),
          ),
        if (isNarrow && cornerFabs.scrollTop)
          Positioned(
            right: AylaScrollTopFab.narrowRight,
            bottom: AylaScrollTopFab.narrowBottomBase + safe.bottom,
            child: AylaScrollTopFab(
              position: AylaScrollTopFabPosition.narrow,
              stacked: fabAction != null,
            ),
          ),
        // ---- 创建浮层（`.create-fab` 的落点）----
        if (_createSheetOpen && fabAction != null)
          AylaCreateSheet(
            title: fabAction.label,
            onClose: () => setState(() => _createSheetOpen = false),
            child: Padding(
              padding: const EdgeInsets.all(AylaSpacing.sp2),
              child: Text(
                '该创建表单属后续批次（web CreateFab.tsx:93–103 · shellConfig.ts:224–261：'
                '${fabAction.key} / handler=${fabAction.handler ?? '—'} / ${fabAction.plannedStep}）',
                style: AylaTextStyles.of(context).caption,
              ),
            ),
          ),
      ],
    );
  }
}