/// 认证消息面板与行 —— `WideMessagesSidebar` 与 `QuickMessagesSheet` **共用**。
///
/// ## 事实源
///
/// | 本件 | web |
/// |---|---|
/// | [AylaRequestRow] | `WideMessagesSidebar.tsx:336–368` / `QuickMessagesSheet.tsx:331–363` 的 `RequestRow`（两处同构：头像 36 + 名称 + 留言 + 同意/拒绝） |
/// | [AylaNoticeRow] | 退群通知行（`notice-row`：正文两行 + 「知道了」） |
/// | [AylaFriendRow] | `WideMessagesSidebar.tsx:237–260`（`.friend-row`：可点主体 + 「解除好友」） |
/// | [AylaRequestsPanel] | 两处的认证 tab 内容（退群通知 / 好友申请 / 群邀请 / 入群申请 + 空态） |
/// | 行材质 | messages.css 96–143（`.request-row`：flex + gap sp3 + padding `sp2 sp3` + radius-input + `--glass-bg` + 1px 边 + `--glass-filter` + `--glass-shadow-compact`）；`.request-btn` min-h 32 / padding 0 sp3 / 13 |
/// | 好友行 | messages.css 145–191（`.friend-row` 同材质；`.friend-row-main` gap sp3 / min-h 40；`.friend-remove-btn` min-h 40 / padding 0 sp2 / 12） |
/// | 分组 | messages.css 83–94（`.messages-group-title` 15/700 + margin-bottom sp2；`.messages-group` column + gap sp2）+ 63–68（`.messages-section-hint`：`margin-top: -sp2` + 13 secondary）+ 199–205（`.messages-empty`：padding sp4 + 13 secondary 居中） |
///
/// ## 与 web 的差异（有意，登记）
/// 1. web 的 `RequestRow` 在 `WideMessagesSidebar`（`<h4>`）与 `QuickMessagesSheet`（`<h3>`）
///    各写了一份，**只有标题层级不同、视觉完全相同**（都是 `.messages-group-title`）⇒
///    本库抽成一件共用（`sectionTitle` 由调用方给）；
/// 2. 群邀请行的名称文案两处不同（宽屏 `「X（来自 Y）」` / 快捷栏 `「X」`）⇒ 由调用方传 `name`，
///    本件不拼文案；入群申请的 `message` 拼接同理由调用方完成（web 两处不一致，属调用方职责）。
///
/// ## 公开面
/// `AylaRequestRow` · `AylaNoticeRow` · `AylaFriendRow` · `AylaRequestsPanel` · `AylaGlassRowShell` · 样张 `aylaRequestsPanelSamples()`

library;

import 'package:flutter/material.dart';

import '../../core/models/social_requests.dart';
import '../../core/models/user_public.dart';
import '../../theme/glass.dart';
import '../../theme/sample_media.dart';
import '../../theme/tokens.dart';
import '../base/avatar_halo.dart';
import '../base/directory_controls.dart' show AylaDirectoryLoadMore;

/// 认证消息行（`.request-row`）。
class AylaRequestRow extends StatelessWidget {
  const AylaRequestRow({
    super.key,
    required this.name,
    this.message,
    this.avatar,
    this.avatarLabel,
    this.avatarOnline = false,
    this.onAvatarTap,
    this.onAccept,
    this.onReject,
    this.acceptLabel = '同意',
    this.rejectLabel = '拒绝',
    this.busy = false,
  });

  /// 主文案（`.request-name`；群邀请/入群申请的拼接由调用方负责）。
  final String name;

  /// 次要文案（`.request-msg`；null/空 = 不渲染）。
  final String? message;

  final AylaUserPublic? avatar;

  /// 头像文案（默认取 [avatar] 的 displayName）。
  final String? avatarLabel;

  final bool avatarOnline;
  final VoidCallback? onAvatarTap;

  /// 同意（`.btn-primary.request-btn`）；null = 不渲染。
  final VoidCallback? onAccept;

  /// 拒绝（`.btn-ghost.request-btn`）；null = 不渲染。
  final VoidCallback? onReject;

  final String acceptLabel;
  final String rejectLabel;

