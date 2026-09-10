/**
 * VoiceControls —— 语音控制条（M5-3 §2）：离开频道 / 断线重入。
 *
 * - 麦克风开关已上移：由成员行内自己条目的麦克风按钮承担（VoiceMemberRow
 *   onToggleMic），这里不再放全局开关按钮；
 * - livekit="failed" → 显示"重新加入"（媒体断线 ≠ 离开频道，不自动 leave/）。
 */
import type { LiveKitConnectionState } from "../../stores/voice";

export function VoiceControls({
  livekit,
  onLeave,
  onRejoin,
}: {
  livekit: LiveKitConnectionState;
  onLeave: () => void;
  onRejoin: () => void;
}) {
  return (
    <div className="voice-controls">
      <button type="button" className="btn voice-leave-btn" onClick={onLeave}>
        离开频道
      </button>
      {livekit === "failed" && (
        <button type="button" className="btn btn-primary voice-rejoin-btn" onClick={onRejoin}>
          重新加入
        </button>
      )}
    </div>
  );
}
