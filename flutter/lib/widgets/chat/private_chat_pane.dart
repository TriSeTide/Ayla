/// 私聊内容面板（`components/chat/PrivateChatPane.tsx` 的 Flutter 等价）。
///
/// ## 事实源
///
/// | 本件 | web |
/// |---|---|
/// | [AylaPrivateChatPane] | `PrivateChatPane.tsx:165–253`（头部 + 消息区 + 输入区三段） |
/// | 外壳 | private.css 8–15（`.private-chat`：`height: 100%` + column + `overflow: hidden`） |
/// | 头部（窄屏档） | private.css 14–26（`.private-chat-head`：56 高 / padding `sp2 sp4` / gap sp3 / `--glass-bg` + **blur18 sat1.4** + 下边框） |
/// | 头部（宽屏档） | auroraqua 402–410（≥769 卡片化：1px 边 + radius-card 16 + `--glass-shadow-compact` + `--glass-filter`(blur24 sat1.4)；`margin: var(--sidebar-gutter)` = **12px**（`tokens.css:132` 确有定义 —— 2026-09-28 更正原「死声明」误判）⇒ 本件当前未表达该外边距，属待裁决偏离）+ auroraqua 366（`.wide-messages-pane .private-chat-head { margin-left: 0 }`） |
/// | 标题/状态 | private.css 27–52（`.private-chat-name` 15/700；`.private-chat-status` 12 secondary；**`.is-typing` → `--glow-500`**） |
/// | 禁发提示 | private.css 54–64（`.private-chat-blocked`：`margin: sp3 sp6` + padding `sp3 sp4` + radius-input + `--warning-soft-bg/--warning-soft-border` + 13 居中） |
/// | 禁用条件 | tsx 158–163（私聊 + 对端已知 + 好友关系已加载 + 对端不是爱莉 + 非好友） |
///
/// ## 注入边界（与 web 的分层一致）
/// web 在本件内直接调用 `useChat` 数据流（拉历史 / 订阅 WS / 标已读 / typing 帧）；
/// Flutter 侧这些属**页面层职责**，本件只接收投影与回调：
/// - 消息与会话摘要、分页标志、`onLoadMore` / `onLoadUntilSeq`；
/// - `onMarkRead` / `onMarkConversationRead`（已读上报）；
/// - `peerOnline` / `peerStatus`（presence）、`peerTyping`（typing 帧）；
/// - `blocked`（非好友禁发判定由调用方给：它依赖好友关系查询，属数据层）；
/// - `composer`（调用方构造 `AylaMessageInput`，与 `AylaDanmakuList` 同口径）。
///
/// ## 公开面
/// `AylaPrivateChatPane` · 样张 `aylaPrivateChatPaneSamples()`

library;

import 'package:flutter/material.dart';

import '../../core/models/chat_message.dart';
import '../../core/models/conversation.dart';
import '../../core/models/user_public.dart';
import '../../theme/app_icons.dart';
import '../../theme/glass.dart';
import '../../theme/sample_media.dart';
import '../../theme/tokens.dart';
import '../base/avatar_halo.dart';
import 'message_input.dart';
import 'message_list.dart';

/// 私聊内容面板（宽屏消息两列右侧 / 私聊窗口 / 快捷消息栏内联共用）。
class AylaPrivateChatPane extends StatelessWidget {
  const AylaPrivateChatPane({
    super.key,
    required this.conversation,
    required this.messages,
    required this.currentUserId,
    this.elysiaUserId,
    this.onBack,
    this.backLabel = '返回消息中心',
    this.disableAvatarNav = false,
    this.hasMore = false,
    this.loading = false,
    this.onLoadMore,
    this.onQuote,
    this.onRecall,
    this.onRetry,
    this.onRemove,
    this.onCancel,
    this.onMarkRead,
    this.onMarkConversationRead,
    this.onLoadUntilSeq,
    this.onPoke,
    this.onMentionSender,
    this.onAvatarTap,
    this.externalJump,
    this.onExternalJumpHandled,
    this.unreadSeqs = const <int>[],
    this.mentionUnreadSeqs = const <int>[],
    this.replyUnreadSeqs = const <int>[],
    this.peerOnline = false,
    this.peerStatus,
    this.peerTyping = false,
    this.blocked = false,
    this.composer,
    this.narrow = false,
  });

