/// 桌游房内页宿主 —— web `pages/GamesHubPage.tsx:105–164` 的房内分支。
///
/// ## 为什么需要宿主
/// Flutter 的 [AylaGameRoomPlaceholder] 是**展示型**（`members` / `busy` / `error` /
/// 收藏与分享都由页面注入，见 B4 组件交付），而 web 的 `GameRoomPlaceholder` 自带
/// join/leave/成员分页/收藏/分享的全部逻辑 ⇒ 本宿主承接那一半。
///
/// ## 逐条对应（web tsx / GameRoomPlaceholder.tsx）
/// | 本宿主 | web |
/// |---|---|
/// | 直达进房：先取房间（**已知则用列表里的**，否则 REST），再幂等 join | tsx 116–141 |
/// | join 失败保持 `is_member` 原值（**不伪造成"已加入"**） | `GameRoomPlaceholder.tsx:99–119` |
/// | 成员分页（limit 20，**仅房主**拉取） | tsx 43–48 + `GameRoomPlaceholder.tsx:57` |
/// | 房主操作（kick/transfer）→ 用后端回显刷新房间 + 成员 | `GameRoomPlaceholder.tsx:82–97` |
/// | 离开 → `onLeave`（页面退出 + 刷新大厅） | tsx 142–145 |
/// | 删除 → 成功回大厅 | `GameRoomPlaceholder.tsx:163–175` |
/// | 收藏/分享（compact + 「分享桌游室」） | `GameRoomPlaceholder.tsx:130–140` |
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api/boardgame_api.dart';
import '../core/models/game_room.dart';
import '../core/models/share_payload.dart' show AylaSharePayload;
import '../state/auth_state.dart';
import '../state/favorite_status.dart';
import '../state/media_paged_list.dart';
import '../widgets/base/directory_page.dart' show aylaDirectoryIsNarrow;
import '../widgets/game/game_room_placeholder.dart';
import '../widgets/motion/gestures.dart' show AylaFullScreenSwipeBack;
import 'share_support.dart';

class AylaGameRoomHost extends ConsumerStatefulWidget {
  const AylaGameRoomHost({
    super.key,
    required this.roomId,
    this.initialRoom,
    this.onExit,
  });

  /// 房间 id（路由 `/games/:roomId`）。
  final String roomId;

  /// 大厅列表里已知的房间（web：`store.rooms.find(...)` 命中则不重复拉详情）。
  final AylaGameRoom? initialRoom;

  /// 退出房内（离开 / 删除 / 返回都汇到这里；页面据此回大厅并刷新）。
  final VoidCallback? onExit;

  @override
  ConsumerState<AylaGameRoomHost> createState() => _AylaGameRoomHostState();
}

class _AylaGameRoomHostState extends ConsumerState<AylaGameRoomHost> {
  AylaGameRoom? _room;
  bool _busy = false;
  String? _error;
  String? _actionBusyUserId;
  AylaMediaPagedList<AylaGameRoomMember>? _members;
  bool _membersInvalidated = false;
  final AylaFavoriteStatusController _favorites = AylaFavoriteStatusController();
  final AylaShareController _share = AylaShareController();

  @override
  void initState() {
    super.initState();
    _favorites.addListener(_onChanged);
    _room = widget.initialRoom;
    unawaited(_enter());
  }