  /// 请求进行中（禁用两键）。
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final String label = avatarLabel ?? avatar?.displayName ?? name;
    return AylaGlassRowShell(
      child: Row(
        children: <Widget>[
          AylaAvatarHalo(
            label: label,
            size: 36,
            online: avatarOnline,
            resourceUrl: avatar?.avatar,
            onTap: onAvatarTap,
          ),
          const SizedBox(width: AylaSpacing.sp3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: AylaFonts.body,
                    fontFamilyFallback: AylaFonts.cjkFallback,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AylaColors.textPrimary,
                  ),
                ),
                if (message != null && message!.isNotEmpty)
                  Text(
                    message!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: AylaFonts.body,
                      fontFamilyFallback: AylaFonts.cjkFallback,
                      fontSize: 12,
                      color: AylaColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          if (onAccept != null || onReject != null) ...<Widget>[
            const SizedBox(width: AylaSpacing.sp2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (onAccept != null)
                  _RequestButton(
                    label: acceptLabel,
                    primary: true,
                    onPressed: busy ? null : onAccept,
                  ),
                if (onAccept != null && onReject != null)
                  const SizedBox(width: AylaSpacing.sp2),
                if (onReject != null)
                  _RequestButton(
                    label: rejectLabel,
                    primary: false,
                    onPressed: busy ? null : onReject,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 退群通知行（`notice-row`：两行正文 + 「知道了」）。
class AylaNoticeRow extends StatelessWidget {
  const AylaNoticeRow({
    super.key,
    required this.title,
    required this.detail,
    this.onDismiss,
    this.dismissLabel = '知道了',
    this.busy = false,
  });

  final String title;
  final String detail;
  final VoidCallback? onDismiss;
  final String dismissLabel;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return AylaGlassRowShell(
      child: Row(
        children: <Widget>[
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
                    fontFamilyFallback: AylaFonts.cjkFallback,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AylaColors.textPrimary,
                  ),
                ),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: AylaFonts.body,
                    fontFamilyFallback: AylaFonts.cjkFallback,
                    fontSize: 12,
                    color: AylaColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (onDismiss != null) ...<Widget>[
            const SizedBox(width: AylaSpacing.sp2),
            _RequestButton(
              label: dismissLabel,
              primary: false,
              onPressed: busy ? null : onDismiss,
            ),
          ],
        ],
      ),
    );
  }
}

/// 好友行（`.friend-row`）：可点主体（进会话）+ 「解除好友」。
///
/// ⚠️ [avatarSize] 是 2026-09-28 消息域批次补的**纯增量档**（默认 36 ⇒ 既有调用点逐像素不变）：
/// web 两处同构好友行**头像尺寸不同** —— 宽屏 `WideMessagesSidebar.tsx:241` 用 `size={36}`、
/// 窄屏 `MessagesPage.tsx:288` 用 `size={40}`；`.friend-row` 其余声明两者完全一致。
class AylaFriendRow extends StatelessWidget {
  const AylaFriendRow({
    super.key,
    required this.user,
    required this.onOpenChat,
    this.onAvatarTap,
    this.onRemove,
    this.online = false,
    this.removing = false,
    this.avatarSize = 36,
  });

  final AylaUserPublic user;
  final VoidCallback onOpenChat;
  final VoidCallback? onAvatarTap;
  final VoidCallback? onRemove;
  final bool online;
  final bool removing;

  /// 头像尺寸（`.friend-row-main` 的 `Avatar`；宽屏 36 / 窄屏 40）。
  final double avatarSize;

  @override
  Widget build(BuildContext context) {
    final String label = user.displayName ?? '';
    return AylaGlassRowShell(
      child: Row(
        children: <Widget>[
          Expanded(
            child: GestureDetector(
              onTap: onOpenChat,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 40),
                  child: Row(
                    children: <Widget>[
                      AylaAvatarHalo(
                        label: label,
                        size: avatarSize,
                        online: online,
                        resourceUrl: user.avatar,
                        onTap: onAvatarTap,
                      ),
                      const SizedBox(width: AylaSpacing.sp3),
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: AylaFonts.body,
                            fontFamilyFallback: AylaFonts.cjkFallback,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AylaColors.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (onRemove != null) ...<Widget>[
            const SizedBox(width: AylaSpacing.sp2),
            AylaGlassButton(
              label: removing ? '解除中…' : '解除好友',
              variant: AylaGlassButtonVariant.ghost,
              minHeight: 40,
              padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp2),
              fontSize: 12,
              onPressed: removing ? null : onRemove,
              semanticLabel: '解除好友',
            ),
          ],
        ],
      ),
    );
  }
}

/// 认证消息面板（退群通知 / 好友申请 / 群邀请 / 入群申请 + 空态）。
class AylaRequestsPanel extends StatelessWidget {
  const AylaRequestsPanel({
    super.key,
    this.leaveNotices = const AylaSocialPage<AylaGroupMemberLeaveNotice>(),
    this.realtimeLeaveNotices = const <AylaNoticeRow>[],
    this.friendRequests = const AylaSocialPage<AylaFriendRequest>(),
    this.invites = const AylaSocialPage<AylaGroupInvite>(),
    this.joinRequests = const AylaSocialPage<AylaGroupJoinRequest>(),
    this.sectionHint,
    this.emptyText = '暂无待处理认证消息',
    this.onDismissLeaveNotice,
    this.onDismissRealtimeNotice,
    this.onFriendAction,
    this.onInviteAction,
    this.onJoinAction,
    this.busyId,
    this.friendNameOf,
    this.inviteNameOf,
    this.joinNameOf,
    this.isOnline,
    this.joinSectionTitle = '入群申请',
    this.sectionGap = AylaSpacing.sp3,
  });

  /// 持久化退群通知分组。
  final AylaSocialPage<AylaGroupMemberLeaveNotice> leaveNotices;

  /// 实时退群通知（WS 帧；web 的 `realtimeLeaveNotices`）—— 调用方构造行。
  final List<AylaNoticeRow> realtimeLeaveNotices;

  final AylaSocialPage<AylaFriendRequest> friendRequests;
  final AylaSocialPage<AylaGroupInvite> invites;
  final AylaSocialPage<AylaGroupJoinRequest> joinRequests;

  /// 顶部提示（宽屏 tab 有「好友申请、群邀请和入群申请」，快捷栏没有）。
  final String? sectionHint;

  final String emptyText;

  /// (noticeId) → 标记已读（web `readLeaveNotice`）。
  final void Function(String id)? onDismissLeaveNotice;

  /// (index) → 关闭实时通知（web `dismissNotice(id)`；实时条目由调用方持有列表）。
  final void Function(int index)? onDismissRealtimeNotice;

  final void Function(AylaFriendRequest req, bool accept)? onFriendAction;
  final void Function(AylaGroupInvite inv, bool accept)? onInviteAction;
  final void Function(AylaGroupJoinRequest req, bool accept)? onJoinAction;

  /// 当前进行中的条目 id（禁用两键）。
  final String? busyId;

  /// 名称拼接（web 两处文案不同 ⇒ 由调用方决定；null = 用默认规则）。
  final String Function(AylaFriendRequest req)? friendNameOf;
  final String Function(AylaGroupInvite inv)? inviteNameOf;
  final String Function(AylaGroupJoinRequest req)? joinNameOf;

  /// 实时在线判定（presence 注入）。
  final bool Function(AylaUserPublic user)? isOnline;

  /// 入群申请分组标题（web 宽屏 `WideMessagesSidebar.tsx:313` = 「入群申请」；
  /// 窄屏 `MessagesPage.tsx:357` = 「入群申请（群主/管理员）」）——纯增量档，默认 = 宽屏文案。
  final String joinSectionTitle;

  /// 分组间距（web `.messages-friends { gap: sp3 }` = 宽屏侧栏；
  /// `.messages-requests { gap: sp4 }` = 窄屏认证 tab）——纯增量档，默认 = sp3。
  final double sectionGap;

  bool get _allEmpty =>
      friendRequests.isEmptyState &&
      invites.isEmptyState &&
      joinRequests.isEmptyState &&
      leaveNotices.isEmptyState &&
      realtimeLeaveNotices.isEmpty;

  @override
  Widget build(BuildContext context) {
    final List<Widget> sections = <Widget>[];
    if (sectionHint != null) {
      sections.add(
        Padding(
          // `.messages-section-hint { margin: calc(var(--sp-2) * -1) 0 0 }`
          padding: const EdgeInsets.only(top: 0),
          child: Transform.translate(
            offset: const Offset(0, -AylaSpacing.sp2),
            child: Text(
              sectionHint!,
              style: const TextStyle(
                fontFamily: AylaFonts.body,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 13,
                height: 1.5,
                color: AylaColors.textSecondary,
              ),
            ),
          ),
        ),
      );
    }
    if (leaveNotices.shouldRender || realtimeLeaveNotices.isNotEmpty) {
      sections.add(
        _section(
          '退群通知',
          <Widget>[
            for (final AylaGroupMemberLeaveNotice n in leaveNotices.items)
              AylaNoticeRow(
                title: '群成员已离开',
                detail: '${n.conversationTitle}：${n.memberName} 已离开',
                busy: busyId == n.id,
                onDismiss: onDismissLeaveNotice == null
                    ? null
                    : () => onDismissLeaveNotice!(n.id),
              ),
            ...realtimeLeaveNotices,
          ],
          page: leaveNotices,
        ),
      );
    }
    if (friendRequests.shouldRender) {
      sections.add(
        _section(
          '好友申请',
          <Widget>[
            for (final AylaFriendRequest r in friendRequests.items)
              AylaRequestRow(
                name: friendNameOf?.call(r) ?? (r.fromUser.displayName ?? ''),
                message: r.message,
                avatar: r.fromUser,
                avatarOnline: isOnline?.call(r.fromUser) ?? r.fromUser.online,
                busy: busyId == r.id,
                onAccept: onFriendAction == null
                    ? null
                    : () => onFriendAction!(r, true),
                onReject: onFriendAction == null
                    ? null
                    : () => onFriendAction!(r, false),
              ),
          ],
          page: friendRequests,
        ),
      );
    }
    if (invites.shouldRender) {
      sections.add(
        _section(
          '群邀请',
          <Widget>[
            for (final AylaGroupInvite inv in invites.items)
              AylaRequestRow(
                name: inviteNameOf?.call(inv) ?? inv.conversationTitle,
                message: '邀请你加入群聊',
                avatar: inv.inviter,
                avatarOnline: isOnline?.call(inv.inviter) ?? inv.inviter.online,
                busy: busyId == inv.id,
                onAccept:
                    onInviteAction == null ? null : () => onInviteAction!(inv, true),
                onReject: onInviteAction == null
                    ? null
                    : () => onInviteAction!(inv, false),
              ),
          ],
          page: invites,
        ),
      );
    }
    if (joinRequests.shouldRender) {
      sections.add(
        _section(
          joinSectionTitle,
          <Widget>[
            for (final AylaGroupJoinRequest r in joinRequests.items)
              AylaRequestRow(
                name: joinNameOf?.call(r) ?? (r.applicant.displayName ?? ''),
                message: r.message.isEmpty
                    ? r.conversationTitle
                    : '${r.conversationTitle}：${r.message}',
                avatar: r.applicant,
                avatarOnline:
                    isOnline?.call(r.applicant) ?? r.applicant.online,
                busy: busyId == r.id,
                onAccept:
                    onJoinAction == null ? null : () => onJoinAction!(r, true),
                onReject:
                    onJoinAction == null ? null : () => onJoinAction!(r, false),
              ),
          ],
          page: joinRequests,
        ),
      );
    }

    if (_allEmpty) {
      sections.add(
        Padding(
          // `.messages-empty { padding: var(--sp-4) }`
          padding: const EdgeInsets.all(AylaSpacing.sp4),
          child: Text(
            emptyText,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: AylaFonts.body,
              fontFamilyFallback: AylaFonts.cjkFallback,
              fontSize: 13,
              color: AylaColors.textSecondary,
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < sections.length; i++) ...<Widget>[
          if (i > 0) SizedBox(height: sectionGap),
          sections[i],
        ],
      ],
    );
  }

  Widget _section(String title, List<Widget> rows, {required AylaSocialPage<Object?> page}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: AylaSpacing.sp2),
          child: Text(
            title,
            style: const TextStyle(
              fontFamily: AylaFonts.body,
              fontFamilyFallback: AylaFonts.cjkFallback,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: AylaColors.textPrimary,
            ),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: AylaSpacing.sp2, // `.messages-group { gap: sp2 }`
          children: <Widget>[
            ...rows,
            if (page.loading || page.error != null || page.hasMore)
              AylaDirectoryLoadMore(
                loading: page.loading,
                error: page.error,
                hasMore: page.hasMore,
                invalidated: false,
                loadMore: page.loadMore ?? () async {},
                refresh: page.refresh ?? () async {},
                retainCompletedSpace: false,
              ),
          ],
        ),
      ],
    );
  }
}

/// 认证/好友行的公共外壳（`.request-row` / `.friend-row` 同材质）。
class AylaGlassRowShell extends StatelessWidget {
  const AylaGlassRowShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AylaGlassSurface(
      radius: AylaRadii.rInput, // radius-input 12
      blur: AylaGlass.blurCard, // `backdrop-filter: var(--glass-filter)`（blur24 sat1.4）
      shadow: AylaShadows.compact, // --glass-shadow-compact
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp3,
        vertical: AylaSpacing.sp2,
      ), // padding: sp2 sp3
      child: child,
    );
  }
}

/// `.request-btn`：min-h 32 / padding 0 sp3 / 13。
class _RequestButton extends StatelessWidget {
  const _RequestButton({
    required this.label,
    required this.primary,
    this.onPressed,
  });

  final String label;
  final bool primary;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return AylaGlassButton(
      label: label,
      variant: primary ? AylaGlassButtonVariant.primary : AylaGlassButtonVariant.ghost,
      minHeight: 32,
      padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp3),
      fontSize: 13,
      onPressed: onPressed,
      semanticLabel: label,
    );
  }
}

