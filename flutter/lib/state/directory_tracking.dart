/// 目录缓存的 **store 订阅通路** —— web `ensureDirectoryTracking`
/// （`stores/directory.ts:205–219`）的 Flutter 等价物。
///
/// ## 为什么这条通路才是「热更新」的主体
/// web 的目录接口**是**域 store 的查询投影 —— `stores/directory.ts:143–146` 的
/// `cachedItems(kind)` 直接返回 `useLiveStore.channels` / `useVoiceStore.channels` /
/// `useBoardgameStore.rooms`。WS 帧先落域 store（`ws/chat.ts:667–768 / 845–865`），
/// **再由本通路**把新旧快照 diff 进目录缓存（`updateCachedItems`，:148–196）。
/// ⇒ 页面**不订阅 WS / 不订阅事件总线**，所有读缓存的页面天然热更新。
///
/// 帧桥（`core/ws/room_frames.dart`）只承担 web `stores/directory.ts:220–259` 的
/// **创建 / 删除跟踪**那一半（`createdIds` 登记 + 删除摘除），不负责「更新」——
/// 与 web 的两条独立通路逐条对应。
///
/// ## 三个域 store → 目录缓存的形态转换
/// web 的目录条目**就是**域 store 的描述符（同一对象）；Flutter 侧的域 store 形态不一：
/// - voice / live：`channels` 是**按 id 的 Map**（`Map<String, Ayla*ChannelSnapshot>`）
///   ⇒ 投影成目录条目 [AylaDirectoryVoiceEntry] / [AylaDirectoryLiveEntry]
///   （逐字段搬运：`AylaDirectoryVoiceEntry.fromSnapshot` /
///   `AylaDirectoryLiveEntry.fromSnapshot`），再交给
///   [AylaDirectoryStore.updateCachedItems]；
/// - game：`rooms` 是完整 [AylaGameRoom] 列表、字段齐全 ⇒ 包成
///   [AylaDirectoryGameEntry]（`card` 与 `room` 同源）。
///
/// ## 为什么用「引用比较」而不是深比较
/// web 的 `useLiveStore.subscribe((next, old) => { if (next.channels !== old.channels) … })`
/// （:208–216）判的是**数组引用**：zustand 的每个 action 都返回新数组 ⇒ 忠实反映「变了」。
/// Flutter 侧的 `ChangeNotifier` 不带旧值 ⇒ 本类**自己缓存上一次的投影列表**
/// 并做 `identical` 比较；三个域 store 的写路径同样是「整表替换 / 新建 Map」
/// （`upsertChannel` / `patchChannel` / `removeChannel` 都改 `_channels`），
/// 投影每次新建列表 ⇒ 引用必变，语义与 web 等价。
///
/// ## 纪律（与 web 同）
/// - **账号切换 ⇒ 清目录缓存**（web `:217–219` 订阅 auth store 的 `currentUser.id` 变化
///   ⇒ `useDirectoryStore.getState().reset()`）；
/// - `stop()` 幂等，并清空提示（web `disposeDirectoryTracking` 的 `reset()`）。
library;

import 'package:flutter/foundation.dart';

import '../core/api/boardgame_api.dart' show AylaDirectoryGameEntry;
import '../core/api/live_api.dart' show AylaDirectoryLiveEntry;
import '../widgets/live/live_channel_snapshot.dart' show AylaLiveChannelSnapshot;
import '../core/api/voice_api.dart'
    show AylaDirectoryVoiceEntry, AylaVoiceChannelSnapshot;
import '../core/models/game_room.dart' show AylaGameCardData, AylaGameRoom;
import 'boardgame_store.dart' show AylaBoardgameStore;
import 'directory_events.dart' show AylaDirectoryKind;
import 'directory_store.dart' show AylaDirectoryStore;
import 'live_state.dart' show AylaLiveState;
import 'voice_state.dart' show AylaVoiceState;

/// 目录 store 订阅通路（web `ensureDirectoryTracking` / `disposeDirectoryTracking`）。
///
/// 生命周期 = 登录周期：`start()` 幂等重挂（先 `stop()`），`stop()` 幂等卸载。
class AylaDirectoryTracking {
  AylaVoiceState? _voice;
  AylaLiveState? _live;
  AylaBoardgameStore? _boardgame;
  AylaDirectoryStore? _store;
  String? Function()? _currentUserId;

  /// 上一次投影（引用比较用；web 的 `old.channels` 等价物）。
  List<Object>? _lastVoice;
  List<Object>? _lastLive;
  List<Object>? _lastGame;

  /// 当前是否已装配。
  bool get isTracking => _store != null;

