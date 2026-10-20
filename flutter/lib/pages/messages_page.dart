/// 消息中心（路由 `/messages`）—— web `pages/MessagesPage.tsx`（401 行）的 Flutter 等价物。
///
/// ## 事实源（逐条）
/// - tsx 37–61：三个 tab（私信 / 好友列表 / 认证消息）+ 五路 `useSocialPage` 取数；
/// - tsx 181–203：**宽屏两列**（`WideMessagesSidebar` + `.wide-messages-pane`，右列空态
///   「选择一个会话开始聊天」/「左侧会话列表，点击进入私聊」）；
/// - tsx 206–244：窄屏页骨架 —— 选项卡行（inline style `padding: 0 16px` + `flex: 1` 的
///   `.messages-tabs`）+ 三档面板；认证 tab 徽标 = `requestBadge()`；
/// - tsx 246–270：私信 tab（爱莉入口 + `ConversationList` + `DirectoryLoadMore`，包 `PullToRefresh`）；
/// - tsx 271–314：好友 tab（`.messages-group` + 「我的好友（N）」+ 头像 **40** 的行 + 空态
///   「还没有好友，去搜索添加吧」+ 页脚）；
/// - tsx 315–364：认证 tab（`.messages-requests`：「认证消息」标题 + 提示 + 四分组 + 空态）；
/// - tsx 114–150：解除好友 / 同意拒绝三路动作（成功后本地移除 + `refreshBadges`）；
/// - CSS：`messages.css 9–15 / 17–22 / 24–57 / 59–68 / 70–81 / 83–94 / 96–204 / 207–230`
///   + `auroraqua.css 272–285`（`.messages-tabs` 的 1px 边 + radius 16 + inset + margin sp2 +
///   padding sp1 —— **后加载，同特异性下覆盖 messages.css 的 padding**）
///   + `auroraqua.css 414`（窄屏 `auroraqua-panel-from-top` 入场，由 `AylaMessagesTabs` 宿主承担）。
///
/// ## 与 web 的差异（登记）
/// 1. **presence 通道未接入** ⇒ 在线态不注入（组件回退 REST 快照 `online`），不伪造实时在线；
/// 2. 会话列表 **60s 缓存短路**未实现（同 `state/paged_list.dart` 的既有登记）；
/// 3. 窄屏好友/认证 tab 的整页滚动用外层 `SingleChildScrollView` 表达（web 是 `.messages-page`
///    自身 `overflow-y: auto`）；私信 tab 仍由列表内部滚动；
/// 4. 会话 ⋯ 菜单（置顶/删除）web 在本页**不传**回调 ⇒ 本页同样不传；
/// 5. 空态判定比 web **宽一格**：`AylaSocialPage.isEmptyState` 只判 `items/loading/error`，
///    web 还要求 `!hasMore`（`MessagesPage.tsx:362`）——`hasMore` 且无条目的组合极罕见。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/chat_api.dart';
import '../core/api/directory_page.dart' show AylaDirectoryPage;
import '../core/api/users_api.dart';
import '../core/models/conversation.dart';
import '../core/models/elysia_profile.dart';
import '../core/models/social_requests.dart';
import '../core/models/user_public.dart';
import '../state/auth_state.dart';
import '../state/chat_providers.dart';
import '../state/chat_state.dart'
    show
        AylaChatState,
        aylaApplyPinToProjection,
        aylaRemoveFromProjection,
        aylaSortPrivateByActivity,
        aylaToggleConversationPin,
        aylaHideConversation;
import '../state/notices_state.dart';
import '../state/paged_list.dart';
import '../state/shell_state.dart';
import '../state/social_store.dart'
    show
        AylaSocialController,
        AylaSocialKind,
        AylaSocialOptions,
        aylaSocialStore;
