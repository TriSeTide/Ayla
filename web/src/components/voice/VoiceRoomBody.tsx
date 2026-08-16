/**
 * VoiceRoomBody —— 语音房整页（进房态，F5）。
 *
 * 复用 M5-3 VoiceChannelPanel 的成员网格 + 控制排（上麦/静音/离开），新增：
 * - 返回头（回语音房卡片列表）；
 * - 房内打字输入框（开发文档 §1.9 复用群会话方案：群内语音房输入 = 群消息，
 *   仅群语音房 group 非空时显示；公开语音房无独立文字流）；
 * - 输入框滑入动画（useEnterRoomAnimation，进房 250ms 延迟 100ms，与直播同向）。
 */
import { useState } from "react";
import * as chatApi from "../../api/chat";
import type { ElysiaProfile } from "../../api/types";
import { IconSend } from "../icons";
import type { LiveKitConnectionState, VoiceWSConnectionState } from "../../stores/voice";
import { VoiceChannelPanel } from "./VoiceChannelPanel";

export function VoiceRoomBody({
  channelName,
  livekit,
  wsConnection,
  elysiaProfile,
  groupId,
  onToggleMic,
  onLeave,
  onRejoin,
  onVolumeChange,
  onLocalVolumeChange,
  onToggleMemberMuted,
  onBack,
  inputEntered,
}: {
  channelName: string;
  livekit: LiveKitConnectionState;
  wsConnection: VoiceWSConnectionState;
  elysiaProfile: ElysiaProfile | null;
  /** 群语音房的群 id：房内打字发到该群会话；公开语音房为 null（无打字框） */
  groupId: string | null;
  onToggleMic: () => void;
  onLeave: () => void;
  onRejoin: () => void;
  onVolumeChange: (userId: string, volume: number) => void;
  /** 本地麦克风音量 0~100（自己说话别人听到的响度） */
  onLocalVolumeChange: (volume: number) => void;
  /** 远端成员本地播放静音（喇叭按钮） */
  onToggleMemberMuted: (userId: string) => void;
  onBack: () => void;
  inputEntered: boolean;
}) {
  const [text, setText] = useState("");
  const [sending, setSending] = useState(false);

  // 房内打字 = 群消息（复用群会话方案，开发文档 §1.9）
  const sendText = async () => {
    const content = text.trim();
    if (!content || !groupId || sending) return;
    setSending(true);
    try {
      await chatApi.sendMessage(groupId, { type: "text", content });
      setText("");
    } catch {
      // 发送失败保留输入（可重试）；不伪造"已发送"
    } finally {
      setSending(false);
    }
  };

  return (
    <div className="voice-room-body">
      <header className="voice-room-head">
        <button type="button" className="msg-action-btn" onClick={onBack} aria-label="返回">
          ← 返回
        </button>
        <span className="voice-room-title">{channelName}</span>
      </header>

      <VoiceChannelPanel
        channelName={channelName}
        livekit={livekit}
        wsConnection={wsConnection}
        elysiaProfile={elysiaProfile}
        onToggleMic={onToggleMic}
        onLeave={onLeave}
        onRejoin={onRejoin}
        onVolumeChange={onVolumeChange}
        onLocalVolumeChange={onLocalVolumeChange}
        onToggleMemberMuted={onToggleMemberMuted}
      />

      {groupId != null && (
        <div
          className="voice-room-input"
          style={{
            transform: inputEntered ? "translateY(0)" : "translateY(100%)",
            transition: "transform 250ms var(--ease-out)",
          }}
        >
          <div className="composer-row">
            <textarea
              className="field composer-input"
              value={text}
              onChange={(e) => setText(e.target.value)}
              placeholder="在语音房内打字（发送到群消息）"
              rows={1}
            />
            <button
              type="button"
              className="btn btn-primary"
              disabled={sending || !text.trim()}
              onClick={() => void sendText()}
              aria-label="发送语音房消息"
            >
              <IconSend width={15} height={15} />
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
