/**
 * 全局覆盖层滚动条（Overlay Scrollbar）
 *
 * 原生滚动条在桌面浏览器（Windows/Linux 的 Chrome/Edge/Firefox）会占据元素可用宽度，
 * 且无法做到“滚动时才显示”。base.css 已把原生滚动条全局隐藏（零占位、内容全宽），
 * 本组件用事件委托补回滚动反馈：监听文档级 scroll（捕获）/mouseover/mouseout，
 * 对正在滚动的容器，在视口内其右缘绘制一条细滚动条 —— 滚动中淡入、静止
 * HIDE_DELAY 后淡出，容器悬停时保持显示；始终不参与布局、不挤占内容宽度。
 *
 * 交互：
 * - 滚动/悬停时显示，停止滚动后淡出；
 * - thumb 可用鼠标/触控笔/触摸拖拽（Pointer Events + setPointerCapture），
 *   拖动时实时换算成容器的 scrollTop/scrollLeft；
 * - 窄屏（≤768px，与项目手机断点一致）完全不显示、不参与计算。
 *
 * 实现要点：
 * - thumb 固定挂载在 document.body（React 渲染树之外），用 fixed 定位 +
 *   getBoundingClientRect 视口坐标跟随滚动容器：不改动任何滚动容器的 DOM 结构，
 *   也不会与 React 的 children 协调或 transform 祖先冲突（thumb 的祖先只有 body/html）；
 * - thumb 四边带透明 padding 命中区（视觉条 = content-box 的 4px），方便拖拽；
 * - 竖向/横向双方向：竖向优先，纯横向容器画底部条，thumb 长度按 可视区²/内容区 比例；
 * - 页面滚动时滚动容器在视口中的位置会整体变化，document scroll 事件里对
 *   所有活跃容器统一重算；窗口 resize 同理。
 */
import { useEffect } from "react";

const THUMB_CLASS = "ov-scrollbar-thumb";
const VISIBLE_CLASS = "is-visible";
const HOST_ATTR = "data-ov-scrollbar";
/** 停止滚动后淡出延迟（ms） */
const HIDE_DELAY = 600;
/** 滚动条视觉粗细（px，content-box） */
const THICKNESS = 4;
/** 距容器边缘的留白（px） */
const OFFSET = 2;
/** thumb 四边透明命中区（px），视觉条保持 THICKNESS */
const PAD = 3;
/** 竖条/横条的最小视觉长度（px），保证可辨识 */
const MIN_VERT = 28;
const MIN_HORZ = 48;
/** 窄屏断点（与项目 ≤768px 手机断点一致）：完全不显示覆盖层滚动条 */
const NARROW_QUERY = "(max-width: 768px)";

/** 滚动容器 -> 它的 thumb（fixed，挂在 body 下） */
const thumbs = new WeakMap<Element, HTMLDivElement>();
/** thumb -> 所属滚动容器（拖拽命中需要反向查找） */
const owners = new Map<HTMLDivElement, Element>();
/** 滚动容器 -> 淡出定时器 */
const timers = new WeakMap<Element, ReturnType<typeof setTimeout>>();
/** 当前鼠标悬停的滚动容器（悬停期间不淡出） */
const hovered = new Set<Element>();
/** 当前活跃（可见 thumb）的滚动容器，供页面滚动/resize 时统一重算 */
const active = new Set<Element>();

interface DragState {
  el: Element;
  vert: boolean;
  /** 拾取点在 thumb 元素盒内的偏移（px） */
  grabOffset: number;
}

let drag: DragState | null = null;

function narrow(): boolean {
  return window.matchMedia(NARROW_QUERY).matches;
}

function scrollRoot(target: EventTarget | null): Element | null {
  if (target instanceof Document) {
    return document.scrollingElement ?? document.documentElement;
  }
  return target instanceof Element ? target : null;
}

