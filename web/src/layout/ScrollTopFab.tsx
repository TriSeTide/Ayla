/**
 * ScrollTopFab —— 右下角「回到顶部」44px 玻璃圆钮（方案 §3.4 / design.md §12.5）。
 *
 * - 页面滚动超过一屏（viewport 高度）才浮入，点击平滑回顶。
 * - 滚动容器：本应用采用「每页一个滚动容器」模型（页面根或群内场景列表容器，
 *   均 overflow-y:auto），不是 window/body 滚动。故用 document 的 capture 阶段 scroll
 *   监听捕获各滚动容器的 scroll 事件（scroll 不冒泡，需 capture）。判定「页面主滚动
 *   容器」= 可滚动（scrollHeight > clientHeight）且占据主体高度（clientHeight ≥ 40% 视口），
 *   忽略消息列表/弹幕等内嵌小滚动区。
 * - 出现/消失 200ms 浮入淡出（opacity + translateY，design.md §7）；reduced-motion
 *   关闭位移过渡、只留透明度渐变。
 */
import { useEffect, useRef, useState } from "react";
import { useLocation } from "react-router-dom";
import { IconArrowUp } from "../components/icons";

/** 页面主滚动容器：可滚动且占据主体高度（排除内嵌小滚动区） */
function isMainScroller(el: HTMLElement): boolean {
  if (el.scrollHeight <= el.clientHeight) return false;
  return el.clientHeight >= window.innerHeight * 0.4;
}

export function ScrollTopFab({
  position = "corner",
  stacked = false,
}: {
  /** corner：由 .corner-fab-stack 容器定位；narrow：窄屏独立定位（fixed 右下，避让底栏/CreateFAB） */
  position?: "corner" | "narrow";
  /** 窄屏是否堆叠在 CreateFAB 之上（有 CreateFAB 时 bottom 再抬高 56+12） */
  stacked?: boolean;
}) {
  const { pathname } = useLocation();
  const [visible, setVisible] = useState(false);
  const scrollerRef = useRef<HTMLElement | null>(null);

  // 路由切换：新页面 scrollTop=0，回顶钮复位隐藏（也清掉已卸载页面的滚动容器引用）
  useEffect(() => {
    scrollerRef.current = null;
    setVisible(false);
  }, [pathname]);

  useEffect(() => {
    const onScroll = (e: Event) => {
      const el = e.target as HTMLElement | null;
      if (!el || typeof el.scrollTop !== "number") return;
      if (!isMainScroller(el)) return;
      scrollerRef.current = el;
      setVisible(el.scrollTop > window.innerHeight);
    };
    document.addEventListener("scroll", onScroll, { capture: true, passive: true });
    return () => document.removeEventListener("scroll", onScroll, { capture: true });
  }, []);

  const scrollToTop = () => {
    const el = scrollerRef.current;
    if (!el) return;
    const reduced =
      typeof window.matchMedia === "function" &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    el.scrollTo({ top: 0, behavior: reduced ? "auto" : "smooth" });
  };

  return (
    <button
      type="button"
      className={`corner-fab corner-fab-scroll-top${position === "narrow" ? " is-narrow" : ""}${stacked ? " is-stacked" : ""}${visible ? " is-visible" : ""}`}
      onClick={scrollToTop}
      aria-label="回到顶部"
      aria-hidden={!visible}
      tabIndex={visible ? 0 : -1}
    >
      <IconArrowUp width={20} height={20} />
    </button>
  );
}
