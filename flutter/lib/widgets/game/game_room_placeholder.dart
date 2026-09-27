/// 进入桌游室后的占位整页壳。
///
/// ## 事实源
/// ```
/// GameRoomPlaceholder.tsx 132–187  结构：head（返回/名字/分享/收藏）+ body（说明 · 人数房主 ·
///                                  错误 · 房主控制 · 加入/离开）+ 删除确认弹窗
/// boardgame.css 136–141   .game-room-placeholder：height 100% · flex column · overflow hidden
/// …（逐条 CSS 对照 / 层叠推导**原文**见 `docs/flutter/17-组件文件头归档（整理前原文）.md` 的 `widgets/game/game_room_placeholder.dart` 一节）
/// ```
///
/// ## 机制差异
/// web 组件内直接调 boardgameApi（join/leave/成员操作/删除）并自持 latestRoom 与竞态守卫；
/// Flutter 侧按 live/voice 整页壳的既有范式（AylaLiveRoomBody / AylaVoiceRoomBody）：
/// **权威状态与请求全部注入**，组件只保留纯 UI 状态（删除确认弹窗开关）。
///
/// ## 公开面
/// `AylaGameRoomPlaceholder` · 样张 `aylaGameRoomPlaceholderSamples()`

library;

import 'package:flutter/material.dart';

import '../../core/models/game_room.dart';
import '../../core/models/user_public.dart';
import '../../core/models/visibility.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_theme.dart';
import '../../theme/buttons.dart' show AylaIconButton;
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import '../base/dialogs.dart' show AylaConfirmDialog;
import '../base/directory_controls.dart'
    show AylaDirectoryLoadMore, AylaFavoriteButton, AylaFavoriteState;
import '../base/reveal.dart';
import '../base/share.dart' show AylaShareButton;

/// .game-room-placeholder —— 进入桌游室后的占位界面（GameRoomPlaceholder.tsx）。
class AylaGameRoomPlaceholder extends StatefulWidget {
  const AylaGameRoomPlaceholder({
    super.key,
    required this.room,
    required this.onBack,
    this.narrow,
    this.onShare,
    this.onJoin,
    this.onLeave,
    this.onKickMember,
    this.onTransferOwner,
    this.onDeleteRoom,
    this.busy = false,
    this.error,
    this.currentUserId,
    this.isMember,
    this.isOwner,
    this.members = const <AylaGameRoomMember>[],
    this.membersLoading = false,
    this.membersError,
    this.membersHasMore = false,
    this.membersInvalidated = false,
    this.onLoadMoreMembers,
    this.onRefreshMembers,
    this.actionBusyUserId,
    this.favoriteState = AylaFavoriteState.unknown,
    this.favoriteBusy = false,
    this.favoriteError,
    this.onToggleFavorite,
    this.onRetryFavoriteStatus,
  });

  /// 房间数据（tsx room）。
  final AylaGameRoom room;

  /// 返回（tsx 135）。
  final VoidCallback onBack;

  /// 窄屏形态（≤768）：通栏 head（无圆角 / 无外边距 / 无阴影）；宽屏 = 卡片化 head。
  ///
  /// **库内同款惯例**：`AylaPrivateChatPane`（`narrow` 构造参数）、`AylaMessagesTabs`
  /// 的窄屏档都由**调用方注入**。null = 组件自行按 `MediaQuery` 视口判定（真机页面可省）。
  ///
  /// ⚠️ **画布 / `画布` 样张必须显式注入**：舞台是固定宽（375），而预览宿主注入的
  /// `MediaQuery` 视口宽可能仍是宿主宽 ⇒ 只读 MediaQuery 会把窄屏样张渲染成宽屏卡片档
  /// （实测「窄屏顶栏是没有圆角的」）。
  final bool? narrow;

  /// 分享（tsx 139–142：页面层构造 boardgameSharePayload 并打开分享弹窗）。
  final VoidCallback? onShare;

  /// 加入房间（tsx 182；页面层发请求 + 刷新房间）。
  final VoidCallback? onJoin;

  /// 离开房间（tsx 178；页面层发请求，成功后由页面层退出本页）。
  final VoidCallback? onLeave;

