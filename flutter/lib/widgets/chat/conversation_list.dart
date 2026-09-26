/// 会话列表（`components/chat/ConversationList.tsx` 的 Flutter 等价）。
///
/// ## 事实源
///
/// | 本文件 | web |
/// |---|---|
/// | [aylaDisplayStatusOf] | `utils/displayStatus.ts:17–32` `displayStatusOf` |
/// | [aylaConversationPreviewLabel] | `ConversationList.tsx:26–52`（`TYPE_PLACEHOLDER` + `previewLabel`） |
/// | [AylaConversationList] | tsx 54–164 |
/// | 行布局 / 悬停 / 置顶 | app.css 490–543（`.conv-li` / `.conv-item` / `.is-pinned*`） |
/// | 标题行 / 状态胶囊 / 预览行 / @我 | app.css 545–617 |
/// | 未读徽标 | app.css 693–706（`.conv-unread`）→ [AylaTabBadgeMetrics.convUnread] |
/// | 空态 | app.css 707–713（`.conv-empty`） |
/// | 选中高亮 / 切换动画 | **复用** [AylaNavHighlightList]（与 `AylaDirectoryFilters` 同一份实现）——事实源 auroraqua.css 142–197 + `DirectoryFilters.tsx:66–82` |
/// | 侧栏卡片容器 | **复用** [AylaSidebarCard]（`.wide-messages-sidebar`：332 / `--glass-shadow` / 入场 500ms；`.chat-sidebar`：300 同款） |
/// | 入场 | tsx 96–102（`staggerDelay` + `.reveal-item`）→ `AylaRevealItem` |
///
/// ## 为什么复用而不自建（点名）
/// > 「会话列表背景卡片、选中高亮、切换动画等应直接复用 DirectoryFilters 宽屏侧栏」
///
/// 会话列表与目录筛选侧栏在 web 里是**同一套 auroraqua 高亮语言**
/// （都带 `has-auroraqua-highlight` + 容器级 `auroraqua-nav-highlight`）⇒ Flutter 侧
/// 由 [AylaNavHighlightList] 提供高亮/迁移/按压/扫光/键盘/滚动揭示，
/// 由 [AylaSidebarCard] 提供卡片材质/自滚动/入场；本文件只负责**行内容与行底色**。
///
/// ## 层叠要点（照实，勿按 app.css 字面改）
/// 1. `.conv-item { border-radius: 16px }` 被 auroraqua.css 172
///    `.has-auroraqua-highlight { border-radius: var(--radius-input) }` **覆写为 12px**
///    （同特异性、后加载）——tsx 恒给行加 `has-auroraqua-highlight` ⇒ 实际圆角 **12**；
/// 2. 选中行**自身底色被取消**（auroraqua 194–197 `background: transparent`，
///    特异性 0,3,0 高于 `.conv-item:hover` 的 0,2,0）⇒ 选中行 hover 也透明，底由胶囊提供；
/// 3. `.conv-item` **不在** auroraqua 的按钮组/导航组 `:is()` 列表里 ⇒ 无 hover 1.02 /
///    active .98；胶囊的扫光由父级 hover 驱动（auroraqua 163）。
///
/// ## 注入面（presence 是运行事实，由页面层给）
/// [AylaConversationList.isOnline] / [AylaConversationList.statusLabel] 未注入时分别回退
/// REST 快照 `peer.online` 与 [aylaDisplayStatusOf]（与 web 的 `withLiveStatus` 回退链一致）。
library;

import 'package:flutter/material.dart';

import '../../core/models/chat_message.dart' show AylaMessageType;
import '../../core/models/conversation.dart';
import '../../core/models/user_public.dart';
import '../../theme/sample_media.dart';
import '../../theme/tokens.dart';
import '../base/avatar_halo.dart';
import 'conversation_more_menu.dart';
import '../base/nav_highlight_list.dart';
import '../base/reveal.dart';
import '../base/sidebar_card.dart';
import '../base/tab_badge.dart';

