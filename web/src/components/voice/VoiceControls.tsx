/**
 * VoiceControls —— 语音控制条（M5-3 §2）：离开频道 / 连接状态。
 *
 * - 麦克风开关已上移：由成员行内自己条目的麦克风按钮承担（VoiceMemberRow
 *   onToggleMic），这里不再放全局开关按钮；
 * - 连接状态：livekit="reconnecting" → "媒体重连中"（成员面板不清空）；
 *   livekit="failed" → 提示 + "重新加入"（媒体断线 ≠ 离开频道，不自动 leave/）；
 * - wsConnection 应用层状态一并展示（离线时 voice.state 暂停，重连后对账）。
 */
import type { LiveKitConnectionState, VoiceWSConnectionState } from "../../stores/voice";

function livekitLabel(s: LiveKitConnectionState): string {
  switch (s) {
    case "connected":
      return "媒体已连接";
    case "connecting":
      return "媒体连接中…";
    case "reconnecting":
      return "媒体重连中…";
    case "failed":
      return "媒体连接断开";
    default:
      return "未连接";
  }
}

export function VoiceControls({
  livekit,
  wsConnection,
  onLeave,
  onRejoin,
}: {
  livekit: LiveKitConnectionState;
  wsConnection: VoiceWSConnectionState;
  onLeave: () => void;
  onRejoin: () => void;
}) {
  return (
    <div className="voice-controls">
      <button type="button" className="btn voice-leave-btn" onClick={onLeave}>
        离开频道
      </button>
      <div className="voice-conn-status">
        <span className={`status-dot ${livekit === "connected" ? "online" : livekit === "failed" ? "offline" : "connecting"}`} />
        {livekitLabel(livekit)}
        {livekit === "failed" && (
          <button type="button" className="btn btn-primary voice-rejoin-btn" onClick={onRejoin}>
            重新加入
          </button>
        )}
        {wsConnection !== "online" && (
          <span className="voice-ws-state">
            · 状态同步{wsConnection === "connecting" ? "重连中…" : "离线"}
          </span>
        )}
      </div>
    </div>
  );
}
