/// task-5 / E5 语音三项的接线回归锁（2026-10-17）。
///
/// 覆盖：
/// - **E5.1** 采前处理 AEC / NS / AGC 三项（web `wsRelayRoom.ts:492–494`）；
/// - **E5.2** Opus 码率的**能力边界**（web `wsRelayRoom.ts:516` bitrate:32000；
///   Flutter 侧库不暴露码率入口 ⇒ 常量降级为文档常量，必须有明确标注）；
/// - **E5.3** 登出收尾（web `stores/auth.ts:126–136` 的四项 runtime + 媒体断开）。
///
/// 这些是**契约/接线**层面的锁：用源码字符串 + 函数存在性断言，不启真机音频。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('E5.1 采集三项（web wsRelayRoom.ts:492–494 的等价要求）', () {
    test('AudioCaptureOptions 必须显式开 回声消除 / 降噪 / 自动增益', () {
      final String src =
          File('lib/audio/livekit_room_adapter.dart').readAsStringSync();
      final int start = src.indexOf('AudioCaptureOptions(');
      expect(start, greaterThan(0), reason: '必须显式构造 AudioCaptureOptions');
      final int end = src.indexOf(');', start);
      final String block = src.substring(start, end);
      expect(block, contains('echoCancellation: true'),
          reason: 'wsRelayRoom.ts:492 echoCancellation: true');
      expect(block, contains('noiseSuppression: true'),
          reason: 'wsRelayRoom.ts:493 noiseSuppression: true');
      expect(block, contains('autoGainControl: true'),
          reason: 'wsRelayRoom.ts:494 autoGainControl: true');
    });
  });

  group('E5.2 发布参数（web wsRelayRoom.ts:516 bitrate:32000）', () {
    test('AudioPublishOptions 必须是 32kbps + 关 DTX + 开 RED', () {
      final String src =
          File('lib/audio/livekit_room_adapter.dart').readAsStringSync();
      final int start = src.indexOf('AudioPublishOptions(');
      expect(start, greaterThan(0), reason: '必须显式构造 AudioPublishOptions');
      final int end = src.indexOf(');', start);
      final String block = src.substring(start, end);
      expect(block, contains('maxBitrate: 32000'),
          reason: '与 web 的 bitrate: 32000 对齐');
      expect(block, contains('dtx: false'),
          reason: 'DTX 会在安静段完全停发 = doc 39 的听感缺陷');
      expect(block, contains('red: true'), reason: 'RED 冗余抗丢包');
    });
  });

  group('E5.3 登出语音收尾（stores/auth.ts:126–136）', () {
    test('aylaVoiceRuntimeTeardown 四项齐全，且两条登出链都调用它', () {
      final String src = File('lib/state/room_providers.dart').readAsStringSync();
      // 函数本体：四项逐条对齐 auth.ts:127/128/129/136
      final int start = src.indexOf('void aylaVoiceRuntimeTeardown() {');
      expect(start, greaterThan(0), reason: '必须存在统一收尾函数');
      final int end = src.indexOf('\n}', start);
      final String body = src.substring(start, end);
      expect(body, contains('cancelSelection()'), reason: 'auth.ts:127');
      expect(body, contains('stopHeartbeat()'), reason: 'auth.ts:128');
      expect(body, contains('setMediaChannel(null)'), reason: 'auth.ts:129');
      expect(body, contains('aylaVoiceMediaTeardown()'), reason: 'auth.ts:136');

      // 两条登出链（WidgetRef 版 / ProviderContainer 版）都必须调用
      final int first = src.indexOf('void aylaStopRooms(WidgetRef ref) {');
      final int second =
          src.indexOf('void aylaStopRoomsForContainer(ProviderContainer container) {');
      expect(first, greaterThan(0));
      expect(second, greaterThan(first));
      final String refBody = src.substring(first, second);
      expect(refBody, contains('aylaVoiceRuntimeTeardown()'),
          reason: 'WidgetRef 版登出链漏了语音收尾');
      final String containerBody = src.substring(second);
      expect(containerBody, contains('aylaVoiceRuntimeTeardown()'),
          reason: 'ProviderContainer 版登出链漏了语音收尾');
    });

    test('aylaVoiceMediaTeardown 释放单例（下次取会新建，不继承上一账号）', () {
      final String src = File('lib/audio/voice_media.dart').readAsStringSync();
      expect(src, contains('void aylaVoiceMediaTeardown()'),
          reason: '必须有账号级媒体收尾');
      final int start = src.indexOf('void aylaVoiceMediaTeardown() {');
      final int end = src.indexOf('\n}', start);
      final String body = src.substring(start, end);
      expect(body, contains('_voiceMedia = null'), reason: '必须放弃单例');
      expect(body, contains('dispose()'), reason: '必须释放房间与麦克风设备');
    });
  });
}
