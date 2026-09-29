/// 房内域目录帧桥 —— web `ws/chat.ts` 的 `voice.channel.*` / `live.*` /
/// `boardgame.room.*` 分支 + `stores/directory.ts` 的创建/删除跟踪，Flutter 侧等价物。
///
/// ## 为什么单独一件
/// 这些帧全部走 **chat WS**（第四批登记为「域外 23 条」的一部分）。它们的效应跨两个域
/// 三层：语音/直播状态表（`stores/voice.ts` / `stores/live.ts`）、目录列表
/// （web 的跨页缓存；Flutter 用事件总线）与房内会话（SRS 判定重拉 —— 归
/// `liveSessionRuntime` 自己订阅，本桥不重复实现）。
/// 集中成一件可被 chat WS 与测试共同驱动，也避免 `chat_ws.dart` 反向依赖房内域。
///
/// ## 逐条对应（web 事实源）
/// | 帧 | web | 本桥 |
/// |---|---|---|
/// | `voice.channel.created` | `chat.ts:667–678`（**REST 详情才权威**，避免泄露受限频道） | `GET /voice/channels/<id>/` → [AylaVoiceState.upsertChannel] + 目录失效 |
/// | `voice.channel.deleted` | `chat.ts:679–683`（删除不回退排序） | [AylaVoiceState.removeChannel] + 目录删除事件 |
/// | `voice.channel.member_count_changed` | `chat.ts:685–719`（帧带排序投影则直接 patch，否则拉详情对账） | 同语义 |
/// | `voice.channel.updated` | `chat.ts:720–727`（改名/可见性/转让 → REST 对账） | 同 |
/// | `live.channel.created` / `.updated` | `chat.ts:728–731 / 751–755`（`reconcileLiveChannel`） | `GET /live/channels/<id>/` → [AylaLiveState.upsertChannel] + 目录失效 |
/// | `live.channel.status.changed` | `chat.ts:732–750` | 同上；SRS 判定重拉归会话运行时 |
/// | `live.channel.deleted` | `chat.ts:745–750` | [AylaLiveState.removeChannel] + 目录删除事件 |
/// | `live.viewers.changed` | `chat.ts:756–768`（**瞬态投影**：不拉 REST、不标失效、不改排序 —— 帧不属于 `live.channel.*` 命名空间） | [AylaLiveState.patchViewerCount] + 目录人数事件 |
/// | `boardgame.room.created` / `.deleted` / `.updated` | `stores/directory.ts:221–232` | 目录失效 / 删除事件（房间表归各页分页） |
///
/// ## 纪律
/// - **403/404 一律静默**（web 原话：当前用户不可见或已删除，忽略提示）—— 不把
///   「看不到」写成「不存在」；
/// - **账号守卫**：REST 往返期间账号变了就丢弃结果（web 用 `currentOwner.current` 同法）；
/// - 帧结构非法（缺 `channel_id`）⇒ 直接忽略，不猜测。
library;

import 'dart:async';

import '../../state/directory_events.dart';
import '../../state/live_state.dart';
import '../../widgets/live/live_channel_snapshot.dart';
import '../../state/voice_state.dart';
import '../api/live_api.dart';
import '../api/voice_api.dart';
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
    required AylaDirectoryEvents directory,
    required String? Function() currentUserId,
  })  : _voice = voiceState,
        _live = liveState,
        _directory = directory,
        _currentUserId = currentUserId;

  final AylaVoiceState _voice;
  final AylaLiveState _live;
  final AylaDirectoryEvents _directory;
  final String? Function() _currentUserId;

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
  void handleFrame(Map<String, dynamic> frame) {
    final Object? rawType = frame['type'];
    if (rawType is! String) return;
    switch (rawType) {
      case 'voice.channel.created':
      case 'voice.channel.updated':
        unawaited(_reconcileVoiceChannel(_channelId(frame)));
      case 'voice.channel.deleted':
        final String id = _channelId(frame);
        if (id.isEmpty) return;
        _voice.removeChannel(id);
        _directory.emitDeleted(AylaDirectoryKind.voice, id);
      case 'voice.channel.member_count_changed':
        unawaited(_applyVoiceMemberCount(frame));
      case 'live.channel.created':
      case 'live.channel.updated':
      case 'live.channel.status.changed':
        unawaited(_reconcileLiveChannel(_channelId(frame)));
      case 'live.channel.deleted':
        final String id = _channelId(frame);
        if (id.isEmpty) return;
        _live.removeChannel(id);
        _directory.emitDeleted(AylaDirectoryKind.live, id);
      case 'live.viewers.changed':
        _applyViewerCount(frame);
      case 'boardgame.room.created':
      case 'boardgame.room.updated':
        if (_roomId(frame).isEmpty) return;
        _directory.emitInvalidated(AylaDirectoryKind.game);
      case 'boardgame.room.deleted':
        final String id = _roomId(frame);
        if (id.isEmpty) return;
        _directory.emitDeleted(AylaDirectoryKind.game, id);
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
      _voice.upsertChannel(channel);
      _directory.emitInvalidated(AylaDirectoryKind.voice);
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
    _directory.emitPatched(AylaDirectoryKind.voice, channelId, count);
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
      _live.upsertChannel(channel);
      _directory.emitInvalidated(AylaDirectoryKind.live);
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
    _directory.emitPatched(AylaDirectoryKind.live, channelId, count);
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
