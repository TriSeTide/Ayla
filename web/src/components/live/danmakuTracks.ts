/**
 * 飘弹幕轨道算法（纯函数，任务 04 直播画面飘弹幕专用）。
 *
 * 模型：所有弹幕同速从右向左匀速飘（CSS transform 动画，GPU 合成），因此同轨道
 * 两条弹幕的水平间距只由「开始时间差」决定——分配轨道时保证相邻开始时间差 ≥
 * 最小间距时间，即可从数学上避免同轨道重叠，无需逐帧位置仲裁。
 *
 * - 轨道数按容器高度动态算（行高刻度 36px，2~10 条）；
 * - 弹幕时长 = (容器宽 + 文本宽估算) / 速度，容器越宽飘得越久（视觉速度一致）；
 * - 选轨道 = 选最空闲（最近开始时间最早）的一条。
 */
export const DANMAKU_SPEED_PX_PER_SEC = 150;
/** 同轨道相邻弹幕最小水平间距（px） */
export const DANMAKU_MIN_GAP_PX = 60;
/** 弹幕行高（px）：16px 字体 + 上下留白（轨道间距同刻度） */
export const DANMAKU_TRACK_HEIGHT = 36;
/** 轨道数下限 / 上限（过少挤不下，过多画面堆积） */
export const DANMAKU_TRACK_MIN = 2;
export const DANMAKU_TRACK_MAX = 10;
/** 文本宽度估算余量（px）：时长 = (容器宽 + 文本宽) / 速度，文本不逐条测量 */
export const DANMAKU_TEXT_EST_WIDTH = 280;

/** 容器高度 → 轨道数（clamp 2~10；非法高度回退下限） */
export function trackCountForHeight(heightPx: number): number {
  if (!Number.isFinite(heightPx) || heightPx <= 0) return DANMAKU_TRACK_MIN;
  return Math.max(
    DANMAKU_TRACK_MIN,
    Math.min(DANMAKU_TRACK_MAX, Math.floor(heightPx / DANMAKU_TRACK_HEIGHT)),
  );
}

/** 一条弹幕从右缘入屏到完全出屏的时长（ms）；容器宽非法时用 640px 兜底 */
export function flyDurationMs(containerWidthPx: number): number {
  const w = Number.isFinite(containerWidthPx) && containerWidthPx > 0 ? containerWidthPx : 640;
  return Math.round(((w + DANMAKU_TEXT_EST_WIDTH) / DANMAKU_SPEED_PX_PER_SEC) * 1000);
}

/** 同轨道两条弹幕的最小开始时间差（ms）= 最小间距 / 速度 */
export function minGapMs(): number {
  return Math.round((DANMAKU_MIN_GAP_PX / DANMAKU_SPEED_PX_PER_SEC) * 1000);
}

export interface TrackState {
  /** 该轨道最近一条弹幕的开始时间戳 */
  lastStartAt: number;
}

/** 选最空闲轨道（lastStartAt 最早）；返回轨道下标。调用方负责把该轨道 lastStartAt 更新为 now。 */
export function pickTrack(tracks: TrackState[]): number {
  let best = 0;
  for (let i = 1; i < tracks.length; i += 1) {
    if (tracks[i].lastStartAt < tracks[best].lastStartAt) best = i;
  }
  return best;
}
