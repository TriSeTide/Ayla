/// 宽屏消息左列（`components/chat/WideMessagesSidebar.tsx` 的 Flutter 等价）。
///
/// ## 事实源
///
/// | 本件 | web |
/// |---|---|
/// | 容器 | messages.css 243–256（`.wide-messages-sidebar`：**332 宽** / column / `--glass-bg` + `--glass-filter` / `min-height: 0` / `--glass-shadow` / 1px 边 / radius-card 16 / 入场 `auroraqua-sidebar-in` **500ms**）⇒ 复用 `AylaSidebarCard`（`scrollable: false`：web 未声明 overflow，滚动归各 tab 内容区） |
/// | 选项卡 | tsx 183–211（三档 私信/好友/认证消息 + 认证徽标）⇒ 复用 `AylaMessagesTabs` |
/// | 私信 tab | tsx 213–230（爱莉入口 + `ConversationList` + `DirectoryLoadMore`）；内容区 messages.css 267–272（`flex: 1` / `min-height: 0` / `overflow-y: auto` / **padding `sp2 sp2 sp4`**） |
/// | 好友 tab | tsx 231–264（`friend-row` 列表 + 「暂无好友」空态 + 分页）；内容区 messages.css 274–279（同 padding） |
/// | 认证 tab | tsx 265–331（四分组，`messages-requests` 额外 `gap: sp4`：messages.css 60–62）⇒ 复用 `AylaRequestsPanel` |
/// | 面板动效 | tsx 173–181（`panelVariants(reduced, "left")`）⇒ 由 `AylaSidebarCard` 的入场承担 |
///
/// ## 注入边界
/// web 在本件内直连 store / `useSocialPage` / WS（`chatWS.onFrame` 刷新认证数据）；
/// Flutter 侧这些属页面层：本件只接收**已排序**的会话、好友、分页投影与回调，
/// 认证 tab 内容由调用方构造 `AylaRequestsPanel` 传入（`requestsPanel`）。
///
/// ## 公开面
/// `AylaWideMessagesSidebar` · 样张 `aylaWideMessagesSidebarSamples()`

library;

import 'package:flutter/material.dart';

import '../../core/models/conversation.dart';
import '../../core/models/social_requests.dart';
import '../../core/models/user_public.dart';
import '../../theme/sample_media.dart';
import '../../theme/tokens.dart';
import 'conversation_list.dart';
import '../base/directory_controls.dart' show AylaDirectoryLoadMore;
import '../motion/gestures.dart' show AylaPanelEdge, AylaPanelTransition;
import 'messages_tabs.dart';
import 'request_rows.dart';
import '../base/sidebar_card.dart';

/// 宽屏消息左列（`/messages` 两列左栏、`/chat/:id` 两列同构）。
class AylaWideMessagesSidebar extends StatefulWidget {
  const AylaWideMessagesSidebar({
    super.key,
    required this.activeId,
    required this.onSelect,
    this.conversations = const <AylaConversationSummary>[],
    this.conversationsPage,
    this.elysiaEntry,
    this.elysiaUserId,
    this.friendList = const <AylaUserPublic>[],
    this.friendsPage,
    this.friendsLoading = false,
    this.onOpenUserChat,
    this.onAvatarTap,
    this.onRemoveFriend,
    this.removingFriendId,
    this.requestsPanel,
    this.requestBadge = 0,
    this.initialTab = 'chat',
    this.onTabChanged,
    this.isOnline,
    this.statusLabel,
    this.onTogglePin,
    this.onDelete,
    this.menuBusy = false,
    this.disableAvatarNav = false,
  });

  /// 当前选中的私聊会话 id（高亮）。
  final String? activeId;

  /// 点击会话 → 选中。
  final void Function(String id) onSelect;

  /// 私信会话（**调用方按最近活跃排序**：web `sortPrivateByActivity` 在 store 层）。
  final List<AylaConversationSummary> conversations;

