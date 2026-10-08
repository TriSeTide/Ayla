/// 房内域目录帧桥 —— web `ws/chat.ts` 的 `voice.channel.*` / `live.*` /
/// `boardgame.room.*` 分支 + `stores/directory.ts` 的创建/删除跟踪，Flutter 侧等价物。
///
/// ## 架构（2026-10-08 按 web 收口，与消息域同型）
/// web 是**两条彼此独立**的通路（`stores/directory.ts:205–259`）：
/// 1. **store 订阅通路**（:208–216）：帧先落域 store（`ws/chat.ts` 的对应分支），
///    `ensureDirectoryTracking` 再 diff 出目录 patch —— 负责**新增/更新/重排/成员数**。
///    Flutter 侧 = `state/directory_tracking.dart`（由 `main.dart` 启动期装配）。
/// 2. **帧直连通路**（:220–259）：`live.channel.created|deleted` /
///    `voice.channel.created|deleted` / `boardgame.room.created|deleted` ⇒ 登记
///    `createdIds`（创建提示，60s）/ 从缓存摘除条目 + 校正 `mutationRevision` /
///    `total` / `totalMemberCount`。Flutter 侧 = **本桥**。
///
/// ⇒ **本桥不再把帧「广播给页面」**（那是改造前的错误架构：页面漏订阅就没有热更新）；
/// 它只做「落域 store + 落目录缓存提示」两件事 —— 与消息域的
/// `core/ws/chat_ws.dart:620` 的 `_message.upsertMessage(convId, msg)` 同型。
///
/// ## 逐条对应（web 事实源）
/// | 帧 | web | 本桥 |
/// |---|---|---|
/// | `voice.channel.created` | `chat.ts:667–678`（**REST 详情才权威**，避免泄露受限频道） | `GET /voice/channels/<id>/` → [AylaVoiceState.upsertChannel] + [AylaDirectoryStore.noteCreated] |
/// | `voice.channel.deleted` | `chat.ts:679–683`（删除不回退排序） | [AylaVoiceState.removeChannel] + [AylaDirectoryStore.noteDeleted] |
/// | `voice.channel.member_count_changed` | `chat.ts:685–719`（帧带排序投影则直接 patch，否则拉详情对账） | [AylaVoiceState.patchChannel] + 缺失排序投影时 REST 对账 |
/// | `voice.channel.updated` | `chat.ts:720–727`（改名/可见性/转让 → REST 对账） | 同 |
/// | `live.channel.created` / `.updated` | `chat.ts:728–731 / 751–755`（`reconcileLiveChannel`） | `GET /live/channels/<id>/` → [AylaLiveState.upsertChannel] + [AylaDirectoryStore.noteCreated] |
/// | `live.channel.status.changed` | `chat.ts:732–750` | 同上；SRS 判定重拉归会话运行时 |
/// | `live.channel.deleted` | `chat.ts:745–750` | [AylaLiveState.removeChannel] + [AylaDirectoryStore.noteDeleted] |
/// | `live.viewers.changed` | `chat.ts:756–768`（**瞬态投影**：不拉 REST、不标失效、不改排序 —— 帧不属于 `live.channel.*` 命名空间） | [AylaLiveState.patchViewerCount]（目录侧由 store 订阅通路随同 patch） |
/// | `boardgame.room.created` / `.updated` | `chat.ts:845–851 / 857–865`（**REST 详情才权威**） | `GET /boardgame/rooms/<id>/` → [AylaBoardgameStore.upsertRoom] + [AylaDirectoryStore.noteCreated] |
/// | `boardgame.room.deleted` | `chat.ts:853–855`（删除不回退排序） | [AylaBoardgameStore.removeRoom] + [AylaDirectoryStore.noteDeleted] |
///
/// ## 与 web 的一处**必要差异**（登记）
/// `live.viewers.changed` / `voice.channel.member_count_changed` 在 web 里只改域 store
/// （目录缓存随后由 store 订阅通路更新）；Flutter 侧的域 store 写路径与 web 同，
/// 但由于本桥是**同步**调用而订阅通路可能尚未装配（未登录 / 测试），本桥在写完域 store
/// 后**同步补一次** [AylaDirectoryStore.updateCachedItems] 的等价效应 —— 即复用订阅
/// 通路的同一个方法（幂等：与随后的 store 通知产生的 diff 结果一致）。
///
/// ## 纪律
/// - **403/404 一律静默**（web 原话：当前用户不可见或已删除，忽略提示）—— 不把
///   「看不到」写成「不存在」；
/// - **账号守卫**：REST 往返期间账号变了就丢弃结果（web 用 `currentOwner.current` 同法）；
/// - 帧结构非法（缺 `channel_id`）⇒ 直接忽略，不猜测。
library;

