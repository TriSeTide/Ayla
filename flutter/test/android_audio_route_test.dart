/// P2 / 任务 A：Android 语音房「媒体音量」原生通道（`ayla/audio_route`）契约锁。
///
/// 用户 2026-10-28 实报：手机端语音房的音量键落在**通话音量**上（听感像打电话）。
/// 根因：livekit_client 2.13.2 的 `AudioSessionOptions.mediaPlayback` 只改会话策略，
/// WebRTC ADM 的播放 AudioTrack 在 initialize 时就按 USAGE_VOICE_COMMUNICATION 建好了，
/// 于是音量键仍作用在 STREAM_VOICE_CALL。原生兜底见
/// `android/app/src/main/kotlin/com/ayla/ayla_flutter/MainActivity.kt`。
///
/// 本文件锁死三条**调用方可以依赖**的契约：
/// 1. **幂等**：重复调用不抛、状态一致；同一时刻的并发调用只发一次原生请求（合流）；
/// 2. **非 Android 返回 false**：Windows/iOS/Web 不碰原生通道（连 channel 都不发）；
/// 3. **失败不抛**：原生抛错 / 返回错误 / 没返回任何值 —— 一律 false，绝不向上抛
///    （语音生命周期不得因为音频路由失败而中断）。
library;

import 'dart:io';

