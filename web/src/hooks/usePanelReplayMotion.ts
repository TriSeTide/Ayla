import { useLayoutEffect, useRef } from "react";
import { AURORAQUA_MOTION } from "../components/motion/auroraquaMotion";
import { usePrefersReducedMotion } from "./usePrefersReducedMotion";

export interface PanelReplayTarget {
  selector: string;
  edge: "left" | "right" | "top" | "bottom";
}

/** Re-enter existing media panels when their room identity changes, without remounting owners. */
export function usePanelReplayMotion<T extends HTMLElement>(
  identity: string,
  panels: readonly PanelReplayTarget[],
  enabled = true,
) {
  const ref = useRef<T>(null);
  const reduced = usePrefersReducedMotion();
  useLayoutEffect(() => {
    if (!enabled || reduced) return;
    const root = ref.current;
    if (!root) return;
    const animations: Animation[] = [];
    for (const { selector, edge } of panels) {
      const panel = root.querySelector<HTMLElement>(selector);
      if (!panel || typeof panel.animate !== "function") continue;
      const distance = AURORAQUA_MOTION.distance;
      const x = edge === "left" ? -distance : edge === "right" ? distance : 0;
      const y = edge === "top" ? -distance : edge === "bottom" ? distance : 0;
      animations.push(panel.animate(
        [{ opacity: 0, transform: `translate(${x}px, ${y}px)` }, { opacity: 1, transform: "translate(0px, 0px)" }],
        { duration: AURORAQUA_MOTION.duration * 1000, easing: `cubic-bezier(${AURORAQUA_MOTION.easeOut.join(",")})` },
      ));
    }
    return () => animations.forEach((animation) => animation.cancel());
  }, [identity, panels, enabled, reduced]);
  return ref;
}
