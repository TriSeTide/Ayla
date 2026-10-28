/// 媒体连接契约（**LiveKit only**）。
///
/// 2026-10-28：用户决定删掉 ws_relay 中继与它的回退路径，本文件从
/// 「传输选择与原地降级」改写为「LiveKit 单一实现」的契约锁：
/// 1. `media.livekit` 完整 ⇒ 用后端给的 url/token 连接；
/// 2. `media` 缺失 / `livekit` 不完整 ⇒ **显式失败**（不再静默降级）；
/// 3. 连接失败 ⇒ 原样上抛（不换传输）；
/// 4. 连接在途被取代 ⇒ `AylaVoiceMediaCancelled`；
/// 5. identity 与 self 不一致 ⇒ 主动报 `identity_mismatch`，且日志不夹带 token。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../lib/audio/voice_media.dart';
import '../lib/audio/voice_media_config.dart';
import '../lib/audio/voice_state.dart' show RelayState;
import 'fixtures/fake_livekit_room.dart';

/// 记录全部回调（断言用）。
class _Recorder {
  final List<RelayState> states = <RelayState>[];
  final List<String> logs = <String>[];
  final List<double> localLevels = <double>[];
  final List<Map<String, double>> snapshots = <Map<String, double>>[];
}

AylaVoiceMediaEvents _events(_Recorder rec) {
  final AylaVoiceMediaEvents events = AylaVoiceMediaEvents();
  events.onStateChange = rec.states.add;
  events.onLog = rec.logs.add;
  events.onLocalAudioLevel = rec.localLevels.add;
  events.onRemoteAudioLevels = rec.snapshots.add;
  return events;
}

AylaVoiceMediaConfig _media({
  String url = 'wss://livekit.example/livekit',
  String token = 'media-token',
  String? identity,
}) =>
    AylaVoiceMediaConfig(
      livekit: AylaVoiceLiveKitConfig(
        url: url,
        token: token,
        roomName: 'room_1',
        identity: identity,
      ),
    );

