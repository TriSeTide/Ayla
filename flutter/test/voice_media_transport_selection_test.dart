/// 媒体传输选择 + 原地降级契约锁（task-5）。
///
/// 锁的是 `AylaVoiceMedia` 这一层的**装配语义**（对应 web `client.ts
/// connectWithMedia`）：
/// 1. 按 `media` 配置选后端（livekit | ws_relay），**老后端无 `media` ⇒ 走中继**；
/// 2. LiveKit 连接失败 ⇒ **原地降级**到 ws_relay（一次重试、不回后端、不发版），
///    日志形如 `transport_fallback from=livekit to=ws_relay` 且**不含 token**；
/// 3. 被新连接取代（切频道/离开）**不降级**，抛 [AylaVoiceMediaCancelled]；
/// 4. LiveKit 后端的回调必须落在媒体实例**自己的** `events` 容器上
///    （「孤儿 events」是 2026-10-26 实报事故的根因）；
/// 5. identity 与当前用户不一致时主动打 `identity_mismatch`（硬约束 1 的兜底观测）。
///
/// 数据面（真机连通/音质）由用户 `flutter run` 验收；本文件只锁可离线判定的接线。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../lib/audio/livekit_voice_backend.dart';
import '../lib/audio/relay_client.dart' show RelayState;
import '../lib/audio/voice_media.dart';
import 'fixtures/fake_livekit_room.dart';

/// ws_relay 连接的测试替身（**绝不触网**）：记录调用，并模拟握手成功。
class _RelayProbe {
  int calls = 0;
  final List<String> channels = <String>[];
  final List<String> tokens = <String>[];

  Future<void> connect(AylaVoiceMedia media, String channelId, String token) async {
    calls += 1;
    channels.add(channelId);
    tokens.add(token);
    media.events.onStateChange?.call(RelayState.connected);
  }
}

Map<String, Object?> _liveKitJson({String identity = '7', String token = 'media-token'}) =>
    <String, Object?>{
      'transport': 'livekit',
      'livekit': <String, Object?>{
        'url': 'wss://livekit.example/livekit',
        'token': token,
        'ttl': 600,
        'room_name': 'room_abc',
        'identity': identity,
      },
      'ws_relay': <String, Object?>{'url': '/ws/voice/audio/?channel=3'},
    };

