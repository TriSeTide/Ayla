import { useLayoutEffect, useRef } from "react";
import { AURORAQUA_MOTION } from "../components/motion/auroraquaMotion";
import { usePrefersReducedMotion } from "./usePrefersReducedMotion";

/** Exit downward, then re-enter the same input DOM without changing its draft/focus owner. */
export function usePanelSwapMotion<T extends HTMLElement>(identity: string, selector: string, enabled = true) {
  const ref = useRef<T>(null);
  const previous = useRef(identity);
  const running = useRef<Animation | null>(null);
  const reduced = usePrefersReducedMotion();
  useLayoutEffect(() => {
    const changed = previous.current !== identity;
    previous.current = identity;
    const panel = ref.current?.querySelector<HTMLElement>(selector);
    if (!enabled || reduced) {
      running.current?.cancel();
      running.current = null;
      return;
    }
    if (!changed || !panel || typeof panel.animate !== "function") return;
    // A rapid selection continues from the visible frame before retiring the old animation.
    const current = getComputedStyle(panel);
    const start = { opacity: current.opacity || "1", transform: current.transform || "none" };
    running.current?.cancel();
    const easing = `cubic-bezier(${AURORAQUA_MOTION.easeOut.join(",")})`;
    const animation = panel.animate([
      { ...start, offset: 0, easing },
      { opacity: 0, transform: `translateY(${AURORAQUA_MOTION.distance}px)`, offset: 0.5, easing },
      { opacity: 1, transform: "translateY(0)", offset: 1 },
    ], { duration: AURORAQUA_MOTION.duration * 2000 });
    running.current = animation;
    animation.onfinish = () => {
      if (running.current !== animation) return;
      running.current = null;
      animation.cancel();
    };
  }, [identity, selector, enabled, reduced]);
  useLayoutEffect(() => () => {
    running.current?.cancel();
    running.current = null;
  }, []);
  return ref;
}
