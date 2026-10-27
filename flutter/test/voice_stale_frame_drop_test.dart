/// 过期帧回收回归锁（2026-10-27）。
///
/// ## 用户观察（本轮的决定性线索）
///
/// 「断连期间的上传音频帧是**上传了的**。因为收音这一端在恢复连接时听到的声音
/// 会**爆发式**短时间听见这段时间的所有音频帧」。
///
/// ⇒ 帧没丢，是在链路/缓冲里**排队后集中送达**，接收端把过期音频**照单补播**。
/// 实时语音里迟到 200ms 以上的帧已无价值，必须丢弃而不是播放。
///
/// 修复前：drop 分支只清 Dart 侧 pending，**设备 FIFO 里的积压从不清理**
/// ⇒ 爆发回放照旧。现在补上 `MiniaudioPlayer.flushFifo()`（fork 新增导出）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/poc/relay_protocol.dart';

String _src(String relative) => File(relative).readAsStringSync();

/// 剥掉 `//` 行注释（文档注释里会引用旧代码作反例）。
String _stripComments(String src) => src
    .split('\n')
    .map((String line) {
      final int i = line.indexOf('//');
      return i < 0 ? line : line.substring(0, i);
    })
    .join('\n');

JitterDecision _d({required double fifo, required double pending, bool playing = true}) =>
    decideJitterFrame(
      fifoDepthSec: fifo,
      pendingSec: pending,
      frameSec: kFrameSamples / kSampleRate,
      playing: playing,
      catchingUp: false,
    );

void main() {
  group('过期帧裁剪：待播总量超过 kStaleDropSec 即丢弃', () {
    test('★ 待播 250ms（> 200ms 阈值）⇒ drop', () {
      // 模拟链路批量积压后集中送达：FIFO 已囤 250ms
      final JitterDecision d = _d(fifo: 0.25, pending: 0);
      expect(d.action, JitterAction.drop,
          reason: '过期帧必须丢弃，否则会把几秒前的话补播一遍（用户实报的爆发回放）');
      expect(d.playing, isFalse);
    });

    test('★ pending 很长也要触发（不能只看 FIFO）', () {
      // 高水位分支只看 FIFO，若只看它，pending 攒再多也不会被裁
      final JitterDecision d = _d(fifo: 0, pending: 0.3);
      expect(d.action, JitterAction.drop);
    });

    test('FIFO + pending 合计超阈值 ⇒ drop（任一单独都不超）', () {
      final JitterDecision d = _d(fifo: 0.15, pending: 0.1);
      expect(d.action, JitterAction.drop,
          reason: '待播总量是两者之和，必须合并判定');
    });

    test('★ 正常抖动（150ms 待播）不触发，避免误杀', () {
      final JitterDecision d = _d(fifo: 0.15, pending: 0);
      expect(d.action, isNot(JitterAction.drop),
          reason: '150ms 在正常抖动范围，裁掉会造成无谓静音');
    });

    test('阈值常量合理：> 一次 RTT（44-47ms），< 300ms', () {
      expect(kStaleDropSec, greaterThan(0.1));
      expect(kStaleDropSec, lessThanOrEqualTo(0.3));
    });

    test('裁剪目标水位必须高于欠载下限（裁完不能立刻欠载）', () {
      expect(kStaleTrimToSec, greaterThan(kUnderrunFloorSec));
      expect(kStaleTrimToSec, lessThan(kStaleDropSec));
    });
  });

  group('接线锁：drop 必须真正清空设备 FIFO', () {
    test('★ audio_engine 的 drop 分支必须调用 flushFifo()', () {
      final String engine = _stripComments(_src('lib/audio/audio_engine.dart'));
      expect(engine, contains('p.flushFifo()'),
          reason: '只清 pending 不清设备 FIFO ⇒ 积压照样播出（本轮真因）');
    });

    test('★ miniaudio fork 必须导出 ma_bridge_flush_fifo（C + 头 + Dart 绑定）', () {
      expect(_src('third_party/flutter_miniaudio/src/miniaudio_bridge.h'),
          contains('ma_bridge_flush_fifo'));
      expect(_src('third_party/flutter_miniaudio/src/miniaudio_bridge.c'),
          contains('ma_bridge_flush_fifo'));
      expect(_src('third_party/flutter_miniaudio/lib/src/miniaudio_bindings.dart'),
          contains('ma_bridge_flush_fifo'));
      expect(_src('third_party/flutter_miniaudio/lib/src/miniaudio_player.dart'),
          contains('flushFifo'));
    });
  });
}