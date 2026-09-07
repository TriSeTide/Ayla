import { useLayoutEffect, useRef } from "react";
import { AURORAQUA_MOTION } from "../components/motion/auroraquaMotion";
import { usePrefersReducedMotion } from "./usePrefersReducedMotion";

/**
 * Animate the existing selected panel using Auroraqua's route cadence.
 * No key, duplicate panel, or remount is introduced: sessions, drafts and scroll owners
 * remain with their current components. A cancelled Web Animation restores original
 * styles automatically, including when reduced motion changes during a transition.
 * `selector` scopes the effect to the content below a navigation bar; `ready` lets an
 * async filter wait for its actual result before beginning the effect.
 */
export function useTabPanelMotion<T extends HTMLElement>(
  selection: string,
  selector?: string,
  ready = true,
  establishBaseline = false,
) {
  const ref = useRef<T>(null);
  const previous = useRef(selection);
  const reduced = usePrefersReducedMotion();

  useLayoutEffect(() => {
    if (establishBaseline) {
      previous.current = selection;
      return;
    }
    if (!ready) return;
    const changed = previous.current !== selection;
    previous.current = selection;
    if (!changed || reduced) return;
    const root = ref.current;
    const panel = selector ? root?.querySelector<HTMLElement>(selector) : root;
    if (!panel || typeof panel.animate !== "function") return;
    const animation = panel.animate(
      [
        { opacity: 0, transform: `translateX(${AURORAQUA_MOTION.distance}px)` },
        { opacity: 1, transform: "translateX(0)" },
      ],
      {
        duration: AURORAQUA_MOTION.duration * 1000,
        easing: `cubic-bezier(${AURORAQUA_MOTION.easeInOut.join(",")})`,
      },
    );
    return () => animation.cancel();
  }, [selection, selector, ready, reduced, establishBaseline]);

  return ref;
}
