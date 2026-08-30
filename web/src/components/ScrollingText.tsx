/**
 * ScrollingText —— 长文本单行滚动显示（不换行、不挤压）。
 *
 * 文本在容器内始终单行（white-space: nowrap）；当内容宽度超出容器时，
 * 内层以 marquee 来回滚动，保证完整可读（首尾各停留一段）；未溢出时静态显示。
 * 容器通过 className 承担布局角色（如 flex: 1 / min-width: 0），
 * 滚动距离与时长由内联变量 --marquee-distance / --marquee-duration 提供。
 *
 * prefers-reduced-motion：关闭滚动，仅单行裁剪（配合 title 提示完整文本）。
 */
import { useEffect, useRef, useState } from "react";
import type { CSSProperties } from "react";

export function ScrollingText({
  text,
  className = "",
  speed = 24,
}: {
  text: string;
  className?: string;
  /** 每秒滚动像素（默认 24）；越大滚动越快 */
  speed?: number;
}) {
  const containerRef = useRef<HTMLSpanElement | null>(null);
  const [overflow, setOverflow] = useState(false);
  const [distance, setDistance] = useState(0);
  const [duration, setDuration] = useState(0);

  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const measure = () => {
      const d = el.scrollWidth - el.clientWidth;
      setOverflow(d > 1);
      setDistance(d);
      // 文本越长滚得越久：距离 / 速度，夹在 4~16s（一个完整来回周期）
      setDuration(d > 0 ? Math.max(4, Math.min(16, d / speed)) : 0);
    };
    measure();
    if (typeof ResizeObserver === "undefined") return;
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, [text, speed]);

  return (
    <span
      ref={containerRef}
      className={`scroll-text${overflow ? " is-overflow" : ""}${className ? ` ${className}` : ""}`}
      title={text}
    >
      <span
        className="scroll-text-inner"
        style={
          overflow
            ? ({
                ["--marquee-distance" as string]: `-${distance}px`,
                ["--marquee-duration" as string]: `${duration}s`,
              } as CSSProperties)
            : undefined
        }
      >
        {text}
      </span>
    </span>
  );
}

export default ScrollingText;