  /// 私信分页投影（`DirectoryLoadMore`）。
  final AylaSocialPage<AylaConversationSummary>? conversationsPage;

  /// 爱莉入口（私信 tab 顶部；调用方构造 `AylaElysiaEntry`）。
  final Widget? elysiaEntry;

  /// 爱莉 user id（会话列表头像形态用）。
  final String? elysiaUserId;

  /// 好友列表（好友 tab）。
  final List<AylaUserPublic> friendList;

  final AylaSocialPage<AylaUserPublic>? friendsPage;
  final bool friendsLoading;

  /// 点击好友 / 爱莉 → 打开私聊（web `openPrivateConversation`）。
  final void Function(String userId)? onOpenUserChat;

  /// 头像点击 → 个人主页。
  final void Function(AylaUserPublic user)? onAvatarTap;

  /// 解除好友（web `deleteFriend`）。
  final void Function(AylaUserPublic user)? onRemoveFriend;

  /// 正在解除的好友 id（禁用其按钮 + 文案「解除中…」）。
  final String? removingFriendId;

  /// 认证 tab 内容（调用方构造 `AylaRequestsPanel`）。
  final Widget? requestsPanel;

  /// 认证徽标计数（web `requestBadge()`）。
  final int requestBadge;

  final String initialTab;
  final void Function(String tab)? onTabChanged;

  /// presence 注入（会话列表/好友行共用）。
  final bool Function(AylaUserPublic? peer)? isOnline;
  final String Function(AylaUserPublic? peer, bool online)? statusLabel;

  final void Function(AylaConversationSummary conv, bool pinned)? onTogglePin;
  final void Function(AylaConversationSummary conv)? onDelete;
  final bool menuBusy;

  /// 快捷消息栏内：头像不可点。
  final bool disableAvatarNav;

  /// 侧栏宽（messages.css 245：`width: 332px`）。
  static const double sidebarWidth = 332;

  @override
  State<AylaWideMessagesSidebar> createState() =>
      _AylaWideMessagesSidebarState();
}

class _AylaWideMessagesSidebarState extends State<AylaWideMessagesSidebar> {
  late String _tab = widget.initialTab;

