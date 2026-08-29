/**
 * GameRoomPlaceholder —— 进入桌游室后的占位界面（R-B1，玩法后续）。
 *
 * 展示房间基本信息（名称/房主/人数）+ join/leave 状态切换（本组件负责调用与展示）；
 * 玩法引擎、WS 对局通道非本期目标，正文区占位提示。
 */
import { useState } from "react";
import * as boardgameApi from "../../api/boardgame";
import type { GameRoom } from "../../api/types";
import { ConfirmDialog } from "../ConfirmDialog";
import { FavoriteButton } from "../FavoriteButton";
import { useAuthStore } from "../../stores/auth";

export function GameRoomPlaceholder({
  room,
  onLeave,
  onBack,
}: {
  room: GameRoom;
  onLeave: () => void;
  onBack: () => void;
}) {
  const [isMember, setIsMember] = useState(room.is_member);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const currentUser = useAuthStore((state) => state.currentUser);
  const [actionBusy, setActionBusy] = useState<string | null>(null);
  const isOwner = room.is_owner || room.owner_id === currentUser?.id;
  const [confirmDeleteOpen, setConfirmDeleteOpen] = useState(false);

  const join = async () => {
    setBusy(true);
    setError(null);
    try {
      await boardgameApi.joinGameRoom(room.id);
      setIsMember(true);
    } catch (e) {
      setError(e instanceof Error ? e.message : "加入失败");
    } finally {
      setBusy(false);
    }
  };

  const leave = async () => {
    setBusy(true);
    setError(null);
    try {
      await boardgameApi.leaveGameRoom(room.id);
      setIsMember(false);
      onLeave();
    } catch (e) {
      setError(e instanceof Error ? e.message : "离开失败");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="game-room-placeholder">
      <header className="game-room-placeholder-head">
        <button type="button" className="msg-action-btn" onClick={onBack} aria-label="返回">
          ← 返回
        </button>
        <span className="game-room-placeholder-name">{room.name}</span>
        <FavoriteButton targetType="game" targetId={room.id} compact />
      </header>
      <div className="game-room-placeholder-body">
        <p className="game-room-placeholder-desc">
          桌游玩法后续上线，当前为房间框架占位
        </p>
        <p className="game-room-placeholder-meta">
          {room.member_count} 人 · 房主 {room.owner.nickname || room.owner.username}
        </p>
        {error && <p className="post-editor-error">{error}</p>}
        {isOwner && <div className="game-room-owner-controls">
          <strong>房主控制</strong>
          {room.members.filter((member) => member.user_id !== currentUser?.id).map((member) => <div key={member.user_id} className="game-room-member-action">
            <span>{member.user.nickname || member.user.username}</span>
            <button type="button" className="btn btn-ghost" disabled={actionBusy !== null} onClick={() => { setActionBusy(member.user_id); boardgameApi.actionGameMember(room.id, member.user_id, "kick").then(() => setError("成员已移出房间")).catch((e) => setError(e instanceof Error ? e.message : "移除失败")).finally(() => setActionBusy(null)); }}>移出</button>
            <button type="button" className="btn btn-ghost" disabled={actionBusy !== null} onClick={() => { setActionBusy(member.user_id); boardgameApi.actionGameMember(room.id, member.user_id, "transfer").then(() => setError("房主已转让")).catch((e) => setError(e instanceof Error ? e.message : "转让失败")).finally(() => setActionBusy(null)); }}>转让房主</button>
          </div>)}
          <button type="button" className="btn btn-destructive" disabled={busy} onClick={() => setConfirmDeleteOpen(true)}>删除房间</button>
        </div>}
        {confirmDeleteOpen && (
          <ConfirmDialog
            title="删除桌游房间"
            message={`确定删除桌游房间「${room.name}」？此操作不可撤销。`}
            onConfirm={() => {
              setConfirmDeleteOpen(false);
              boardgameApi
                .deleteGameRoom(room.id)
                .then(onBack)
                .catch((e) => setError(e instanceof Error ? e.message : "删除失败"));
            }}
            onClose={() => setConfirmDeleteOpen(false)}
          />
        )}
        {isMember ? (
          <button type="button" className="btn btn-ghost" onClick={() => void leave()} disabled={busy}>
            {busy ? "离开中…" : "离开房间"}
          </button>
        ) : (
          <button type="button" className="btn btn-primary" onClick={() => void join()} disabled={busy}>
            {busy ? "加入中…" : "加入房间"}
          </button>
        )}
      </div>
    </div>
  );
}