  /// 移出成员（tsx 157；参数 = 成员 user_id）。
  final ValueChanged<String>? onKickMember;

  /// 转让房主（tsx 158；参数 = 成员 user_id）。
  final ValueChanged<String>? onTransferOwner;

  /// 删除房间（确认弹窗 onConfirm 内部，tsx 167–173）。
  final VoidCallback? onDeleteRoom;

  /// 加入/离开进行中（禁用按钮 + 文案切换，tsx 31/178–184）。
  final bool busy;

  /// 错误文案（tsx 152）。
  final String? error;

  /// 当前用户 id（成员行排除自己 tsx 155；is_owner 的第二判据 tsx 35）。
  final String? currentUserId;

  /// 是否在房内；null → 用 [room] 的 isMember。
  final bool? isMember;

  /// 是否房主；null → room.isOwner || room.ownerId == currentUserId（tsx 35）。
  final bool? isOwner;

  /// 房主控制里的成员列表（web usePagedMediaList('game-members:…')，limit 20）。
  final List<AylaGameRoomMember> members;

  /// 成员分页状态（AylaDirectoryLoadMore 契约）。
  final bool membersLoading;
  final String? membersError;
  final bool membersHasMore;

  /// 成员列表在加载期间被更新（web membersInvalidated）。
  final bool membersInvalidated;

  /// 加载更多成员。
  final Future<void> Function()? onLoadMoreMembers;

  /// 重新拉取成员（invalidated 时自动调用，web refreshMembers）。
  final Future<void> Function()? onRefreshMembers;

  /// 成员操作进行中的用户 id（web actionBusy）：非 null ⇒ 两个操作键全部禁用。
  final String? actionBusyUserId;

  /// 收藏状态（AylaFavoriteButton 契约，tsx 143）。
  final AylaFavoriteState favoriteState;
  final bool favoriteBusy;
  final String? favoriteError;
  final ValueChanged<bool>? onToggleFavorite;
  final VoidCallback? onRetryFavoriteStatus;

  @override
  State<AylaGameRoomPlaceholder> createState() =>
      _AylaGameRoomPlaceholderState();
}

class _AylaGameRoomPlaceholderState extends State<AylaGameRoomPlaceholder> {
  /// 纯 UI 状态：删除确认弹窗（tsx 36 confirmDeleteOpen）。
  bool _confirmOpen = false;

  AylaGameRoom get _room => widget.room;

  /// tsx 35：room.is_owner || room.owner_id === currentUser?.id。
  bool get _isOwner =>
      widget.isOwner ??
      (_room.isOwner ||
          (widget.currentUserId != null &&
              _room.ownerId == widget.currentUserId));

  /// tsx 177：isMember（页面层可覆写为 join/leave 之后的即时值）。
  bool get _isMember => widget.isMember ?? _room.isMember;

