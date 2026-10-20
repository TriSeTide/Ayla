/// 快捷消息栏的**页面级接线** —— web `components/chat/QuickMessagesSheet.tsx`（363 行）
/// 的自取数等价物。
///
/// ## 为什么需要它
/// Flutter 的 [AylaQuickMessagesSheet] 是**展示型**（两个 tab 的内容与内联私聊面板全部由
/// 调用方注入，见 `widgets/chat/quick_messages_sheet.dart` 的「公开面」）；而 web 的
/// `QuickMessagesSheet` **自己取数**（`useSocialPage` 五路 + WS 帧刷新 + badges +
/// 爱莉档案）。本文件承担那部分并把结果灌进展示件 —— 与
/// `pages/chat_support.dart` 的 [AylaWideMessagesSidebarHost] 同一形制（网络层不进
/// `lib/widgets`）。
///
/// ## 逐条对应（web `QuickMessagesSheet.tsx`）
/// | 本件 | web tsx |
/// |---|---|
/// | 私信会话分页（`type=private`，limit 30） | 42（`useSocialPage("conversations", {type:"private"})`） |
/// | 认证四路分页（好友申请/群邀请/入群申请/退群通知） | 44–51 |
/// | 爱莉入口（`elysiaProfileProvider`，`enabled` 才展示） | 62 + 74–80（失败/未启用静默降级） |
/// | 私信 tab：爱莉入口 + 会话列表 + 页脚 | 219–231 |
/// | 认证 tab：`AylaRequestsPanel` 四分组 + 空态 | 233–323 |
/// | 认证相关 WS 帧 → 认证四路重取 | 92–105（`friend.request.*` / `group.invite.new` / `group.request.*`） |
/// | 认证徽标 = `requestBadge()` | 108–109 |
/// | 点会话 → 栏内**内联**打开私聊（不跳路由） | 208–217 + 54 + 114–119 |
/// | 头像一律不可点（`disableAvatarNav`） | 227（`ConversationList ... disableAvatarNav`） |
///
/// ## 与 web 的机制差异（登记）
/// 1. **没有 `onEnter` 内联爱莉会话**：web 的 `ElysiaEntry onEnter` 调
///    `openPrivateConversation` 后 `setActiveChatId`（tsx 114–119 / 221），本件同法
///    （[AylaQuickMessagesHost] 的 `_openUserChat`）；
/// 2. **私信面板不做 `PullToRefresh`**：web 的快捷栏私信 tab 只有 `DirectoryLoadMore`
///    （tsx 230），下拉刷新在 `.quick-messages-private { overflow-y: auto }` 里没有挂件；
/// 3. **朋友申请过滤**只看「发给我且 pending」（tsx 160–163），与 `/messages` 同口径；
/// 4. 快捷栏内**不注册 RefreshFAB 回调**（web 也没有；refreshCallback 属页面）；
/// 5. **内联私聊头部头像仍可点**（跳 `/user/:id`）—— web 的 `PrivateChatPane` 收
///    `disableAvatarNav`（tsx 215），但 Flutter 侧的装配件 [AylaChatPaneHost]
///    （`pages/chat_support.dart`，不属本任务写域）**未暴露该参数** ⇒ 这里没有关掉它。
///    头部返回键（`onBack`）与栏内列表头像（[AylaConversationList.disableAvatarNav]）
///    都已按 web 关掉，只有**内联私聊头**这一处待裁决。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api/chat_api.dart';
import '../core/api/directory_page.dart' show AylaDirectoryPage;
import '../core/api/users_api.dart';
import '../core/models/conversation.dart' show AylaConversationSummary;
import '../core/models/elysia_profile.dart' show AylaElysiaProfile;
import '../core/models/social_requests.dart';
import '../core/models/user_public.dart' show AylaUserPublic;
import '../state/auth_state.dart' show authNotifierProvider;
import '../state/chat_providers.dart'
    show
        badgesProvider,
        chatStateProvider,
        chatWsProvider,
        elysiaProfileProvider,
        noticesProvider;