import 'package:ayla_flutter/core/media/android_audio_route.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const MethodChannel _channel = MethodChannel('ayla/audio_route');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// 注入原生侧实现；[calls] 累加每次收到的 method 名（断言幂等/合流次数用）。
  List<String> installHandler(
    Future<Object?> Function(MethodCall call) handler,
  ) {
    final List<String> calls = <String>[];
    messenger.setMockMethodCallHandler(_channel, (MethodCall call) {
      calls.add(call.method);
      return handler(call);
    });
    return calls;
  }

  Map<String, Object?> okState({
    String mode = 'MODE_NORMAL',
    bool focusGranted = true,
    bool headset = false,
    String headsetKind = '',
    bool speakerOn = true,
    int musicVolume = 7,
    int voiceCallVolume = 3,
  }) =>
      <String, Object?>{
        'ok': true,
        'mode': mode,
        'modeInt': 0,
        'headset': headset,
        'headsetKind': headsetKind,
        'speakerOn': speakerOn,
        'focusGranted': focusGranted,
        'streamMusicVolume': musicVolume,
        'streamMusicMaxVolume': 15,
        'streamVoiceCallVolume': voiceCallVolume,
        'outputDevice': 'Speaker',
      };

  setUp(() {
    AylaAndroidAudioRoute.resetForTesting();
    // 默认按「Android」跑（真实平台在 flutter test 里恒为 Windows）。
    AylaAndroidAudioRoute.platformIsAndroid = () => true;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    AylaAndroidAudioRoute.resetForTesting();
  });

  group('契约 2：非 Android 一律 false，且不发原生调用', () {
    test('supported=false 时 applyMediaMode 返回 false 且零调用', () async {
      AylaAndroidAudioRoute.platformIsAndroid = () => false;
      final List<String> calls = installHandler((_) async => okState());

      expect(AylaAndroidAudioRoute.supported, isFalse);
      expect(await aylaApplyAndroidMediaRoute(), isFalse);
      expect(await AylaAndroidAudioRoute.applyMediaMode(), isFalse);
      expect(calls, isEmpty, reason: '非 Android 不得触碰 ayla/audio_route 通道');
      expect(AylaAndroidAudioRoute.lastState, isNull);
    });

    test('非 Android 的 readMediaModeState 返回 null 且零调用', () async {
      AylaAndroidAudioRoute.platformIsAndroid = () => false;
      final List<String> calls = installHandler((_) async => okState());

      expect(await AylaAndroidAudioRoute.readMediaModeState(), isNull);
      expect(calls, isEmpty);
    });

    test('supported 跟随注入：Android 为 true', () {
      expect(AylaAndroidAudioRoute.supported, isTrue);
    });
  });

  group('契约 1：幂等', () {
    test('连续两次 applyMediaMode：都成功、状态一致、原生被调用两次', () async {
      final List<String> calls =
          installHandler((_) async => okState(musicVolume: 9, voiceCallVolume: 4));

      expect(await aylaApplyAndroidMediaRoute(), isTrue);
      final AylaAndroidMediaRouteState? first = AylaAndroidAudioRoute.lastState;
      expect(await aylaApplyAndroidMediaRoute(), isTrue);
      final AylaAndroidMediaRouteState? second = AylaAndroidAudioRoute.lastState;

      expect(calls, <String>['applyMediaMode', 'applyMediaMode']);
      expect(first, isNotNull);
      expect(second!.mode, first!.mode);
      expect(second.focusGranted, first.focusGranted);
      expect(second.streamMusicVolume, 9);
      expect(second.streamVoiceCallVolume, 4);
      expect(second.mode, 'MODE_NORMAL');
      expect(second.speakerOn, isTrue);
      expect(second.headset, isFalse);
    });

    test('并发调用合流：同一时刻的 5 次调用只发一次原生请求', () async {
      int handled = 0;
      final List<String> calls = installHandler((_) async {
        handled++;
        return okState();
      });

      final List<bool> results = await Future.wait<bool>(<Future<bool>>[
        for (int i = 0; i < 5; i++) aylaApplyAndroidMediaRoute(),
      ]);

      expect(results, everyElement(isTrue));
      expect(handled, 1, reason: '并发合流：原生只该被调用一次');
      expect(calls.length, 1);
    });

    test('合流结束后可再次发起（不是永久缓存）', () async {
      final List<String> calls = installHandler((_) async => okState());

      await aylaApplyAndroidMediaRoute();
      await aylaApplyAndroidMediaRoute();
      expect(calls.length, 2);
    });

    test('每次成功都刷新 lastState', () async {
      int volume = 5;
      installHandler((_) async => okState(musicVolume: volume));

      await aylaApplyAndroidMediaRoute();
      expect(AylaAndroidAudioRoute.lastState?.streamMusicVolume, 5);

      volume = 11;
      await aylaApplyAndroidMediaRoute();
      expect(AylaAndroidAudioRoute.lastState?.streamMusicVolume, 11);
    });
  });

  group('契约 3：失败不抛', () {
    test('原生抛 PlatformException → false，不抛', () async {
      installHandler((_) async =>
          throw PlatformException(code: 'audio_route_failed', message: 'boom'));

      expect(await aylaApplyAndroidMediaRoute(), isFalse);
      expect(AylaAndroidAudioRoute.lastState, isNull);
    });

    test('原生抛 MissingPluginException → false，不抛', () async {
      installHandler((_) async => throw MissingPluginException('no impl'));

      expect(await aylaApplyAndroidMediaRoute(), isFalse);
    });

    test('原生返回 ok=false → false，不抛，lastState 不被污染', () async {
      installHandler((_) async => <String, Object?>{
            'ok': false,
            'reason': 'AudioManager unavailable',
          });

      expect(await aylaApplyAndroidMediaRoute(), isFalse);
      expect(AylaAndroidAudioRoute.lastState, isNull);
    });

    test('原生返回 null → false，不抛', () async {
      installHandler((_) async => null);

      expect(await aylaApplyAndroidMediaRoute(), isFalse);
      expect(AylaAndroidAudioRoute.lastState, isNull);
    });

    test('原生返回非 Map → false，不抛', () async {
      installHandler((_) async => 'nonsense');

      expect(await aylaApplyAndroidMediaRoute(), isFalse);
    });

    test('失败后仍可恢复（下一次成功调用照常工作）', () async {
      bool failing = true;
      int handled = 0;
      installHandler((_) async {
        handled++;
        if (failing) throw PlatformException(code: 'x', message: 'y');
        return okState();
      });

      expect(await aylaApplyAndroidMediaRoute(), isFalse);
      failing = false;
      expect(await aylaApplyAndroidMediaRoute(), isTrue);
      expect(handled, 2, reason: '失败不得把 _inFlight 卡死');
      expect(AylaAndroidAudioRoute.lastState?.mode, 'MODE_NORMAL');
    });

    test('原生缺字段不会抛（缺项走安全默认）', () async {
      installHandler((_) async => <String, Object?>{'ok': true});

      expect(await aylaApplyAndroidMediaRoute(), isTrue);
      final AylaAndroidMediaRouteState? state =
          AylaAndroidAudioRoute.lastState;
      expect(state, isNotNull);
      expect(state!.mode, 'unknown');
      expect(state.streamMusicVolume, -1);
      expect(state.streamVoiceCallVolume, -1);
      expect(state.headset, isFalse);
      expect(state.focusGranted, isFalse);
    });
  });

  group('只读回读 readMediaModeState', () {
    test('Android：返回原生状态，不进 lastState（只读不写缓存）', () async {
      final List<String> calls = installHandler((_) async => okState(
            mode: 'MODE_IN_COMMUNICATION',
            musicVolume: 13,
            voiceCallVolume: 2,
          ));

      final AylaAndroidMediaRouteState? state =
          await AylaAndroidAudioRoute.readMediaModeState();

      expect(calls, <String>['getMediaModeState']);
      expect(state, isNotNull);
      expect(state!.mode, 'MODE_IN_COMMUNICATION');
      expect(state.streamMusicVolume, 13);
      expect(state.streamVoiceCallVolume, 2);
      expect(AylaAndroidAudioRoute.lastState, isNull,
          reason: '只读回读不得改写 apply 的缓存状态');
    });

    test('原生抛错 → null，不抛', () async {
      installHandler((_) async => throw PlatformException(code: 'e', message: 'm'));

      expect(await AylaAndroidAudioRoute.readMediaModeState(), isNull);
    });
  });

  group('接线：livekit_room_adapter 必须在 connect 后与 publish 后各调一次', () {
    test('适配器源码引用 aylaApplyAndroidMediaRoute（connect + publishMicrophone）',
        () {
      final String src =
          File('lib/audio/livekit_room_adapter.dart').readAsStringSync();
      expect(src, contains("import '../core/media/android_audio_route.dart';"));
      expect(src, contains('_applyAndroidMediaRoute('));
      // connect()：必须在 await _room.connect(...) 之后调用。
      final int connectAt = src.indexOf('await _room.connect(url, token);');
      expect(connectAt, greaterThan(0));
      final int connectCallAt = src.indexOf("_applyAndroidMediaRoute('connect')");
      expect(connectCallAt, greaterThan(connectAt),
          reason: '媒体路由必须在 connect 之后（之前会被 SDK 覆盖）');
      // publishMicrophone()：必须在 publication 落库之后调用。
      final int publishCallAt =
          src.indexOf("_applyAndroidMediaRoute('publish')");
      expect(publishCallAt, greaterThan(src.indexOf('_micPublication = publication')));
      expect(publishCallAt, greaterThan(connectCallAt));
    });

    test('适配器不得吞掉异常（路由失败只 log，不中断语音）', () {
      final String src =
          File('lib/audio/livekit_room_adapter.dart').readAsStringSync();
      final int start = src.indexOf('Future<void> _applyAndroidMediaRoute(');
      expect(start, greaterThan(0));
      final int end = src.indexOf('/// 连接后再压一次移动端的媒体会话', start);
      final String body = src.substring(start, end);
      expect(body, isNot(contains('throw ')));
      expect(body, contains('aylaApplyAndroidMediaRoute()'));
    });
  });
}