  Future<void> _noop() async {}

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Column(
          children: <Widget>[
            _head(context),
            Expanded(child: _body(context)),
          ],
        ),
        // 删除确认（tsx 163–176）：web 走 createPortal(document.body)，
        // Flutter 侧由本组件的 Stack 顶层铺满承载（AylaConfirmDialog 自带遮罩层）。
        if (_confirmOpen)
          Positioned.fill(
            child: AylaConfirmDialog(
              title: '删除桌游房间',
              message: '确定删除桌游房间「${_room.name}」？此操作不可撤销。',
              onConfirm: () {
                setState(() => _confirmOpen = false);
                widget.onDeleteRoom?.call();
              },
              onClose: () => setState(() => _confirmOpen = false),
            ),
          ),
      ],
    );
  }

  /// head：窄屏通栏玻璃条 / 宽屏卡片（两档高度恒 64）。
  Widget _head(BuildContext context) {
    // 形态由调用方注入（[narrow]）；缺省才回退到视口判定（见 [narrow] 的注释）
    final bool narrow = widget.narrow ??
        AylaBreakpoints.isNarrow(MediaQuery.sizeOf(context).width);

    // 行内最高子项是 40 的返回键（.icon-btn-40）⇒ 行高恒 40，head 高恒 sp3×2 + 40 = 64
    final Widget sized = SizedBox(
      height: 40,
      child: Row(
        children: <Widget>[
          AylaIconButton(
            // tsx 135–137：.icon-btn-40 + IconBack 20
            icon: AylaIcon(aylaIconByName('iconBack')!, size: 20),
            onPressed: widget.onBack,
            semanticLabel: '返回', // tsx 135 aria-label
          ),
          const SizedBox(width: AylaSpacing.sp3), // gap: var(--sp-3)
          Expanded(
            child: Text(
              _room.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis, // text-overflow: ellipsis + nowrap
              style: const TextStyle(
                fontFamily: AylaFonts.display, // --font-display
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 18,
                color: AylaColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(width: AylaSpacing.sp3),
          AylaShareButton(
            label: '分享桌游室', // tsx 141
            onPressed: widget.onShare,
          ),
          const SizedBox(width: AylaSpacing.sp3),
          AylaFavoriteButton(
            state: widget.favoriteState,
            compact: true, // .favorite-toggle.is-compact
            busy: widget.favoriteBusy,
            actionError: widget.favoriteError,
            onToggle: widget.onToggleFavorite,
            onRetryStatus: widget.onRetryFavoriteStatus,
          ),
        ],
      ),
    );

    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final Widget content;
    if (narrow) {
      // ≤768：通栏玻璃条（--glass-bg + blur18 sat1.4 + 下边框，无圆角、无外边距）
      content = AylaGlassSurface(
        radiusOverride: BorderRadius.zero,
        borderOverride: const Border(
          bottom: BorderSide(color: AylaColors.glassBorder),
        ),
        blur: AylaGlass.blurNav,
        shadow: const <BoxShadow>[],
        padding: const EdgeInsets.symmetric(
          horizontal: AylaSpacing.sp4,
          vertical: AylaSpacing.sp3,
        ),
        child: sized,
      );
    } else {
      // ≥769：卡片化（margin --sidebar-gutter 12 + radius 16 + compact 阴影 + blur24 sat1.4）
      content = Padding(
        padding: const EdgeInsets.all(AylaSpacing.sidebarGutter),
        child: AylaGlassSurface(
          radius: AylaRadii.rCard,
          blur: AylaGlass.blurCard,
          shadow: AylaShadows.compact,
          padding: const EdgeInsets.symmetric(
            horizontal: AylaSpacing.sp4,
            vertical: AylaSpacing.sp3,
          ),
          child: sized,
        ),
      );
    }

    // auroraqua-panel-from-top：translate 0 -20px + fade，300ms --auroraqua-ease-out
    return AylaRevealItem(
      enabled: !reduceMotion,
      offset: const Offset(0, -20),
      duration: AylaDurations.auroraqua,
      curve: AylaCurves.auroraquaEaseOut,
      child: content,
    );
  }

  /// body：居中可滚内容区（justify-content: safe center 的 Flutter 等价）。
  Widget _body(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final String ownerName = _room.ownerDisplayName ?? '';

    final List<Widget> children = <Widget>[
      // tsx 146–148
      Text(
        '桌游玩法后续上线，当前为房间框架占位',
        textAlign: TextAlign.center,
        style: t.body.copyWith(
          fontSize: 14, // .game-room-placeholder-desc
          color: AylaColors.textSecondary,
        ),
      ),
      // tsx 149–151：「{member_count} 人 · 房主 {nickname || username}」
      Text(
        '${_room.memberCount} 人 · 房主 $ownerName',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: AylaFonts.utility, // --font-utility
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: 13,
          height: t.body.height,
          color: AylaColors.textPrimary,
        ),
      ),
      if ((widget.error ?? '').isNotEmpty)
        Text(
          widget.error!,
          textAlign: TextAlign.center,
          // .post-editor-error：13px · --destructive（tsx 152 复用该类）
          style: t.body.copyWith(fontSize: 13, color: AylaColors.destructive),
        ),
      if (_isOwner) _ownerControls(t),
      // tsx 177–185
      if (_isMember)
        AylaGlassButton(
          label: widget.busy ? '离开中…' : '离开房间',
          variant: AylaGlassButtonVariant.ghost,
          onPressed: widget.busy ? null : widget.onLeave,
        )
      else
        AylaGlassButton(
          label: widget.busy ? '加入中…' : '加入房间',
          variant: AylaGlassButtonVariant.primary,
          onPressed: widget.busy ? null : widget.onJoin,
        ),
    ];

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        return SingleChildScrollView(
          // overscroll-behavior: contain（不外溢到外层滚动链）
          child: ConstrainedBox(
            // safe center：内容不满一屏时居中，超出时可正常滚动
            constraints: BoxConstraints(minHeight: c.maxHeight),
            child: Padding(
              // padding: var(--sp-6)
              padding: const EdgeInsets.all(AylaSpacing.sp6),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                spacing: AylaSpacing.sp3, // gap: var(--sp-3)
                children: children,
              ),
            ),
          ),
        );
      },
    );
  }

  /// .game-room-owner-controls：房主控制（成员列表 + 删除房间）。
  Widget _ownerControls(AylaTextStyles t) {
    final bool actionDisabled = widget.actionBusyUserId != null; // tsx 157–158
    final List<AylaGameRoomMember> visible = <AylaGameRoomMember>[
      // tsx 155：过滤掉自己
      for (final AylaGameRoomMember m in widget.members)
        if (m.userId != widget.currentUserId) m,
    ];

    return Align(
      // width: min(100%, 680px) —— 父级是 align-items:center 的列，
      // Align 先松掉横向紧约束（否则 ConstrainedBox 会被紧父级夹回，13 号既有结论）
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, // flex column 默认 stretch
          mainAxisSize: MainAxisSize.min,
          spacing: AylaSpacing.sp3, // gap: var(--sp-3)
          children: <Widget>[
            Text(
              '房主控制', // tsx 154：<strong>
              textAlign: TextAlign.left, // .game-room-owner-controls { text-align: left }
              style: t.bodyStrong,
            ),
            for (final AylaGameRoomMember member in visible)
              _memberRow(t, member, actionDisabled),
            AylaDirectoryLoadMore(
              loading: widget.membersLoading,
              error: widget.membersError,
              hasMore: widget.membersHasMore,
              invalidated: widget.membersInvalidated,
              loadMore: widget.onLoadMoreMembers ?? _noop,
              refresh: widget.onRefreshMembers ?? _noop,
            ),
            // tsx 161：「删除房间」—— web 里父容器 stretch ⇒ 按钮全宽
            AylaGlassButton(
              label: '删除房间',
              variant: AylaGlassButtonVariant.destructive,
              expand: true,
              onPressed: () => setState(() => _confirmOpen = true),
            ),
          ],
        ),
      ),
    );
  }

  /// .game-room-member-action：成员行（名字 + 移出 / 转让房主）。
  Widget _memberRow(
    AylaTextStyles t,
    AylaGameRoomMember member,
    bool disabled,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AylaSpacing.sp2), // padding: sp2 0
      child: Row(
        spacing: AylaSpacing.sp2, // gap: var(--sp-2)
        children: <Widget>[
          Expanded(
            // span：flex 1 1 120px + overflow-wrap: anywhere
            child: Text(
              member.displayName ?? '', // tsx 156：nickname || username
              style: t.body,
            ),
          ),
          AylaGlassButton(
            label: '移出', // tsx 157
            variant: AylaGlassButtonVariant.ghost,
            onPressed: disabled
                ? null
                : () => widget.onKickMember?.call(member.userId),
          ),
          AylaGlassButton(
            label: '转让房主', // tsx 158
            variant: AylaGlassButtonVariant.ghost,
            onPressed: disabled
                ? null
                : () => widget.onTransferOwner?.call(member.userId),
          ),
        ],
      ),
    );
  }
}