  @override
  Widget build(BuildContext context) {
    final List<AylaMessagesTabItem> tabs = <AylaMessagesTabItem>[
      const AylaMessagesTabItem(key: 'chat', label: '私信'),
      const AylaMessagesTabItem(key: 'friends', label: '好友'),
      AylaMessagesTabItem(
        key: 'requests',
        label: '认证消息',
        badge: widget.requestBadge,
      ),
    ];

    return AylaSidebarCard(
      width: AylaWideMessagesSidebar.sidebarWidth,
      // `margin: var(--sidebar-gutter)` = **12**（`messages.css:255` 在 `.wide-messages-sidebar`
      // 自己的规则块里；`--sidebar-gutter: 12px` = `tokens.css:132`）。
      // ⚠️ 该 12px 此前只登记未表达（19 号 §7.5 的待裁决偏离）；2026-09-29 用户裁决
      // 「按 web 语义收口」⇒ 由本调用方显式传入（AylaSidebarCard.gutter 默认 0，
      // 以免影响目录页复用点 `.directory-filters` 的 `margin: 0 0 sp3`）。
      gutter: const EdgeInsets.all(AylaSpacing.sidebarGutter),
      shadow: AylaShadows.glass, // --glass-shadow
      enterDuration: AylaDurations.enter, // auroraqua-sidebar-in 500ms
      // web 未声明 overflow ⇒ 不自滚动（滚动归各 tab 内容区，tabs 固定）
      scrollable: false,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.max,
        children: <Widget>[
          AylaMessagesTabs(
            items: tabs,
            value: _tab,
            onChange: (String v) {
              setState(() => _tab = v);
              widget.onTabChanged?.call(v);
            },
          ),
          Expanded(child: _tabBody()),
        ],
      ),
    );
  }

  Widget _tabBody() {
    final Widget panel = switch (_tab) {
      'friends' => _friendsTab(),
      'requests' => _requestsTab(),
      _ => _chatTab(),
    };
    // 选项卡面板**进场**（web `WideMessagesSidebar.tsx:77` 的 `useTabPanelMotion`，
    // selector = `:scope > .messages-private, :scope > .messages-friends`）：
    // 新面板自右 +20 淡入 300ms `cubic-bezier(.42,0,.58,1)`；reduced ⇒ 不播；无退出动画。
    return AylaPanelTransition(
      key: ValueKey<String>(_tab),
      edge: AylaPanelEdge.right,
      show: true,
      child: panel,
    );
  }

  /// 私信 tab（tsx 213–230）。
  Widget _chatTab() {
    return _ScrollingTabBody(
      // `.wide-messages-sidebar .messages-private { padding: sp2 sp2 sp4 }`
      padding: const EdgeInsets.fromLTRB(
        AylaSpacing.sp2,
        AylaSpacing.sp2,
        AylaSpacing.sp2,
        AylaSpacing.sp4,
      ),
      children: <Widget>[
        if (widget.elysiaEntry != null) ...<Widget>[
          widget.elysiaEntry!,
          const SizedBox(height: AylaSpacing.sp2),
        ],
        AylaConversationList(
          conversations: widget.conversations,
          activeId: widget.activeId,
          onSelect: widget.onSelect,
          elysiaUserId: widget.elysiaUserId,
          revealItems: true,
          isOnline: widget.isOnline,
          statusLabel: widget.statusLabel,
          onAvatarTap: widget.disableAvatarNav ? null : widget.onAvatarTap,
          onTogglePin: widget.onTogglePin,
          onDelete: widget.onDelete,
          menuBusy: widget.menuBusy,
          disableAvatarNav: widget.disableAvatarNav,
        ),
        if (widget.conversationsPage != null)
          AylaDirectoryLoadMore(
            loading: widget.conversationsPage!.loading,
            error: widget.conversationsPage!.error,
            hasMore: widget.conversationsPage!.hasMore,
            invalidated: false,
            loadMore: widget.conversationsPage!.loadMore ?? () async {},
            refresh: widget.conversationsPage!.refresh ?? () async {},
            retainCompletedSpace: false,
          ),
      ],
    );
  }

  /// 好友 tab（tsx 231–264）。
  Widget _friendsTab() {
    final List<AylaUserPublic> friends = widget.friendList;
    return _ScrollingTabBody(
      padding: const EdgeInsets.fromLTRB(
        AylaSpacing.sp2,
        AylaSpacing.sp2,
        AylaSpacing.sp2,
        AylaSpacing.sp4,
      ),
      children: <Widget>[
        if (friends.isEmpty && !widget.friendsLoading)
          // `.messages-empty { padding: var(--sp-4) }`
          const Padding(
            padding: EdgeInsets.all(AylaSpacing.sp4),
            child: Text(
              '暂无好友',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: AylaFonts.body,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 13,
                color: AylaColors.textSecondary,
              ),
            ),
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: AylaSpacing.sp2,
            children: <Widget>[
              for (final AylaUserPublic f in friends)
                AylaFriendRow(
                  user: f,
                  online: widget.isOnline?.call(f) ?? f.online,
                  removing: widget.removingFriendId == f.id,
                  onOpenChat: widget.onOpenUserChat == null
                      ? () {}
                      : () => widget.onOpenUserChat!(f.id),
                  onAvatarTap: widget.disableAvatarNav || widget.onAvatarTap == null
                      ? null
                      : () => widget.onAvatarTap!(f),
                  onRemove: widget.onRemoveFriend == null
                      ? null
                      : () => widget.onRemoveFriend!(f),
                ),
            ],
          ),
        if (widget.friendsPage != null)
          AylaDirectoryLoadMore(
            loading: widget.friendsPage!.loading,
            error: widget.friendsPage!.error,
            hasMore: widget.friendsPage!.hasMore,
            invalidated: false,
            loadMore: widget.friendsPage!.loadMore ?? () async {},
            refresh: widget.friendsPage!.refresh ?? () async {},
            retainCompletedSpace: false,
          ),
      ],
    );
  }

  /// 认证 tab（tsx 265–331；`messages-requests` 额外 `gap: sp4`）。
  Widget _requestsTab() {
    return _ScrollingTabBody(
      padding: const EdgeInsets.fromLTRB(
        AylaSpacing.sp2,
        AylaSpacing.sp2,
        AylaSpacing.sp2,
        AylaSpacing.sp4,
      ),
      gap: AylaSpacing.sp4,
      children: <Widget>[
        widget.requestsPanel ?? const AylaRequestsPanel(),
      ],
    );
  }
}