void main() {
  setUp(() {
    AylaVoiceMedia.debugLiveKitRoomFactory = null;
  });
  tearDown(() {
    AylaVoiceMedia.debugLiveKitRoomFactory = null;
  });

  group('LiveKit 连接', () {
    test('配置完整 ⇒ 用后端给的 url/token 连接，事件落在自身 events', () async {
      final FakeLiveKitRoom room = FakeLiveKitRoom();
      final _Recorder rec = _Recorder();
      AylaVoiceMedia.debugLiveKitRoomFactory = () async => room;
      final AylaVoiceMedia media = AylaVoiceMedia(_events(rec));
      addTearDown(media.dispose);

      await media.connectWithMedia('1', 'api-access', _media());

      expect(room.connectCalls, 1);
      expect(room.connectedUrls.single, 'wss://livekit.example/livekit');
      expect(room.connectedTokens.single, 'media-token');
      expect(media.connected, isTrue);
      expect(rec.states, contains(RelayState.connected));
    });

    test('media 缺失 ⇒ 显式失败（不再回退中继）', () async {
      final FakeLiveKitRoom room = FakeLiveKitRoom();
      AylaVoiceMedia.debugLiveKitRoomFactory = () async => room;
      final AylaVoiceMedia media = AylaVoiceMedia(_events(_Recorder()));
      addTearDown(media.dispose);

      await expectLater(
        media.connectWithMedia('1', 'api-access', null),
        throwsA(isA<StateError>()),
      );
      expect(room.connectCalls, 0, reason: '没有可用配置时不得发起任何连接');
    });

    test('livekit 字段不完整（fromJson 已过滤）⇒ 显式失败', () async {
      final FakeLiveKitRoom room = FakeLiveKitRoom();
      AylaVoiceMedia.debugLiveKitRoomFactory = () async => room;
      final AylaVoiceMedia media = AylaVoiceMedia(_events(_Recorder()));
      addTearDown(media.dispose);

      // 缺 token 的 livekit 会被 fromJson 判为 null ⇒ 等价于「未下发媒体配置」
      final AylaVoiceMediaConfig? parsed =
          AylaVoiceMediaConfig.fromJson(<String, Object?>{
        'livekit': <String, Object?>{'url': 'wss://x/livekit'},
      });
      expect(parsed?.livekit, isNull);

      await expectLater(
        media.connectWithMedia('1', 'api-access', parsed),
        throwsA(isA<StateError>()),
      );
    });

    test('连接失败 ⇒ 原样上抛，不换传输', () async {
      final FakeLiveKitRoom room = FakeLiveKitRoom(connectError: StateError('boom'));
      final _Recorder rec = _Recorder();
      AylaVoiceMedia.debugLiveKitRoomFactory = () async => room;
      final AylaVoiceMedia media = AylaVoiceMedia(_events(rec));
      addTearDown(media.dispose);

      await expectLater(
        media.connectWithMedia('1', 'api-access', _media()),
        throwsA(isA<StateError>()),
      );
      expect(room.connectCalls, 1, reason: '只尝试一次，不存在第二次换传输');
      expect(rec.logs.where((String l) => l.contains('livekit_connect_failed')),
          isNotEmpty);
      expect(rec.logs.join(' '), isNot(contains('media-token')),
          reason: '日志不得泄露媒体 token');
    });

    test('连接在途被取代 ⇒ AylaVoiceMediaCancelled', () async {
      final FakeLiveKitRoom room = FakeLiveKitRoom();
      room.connectGate = Completer<void>();
      AylaVoiceMedia.debugLiveKitRoomFactory = () async => room;
      final AylaVoiceMedia media = AylaVoiceMedia(_events(_Recorder()));
      addTearDown(media.dispose);

      final Future<void> pending =
          media.connectWithMedia('1', 'api-access', _media());
      await Future<void>.delayed(Duration.zero);
      await media.disconnect();
      room.connectGate!.complete();

      await expectLater(pending, throwsA(isA<AylaVoiceMediaCancelled>()));
    });
  });

  group('配置解析', () {
    test('只有 livekit 一个来源；ws_relay 字段被忽略', () {
      final AylaVoiceMediaConfig? cfg =
          AylaVoiceMediaConfig.fromJson(<String, Object?>{
        'transport': 'ws_relay', // 历史字段，现在应被完全忽略
        'livekit': <String, Object?>{
          'url': 'wss://lk/livekit',
          'token': 't',
          'room_name': 'r',
          'identity': 'abc',
        },
        'ws_relay': <String, Object?>{'url': 'wss://relay/ws'},
      });
      expect(cfg, isNotNull);
      expect(cfg!.livekit!.url, 'wss://lk/livekit');
      expect(cfg.toString(), isNot(contains('wss://relay/ws')), reason: '旧中继地址不该出现');
      expect(cfg.toString(), isNot(contains("'t'")), reason: 'toString 不得含 token');
      expect(cfg.toString().contains(' token: '), isFalse, reason: 'toString 不得含 token');
    });

    test('media 缺失 ⇒ null', () {
      expect(AylaVoiceMediaConfig.fromJson(null), isNull);
      expect(AylaVoiceMediaConfig.fromJson(<String, Object?>{}), isNull);
    });
  });

  group('identity 纪律', () {
    test('token.identity 与 self 不一致 ⇒ 主动报 identity_mismatch', () async {
      final FakeLiveKitRoom room = FakeLiveKitRoom();
      final _Recorder rec = _Recorder();
      AylaVoiceMedia.debugLiveKitRoomFactory = () async => room;
      final AylaVoiceMedia media = AylaVoiceMedia(_events(rec));
      addTearDown(media.dispose);

      await media.connectWithMedia(
        '1',
        'api-access',
        _media(identity: 'user_abc'),
        selfUserId: 'abc',
      );

      final String joined = rec.logs.join(' ');
      expect(joined, contains('identity_mismatch'));
      expect(joined, isNot(contains('media-token')), reason: '日志不得含 token');
    });
  });
}