// ======================= 样张 =======================

/// 桌游室占位整页壳样张。
///
/// 覆盖：房主（成员控制 + 删除确认）/ 非成员（加入房间）/ 窄屏 375 档（通栏 head）。
Widget aylaGameRoomPlaceholderSamples() => const _GameRoomPlaceholderDemo();

class _GameRoomPlaceholderDemo extends StatefulWidget {
  const _GameRoomPlaceholderDemo();

  @override
  State<_GameRoomPlaceholderDemo> createState() =>
      _GameRoomPlaceholderDemoState();
}

class _GameRoomPlaceholderDemoState extends State<_GameRoomPlaceholderDemo> {
  String _log = '—';

  static const AylaUserPublic _alice =
      AylaUserPublic(id: 'u1', nickname: '爱莉', username: 'elysia');
  static const AylaUserPublic _bob =
      AylaUserPublic(id: 'u2', username: 'bob_the_builder');
  static const AylaUserPublic _carol =
      AylaUserPublic(id: 'u3', nickname: '卡罗尔');

  static const AylaGameRoom _room = AylaGameRoom(
    id: 7,
    name: '爱莉的桌游室',
    owner: _alice,
    ownerId: 'u1',
    status: AylaGameRoomStatus.waiting,
    visibility: AylaPostVisibility.public,
    memberCount: 3,
    isOwner: true,
    isMember: true,
  );

