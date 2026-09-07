import { useLayoutEffect, type RefObject } from "react";

const sections = [
  { row: ".channel-scene-row--chat", content: ".channel-subgroups" },
  { row: ".channel-scene-row--voice", content: ".channel-voice-rooms" },
  { row: ".channel-scene-row--live", content: ".channel-live-rooms" },
] as const;

/** Clip scrolling content to the gap between its actual sticky scene headers.
 *
 * Headers can pin to either edge of the same scrollport. A paint-only clip keeps
 * their translucent material clear without changing list layout, scroll bounds,
 * disclosure heights, or the transforms owned by room reordering.
 */
export function useSidebarContentClip(ref: RefObject<HTMLDivElement>) {
  // Refresh the observed children after every commit: AnimatePresence can retain
  // an exiting dropdown while another commit adds or removes its siblings.
  useLayoutEffect(() => {
    const container = ref.current;
    if (!container) return;
    let active = true;
    const ownedClips = new Map<HTMLElement, string>();
    const sync = () => {
      if (!active) return;
      const viewport = container.getBoundingClientRect();
      const viewportTop = viewport.top + container.clientTop;
      const viewportBottom = viewportTop + container.clientHeight;
      const gap = Number.parseFloat(getComputedStyle(container).rowGap) || 0;
      // Read every rectangle before writing any style so scroll needs one
      // layout snapshot, including during disclosure height animations.
      const geometry = sections.map(({ row, content }) => {
        const header = container.querySelector<HTMLElement>(`:scope > ${row}`);
        const dropdown = container.querySelector<HTMLElement>(`:scope > ${content}`);
        return {
          header: header?.getBoundingClientRect(),
          dropdown,
          rect: dropdown?.getBoundingClientRect(),
        };
      });
      const clips = geometry.flatMap(({ header, dropdown, rect }, index) => {
        if (!header || !dropdown || !rect) return [];
        const nextHeader = geometry[index + 1]?.header;
        // Keep the existing flex gaps empty when adjacent headers are pinned;
        // otherwise a few pixels of old glyphs would survive between the cards.
        const start = Math.max(viewportTop, header.bottom + gap, rect.top);
        const end = Math.min(viewportBottom, nextHeader ? nextHeader.top - gap : viewportBottom, rect.bottom);
        const height = Math.max(0, rect.height);
        const top = Math.min(height, Math.max(0, start - rect.top));
        const bottom = end <= start
          ? height - top
          : Math.min(height - top, Math.max(0, rect.bottom - end));
        return [{ dropdown, value: `inset(${top}px 0px ${bottom}px 0px)` }];
      });
      for (const { dropdown, value } of clips) {
        if (ownedClips.get(dropdown) !== value) {
          dropdown.style.clipPath = value;
          ownedClips.set(dropdown, value);
        }
      }
    };
    container.addEventListener("scroll", sync, { passive: true });
    const observer = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(sync);
    observer?.observe(container);
    const observedChildren = new Set<Element>();
    const refreshChildren = () => {
      if (!active) return;
      const children = new Set(container.children);
      for (const child of observedChildren) {
        if (!children.has(child)) {
          observer?.unobserve(child);
          observedChildren.delete(child);
        }
      }
      for (const child of children) {
        if (!observedChildren.has(child)) {
          observer?.observe(child);
          observedChildren.add(child);
        }
      }
      for (const [element, value] of ownedClips) {
        if (!children.has(element)) {
          if (element.style.clipPath === value) element.style.removeProperty("clip-path");
          ownedClips.delete(element);
        }
      }
      sync();
    };
    refreshChildren();
    // AnimatePresence may remove a zero-height exit internally without another
    // parent commit or resize. Its disappearing flex gap still moves headers.
    // Observe only direct child identity, never our clip style mutations.
    const mutations = typeof MutationObserver === "undefined" ? null : new MutationObserver(refreshChildren);
    mutations?.observe(container, { childList: true });
    return () => {
      active = false;
      container.removeEventListener("scroll", sync);
      mutations?.disconnect();
      observer?.disconnect();
      for (const [element, value] of ownedClips) {
        if (element.style.clipPath === value) element.style.removeProperty("clip-path");
      }
    };
  });
}
