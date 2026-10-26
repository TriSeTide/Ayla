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
}