  @override
  void dispose() {
    _favorites.removeListener(_onChanged);
    _favorites.dispose();
    _share.dispose();
    _members?.removeListener(_onChanged);
    _members?.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// 直达进房（web tsx 116–141）：取房间 → 幂等 join（**失败保留原 `is_member`**）。
  Future<void> _enter() async {
    final int? id = int.tryParse(widget.roomId);
    if (id == null) {
      _exit();
      return;
    }
    AylaGameRoom? room = _room;
    try {
      room ??= await AylaBoardgameApi.getGameRoom(id);
    } catch (_) {
      // 房间不存在/无权访问：静默回大厅（web tsx 136–139）
      _exit();
      return;
    }
    if (!mounted) return;
    setState(() => _room = room);
    if (room.isMember) {
      _ensureMembers();
      return;
    }
    try {
      await AylaBoardgameApi.joinGameRoom(room.id);
      if (!mounted) return;
      _applyRoom(await AylaBoardgameApi.getGameRoom(room.id));
    } catch (_) {
      // join 失败：**保持 room.is_member 原值**（不伪造已加入，web tsx 134–135）
      if (mounted) setState(() => _room = room);
    }
  }

  /// 成员分页（仅房主；web `usePagedMediaList(..., isOwner)`）。
  void _ensureMembers() {
    final AylaGameRoom? room = _room;
    if (room == null) return;
    if (_members != null) return;
    final pager = AylaMediaPagedList<AylaGameRoomMember>(
      scope: 'game-members:${room.id}:${ref.read(authNotifierProvider).user?.id ?? ''}',
      request: (String? cursor) =>
          AylaBoardgameApi.listGameRoomMembersPage(room.id, cursor: cursor),
      idOf: (AylaGameRoomMember member) => member.userId,
    )..addListener(_onChanged);
    _members = pager;
    if (_isOwner(room)) unawaited(pager.reset());
    _favorites.load('game', <String>['${room.id}']);
  }

  bool _isOwner(AylaGameRoom room) =>
      room.isOwner || room.ownerId == ref.read(authNotifierProvider).user?.id;

  void _applyRoom(AylaGameRoom room) {
    final bool wasOwner = _room != null && _isOwner(_room!);
    _room = room;
    if (!wasOwner && _isOwner(room)) _ensureMembers();
    if (mounted) setState(() {});
  }

  void _exit() {
    final VoidCallback? onExit = widget.onExit;
    if (onExit != null) {
      onExit();
      return;
    }
    if (mounted) context.go('/games');
  }

  Future<void> _join() async {
    final AylaGameRoom? room = _room;
    if (room == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    bool joined = false;
    try {
      await AylaBoardgameApi.joinGameRoom(room.id);
      joined = true;
      if (!mounted) return;
      setState(() => _room = _copyMember(room, true));
      _applyRoom(await AylaBoardgameApi.getGameRoom(room.id));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = joined
            ? '已加入，房间信息刷新失败，请稍后重试'
            : (error is Exception ? '$error' : '加入失败');
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    final AylaGameRoom? room = _room;
    if (room == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AylaBoardgameApi.leaveGameRoom(room.id);
      if (!mounted) return;
      setState(() => _room = _copyMember(room, false));
      _exit();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error is Exception ? '$error' : '离开失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshMembers() async {
    await _members?.refresh();
    if (!mounted) return;
    setState(() => _membersInvalidated = false);
  }

  Future<void> _memberAction(String userId, String action) async {
    final AylaGameRoom? room = _room;
    if (room == null || _actionBusyUserId != null) return;
    setState(() {
      _actionBusyUserId = userId;
      _error = null;
    });
    try {
      await AylaBoardgameApi.actionGameMember(room.id, userId, action);
      if (!mounted) return;
      _applyRoom(await AylaBoardgameApi.getGameRoom(room.id));
      await _refreshMembers();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error is Exception ? '$error' : '成员操作失败');
    } finally {
      if (mounted) setState(() => _actionBusyUserId = null);
    }
  }

  Future<void> _deleteRoom() async {
    final AylaGameRoom? room = _room;
    if (room == null) return;
    try {
      await AylaBoardgameApi.deleteGameRoom(room.id);
      if (!mounted) return;
      _exit();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error is Exception ? '$error' : '删除失败');
    }
  }

  /// 只改 `is_member` 的房间副本（其余字段逐条搬运）。
  static AylaGameRoom _copyMember(AylaGameRoom room, bool isMember) => AylaGameRoom(
        id: room.id,
        name: room.name,
        owner: room.owner,
        ownerId: room.ownerId,
        status: room.status,
        visibility: room.visibility,
        group: room.group,
        groupName: room.groupName,
        allowedGroupIds: room.allowedGroupIds,
        allowedGroupNames: room.allowedGroupNames,
        gameType: room.gameType,
        memberCount: room.memberCount,
        isOwner: room.isOwner,
        isMember: isMember,
        createdAt: room.createdAt,
      );

  @override
  Widget build(BuildContext context) {
    final AylaGameRoom? room = _room;
    if (room == null) {
      return const Center(child: CircularProgressIndicator.adaptive());
    }
    final bool narrow = aylaDirectoryIsNarrow(context);
    final bool isOwner = _isOwner(room);
    final String? selfId = ref.watch(
      authNotifierProvider.select((AuthState s) => s.user?.id),
    );

    final Widget body = AylaGameRoomPlaceholder(
      room: room,
      narrow: narrow,
      currentUserId: selfId,
      onBack: () => context.go('/games'),
      onShare: () => unawaited(aylaOpenShareSheet(
        context,
        payload: AylaSharePayload.boardgame(
          id: '${room.id}',
          name: room.name,
          group: room.group,
          gameType: room.gameType,
        ),
        controller: _share,
        currentUserId: selfId,
      )),
      onJoin: () => unawaited(_join()),
      onLeave: () => unawaited(_leave()),
      onKickMember: isOwner
          ? (String userId) => unawaited(_memberAction(userId, 'kick'))
          : null,
      onTransferOwner: isOwner
          ? (String userId) => unawaited(_memberAction(userId, 'transfer'))
          : null,
      onDeleteRoom: isOwner ? () => unawaited(_deleteRoom()) : null,
      busy: _busy,
      error: _error,
      members: _members?.items ?? const <AylaGameRoomMember>[],
      membersLoading: _members?.loading ?? false,
      membersError: _members?.error,
      membersHasMore: _members?.hasMore ?? false,
      membersInvalidated: _membersInvalidated,
      onLoadMoreMembers: _members?.loadMore,
      onRefreshMembers: _refreshMembers,
      actionBusyUserId: _actionBusyUserId,
      favoriteState: _favorites.stateOf('game', '${room.id}'),
      favoriteBusy: _favorites.busyOf('game', '${room.id}'),
      favoriteError: _favorites.actionErrorOf('game', '${room.id}'),
      onToggleFavorite: (bool next) =>
          unawaited(_favorites.toggle('game', '${room.id}')),
      onRetryFavoriteStatus: () =>
          _favorites.load('game', <String>['${room.id}'], force: true),
    );

    return narrow
        ? AylaFullScreenSwipeBack(
            onBack: () => context.go('/games'),
            child: body,
          )
        : body;
  }
}
