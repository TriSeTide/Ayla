/**
 * VoiceControls —— 语音控制条（M5-3 §2）：静音切换 / 离开频道 / 连接状态。
 *
 * - 静音：乐观 UI + SDK 失败回滚（useVoiceChannel.toggleMic）；
 * - 连接状态：livekit="reconnecting" → "媒体重连中"（成员面板不清空）；
 *   livekit="failed" → 提示 + "重新加入"（媒体断线 ≠ 离开频道，不自动 leave/）；
 * - wsConnection 应用层状态一并展示（离线时 voice.state 暂停，重连后对账）。
 */
import type { LiveKitConnectionState, VoiceWSConnectionState } from "../../stores/voice";
import { IconMic } from "../icons";

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
  micEnabled,
  livekit,
  wsConnection,
  onToggleMic,
  onLeave,
  onRejoin,
}: {
  micEnabled: boolean;
  livekit: LiveKitConnectionState;
  wsConnection: VoiceWSConnectionState;
  onToggleMic: () => void;
  onLeave: () => void;
  onRejoin: () => void;
}) {
  return (
    <div className="voice-controls">
      <button
        type="button"
        className={`btn voice-mic-btn ${micEnabled ? "btn-primary" : "voice-mic-off"}`}
        onClick={onToggleMic}
        aria-pressed={micEnabled}
        aria-label={micEnabled ? "静音" : "取消静音"}
      >
        <IconMic width={15} height={15} />
        {micEnabled ? "麦克风开" : "已静音"}
      </button>
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
