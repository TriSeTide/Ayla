/// 测试替身：LiveKit 房间面（~AylaVoiceRoomLike~）。
///
/// 只实现后端真正消费的 11 个成员；记录调用次数供契约断言。生产实现在
/// ~lib/audio/livekit_room_adapter.dart~（SDK 胶水层），本替身让后端
/// （状态机 / 100ms 电平 / 麦开关语义）可以**纯单测**，不需要真服务器与原生插件。
library;

import 'dart:async';

import '../../lib/audio/livekit_voice_backend.dart';

class FakeLiveKitRoom implements AylaVoiceRoomLike {
  FakeLiveKitRoom({this.connectError});

  /// 连接时抛出的错误（null = 连接成功）。
  Object? connectError;

  /// 连接挂起点（用于「连接在途被 disconnect 取代」用例）。
  Completer<void>? connectGate;

  final StreamController<AylaRoomEvent> _events =
      StreamController<AylaRoomEvent>.broadcast();

  int connectCalls = 0;
  int disconnectCalls = 0;
  int disposeCalls = 0;
  int publishCalls = 0;
  int unpublishCalls = 0;
  int startAudioCalls = 0;
  int subscribeCalls = 0;
  int unsubscribeCalls = 0;
  final List<String> connectedUrls = <String>[];
  final List<String> connectedTokens = <String>[];
  final List<(String identity, bool enabled)> remoteAudioToggles =
      <(String, bool)>[];

  /// 远端成员列表 / 电平（由用例直接摆布）。
  List<String> remotes = <String>[];
  final Map<String, double> levels = <String, double>{};

  /// 本地电平实测值。
  double localLevel = 0;

  bool _mic = false;
  bool _disposed = false;

  @override
  Stream<AylaRoomEvent> get events => _events.stream;

  @override
  List<String> get remoteIdentities => List<String>.of(remotes);

  @override
  double get localAudioLevel => _mic ? localLevel : 0;

  @override
  double remoteAudioLevel(String identity) => levels[identity] ?? 0;

  @override
  bool get microphoneEnabled => _mic;

  @override
  Future<void> connect(String url, String token) async {
    connectCalls += 1;
    connectedUrls.add(url);
    connectedTokens.add(token);
    final Completer<void>? gate = connectGate;
    if (gate != null) await gate.future;
    final Object? error = connectError;
    if (error != null) throw error;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls += 1;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    disposeCalls += 1;
    await _events.close();
  }

  @override
  Future<void> publishMicrophone() async {
    publishCalls += 1;
    _mic = true;
  }

  @override
  Future<void> unpublishMicrophone() async {
    unpublishCalls += 1;
    _mic = false;
  }

  @override
  Future<void> startAudio() async {
    startAudioCalls += 1;
  }

  @override
  Future<void> setRemoteAudioEnabled(String identity, bool enabled) async {
    remoteAudioToggles.add((identity, enabled));
    if (enabled) {
      subscribeCalls += 1;
    } else {
      unsubscribeCalls += 1;
    }
  }

  /// 向订阅方推一条归一化事件。
  void emit(AylaRoomEventKind kind, {String? identity, bool? muted}) {
    if (_disposed || _events.isClosed) return;
    _events.add(AylaRoomEvent(kind, identity: identity, muted: muted));
  }
}
