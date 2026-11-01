/// R1 贴边 seek 目标计算回归锁（开发文档 §3 R1；需求 §3.3 R1 / §5.3 I1）。
///
/// ## 缺陷
/// 旧实现 `refreshToLiveEdge()` 最终执行 `seek(duration)`，而 HLS 直播的 `duration`
/// 是**整个 playlist 的总长**（实测 ≈66s），不是直播边缘 ⇒ 点刷新等于跳到 playlist
/// 末尾（语义错误，需求 §3.3 R1）。
///
/// ## 修法（本文件锁住其中的纯计算部分）
/// - media_kit：读 mpv 的 `seekable-ranges`，取**最后一段的 end**，回退 1 个分片（2s）；
/// - video_player：Dart 侧没有 seekable API ⇒ `duration - 2s` 兜底；
/// - 兜底要求 `duration > 4s`（短视频 / 尚未拿到 playlist 时不该被「贴边」倒回去）；
/// - 目标恒 > 0：回退到负值时退回边缘本身，绝不倒回开头。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/player/live_edge.dart';

void main() {
  group('aylaParseSeekableEnd（mpv seekable-ranges 解析）', () {
    test('单段：end 即直播边缘', () {
      expect(
        aylaParseSeekableEnd('[{start=0.000000, end=66.000000}]'),
        const Duration(seconds: 66),
      );
    });

    test('多段：取**最大** end（直播窗口右边缘），不是第一段的', () {
      expect(
        aylaParseSeekableEnd(
          '[{start=0.000000, end=12.000000}, {start=52.000000, end=68.000000}]',
        ),
        const Duration(seconds: 68),
        reason: 'SRS 追加分片时 seekable 会裂成多段，边缘永远在最后一段末尾',
      );
    });

    test('小数分片（0.7s）也要能解析', () {
      expect(
        aylaParseSeekableEnd('[{start=0.000000, end=0.7}]'),
        const Duration(milliseconds: 700),
      );
    });

    test('空串 / 无 end / 零值 / 非法文本 ⇒ null（调用方走 duration 兜底）', () {
      expect(aylaParseSeekableEnd(''), isNull);
      expect(aylaParseSeekableEnd('[]'), isNull);
      expect(aylaParseSeekableEnd('[{start=0.000000}]'), isNull);
      expect(aylaParseSeekableEnd('[{start=0, end=0}]'), isNull);
      expect(aylaParseSeekableEnd('not a range'), isNull);
    });
  });

  group('aylaLiveEdgeSeekTarget（贴边目标）', () {
    test('seekable 可用 ⇒ 目标 = end - 1 个分片（2s）', () {
      expect(
        aylaLiveEdgeSeekTarget(seekableEnd: const Duration(seconds: 66)),
        const Duration(seconds: 64),
        reason: '开发文档 §3 R1 明确 end - 2s；需求 §5.3 I1 要求距边缘 ≤2 个分片',
      );
    });

    test('seekable 优先于 duration（两者都在时用真实边缘）', () {
      expect(
        aylaLiveEdgeSeekTarget(
          seekableEnd: const Duration(seconds: 30),
          duration: const Duration(seconds: 66),
        ),
        const Duration(seconds: 28),
        reason: 'duration 是整个 playlist 总长，绝不能拿它当边缘',
      );
    });

    test('没有 seekable ⇒ duration - 2s 兜底（video_player 走的这条）', () {
      expect(
        aylaLiveEdgeSeekTarget(duration: const Duration(seconds: 66)),
        const Duration(seconds: 64),
      );
    });

    test('duration 太短（≤4s）⇒ null（不把 VOD / 空 playlist 当直播倒回去）', () {
      expect(aylaLiveEdgeSeekTarget(duration: const Duration(seconds: 1)), isNull);
      expect(aylaLiveEdgeSeekTarget(duration: const Duration(seconds: 4)), isNull);
    });

    test('两者都没有 / 都是零 ⇒ null（调用方走 rebuild 兜底）', () {
      expect(aylaLiveEdgeSeekTarget(), isNull);
      expect(
        aylaLiveEdgeSeekTarget(
          seekableEnd: Duration.zero,
          duration: Duration.zero,
        ),
        isNull,
      );
    });

    test('边缘小于 1 个分片时退回边缘本身（目标恒 > 0，绝不倒回开头）', () {
      expect(
        aylaLiveEdgeSeekTarget(seekableEnd: const Duration(seconds: 1)),
        const Duration(seconds: 1),
      );
    });
  });

  test('常量口径：回退 1 个分片 = 2s；最短可贴边 duration = 4s', () {
    expect(kLiveEdgeSeekBackoff, const Duration(seconds: 2));
    expect(kLiveEdgeMinDuration, const Duration(seconds: 4));
  });
}
