import { useRealtimeStore, type RealtimeChannel, type RealtimeConnection } from "../stores/realtime";

const CHANNEL_LABELS: Record<RealtimeChannel, string> = {
  chat: "聊天",
  presence: "在线状态",
  voice: "语音",
  live: "直播",
};

const CONNECTION_LABELS: Record<RealtimeConnection, string> = {
  connecting: "重连中",
  online: "已连接",
  offline: "未连接",
  failed: "连接失败",
};

export function RealtimeStatusBanner() {
  const statuses = useRealtimeStore((s) => s.statuses);
  const degraded = (Object.entries(statuses) as Array<[RealtimeChannel, typeof statuses[RealtimeChannel]]>)
    .filter(([, value]) => value.connection === "connecting" || value.connection === "failed");
  if (degraded.length === 0) return null;
  const reconnecting = degraded.some(([, value]) => value.connection === "connecting");
  return (
    <div className="realtime-status-banner" role="status" aria-live="polite">
      <div className="realtime-status-summary">
        <span>{reconnecting ? "实时连接重连中，文字和页面功能仍可继续使用" : "实时连接暂不可用，页面数据不会被隐藏"}</span>
        <span className="realtime-status-hint">连接状态</span>
      </div>
      <ul className="realtime-status-list" aria-label="实时连接状态">
        {degraded.map(([channel, value]) => (
          <li key={channel} className={`realtime-status-item is-${value.connection}`}>
            <span className="realtime-status-dot" aria-hidden="true" />
            <span>{CHANNEL_LABELS[channel]}</span>
            <strong>{CONNECTION_LABELS[value.connection]}</strong>
            {value.lastError ? <small title={value.lastError}>{value.lastError}</small> : null}
          </li>
        ))}
      </ul>
    </div>
  );
}
