/**
 * GroupCarousel —— 群卡片封面轮播（design.md §12.6，需求 R-H4/R-H5）。
 *
 * - 4:3 封面区，轮播图圆角 12px，内嵌 8px；
 * - 轮播：横向滑轨 + translateX，300ms 滑入切换、3s 间隔；**进视口才启动、离开暂停**
 *   （IntersectionObserver）；`prefers-reduced-motion` 降级为静态首帧
 *   （design.md §7 装饰性循环例外条款）；
 * - 指示点：底部居中，当前 --glow-500、其余 --ice-300；
 * - 无动态回退群头像（居中 64px 带光环）。
 *
 * 点击封面交给父级 onOpen(highlight)（跳 target_url）；本组件不直接 navigate。
 */
import { useEffect, useState } from "react";
import type { GroupHighlight } from "../../api/types";
import { Avatar } from "../Avatar";

const INTERVAL_MS = 3000;
const SLIDE_MS = 300;

export function GroupCarousel({
  highlights,
  groupName,
  avatar,
  onOpen,
}: {
  highlights: GroupHighlight[];
  groupName: string;
  /** 群头像（媒体 content URL，可选；无动态空态回退显示） */
  avatar?: string;
  onOpen?: (h: GroupHighlight) => void;
}) {
  const hasItems = highlights.length > 0;
  const [index, setIndex] = useState(0);
  const [visible, setVisible] = useState(false);
  const [reduced, setReduced] = useState(false);
  const [rootEl, setRootEl] = useState<HTMLDivElement | null>(null);

  // prefers-reduced-motion 监听
  useEffect(() => {
    if (typeof window.matchMedia !== "function") return;
    const mql = window.matchMedia("(prefers-reduced-motion: reduce)");
    const update = () => setReduced(mql.matches);
    update();
    mql.addEventListener("change", update);
    return () => mql.removeEventListener("change", update);
  }, []);

  // IntersectionObserver：进视口启动轮播、离开暂停（design.md §12.6）
  useEffect(() => {
    if (!rootEl) return;
    if (typeof IntersectionObserver === "undefined") {
      setVisible(true);
      return;
    }
    const io = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) setVisible(entry.isIntersecting);
      },
      { threshold: 0.1 },
    );
    io.observe(rootEl);
    return () => io.disconnect();
  }, [rootEl]);

  // 轮播计时：可见 + 有多项 + 非 reduced-motion 时启停
  useEffect(() => {
    if (!visible || !hasItems || reduced || highlights.length <= 1) return;
    const timer = window.setInterval(() => {
      setIndex((i) => (i + 1) % highlights.length);
    }, INTERVAL_MS);
    return () => window.clearInterval(timer);
  }, [visible, hasItems, reduced, highlights.length]);

  if (!hasItems) {
    return (
      <div className="group-carousel">
        <div className="group-carousel-empty" aria-label={`${groupName} 暂无动态`}>
          <Avatar label={groupName} size={64} online imageUrl={avatar || null} />
        </div>
      </div>
    );
  }

  const safeIndex = index % highlights.length;

  return (
    <div className="group-carousel" ref={setRootEl}>
      <div className="group-carousel-track">
        <div
          className="group-carousel-slides"
          style={{
            transform: `translateX(-${safeIndex * 100}%)`,
            transition: reduced ? "none" : `transform ${SLIDE_MS}ms var(--ease-out)`,
          }}
        >
          {highlights.map((h, i) => (
            <button
              key={`${h.type}-${i}-${h.created_at}`}
              type="button"
              className="group-carousel-slide"
              tabIndex={i === safeIndex ? 0 : -1}
              onClick={() => onOpen?.(h)}
              aria-label={`打开动态：${h.title}`}
              aria-hidden={i === safeIndex ? undefined : "true"}
            >
              {h.cover_url ? (
                <img src={h.cover_url} alt="" className="group-carousel-img" draggable={false} />
              ) : (
                <span className={`group-carousel-fallback group-carousel-fallback-${h.type}`}>
                  {h.title}
                </span>
              )}
              <span className="group-carousel-badge" aria-hidden="true">
                {h.type === "live" ? "LIVE" : h.type === "game" ? "对局" : "动态"}
              </span>
            </button>
          ))}
        </div>
      </div>
      {highlights.length > 1 && (
        <div className="group-carousel-dots" aria-hidden="true">
          {highlights.map((_, i) => (
            <span key={i} className={`group-carousel-dot ${i === safeIndex ? "is-active" : ""}`} />
          ))}
        </div>
      )}
    </div>
  );
}
