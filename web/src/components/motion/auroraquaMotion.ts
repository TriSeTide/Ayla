import type { Transition, Variants } from "framer-motion";

/**
 * Auroraqua UI motion recipes, adapted to Ayla's existing navigation owners.
 * Sources: micromimo/Auroraqua-UI, src/routes.jsx and src/pages/Case3.jsx
 * (20px / 300ms / easeInOut), components/ui/animations.jsx
 * (scale .95 / 500ms / easeOut; stagger 20px / 300ms / 50ms),
 * and components/ui/PillTabBar.jsx (300ms ease-out indicator).
 * No palette, business state, route identity, or gesture thresholds live here.
 */
export const AURORAQUA_MOTION = {
  distance: 20,
  fadeScale: 0.95,
  duration: 0.3,
  fadeDuration: 0.5,
  staggerMs: 50,
  easeOut: [0, 0, 0.58, 1] as [number, number, number, number],
  easeInOut: [0.42, 0, 0.58, 1] as [number, number, number, number],
};

export const auroraquaRouteTransition: Transition = {
  duration: AURORAQUA_MOTION.duration,
  ease: AURORAQUA_MOTION.easeInOut,
};

export const auroraquaIndicatorTransition: Transition = {
  duration: AURORAQUA_MOTION.duration,
  ease: AURORAQUA_MOTION.easeOut,
};

/** A transparent variant owner coordinates children without adding another transform. */
export const auroraquaPanelOrchestration: Variants = { enter: {}, center: {}, exit: {} };

type PanelEdge = "left" | "right" | "top" | "bottom";

/** A surface enters from its own edge; messages can leave through the opposite edge. */
export function panelVariants(reduced: boolean, edge: PanelEdge, exitEdge: PanelEdge = edge): Variants {
  const offset = (from: PanelEdge) => {
    const distance = reduced ? 0 : AURORAQUA_MOTION.distance;
    return {
      x: from === "left" ? -distance : from === "right" ? distance : 0,
      y: from === "top" ? -distance : from === "bottom" ? distance : 0,
    };
  };
  const transition = reduced ? { duration: 0 } : auroraquaRouteTransition;
  return {
    enter: { ...offset(edge), opacity: reduced ? 1 : 0 },
    center: { x: 0, y: 0, opacity: 1, transition },
    exit: { ...offset(exitEdge), opacity: 0, transition },
  };
}

/** A page's own swipe direction is retained; reduced motion also clears an active drag transform. */
export function directionalVariants(reduced: boolean, axis: "x" | "y" = "x"): Variants {
  const transition = reduced ? { duration: 0 } : auroraquaRouteTransition;
  const position = (distance: number) => axis === "x" ? { x: distance } : { y: distance };
  return {
    enter: (direction: number) => ({
      ...position(reduced ? 0 : direction * AURORAQUA_MOTION.distance),
      opacity: reduced ? 1 : 0,
    }),
    center: { ...position(0), opacity: 1, transition },
    exit: (direction: number) => ({
      ...position(reduced ? 0 : -direction * AURORAQUA_MOTION.distance),
      opacity: 0,
      transition,
    }),
  };
}

/** FadeInCard recipe for a content surface; group entry adds its existing upward choreography. */
export function surfaceEntryVariants(reduced: boolean, delay = 0): Variants {
  return {
    out: reduced
      ? { opacity: 0 }
      : { opacity: 0, y: AURORAQUA_MOTION.distance, scale: AURORAQUA_MOTION.fadeScale },
    in: {
      opacity: 1,
      y: 0,
      scale: 1,
      transition: reduced
        ? { duration: 0 }
        : { duration: AURORAQUA_MOTION.fadeDuration, ease: AURORAQUA_MOTION.easeOut, delay },
    },
  };
}

/** Keep the sidebar's existing height ownership, with Auroraqua's 300ms reveal cadence. */
export function disclosureVariants(reduced: boolean): Variants {
  const transition = reduced ? { duration: 0 } : auroraquaIndicatorTransition;
  return {
    open: { height: "auto", opacity: 1, transition },
    closed: { height: 0, opacity: 0, transition },
  };
}