import '../theme/tokens.dart';
import '../widgets/base/directory_controls.dart' show AylaDirectoryLoadMore;
import '../widgets/base/media_interaction.dart' show AylaPullToRefresh;
import '../widgets/chat/conversation_list.dart';
import '../widgets/chat/elysia_entry.dart';
import '../widgets/chat/messages_layout.dart';
import '../widgets/chat/messages_tabs.dart';
import '../widgets/chat/request_rows.dart';
import '../widgets/motion/gestures.dart'
    show AylaConversationTransition, AylaPanelEdge, AylaPanelTransition;
import 'chat_support.dart';

class MessagesPage extends ConsumerStatefulWidget {
  const MessagesPage({super.key});

  /// 窄屏选项卡（tsx 210–242 逐字；宽屏侧栏用「好友」而非「好友列表」）。
  static const List<({String key, String label})> tabs =
      <({String key, String label})>[
    (key: 'chat', label: '私信'),
    (key: 'friends', label: '好友列表'),
    (key: 'requests', label: '认证消息'),
  ];

  @override
  ConsumerState<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends ConsumerState<MessagesPage> {
  String _tab = 'chat';
  String? _activeChatId;
  final ScrollController _privateScroll = ScrollController();

  /// 选项卡行的 **GlobalKey** —— 窄屏两档切换时保住 tabs 行的 Element/State。
  ///
  /// ## 为什么必须（用户 2026-10-09 实报「私信卡 ↔ 别的卡切换时高亮跳变」）
  /// web 三档 tab 的 DOM 结构**完全相同**（`MessagesPage.tsx:206–247`：`.messages-page`
  /// 的第一子项恒为 tabs 包装行、第二子项恒为面板，差别只在面板的类名
  /// `.messages-private` / `.messages-friends`）⇒ **切 tab 不重建 tabs 行**，
  /// `AuroraquaNavHighlight` 的 Framer `layoutId` 因此能连续迁移
  /// （`AuroraquaNavHighlight.tsx:17` + `auroraquaMotion.ts:26–29`：
  /// 300ms、`ease: [0, 0, 0.58, 1]`）。
  ///
  /// Flutter 侧两档的树位不同（私信档 = `Column` 直挂；好友/认证档 = 外层
  /// `SingleChildScrollView` 的子项 —— 这段差异本身是**对的**，对应 web 的
  /// `.messages-private { flex: 1; overflow-y: auto }`「tabs 固定」与
  /// `.messages-page { overflow-y: auto }`「整页滚、tabs 随滚」两种滚动行为）
  /// ⇒ 没有 GlobalKey 时 Flutter 判定为「换了父级」而**重建** tabs 行 ⇒
  /// `AylaNavHighlightList` 的 State 归零、`_capsuleRect == null` ⇒
  /// **切换首帧胶囊整个消失**，等 postFrame 测量完才瞬现于新位置 = 用户看到的「跳变」。
  ///
  /// GlobalKey 的 reparenting 语义（同一帧内旧 Element 进 inactive 表、新位置
  /// `_retakeInactiveElement` 取回复用）正是为此设计 ⇒ 两档间 Element 与
  /// State 原地复用，`AnimatedPositioned` 的迁移不中断。
  /// 回归锁：`test/messages_tabs_highlight_test.dart`。
  final GlobalKey _tabsRowKey = GlobalKey();

  /// 私信会话列表 —— **读共享 social store**（web `MessagesPage.tsx:50–51` 的
  /// `useSocialPage("conversations", { type: "private" })`）。
  ///
  /// ⚠️ **2026-10-20 热更新审计 A 的 D1 修复（头号根因）**：原实现用页面私有
  /// `AylaPagedList` 快照，且本页 `onFrame`（:140–144）只处理认证刷新帧、
  /// **完全不理会 `message.new`** ⇒ WS 帧到达后 `chatState`/`messageState` 都更新了
  /// （未读、预览、活跃度），但**列表渲染的是另一份数据** ⇒ 界面纹丝不动：
  /// 不显示新消息、不出预览、不涨未读、不重排。这正是用户实报「别人发的内容不出现」，
  /// 也是宽屏消息左列（`chat_support.dart`）的同一个病根。
  ///
  /// web 等价链路：`message.new` → `useChatStore.setLastMessage/bumpUnread` →
  /// `social.ts` 的会话投影双写 → `useSocialPage` 读的 record 变 → 重渲染。
  /// 换成 [AylaSocialController] 后本页与 web 同构（`AylaSocialTracking` 负责把
  /// chatState 变化回写进 social record，见 `state/chat_providers.dart:aylaStartSocialTracking`）。
  AylaSocialController<AylaConversationSummary>? _conversations;
  AylaPagedList<AylaUserPublic>? _friends;
  AylaPagedList<AylaFriendRequest>? _friendRequests;
  AylaPagedList<AylaGroupInvite>? _invites;
  AylaPagedList<AylaGroupJoinRequest>? _joinRequests;
  AylaPagedList<AylaGroupMemberLeaveNotice>? _leaveNotices;

  String? _removingFriendId;
  String? _busyRequestId;
  int _revealNonce = 0;
  void Function()? _frameOff;
  ShellUiNotifier? _shellNotifier;
  Future<void> Function()? _refreshCallback;

  @override
  void initState() {
    super.initState();
    // 私信会话（web tsx 50：`useSocialPage("conversations", { type: "private" })`，恒开）。
    // ⇒ 共享 social store 的私有 record（**不是**页面私有分页快照，见字段注释）。
    _conversations = _socialPager<AylaConversationSummary>(
      const AylaSocialOptions(type: 'private'),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 认证相关帧 → 认证列表重取（web tsx 97–110）。
      _frameOff = ref.read(chatWsProvider).onFrame((Map<String, dynamic> frame) {
        final Object? type = frame['type'];
        if (type is String && aylaIsAuthRefreshFrame(type)) _loadRequestsTab();
      });
      unawaited(ref.read(badgesProvider).fetch());
    });
    _registerRefresh();
  }

