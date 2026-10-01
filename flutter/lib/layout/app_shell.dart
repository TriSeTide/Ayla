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
/// ## 窄屏浮动小窗（`AppShell.tsx:131–132`，2026-09-29 接线）
/// `isNarrow && miniPlayer != null` ⇒ 渲染 `AylaLiveMiniPlayer`（fixed 右下 16 / z 60）。
/// 状态与语义在 `state/live_state.dart`（`miniPlayer`）与 `pages/live_support.dart`
/// （`detachView` 进小窗 / `refreshSrsStatus` 结束清位 / `aylaCloseLiveMiniPlayer` 关闭）——
/// 小窗**只有窄屏渲染**（宽屏不开，web 同一条判据）。
///
/// ## 未接线项（第 1 批登记，见 13 号文档）
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

import '../pages/live_support.dart';
import '../router/shell_config.dart';
import '../state/auth_bootstrap.dart';
import '../state/auth_state.dart';
import '../state/chat_providers.dart' show badgesProvider;
import '../state/live_state.dart';
import '../state/room_providers.dart' show liveStateProvider;
import '../state/shell_state.dart';
import '../theme/app_icons.dart';
import '../theme/buttons.dart';
import '../theme/tokens.dart';
import '../widgets/live/live_mini_player.dart';
import '../widgets/shell/bottom_tabs.dart';
import '../widgets/shell/fab.dart';
import '../widgets/shell/session_activity.dart';
import '../widgets/shell/top_nav.dart';
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
      case AylaTopNavMenuAction.logout:
        _logout();
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
        // ---- 窄屏浮动小窗（`AppShell.tsx:131–132`）----
        // 只有窄屏渲染，且 `miniPlayer` 非空才出现（唯一 owner）；层级 z 60 高于底栏 50、
        // 消息/创建 FAB 40、活动态悬浮球 55，低于弹层遮罩 70+ ⇒ 放在 FAB 之后、浮层之前。
        // ⚠️ 本件必须是 `Stack` 的**直接子级**：`AylaLiveMiniPlayer` 自身返回 `Positioned`
        //（等价 web 的 `position: fixed`），外面再包 `Positioned` 会命中“双重 ParentData”。
        if (isNarrow && liveMiniPlayer != null)
          _LiveMiniPlayerHost(
            mini: liveMiniPlayer,
            onOpenRoom: () => context.go(liveMiniPlayer.sourceRoute),
          ),
        // ---- 创建浮层（`.create-fab` 的落点）----
        if (_createSheetOpen && fabAction != null) _createSheet(fabAction),
      ],
    );
  }
}

/// 窄屏浮动小窗宿主（web `AppShell.tsx:131–132`：
/// `{isNarrow && liveMiniPlayer ? <LiveMiniPlayer /> : null}`）。
///
/// - **渲染条件**只由 `AylaLiveState.miniPlayer` 决定（同 web：组件自身读 store），
///   位置/尺寸/交互全在 `AylaLiveMiniPlayer` 内部（fixed 右下 16 / 168×94 / z 60）；
/// - 会话（含 `videoView`）来自全局小窗宿主 [aylaMiniPlayerOwner]（唯一 owner）；
///   本件订阅它的 `notifyListeners`，播放器状态变化时刷新画面；
/// - **必须是 `Stack` 的直接子级**：`AylaLiveMiniPlayer` 自身返回 `Positioned`（等价 web 的
///   `position: fixed`）。本件是 StatelessWidget（不产生 RenderObject），`Positioned` 仍会
///   正确挂到 `Stack` 的 parentData 上；外面再包一层 `Positioned` 才会报双重 ParentData。
class _LiveMiniPlayerHost extends StatelessWidget {
  const _LiveMiniPlayerHost({required this.mini, required this.onOpenRoom});

  /// 小窗 UI 投影（`AylaLiveState.miniPlayer`）。
  final AylaLiveMiniPlayerState mini;

  /// 点击小窗 / Enter / Space → 回直播间（web `navigate(mini.sourceRoute)`）。
  final VoidCallback onOpenRoom;

  /// 无宿主会话时的空可监听（避免每次 build 新建订阅对象）。
  static final Listenable _idle = Listenable.merge(const <Listenable>[]);

  @override
  Widget build(BuildContext context) {
    final AylaLiveRoomSession? owner = aylaMiniPlayerOwner;
    return ListenableBuilder(
      listenable: owner ?? _idle,
      builder: (BuildContext context, Widget? child) => AylaLiveMiniPlayer(
        // 同一会话实例的 `videoView`：Flutter 的平台视图不能跨树迁移 ⇒ 由平台实现重建
        // 渲染面（播放器实例与 HLS 连接不重建，见 `live_support.dart` 文件头的偏离登记）。
        videoView: owner?.videoView,
        // web `LiveMiniPlayer.tsx:195` `title={mini.channel?.title ?? "直播间"}`。
        channelTitle: mini.title,
        onOpenRoom: onOpenRoom,
        // 关闭键 = 完整销毁会话（web `LiveMiniPlayer.tsx:93–96`；幂等）。
        onClose: () => unawaited(aylaCloseLiveMiniPlayer()),
      ),
    );
  }
}