/// 群内桌游子界面 —— web `pages/group/GroupGames.tsx`（124 行）的等价物。
///
/// ## 逐条对应
/// | 本页 | web tsx |
/// |---|---|
/// | 群内房间目录（服务端 `group_id` 过滤 + 游标分页） | 20（`useDirectoryPage("game", {groupId})`） |
/// | 刷新后已入场卡片整批重播浮入 | 22–32（`useListEntryMotion` + `replayNonce`） |
/// | RefreshFAB 注册（引用守卫） | 35–42 |
/// | 上拉刷新只在滚动容器已到顶时响应 | 45（`hubRef.current.scrollTop <= 0`） |
/// | 同页创建/删除的本地事件触发重取 | 48–56 |
/// | 进房（先 join，失败保留原 is_member） | 58–63 + `GameRoomPlaceholder.tsx:99–119` |
/// | sticky 场景头 + 错误/加载/空/列表四分支 | 82–121 |
///
/// ## 机制差异（登记）
/// - web 的 `boardgame:room-created` / `room-deleted` 是两个 **window 自定义事件**
///   （同页创建后本地对账）；Flutter 侧由目录帧桥（`AylaRoomDirectoryBridge`）通过
///   [directoryEventsProvider] 广播同一语义 ⇒ 本页监听事件总线而不是 window。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api/boardgame_api.dart';
import '../core/models/game_room.dart' show AylaGameRoom;
import '../state/paged_list.dart';
import '../state/shell_state.dart' show ShellUiNotifier, shellUiProvider;
import '../theme/glass.dart' show AylaGlassButton, AylaGlassButtonVariant;
import '../theme/tokens.dart' show AylaSpacing;
import '../widgets/base/directory_load_more.dart' show AylaDirectoryLoadMore;
import '../widgets/base/media_interaction.dart' show AylaPullToRefresh;
import '../widgets/base/reveal.dart' show AylaRevealMotion, AylaRevealScope;
import '../widgets/game/game_room_card.dart' show AylaGameRoomCard;
import '../widgets/game/games_grid.dart'
    show AylaGamesGrid, AylaGamesGridSkeleton;
import '../widgets/group/group_scene.dart'
    show
        AylaGroupSceneHead,
        AylaGroupScenePlaceholder,
        AylaGroupScenePlaceholderRole,
        AylaGroupSceneStickyHead;
import 'game_support.dart' show AylaGameRoomHost;

class GroupGamesPage extends ConsumerStatefulWidget {
  const GroupGamesPage({super.key, required this.groupId, this.onExit});

  final String groupId;

  /// 「返回聊天」（空态键；web tsx 104–106）。
  final VoidCallback? onExit;

  @override
  ConsumerState<GroupGamesPage> createState() => _GroupGamesPageState();
}

class _GroupGamesPageState extends ConsumerState<GroupGamesPage> {
  AylaPagedList<AylaDirectoryGameEntry>? _pager;
  final ScrollController _scroll = ScrollController();
  ShellUiNotifier? _shell;
  Future<void> Function()? _refreshCallback;

  /// 当前房内房间 id（null = 列表）。
  String? _currentRoomId;

  int _replayNonce = 0;

  @override
  void initState() {
    super.initState();
    _pager = AylaPagedList<AylaDirectoryGameEntry>(
      request: (String? cursor) => AylaBoardgameApi.listGameRoomsPage(
        cursor: cursor,
        groupId: widget.groupId,
      ),
      keyOf: (AylaDirectoryGameEntry entry) => entry.card.id,
    )..addListener(_onChanged);
    unawaited(_pager!.load());
    _registerRefresh();
  }

  @override
  void dispose() {
    final ShellUiNotifier? notifier = _shell;
    final Future<void> Function()? callback = _refreshCallback;
    if (notifier != null && callback != null) {
      scheduleMicrotask(() => notifier.unregisterRefresh(callback));
    }
    _pager?.removeListener(_onChanged);
    _pager?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }


