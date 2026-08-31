/**
 * danmakuTracks 纯逻辑单测（任务 04 直播画面飘弹幕）：
 * - trackCountForHeight：非法高度回退下限；行高刻度取整；上限封顶
 * - flyDurationMs：非法宽度兜底；宽度越大时长越长（视觉速度一致）
 * - minGapMs：间距/速度换算
 * - pickTrack：恒选最空闲（最近开始时间最早）轨道
 */
import { describe, expect, it } from "vitest";
import {
  DANMAKU_SPEED_PX_PER_SEC,
  DANMAKU_TEXT_EST_WIDTH,
  DANMAKU_TRACK_HEIGHT,
  DANMAKU_TRACK_MAX,
  DANMAKU_TRACK_MIN,
  flyDurationMs,
  minGapMs,
  pickTrack,
  trackCountForHeight,
} from "../components/live/danmakuTracks";

describe("trackCountForHeight", () => {
  it("非法/零/负高度回退下限", () => {
    expect(trackCountForHeight(0)).toBe(DANMAKU_TRACK_MIN);
    expect(trackCountForHeight(-10)).toBe(DANMAKU_TRACK_MIN);
    expect(trackCountForHeight(Number.NaN)).toBe(DANMAKU_TRACK_MIN);
    expect(trackCountForHeight(Number.POSITIVE_INFINITY)).toBe(DANMAKU_TRACK_MIN);
  });

  it("按行高刻度取整（下限 2 轨道兜底）", () => {
    // 恰好一行（被下限抬到 2 轨道）
    expect(trackCountForHeight(DANMAKU_TRACK_HEIGHT)).toBe(DANMAKU_TRACK_MIN);
    // 三行按行高取整
    expect(trackCountForHeight(DANMAKU_TRACK_HEIGHT * 3 + 5)).toBe(3);
  });

  it("封顶上限，不随高度无限增长", () => {
    expect(trackCountForHeight(DANMAKU_TRACK_HEIGHT * 100)).toBe(DANMAKU_TRACK_MAX);
  });
});

describe("flyDurationMs", () => {
  it("非法宽度用 640 兜底", () => {
    expect(flyDurationMs(0)).toBe(
      Math.round(((640 + DANMAKU_TEXT_EST_WIDTH) / DANMAKU_SPEED_PX_PER_SEC) * 1000),
    );
    expect(flyDurationMs(Number.NaN)).toBe(
      Math.round(((640 + DANMAKU_TEXT_EST_WIDTH) / DANMAKU_SPEED_PX_PER_SEC) * 1000),
    );
  });

  it("宽度越大时长越长（同速度）", () => {
    const narrow = flyDurationMs(390);
    const wide = flyDurationMs(1440);
    expect(wide).toBeGreaterThan(narrow);
    expect(narrow).toBe(
      Math.round(((390 + DANMAKU_TEXT_EST_WIDTH) / DANMAKU_SPEED_PX_PER_SEC) * 1000),
    );
  });
});

describe("minGapMs", () => {
  it("= 最小间距 / 速度（取整）", () => {
    expect(minGapMs()).toBe(Math.round((60 / DANMAKU_SPEED_PX_PER_SEC) * 1000));
    expect(minGapMs()).toBeGreaterThan(0);
  });
});

describe("pickTrack", () => {
  it("恒选最近开始时间最早（最空闲）的轨道", () => {
    const tracks = [
      { lastStartAt: 500 },
      { lastStartAt: 100 },
      { lastStartAt: 300 },
    ];
    expect(pickTrack(tracks)).toBe(1);
    // 更新后重新选（1 号变最忙 → 最闲换到 2 号）
    tracks[1].lastStartAt = 2000;
    expect(pickTrack(tracks)).toBe(2);
  });

  it("空轨道（0 起始）优先被选中", () => {
    const tracks = [{ lastStartAt: 100 }, { lastStartAt: 0 }, { lastStartAt: 200 }];
    expect(pickTrack(tracks)).toBe(1);
  });
});