  /// 会话摘要（null = 尚未加载 ⇒ 头部按「私聊」占位）。
  final AylaConversationSummary? conversation;

  final List<AylaChatMessage> messages;
  final String? currentUserId;

  /// 爱莉 profile 的 user.id（决定头像/头部是否走爱莉专属形态与是否可点）。
  final String? elysiaUserId;

  /// 返回键（窄屏私聊窗口用；宽屏两列不传）。
  final VoidCallback? onBack;
  final String backLabel;

  /// 快捷消息栏内：头像不可点（web `disableAvatarNav`，R-QM）。
  final bool disableAvatarNav;

  final bool hasMore;
  final bool loading;
  final Future<void> Function()? onLoadMore;

  final void Function(AylaChatMessage msg)? onQuote;
  final void Function(AylaChatMessage msg)? onRecall;
  final void Function(AylaChatMessage msg)? onRetry;
  final void Function(AylaChatMessage msg)? onRemove;
  final void Function(AylaChatMessage msg)? onCancel;

  /// 已读上报（`exact` = 精确到该条）。
  final Future<void> Function(AylaChatMessage msg, bool exact)? onMarkRead;

  /// 普通未读标签批量已读。
  final Future<void> Function(int throughSeq, List<String> excludeIds)?
      onMarkConversationRead;

  final Future<bool> Function(int seq)? onLoadUntilSeq;
  final void Function(String targetUserId)? onPoke;
  final void Function(String userId, String name)? onMentionSender;
  final void Function()? onAvatarTap;

  final ({String messageId, int seq})? externalJump;
  final void Function()? onExternalJumpHandled;

  final List<int> unreadSeqs;
  final List<int> mentionUnreadSeqs;
  final List<int> replyUnreadSeqs;

  /// 实时在线（presence 注入；web `usePresenceOnline(peer)`）。
  final bool peerOnline;

  /// 显示状态文案（web `useDisplayStatus(peer)`）；null = 不渲染状态行。
  final String? peerStatus;

  /// 「对方正在输入」（web：typing 帧聚合出的 `typingActive`）。
  final bool peerTyping;

  /// 非好友禁发（web tsx 158–163 的 `blocked`）—— 为真时**替换输入区**。
  final bool blocked;

  /// 输入区（调用方构造 `AylaMessageInput`；null = 不渲染）。
  final Widget? composer;

  /// 窄屏档（头部为通栏玻璃条）；宽屏档（≥769）头部**卡片化**。
  final bool narrow;

  /// 头部高度（`.private-chat-head { height: 56px }`）。
  static const double headHeight = 56;