  @override
  void dispose() {
    _frameOff?.call();
    final ShellUiNotifier? notifier = _shellNotifier;
    final Future<void> Function()? callback = _refreshCallback;
    if (notifier != null && callback != null) {
      scheduleMicrotask(() => notifier.unregisterRefresh(callback));
    }
    // social controller 与 paged list 的释放方式不同：前者要同时摘监听，
    // 否则 store 会继续向已 dispose 的 controller 通知（`_disposed` 已守卫，但监听应显式摘）。
    _conversations?.removeListener(_onPagerChanged);
    _conversations?.dispose();
    _friends?.dispose();
    _friendRequests?.dispose();
    _invites?.dispose();
    _joinRequests?.dispose();
    _leaveNotices?.dispose();
    _privateScroll.dispose();
    super.dispose();
  }

  AylaPagedList<T> _pager<T>(
    Future<AylaDirectoryPage<T>> Function(String? cursor) request,
    String Function(T item) keyOf,
  ) {
    final AylaPagedList<T> pager = AylaPagedList<T>(
      request: request,
      keyOf: keyOf,
    );
    pager.addListener(_onPagerChanged);
    unawaited(pager.load());
    return pager;
  }

  /// 共享 social store 的分页控制器（web `useSocialPage`，`hooks/useSocialPage.ts:8–25`）。
  ///
  /// 与 [_pager] 的差别正是 D1 的修复点：数据归**全局 store**（`aylaSocialStore`），
  /// 页面只是它的**读投影**；WS 帧 → chatState/messageState → `AylaSocialTracking`
  /// 回写 social record → store `notifyListeners` → 本 controller 转发 → 页面重建。
  /// ⇒ 新消息、预览、未读、活跃度排序**全部自动热更新**（与 web 同一条链）。
  AylaSocialController<T> _socialPager<T>(AylaSocialOptions options) {
    final AylaSocialController<T> controller =
        AylaSocialController<T>(
      store: aylaSocialStore,
      kind: AylaSocialKind.conversations,
      options: options,
    )..addListener(_onPagerChanged);
    unawaited(controller.load());
    return controller;
  }