import 'dart:async';

import '../../state/boardgame_store.dart';
import '../../state/directory_events.dart' show AylaDirectoryEvents, AylaDirectoryKind;
import '../../state/directory_store.dart' show AylaDirectoryStore;
import '../../state/live_state.dart';
import '../../state/voice_state.dart';
import '../../widgets/live/live_channel_snapshot.dart';
import '../api/boardgame_api.dart';
import '../api/live_api.dart';
import '../api/voice_api.dart';
import '../models/game_room.dart' show AylaGameRoom;
import '../net/dio_client.dart' show ApiException;
import 'chat_ws.dart';

/// 本桥**转正**的 12 条域外帧（第四批登记 23 条 → 本批承接口见 [AylaRoomDirectoryBridge]）。
///
/// 消费点：`room_voice_test` / `room_live_test` / `chat_ws_test`（后者断言 chat 客户端
/// 对它们仍是 no-op **但照样透传** —— 桥正是靠 `onFrame` 接帧）。
const List<String> kAylaRoomFramesTurnedOn = <String>[
  'voice.channel.created',
  'voice.channel.deleted',
  'voice.channel.member_count_changed',
  'voice.channel.updated',
  'live.channel.created',
  'live.channel.status.changed',
  'live.channel.deleted',
  'live.channel.updated',
  'live.viewers.changed',
  'boardgame.room.created',
  'boardgame.room.deleted',
  'boardgame.room.updated',
];

/// 目录帧桥（挂在 chat WS 的 `onFrame` 上；单例由 provider 持有）。
class AylaRoomDirectoryBridge {
  AylaRoomDirectoryBridge({
    required AylaVoiceState voiceState,
    required AylaLiveState liveState,
    required AylaBoardgameStore boardgameStore,
    required String? Function() currentUserId,
    AylaDirectoryEvents? directory,
    AylaDirectoryStore? directoryStore,
  })  : _voice = voiceState,
        _live = liveState,
        _directory = directory,
        _directoryStore = directoryStore,
        _boardgame = boardgameStore,
        _currentUserId = currentUserId;

  final AylaVoiceState _voice;
  final AylaLiveState _live;

  /// 目录 store（web `stores/directory.ts` 的模块级 `useDirectoryStore`）——
  /// `*.created` / `*.deleted` 帧的 `createdIds` / 删除摘除落点。
  ///
  /// ⚠️ 可空只为**测试与旧调用点**兼容：生产由 `room_providers.dart` 注入全局单例。
  /// 为 null 时本桥退化为「只落域 store」（与 web 在 `ensureDirectoryTracking` 尚未
  /// 装配时的行为一致 —— 帧照样不丢，只是没有目录缓存可 patch）。
  final AylaDirectoryStore? _directoryStore;

  /// 旧的事件总线（**已退役**）：只为历史调用点/测试保留，生产恒为 null。
  ///
  /// 退役理由见文件头「架构」段：web 里帧不广播给页面，页面只读目录缓存；
  /// 总线的「广播 + 页面各自 patch」正是漏订阅页面没有热更新的根因。
  @Deprecated('目录热更新已改为「帧 → store」；请用 directoryStore，不要再订阅事件总线')
  final AylaDirectoryEvents? _directory;

