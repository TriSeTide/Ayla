/// LiveKit 语音后端契约锁（task-5）。
///
/// ## 为什么是「行为层 + 源码锁」两层
/// 媒体链路的真实验收只能由用户 `flutter run` 做（真机 + 真服务器），所以这里锁
/// **可离线判定的契约**：
/// 1. **行为层**（注入 FakeLiveKitRoom）：RelayState 六值映射、100ms 电平快照
///    含 0、关麦走 unpublish（不是 mute）、identity → 合成 slot 映射；
/// 2. **源码层**（三条硬约束的落地证据）：
///    - 关麦必须 removePublishedTrack + track.stop() + mediaStreamTrack.stop()；
///    - 代码里**不得**出现 isSpeaking / activeSpeakers（speaking 是 UI 事实，
///      muted 是唯一硬门控 —— 见 `docs/flutter/39`）；
///    - identity **不得**加 user_ 前缀（后端 `audio_consumer.py:93-95` 的硬缺陷）。
///
/// ## 变异验证（已实测）
/// - 把 unpublishMicrophone() 换成 track.mute()：用例「关麦释放设备」变红；
/// - 在 publishMicrophone 里加 if (!participant.isSpeaking) return：源码锁变红；
/// - 把 identity 改成 'user_' + identity：源码锁「identity 不加前缀」变红。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/audio/livekit_voice_backend.dart';
import '../lib/audio/voice_state.dart' show RelayState;
import 'fixtures/fake_livekit_room.dart';

/// 剥掉行注释（文档注释里的反例说明不算违规 —— 同类锁曾踩过假红）。
String _codeOnly(String src) => src.split('\n').map((String line) {
      final int i = line.indexOf('//');
      return i < 0 ? line : line.substring(0, i);
    }).join('\n');

/// 收集后端回调（断言用）。
class _Recorder {
  final List<RelayState> states = <RelayState>[];
  final List<(int slot, bool muted)> muted = <(int, bool)>[];
  final List<double> localLevels = <double>[];
  final List<Map<String, double>> snapshots = <Map<String, double>>[];
  final List<String> logs = <String>[];
}

/// 让广播流事件真正送达（StreamController.broadcast 是异步投递）。
Future<void> _flushEvents() => Future<void>.delayed(Duration.zero);

AylaLiveKitVoiceBackend _backend(FakeLiveKitRoom room, _Recorder rec) =>
    AylaLiveKitVoiceBackend(
      onStateChange: rec.states.add,
      onTrackMuted: (int slot, bool muted) => rec.muted.add((slot, muted)),
      onLocalAudioLevel: rec.localLevels.add,
      onRemoteAudioLevels: rec.snapshots.add,
      onLog: rec.logs.add,
      roomFactory: () async => room,
    );