  void _onPagerChanged() {
    if (!mounted) return;
    // 会话摘要进 chat store（web `stores/social.ts:172` 的 reconcile）：私聊面板读的就是这份缓存。
    final AylaChatState chat = ref.read(chatStateProvider);
    for (final AylaConversationSummary c
        in _conversations?.items ?? const <AylaConversationSummary>[]) {
      chat.upsertConversation(c);
    }
    setState(() {});
  }

  /// 好友 tab 取数（web tsx 52：`useSocialPage("friends", {}, tab === "friends")`）。
  void _ensureFriendsTab() {
    _friends ??= _pager<AylaUserPublic>(
      (String? cursor) => AylaUsersApi.listFriendsPageOf(cursor: cursor),
      (AylaUserPublic u) => u.id,
    );
  }

  /// 认证 tab 四路取数（web tsx 54–61）。
  void _ensureRequestsTab() {
    _friendRequests ??= _pager<AylaFriendRequest>(
      (String? cursor) => AylaUsersApi.listFriendRequestsPage(cursor: cursor),
      (AylaFriendRequest r) => r.id,
    );
    _invites ??= _pager<AylaGroupInvite>(
      (String? cursor) => AylaChatApi.listMyInvitesPage(cursor: cursor),
      (AylaGroupInvite i) => i.id,
    );
    _joinRequests ??= _pager<AylaGroupJoinRequest>(
      (String? cursor) => AylaChatApi.listManagedJoinRequestsPage(cursor: cursor),
      (AylaGroupJoinRequest r) => r.id,
    );
    _leaveNotices ??= _pager<AylaGroupMemberLeaveNotice>(
      (String? cursor) => AylaChatApi.listLeaveNoticesPage(cursor: cursor),
      (AylaGroupMemberLeaveNotice n) => n.id,
    );
  }

  void _loadRequestsTab() {
    _ensureRequestsTab();
    unawaited(_friendRequests?.refresh());
    unawaited(_invites?.refresh());
    unawaited(_joinRequests?.refresh());
    unawaited(_leaveNotices?.refresh());
  }

  void _onTabChanged(String next) {
    setState(() => _tab = next);
    if (next == 'friends') _ensureFriendsTab();
    if (next == 'requests') _loadRequestsTab();
  }

  AylaSocialPage<T>? _pageOf<T>(AylaPagedList<T>? pager) {
    if (pager == null) return null;
    return AylaSocialPage<T>(
      items: pager.items,
      loading: pager.loading,
      error: pager.error,
      hasMore: pager.hasMore,
      loadMore: pager.loadMore,
      refresh: pager.refresh,
    );
  }

  /// 好友申请只看「发给我且 pending」（web tsx 342 的过滤；后端 `direction=received` 已同向过滤）。
  AylaSocialPage<AylaFriendRequest>? _friendRequestsPage() {
    final AylaPagedList<AylaFriendRequest>? pager = _friendRequests;
    if (pager == null) return null;
    final String? me = ref.read(authNotifierProvider).user?.id;
    return AylaSocialPage<AylaFriendRequest>(
      items: <AylaFriendRequest>[
        for (final AylaFriendRequest r in pager.items)
          if (me != null && r.toUser?.id == me && r.status == 'pending') r,
      ],
      loading: pager.loading,
      error: pager.error,
      hasMore: pager.hasMore,
      loadMore: pager.loadMore,
      refresh: pager.refresh,
    );
  }

  Future<void> _refreshConversations() async {
    await _conversations?.refresh();
    if (mounted) setState(() => _revealNonce++);
  }

