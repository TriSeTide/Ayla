import { useSyncExternalStore } from "react";

const QUERY = "(prefers-reduced-motion: reduce)";

function readPreference(): boolean {
  return typeof window !== "undefined" && typeof window.matchMedia === "function"
    ? window.matchMedia(QUERY).matches
    : false;
}

function subscribe(onChange: () => void): () => void {
  if (typeof window === "undefined" || typeof window.matchMedia !== "function") return () => {};
  const media = window.matchMedia(QUERY);
  if (typeof media.addEventListener === "function") {
    media.addEventListener("change", onChange);
    return () => media.removeEventListener("change", onChange);
  }
  // Older WebViews expose the legacy MediaQueryList listener API.
  media.addListener?.(onChange);
  return () => media.removeListener?.(onChange);
}

/** Synchronous first frame and live preference changes, including a currently mounted page. */
export function usePrefersReducedMotion(): boolean {
  return useSyncExternalStore(subscribe, readPreference, () => false);
}
