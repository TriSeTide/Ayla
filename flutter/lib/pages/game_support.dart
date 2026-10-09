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
///
/// ⚠️ **根因 B（2026-10-09 修）**：收藏键此前只支持注入档，而本宿主的
/// `_favorites.load('game', …)` 写在 `_ensureMembers()` 里 —— 后者**只有房主**
/// 才会走到（`room.isMember` 分支 + `_applyRoom` 的 `!wasOwner && _isOwner` 判定）
/// ⇒ **非房主/普通成员进房时收藏状态从未加载**，收藏键永远 `unknown`
/// （禁用 +「正在加载收藏状态」，用户实报）。
/// web 侧根本没有这条接线：`GameRoomPlaceholder.tsx:143` 只写
/// `<FavoriteButton targetType="game" targetId={room.id} compact />`，
/// 加载由收藏键自己承担（`FavoriteButton.tsx:22` → `useFavoriteStatuses.ts:12–16`）
/// ⇒ 本次同样改为**自给自足档**，与成员分页逻辑彻底解耦。
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

  /// 收藏状态控制器 = **库内共享单例**（web `favoriteStatus.ts:17` 的模块级 store）。
  ///
  /// ⚠️ 不 dispose：单例跟随进程生命周期（与 web 模块级 store 同），页面卸载只
  /// `removeListener`。用私有实例会让收藏页的「取消收藏」对账（`applyFavoriteStatus`）
  /// 写进一个没人读的缓存 —— web 会广播给全部挂载键（`favoriteStatus.ts:50–61`）。
  final AylaFavoriteStatusController _favorites =
      aylaSharedFavoriteStatusController;
  final AylaShareController _share = AylaShareController();

  /// 收藏状态键（与 [AylaGameRoomPlaceholder] 的 `favoriteState` 取值**同一口径**）。
  static String _favKey(AylaGameRoom room) => '${room.id}';

  /// 收藏状态加载（web `GameRoomPlaceholder.tsx:143` 的
  /// `<FavoriteButton targetType="game" targetId={room.id}/>` ⇒ 键自己 load）。
  ///
  /// ⚠️ **根因 B**：此前这行写在 `_ensureMembers()` 里，而后者**只有房主**可达
  /// （`room.isMember` 分支 + `_applyRoom` 的 `!wasOwner && _isOwner` 判定）
  /// ⇒ 非房主/普通成员进房时收藏状态从未加载 ⇒ 收藏键永远 `unknown`（禁用）。
  /// 现在挂在**拿到 room 的所有路径**上，与成员分页彻底解耦。
  void _ensureFavoriteStatus(AylaGameRoom room) {
    unawaited(_favorites.load('game', <String>[_favKey(room)]));
  }

  @override
  void initState() {
    super.initState();
    _favorites.addListener(_onChanged);
    _room = widget.initialRoom;
    // 已知 room（大厅列表带过来的）⇒ 帧后加载。
    // ⚠️ 必须帧后：`load` 会同步 `notifyListeners`，build 期发会触发
    // "setState() or markNeedsBuild() called during build"（本项目既有实测）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final AylaGameRoom? room = _room;
      if (room != null) _ensureFavoriteStatus(room);
    });
    unawaited(_enter());
  }

  @override
  void dispose() {
    _favorites.removeListener(_onChanged);
    // ⚠️ **不 dispose**：`_favorites` 是库内共享单例（web 模块级 store）。
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
    _ensureFavoriteStatus(room); // 根因 B：拿到 room 就加载（不分房主/成员）
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
    // ⚠️ 收藏状态**不再**在这里加载（原根因 B：本函数仅房主可达）
    // ⇒ 见 [_ensureFavoriteStatus]，挂在所有拿到 room 的路径上。
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
      favoriteState: _favorites.stateOf('game', _favKey(room)),
      favoriteBusy: _favorites.busyOf('game', _favKey(room)),
      favoriteError: _favorites.actionErrorOf('game', _favKey(room)),
      onToggleFavorite: (bool next) =>
          unawaited(_favorites.toggle('game', _favKey(room))),
      onRetryFavoriteStatus: () => _favorites.load(
        'game',
        <String>[_favKey(room)],
        force: true,
      ),
    );

    return narrow
        ? AylaFullScreenSwipeBack(
            onBack: () => context.go('/games'),
            child: body,
          )
        : body;
  }
}