/// 显示状态文案（web `utils/displayStatus.ts:17–32` `displayStatusOf`）：
/// `dnd→勿扰` / `away→离开` / `invisible→离线` / 其余（auto、未知旧值）跟随实时在线。
String aylaDisplayStatusOf(String? status, bool online) => switch (status) {
      'dnd' => '勿扰',
      'away' => '离开',
      'invisible' => '离线',
      _ => online ? '在线' : '离线',
    };

/// 非文本消息类型 → 预览占位（tsx 26–33 `TYPE_PLACEHOLDER`）。
const Map<AylaMessageType, String> kAylaConversationTypePlaceholder =
    <AylaMessageType, String>{
  AylaMessageType.image: '[图片]',
  AylaMessageType.voice: '[语音]',
  AylaMessageType.file: '[文件]',
  AylaMessageType.emoji: '[表情]',
  AylaMessageType.video: '[视频]',
  AylaMessageType.system: '[系统消息]',
};

/// 最新一条消息的列表预览文案（tsx 36–52 `previewLabel`）。
String aylaConversationPreviewLabel(AylaConversationSummary conv) {
  final AylaLastMessagePreview? last = conv.lastMessage;
  if (last == null) return '暂无消息';
  String body;
  if (last.status == 'recalled') {
    body = '[已撤回]';
  } else {
    // 后端统一生成混排摘要（preview）；旧后端/旧缓存无 preview 时按类型兜底
    final String preview = last.preview ?? '';
    if (preview.isNotEmpty) {
      body = preview;
    } else if (last.content.isNotEmpty) {
      body = last.content;
    } else {
      body = kAylaConversationTypePlaceholder[last.type] ?? '[消息]';
    }
  }
  // 群聊：带发送者名；私聊对端名即会话标题，不再重复。
  // 戳一戳（type=poke）的 preview 已是「A戳了戳B」完整文案，不再加发送者前缀（tsx 48–50）。
  if (conv.isGroup &&
      last.senderId != null &&
      last.senderName.isNotEmpty &&
      last.type != AylaMessageType.poke) {
    body = '${last.senderName}: $body';
  }
  return body;
}

/// 会话列表（`.conv-scroll` 内的 `ul`；滚动由调用方持有）。
///
/// **本件不自建高亮/动画**：选中胶囊、300ms 迁移、按压同步、扫光、键盘与滚动揭示
/// 全部走 [AylaNavHighlightList]（与 `AylaDirectoryFilters` 同一份实现）。
class AylaConversationList extends StatelessWidget {
  const AylaConversationList({
    super.key,
    required this.conversations,
    required this.activeId,
    required this.onSelect,
    this.elysiaUserId,
    this.disableAvatarNav = false,
    this.revealItems = false,
    this.isOnline,
    this.statusLabel,
    this.onAvatarTap,
    this.onTogglePin,
    this.onDelete,
    this.menuBusy = false,
    this.emptyText = '暂无会话，点击上方「新会话」发起',
  });

  final List<AylaConversationSummary> conversations;

  /// 当前选中的会话 id（null = 无选中）。
  final String? activeId;

  final void Function(String id) onSelect;

  /// 爱莉 user id（决定光环/头像是否走爱莉专属形态）。
  final String? elysiaUserId;

  /// 快捷消息栏内：头像不可点（不跳个人主页，tsx 66–67）。
  final bool disableAvatarNav;

  /// 逐条浮入（stagger，tsx 68–69）。
  final bool revealItems;

  /// 实时在线判定（web `presenceOnline(onlineUsers, withLiveStatus(...))`）——
  /// 页面层注入；未注入时回退 REST 快照 `peer.online`。
  final bool Function(AylaUserPublic? peer)? isOnline;

  /// 显示状态文案；未注入时用 [aylaDisplayStatusOf]。
  final String Function(AylaUserPublic? peer, bool online)? statusLabel;

