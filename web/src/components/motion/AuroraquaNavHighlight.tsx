import { motion } from "framer-motion";
import { usePrefersReducedMotion } from "../../hooks/usePrefersReducedMotion";
import { auroraquaIndicatorTransition } from "./auroraquaMotion";

/**
 * PillTabBar's moving selection surface, using existing Framer layout measurement.
 * The parent supplies a useId() scoped to this navigation instance so exiting pages,
 * simultaneous sidebars, and separate lists never share a projection owner.
 * Colors and geometry stay in CSS; this decorative surface never owns input events.
 */
export function AuroraquaNavHighlight({ id, className = "", sharedLayout = true }: { id: string; className?: string; sharedLayout?: boolean }) {
  const reduced = usePrefersReducedMotion();
  return (
    <motion.span
      className={`auroraqua-nav-highlight ${className}`}
      aria-hidden="true"
      layoutId={reduced || !sharedLayout ? undefined : id}
      initial={false}
      transition={reduced ? { duration: 0 } : auroraquaIndicatorTransition}
    />
  );
}