function ensureThumb(el: Element): HTMLDivElement | null {
  let thumb = thumbs.get(el);
  if (thumb) return thumb;
  thumb = document.createElement("div");
  thumb.className = THUMB_CLASS;
  document.body.appendChild(thumb);
  el.setAttribute(HOST_ATTR, "");
  thumbs.set(el, thumb);
  owners.set(thumb, el);
  attachDrag(thumb, el);
  return thumb;
}

/** 拖拽 thumb -> 滚动容器（Pointer Events + 元素指针捕获，移出容器仍跟手） */
function attachDrag(thumb: HTMLDivElement, el: Element): void {
  thumb.addEventListener("pointerdown", (e) => {
    if (narrow()) return;
    e.preventDefault();
    thumb.setPointerCapture(e.pointerId);
    const r = thumb.getBoundingClientRect();
    drag = {
      el,
      vert: thumb.dataset.dir !== "h",
      grabOffset: thumb.dataset.dir === "h" ? e.clientX - r.left : e.clientY - r.top,
    };
  });

  thumb.addEventListener("pointermove", (e) => {
    if (!drag || drag.el !== el) return;
    const thumbRect = thumb.getBoundingClientRect();
    const elRect = el.getBoundingClientRect();
    const visual = Math.max(1, (thumb.dataset.dir === "h" ? thumbRect.width : thumbRect.height) - PAD * 2);
    if (drag.vert) {
      const trackH = el.clientHeight;
      const maxTop = trackH - visual;
      if (maxTop <= 0) return;
      const top = Math.min(Math.max(e.clientY - elRect.top - drag.grabOffset + PAD, 0), maxTop);
      el.scrollTop = (top / maxTop) * (el.scrollHeight - el.clientHeight);
    } else {
      const trackW = el.clientWidth;
      const maxLeft = trackW - visual;
      if (maxLeft <= 0) return;
      const left = Math.min(Math.max(e.clientX - elRect.left - drag.grabOffset + PAD, 0), maxLeft);
      el.scrollLeft = (left / maxLeft) * (el.scrollWidth - el.clientWidth);
    }
  });

  const endDrag = () => {
    if (!drag) return;
    const { el: dragged } = drag;
    drag = null;
    // 拖完保持悬停可见的语义：进入该容器视口位置的内容上
    scheduleHide(dragged);
  };
  thumb.addEventListener("pointerup", endDrag);
  thumb.addEventListener("pointercancel", endDrag);
}

function update(el: Element): void {
  const thumb = ensureThumb(el);
  if (!thumb) return;
  const rect = el.getBoundingClientRect();
  const vert = el.scrollHeight > el.clientHeight + 1;
  const horz = el.scrollWidth > el.clientWidth + 1;

  if (!vert && !horz) {
    thumb.style.display = "none";
    thumb.classList.remove(VISIBLE_CLASS);
    active.delete(el);
    return;
  }

  if (vert) {
    const track = el.clientHeight;
    const h = Math.max(MIN_VERT, Math.round((track * track) / el.scrollHeight));
    const maxTop = track - h;
    const top = maxTop <= 0 ? 0 : Math.round((el.scrollTop / (el.scrollHeight - track)) * maxTop);
    thumb.dataset.dir = "v";
    thumb.style.display = "block";
    // 全局 * { box-sizing: border-box }：盒宽 = 视觉条 + 两侧透明命中区
    thumb.style.width = `${THICKNESS + PAD * 2}px`;
    thumb.style.height = `${h + PAD * 2}px`;
    thumb.style.borderRadius = `${THICKNESS / 2 + PAD}px`;
    thumb.style.left = `${Math.round(rect.right) - OFFSET - THICKNESS - PAD}px`;
    thumb.style.top = `${Math.round(rect.top) + top - PAD}px`;
  } else {
    const track = el.clientWidth;
    const w = Math.max(MIN_HORZ, Math.round((track * track) / el.scrollWidth));
    const maxLeft = track - w;
    const left =
      maxLeft <= 0 ? 0 : Math.round((el.scrollLeft / (el.scrollWidth - track)) * maxLeft);
    thumb.dataset.dir = "h";
    thumb.style.display = "block";
    thumb.style.height = `${THICKNESS + PAD * 2}px`;
    thumb.style.width = `${w + PAD * 2}px`;
    thumb.style.borderRadius = `${THICKNESS / 2 + PAD}px`;
    thumb.style.top = `${Math.round(rect.bottom) - OFFSET - THICKNESS - PAD}px`;
    thumb.style.left = `${Math.round(rect.left) + left - PAD}px`;
  }

  thumb.classList.add(VISIBLE_CLASS);
  active.add(el);
}

