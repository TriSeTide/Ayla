/**
 * DanmakuOverlay —— 直播画面飘弹幕层（任务 04）。
 *
 * 在视频画面上叠加从右向左飘过的弹幕（B 站式），与右侧弹幕列表是同一数据的
 * **另一种展示形态**，不替代列表、不改数据链路：
 *
 * - 数据接入：订阅 live store 的 `current.danmaku`，**只飘"新弹幕"**（append 实时帧）；
 *   进房历史 / 重连对账（merge）以挂载基线快照排除，不重放；
 * - 轨道管理：按容器高度算轨道数（2~10），选最空闲轨道，同轨道保证最小间距
 *   （同速 → 时间差 = 间距，见 danmakuTracks.ts），不重叠、不堆积；
 * - 内容：弹幕左侧飘发送者头像（20px 圆，加载失败自动隐藏）；图片弹幕只飘
 *   **缩略图**（限定大小：画面固定 72×36 小图框，不飘原图；无缩略图不飘媒体）；
 *   图片用 ResourceImage 签名加载（不破图），点击打开 ImageViewer 放大（与聊天一致）；
 * - 动画：CSS transform 动画（GPU 合成），`--fly-from` 起点随容器宽度变化
 *   （宽窄屏 / 全屏自适应），animationend 移除 DOM，数量有上限防堆积；
 * - 层级：absolute 覆盖在 .live-player 内（pointer-events: none 不挡播放器控制条，
 *   z-index 在视频之上、悬浮控件之下）；reduced-motion 下整层不渲染。
 */
import { useEffect, useRef, useState } from "react";
import type { DanmakuItem, MediaDescriptor } from "../../api/types";
import { resolveMediaPath } from "../../api/media";
import { ResourceImage } from "../ResourceImage";
import { ImageViewer } from "../chat/ImageViewer";
import { useLiveStore } from "../../stores/live";
import {
  DANMAKU_TRACK_HEIGHT,
  flyDurationMs,
  minGapMs,
  pickTrack,
  trackCountForHeight,
  type TrackState,
} from "./danmakuTracks";

/** 画面内同时飘的弹幕上限（防长直播 DOM 堆积；超限丢弃最旧的） */
const MAX_FLYING = 80;
/** 顶部第一条弹幕的起始偏移（px），轨道内再按行高递增 */
const OVERLAY_TOP_PAD = 8;

interface FlyingEntry {
  /** 弹幕 id（store 按 id 去重，全局唯一，可直接做 React key） */
  key: string;
  /** 纯文本内容（媒体弹幕的占位文案 "图片" 不飘文字，只飘图） */
  text: string;
  /** 媒体缩略图路径（ResourceImage 内部签名加载）；null = 无图（文字弹幕） */
  mediaUrl: string | null;
  /** 媒体描述（点击放大 ImageViewer 用）；null = 无媒体 */
  media: MediaDescriptor | null;
  /** 发送者头像 URL；空串 = 无头像（不渲染） */
  avatar: string;
  track: number;
  durMs: number;
  fromX: number;
  top: number;
}

function prefersReducedMotion(): boolean {
  return (
    typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches
  );
}

/**
 * 媒体弹幕只飘缩略图（限定大小：画面固定小图框，不飘原图——原图大、加载慢）。
 * 无缩略图（thumbnail 为 null / 路径格式不符）返回 null，由调用方跳过该条媒体。
 */
function mediaThumb(item: DanmakuItem): string | null {
  if (!item.media) return null;
  return resolveMediaPath(item.media.thumbnail);
}