  void _registerRefresh() {
    final ShellUiNotifier notifier = ref.read(shellUiProvider.notifier);
    Future<void> callback() async {
      await _pager?.refresh();
      if (mounted) setState(() => _replayNonce += 1);
    }

    _shell = notifier;
    _refreshCallback = callback;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      notifier.registerRefresh(callback);
    });
  }

  Future<void> _refresh() async {
    await _pager?.refresh();
    if (mounted) setState(() => _replayNonce += 1);
  }

  bool _isAtTop() => !_scroll.hasClients || _scroll.position.pixels <= 0;

  /// 列表里已知的房间（web：`store.rooms.find(...)` 命中则不重复拉详情）。
  AylaGameRoom? _roomOf(String roomId) {
    for (final AylaDirectoryGameEntry entry
        in _pager?.items ?? const <AylaDirectoryGameEntry>[]) {
      if (entry.card.id == roomId) return entry.room;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final String? roomId = _currentRoomId;
    if (roomId != null) {
      return AylaGameRoomHost(
        key: ValueKey<String>(roomId),
        roomId: roomId,
        initialRoom: _roomOf(roomId),
        onExit: () {
          setState(() => _currentRoomId = null);
          unawaited(_refresh());
        },
      );
    }

    final AylaPagedList<AylaDirectoryGameEntry>? pager = _pager;

    Widget content;
    if (pager == null || (!pager.loaded && pager.loading)) {
      // tsx 94–99：两张骨架卡 + 跨列文案（`AylaGamesGridSkeleton` 即该结构）。
      content = const AylaGamesGridSkeleton();
    } else if (pager.error != null && pager.items.isEmpty) {
      // tsx 89–93：role="alert" + 错误文案 + ghost「重试」。
      content = AylaGroupScenePlaceholder(
        description: pager.error,
        role: AylaGroupScenePlaceholderRole.alert,
        expandHeight: false,
        actions: <Widget>[
          AylaGlassButton(
            label: '重试',
            variant: AylaGlassButtonVariant.ghost,
            onPressed: pager.loading ? null : () => unawaited(pager.refresh()),
          ),
        ],
      );
    } else if (pager.items.isEmpty) {
      // tsx 100–107：标题 / 描述 / ghost「返回聊天」。
      content = AylaGroupScenePlaceholder(
        title: '群内还没有桌游室',
        description: '建一个群内桌游室吧',
        expandHeight: false,
        actions: <Widget>[
          AylaGlassButton(
            label: '返回聊天',
            variant: AylaGlassButtonVariant.ghost,
            onPressed: widget.onExit,
          ),
        ],
      );
    } else {
      content = AylaPullToRefresh(
        isAtTop: _isAtTop,
        onRefresh: _refresh,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AylaRevealScope(
              replayKey: _replayNonce,
              // 卡片留白口径（问题 6 真根因）：web 群内用的是 **.group-games-grid**
              // （boardgame.css:254–259）—— 它**没有 padding 声明**（⇒ 0），且**恒 2 列**
              // （`repeat(2, 1fr)`；boardgame.css:239–243 的四列媒体查询只作用于
              // `.games-grid`）。左右留白**只由外层** `.group-page .group-games
              // { padding: var(--sp-4) }`（group.css:411–417，特异性 0-2-0 压过
              // boardgame.css:247–252 的 `sp3 sp4`）给。
              // ⇒ 本件默认的 `sp3 sp4` 若再叠一次，群内左右各多 16（实测 32，用户实报）。
              child: AylaGamesGrid(
                padding: EdgeInsets.zero,
                columns: 2,
                children: <Widget>[
                  for (int i = 0; i < pager.items.length; i += 1)
                    AylaGameRoomCard(
                      room: pager.items[i].card,
                      onEnter: () => setState(
                        () => _currentRoomId = pager.items[i].card.id,
                      ),
                      revealDelay: AylaRevealMotion.staggerDelay(i),
                    ),
                ],
              ),
            ),
            AylaDirectoryLoadMore(
              loading: pager.loading,
              error: pager.error,
              hasMore: pager.hasMore,
              invalidated: pager.invalidated,
              loadMore: pager.loadMore,
              refresh: pager.refresh,
            ),
          ],
        ),
      );
    }

    return AylaGroupSceneStickyHead(
      controller: _scroll,
      padding: const EdgeInsets.all(AylaSpacing.sp4),
      gap: AylaSpacing.sp4,
      head: const AylaGroupSceneHead(
        title: '群内桌游',
        description: '选择一个房间加入，或创建新的群内桌游室',
      ),
      child: content,
    );
  }
}