import '../state/chat_state.dart' show AylaChatState, aylaSortPrivateByActivity;
import '../state/notices_state.dart'
    show AylaRealtimeNotice, AylaRealtimeNoticeKind;
import '../state/paged_list.dart';
import '../state/social_store.dart'
    show
        AylaSocialController,
        AylaSocialKind,
        AylaSocialOptions,
        aylaSocialStore;
import '../widgets/base/directory_controls.dart' show AylaDirectoryLoadMore;
import '../widgets/chat/conversation_list.dart' show AylaConversationList;
import '../widgets/chat/elysia_entry.dart' show AylaElysiaEntry;
import '../widgets/chat/quick_messages_sheet.dart' show AylaQuickMessagesSheet;
import '../widgets/chat/request_rows.dart' show AylaNoticeRow, AylaRequestsPanel;
import 'chat_support.dart' show AylaChatPaneHost, aylaIsAuthRefreshFrame;

/// 红点快捷消息栏宿主（web `QuickMessagesSheet.tsx` 的取数与装配）。
///
/// 自身不产出视觉外壳 —— 外观全部来自 [AylaQuickMessagesSheet]；本件只把
/// 「数据 + 动作 + 内联面板」灌进去。开合由壳层（`layout/app_shell.dart`）持有。
class AylaQuickMessagesHost extends ConsumerStatefulWidget {
  const AylaQuickMessagesHost({super.key, required this.onClose});

  /// 关闭（遮罩 / 关闭键 / ESC 三条路径都走它 —— web tsx 65–71 / 175 / 203）。
  final VoidCallback onClose;

  @override
  ConsumerState<AylaQuickMessagesHost> createState() =>
      _AylaQuickMessagesHostState();
}

class _AylaQuickMessagesHostState extends ConsumerState<AylaQuickMessagesHost> {
  /// 私信会话列表 —— **读共享 social store**（web `QuickMessagesSheet` 的
  /// `useSocialPage("conversations", { type: "private" })`）。
  ///
  /// ⚠️ **2026-10-20 全量普查修复（R2'）**：与 `messages_page` / `chat_support` 同病根 ——
  /// 原实现用页面私有 `AylaPagedList` 快照 ⇒ 面板打开期间收到的新私信**不会出现**
  /// （不显示新消息、不出预览、不涨未读）。这是 D1 漏修的第三个点。
  AylaSocialController<AylaConversationSummary>? _conversations;
  AylaPagedList<AylaFriendRequest>? _friendRequests;
  AylaPagedList<AylaGroupInvite>? _invites;
  AylaPagedList<AylaGroupJoinRequest>? _joinRequests;
  AylaPagedList<AylaGroupMemberLeaveNotice>? _leaveNotices;
  String? _busyId;
  void Function()? _frameOff;

  /// 私信 tab 内联打开的会话 id（null = 列表态；web tsx 54 的 `activeChatId`）。
  String? _activeChatId;

