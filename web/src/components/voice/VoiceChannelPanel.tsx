/**
 * VoiceChannelPanel —— 当前频道面板（成员列表 + 控制条，M5-3 §2）。
 *
 * - 可见成员由独立 cursor 页读取；媒体状态取 voice store 的完整成员对账；
 * - 控制条复用 VoiceControls。
 */
import { Fragment, useCallback, useEffect, useRef, useState } from "react";
import type { ElysiaProfile } from "../../api/types";
import * as voiceApi from "../../api/voice";
import { useAuthStore } from "../../stores/auth";
import type { LiveKitConnectionState } from "../../stores/voice";
import { useVoiceStore } from "../../stores/voice";
import { VoiceControls } from "./VoiceControls";
import { VoiceMemberRow } from "./VoiceMemberRow";
import { usePagedMediaList } from "../../hooks/usePagedMediaList";
import { DirectoryLoadMore } from "../DirectoryLoadMore";
import { voiceWS } from "../../ws/voice";

export function VoiceChannelPanel({
  channelName,
  channelId,
  ownerId,
  livekit,
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
  // 自己兜底：分页第一页可能不含自己（进入时 join 未完成 / 成员 ≥20 人时自己按
  // joined_at 升序排最后），只要 store 对账里有自己就保证渲染（置顶），
  // 避免"进去了不显示自己"。
  const selfId = currentUser?.id;
  const selfMember = selfId != null ? members[selfId] : undefined;
  const mergedList = selfMember && !list.some((m) => m.user_id === selfId)
    ? [selfMember, ...list]
    : list;
  // 进入房间后强制刷新一次成员列表：面板可能在 join 完成前挂载，第一页不含自己；
  // 渲染层已兜底自己可见，这里纠正分页数据本身（joined 帧若在订阅前广播则不会触发 invalidate）。
  const selfInStore = useVoiceStore((s) => (selfId != null ? s.members[selfId] != null : false));
  const refreshedChannelRef = useRef<string | null>(null);
  const elysiaUserId = elysiaProfile?.user.id ?? null;
  const isOwner = ownerId != null && ownerId === currentUser?.id;
  const [busyUserId, setBusyUserId] = useState<string | null>(null);
  useEffect(() => { setInvalidated(false); setBusyUserId(null); }, [scope]);
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
  // 进入房间后强制刷新一次成员列表（refresh 定义之后挂 effect，避免 TDZ）：
  // 面板可能在 join 完成前挂载，第一页不含自己；渲染层已兜底自己可见，
  // 这里纠正分页数据本身（joined 帧若在订阅前广播则不会触发 invalidate）。
  useEffect(() => {
    if (!channelId || refreshedChannelRef.current === channelId || !pages.loaded || !selfInStore) return;
    refreshedChannelRef.current = channelId;
    void refresh();
  }, [channelId, pages.loaded, selfInStore, refresh]);
  const memberAction = async (userId: string, action: "kick" | "transfer") => {
    if (!channelId || busyUserId) return;
    setBusyUserId(userId);
    try {
      await voiceApi.actionVoiceMember(channelId, userId, action);
      if (currentScope.current !== scope) return;
      await refresh();
    } catch {
      // 成员操作失败静默
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
        {mergedList.length === 0 ? (
          !pages.loading && !pages.error && <div className="voice-list-empty">当前还没有成员</div>
        ) : (
          mergedList.map((m) => {
            const isElysia = elysiaUserId != null && m.user_id === elysiaUserId;
            return (
              <Fragment key={m.user_id}>
              <VoiceMemberRow
                key={m.user_id}
                member={m}
                isSelf={m.user_id === currentUser?.id}
                isElysia={isElysia}
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
      <VoiceControls
        livekit={livekit}
        onLeave={onLeave}
        onRejoin={onRejoin}
      />
    </section>
  );
}