  static const List<AylaGameRoomMember> _members = <AylaGameRoomMember>[
    AylaGameRoomMember(id: 1, userId: 'u1', user: _alice, seat: 0),
    AylaGameRoomMember(id: 2, userId: 'u2', user: _bob, seat: 1),
    AylaGameRoomMember(id: 3, userId: 'u3', user: _carol, seat: 2),
  ];

  void _say(String what) => setState(() => _log = what);

  Widget _stage({
    required String title,
    required double width,
    required double height,
    required Widget child,
    bool narrow = false,
  }) {
    final Widget framed = SizedBox(
      width: width,
      height: height,
      // ⚠️ 舞台**不裁圆角**：窄屏 head 是通栏方角（web 无 radius），裁圆角会让它看起来像卡片
      //    （实测「窄屏顶栏是没有圆角的」）；弹窗样张的遮罩也要铺满舞台。
      child: narrow
          ? MediaQuery(
              data: MediaQueryData(size: Size(width, height)),
              child: child,
            )
          : child,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: AylaSpacing.sp2,
      children: <Widget>[
        Text(title, style: const TextStyle(fontSize: 11)),
        framed,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: AylaSpacing.sp4,
      children: <Widget>[
        Text('最近操作：$_log', style: const TextStyle(fontSize: 12)),
        Wrap(
          spacing: AylaSpacing.sp6,
          runSpacing: AylaSpacing.sp6,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: <Widget>[
            _stage(
              title: '宽屏 900×620 · 房主（成员控制 + 删除房间）',
              width: 900,
              height: 620,
              child: AylaGameRoomPlaceholder(
                room: _room,
                narrow: false,
                currentUserId: 'u1',
                onBack: () => _say('返回'),
                onShare: () => _say('分享'),
                members: _members,
                membersHasMore: true,
                onLoadMoreMembers: () async => _say('加载更多成员'),
                onRefreshMembers: () async => _say('刷新成员'),
                onKickMember: (String id) => _say('移出 $id'),
                onTransferOwner: (String id) => _say('转让 $id'),
                onDeleteRoom: () => _say('删除房间'),
                onLeave: () => _say('离开房间'),
              ),
            ),
            _stage(
              title: '宽屏 900×620 · 非成员（加入房间）',
              width: 900,
              height: 620,
              child: const AylaGameRoomPlaceholder(
                narrow: false,
                room: AylaGameRoom(
                  id: 8,
                  name: '别人的桌游室',
                  owner: _bob,
                  ownerId: 'u2',
                  status: AylaGameRoomStatus.playing,
                  visibility: AylaPostVisibility.friends,
                  memberCount: 2,
                ),
                currentUserId: 'u1',
                onBack: _noopBack,
              ),
            ),
            _stage(
              title: '窄屏 375×700 · 成员（通栏 head）',
              width: 375,
              height: 700,
              narrow: true,
              child: const AylaGameRoomPlaceholder(
                narrow: true,
                room: AylaGameRoom(
                  id: 9,
                  name: '深夜局',
                  owner: _carol,
                  ownerId: 'u3',
                  status: AylaGameRoomStatus.waiting,
                  memberCount: 2,
                  isMember: true,
                ),
                currentUserId: 'u1',
                onBack: _noopBack,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

void _noopBack() {}