  @override
  void initState() {
    super.initState();
    // 私信会话（web tsx 42：`useSocialPage("conversations", { type: "private" })`，恒开）。
    // ⇒ 共享 social store 的私有 record（web `useSocialPage`，见字段注释）。
    _conversations = _socialPager<AylaConversationSummary>(
      const AylaSocialOptions(type: 'private'),
    );
    // 认证四路**懒加载**：web tsx 44–51 的 `useSocialPage(kind, {}, tab === "requests")`
    // 只在认证 tab 打开时取数（切 tab 触发 `_ensureRequests`）；徽标来自 badgesProvider，不依赖它们。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 认证相关帧 → 认证四路重取（web tsx 92–105：只在该 tab 打开时才刷）。
      _frameOff = ref.read(chatWsProvider).onFrame((Map<String, dynamic> frame) {
        final Object? type = frame['type'];
        if (type is String && aylaIsAuthRefreshFrame(type)) _refreshRequests();
      });
    });
  }

  @override
  void dispose() {
    _frameOff?.call();
    _conversations?.removeListener(_onPagerChanged);
    _conversations?.dispose();
    _friendRequests?.dispose();
    _invites?.dispose();
    _joinRequests?.dispose();
    _leaveNotices?.dispose();
    super.dispose();
  }

  /// 共享 social store 的分页控制器（web `useSocialPage`）。
  ///
  /// 与 [_pager] 的差别正是 R2' 的修复点：数据归**全局 store**，本面板只是读投影
  /// ⇒ `message.new` → chatState → `AylaSocialTracking` 回写 → store 通知 → 重建。
  AylaSocialController<T> _socialPager<T>(AylaSocialOptions options) {
    final AylaSocialController<T> controller = AylaSocialController<T>(
      store: aylaSocialStore,
      kind: AylaSocialKind.conversations,
      options: options,
    )..addListener(_onPagerChanged);
    unawaited(controller.load());
    return controller;
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

  void _onPagerChanged() {
    if (!mounted) return;
    // 会话摘要进 chat store（同 `MessagesPage`：私聊面板读的就是这份缓存）。
    final AylaChatState chat = ref.read(chatStateProvider);
    for (final AylaConversationSummary c
        in _conversations?.items ?? const <AylaConversationSummary>[]) {
      chat.upsertConversation(c);
    }
    setState(() {});
  }

  /// 认证四路取数（web tsx 44–51，tab === "requests" 时启用）。
  void _ensureRequests() {
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

  /// 四路重取（web tsx 87–89 的 `loadRequests`）。
  void _refreshRequests() {
    if (_friendRequests == null) return; // 从未打开认证 tab ⇒ 不凭空发请求（web 的 enabled 同义）
    unawaited(_friendRequests?.refresh());
    unawaited(_invites?.refresh());
    unawaited(_joinRequests?.refresh());
    unawaited(_leaveNotices?.refresh());
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

  /// 好友申请只看「发给我且 pending」（web tsx 160–163）。
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

  List<AylaConversationSummary> _sortedPrivate() =>
      aylaSortPrivateByActivity<AylaConversationSummary>(
        _conversations?.items ?? const <AylaConversationSummary>[],
        ref.watch(chatStateProvider).conversationActivityAt,
        idOf: (AylaConversationSummary c) => c.id,
        pinnedOf: (AylaConversationSummary c) => c.isPinned ?? false,
      );

  /// 打开与某用户（爱莉/会话）的私聊，**栏内联**（不跳路由；web tsx 114–119 的 `openUserChat`）。
  Future<void> _openUserChat(String userId) async {
    if (userId.isEmpty) return;
    try {
      final String convId = await AylaUsersApi.openPrivateConversation(userId);
      if (!mounted || convId.isEmpty) return;
      setState(() => _activeChatId = convId);
    } catch (_) {
      // 打开私聊失败静默（web tsx 118 的 `.catch(() => {})`）
    }
  }

  Future<void> _act(
    String id,
    Future<void> Function() action,
    void Function() onDone,
  ) async {
    if (_busyId != null) return;
    setState(() => _busyId = id);
    try {
      await action();
      onDone();
      unawaited(ref.read(badgesProvider).fetch()); // web tsx 111 的 refreshBadges
    } catch (_) {
      // 处理失败静默（web tsx 128 / 138 / 148 的 `.catch(() => {})`）；条目保留以便重试
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AylaElysiaProfile? profile =
        ref.watch(elysiaProfileProvider).valueOrNull;
    // web tsx 74–80：`getElysiaProfile().then(p => setElysiaProfile(p.enabled ? p : null))`
    final AylaElysiaProfile? entryProfile =
        (profile != null && profile.enabled) ? profile : null;
    final int requestBadge = ref.watch(badgesProvider).requestBadge;
    final List<AylaRealtimeNotice> leaveNotices = ref
        .watch(noticesProvider)
        .ofKind(AylaRealtimeNoticeKind.groupMemberLeft);

    return AylaQuickMessagesSheet(
      onClose: widget.onClose,
      activeChatId: _activeChatId,
      // web tsx 213：`onBack={() => setActiveChatId(null)}` + 214 的文案。
      onBackToList: () => setState(() => _activeChatId = null),
      backLabel: '返回私信列表',
      requestBadge: requestBadge,
      onTabChanged: (String tab) {
        // web tsx 44–51 的 `tab === "requests"` 才启用四路取数。
        if (tab == 'requests') _ensureRequests();
      },
      privatePanel: _privatePanel(entryProfile),
      requestsPanel: _requestsPanel(leaveNotices),
      privateChatPane: _privateChatPane(),
    );
  }

  /// 私信 tab（web tsx 219–231）：爱莉入口 + 会话列表 + 页脚。
  ///
  /// 快捷栏是**单页**（无 `/chat/:id` 路由），点会话/爱莉**内联**打开；
  /// 头像一律不可点（tsx 227 的 `disableAvatarNav`）。
  Widget _privatePanel(AylaElysiaProfile? entryProfile) {
    final AylaSocialController<AylaConversationSummary>? pager = _conversations;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (entryProfile != null)
          AylaElysiaEntry(
            profile: entryProfile,
            // web tsx 221：`onEnter={() => openUserChat(elysiaProfile.user.id)}`
            onEnter: () => unawaited(_openUserChat(entryProfile.userId ?? '')),
          ),
        AylaConversationList(
          conversations: _sortedPrivate(),
          activeId: null, // web tsx 224：`activeId={null}`（进入会话由内联面板表达）
          elysiaUserId: entryProfile?.userId,
          disableAvatarNav: true, // tsx 227
          onSelect: (String id) => setState(() => _activeChatId = id),
        ),
        if (pager != null)
          AylaDirectoryLoadMore(
            loading: pager.loading,
            error: pager.error,
            hasMore: pager.hasMore,
            invalidated: false,
            loadMore: pager.loadMore,
            refresh: pager.refresh,
            // web tsx 230：`retainCompletedSpace={false}`
            retainCompletedSpace: false,
          ),
      ],
    );
  }

  /// 认证 tab（web tsx 233–323）：`AylaRequestsPanel` 四分组 + 空态。
  Widget _requestsPanel(List<AylaRealtimeNotice> leaveNotices) {
    _ensureRequests();
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
      // 快捷栏没有顶部提示（web tsx 233 只有四分组 + 空态）⇒ 不传 sectionHint。
      busyId: _busyId,
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
        () => _friendRequests?.removeWhere((AylaFriendRequest item) => item.id == r.id),
      ),
      onInviteAction: (AylaGroupInvite inv, bool accept) => _act(
        inv.id,
        () => AylaChatApi.actionGroupInvite(inv.id, accept),
        () => _invites?.removeWhere((AylaGroupInvite item) => item.id == inv.id),
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

  /// 内联私聊面板（web tsx 208–217）：`PrivateChatPane` + `onBack` + `backLabel`。
  ///
  /// 复用 [AylaChatPaneHost]（私聊页/宽屏右列/快捷栏**三处共用**的装配层）——
  /// 只关掉头像导航（web 的 `disableAvatarNav`）。
  Widget _privateChatPane() {
    final String? id = _activeChatId;
    if (id == null) return const SizedBox.shrink();
    return AylaChatPaneHost(
      // web tsx 211：`key={activeChatId}` 使切会话时整件重挂（换运行时）
      key: ValueKey<String>('quick-messages-chat:$id'),
      conversationId: id,
      narrow: true,
      onBack: () => setState(() => _activeChatId = null),
    );
  }
}
