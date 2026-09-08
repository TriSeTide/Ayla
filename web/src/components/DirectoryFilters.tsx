import { useCallback, useLayoutEffect, useRef, type KeyboardEvent, type ReactNode, type SyntheticEvent } from "react";
import { AuroraquaNavHighlight } from "./motion/AuroraquaNavHighlight";
import "../styles/directory-filters.css";

/** Page-owned filters stay outside the result scroller in both layouts. */
export function DirectoryFilters<Value extends string>({ id, label, options, value, narrow, className = "", buttonClassName = "", decor, leading, onChange }: {
  id: string;
  label: string;
  options: ReadonlyArray<{ key: Value; label: string }>;
  value: Value;
  narrow: boolean;
  className?: string;
  buttonClassName?: string;
  /** 仅装饰的侧栏图标；不属于交互控件，窄屏隐藏。 */
  decor?: ReactNode;
  /** 宽屏侧栏左上角的独立操作（如返回键）；窄屏由 AppShell 顶栏接管，不渲染。 */
  leading?: ReactNode;
  onChange: (value: Value) => void;
}) {
  const strip = useRef<HTMLDivElement>(null);
  const buttons = useRef(new Map<Value, HTMLButtonElement>());
  const revealButton = useCallback((button: HTMLButtonElement) => {
    const list = strip.current;
    if (!list || !list.clientWidth || !list.clientHeight) return;
    const bounds = list.getBoundingClientRect();
    const target = button.getBoundingClientRect();
    const style = getComputedStyle(list);
    const padding = parseFloat(narrow ? style.scrollPaddingInlineStart : style.scrollPaddingBlockStart) || 0;
    const start = (narrow ? bounds.left + list.clientLeft : bounds.top + list.clientTop) + padding;
    const end = start + (narrow ? list.clientWidth : list.clientHeight) - padding * 2;
    const delta = (narrow ? target.left : target.top) < start
      ? (narrow ? target.left : target.top) - start
      : Math.max(0, (narrow ? target.right : target.bottom) - end);
    // Move only the filter strip, preserving the independent result scroll position.
    if (narrow) list.scrollLeft += delta;
    else list.scrollTop += delta;
  }, [narrow]);
  useLayoutEffect(() => {
    const revealSelected = () => {
      const selected = buttons.current.get(value);
      if (selected) revealButton(selected);
    };
    revealSelected();
    if (!strip.current || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(revealSelected);
    observer.observe(strip.current);
    return () => observer.disconnect();
  }, [options, revealButton, value]);
  const keepNativeSwipe = (event: SyntheticEvent) => {
    if (narrow) event.stopPropagation();
  };
  const onKeyDown = (event: KeyboardEvent<HTMLButtonElement>, index: number) => {
    const nextKey = narrow ? "ArrowRight" : "ArrowDown";
    const previousKey = narrow ? "ArrowLeft" : "ArrowUp";
    const nextIndex = event.key === "Home" ? 0 : event.key === "End" ? options.length - 1
      : event.key === nextKey ? (index + 1) % options.length
      : event.key === previousKey ? (index - 1 + options.length) % options.length : null;
    if (nextIndex == null) return;
    event.preventDefault();
    const next = options[nextIndex].key;
    buttons.current.get(next)?.focus({ preventScroll: true });
    if (next !== value) onChange(next);
  };
  return <div ref={strip} className={`directory-filters ${className}`} role="tablist" aria-label={label}
    aria-orientation={narrow ? "horizontal" : "vertical"}
    onPointerDownCapture={keepNativeSwipe} onTouchStartCapture={keepNativeSwipe}
    onTouchMoveCapture={keepNativeSwipe} onTouchEndCapture={keepNativeSwipe} onTouchCancelCapture={keepNativeSwipe}>
    {!narrow && leading}
    {decor}
    {options.map((option, index) => <button key={option.key} ref={(node) => {
      if (node) buttons.current.set(option.key, node);
      else buttons.current.delete(option.key);
    }} id={`${id}-${option.key}`} type="button" role="tab" aria-selected={value === option.key}
      aria-controls={`${id}-panel`} tabIndex={value === option.key ? 0 : -1}
      className={`directory-filter ${buttonClassName} has-auroraqua-highlight${value === option.key ? " is-active" : ""}`}
      onFocus={(event) => revealButton(event.currentTarget)}
      onKeyDown={(event) => onKeyDown(event, index)} onClick={() => { if (option.key !== value) onChange(option.key); }}>
      {value === option.key && <AuroraquaNavHighlight id={id} />}
      <span className="auroraqua-nav-label">{option.label}</span>
    </button>)}
  </div>;
}
