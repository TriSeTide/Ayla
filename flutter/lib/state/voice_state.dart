/// voice 全局状态 —— web `stores/voice.ts`（291 行）的 Flutter 等价物。
///
/// ## 逐字段对应（web `stores/voice.ts`）
/// | 本类 | web | 口径 |
/// |---|---|---|
/// | [currentChannelId] | `currentChannelId` | null = 未加入任何频道 |
/// | [members] | `members: Record<user_id, VoiceMemberState>` | `voice.state` 帧合并 + `members/` 对账铺底 |
/// | [media] | `livekit`（LiveKitConnectionState） | **媒体面**状态（WS 中继；LiveKit 已退役，字段名保留以对齐 web） |
/// | [wsConnection] | `wsConnection` | **应用层** voice WS 状态（connecting/online/offline） |
/// | [micEnabled] / [localAudioLevel] / [localVolume] | 同名 | 本地媒体事实与本地偏好（不落库） |
/// | [channels] | `channels` | **房内页需要的频道描述**（目录列表由各页 `AylaPagedList` 持有；web 的 `setChannels` / 分页由 `stores/directory.ts` 承担） |
///
/// ## 纪律（web 文件头原话）
/// - 成员昵称/头像**不复制**到本状态：渲染层用 `ensureUsers` 懒拉缓存；
/// - 爱莉条目只是普通成员 + UI 中性标签，无特殊数据源；
/// - `muted` 来自**应用层** `voice.state`；媒体层静音事实走中继的 `muted` 帧，
///   两者语义不同、不混用（web §4.3）；
/// - **读不到不写 0**：`wsConnection` 只记连接事实，不顶替业务数据。
library;

import 'package:flutter/foundation.dart';

import '../core/api/voice_api.dart';
import '../widgets/voice/voice_channels.dart' show AylaVoiceCardData;
import '../widgets/voice/voice_member_row.dart'
    show AylaVoiceMember, AylaVoiceSelfState;

/// `voice.state` 帧的 state 枚举（web `VoiceMemberEventState`，`api/types.ts:991`）。
///
/// **未知枚举值 → null**（不 fallback 成 joined/heartbeat）。
enum AylaVoiceMemberEventState {
  joined,
  left,
  heartbeat,
  muted,
  unmuted;

  /// 解析；未知值 → null。
  static AylaVoiceMemberEventState? parse(Object? raw) => switch (raw) {
        'joined' => AylaVoiceMemberEventState.joined,
        'left' => AylaVoiceMemberEventState.left,
        'heartbeat' => AylaVoiceMemberEventState.heartbeat,
        'muted' => AylaVoiceMemberEventState.muted,
        'unmuted' => AylaVoiceMemberEventState.unmuted,
        _ => null,
      };
}

/// 成员视图状态（web `VoiceMemberState`，`stores/voice.ts:20–32`）。
@immutable
class AylaVoiceMemberState {
  const AylaVoiceMemberState({
    required this.userId,
    this.joinedAt,
    this.lastSeenAt,
    this.muted = false,
    this.volume = 100,
    this.locallyMuted = false,
    this.audioLevel = 0,
  });

  final String userId;
  final String? joinedAt;
  final String? lastSeenAt;

  /// 应用层静音标记（`voice.state muted/unmuted`）。
  final bool muted;

  /// 本地播放音量 0~100（本地偏好，不落库、刷新重置）。
  final double volume;

  /// 本地播放静音（喇叭按钮；不改变 [volume] 设定值）。
  final bool locallyMuted;

  /// 远端实时说话音量 0~1（100ms 快照写入；未说话为 0）。
  final double audioLevel;

  /// 面板行的媒体投影（`AylaVoiceMemberRow.member`）。
  AylaVoiceMember toMember() => AylaVoiceMember(
        userId: userId,
        muted: muted,
        volume: volume,
        locallyMuted: locallyMuted,
        audioLevel: audioLevel,
      );

  AylaVoiceMemberState copyWith({
    String? joinedAt,
    String? lastSeenAt,
    bool? muted,
    double? volume,
    bool? locallyMuted,
    double? audioLevel,
  }) =>
      AylaVoiceMemberState(
        userId: userId,
        joinedAt: joinedAt ?? this.joinedAt,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
        muted: muted ?? this.muted,
        volume: volume ?? this.volume,
        locallyMuted: locallyMuted ?? this.locallyMuted,
        audioLevel: audioLevel ?? this.audioLevel,
      );
}

/// 媒体面连接状态（web `LiveKitConnectionState`，`stores/voice.ts:34–40`）。
enum AylaVoiceMediaConnection { idle, connecting, connected, reconnecting, failed }

/// 应用层 voice WS 连接状态（web `VoiceWSConnectionState`）。
enum AylaVoiceWsConnection { connecting, online, offline }

