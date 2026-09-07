import { useLayoutEffect, useRef } from "react";
import type { ReactNode } from "react";
import { AnimatePresence, motion, useIsPresent } from "framer-motion";
import { usePrefersReducedMotion } from "../../hooks/usePrefersReducedMotion";
import { auroraquaPanelOrchestration, panelVariants } from "./auroraquaMotion";

/**
 * One conversation owns its subscriptions and editor at a time. The previous owner
 * finishes its panel exits before the latest requested identity mounts; rapid changes
 * do not mount intermediate conversations. The wrapper paints no second surface.
 */
export function ConversationTransition({ identity, panels = true, children }: {
  identity: string;
  panels?: boolean;
  children: ReactNode;
}) {
  return (
    <AnimatePresence mode="wait" propagate>
      <ConversationOwner key={identity} identity={identity} panels={panels}>
        {children}
      </ConversationOwner>
    </AnimatePresence>
  );
}

function ConversationOwner({ identity, panels, children }: {
  identity: string;
  panels: boolean;
  children: ReactNode;
}) {
  const present = useIsPresent();
  const reduced = usePrefersReducedMotion();
  const ref = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    ref.current?.toggleAttribute("inert", !present);
  }, [present]);

  return (
    <motion.div
      ref={ref}
      className="conversation-transition"
      data-conversation-owner={identity}
      data-motion-state={present ? "active" : "exiting"}
      aria-hidden={!present || undefined}
      style={{ pointerEvents: present ? undefined : "none" }}
      inherit={false}
      initial={reduced ? false : "enter"}
      animate="center"
      exit="exit"
      variants={panels ? auroraquaPanelOrchestration : panelVariants(reduced, "right", "left")}
    >
      {children}
    </motion.div>
  );
}
