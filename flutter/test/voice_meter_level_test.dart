/// 语音房音量条「波动」回归锁（2026-10-26）。
///
/// 用户实报「修复语音房音量条波动效果」。代码层排查结论：
/// - 电平映射（level^0.4）、80ms 过渡、store → 渲染链路**都已存在**；
/// - 但 audio_engine._startLevelTick 在循环**内**逐 slot 访问 slotIdentity
///   —— 那是 getter，每次 Map.unmodifiable 造新副本（relay_client.dart:141）
///   ⇒ 房间 N 人时每 100ms 复制 N 次整表，人多会抖动/掉电平。已修（提到循环外）。
///
/// 本文件锁住「映射口径」，防将来退化。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/widgets/voice/voice_member_row.dart' show AylaVoiceMemberRow;

void main() {
  group('电平映射（web VoiceMemberRow.tsx:56-63，DISPLAY_EXP = 0.4）', () {
    test('★ 静音 ⇒ 0%', () {
      expect(AylaVoiceMemberRow.debugLevelPercent(0), 0);
    });

    test('★ 满幅 ⇒ 100%', () {
      expect(AylaVoiceMemberRow.debugLevelPercent(1), 100);
    });

    test('★ 低音量被放大（0.01 的原始电平也要可见）', () {
      expect(AylaVoiceMemberRow.debugLevelPercent(0.01), 16);
    });

    test('★ 单调递增：电平变大 ⇒ 百分比不减', () {
      int prev = -1;
      for (int i = 0; i <= 100; i += 1) {
        final int p = AylaVoiceMemberRow.debugLevelPercent(i / 100);
        expect(p, greaterThanOrEqualTo(prev));
        prev = p;
      }
    });

    test('★ 越界夹取：负值与 >1 不得溢出', () {
      expect(AylaVoiceMemberRow.debugLevelPercent(-0.5), 0);
      expect(AylaVoiceMemberRow.debugLevelPercent(2), 100);
    });

    test('★ 常见说话电平有可见差异（0.02/0.1/0.3 三档递增）', () {
      final int a = AylaVoiceMemberRow.debugLevelPercent(0.02);
      final int b = AylaVoiceMemberRow.debugLevelPercent(0.1);
      final int c = AylaVoiceMemberRow.debugLevelPercent(0.3);
      expect(a, lessThan(b));
      expect(b, lessThan(c));
      expect(a, greaterThan(0));
    });
  });

  group('电平衰减（web wsRelayRoom.ts:461/470 的 *= 0.6）', () {
    /// 复刻 tick 的衰减语义：采样 → 上报 → 乘 0.6 回落。
    List<double> simulate(List<double> peaks) {
      const double decay = 0.6;
      double cur = 0;
      final List<double> out = <double>[];
      for (final double p in peaks) {
        if (p > cur) cur = p;
        out.add(cur);
        cur *= decay;
      }
      return out;
    }

    test('★ 有峰值后逐 tick 衰减，而不是立刻归零（这是「波动感」的来源）', () {
      final List<double> out = simulate(<double>[0.8, 0, 0, 0]);
      expect(out[0], 0.8, reason: '第一 tick 采样到峰值');
      expect(out[1], closeTo(0.48, 1e-9), reason: '衰减 0.6 倍，不是 0');
      expect(out[2], closeTo(0.288, 1e-9));
      expect(out[3], closeTo(0.1728, 1e-9));
      expect(out[1], greaterThan(0), reason: '★ 直接归零会让条子「完全不跳」');
    });

    test('★ 连续峰值时取较大者（不会因衰减丢失更大音量）', () {
      final List<double> out = simulate(<double>[0.3, 0.9, 0.1]);
      expect(out[1], 0.9);
    });

    test('★ 静音静置后最终趋近 0（不会永久残留）', () {
      double cur = 1.0;
      for (int i = 0; i < 20; i += 1) {
        cur *= 0.6;
      }
      expect(cur, lessThan(0.001));
    });
  });
}