void main() {
  group('状态映射：LiveKit 事件 → RelayState 六值（会话层映射函数零改动）', () {
    test('连接起点 connecting / connect 解析后 connected / 重连与断线', () async {
      final FakeLiveKitRoom room = FakeLiveKitRoom();
      final _Recorder rec = _Recorder();
      final AylaLiveKitVoiceBackend backend = _backend(room, rec);
      addTearDown(backend.dispose);

      await backend.connect('wss://livekit.example/livekit', 'media-token');
      expect(room.connectCalls, 1);
      expect(room.connectedUrls.single, 'wss://livekit.example/livekit');
      expect(backend.state, RelayState.connected);
      expect(rec.states,
          <RelayState>[RelayState.connecting, RelayState.connected]);

      room.emit(AylaRoomEventKind.reconnecting);
      await _flushEvents();
      expect(backend.state, RelayState.reconnecting);

      room.emit(AylaRoomEventKind.reconnected);
      await _flushEvents();
      expect(backend.state, RelayState.connected);

      room.emit(AylaRoomEventKind.disconnected);
      await _flushEvents();
      expect(backend.state, RelayState.failed,
          reason: '非用户主动断开 ⇒ failed，由用户决定重进（媒体断线 ≠ 离开频道）');
    });

    test('连接失败 → failed 且异常原样上抛（由上层决定是否降级）', () async {
      final FakeLiveKitRoom room =
          FakeLiveKitRoom(connectError: StateError('ICE 失败'));
      final _Recorder rec = _Recorder();
      final AylaLiveKitVoiceBackend backend = _backend(room, rec);
      addTearDown(backend.dispose);

      await expectLater(
        backend.connect('wss://livekit.example/livekit', 'token'),
        throwsA(isA<StateError>()),
      );
      expect(backend.state, RelayState.failed);
      expect(room.disconnectCalls, 1, reason: '失败也要收掉半开房间');
    });
  });

  group('100ms 电平节拍（UI 条子契约：连续回调 + 快照含 0）', () {
    test('本地电平随实测更新、未开麦恒 0；远端快照是全量（含 0）', () async {
      final FakeLiveKitRoom room = FakeLiveKitRoom();
      room.remotes = <String>['u1', 'u2'];
      room.levels['u1'] = 0.5;
      room.levels['u2'] = 0;
      final _Recorder rec = _Recorder();
      final AylaLiveKitVoiceBackend backend = _backend(room, rec);
      addTearDown(backend.dispose);

      await backend.connect('wss://livekit.example/livekit', 'token');
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(backend.state, RelayState.connected);
      expect(rec.snapshots, isNotEmpty, reason: '100ms 节拍必须真的在跑');
      final Map<String, double> snapshot = rec.snapshots.last;
      expect(snapshot.keys.toSet(), <String>{'u1', 'u2'},
          reason: '★ 快照必须含**全部**远端成员（上层按「缺失=0」覆盖）');
      expect(snapshot['u1'], 0.5);
      expect(snapshot['u2'], 0,
          reason: '★ 0 也必须出现在快照里，否则上层留残值');
      expect(rec.localLevels.last, 0, reason: '未开麦时本地电平恒 0');

      await backend.setMicrophoneEnabled(true);
      room.localLevel = 0.9;
      rec.localLevels.clear();
      await Future<void>.delayed(const Duration(milliseconds: 260));
      expect(rec.localLevels.where((double v) => v > 0), isNotEmpty,
          reason: '开麦后本地电平必须真的跳到实测值');

      backend.setRemoteVolume('u1', 0);
      await Future<void>.delayed(Duration.zero);
      expect(room.remoteAudioToggles.last, ('u1', false),
          reason: '0 档 = 本地禁音（SDK 无 per-track 音量，只能退订）');
    });
  });

  group('硬约束 2：关麦 = 释放麦克风设备（不是 mute）', () {
    test('setMicrophoneEnabled(false) 必须调用 unpublishMicrophone', () async {
      final FakeLiveKitRoom room = FakeLiveKitRoom();
      final _Recorder rec = _Recorder();
      final AylaLiveKitVoiceBackend backend = _backend(room, rec);
      addTearDown(backend.dispose);

      await backend.connect('wss://livekit.example/livekit', 'token');
      await backend.setMicrophoneEnabled(true);
      expect(room.publishCalls, 1);
      expect(backend.microphoneEnabled, isTrue);

      await backend.setMicrophoneEnabled(false);
      expect(room.unpublishCalls, 1,
          reason: '★ 关麦必须走「释放设备」路径（unpublish + track.stop()），'
              '不能只 mute —— 否则系统麦克风指示灯常亮，隐私语义回退');
      expect(backend.microphoneEnabled, isFalse);
      expect(rec.localLevels.last, 0, reason: '关麦瞬间本地电平归 0');
    });

    test('适配层源码必须有关麦三件套（unpublish + track.stop + 设备轨 stop）', () {
      final String src = _codeOnly(
        File('lib/audio/livekit_room_adapter.dart').readAsStringSync(),
      );
      expect(src, contains('removePublishedTrack('),
          reason: '协议侧退订：localParticipant.removePublishedTrack(pub.sid)');
      expect(src, contains('track?.stop()'),
          reason: 'SDK 轨道必须显式停（不赌 stopLocalTrackOnUnpublish 的实现细节）');
      expect(src, contains('mediaStreamTrack.stop()'),
          reason: '★ 停**采集设备原始轨**才是熄灭硬件指示灯的那一步');
      expect(src, isNot(contains('setMicrophoneEnabled(')),
          reason: '★ 不许用 SDK 的 setMicrophoneEnabled(false)：默认只 mute 不释放设备');
    });
  });

  group('硬约束 3：绝不用 isSpeaking / activeSpeakers 门控发布', () {
    test('后端与适配层代码里不得出现 isSpeaking / activeSpeakers', () {
      for (final String path in <String>[
        'lib/audio/livekit_voice_backend.dart',
        'lib/audio/livekit_room_adapter.dart',
      ]) {
        final String src = _codeOnly(File(path).readAsStringSync());
        expect(src, isNot(contains('isSpeaking')),
            reason: '★ ' + path + '：speaking 是 UI 事实，不是媒体门控（docs/flutter/39）');
        expect(src, isNot(contains('activeSpeakers')),
            reason: '★ ' + path + '：同上；muted 是唯一硬门控');
      }
    });

    test('DTX 必须关闭（DTX 在安静段完全停发 = doc39 的听感缺陷）', () {
      final String src = _codeOnly(
        File('lib/audio/livekit_room_adapter.dart').readAsStringSync(),
      );
      expect(src, contains('dtx: false'),
          reason: '★ 静音帧照发（Opus VBR 下约 25 字节），绝不按说话状态开关 track');
      expect(src, contains('maxBitrate: 32000'),
          reason: '码率与中继版 Opus 参数对齐（32 kbps）');
    });
  });

  group('硬约束 1：identity 用裸 user_id（不许加前缀）', () {
    test('identity → 合成 slot → identityOfSlot 反查回裸 user_id', () async {
      final FakeLiveKitRoom room = FakeLiveKitRoom();
      room.remotes = <String>['7', '9'];
      final _Recorder rec = _Recorder();
      final AylaLiveKitVoiceBackend backend = _backend(room, rec);
      addTearDown(backend.dispose);

      await backend.connect('wss://livekit.example/livekit', 'token');
      await Future<void>.delayed(const Duration(milliseconds: 120));

      room.emit(AylaRoomEventKind.trackMuted, identity: '9', muted: true);
      await _flushEvents();

      expect(rec.muted, isNotEmpty);
      final (int slot, bool muted) = rec.muted.last;
      expect(muted, isTrue);
      expect(backend.identityOfSlot(slot), '9',
          reason: '★ 会话层用 identityOfSlot 把静音事实映射到成员表；'
              'identity 带前缀会让成员表/音量/静音**全部失配**');
    });

    test('源码锁：LiveKit 路径不得给 identity 加 user_ 前缀', () {
      for (final String path in <String>[
        'lib/audio/livekit_voice_backend.dart',
        'lib/audio/livekit_room_adapter.dart',
      ]) {
        final String src = _codeOnly(File(path).readAsStringSync());
        expect(src, isNot(contains('user_')),
            reason: '★ ' + path + '：后端签发的是裸 str(user.pk)；'
                '被删的旧实现 livekit.py:50 就是 user_ 前缀（别照抄）');
      }
    });
  });

  group('能力边界（诚实上报，不伪造成功）', () {
    test('本地增益记录但不生效，并打日志说明原因', () {
      final FakeLiveKitRoom room = FakeLiveKitRoom();
      final _Recorder rec = _Recorder();
      final AylaLiveKitVoiceBackend backend = _backend(room, rec);
      addTearDown(backend.dispose);

      backend.setLocalVolume(1.6);
      expect(backend.debugLocalGain, 1.6);
      expect(rec.logs.join('\n'), contains('暂不生效'),
          reason: 'SDK 2.13.2 无 per-track 音量 API ⇒ 必须明说，不许静默无操作');
    });
  });

  group('本地禁音是成员级事实（对方重新开麦不得绕过）', () {
    test('trackSubscribed 到达后按已记录音量重新对齐', () async {
      final FakeLiveKitRoom room = FakeLiveKitRoom();
      final _Recorder rec = _Recorder();
      final AylaLiveKitVoiceBackend backend = _backend(room, rec);
      addTearDown(backend.dispose);

      await backend.connect('wss://livekit.example/livekit', 'token');
      room.remotes = <String>['u1', 'u2'];

      // 本地把 u1 静音（0 档 = 退订）
      backend.setRemoteVolume('u1', 0);
      await _flushEvents();
      expect(room.remoteAudioToggles.last, ('u1', false),
          reason: '0 档 = 本地禁音（SDK 无 per-track 音量，只能退订）');

      // 对方重新开麦 = 新 publication 被 SDK 自动订阅 -> 必须重新施加禁音
      room.remoteAudioToggles.clear();
      room.emit(AylaRoomEventKind.trackSubscribed, identity: 'u1');
      await _flushEvents();
      expect(room.remoteAudioToggles, contains(('u1', false)),
          reason: '用户实报：收音方关掉放音方声音后，放音方重新开麦又能听见');

      // 未静音的成员：新轨道应保持订阅（enabled = true）
      backend.setRemoteVolume('u2', 0.8);
      await _flushEvents();
      room.remoteAudioToggles.clear();
      room.emit(AylaRoomEventKind.trackSubscribed, identity: 'u2');
      await _flushEvents();
      expect(room.remoteAudioToggles, contains(('u2', true)),
          reason: '未静音成员不应被误退订');
    });
  });
}