/// voice 全局状态（登录周期内单例；登出时 [reset]）。
class AylaVoiceState extends ChangeNotifier {
  String? _currentChannelId;
  final Map<String, AylaVoiceMemberState> _members =
      <String, AylaVoiceMemberState>{};
  final Map<String, AylaVoiceChannelSnapshot> _channels =
      <String, AylaVoiceChannelSnapshot>{};
  AylaVoiceMediaConnection _media = AylaVoiceMediaConnection.idle;
  AylaVoiceWsConnection _wsConnection = AylaVoiceWsConnection.offline;
  bool _micEnabled = false;
  double _localAudioLevel = 0;
  double _localVolume = 100;

  /// 我正在的频道 id（null = 未加入任何频道）。
  String? get currentChannelId => _currentChannelId;

  /// 成员表（插入序；`voice.state joined` 的顺序）。
  Map<String, AylaVoiceMemberState> get members =>
      Map<String, AylaVoiceMemberState>.unmodifiable(_members);

  /// 成员表按插入序遍历（web `Object.keys(members)`）。
  List<AylaVoiceMemberState> get membersInOrder =>
      _members.values.toList(growable: false);

  /// 频道描述表（房内页/热更新投影用）。
  Map<String, AylaVoiceChannelSnapshot> get channels =>
      Map<String, AylaVoiceChannelSnapshot>.unmodifiable(_channels);

  /// 取频道描述（不存在 → null）。
  AylaVoiceChannelSnapshot? channelOf(String? channelId) =>
      channelId == null ? null : _channels[channelId];

  /// 当前频道描述（null = 未加入/尚未拉到详情）。
  AylaVoiceChannelSnapshot? get currentChannel => channelOf(_currentChannelId);

  /// 我的成员态（不在频道 → null）。
  AylaVoiceMemberState? memberOf(String? userId) =>
      userId == null ? null : _members[userId];

  /// 自己那一行的本地媒体事实（面板的 `self` 档）。
  AylaVoiceSelfState selfState() => AylaVoiceSelfState(
        micEnabled: _micEnabled,
        localVolume: _localVolume,
        localAudioLevel: _localAudioLevel,
      );

  AylaVoiceMediaConnection get media => _media;
  AylaVoiceWsConnection get wsConnection => _wsConnection;
  bool get micEnabled => _micEnabled;
  double get localAudioLevel => _localAudioLevel;
  double get localVolume => _localVolume;

  // ---------------- 频道描述（web `upsertChannel` / `patchChannel` / `removeChannel`） ----------------

  /// 插入或整体替换（web `upsertChannel`；列表排序归各页 `AylaPagedList`）。
  void upsertChannel(AylaVoiceChannelSnapshot channel) {
    _channels[channel.id] = channel;
    notifyListeners();
  }

  /// 只改局部字段（web `patchChannel`）。
  void patchChannel(
    String channelId, {
    int? memberCount,
    bool? mine,
    String? lastOccupiedAt,
    String? lastVacantAt,
  }) {
    final AylaVoiceChannelSnapshot? prev = _channels[channelId];
    if (prev == null) return;
    _channels[channelId] = prev.patch(
      memberCount: memberCount,
      mine: mine,
      lastOccupiedAt: lastOccupiedAt,
      lastVacantAt: lastVacantAt,
    );
    notifyListeners();
  }

  /// 移除频道（web `removeChannel`）。
  void removeChannel(String channelId) {
    if (_channels.remove(channelId) != null) notifyListeners();
  }

  /// 卡投影列表（页面把目录页的条目同步进来时用；**不做排序**——排序归各页）。
  List<AylaVoiceCardData> get channelCards => <AylaVoiceCardData>[
        for (final AylaVoiceChannelSnapshot c in _channels.values) c.card,
      ];

  // ---------------- 成员（web `enterChannel` / `leaveChannelLocal` / `applyVoiceState`） ----------------

  /// 进入频道：设置当前频道并用 `members/` 对账结果铺底（web `enterChannel`）。
  void enterChannel(String channelId, List<AylaVoiceMemberState> members) {
    _currentChannelId = channelId;
    _members
      ..clear()
      ..addEntries(
        <MapEntry<String, AylaVoiceMemberState>>[
          for (final AylaVoiceMemberState m in members) MapEntry<String, AylaVoiceMemberState>(m.userId, m),
        ],
      );
    notifyListeners();
  }

  /// 离开/被移出：清空成员与当前频道（**幂等**，web `leaveChannelLocal`）。
  void leaveChannelLocal() {
    _currentChannelId = null;
    _members.clear();
    _media = AylaVoiceMediaConnection.idle;
    _micEnabled = false;
    _localAudioLevel = 0;
    _localVolume = 100;
    notifyListeners();
  }