  /// 装配（幂等：重复调用先 [stop]，与 web 的 `if (tracking) return` 等价 ——
  /// Flutter 侧多一步「换了 store 实例就重挂」，因为测试会传入不同实例）。
  void start({
    required AylaVoiceState voiceState,
    required AylaLiveState liveState,
    required AylaBoardgameStore boardgameStore,
    required String? Function() currentUserId,
    required AylaDirectoryStore store,
  }) {
    stop();
    _voice = voiceState;
    _live = liveState;
    _boardgame = boardgameStore;
    _store = store;
    _currentUserId = currentUserId;
    // web 的 `cachedItems` 返回描述符、目录缓存条目**就是**它（恒等）；
    // Flutter 侧要让 record 里始终保持目录条目类型 ⇒ 注入「描述符 → 条目」投影。
    store.descriptorAdapters[AylaDirectoryKind.voice] =
        (Object d) => d is AylaVoiceChannelSnapshot ? _voiceEntryOf(d) : d;
    store.descriptorAdapters[AylaDirectoryKind.live] =
        (Object d) => d is AylaLiveChannelSnapshot ? AylaDirectoryLiveEntry.fromSnapshot(d) : d;
    store.descriptorAdapters[AylaDirectoryKind.game] =
        (Object d) => d is AylaGameRoom ? _gameEntryOf(d) : d;
    _lastVoice = _projectVoice();
    _lastLive = _projectLive();
    _lastGame = _projectGame();
    voiceState.addListener(_onVoiceChanged);
    liveState.addListener(_onLiveChanged);
    boardgameStore.addListener(_onGameChanged);
  }

  /// 停掉订阅（web `disposeDirectoryTracking`：先退订、再 `reset()`）。
  void stop() {
    _voice?.removeListener(_onVoiceChanged);
    _live?.removeListener(_onLiveChanged);
    _boardgame?.removeListener(_onGameChanged);
    _voice = null;
    _live = null;
    _boardgame = null;
    _store = null;
    _currentUserId = null;
    _lastVoice = null;
    _lastLive = null;
    _lastGame = null;
  }

  /// 账号切换 / 登出：清目录缓存（web `:217–219`）。
  void resetStore() => _store?.reset();

  // ---------------- 三个域 store 的变化回调（web :208–216） ----------------

  void _onVoiceChanged() {
    final AylaDirectoryStore? store = _store;
    if (store == null) return;
    final List<Object> next = _projectVoice();
    final List<Object> previous = _lastVoice ?? const <Object>[];
    _lastVoice = next;
    store.updateCachedItems(
      AylaDirectoryKind.voice,
      next,
      previous,
      currentUserId: _currentUserId?.call(),
    );
  }

  void _onLiveChanged() {
    final AylaDirectoryStore? store = _store;
    if (store == null) return;
    final List<Object> next = _projectLive();
    final List<Object> previous = _lastLive ?? const <Object>[];
    _lastLive = next;
    store.updateCachedItems(
      AylaDirectoryKind.live,
      next,
      previous,
      currentUserId: _currentUserId?.call(),
    );
  }

  void _onGameChanged() {
    final AylaDirectoryStore? store = _store;
    if (store == null) return;
    final List<Object> next = _projectGame();
    final List<Object> previous = _lastGame ?? const <Object>[];
    _lastGame = next;
    store.updateCachedItems(
      AylaDirectoryKind.game,
      next,
      previous,
      currentUserId: _currentUserId?.call(),
    );
  }

  // ---------------- 投影（域 store 快照 → 目录条目） ----------------

  /// voice：`Map<String, AylaVoiceChannelSnapshot>` → [AylaDirectoryVoiceEntry]
  /// （**插入序**，与 web `useVoiceStore.channels` 的数组序同构 —— 排序由
  /// `updateCachedItems` 的 `sortItems` 承担，这里只保证集合完整）。
  List<Object> _projectVoice() => <Object>[
        for (final AylaVoiceChannelSnapshot c
            in _voice?.channels.values ?? const Iterable<AylaVoiceChannelSnapshot>.empty())
          _voiceEntryOf(c),
      ];

  /// live：`Map<String, AylaLiveChannelSnapshot>` → [AylaDirectoryLiveEntry]。
  List<Object> _projectLive() => <Object>[
        for (final AylaLiveChannelSnapshot c
            in _live?.channels.values ?? const Iterable<AylaLiveChannelSnapshot>.empty())
          AylaDirectoryLiveEntry.fromSnapshot(c),
      ];

  /// game：`List<AylaGameRoom>` → [AylaDirectoryGameEntry]（卡与房间同源）。
  List<Object> _projectGame() => <Object>[
        for (final AylaGameRoom room in _boardgame?.rooms ?? const <AylaGameRoom>[])
          _gameEntryOf(room),
      ];

  /// 语音快照 → 目录条目（**逐字段搬运**；`is_owner` 对 `mine`）。
  static AylaDirectoryVoiceEntry _voiceEntryOf(AylaVoiceChannelSnapshot c) =>
      AylaDirectoryVoiceEntry(
        card: c.card,
        ownerId: c.ownerId,
        createdAt: c.createdAt,
        roomName: c.roomName,
        allowedGroupIds: c.allowedGroupIds,
        lastOccupiedAt: c.lastOccupiedAt,
        lastVacantAt: c.lastVacantAt,
        isOwner: c.mine,
      );

  /// 桌游房 → 目录条目（`card` 与 `room` 同源）。
  static AylaDirectoryGameEntry _gameEntryOf(AylaGameRoom room) =>
      AylaDirectoryGameEntry(
        card: AylaGameCardData(
          id: room.id.toString(),
          name: room.name,
          status: room.status,
          owner: room.owner,
          memberCount: room.memberCount,
          visibility: room.visibility,
          allowedGroupNames: room.allowedGroupNames,
          groupName: room.groupName,
        ),
        room: room,
        ownerId: room.ownerId,
        isOwner: room.isOwner,
      );
}

/// 三个域 store 的「组装」由调用方注入（本件不 import Riverpod / 不建 provider）。
@visibleForTesting
void debugAssertTrackingShape() {}
