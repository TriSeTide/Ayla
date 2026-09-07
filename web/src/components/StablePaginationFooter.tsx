import { forwardRef, useCallback, useLayoutEffect, useRef, type HTMLAttributes } from "react";

/** Keep this footer's largest measured height while its list remains mounted. */
export const StablePaginationFooter = forwardRef<HTMLDivElement, HTMLAttributes<HTMLDivElement>>(
  function StablePaginationFooter({ className = "", ...props }, forwardedRef) {
    const elementRef = useRef<HTMLDivElement | null>(null);
    const tallest = useRef(0);
    const setRef = useCallback((node: HTMLDivElement | null) => {
      elementRef.current = node;
      if (typeof forwardedRef === "function") forwardedRef(node);
      else if (forwardedRef) forwardedRef.current = node;
    }, [forwardedRef]);

    const retainHeight = useCallback(() => {
      const node = elementRef.current;
      if (!node) return;
      const height = node.offsetHeight;
      if (height > tallest.current) tallest.current = height;
      if (tallest.current > 0) node.style.minHeight = `${tallest.current}px`;
    }, []);

    // Measure before paint when a wrapped error is replaced by retry/loading.
    useLayoutEffect(retainHeight);
    useLayoutEffect(() => {
      const node = elementRef.current;
      if (!node || typeof ResizeObserver === "undefined") return;
      const observer = new ResizeObserver(retainHeight);
      observer.observe(node);
      return () => observer.disconnect();
    }, [retainHeight]);

    return <div {...props} ref={setRef} className={`stable-pagination-footer ${className}`.trim()} />;
  },
);