  @override
  Widget build(BuildContext context) {
    final AylaConversationSummary? conv = conversation;
    final String title = conv == null
        ? '私聊'
        : (conv.isPrivate
            ? (conv.peer?.displayName ?? _nonEmpty(conv.title) ?? '私聊')
            : (_nonEmpty(conv.title) ?? '私聊'));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.max,
      children: <Widget>[
        _head(title, conv),
        Expanded(
          child: AylaMessageList(
            messages: messages,
            currentUserId: currentUserId,
            conversation: conv,
            elysiaUserId: elysiaUserId,
            hasMore: hasMore,
            loading: loading,
            onLoadMore: onLoadMore,
            onQuote: onQuote,
            onRecall: onRecall,
            onRetry: onRetry,
            onRemove: onRemove,
            onCancel: onCancel,
            onMarkRead: onMarkRead,
            onMarkConversationRead: onMarkConversationRead,
            onLoadUntilSeq: onLoadUntilSeq,
            onPoke: onPoke,
            onMentionSender: onMentionSender,
            externalJump: externalJump,
            onExternalJumpHandled: onExternalJumpHandled,
            unreadSeqs: unreadSeqs,
            mentionUnreadSeqs: mentionUnreadSeqs,
            replyUnreadSeqs: replyUnreadSeqs,
          ),
        ),
        if (blocked)
          // `.private-chat-blocked`（private.css 54–64）
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AylaSpacing.sp6,
              vertical: AylaSpacing.sp3,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AylaSpacing.sp4,
                vertical: AylaSpacing.sp3,
              ),
              decoration: BoxDecoration(
                color: AylaColors.warningSoftBg,
                border: Border.all(color: AylaColors.warningSoftBorder),
                borderRadius: BorderRadius.circular(AylaRadii.rInput),
              ),
              child: const Text(
                '对方已不是你的好友，无法发送消息',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: AylaFonts.body,
                  fontSize: 13,
                  color: AylaColors.textPrimary,
                ),
              ),
            ),
          )
        else if (composer != null)
          composer!,
      ],
    );
  }

  /// 头部（`.private-chat-head`；窄屏通栏条 / 宽屏卡片）。
  Widget _head(String title, AylaConversationSummary? conv) {
    final bool isElysia = elysiaUserId != null && conv?.peer?.id == elysiaUserId;
    final bool avatarTappable = !disableAvatarNav &&
        conv?.peer != null &&
        !isElysia &&
        onAvatarTap != null;

    final Widget content = Row(
      children: <Widget>[
        if (onBack != null) ...<Widget>[
          // `.icon-btn-40`（40×40）
          Semantics(
            button: true,
            label: backLabel,
            child: GestureDetector(
              key: const ValueKey<String>('private-chat-back'),
              onTap: onBack,
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AylaColors.glassBg,
                  border: Border.all(color: AylaColors.glassBorder),
                  borderRadius: BorderRadius.circular(AylaRadii.rInput),
                ),
                child: Center(
                  child: AylaIcon(aylaIconByName('iconBack')!, size: 20),
                ),
              ),
            ),
          ),
          const SizedBox(width: AylaSpacing.sp3),
        ],
        AylaAvatarHalo(
          label: title,
          size: 36,
          online: peerOnline,
          core: isElysia ? AylaAvatarCore.elysia : AylaAvatarCore.user,
          resourceUrl: conv?.peer?.avatar,
          onTap: avatarTappable ? onAvatarTap : null,
          semanticLabel: avatarTappable ? '查看 $title 的个人主页' : null,
        ),
        const SizedBox(width: AylaSpacing.sp3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: AylaFonts.body,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AylaColors.textPrimary,
                ),
              ),
              if (peerTyping || (peerStatus != null && peerStatus!.isNotEmpty))
                Text(
                  // 「对方正在输入…」替换在线状态行，不加高顶栏（private.css 49–52）
                  peerTyping ? '对方正在输入…' : peerStatus!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: AylaFonts.body,
                    fontSize: 12,
                    color: peerTyping
                        ? AylaColors.glow500 // `.is-typing { color: var(--glow-500) }`
                        : AylaColors.textSecondary,
                  ),
                ),
            ],
          ),
        ),
      ],
    );

    final Widget sized = SizedBox(height: headHeight, child: content);

    if (narrow) {
      // 窄屏：通栏玻璃条（`--glass-bg` + blur18 sat1.4 + 下边框，无圆角）
      return AylaGlassSurface(
        radiusOverride: BorderRadius.zero,
        borderOverride: const Border(
          bottom: BorderSide(color: AylaColors.glassBorder),
        ),
        blur: AylaGlass.blurNav,
        shadow: const <BoxShadow>[],
        padding: const EdgeInsets.symmetric(
          horizontal: AylaSpacing.sp4,
          vertical: AylaSpacing.sp2,
        ),
        child: sized,
      );
    }
    // 宽屏：卡片（1px 边 + radius 16 + compact 阴影 + blur24 sat1.4；无外边距）
    return AylaGlassSurface(
      radius: AylaRadii.rCard,
      blur: AylaGlass.blurCard,
      shadow: AylaShadows.compact,
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp4,
        vertical: AylaSpacing.sp2,
      ),
      child: sized,
    );
  }
}

