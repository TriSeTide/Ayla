import type { ReactNode } from "react";

export function AsyncState({
  status,
  children,
  error,
  empty,
  onRetry,
}: {
  status: "loading" | "error" | "empty" | "content";
  children?: ReactNode;
  error?: string;
  empty?: ReactNode;
  onRetry?: () => void;
}) {
  if (status === "loading") {
    return <div className="async-state-loading" role="status" aria-label="正在加载"><span className="skeleton async-state-skeleton" /></div>;
  }
  if (status === "error") {
    return (
      <div className="async-state-error" role="alert">
        <p>{error || "加载失败，请稍后重试"}</p>
        {onRetry && <button type="button" className="btn btn-ghost" onClick={onRetry}>重试</button>}
      </div>
    );
  }
  if (status === "empty") return <div className="async-state-empty" role="status">{empty || "这里还没有内容"}</div>;
  return <>{children}</>;
}
