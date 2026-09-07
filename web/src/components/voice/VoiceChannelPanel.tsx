/**
 * VoiceChannelPanel —— 当前频道面板（成员列表 + 控制条，M5-3 §2）。
 *
 * - 可见成员由独立 cursor 页读取；媒体状态取 voice store 的完整成员对账；
 * - 爱莉条目识别：profile.user.id 命中成员 user_id → 中性技术标签（§4.6）；
 * - 控制条复用 VoiceControls。
 */
import { Fragment, useCallback, useEffect, useRef, useState } from "react";
import type { ElysiaProfile } from "../../api/types";
import * as voiceApi from "../../api/voice";
import { useAuthStore } from "../../stores/auth";
import type { LiveKitConnectionState, VoiceWSConnectionState } from "../../stores/voice";
import { useVoiceStore } from "../../stores/voice";
import { VoiceControls } from "./VoiceControls";
import { VoiceMemberRow } from "./VoiceMemberRow";
import { usePagedMediaList } from "../../hooks/usePagedMediaList";
import { DirectoryLoadMore } from "../DirectoryLoadMore";
import { voiceWS } from "../../ws/voice";

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
  connectionError,
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
  connectionError?: string | null;
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
  const currentChannelId = useVoiceStore((s) => s.currentChannelId);
  const currentUser = useAuthStore((s) => s.currentUser);
  const scope = `voice-members:${currentUser?.id ?? ""}:${channelId ?? ""}`;
  const currentScope = useRef(scope);
  currentScope.current = scope;
  const memberRevision = useRef(0);
  const fetchPage = useCallback(async (cursor: string | null) => {
    const revision = memberRevision.current;
    const page = await voiceApi.listVoiceChannelMembersPage(channelId!, { cursor, limit: 20 });
    if (memberRevision.current !== revision) throw new Error("成员列表已更新，请刷新后继续");
    return page;
  }, [channelId]);
  const pages = usePagedMediaList(scope, fetchPage, Boolean(channelId));
  const [invalidated, setInvalidated] = useState(false);
  const list = pages.items.map((member) => ({ ...member,
    muted: false, volume: 100, locallyMuted: false, audioLevel: 0,
    ...(currentChannelId === channelId ? members[member.user_id] : {}),
  }));
  const elysiaUserId = elysiaProfile?.user.id ?? null;
  const isOwner = ownerId != null && ownerId === currentUser?.id;
  const [actionError, setActionError] = useState<string | null>(null);
  const [busyUserId, setBusyUserId] = useState<string | null>(null);
  useEffect(() => { setInvalidated(false); setActionError(null); setBusyUserId(null); }, [scope]);
  useEffect(() => voiceWS.onFrame((frame) => {
    if (frame.type !== "voice.state" || String(frame.data.channel_id) !== channelId) return;
    if (frame.data.state === "joined" || frame.data.state === "left") {
      memberRevision.current += 1;
      setInvalidated(true);
      if (frame.data.state === "left") pages.updateItems((items) => items.filter((item) => item.user_id !== frame.data.user_id));
    }
  }), [channelId, pages.updateItems]);
  const refresh = useCallback(async () => {
    const revision = memberRevision.current;
    if (await pages.refreshPage() && memberRevision.current === revision) setInvalidated(false);
  }, [pages.refreshPage]);
  const memberAction = async (userId: string, action: "kick" | "transfer") => {
    if (!channelId || busyUserId) return;
    setBusyUserId(userId);
    setActionError(null);
    try {
      await voiceApi.actionVoiceMember(channelId, userId, action);
      if (currentScope.current !== scope) return;
      if (action === "transfer") setActionError("房主已转让");
      await refresh();
    } catch (error) {
      if (currentScope.current === scope) setActionError(error instanceof Error ? error.message : "房主操作失败");
    } finally {
      if (currentScope.current === scope) setBusyUserId(null);
    }
  };

  return (
    <section className="voice-panel">
      <header className="voice-panel-head">
        <h3 className="voice-panel-title">{channelName}</h3>
        <span className="voice-panel-count">{currentChannelId === channelId ? Object.keys(members).length : pages.total} 人</span>
      </header>
      <div className="voice-member-list">
        {list.length === 0 ? (
          !pages.loading && !pages.error && <div className="voice-list-empty">当前还没有成员</div>
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
        <DirectoryLoadMore {...pages} invalidated={invalidated} refresh={refresh} retainCompletedSpace={false} />
      </div>
      {actionError && <div className="chat-notice" role="alert">{actionError}</div>}
      {connectionError && <div className="chat-notice" role="alert">{connectionError}</div>}
      <VoiceControls
        livekit={livekit}
        wsConnection={wsConnection}
        onLeave={onLeave}
        onRejoin={onRejoin}
      />
    </section>
  );
}
