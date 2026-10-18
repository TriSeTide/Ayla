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
  group('E5.1 采集三项（wsRelayRoom.ts:492–494）', () {
    test('RecordConfig 必须显式开 echoCancel / noiseSuppress / autoGain', () {
      final String src =
          File('lib/audio/audio_engine.dart').readAsStringSync();
      // record 6.x 的 RecordConfig 三项默认全 false（record_platform_interface
      // 1.6.0 record_config.dart:45/50/55）⇒ 不写就是关的，必须显式出现。
      expect(src, contains('echoCancel: true'),
          reason: 'wsRelayRoom.ts:492 echoCancellation: true');
      expect(src, contains('noiseSuppress: true'),
          reason: 'wsRelayRoom.ts:493 noiseSuppression: true');
      expect(src, contains('autoGain: true'),
          reason: 'wsRelayRoom.ts:494 autoGainControl: true');
      // 三项必须出现在同一个 RecordConfig 里（不能只是别处的注释）
      final int start = src.indexOf('const RecordConfig(');
      expect(start, greaterThan(0), reason: '必须显式构造 RecordConfig');
      final int end = src.indexOf(');', start);
      final String block = src.substring(start, end);
      expect(block, contains('echoCancel: true'));
      expect(block, contains('noiseSuppress: true'));
      expect(block, contains('autoGain: true'));
      expect(block, contains('AudioEncoder.pcm16bits'));
      expect(block, contains('sampleRate: kSampleRate'));
    });
  });

  group('E5.2 Opus 码率能力边界（wsRelayRoom.ts:516 bitrate:32000）', () {
    test('kOpusBitrate 必须标注为「不生效的文档常量」且确实是 32000', () {
      final String src = File('lib/poc/relay_protocol.dart').readAsStringSync();
      expect(src, contains('const int kOpusBitrate = 32000;'),
          reason: '数值仍须等于 web 的 bitrate: 32000');
      // 必须写明为什么不生效（否则后续 agent 会以为设了）
      expect(src, contains('文档常量'));
      expect(src, contains('SimpleOpusEncoder'));
      expect(src, contains('encoderCtl'));
      // 全库只有这一处定义（死常量不许散落）
      final Iterable<File> libs = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.dart'));
      int defs = 0;
      for (final File f in libs) {
        if (f.readAsStringSync().contains('kOpusBitrate =')) defs += 1;
      }
      expect(defs, 1, reason: 'kOpusBitrate 只允许有一处定义');
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
      expect(body, contains('dispose()'), reason: '必须释放引擎与中继');
    });
  });
}
