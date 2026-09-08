import { useRef, type KeyboardEvent } from "react";
import { AuroraquaNavHighlight } from "./motion/AuroraquaNavHighlight";
import "../styles/directory-filters.css";

/** Page-owned filters stay outside the result scroller in both layouts. */
export function DirectoryFilters<Value extends string>({ id, label, options, value, narrow, className = "", buttonClassName = "", onChange }: {
  id: string;
  label: string;
  options: ReadonlyArray<{ key: Value; label: string }>;
  value: Value;
  narrow: boolean;
  className?: string;
  buttonClassName?: string;
  onChange: (value: Value) => void;
}) {
  const buttons = useRef(new Map<Value, HTMLButtonElement>());
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
  return <div className={`directory-filters ${className}`} role="tablist" aria-label={label}
    aria-orientation={narrow ? "horizontal" : "vertical"}>
    {options.map((option, index) => <button key={option.key} ref={(node) => {
      if (node) buttons.current.set(option.key, node);
      else buttons.current.delete(option.key);
    }} id={`${id}-${option.key}`} type="button" role="tab" aria-selected={value === option.key}
      aria-controls={`${id}-panel`} tabIndex={value === option.key ? 0 : -1}
      className={`directory-filter ${buttonClassName} has-auroraqua-highlight${value === option.key ? " is-active" : ""}`}
      onKeyDown={(event) => onKeyDown(event, index)} onClick={() => { if (option.key !== value) onChange(option.key); }}>
      {value === option.key && <AuroraquaNavHighlight id={id} />}
      <span className="auroraqua-nav-label">{option.label}</span>
    </button>)}
  </div>;
}