export function DanmakuOverlay({ channelId }: { channelId: number }) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const [entries, setEntries] = useState<FlyingEntry[]>([]);
  /** 已处理（飘过或基线）的弹幕 id，防重复飘 */
  const seenRef = useRef<Set<string>>(new Set());
  /** 各轨道最近一条弹幕的开始时间戳（轨道分配状态） */
  const tracksRef = useRef<TrackState[]>([]);
  /** 容器当前宽度（ResizeObserver 维护；全屏 / 宽窄屏切换自适应） */
  const widthRef = useRef(0);
  const [reduced] = useState(prefersReducedMotion);
  /** 点击弹幕图片放大的查看器（与聊天界面一致） */
  const [viewer, setViewer] = useState<{ media: MediaDescriptor; alt: string } | null>(null);

  // 容器尺寸：决定轨道数（高度）/ 动画起点（宽度）/ 时长（宽度）
  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    widthRef.current = el.clientWidth;
    if (typeof ResizeObserver === "undefined") return;
    const ro = new ResizeObserver(([entry]) => {
      widthRef.current = entry.contentRect.width;
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // 基线 + 订阅：只飘新弹幕（append），历史 / 重连对账（merge）不重放。
  // channelId 变化 → effect 重跑 → 基线重建、画面清空（切台无残留）。
  useEffect(() => {
    seenRef.current = new Set(
      useLiveStore.getState().current.danmaku.map((d) => d.id),
    );
    tracksRef.current = [];
    setEntries([]);

    const unsub = useLiveStore.subscribe((state, prev) => {
      if (state.current.danmaku === prev.current.danmaku) return;
      const now = Date.now();
      const trackCount = trackCountForHeight(containerRef.current?.clientHeight ?? 0);
      if (tracksRef.current.length !== trackCount) {
        tracksRef.current = Array.from({ length: trackCount }, () => ({ lastStartAt: 0 }));
      }
      const gap = minGapMs();
      const newEntries: FlyingEntry[] = [];
      const fromX = widthRef.current > 0 ? widthRef.current : 640;
      for (const item of state.current.danmaku) {
        if (seenRef.current.has(item.id)) continue;
        seenRef.current.add(item.id);
        const text = item.content && item.content !== "图片" ? item.content : "";
        const mediaUrl = mediaThumb(item);
        // 空弹幕不飘：纯图弹幕且无缩略图（或文字为空且无图）
        if (!text && !mediaUrl) continue;
        const idx = pickTrack(tracksRef.current);
        const track = tracksRef.current[idx];
        // 同轨道最小间距：若上一条开始未满 gap，从 gap 之后开始（同速 → 水平间距恒 ≥ 最小间距）
        const startAt = Math.max(now, track.lastStartAt + gap);
        track.lastStartAt = startAt;
        newEntries.push({
          key: item.id,
          text,
          mediaUrl,
          media: item.media ?? null,
          avatar: item.sender.avatar || "",
          track: idx,
          durMs: flyDurationMs(fromX),
          fromX,
          top: OVERLAY_TOP_PAD + idx * DANMAKU_TRACK_HEIGHT,
        });
      }
      if (newEntries.length === 0) return;
      setEntries((prevList) => {
        const next = [...prevList, ...newEntries];
        return next.length > MAX_FLYING ? next.slice(next.length - MAX_FLYING) : next;
      });
    });
    return unsub;
  }, [channelId]);

  const handleEnd = (key: string) => {
    setEntries((prevList) => prevList.filter((e) => e.key !== key));
  };

  // reduced-motion：飘弹幕本质是动效，直接不渲染（无静态降级需求）
  if (reduced) return null;

  return (
    <div className="danmaku-overlay" ref={containerRef} aria-hidden="true">
      {entries.map((e) => (
        <span
          key={e.key}
          className="danmaku-fly"
          style={
            {
              top: e.top,
              "--dur": `${e.durMs}ms`,
              "--fly-from": `${e.fromX}px`,
            } as React.CSSProperties
          }
          onAnimationEnd={() => handleEnd(e.key)}
        >
          {e.avatar ? (
            <ResourceImage
              src={e.avatar}
              alt=""
              className="danmaku-fly-avatar"
              // 头像加载失败（空头像 / 路径失效）不显示，不出现破图
              fallback={null}
            />
          ) : null}
          {e.mediaUrl && e.media ? (
            <button
              type="button"
              className="danmaku-fly-img-open"
              onClick={() =>
                setViewer({ media: e.media as MediaDescriptor, alt: e.text || "弹幕图片" })
              }
              aria-label="查看弹幕图片"
              title="点击查看大图"
            >
              <ResourceImage
                src={e.mediaUrl}
                alt=""
                className="danmaku-fly-img"
                variant="thumb"
                fallback={null}
              />
            </button>
          ) : null}
          {e.text ? <span className="danmaku-fly-text">{e.text}</span> : null}
        </span>
      ))}
      {viewer && (
        <ImageViewer
          media={viewer.media}
          alt={viewer.alt}
          onClose={() => setViewer(null)}
        />
      )}
    </div>
  );
}