  void _registerRefresh() {
    final ShellUiNotifier notifier = ref.read(shellUiProvider.notifier);
    Future<void> callback() => _refreshConversations();
    _shellNotifier = notifier;
    _refreshCallback = callback;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      notifier.registerRefresh(callback);
    });
  }

  // ---- 动作（web tsx 114–150）----

  Future<void> _removeFriend(AylaUserPublic user) async {
    if (_removingFriendId != null) return;
    setState(() => _removingFriendId = user.id);
    try {
      await AylaUsersApi.deleteFriend(user.id);
      _friends?.removeWhere((AylaUserPublic f) => f.id == user.id);
      unawaited(ref.read(badgesProvider).fetch());
    } catch (_) {
      // 解除好友失败静默（web 同）
    } finally {
      if (mounted) setState(() => _removingFriendId = null);
    }
  }

  Future<void> _act(
    String id,
    Future<void> Function() action,
    void Function() onDone,
  ) async {
    if (_busyRequestId != null) return;
    setState(() => _busyRequestId = id);
    try {
      await action();
      onDone();
      unawaited(ref.read(badgesProvider).fetch());
    } catch (_) {
      // 处理失败静默（web 同）；条目保留以便重试
    } finally {
      if (mounted) setState(() => _busyRequestId = null);
    }
  }

  Future<void> _openUserChat(String userId) async {
    if (userId.isEmpty) return;
    try {
      final String convId = await AylaUsersApi.openPrivateConversation(userId);
      if (!mounted || convId.isEmpty) return;
      if (AylaBreakpoints.isNarrow(MediaQuery.sizeOf(context).width)) {
        // 消息列表 → 私聊：**push**（返回回消息列表）。
        context.push('/chat/${Uri.encodeComponent(convId)}');
      } else {
        setState(() => _activeChatId = convId);
      }
    } catch (_) {
      // 打开私聊失败静默（web 同）
    }
  }

  void _goUserProfile(AylaUserPublic user) {
    // 消息列表 → 他人主页：**push**。
    context.push('/user/${Uri.encodeComponent(user.id)}');
  }

  /// 本页 ⋯ 菜单的请求在途标记（web 是 `ConversationMoreMenu` 的局部 `busy`）。
  ///
  /// web 的 busy 是**每个菜单实例自己的**状态（`tsx 43` `useState(false)`）；
  /// Flutter 的 [AylaConversationList.menuBusy] 是整列表一个档位
  /// （组件库既定契约，见 `conversation_list.dart:156–160`）⇒ 用页面级一个布尔表达，
  /// 效果是「在途期间所有行的菜单项都禁用」，比 web 略宽但不会误触。
  bool _menuBusy = false;

  /// 置顶 / 取消置顶（web `ConversationMoreMenu.tsx:91–103` 的 `handleTogglePin`）。
  ///
  /// 两步式与失败静默都收在 `state/chat_state.dart` 的 [aylaToggleConversationPin]；
  /// 本页额外要把结果写回**自己的分页投影**（页面私有 [AylaPagedList]，不挂
  /// `AylaSocialTracking` 的对账链 —— 详见该函数的注释）。
  Future<void> _togglePin(AylaConversationSummary conv, bool pinned) async {
    if (_menuBusy) return;
    setState(() => _menuBusy = true);
    try {
      final bool ok = await aylaToggleConversationPin(
        ref.read(chatStateProvider),
        conv.id,
        pinned,
      );
      if (!ok || !mounted) return;
      _conversations?.setItems(
        aylaApplyPinToProjection(
          _conversations?.items ?? const <AylaConversationSummary>[],
          conv.id,
          pinned,
        ),
      );
    } finally {
      if (mounted) setState(() => _menuBusy = false);
    }
  }

  /// 删除（隐藏）会话（web `ConversationMoreMenu.tsx:110–120` 的 `doDelete`）。
  ///
  /// 二次确认在 [AylaConversationMoreMenu] 内部完成（同 web `ConfirmDialog`）；
  /// 本方法只负责「请求成功 ⇒ 本地移除」，失败静默。
  Future<void> _deleteConversation(AylaConversationSummary conv) async {
    if (_menuBusy) return;
    setState(() => _menuBusy = true);
    try {
      final bool ok = await aylaHideConversation(
        ref.read(chatStateProvider),
        conv.id,
      );
      if (!ok || !mounted) return;
      _conversations?.setItems(
        aylaRemoveFromProjection(
          _conversations?.items ?? const <AylaConversationSummary>[],
          conv.id,
        ),
      );
    } finally {
      if (mounted) setState(() => _menuBusy = false);
    }
  }

  List<AylaConversationSummary> _sortedPrivate() =>
      aylaSortPrivateByActivity<AylaConversationSummary>(
        _conversations?.items ?? const <AylaConversationSummary>[],
        ref.watch(chatStateProvider).conversationActivityAt,
        idOf: (AylaConversationSummary c) => c.id,
        pinnedOf: (AylaConversationSummary c) => c.isPinned ?? false,
      );

  @override
  Widget build(BuildContext context) {
    final bool narrow = AylaBreakpoints.isNarrow(MediaQuery.sizeOf(context).width);
    final AylaElysiaProfile? profile =
        ref.watch(elysiaProfileProvider).valueOrNull;
    final AylaElysiaProfile? entryProfile =
        (profile != null && profile.enabled) ? profile : null;
    final String? elysiaUserId = profile?.userId;
    final int requestBadge = ref.watch(badgesProvider).requestBadge;

    // 宽屏：左列的五路取数与三路动作由 `AylaWideMessagesSidebarHost` 承担（web 是组件自己取数）；
    // 窄屏才有本页内联的好友/认证处理逻辑（`.messages-friends` 版式与侧栏不同，无法共用一件）。
    if (!narrow) {
      final String? activeId = _activeChatId;
      return AylaMessagesPage(
        wide: true,
        children: <Widget>[
          // 宽屏左列自己取数（web `WideMessagesSidebar` 同）⇒ 复用宿主，不在这里重复五路分页。
          AylaWideMessagesSidebarHost(
            activeId: activeId,
            onSelect: (String id) => setState(() => _activeChatId = id),
          ),
          AylaWideMessagesPane(
            child: AylaConversationTransition(
              identity: 'private:${activeId ?? 'empty'}',
              panels: activeId != null,
              // 空态档（panels:false）由宿主自己播；有会话档子件自持三区进出场
              // （web `MessagesPage.tsx:190–192` 的 `panels` + `PrivateChatPane panelMotion`）。
              childOwnsPanels: activeId != null,
              builder: (BuildContext context, String identity) => activeId == null
                  ? const AylaWideMessagesEmpty()
                  : AylaChatPaneHost(
                      conversationId: activeId,
                      narrow: false,
                      panelMotion: true,
                    ),
            ),
          ),
        ],
      );
    }

    // tsx 208 的 inline style：flex + space-between + `padding: 0 16px`。
    // ⚠️ `key: _tabsRowKey` 是**必需**的（见 [_tabsRowKey] 文档）：窄屏两档里本行的
    // 树位不同，没有它切 tab 时会被判定为「换父级」而重建 ⇒ 胶囊 State 归零 ⇒ 跳变。
    final Widget tabsRow = Padding(
      key: _tabsRowKey,
      padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: AylaMessagesTabs(
              items: <AylaMessagesTabItem>[
                for (final ({String key, String label}) t in MessagesPage.tabs)
                  AylaMessagesTabItem(
                    key: t.key,
                    label: t.label,
                    badge: t.key == 'requests' ? requestBadge : 0,
                  ),
              ],
              value: _tab,
              onChange: _onTabChanged,
            ),
          ),
        ],
      ),
    );

    final Widget panel = switch (_tab) {
      'friends' => _friendsTab(),
      'requests' => _requestsTab(),
      _ => _chatTab(entryProfile, elysiaUserId),
    };

    // 选项卡面板**进场**（web `MessagesPage.tsx:63` 的 `useTabPanelMotion` +
    // `hooks/useTabPanelMotion.ts:23–46`，selector = `:scope > .messages-private,
    // :scope > .messages-friends`）：新面板 `{opacity:0, x:+20} → {opacity:1, x:0}`，
    // 300ms `cubic-bezier(.42,0,.58,1)`（= `AylaCurves.auroraquaEaseInOut`，见 `AylaPanelTransition`）；
    // `prefers-reduced-motion` ⇒ 不播（同 hook 31 行）；**没有退出动画**
    // —— 旧面板由条件渲染直接卸载（web 无 AnimatePresence）。
    // key 取 `_tab`：切换时新面板重建 ⇒ 重播进场（面板本就随 tab 换组件，不额外引入重挂载）。
    final Widget body = AylaPanelTransition(
      key: ValueKey<String>(_tab),
      edge: AylaPanelEdge.right,
      show: true,
      child: panel,
    );

    // 私信 tab：选项卡固定 + 列表内部滚动（web `.messages-private` 自己 `overflow-y: auto`）；
    // 好友/认证 tab：web 由 `.messages-page` 整体滚动（选项卡随之滚走）⇒ 外层滚动视图。
    if (_tab == 'chat') {
      return AylaMessagesPage(
        children: <Widget>[tabsRow, Expanded(child: body)],
      );
    }
    return AylaMessagesPage(
      children: <Widget>[
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[tabsRow, body],
            ),
          ),
        ),
      ],
    );
  }

  bool _isPrivateAtTop() =>
      !_privateScroll.hasClients || _privateScroll.position.pixels <= 0;

  /// 私信 tab（tsx 246–270）。
  Widget _chatTab(AylaElysiaProfile? entryProfile, String? elysiaUserId) {
    final AylaSocialController<AylaConversationSummary>? pager = _conversations;
    return AylaPullToRefresh(
      isAtTop: _isPrivateAtTop,
      onRefresh: _refreshConversations,
      child: SingleChildScrollView(
        controller: _privateScroll,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (entryProfile != null)
              AylaElysiaEntry(
                profile: entryProfile,
                onEnter: () => _openUserChat(entryProfile.userId ?? ''),
              ),
            AylaConversationList(
              key: ValueKey<int>(_revealNonce),
              conversations: _sortedPrivate(),
              activeId: null,
              elysiaUserId: elysiaUserId,
              onSelect: (String id) => context.push('/chat/${Uri.encodeComponent(id)}'),
              revealItems: !(pager?.loading ?? false),
              onAvatarTap: _goUserProfile,
              // ⋯ 菜单两项 —— web `ConversationList.tsx:158`
              // `<ConversationMoreMenu conversation={conv} />`（默认 showDelete=true），
              // 组件内直连 `togglePinConversation` / `hideConversation`。
              // Flutter 侧组件库不碰网络 ⇒ 由本页注入（[AylaConversationList.onTogglePin] /
              // [AylaConversationList.onDelete] 的既定契约）。
              onTogglePin: _togglePin,
              onDelete: _deleteConversation,
              menuBusy: _menuBusy,
            ),
            if (pager != null)
              AylaDirectoryLoadMore(
                loading: pager.loading,
                error: pager.error,
                hasMore: pager.hasMore,
                invalidated: false,
                loadMore: pager.loadMore,
                refresh: pager.refresh,
                retainCompletedSpace: false,
              ),
          ],
        ),
      ),
    );
  }

  /// 好友 tab（tsx 271–314）。
  Widget _friendsTab() {
    final AylaPagedList<AylaUserPublic>? pager = _friends;
    final List<AylaUserPublic> items =
        pager?.items ?? const <AylaUserPublic>[];
    return Padding(
      // `.messages-friends { padding: 0 var(--sp-4) var(--sp-4) }`
      padding: const EdgeInsets.only(
        left: AylaSpacing.sp4,
        right: AylaSpacing.sp4,
        bottom: AylaSpacing.sp4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: AylaSpacing.sp3, // `.messages-friends { gap: sp3 }`
        children: <Widget>[
          AylaMessagesGroup(
            title: '我的好友（${pager?.total ?? 0}）',
            children: <Widget>[
              for (final AylaUserPublic f in items)
                AylaFriendRow(
                  user: f,
                  avatarSize: 40, // tsx 288：窄屏好友行头像 40（宽屏侧栏 36）
                  online: f.online,
                  onOpenChat: () => _openUserChat(f.id),
                  onAvatarTap: () => _goUserProfile(f),
                  onRemove: () => _removeFriend(f),
                  removing: _removingFriendId == f.id,
                ),
              if (items.isEmpty &&
                  !(pager?.loading ?? false) &&
                  pager?.error == null)
                const AylaMessagesEmpty('还没有好友，去搜索添加吧'),
            ],
          ),
          if (pager != null)
            AylaDirectoryLoadMore(
              loading: pager.loading,
              error: pager.error,
              hasMore: pager.hasMore,
              invalidated: false,
              loadMore: pager.loadMore,
              refresh: pager.refresh,
              retainCompletedSpace: false,
            ),
        ],
      ),
    );
  }

  /// 认证 tab（tsx 315–364）。
  Widget _requestsTab() {
    _ensureRequestsTab();
    return Padding(
      padding: const EdgeInsets.only(
        left: AylaSpacing.sp4,
        right: AylaSpacing.sp4,
        bottom: AylaSpacing.sp4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: AylaSpacing.sp4, // `.messages-requests { gap: sp4 }`
        children: <Widget>[
          // tsx 317–320：分组「认证消息」+ 提示（宽屏侧栏没有该标题、提示也无句号）。
          const AylaMessagesGroup(
            title: '认证消息',
            children: <Widget>[
              AylaMessagesSectionHint('好友申请、群邀请和入群申请都会集中显示在这里。'),
            ],
          ),
          _requestsPanel(narrow: true),
        ],
      ),
    );
  }

  Widget _requestsPanel({required bool narrow}) {
    final List<AylaRealtimeNotice> leaveNotices = ref
        .watch(noticesProvider)
        .ofKind(AylaRealtimeNoticeKind.groupMemberLeft);
    return AylaRequestsPanel(
      leaveNotices: _pageOf(_leaveNotices) ??
          const AylaSocialPage<AylaGroupMemberLeaveNotice>(),
      realtimeLeaveNotices: <AylaNoticeRow>[
        for (final AylaRealtimeNotice n in leaveNotices)
          AylaNoticeRow(
            title: n.title,
            detail: n.detail,
            onDismiss: () => ref.read(noticesProvider).dismiss(n.id),
          ),
      ],
      friendRequests: _friendRequestsPage() ??
          const AylaSocialPage<AylaFriendRequest>(),
      invites: _pageOf(_invites) ?? const AylaSocialPage<AylaGroupInvite>(),
      joinRequests: _pageOf(_joinRequests) ??
          const AylaSocialPage<AylaGroupJoinRequest>(),
      // 宽屏侧栏的提示（`WideMessagesSidebar.tsx:267`）；窄屏由页面自己渲染带句号的版本。
      sectionHint: narrow ? null : '好友申请、群邀请和入群申请',
      joinSectionTitle: narrow ? '入群申请（群主/管理员）' : '入群申请',
      sectionGap: narrow ? AylaSpacing.sp4 : AylaSpacing.sp3,
      busyId: _busyRequestId,
      isOnline: (AylaUserPublic u) => u.online,
      onDismissLeaveNotice: (String id) {
        unawaited(() async {
          try {
            await AylaChatApi.readLeaveNotice(id);
            _leaveNotices?.removeWhere(
              (AylaGroupMemberLeaveNotice n) => n.id == id,
            );
          } catch (_) {
            // 标记已读失败静默（条目保留，下次再点）
          }
        }());
      },
      onFriendAction: (AylaFriendRequest r, bool accept) => _act(
        r.id,
        () => AylaUsersApi.actionFriendRequest(r.id, accept),
        () => _friendRequests?.removeWhere(
          (AylaFriendRequest item) => item.id == r.id,
        ),
      ),
      onInviteAction: (AylaGroupInvite inv, bool accept) => _act(
        inv.id,
        () => AylaChatApi.actionGroupInvite(inv.id, accept),
        () => _invites?.removeWhere(
          (AylaGroupInvite item) => item.id == inv.id,
        ),
      ),
      onJoinAction: (AylaGroupJoinRequest r, bool accept) => _act(
        r.id,
        () => AylaChatApi.actionJoinRequest(r.id, accept),
        () => _joinRequests?.removeWhere(
          (AylaGroupJoinRequest item) => item.id == r.id,
        ),
      ),
    );
  }
}
