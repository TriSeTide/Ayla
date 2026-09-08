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
  // 数据在加载过程中被更新（invalidated）→ 自动重新拉取恢复，不打扰用户；
  // 刷新期间再有更新（revision 变化）会保持 invalidated 继续刷新，直到数据稳定。
  useEffect(() => {
    if (invalidated && !loading) void refresh();
  }, [invalidated, loading, refresh]);
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
    aria-label={loading || invalidated ? "加载更多中" : hasMore ? "加载更多" : undefined}
    aria-busy={loading || invalidated}
  >
    {invalidated ? <span className="pagination-loading-dots" role="status" aria-label="正在刷新列表">
      <span className="home-load-dot" /><span className="home-load-dot" /><span className="home-load-dot" />
    </span> : error ? <>
      <span>{error}</span>
      <button type="button" className="btn btn-ghost" disabled={loading} onClick={() => void (hasMore ? loadMore() : refresh())}>重试</button>
    </> : loading ? <span className="pagination-loading-dots">
      <span className="home-load-dot" /><span className="home-load-dot" /><span className="home-load-dot" />
    </span> : hasMore ? <button type="button" className="btn btn-ghost" onClick={() => void loadMore()}>加载更多</button> : null}
  </StablePaginationFooter>;
}
