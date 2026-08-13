/**
 * VoiceChannelPanel —— 当前频道面板（成员列表 + 控制条，M5-3 §2）。
 *
 * - 成员来自 voice store members（voice.state 合并 + members/ 对账）；
 * - 爱莉条目识别：profile.user.id 命中成员 user_id → 中性技术标签（§4.6）；
 * - 控制条复用 VoiceControls。
 */
import type { ElysiaProfile } from "../../api/types";
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
  livekit,
  wsConnection,
  micEnabled,
  elysiaProfile,
  onToggleMic,
  onLeave,
  onRejoin,
  onVolumeChange,
}: {
  channelName: string;
  livekit: LiveKitConnectionState;
  wsConnection: VoiceWSConnectionState;
  micEnabled: boolean;
  elysiaProfile: ElysiaProfile | null;
  onToggleMic: () => void;
  onLeave: () => void;
  onRejoin: () => void;
  onVolumeChange: (userId: string, volume: number) => void;
}) {
  const members = useVoiceStore((s) => s.members);
  const currentUser = useAuthStore((s) => s.currentUser);
  const list = Object.values(members);
  const elysiaUserId = elysiaProfile?.user.id ?? null;

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
              <VoiceMemberRow
                key={m.user_id}
                member={m}
                isSelf={m.user_id === currentUser?.id}
                isElysia={isElysia}
                elysiaLabel={isElysia ? elysiaStateLabel("connected") : null}
                onVolumeChange={onVolumeChange}
              />
            );
          })
        )}
      </div>
      <VoiceControls
        micEnabled={micEnabled}
        livekit={livekit}
        wsConnection={wsConnection}
        onToggleMic={onToggleMic}
        onLeave={onLeave}
        onRejoin={onRejoin}
      />
    </section>
  );
}