/// tab 内容区（`.messages-private` / `.messages-friends`：`flex: 1` + `min-height: 0`
/// + `overflow-y: auto` + 指定 padding）。
class _ScrollingTabBody extends StatelessWidget {
  const _ScrollingTabBody({
    required this.padding,
    required this.children,
    this.gap = AylaSpacing.sp3,
  });

  final EdgeInsetsGeometry padding;
  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: gap, // `.messages-friends { gap: sp3 }`（认证 tab 用 sp4）
        children: children,
      ),
    );
  }
}

// ======================= 样张 =======================

AylaConversationSummary _conv(String id, String name, {bool online = false}) =>
    AylaConversationSummary(
      id: id,
      type: AylaConversationType.private,
      title: '',
      avatar: '',
      unreadCount: id == 'c2' ? 2 : 0,
      peer: AylaUserPublic(
        id: 'u-$id',
        nickname: name,
        username: 'user_$id',
        online: online,
      ),
    );

/// 宽屏消息左列样张：
/// 私信 tab（会话列表 + 分页）/ 好友 tab / 认证 tab（徽标）。
Widget aylaWideMessagesSidebarSamples() {
  aylaEnableSampleMedia();
  final List<AylaConversationSummary> convs = <AylaConversationSummary>[
    _conv('c1', '小樱', online: true),
    _conv('c2', '阿澈'),
    _conv('c3', '林深', online: true),
  ];
  final List<AylaUserPublic> friends = <AylaUserPublic>[
    const AylaUserPublic(id: 'u1', nickname: '小樱', username: 'sakura', online: true),
    const AylaUserPublic(id: 'u2', nickname: '阿澈', username: 'ache'),
  ];

  Widget stage(String label, String tab, {double height = 560}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: AylaSpacing.sp2),
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: AylaFonts.body,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AylaColors.textSecondary,
              ),
            ),
          ),
          Align(
            alignment: Alignment.topLeft,
            widthFactor: 1,
            child: SizedBox(
              height: height,
              child: AylaWideMessagesSidebar(
                activeId: 'c2',
                initialTab: tab,
                onSelect: (_) {},
                conversations: convs,
                onOpenUserChat: (_) {},
                onAvatarTap: (_) {},
                friendList: friends,
                onRemoveFriend: (_) {},
                removingFriendId: 'u2',
                requestBadge: 3,
                requestsPanel: AylaRequestsPanel(
                  sectionHint: '好友申请、群邀请和入群申请',
                  onFriendAction: (_, __) {},
                  friendRequests: AylaSocialPage<AylaFriendRequest>(
                    items: <AylaFriendRequest>[
                      AylaFriendRequest(
                        id: 'f1',
                        fromUser: const AylaUserPublic(
                          id: 'u3',
                          nickname: '小铃',
                          username: 'suzu',
                          online: true,
                        ),
                        message: '加个好友吧',
                        status: 'pending',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: AylaSpacing.sp6),
        ],
      );

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      stage('私信 tab（332 侧栏卡 + 会话列表；选中项高亮 + 未读徽标）', 'chat'),
      stage('好友 tab（好友行 + 「解除中…」档）', 'friends', height: 420),
      stage('认证 tab（徽标 3 + 认证面板；gap sp4）', 'requests', height: 420),
    ],
  );
}
