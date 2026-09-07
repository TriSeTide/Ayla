import { useEffect, useRef } from "react";
import { StablePaginationFooter } from "./StablePaginationFooter";

export interface DirectoryLoadMoreProps {
  loading: boolean;
  error: string | null;
  hasMore: boolean;
  invalidated: boolean;
  /** Long feeds preserve terminal scroll space; compact sidebars have no empty footer. */
  retainCompletedSpace?: boolean;
  loadMore: () => Promise<void>;
  refresh: () => Promise<void>;
}
export function DirectoryLoadMore({ loading, error, hasMore, invalidated, loadMore, refresh, retainCompletedSpace = true }: DirectoryLoadMoreProps) {
  const sentinel = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (loading || error || invalidated || !hasMore || !sentinel.current || typeof IntersectionObserver === "undefined") return;
    const observer = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) void loadMore();
    }, { rootMargin: "240px 0px" });
    observer.observe(sentinel.current);
    return () => observer.disconnect();
  }, [loading, error, invalidated, hasMore, loadMore]);
  if (!retainCompletedSpace && !loading && !error && !hasMore && !invalidated) return null;
  return <StablePaginationFooter
    ref={sentinel}
    className="home-load-more directory-load-more"
    role={error && !invalidated ? "alert" : "status"}
    aria-label={loading ? "加载更多中" : hasMore ? "加载更多" : undefined}
    aria-busy={loading}
  >
    {invalidated ? (
      <button type="button" className="btn btn-ghost" disabled={loading} onClick={() => void refresh()}>
        列表有更新，刷新后继续加载
      </button>
    ) : error ? <>
      <span>{error}</span>
      <button type="button" className="btn btn-ghost" disabled={loading} onClick={() => void (hasMore ? loadMore() : refresh())}>重试</button>
    </> : loading ? <span className="pagination-loading-dots">
      <span className="home-load-dot" /><span className="home-load-dot" /><span className="home-load-dot" />
    </span> : hasMore ? <button type="button" className="btn btn-ghost" onClick={() => void loadMore()}>加载更多</button> : null}
  </StablePaginationFooter>;
}
