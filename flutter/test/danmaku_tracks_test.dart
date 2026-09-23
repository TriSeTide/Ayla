/// B2-1：弹幕轨道纯函数测试 —— 逐条对照 `components/live/danmakuTracks.ts` 12–55
/// 与官方单测 `vitest/danmaku-tracks.test.ts`（用例 1:1 移植）。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/widgets/danmaku_tracks.dart';

void main() {
  group('trackCountForHeight（tsx 24–30）', () {
    test('非法/零/负高度回退下限', () {
      expect(trackCountForHeight(0), kDanmakuTrackMin);
      expect(trackCountForHeight(-10), kDanmakuTrackMin);
      expect(trackCountForHeight(double.nan), kDanmakuTrackMin);
      expect(trackCountForHeight(double.infinity), kDanmakuTrackMin);
    });

    test('按行高刻度取整（下限 2 轨道兜底）', () {
      // 恰好一行（被下限抬到 2 轨道）
      expect(trackCountForHeight(kDanmakuTrackHeight), kDanmakuTrackMin);
      // 三行按行高取整
      expect(trackCountForHeight(kDanmakuTrackHeight * 3 + 5), 3);
    });

    test('封顶上限，不随高度无限增长', () {
      expect(trackCountForHeight(kDanmakuTrackHeight * 100), kDanmakuTrackMax);
    });
  });

  group('flyDurationMs（tsx 33–36）', () {
    test('非法宽度用 640 兜底', () {
      final int expected =
          ((640 + kDanmakuTextEstWidth) / kDanmakuSpeedPxPerSec * 1000).round();
      expect(flyDurationMs(0), expected);
      expect(flyDurationMs(double.nan), expected);
    });

    test('宽度越大时长越长（同速度）', () {
      final int narrow = flyDurationMs(390);
      final int wide = flyDurationMs(1440);
      expect(wide, greaterThan(narrow));
      expect(
        narrow,
        ((390 + kDanmakuTextEstWidth) / kDanmakuSpeedPxPerSec * 1000).round(),
      );
    });
  });

  group('minGapMs（tsx 39–41）', () {
    test('= 最小间距 / 速度（取整）', () {
      expect(
        minGapMs(),
        (kDanmakuMinGapPx / kDanmakuSpeedPxPerSec * 1000).round(),
      );
      expect(minGapMs(), greaterThan(0));
    });
  });

  group('pickTrack（tsx 49–54）', () {
    test('恒选最近开始时间最早（最空闲）的轨道', () {
      final List<DanmakuTrackState> tracks = <DanmakuTrackState>[
        DanmakuTrackState(lastStartAt: 500),
        DanmakuTrackState(lastStartAt: 100),
        DanmakuTrackState(lastStartAt: 300),
      ];
      expect(pickTrack(tracks), 1);
      // 更新后重新选（1 号变最忙 → 最闲换到 2 号）
      tracks[1].lastStartAt = 2000;
      expect(pickTrack(tracks), 2);
    });

    test('空轨道（0 起始）优先被选中', () {
      final List<DanmakuTrackState> tracks = <DanmakuTrackState>[
        DanmakuTrackState(lastStartAt: 100),
        DanmakuTrackState(),
        DanmakuTrackState(lastStartAt: 200),
      ];
      expect(pickTrack(tracks), 1);
    });
  });
}
