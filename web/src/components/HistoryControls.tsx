import { StablePaginationFooter } from "./StablePaginationFooter";

export interface HistoryControlsProps {
  loading: boolean;
  error: string | null;
  hasMore: boolean;
  hasNewer: boolean;
  loadOlder: () => Promise<void>;
  returnLatest: () => Promise<void>;
  retry: () => Promise<void>;
}

/** Controls are a projection boundary, with explicit continuation and retry. */
export function HistoryControls(props: HistoryControlsProps) {
  return <StablePaginationFooter className="home-load-more history-load-more"
    role={props.error ? "alert" : "status"} aria-busy={props.loading}>
    {props.error && <><span>{props.error}</span><button className="btn btn-ghost" type="button"
      disabled={props.loading} onClick={() => void props.retry()}>重试</button></>}
    {props.loading ? <span className="pagination-loading-dots" aria-label="正在加载历史">
      <span className="home-load-dot" /><span className="home-load-dot" /><span className="home-load-dot" />
    </span> : props.hasMore && <button className="btn btn-ghost" type="button"
      onClick={() => void props.loadOlder()}>加载更早记录</button>}
    {props.hasNewer && <button className="btn btn-ghost" type="button" disabled={props.loading}
      onClick={() => void props.returnLatest()}>返回最新消息</button>}
  </StablePaginationFooter>;
}