  /// `voice.state` 帧合并（**仅处理当前频道**；其他频道帧忽略，web `applyVoiceState`）。
  void applyVoiceState(
    String channelId,
    String userId,
    AylaVoiceMemberEventState state,
    String? ts,
  ) {
    if (_currentChannelId != channelId) return;
    final String stamp = ts ?? DateTime.now().toIso8601String();
    switch (state) {
      case AylaVoiceMemberEventState.joined:
        final AylaVoiceMemberState? prev = _members[userId];
        _members[userId] = AylaVoiceMemberState(
          userId: userId,
          joinedAt: stamp,
          lastSeenAt: stamp,
          muted: prev?.muted ?? false,
          volume: prev?.volume ?? 100,
          locallyMuted: prev?.locallyMuted ?? false,
          audioLevel: prev?.audioLevel ?? 0,
        );
      case AylaVoiceMemberEventState.left:
        _members.remove(userId);
      case AylaVoiceMemberEventState.muted:
      case AylaVoiceMemberEventState.unmuted:
        final AylaVoiceMemberState? existing = _members[userId];
        if (existing == null) break;
        _members[userId] = existing.copyWith(
          muted: state == AylaVoiceMemberEventState.muted,
          lastSeenAt: stamp,
        );
      case AylaVoiceMemberEventState.heartbeat:
        final AylaVoiceMemberState? existing = _members[userId];
        if (existing == null) break;
        _members[userId] = existing.copyWith(lastSeenAt: stamp);
    }
    notifyListeners();
  }

  /// 成员对账：以服务端 `members/` 为权威**全量替换**，但保留本地音量偏好
  /// （音量不落库；web `reconcileMembers`）。
  void reconcileMembers(List<AylaVoiceMemberDescriptor> list) {
    final Map<String, AylaVoiceMemberState> next =
        <String, AylaVoiceMemberState>{};
    for (final AylaVoiceMemberDescriptor m in list) {
      final AylaVoiceMemberState? prev = _members[m.userId];
      next[m.userId] = AylaVoiceMemberState(
        userId: m.userId,
        joinedAt: m.joinedAt,
        lastSeenAt: m.lastSeenAt,
        muted: prev?.muted ?? false,
        volume: prev?.volume ?? 100,
        locallyMuted: prev?.locallyMuted ?? false,
        audioLevel: prev?.audioLevel ?? 0,
      );
    }
    _members
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  /// 移除单个成员（`voice.state left` 帧驱动的列表剔除；web 面板的 `updateItems` 等价物）。
  void removeMember(String userId) {
    if (_members.remove(userId) != null) notifyListeners();
  }

  /// 本地播放音量（0~100）。
  void setMemberVolume(String userId, double volume) {
    final AylaVoiceMemberState? existing = _members[userId];
    if (existing == null) return;
    if (existing.volume == volume) return;
    _members[userId] = existing.copyWith(volume: volume);
    notifyListeners();
  }

  /// 本地播放静音（喇叭按钮；不改变 [setMemberVolume] 的设定值）。
  void setMemberLocallyMuted(String userId, bool muted) {
    final AylaVoiceMemberState? existing = _members[userId];
    if (existing == null || existing.locallyMuted == muted) return;
    _members[userId] = existing.copyWith(locallyMuted: muted);
    notifyListeners();
  }

  /// 远端实时音量**全量快照**（含 0；web `setRemoteAudioLevels`）。
  ///
  /// 快照里有的成员覆盖、没有的归 0（轮询每轮都传完整远端集合）。
  void setRemoteAudioLevels(Map<String, double> levels) {
    bool changed = false;
    final Map<String, AylaVoiceMemberState> next = <String, AylaVoiceMemberState>{};
    for (final MapEntry<String, AylaVoiceMemberState> e in _members.entries) {
      final double raw = levels[e.key] ?? 0;
      final double level = raw < 0 ? 0 : (raw > 1 ? 1 : raw);
      if (e.value.audioLevel != level) {
        next[e.key] = e.value.copyWith(audioLevel: level);
        changed = true;
      } else {
        next[e.key] = e.value;
      }
    }
    if (!changed) return;
    _members
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  void setMedia(AylaVoiceMediaConnection media) {
    if (_media == media) return;
    _media = media;
    notifyListeners();
  }

  void setWsConnection(AylaVoiceWsConnection connection) {
    if (_wsConnection == connection) return;
    _wsConnection = connection;
    notifyListeners();
  }

  void setMicEnabled(bool enabled) {
    if (_micEnabled == enabled) return;
    _micEnabled = enabled;
    notifyListeners();
  }

  void setLocalAudioLevel(double level) {
    final double clamped = level < 0 ? 0 : (level > 1 ? 1 : level);
    if (_localAudioLevel == clamped) return;
    _localAudioLevel = clamped;
    notifyListeners();
  }

  /// 本地麦克风音量 0~100（100 = 原始；web `setLocalVolume` 的取整 + 夹取）。
  void setLocalVolume(double volume) {
    final double clamped = volume < 0 ? 0 : (volume > 100 ? 100 : volume);
    final double rounded = clamped.roundToDouble();
    if (_localVolume == rounded) return;
    _localVolume = rounded;
    notifyListeners();
  }

  /// 登出/账号切换：全清（web `reset`）。
  void reset() {
    _currentChannelId = null;
    _members.clear();
    _channels.clear();
    _media = AylaVoiceMediaConnection.idle;
    _wsConnection = AylaVoiceWsConnection.offline;
    _micEnabled = false;
    _localAudioLevel = 0;
    _localVolume = 100;
    notifyListeners();
  }
}