/** 立即显示并重置淡出计时（滚动事件中调用） */
function show(el: Element): void {
  const thumb = thumbs.get(el);
  if (!thumb) return;
  thumb.classList.add(VISIBLE_CLASS);
  active.add(el);
  const timer = timers.get(el);
  if (timer) clearTimeout(timer);
}

function scheduleHide(el: Element): void {
  const timer = timers.get(el);
  if (timer) clearTimeout(timer);
  timers.set(
    el,
    setTimeout(() => {
      timers.delete(el);
      if (hovered.has(el) || drag?.el === el) return;
      const thumb = thumbs.get(el);
      if (thumb) thumb.classList.remove(VISIBLE_CLASS);
      active.delete(el);
    }, HIDE_DELAY)
  );
}

function onScroll(ev: Event): void {
  if (narrow()) return;
  const el = scrollRoot(ev.target);
  if (!el) return;
  // 页面（根）滚动会改变所有滚动容器的视口位置：统一重算活跃容器
  if (ev.target instanceof Document) {
    for (const other of Array.from(active)) {
      if (other !== el && other.isConnected) update(other);
    }
  }
  update(el);
  show(el);
  scheduleHide(el);
}

function onEnter(ev: MouseEvent): void {
  if (narrow()) return;
  const target = ev.target;
  if (!(target instanceof Element)) return;
  const host = target.closest<HTMLElement>(`[${HOST_ATTR}]`);
  if (!host) return;
  hovered.add(host);
  // 悬停即可见（内容未滚动时停在初始位置），离开后按 HIDE_DELAY 淡出
  update(host);
  show(host);
  scheduleHide(host);
}

function onLeave(ev: MouseEvent): void {
  if (narrow()) return;
  const target = ev.target;
  if (!(target instanceof Element)) return;
  const host = target.closest<HTMLElement>(`[${HOST_ATTR}]`);
  if (!host) return;
  hovered.delete(host);
  scheduleHide(host);
}

function onResize(): void {
  if (narrow()) {
    // 窄屏不显示：清掉所有可见态，避免切回宽屏前几何过期
    for (const el of Array.from(active)) {
      const thumb = thumbs.get(el);
      if (thumb) {
        thumb.classList.remove(VISIBLE_CLASS);
        thumb.style.display = "none";
      }
    }
    active.clear();
    return;
  }
  for (const el of Array.from(active)) {
    if (!el.isConnected) {
      active.delete(el);
      continue;
    }
    update(el);
  }
}

/**
 * 全局覆盖层滚动条（无渲染输出，挂载一次即可）。
 * 放在应用根（App 顶层）；组件卸载时移除监听并清理所有 thumb。
 */
export default function OverlayScrollbar() {
  useEffect(() => {
    document.addEventListener("scroll", onScroll, true);
    document.addEventListener("mouseover", onEnter);
    document.addEventListener("mouseout", onLeave);
    window.addEventListener("resize", onResize);
    return () => {
      document.removeEventListener("scroll", onScroll, true);
      document.removeEventListener("mouseover", onEnter);
      document.removeEventListener("mouseout", onLeave);
      window.removeEventListener("resize", onResize);
      document
        .querySelectorAll(`.${THUMB_CLASS}`)
        .forEach((n) => n.remove());
      document
        .querySelectorAll(`[${HOST_ATTR}]`)
        .forEach((n) => n.removeAttribute(HOST_ATTR));
      hovered.clear();
      active.clear();
      owners.clear();
    };
  }, []);
  return null;
}