  /// 私聊头像点击 → 个人主页（web `goUserProfile`）；未注入时头像不可点。
  final void Function(AylaUserPublic peer)? onAvatarTap;

  /// ⋯ 菜单：置顶切换（新值）。
  final void Function(AylaConversationSummary conv, bool pinned)? onTogglePin;

  /// ⋯ 菜单：删除会话（需调用方确认）。
  final void Function(AylaConversationSummary conv)? onDelete;

  /// 菜单请求进行中。
  final bool menuBusy;

  /// 空态文案（`.conv-empty`）。
  final String emptyText;

  int get _activeIndex =>
      conversations.indexWhere((AylaConversationSummary c) => c.id == activeId);

  @override
  Widget build(BuildContext context) {
    if (conversations.isEmpty) {
      return Padding(
        // `.conv-empty { padding: var(--sp-6) var(--sp-3) }`（app.css 707–713）
        padding: const EdgeInsets.symmetric(
          horizontal: AylaSpacing.sp3,
          vertical: AylaSpacing.sp6,
        ),
        child: Text(
          emptyText,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: AylaFonts.body,
            fontSize: 14,
            color: AylaColors.textSecondary,
          ),
        ),
      );
    }

    return AylaNavHighlightList(
      itemCount: conversations.length,
      selectedIndex: _activeIndex,
      axis: Axis.vertical,
      gap: 0, // web 的 `<ul>` 行间无间隙
      semanticLabel: '会话列表',
      onSelect: (int i) => onSelect(conversations[i].id),
      itemBuilder: (BuildContext context, AylaNavHighlightSlot slot) {
        final Widget row = _ConversationRow(
          conversation: conversations[slot.index],
          slot: slot,
          elysiaUserId: elysiaUserId,
          disableAvatarNav: disableAvatarNav,
          isOnline: isOnline,
          statusLabel: statusLabel,
          onAvatarTap: onAvatarTap,
          onTogglePin: onTogglePin,
          onDelete: onDelete,
          menuBusy: menuBusy,
        );
        if (!revealItems) return row;
        // 逐条浮入（tsx 96–102：`staggerDelay(idx)` + `.reveal-item` 下 20px 淡入）。
        // 包装在**槽位内**：入场只做 transform/opacity，槽位几何不变 ⇒ 胶囊测量不受影响。
        return AylaRevealItem(
          delay: AylaRevealMotion.staggerDelay(slot.index),
          child: row,
        );
      },
    );
  }
}

/// 单个会话行（`.conv-li` 内）—— 行底色、头像、正文、徽标、⋯ 菜单。
class _ConversationRow extends StatefulWidget {
  const _ConversationRow({
    required this.conversation,
    required this.slot,
    this.elysiaUserId,
    this.disableAvatarNav = false,
    this.isOnline,
    this.statusLabel,
    this.onAvatarTap,
    this.onTogglePin,
    this.onDelete,
    this.menuBusy = false,
  });

  final AylaConversationSummary conversation;
  final AylaNavHighlightSlot slot;
  final String? elysiaUserId;
  final bool disableAvatarNav;
  final bool Function(AylaUserPublic? peer)? isOnline;
  final String Function(AylaUserPublic? peer, bool online)? statusLabel;
  final void Function(AylaUserPublic peer)? onAvatarTap;
  final void Function(AylaConversationSummary conv, bool pinned)? onTogglePin;
  final void Function(AylaConversationSummary conv)? onDelete;
  final bool menuBusy;

  @override
  State<_ConversationRow> createState() => _ConversationRowState();
}

class _ConversationRowState extends State<_ConversationRow> {
  bool _hovered = false;

  AylaConversationSummary get conv => widget.conversation;

