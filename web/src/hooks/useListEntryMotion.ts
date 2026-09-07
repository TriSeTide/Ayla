import { useLayoutEffect, useRef, type RefObject } from "react";
import { AURORAQUA_MOTION } from "../components/motion/auroraquaMotion";
import { staggerDelay } from "./useRevealOnEnter";
import { usePrefersReducedMotion } from "./usePrefersReducedMotion";

/** Reveal only DOM items newly committed in this batch; existing items never restart. */
export function useListEntryMotion<T extends HTMLElement>(
  root: RefObject<T | null>,
  selector: string,
  suppressed = false,
) {
  const seen = useRef(new WeakSet<HTMLElement>());
  const running = useRef(new Map<HTMLElement, Animation>());
  const reduced = usePrefersReducedMotion();

  // Run after every commit: async pages, masonry columns and WS additions share the
  // same boundary. No loading flag can remove/re-add animation on retained cards.
  useLayoutEffect(() => {
    for (const [node, animation] of running.current) {
      if (reduced || suppressed || !node.isConnected) {
        animation.cancel();
        running.current.delete(node);
      }
    }
    let index = 0;
    for (const node of root.current?.querySelectorAll<HTMLElement>(selector) ?? []) {
      if (seen.current.has(node)) continue;
      seen.current.add(node);
      if (reduced || suppressed || typeof node.animate !== "function") continue;
      const animation = node.animate(
        [
          { opacity: 0, transform: `translateY(${AURORAQUA_MOTION.distance}px)` },
          { opacity: 1, transform: "translateY(0)" },
        ],
        { duration: 300, delay: staggerDelay(index++), easing: "ease-out", fill: "backwards" },
      );
      running.current.set(node, animation);
      animation.onfinish = () => {
        running.current.delete(node);
        animation.cancel();
      };
    }
  });

  useLayoutEffect(() => () => {
    for (const animation of running.current.values()) animation.cancel();
    running.current.clear();
    seen.current = new WeakSet<HTMLElement>();
  }, []);
}
