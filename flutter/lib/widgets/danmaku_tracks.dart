/// 飘弹幕轨道算法（纯函数，`components/live/danmakuTracks.ts` 的 1:1 移植）。
///
/// 模型：所有弹幕同速从右向左匀速飘（CSS transform 动画，GPU 合成），因此同轨道
/// 两条弹幕的水平间距只由「开始时间差」决定——分配轨道时保证相邻开始时间差 ≥
/// 最小间距时间，即可从数学上避免同轨道重叠，无需逐帧位置仲裁。
///
/// - 轨道数按容器高度动态算（行高刻度 36px，2~10 条）；
/// - 弹幕时长 = (容器宽 + 文本宽估算) / 速度，容器越宽飘得越久（视觉速度一致）；
/// - 选轨道 = 选最空闲（最近开始时间最早）的一条。
///
/// 逐条对照 `danmakuTracks.ts`（行号为 web 文件）：
/// ```
/// 12  DANMAKU_SPEED_PX_PER_SEC = 150
/// 14  DANMAKU_MIN_GAP_PX = 60
/// 16  DANMAKU_TRACK_HEIGHT = 36
/// 18  DANMAKU_TRACK_MIN = 2 / 19  DANMAKU_TRACK_MAX = 10
/// 21  DANMAKU_TEXT_EST_WIDTH = 280
/// 24  trackCountForHeight（非法高度回退下限；floor 取整；上限封顶）
/// 33  flyDurationMs（非法宽度用 640 兜底）
/// 39  minGapMs（最小间距 / 速度，取整）
/// 49  pickTrack（恒选 lastStartAt 最小者；并列取下标最小）
/// ```
library;

import 'dart:math' as math;

/// 飘行速度（`--dur` 换算用；px/s）。
const double kDanmakuSpeedPxPerSec = 150;

/// 同轨道相邻弹幕最小水平间距（px）。
const double kDanmakuMinGapPx = 60;

/// 弹幕行高（px）：16px 字体 + 上下留白（轨道间距同刻度）。
const double kDanmakuTrackHeight = 36;

/// 轨道数下限 / 上限（过少挤不下，过多画面堆积）。
const int kDanmakuTrackMin = 2;
const int kDanmakuTrackMax = 10;

/// 文本宽度估算余量（px）：时长 = (容器宽 + 文本宽) / 速度，文本不逐条测量。
const double kDanmakuTextEstWidth = 280;

/// 容器高度 → 轨道数（clamp 2~10；非法高度回退下限）。
int trackCountForHeight(double heightPx) {
  if (!heightPx.isFinite || heightPx <= 0) return kDanmakuTrackMin;
  return math.max(
    kDanmakuTrackMin,
    math.min(kDanmakuTrackMax, (heightPx / kDanmakuTrackHeight).floor()),
  );
}

/// 一条弹幕从右缘入屏到完全出屏的时长（ms）；容器宽非法时用 640px 兜底。
int flyDurationMs(double containerWidthPx) {
  final double w = containerWidthPx.isFinite && containerWidthPx > 0
      ? containerWidthPx
      : 640;
  return ((w + kDanmakuTextEstWidth) / kDanmakuSpeedPxPerSec * 1000).round();
}

/// 同轨道两条弹幕的最小开始时间差（ms）= 最小间距 / 速度。
int minGapMs() => (kDanmakuMinGapPx / kDanmakuSpeedPxPerSec * 1000).round();

/// 轨道分配状态（`TrackState`）：该轨道最近一条弹幕的开始时间戳（ms）。
class DanmakuTrackState {
  DanmakuTrackState({this.lastStartAt = 0});

  /// 最近一条弹幕的开始时间戳。
  double lastStartAt;
}

/// 选最空闲轨道（[DanmakuTrackState.lastStartAt] 最早）；返回轨道下标。
///
/// 调用方负责把该轨道 `lastStartAt` 更新为本次开始时间。
int pickTrack(List<DanmakuTrackState> tracks) {
  int best = 0;
  for (int i = 1; i < tracks.length; i += 1) {
    if (tracks[i].lastStartAt < tracks[best].lastStartAt) best = i;
  }
  return best;
}
