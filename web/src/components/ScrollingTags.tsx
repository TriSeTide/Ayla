/**
 * ScrollingTags —— 标签组横向滚动显示（标签太多时自动 marquee 来回滚动）。
 *
 * 与 ScrollingText 同源：检测标签总宽是否溢出容器（scrollWidth > clientWidth），
 * 溢出时内层以 marquee 来回滚动（停开头→滚到尾→停结尾→滚回），保证所有标签可读；
 * 未溢出时静态显示。用于可见性标签组（公开/好友/群名），替代手动 overflow-x 滚动
 * （后者隐藏滚动条后桌面鼠标无法横向滚动，等于「不滚动」）。
 */
import { useEffect, useRef, useState } from "react";
import type { CSSProperties } from "react";

export function ScrollingTags({
  labels,
  tagClassName,
  className = "",
  speed = 24,
  title,
}: {
  labels: string[];
  /** 每个标签胶囊的 className（如 voice-source-tag / live-badge live-badge-source） */
  tagClassName: string;
  className?: string;
  /** 每秒滚动像素（默认 24）；越大越快 */
  speed?: number;
  /** 可选悬停提示（完整标签串） */
  title?: string;
}) {
  const containerRef = useRef<HTMLSpanElement | null>(null);
  const [overflow, setOverflow] = useState(false);
  const [distance, setDistance] = useState(0);
  const [duration, setDuration] = useState(0);
  const labelsKey = labels.join("\u0000");

  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const measure = () => {
      const d = el.scrollWidth - el.clientWidth;
      setOverflow(d > 1);
      setDistance(d);
      setDuration(d > 0 ? Math.max(4, Math.min(16, d / speed)) : 0);
    };
    measure();
    if (typeof ResizeObserver === "undefined") return;
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, [labelsKey, speed]);

  return (
    <span
      ref={containerRef}
      className={`scroll-tags${overflow ? " is-overflow" : ""}${className ? ` ${className}` : ""}`}
      title={title}
    >
      <span
        className="scroll-tags-inner"
        style={
          overflow
            ? ({
                ["--marquee-distance" as string]: `-${distance}px`,
                ["--marquee-duration" as string]: `${duration}s`,
              } as CSSProperties)
            : undefined
        }
      >
        {labels.map((label, idx) => (
          <span key={`${idx}-${label}`} className={tagClassName}>
            {label}
          </span>
        ))}
      </span>
    </span>
  );
}

export default ScrollingTags;