String? _nonEmpty(String? value) {
  if (value == null) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

// ======================= 样张 =======================

AylaChatMessage _msg({
  required String id,
  required int seq,
  required String senderId,
  required String content,
  DateTime? at,
}) =>
    AylaChatMessage(
      id: id,
      conversationId: 'c1',
      senderId: senderId,
      type: AylaMessageType.text,
      content: content,
      status: AylaMessageStatus.sent,
      seq: seq,
      createdAt: (at ?? DateTime(2026, 9, 24, 21, 30)).toUtc().toIso8601String(),
    );

AylaConversationSummary _conv() => AylaConversationSummary(
      id: 'c1',
      type: AylaConversationType.private,
      title: '',
      avatar: '',
      peer: const AylaUserPublic(
        id: 'u2',
        nickname: '小樱',
        username: 'sakura',
        online: true,
      ),
    );

/// 私聊面板样张：
/// 宽屏（头部卡片 + 面板）/ 窄屏（通栏条 + 返回键）/ 非好友禁发态。
Widget aylaPrivateChatPaneSamples() {
  aylaEnableSampleMedia();
  final List<AylaChatMessage> messages = <AylaChatMessage>[
    _msg(id: 'a', seq: 1, senderId: 'u2', content: '睡了吗？'),
    _msg(
      id: 'b',
      seq: 2,
      senderId: 'me',
      content: '还没，在写文档',
      at: DateTime(2026, 9, 24, 21, 31),
    ),
    _msg(
      id: 'c',
      seq: 3,
      senderId: 'u2',
      content: '别太晚，早点休息',
      at: DateTime(2026, 9, 24, 21, 32),
    ),
  ];

  Widget stage(String label, Widget child, {double width = 640, double height = 420}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: AylaSpacing.sp2),
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: AylaFonts.body,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AylaColors.textSecondary,
              ),
            ),
          ),
          Align(
            alignment: Alignment.topLeft,
            widthFactor: 1,
            child: SizedBox(width: width, height: height, child: child),
          ),
          const SizedBox(height: AylaSpacing.sp6),
        ],
      );

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      stage(
        '宽屏（头部卡片化 + 消息区 + 输入区）',
        AylaPrivateChatPane(
          conversation: _conv(),
          messages: messages,
          currentUserId: 'me',
          peerOnline: true,
          peerStatus: '在线',
          onMarkRead: (_, __) async {},
          onMarkConversationRead: (_, __) async {},
          composer: AylaMessageInput(
            onSubmit: (_) {},
            draftKey: 'pane-wide',
            narrow: false,
          ),
        ),
      ),
      stage(
        '窄屏（通栏头部 + 返回键 + 工具键下移）',
        AylaPrivateChatPane(
          conversation: _conv(),
          messages: messages,
          currentUserId: 'me',
          narrow: true,
          peerOnline: true,
          peerStatus: '在线',
          peerTyping: true,
          onBack: () {},
          composer: AylaMessageInput(
            onSubmit: (_) {},
            draftKey: 'pane-narrow',
            narrow: true,
          ),
        ),
        width: 375,
        height: 460,
      ),
      stage(
        '非好友禁发（`.private-chat-blocked` 替换输入区）',
        AylaPrivateChatPane(
          conversation: _conv(),
          messages: messages,
          currentUserId: 'me',
          blocked: true,
          peerStatus: '离线',
          composer: AylaMessageInput(onSubmit: (_) {}, draftKey: 'pane-blocked'),
        ),
        height: 360,
      ),
    ],
  );
}
