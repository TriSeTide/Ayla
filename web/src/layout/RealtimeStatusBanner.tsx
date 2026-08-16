import { useRealtimeStore } from "../stores/realtime";

export function RealtimeStatusBanner() {
  const statuses = useRealtimeStore((s) => s.statuses);
  const degraded = Object.entries(statuses).filter(([, value]) => value.connection === "connecting" || value.connection === "failed");
  if (degraded.length === 0) return null;
  const reconnecting = degraded.some(([, value]) => value.connection === "connecting");
  return (
    <div className="realtime-status-banner" role="status">
      <span>{reconnecting ? "实时连接重连中，文字和页面功能仍可继续使用" : "实时连接暂不可用，页面数据不会被隐藏"}</span>
    </div>
  );
}
