/**
 * GroupCarousel —— 群卡片状态轮播（design.md §12.6，需求 R-H5 扩展）。
 *
 * - 4:3 封面区，轮播图圆角 12px，内嵌 8px；
 * - 轮播：横向滑轨 + translateX，300ms 滑入切换、3s 间隔；进视口才启动、离开暂停
 *   （IntersectionObserver）；`prefers-reduced-motion` 降级为静态首帧；
 * - 卡片种类：消息+语音合卡（文本两行）/ 直播卡（封面 + 左下角「主播 在直播 标题」）/
 *   帖子卡（图 + 左上「有新帖」 + 左下标题）/ 桌游卡（开关关闭，保留实现）；
 * - 无任何状态 → 回退群头像（空态）；
 * - 轮播卡非交互（点击卡片整体进群，由 GroupCard 处理，不再跳动态）。
 */
import { useEffect, useState } from "react";
import { Avatar } from "../Avatar";
import { ResourceImage } from "../ResourceImage";
import type { GroupCarouselSlide } from "./groupActivity";

const INTERVAL_MS = 3000;
const SLIDE_MS = 300;

function formatCount(n: number): string {
  return n > 99 ? "99+" : String(n);
}

/** 单个轮播卡内容（按 kind 分支渲染） */
function SlideContent({ slide }: { slide: GroupCarouselSlide }) {
  switch (slide.kind) {
    case "message-voice":
      return (
        <div className="group-carousel-text-lines">
          {slide.newMessageCount > 0 && (
            <span className="group-carousel-text-line">{`${formatCount(slide.newMessageCount)}条新消息`}</span>
          )}
          {slide.voiceRooms.map((r) => (
            <span key={r.name} className="group-carousel-text-line">{`${formatCount(r.memberCount)}人在${r.name}连麦`}</span>
          ))}
        </div>
      );
    case "live":
      return (
        <>
          {slide.cover ? (
            <ResourceImage src={slide.cover} alt="" className="group-carousel-img" />
          ) : (
            <span className="group-carousel-fallback group-carousel-fallback-live">{slide.title}</span>
          )}
          <span className="group-carousel-caption">{`${slide.host} 在直播 ${slide.title}`}</span>
        </>
      );
    case "post":
      return (
        <>
          {slide.image ? (
            <ResourceImage src={slide.image} alt="" className="group-carousel-img" />
          ) : (
            <span className="group-carousel-fallback group-carousel-fallback-post" />
          )}
          <span className="group-carousel-badge" aria-hidden="true">
            有新帖
          </span>
          {slide.body && <span className="group-carousel-post-body">{slide.body}</span>}
          <span className="group-carousel-caption">{slide.title}</span>
        </>
      );
    case "game":
      return (
        <>
          <span className="group-carousel-fallback group-carousel-fallback-game">{slide.name}</span>
          <span className="group-carousel-caption">{`${slide.memberCount}人在玩${slide.name}`}</span>
        </>
      );
  }
}

export function GroupCarousel({
  slides,
  groupName,
  avatar,
}: {
  slides: GroupCarouselSlide[];
  groupName: string;
  /** 群头像（媒体 content URL，可选；无状态空态回退显示） */
  avatar?: string;
}) {
  const hasItems = slides.length > 0;
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
    if (!visible || !hasItems || reduced || slides.length <= 1) return;
    const timer = window.setInterval(() => {
      setIndex((i) => (i + 1) % slides.length);
    }, INTERVAL_MS);
    return () => window.clearInterval(timer);
  }, [visible, hasItems, reduced, slides.length]);

  if (!hasItems) {
    return (
      <div className="group-carousel">
        <div className="group-carousel-empty" aria-label={`${groupName} 暂无动态`}>
          <Avatar label={groupName} size={64} online imageUrl={avatar || null} />
        </div>
      </div>
    );
  }

  const safeIndex = index % slides.length;

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
          {slides.map((s, i) => (
            <div
              key={i}
              className={`group-carousel-slide ${
                s.kind === "message-voice" ? "group-carousel-slide-text" : "group-carousel-slide-media"
              }`}
            >
              <SlideContent slide={s} />
            </div>
          ))}
        </div>
      </div>
      {slides.length > 1 && (
        <div className="group-carousel-dots" aria-hidden="true">
          {slides.map((_, i) => (
            <span key={i} className={`group-carousel-dot ${i === safeIndex ? "is-active" : ""}`} />
          ))}
        </div>
      )}
    </div>
  );
}