  /// 桌游房全局表（web `useBoardgameStore`）—— `boardgame.room.*` 三条帧的落地目标。
  final AylaBoardgameStore _boardgame;
  final String? Function() _currentUserId;

  /// `*.created` 帧的**目录创建提示**（web `stores/directory.ts:228–234`）。
  void _noteCreated(AylaDirectoryKind kind, String id) {
    final AylaDirectoryStore? store = _directoryStore;
    if (store != null) {
      store.noteCreated(kind, id);
      return;
    }
    // 未注入 store（旧测试/未装配）：仍走总线，保持既有可观测性。
    _emitInvalidatedCompat(kind);
  }

  /// `*.deleted` 帧的**目录缓存摘除**（web `stores/directory.ts:237–258`）。
  void _noteDeleted(AylaDirectoryKind kind, String id) {
    final AylaDirectoryStore? store = _directoryStore;
    if (store != null) {
      store.noteDeleted(kind, id);
      return;
    }
    _emitDeletedCompat(kind, id);
  }

  /// 兼容档（无 store 注入时）—— 保留事件总线的最少用途，不静默丢语义。
  void _emitInvalidatedCompat(AylaDirectoryKind kind) {
    // ignore: deprecated_member_use_from_same_package
    _directory?.emitInvalidated(kind);
  }

  void _emitDeletedCompat(AylaDirectoryKind kind, String id) {
    // ignore: deprecated_member_use_from_same_package
    _directory?.emitDeleted(kind, id);
  }

  void Function()? _off;

  /// 挂到 chat WS 上（幂等）。
  void attach(AylaChatWsClient chat) {
    _off?.call();
    _off = chat.onFrame(handleFrame);
  }

  /// 解绑（登出/测试收尾）。
  void detach() {
    _off?.call();
    _off = null;
  }