  @override
  Widget build(BuildContext context) {
    final AylaNavHighlightSlot slot = widget.slot;
    final bool active = slot.active;
    final AylaUserPublic? peer = conv.peer;
    final bool isPrivate = conv.isPrivate;
    final bool online =
        widget.isOnline?.call(peer) ?? (peer?.online ?? false);
    final bool isElysia =
        widget.elysiaUserId != null && peer?.id == widget.elysiaUserId;
    final bool isOnline = isPrivate && (online || isElysia);
    final String title = isPrivate
        ? (peer?.displayName ?? _nonEmpty(conv.title) ?? '未命名会话')
        : (_nonEmpty(conv.title) ?? '未命名群聊');

    return Stack(
      children: <Widget>[
        // 行本体：`<button class="conv-item has-auroraqua-highlight">`
        // 按压态上报（驱动容器级胶囊同步 .98）；web 的胶囊是按钮子元素，
        // 本实现的胶囊在容器级 ⇒ 由本层上报按压。
        Listener(
          onPointerDown: (_) => slot.onPressedChanged(true),
          onPointerUp: (_) => slot.onPressedChanged(false),
          onPointerCancel: (_) => slot.onPressedChanged(false),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) {
              setState(() => _hovered = true);
              slot.onHoverChanged(true);
              // 扫光由**父级 hover** 驱动（auroraqua 163）：只有选中项被指到时直达高亮
              if (slot.active) slot.onSweep(true);
            },
            onExit: (_) {
              setState(() => _hovered = false);
              slot.onHoverChanged(false);
              if (slot.active) slot.onSweep(false);
            },
            child: GestureDetector(
              onTap: slot.onTap,
              child: Semantics(
                button: true,
                selected: active,
                label: '$title，${aylaConversationPreviewLabel(conv)}',
                child: Container(
                  padding: const EdgeInsets.fromLTRB(
                    AylaSpacing.sp3,
                    AylaSpacing.sp3,
                    52, // padding-right: 52px（给 ⋯ 让位，app.css 501）
                    AylaSpacing.sp3,
                  ),
                  decoration: BoxDecoration(
                    // 选中行自身底透明（auroraqua 194–197）；置顶/悬停各有底色
                    color: active
                        ? null
                        : (conv.isPinned == true
                            ? (_hovered
                                ? const Color(0x29F9B0FF) // rgba(249,176,255,.16)
                                : const Color(0x1AF9B0FF)) // rgba(249,176,255,.1)
                            : (_hovered
                                ? const Color(0x2E9DBFE6) // rgba(157,191,230,.18)
                                : null)),
                    // 圆角 12（auroraqua 172 覆写 app.css 的 16，见文件头层叠要点 1）
                    borderRadius: BorderRadius.circular(AylaRadii.rInput),
                  ),
                  child: Row(
                    children: <Widget>[
                      _avatar(title, peer, isPrivate, isElysia, online),
                      const SizedBox(width: AylaSpacing.sp3),
                      Expanded(child: _body(title, peer, isPrivate, isOnline)),
                      if (conv.unreadCount > 0) ...<Widget>[
                        const SizedBox(width: AylaSpacing.sp2),
                        // `.conv-unread { flex-shrink: 0; min-width 20 … }`（app.css 693–706）
                        AylaTabBadge(
                          count: conv.unreadCount,
                          metrics: AylaTabBadgeMetrics.convUnread,
                          placement: AylaTabBadgePlacement.inline,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        // 置顶指示条（`.conv-item.is-pinned::before`：左 0 / 宽 3 / 高 60% / 居中）
        if (conv.isPinned == true)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Center(
              child: FractionallySizedBox(
                heightFactor: 0.6,
                child: Container(
                  width: 3,
                  decoration: BoxDecoration(
                    color: AylaColors.glow500,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            ),
          ),
        // ⋯ 更多菜单（`.conv-more { top:50%; right:6px }`；库内件自带 Positioned）
        AylaConversationMoreMenu(
          conversation: AylaConversation(
            id: conv.id,
            title: title,
            isPinned: conv.isPinned ?? false,
          ),
          showDelete: !conv.isGroup,
          busy: widget.menuBusy,
          onTogglePin: widget.onTogglePin == null
              ? null
              : (bool v) => widget.onTogglePin!(conv, v),
          onDelete: widget.onDelete == null ? null : () => widget.onDelete!(conv),
        ),
      ],
    );
  }

  Widget _avatar(
    String title,
    AylaUserPublic? peer,
    bool isPrivate,
    bool isElysia,
    bool online,
  ) {
    final bool tappable = !widget.disableAvatarNav &&
        isPrivate &&
        peer != null &&
        widget.onAvatarTap != null;
    final AylaUserPublic? target = peer;
    return AylaAvatarHalo(
      label: title,
      size: 40,
      online: isPrivate ? online : false,
      core: isElysia ? AylaAvatarCore.elysia : AylaAvatarCore.user,
      resourceUrl: isPrivate ? peer?.avatar : _nonEmpty(conv.avatar),
      onTap: tappable && target != null ? () => widget.onAvatarTap!(target) : null,
      semanticLabel: tappable ? '查看 $title 的个人主页' : null,
    );
  }

  Widget _body(
    String title,
    AylaUserPublic? peer,
    bool isPrivate,
    bool isOnline,
  ) {
    final String status = widget.statusLabel?.call(peer, isOnline) ??
        aylaDisplayStatusOf(peer?.status, isOnline);
    final int mention = conv.mentionUnreadCount ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // `.conv-item-title-row { gap: 6px }`
        Row(
          children: <Widget>[
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                // `.conv-item-title`：15/700；置顶转 grape-700（app.css 541–543 / 561–569）
                style: TextStyle(
                  fontFamily: AylaFonts.body,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: conv.isPinned == true
                      ? AylaColors.grape700
                      : AylaColors.textPrimary,
                ),
              ),
            ),
            if (isPrivate) ...<Widget>[
              const SizedBox(width: 6),
              _statusChip(status, isOnline),
            ],
          ],
        ),
        const SizedBox(height: 2), // `.conv-item-body { gap: 2px }`
        _previewLine(mention),
      ],
    );
  }

  /// `.conv-item-status`（app.css 571–601）：padding 1/8 + pill + 11/700 + 6px 圆点；
  /// 在线档转 `--success` 色并换底。
  Widget _statusChip(String text, bool isOnline) {
    final Color fg = isOnline ? AylaColors.success : AylaColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(
        color: isOnline
            ? const Color(0x2460B28C) // rgba(96,178,140,.14)
            : const Color(0x299DBFE6), // rgba(157,191,230,.16)
        borderRadius: AylaRadii.pill,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: isOnline ? AylaColors.success : const Color(0xFFB9C6DC),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontFamily: AylaFonts.body,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              height: 1.6,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }

  /// `.conv-item-sub`（app.css 604–617）：13 secondary 单行省略；`@我` 前缀粉色。
  Widget _previewLine(int mentionCount) {
    final String preview = aylaConversationPreviewLabel(conv);
    return Row(
      children: <Widget>[
        if (mentionCount > 0) ...<Widget>[
          Semantics(
            label: '$mentionCount 条消息@了我',
            child: const Text(
              '@我',
              style: TextStyle(
                fontFamily: AylaFonts.body,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AylaColors.pink500,
              ),
            ),
          ),
          const SizedBox(width: 4),
        ],
        Expanded(
          child: Text(
            preview,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: AylaFonts.body,
              fontSize: 13,
              color: AylaColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

String? _nonEmpty(String? value) {
  if (value == null) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

// ======================= 样张 =======================

AylaConversationSummary _previewConv({
  required String id,
  required String title,
  bool group = false,
  int unread = 0,
  int mention = 0,
  bool pinned = false,
  bool online = false,
  String? status,
  AylaLastMessagePreview? last,
  String? peerId,
}) =>
    AylaConversationSummary(
      id: id,
      type: group ? AylaConversationType.group : AylaConversationType.private,
      title: group ? title : '',
      avatar: group ? '/api/v1/media/conv-$id/thumbnail' : '',
      isPinned: pinned,
      unreadCount: unread,
      mentionUnreadCount: mention,
      memberCount: group ? 12 : 0,
      lastMessage: last,
      peer: group
          ? null
          : AylaUserPublic(
              id: peerId ?? 'u-$id',
              nickname: title,
              username: 'user_$id',
              status: status,
              online: online,
            ),
    );

AylaLastMessagePreview _previewLast(
  String content, {
  AylaMessageType type = AylaMessageType.text,
  String? senderName,
  String? senderId,
  String? preview,
  String status = 'sent',
}) =>
    AylaLastMessagePreview(
      seq: 10,
      type: type,
      content: content,
      senderId: senderId,
      senderName: senderName ?? '',
      status: status,
      createdAt: DateTime.now().toUtc().toIso8601String(),
      preview: preview,
    );

/// 会话列表样张。
///
/// 容器用 [AylaSidebarCard]（`.wide-messages-sidebar`：宽 332 / `--glass-shadow` /
/// 入场 500ms）——与 `AylaDirectoryFilters` 宽屏侧栏**同一份卡片实现**。
///
/// 覆盖：私聊（在线/勿扰/离线三档状态胶囊）、群聊（发送者名前缀）、置顶（粉底 + 左竖条 +
/// gravel 标题）、未读徽标（含 99+）、@我 前缀、撤回/媒体类型预览兜底、选中胶囊（可交互）。
Widget aylaConversationListSamples() {
  aylaEnableSampleMedia();
  // 选中项状态放在 StatefulBuilder **之外**（否则每次 rebuild 都被重置）
  String activeId = 'c2';
  return Align(
    alignment: Alignment.topLeft,
    widthFactor: 1,
    child: SizedBox(
      height: 460,
      child: AylaSidebarCard(
        // `.wide-messages-sidebar { width: 332px }`（messages.css 245）
        width: 332,
        shadow: AylaShadows.glass,
        padding: const EdgeInsets.fromLTRB(
          AylaSpacing.sp2,
          AylaSpacing.sp2,
          AylaSpacing.sp2,
          AylaSpacing.sp4,
        ),
        child: StatefulBuilder(
          builder: (BuildContext context, void Function(void Function()) setLocal) {
            return AylaConversationList(
              activeId: activeId,
              elysiaUserId: 'elysia',
              onSelect: (String id) => setLocal(() => activeId = id),
              onTogglePin: (_, __) {},
              onDelete: (_) {},
              conversations: <AylaConversationSummary>[
                _previewConv(
                  id: 'c1',
                  title: '爱莉',
                  peerId: 'elysia',
                  online: true,
                  last: _previewLast('我在的～需要我帮你准备点什么吗？', senderName: '爱莉'),
                ),
                _previewConv(
                  id: 'c2',
                  title: '小樱',
                  online: true,
                  last: _previewLast('晚上一起看直播吗？', senderName: '小樱'),
                ),
                _previewConv(
                  id: 'c3',
                  title: '阿澈',
                  status: 'dnd',
                  last: _previewLast('', type: AylaMessageType.image),
                ),
                _previewConv(
                  id: 'c4',
                  title: '深夜电台群',
                  group: true,
                  unread: 128,
                  mention: 2,
                  last: _previewLast('今晚十点开播', senderName: '汐汐', senderId: 'u9'),
                ),
                _previewConv(
                  id: 'c5',
                  title: '桌游小组',
                  group: true,
                  pinned: true,
                  unread: 3,
                  last: _previewLast('', status: 'recalled'),
                ),
                _previewConv(
                  id: 'c6',
                  title: '已离线的朋友',
                  last: _previewLast('明天见', senderName: '小林'),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}