void main() {
  setUp(() {
    AylaVoiceMedia.debugLiveKitRoomFactory = null;
    debugSetVoiceMedia(null);
  });
  tearDown(() {
    AylaVoiceMedia.debugLiveKitRoomFactory = null;
    debugSetVoiceMedia(null);
  });

  group('配置解析（media 旁路字段）', () {
    test('transport=livekit + 配置完整 ⇒ wantsLiveKit', () {
      final AylaVoiceMediaConfig? cfg =
          AylaVoiceMediaConfig.fromJson(_liveKitJson());
      expect(cfg, isNotNull);
      expect(cfg!.transport, AylaVoiceTransport.livekit);
      expect(cfg.wantsLiveKit, isTrue);
      expect(cfg.livekit?.usable, isTrue);
      expect(cfg.wsRelay?.url, contains('/ws/voice/audio/'));
    });

    test('未知/缺失 transport ⇒ ws_relay（安全侧，与后端回落一致）', () {
      expect(
        AylaVoiceMediaConfig.fromJson(<String, Object?>{'transport': 'webrtc-x'})
            ?.transport,
        AylaVoiceTransport.wsRelay,
      );
      expect(
        AylaVoiceMediaConfig.fromJson(<String, Object?>{})?.transport,
        AylaVoiceTransport.wsRelay,
      );
      expect(AylaVoiceMediaConfig.fromJson(null), isNull);
    });

    test('livekit 缺 token/url ⇒ 该份配置作废，wantsLiveKit 恒 false', () {
      final AylaVoiceMediaConfig? cfg = AylaVoiceMediaConfig.fromJson(
        <String, Object?>{
          'transport': 'livekit',
          'livekit': <String, Object?>{'url': 'wss://x/livekit'},
          'ws_relay': <String, Object?>{'url': '/ws'},
        },
      );
      expect(cfg?.livekit, isNull, reason: '不造半份配置');
      expect(cfg?.wantsLiveKit, isFalse, reason: '配置不全必须回落中继');
    });

    test('toString 不含 token（凭据纪律）', () {
      final AylaVoiceMediaConfig cfg =
          AylaVoiceMediaConfig.fromJson(_liveKitJson())!;
      expect(cfg.toString(), isNot(contains('media-token')));
      expect(cfg.livekit.toString(), isNot(contains('media-token')));
    });
  });

  group('后端选择与原地降级', () {
    test('livekit 连接成功 ⇒ transport=livekit，回调落在媒体实例自己的 events 上',
        () async {
      final FakeLiveKitRoom room = FakeLiveKitRoom();
      room.remotes = <String>['7', 'u2'];
      room.levels['u2'] = 0.4;
      AylaVoiceMedia.debugLiveKitRoomFactory = () async => room;

      final AylaVoiceMediaEvents events = AylaVoiceMediaEvents();
      final AylaVoiceMedia media = AylaVoiceMedia(events);
      addTearDown(media.dispose);

      final Map<String, double> snapshot = <String, double>{};
      int snapshotAt = 0;
      events.onRemoteAudioLevels = (Map<String, double> levels) {
        snapshotAt += 1;
        snapshot
          ..clear()
          ..addAll(levels);
      };
      final List<String> logs = <String>[];
      events.onLog = logs.add;

      await media.connectWithMedia(
        '3',
        'access-token',
        AylaVoiceMediaConfig.fromJson(_liveKitJson()),
        selfUserId: '7',
      );

      expect(media.transport, AylaVoiceTransport.livekit);
      expect(media.state, RelayState.connected);
      expect(room.connectedUrls.single, 'wss://livekit.example/livekit',
          reason: '连接地址来自 media.livekit.url，不是中继地址');
      expect(logs.where((String l) => l.contains('identity_mismatch')), isEmpty,
          reason: 'identity = 裸 user_id 且与当前用户一致 ⇒ 不报');

      // 100ms 电平节拍 → 媒体实例自己的 events（不是孤儿对象）。
      await Future<void>.delayed(const Duration(milliseconds: 160));
      expect(snapshotAt, greaterThan(0), reason: '★ 电平必须穿过 media.events');
      expect(snapshot['u2'], 0.4);
      expect(snapshot.containsKey('7'), isTrue, reason: '快照含全部远端成员');

      // 远端静音事实：identity → 合成 slot → media.identityOfSlot 反查。
      int? mutedSlot;
      events.onTrackMuted = (int slot, bool muted) => mutedSlot = slot;
      room.emit(AylaRoomEventKind.trackMuted, identity: 'u2', muted: true);
      await _flush();
      expect(mutedSlot, isNotNull);
      expect(media.identityOfSlot(mutedSlot!), 'u2');

      await media.disconnect();
      expect(room.disconnectCalls, greaterThanOrEqualTo(1),
          reason: 'disconnect 必须路由到 LiveKit 后端');
    });

    test('livekit 连接失败 ⇒ 原地降级 ws_relay（一次重试，不回后端）', () async {
      final FakeLiveKitRoom room =
          FakeLiveKitRoom(connectError: StateError('ICE 失败'));
      AylaVoiceMedia.debugLiveKitRoomFactory = () async => room;

      final AylaVoiceMediaEvents events = AylaVoiceMediaEvents();
      final AylaVoiceMedia media = AylaVoiceMedia(events);
      addTearDown(media.dispose);
      final List<String> logs = <String>[];
      events.onLog = logs.add;
      final _RelayProbe relay = _RelayProbe();
      media.debugRelayConnect = (String channelId, String token) =>
          relay.connect(media, channelId, token);
      media.debugMarkEngineReady();

      await media.connectWithMedia(
        '3',
        'access-token',
        AylaVoiceMediaConfig.fromJson(_liveKitJson()),
        selfUserId: '7',
      );

      expect(media.transport, AylaVoiceTransport.wsRelay,
          reason: '★ 连接失败必须回到中继（回滚路径永远可用）');
      expect(relay.calls, 1, reason: '*一次*重试，不回后端再要配置');
      expect(relay.channels.single, '3');
      expect(
        logs.where((String l) => l.contains('transport_fallback')).length,
        1,
        reason: '★ 降级必须留一条结构化日志（便于判断是否真的切成功了）',
      );
      expect(relay.tokens.single, 'access-token',
          reason: '中继沿用应用 access token（LiveKit 才用 media token）');
      expect(room.disconnectCalls, 1, reason: '降级前必须收掉失败的 LiveKit 房间');
    });

    test('transport=ws_relay / 老后端无 media ⇒ 不构造 LiveKit 房间', () async {
      bool factoryCalled = false;
      AylaVoiceMedia.debugLiveKitRoomFactory = () async {
        factoryCalled = true;
        return FakeLiveKitRoom();
      };

      for (final AylaVoiceMediaConfig? cfg in <AylaVoiceMediaConfig?>[
        null,
        AylaVoiceMediaConfig.fromJson(<String, Object?>{
          'transport': 'ws_relay',
          'ws_relay': <String, Object?>{'url': '/ws/voice/audio/?channel=3'},
        }),
      ]) {
        final AylaVoiceMediaEvents events = AylaVoiceMediaEvents();
        final AylaVoiceMedia media = AylaVoiceMedia(events);
        addTearDown(media.dispose);
        final _RelayProbe relay = _RelayProbe();
        media.debugRelayConnect = (String channelId, String token) =>
            relay.connect(media, channelId, token);
        media.debugMarkEngineReady();

        await media.connectWithMedia('3', 'access-token', cfg);
        expect(media.transport, AylaVoiceTransport.wsRelay);
        expect(relay.calls, 1);
      }
      expect(factoryCalled, isFalse,
          reason: '★ 未启用 livekit 时不得实例化 LiveKit 房间（零副作用）');
    });

    test('连接在途被取代 ⇒ 抛取消且**不降级**（切频道不是故障）', () async {
      final Completer<void> gate = Completer<void>();
      final FakeLiveKitRoom room = FakeLiveKitRoom()..connectGate = gate;
      AylaVoiceMedia.debugLiveKitRoomFactory = () async => room;

      final AylaVoiceMediaEvents events = AylaVoiceMediaEvents();
      final AylaVoiceMedia media = AylaVoiceMedia(events);
      addTearDown(media.dispose);
      final _RelayProbe relay = _RelayProbe();
      media.debugRelayConnect = (String channelId, String token) =>
          relay.connect(media, channelId, token);
      media.debugMarkEngineReady();

      final Future<void> pending = media.connectWithMedia(
        '3',
        'access-token',
        AylaVoiceMediaConfig.fromJson(_liveKitJson()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await media.disconnect(); // 模拟切频道/离开
      gate.complete();

      await expectLater(pending, throwsA(isA<AylaVoiceMediaCancelled>()));
      expect(relay.calls, 0,
          reason: '★ 被取代不是故障：绝不能降级到中继（会把两条链路的噪声混在一起）');
    });

    test('identity 带前缀 ⇒ 主动报 identity_mismatch（且不含 token）', () async {
      AylaVoiceMedia.debugLiveKitRoomFactory = () async => FakeLiveKitRoom();
      final AylaVoiceMediaEvents events = AylaVoiceMediaEvents();
      final AylaVoiceMedia media = AylaVoiceMedia(events);
      addTearDown(media.dispose);
      final List<String> logs = <String>[];
      events.onLog = logs.add;

      await media.connectWithMedia(
        '3',
        'access-token',
        AylaVoiceMediaConfig.fromJson(_liveKitJson(identity: 'user_7')),
        selfUserId: '7',
      );

      final Iterable<String> mismatch =
          logs.where((String l) => l.contains('identity_mismatch'));
      expect(mismatch, isNotEmpty,
          reason: '★ 硬约束 1 的兜底观测：后端 identity 必须是裸 str(user.pk)');
      expect(mismatch.single, contains('user_7'));
      expect(mismatch.single, isNot(contains('media-token')),
          reason: '日志不得泄露媒体 token');
    });

    test('降级日志脱敏：reason 里夹带的 JWT 必须被替换', () async {
      const String jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiI3In0.abcdefghij';
      AylaVoiceMedia.debugLiveKitRoomFactory =
          () async => FakeLiveKitRoom(connectError: StateError('boom ' + jwt));
      final AylaVoiceMediaEvents events = AylaVoiceMediaEvents();
      final AylaVoiceMedia media = AylaVoiceMedia(events);
      addTearDown(media.dispose);
      final List<String> logs = <String>[];
      events.onLog = logs.add;
      final _RelayProbe relay = _RelayProbe();
      media.debugRelayConnect = (String channelId, String token) =>
          relay.connect(media, channelId, token);
      media.debugMarkEngineReady();

      await media.connectWithMedia(
        '3',
        'access-token',
        AylaVoiceMediaConfig.fromJson(_liveKitJson()),
      );

      final String fallback =
          logs.firstWhere((String l) => l.contains('transport_fallback'));
      expect(fallback, isNot(contains(jwt)),
          reason: '★ AGENTS.md §9：日志不得泄露凭据');
      expect(fallback, contains('<redacted-jwt>'));
    });
  });
}

/// 让广播流事件真正送达（StreamController.broadcast 是异步投递）。
Future<void> _flush() => Future<void>.delayed(Duration.zero);