// ======================= 样张 =======================

AylaUserPublic _u(String id, String name, {bool online = false}) =>
    AylaUserPublic(id: id, nickname: name, username: 'user_$id', online: online);

/// 认证消息面板样张：
/// 四分组齐全（含实时退群通知）/ 空态。
Widget aylaRequestsPanelSamples() {
  aylaEnableSampleMedia();
  Widget cell(String label, Widget child) => Column(
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
            child: SizedBox(width: 420, child: child),
          ),
          const SizedBox(height: AylaSpacing.sp6),
        ],
      );

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      cell(
        '四分组（退群通知 / 好友申请 / 群邀请 / 入群申请 + 同意·拒绝）',
        AylaRequestsPanel(
          sectionHint: '好友申请、群邀请和入群申请',
          isOnline: (AylaUserPublic u) => u.online,
          onDismissLeaveNotice: (_) {},
          onFriendAction: (_, __) {},
          onInviteAction: (_, __) {},
          onJoinAction: (_, __) {},
          leaveNotices: AylaSocialPage<AylaGroupMemberLeaveNotice>(
            items: const <AylaGroupMemberLeaveNotice>[
              AylaGroupMemberLeaveNotice(
                id: 'l1',
                conversationTitle: '深夜电台群',
                memberName: '小林',
              ),
            ],
          ),
          friendRequests: AylaSocialPage<AylaFriendRequest>(
            items: <AylaFriendRequest>[
              AylaFriendRequest(
                id: 'f1',
                fromUser: _u('u1', '小樱', online: true),
                message: '我是小樱，加个好友吧',
                status: 'pending',
              ),
            ],
          ),
          invites: AylaSocialPage<AylaGroupInvite>(
            items: <AylaGroupInvite>[
              AylaGroupInvite(
                id: 'i1',
                conversationTitle: '桌游小组',
                inviter: _u('u2', '阿澈'),
                status: 'pending',
              ),
            ],
          ),
          joinRequests: AylaSocialPage<AylaGroupJoinRequest>(
            items: <AylaGroupJoinRequest>[
              AylaGroupJoinRequest(
                id: 'j1',
                conversationTitle: '摄影交流',
                applicant: _u('u3', '林深', online: true),
                message: '想进来学习',
                status: 'pending',
              ),
            ],
          ),
        ),
      ),
      cell(
        '空态（暂无待处理认证消息）',
        const AylaRequestsPanel(),
      ),
      cell(
        '好友行（可点主体进会话 + 解除好友）',
        Column(
          spacing: AylaSpacing.sp2,
          children: <Widget>[
            AylaFriendRow(
              user: _u('u1', '小樱', online: true),
              online: true,
              onOpenChat: () {},
              onAvatarTap: () {},
              onRemove: () {},
            ),
            AylaFriendRow(
              user: _u('u4', '阿澈'),
              onOpenChat: () {},
              onRemove: () {},
              removing: true,
            ),
          ],
        ),
      ),
    ],
  );
}