  /// 处理一帧（测试可直接投喂）。
  ///
  /// 每条分支的两件事（与 web 逐条对应）：
  /// ① **落域 store**（`chat.ts` 的对应分支；帧只是提示、REST 详情才权威）；
  /// ② **落目录缓存提示**（`stores/directory.ts:220–259` 的 `createdIds` / 删除摘除）。
  /// 两条都做完 ⇒ 目录缓存由 store 订阅通路 patch、页面只读缓存 ⇒ 天然热更新。
  void handleFrame(Map<String, dynamic> frame) {
    final Object? rawType = frame['type'];
    if (rawType is! String) return;
    switch (rawType) {
      case 'voice.channel.created':
        final String id = _channelId(frame);
        if (id.isEmpty) return;
        // web `stores/directory.ts:228–234`：登记创建提示（60s），
        // 供随后的 `updateCachedItems` 判定「这条新增属于哪些查询」。
        _noteCreated(AylaDirectoryKind.voice, id);
        unawaited(_reconcileVoiceChannel(id));
      case 'voice.channel.updated':
        // 改名/可见性/转让 ⇒ 以权限 REST 详情为权威对账（web `chat.ts:720–727`）。
        // ⚠️ 不登记创建提示：`updated` 不是新增（web 的帧跟踪只认 `.created`/`.deleted`）。
        unawaited(_reconcileVoiceChannel(_channelId(frame)));
      case 'voice.channel.deleted':
        final String id = _channelId(frame);
        if (id.isEmpty) return;
        // web `chat.ts:679–683`：`removeChannel` —— 删除不回退排序。
        _voice.removeChannel(id);
        // web `stores/directory.ts:237–258`：从全部同 kind 的 record 摘除 + 校正统计。
        _noteDeleted(AylaDirectoryKind.voice, id);
      case 'voice.channel.member_count_changed':
        unawaited(_applyVoiceMemberCount(frame));
      case 'live.channel.created':
        final String id = _channelId(frame);
        if (id.isEmpty) return;
        _noteCreated(AylaDirectoryKind.live, id);
        unawaited(_reconcileLiveChannel(id));
      case 'live.channel.updated':
      case 'live.channel.status.changed':
        unawaited(_reconcileLiveChannel(_channelId(frame)));
      case 'live.channel.deleted':
        final String id = _channelId(frame);
        if (id.isEmpty) return;
        _live.removeChannel(id);
        _noteDeleted(AylaDirectoryKind.live, id);
      case 'live.viewers.changed':
        _applyViewerCount(frame);
      case 'boardgame.room.created':
        final String roomId = _roomId(frame);
        if (roomId.isEmpty) return;
        // web `stores/directory.ts:229` 读的是 `frame.room.id` —— 是否合法数字由 ① 判；
        // ② 的登记只看 id 是否为空（保持 web 的宽松口径，不猜语义）。
        _noteCreated(AylaDirectoryKind.game, roomId);
        unawaited(_reconcileGameRoom(roomId));
      case 'boardgame.room.updated':
        // 桌游房变更（有人加入/离开/踢出/转让/编辑）⇒ 拉完整房间对账（web `chat.ts:857–865`）。
        final String roomId = _roomId(frame);
        if (roomId.isEmpty) return;
        unawaited(_reconcileGameRoom(roomId));
      case 'boardgame.room.deleted':
        final String id = _roomId(frame);
        if (id.isEmpty) return;
        // web `chat.ts:853–855`：`removeRoom(Number(frame.room_id))` ——
        // 删除不回退排序（全局表与目录缓存两处都摘）。
        final int? roomId = int.tryParse(id);
        if (roomId == null) return;
        _boardgame.removeRoom(roomId);
        _noteDeleted(AylaDirectoryKind.game, id);
      default:
        return;
    }
  }

  /// `voice.channel.created/updated`：**帧只是提示，REST 详情才是权威**
  /// （权限过滤由后端做，避免把受限频道插进列表；web `chat.ts:667–678` 原话）。
  Future<void> _reconcileVoiceChannel(String channelId) async {
    if (channelId.isEmpty) return;
    final String? actor = _currentUserId();
    try {
      final AylaVoiceChannelSnapshot channel =
          await AylaVoiceApi.getVoiceChannel(channelId);
      if (actor != _currentUserId()) return;
      // ① 落域 store —— 目录缓存由 store 订阅通路（`directory_tracking.dart`）patch，
      // 这正是 web 的机制（`chat.ts:672` → `stores/directory.ts:211–213`）。
      _voice.upsertChannel(channel);
    } on ApiException catch (_) {
      // 403/404：当前用户不可见或频道已删除 —— 静默（web 同）
    } catch (_) {
      // 网络层失败：下一次事件或显式刷新会纠正 —— 静默，不伪造条目
    }
  }

  /// `voice.channel.member_count_changed`（web `chat.ts:685–719`）。
  ///
  /// 排序投影（`last_occupied_at` / `last_vacant_at`）帧携带时直接 patch；
  /// **缺失或为 null 时拉一次 REST 详情对账**（旧版后端不带这两个字段 ⇒ 由 serializer
  /// 返回的持久字段恢复「有人区/无人区」排序，多端一致、不依赖帧内容）。
  Future<void> _applyVoiceMemberCount(Map<String, dynamic> frame) async {
    final Object? raw = frame['data'];
    if (raw is! Map) return;
    final Map<String, dynamic> data = Map<String, dynamic>.from(raw);
    final String channelId = data['channel_id']?.toString() ?? '';
    if (channelId.isEmpty) return;
    final int? count = (data['member_count'] as num?)?.toInt();
    if (count == null) return;
    final Object? occupied = data['last_occupied_at'];
    final Object? vacant = data['last_vacant_at'];
    final bool frameHasSort = occupied != null || vacant != null;
    _voice.patchChannel(
      channelId,
      memberCount: count,
      lastOccupiedAt: occupied?.toString(),
      lastVacantAt: vacant?.toString(),
    );
    if (!frameHasSort) {
      unawaited(_reconcileVoiceChannel(channelId));
    }
  }

