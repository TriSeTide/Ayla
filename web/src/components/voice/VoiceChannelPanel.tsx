/**
 * VoiceChannelPanel —— 当前频道面板（成员列表 + 控制条，M5-3 §2）。
 *
 * - 成员来自 voice store members（voice.state 合并 + members/ 对账）；
 * - 爱莉条目识别：profile.user.id 命中成员 user_id → 中性技术标签（§4.6）；
 * - 控制条复用 VoiceControls。
 */
import { Fragment, useState } from "react";
import type { ElysiaProfile } from "../../api/types";
import * as voiceApi from "../../api/voice";
import { useAuthStore } from "../../stores/auth";
import type { LiveKitConnectionState, VoiceWSConnectionState } from "../../stores/voice";
import { useVoiceStore } from "../../stores/voice";
import { VoiceControls } from "./VoiceControls";
import { VoiceMemberRow } from "./VoiceMemberRow";

/** 爱莉 voice.state 技术状态 → 中性标签（§4.6：禁止主观化文案） */
export function elysiaStateLabel(techState: string | null): string | null {
  switch (techState) {
    case "connected":
    case "active":
      return "通话中";
    case "speaking":
      return "输出中";
    case "listening":
      return "接收中";
    default:
      return null;
  }
}

export function VoiceChannelPanel({
  channelName,
  channelId,
  ownerId,
  livekit,
  wsConnection,
  elysiaProfile,
  onToggleMic,
  onLeave,
  onRejoin,
  onVolumeChange,
  onLocalVolumeChange,
  onToggleMemberMuted,
}: {
  channelName: string;
  channelId?: string;
  ownerId?: string;
  livekit: LiveKitConnectionState;
  wsConnection: VoiceWSConnectionState;
  elysiaProfile: ElysiaProfile | null;
  onToggleMic: () => void;
  onLeave: () => void;
  onRejoin: () => void;
  onVolumeChange: (userId: string, volume: number) => void;
  /** 本地麦克风音量 0~100 */
  onLocalVolumeChange: (volume: number) => void;
  /** 远端成员本地播放静音（喇叭按钮） */
  onToggleMemberMuted: (userId: string) => void;
}) {
  const members = useVoiceStore((s) => s.members);
  const currentUser = useAuthStore((s) => s.currentUser);
  const list = Object.values(members);
  const elysiaUserId = elysiaProfile?.user.id ?? null;
  const isOwner = ownerId != null && ownerId === currentUser?.id;
  const [actionError, setActionError] = useState<string | null>(null);
  const [busyUserId, setBusyUserId] = useState<string | null>(null);
  const memberAction = async (userId: string, action: "kick" | "transfer") => {
    if (!channelId || busyUserId) return;
    setBusyUserId(userId);
    setActionError(null);
    try {
      await voiceApi.actionVoiceMember(channelId, userId, action);
      if (action === "transfer") setActionError("房主已转让");
    } catch (error) {
      setActionError(error instanceof Error ? error.message : "房主操作失败");
    } finally {
      setBusyUserId(null);
    }
  };

  return (
    <section className="voice-panel">
      <header className="voice-panel-head">
        <h3 className="voice-panel-title">{channelName}</h3>
        <span className="voice-panel-count">{list.length} 人</span>
      </header>
      <div className="voice-member-list">
        {list.length === 0 ? (
          <div className="voice-list-empty">同步成员中…</div>
        ) : (
          list.map((m) => {
            const isElysia = elysiaUserId != null && m.user_id === elysiaUserId;
            return (
              <Fragment key={m.user_id}>
              <VoiceMemberRow
                key={m.user_id}
                member={m}
                isSelf={m.user_id === currentUser?.id}
                isElysia={isElysia}
                elysiaLabel={isElysia ? elysiaStateLabel("connected") : null}
                onVolumeChange={onVolumeChange}
                onLocalVolumeChange={onLocalVolumeChange}
                onToggleMic={onToggleMic}
                onToggleMemberMuted={onToggleMemberMuted}
              />
              {isOwner && m.user_id !== currentUser?.id && (
                <div className="voice-owner-member-actions">
                  <button type="button" className="btn btn-ghost" disabled={busyUserId !== null} onClick={() => void memberAction(m.user_id, "kick")}>{busyUserId === m.user_id ? "处理中…" : "踢出"}</button>
                  <button type="button" className="btn btn-ghost" disabled={busyUserId !== null} onClick={() => void memberAction(m.user_id, "transfer")}>转让房主</button>
                </div>
              )}
              </Fragment>
            );
          })
        )}
      </div>
      {actionError && <div className="chat-notice" role="alert">{actionError}</div>}
      <VoiceControls
        livekit={livekit}
        wsConnection={wsConnection}
        onLeave={onLeave}
        onRejoin={onRejoin}
      />
    </section>
  );
}
