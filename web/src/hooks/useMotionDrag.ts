import { useCallback, useLayoutEffect, useRef } from "react";
import { animate, useDragControls, useIsPresent, useMotionValue } from "framer-motion";
import type { PanHandler } from "framer-motion";
import { auroraquaRouteTransition } from "../components/motion/auroraquaMotion";
import { usePrefersReducedMotion } from "./usePrefersReducedMotion";

/**
 * Own one draggable surface's displacement and cancellation lifecycle.
 * Turning `drag` off alone leaves Framer's old displacement and queued drag-end
 * callback alive. Cancel the gesture before resetting its own motion value, and
 * accept release only for a gesture started while this surface is enabled.
 * Each AnimatePresence child must create its own owner; values cannot be shared
 * between the outgoing and incoming scene. Bind `offset` only to the drag layer,
 * never to the route variant's transform; a pointer down stops axis animation.
 * Normal exit releases the gesture but preserves its visible displacement; the
 * route layer can continue from that frame instead of snapping back to center.
 * A retained child that reenters returns smoothly on its own drag layer.
 */
export function useMotionDrag(enabled: boolean, onCommit: PanHandler) {
  // Subscribe here as well: an AnimatePresence exit may retain its last parent props.
  const reduced = usePrefersReducedMotion();
  const present = useIsPresent();
  const allowed = enabled && !reduced && present;
  const controls = useDragControls();
  const offset = useMotionValue(0);
  const enabledRef = useRef(allowed);
  const commitRef = useRef(onCommit);
  const gestureActive = useRef(false);
  const previouslyPresent = useRef(present);
  enabledRef.current = allowed;
  commitRef.current = onCommit;

  useLayoutEffect(() => {
    const reentering = present && !previouslyPresent.current;
    previouslyPresent.current = present;

    if (!enabled || reduced) {
      gestureActive.current = false;
      controls.cancel();
      offset.stop();
      offset.set(0);
      return;
    }
    if (!present) {
      gestureActive.current = false;
      controls.cancel();
      // Framer starts snap-back before invoking onDragEnd. A committed route
      // exit stops that spring at its current position without a visible reset.
      offset.stop();
      return;
    }
    if (reentering && offset.get() !== 0) {
      // AnimatePresence may reuse this still-visible child on a quick reversal.
      // Keep the first frame continuous; a new pointer down stops this animation
      // through Framer's own drag owner before taking over the same motion value.
      const returning = animate(offset, 0, auroraquaRouteTransition);
      return () => returning.stop();
    }
  }, [enabled, reduced, present, controls, offset]);

  useLayoutEffect(() => () => {
    gestureActive.current = false;
    controls.cancel();
    offset.stop();
  }, [controls, offset]);

  const onDragStart = useCallback<PanHandler>(() => {
    gestureActive.current = enabledRef.current;
  }, []);

  const onDragEnd = useCallback<PanHandler>((event, info) => {
    const canCommit = enabledRef.current && gestureActive.current && event.type !== "pointercancel";
    gestureActive.current = false;
    if (canCommit) commitRef.current(event, info);
  }, []);

  return { controls, offset, onDragStart, onDragEnd, allowed, reduced, present };
}