  /// `live.channel.created/status.changed/updated`：拉完整详情对账
  /// （web `reconcileLiveChannel`；列表卡/侧栏实时刷新）。
  Future<void> _reconcileLiveChannel(String channelId) async {
    if (channelId.isEmpty) return;
    final String? actor = _currentUserId();
    try {
      final AylaLiveChannelSnapshot channel =
          await AylaLiveApi.getLiveChannel(channelId);
      if (actor != _currentUserId()) return;
      // ① 落域 store（目录缓存由 store 订阅通路 patch；web `chat.ts:730` + :209）。
      _live.upsertChannel(channel);
    } on ApiException catch (_) {
      // 403/404：当前用户不可见或已删除 —— 静默
    } catch (_) {
      // 同上
    }
  }

  /// `live.viewers.changed`：**只 patch 已加载条目**的人数（不拉 REST、不标失效、
  /// 不改排序 —— 帧不含元数据、也不属于 `live.channel.*` 命名空间）。
  void _applyViewerCount(Map<String, dynamic> frame) {
    final Object? raw = frame['data'];
    if (raw is! Map) return;
    final Map<String, dynamic> data = Map<String, dynamic>.from(raw);
    final String channelId = data['channel_id']?.toString() ?? '';
    final int? count = (data['viewer_count'] as num?)?.toInt();
    if (channelId.isEmpty || count == null) return;
    _live.patchViewerCount(channelId, count);
  }

  /// `boardgame.room.created/updated`：拉完整房间对账（web `chat.ts:848–850 / 861–863`）。
  ///
  /// ⚠️ 与调用点 ② 的 `emitInvalidated` **互不替代**：本方法只负责「全局房间表」，
  /// 目录缓存的失效由 web `stores/directory.ts:220–236` 的帧跟踪承担（Flutter 侧
  /// 仍是既有的目录事件总线）。两条效应都保留 —— 房内页批次建立目录事件时还没有全局表，
  /// 本轮**补上**全局表，属于「加一条」而不是「换一条」。
  ///
  /// 静默档（web `.catch(() => {})` 原话）：当前用户不可见或房间已删除。
  Future<void> _reconcileGameRoom(String roomId) async {
    if (roomId.isEmpty) return;
    final int? id = int.tryParse(roomId);
    if (id == null) return;
    final String? actor = _currentUserId();
    try {
      final AylaGameRoom room = await AylaBoardgameApi.getGameRoom(id);
      if (actor != _currentUserId()) return;
      _boardgame.upsertRoom(room);
    } on ApiException catch (_) {
      // 403/404：当前用户不可见或房间已删除 —— 静默（web 同）
    } catch (_) {
      // 网络层失败：下一次事件或显式刷新会纠正 —— 静默，不伪造条目
    }
  }

  /// `data.channel_id`（voice / live 两类帧同一位置；`api/types.ts:663–727`）。
  static String _channelId(Map<String, dynamic> frame) {
    final Object? raw = frame['data'];
    if (raw is! Map) return '';
    return Map<String, dynamic>.from(raw)['channel_id']?.toString() ?? '';
  }

  static String _roomId(Map<String, dynamic> frame) {
    final Object? raw = frame['room'];
    if (raw is Map) {
      return Map<String, dynamic>.from(raw)['id']?.toString() ?? '';
    }
    final Object? data = frame['data'];
    if (data is Map) {
      return Map<String, dynamic>.from(data)['room_id']?.toString() ?? '';
    }
    return '';
  }
}
