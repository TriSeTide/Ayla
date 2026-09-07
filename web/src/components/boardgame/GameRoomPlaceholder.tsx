/**
 * GameRoomPlaceholder —— 进入桌游室后的占位界面（R-B1，玩法后续）。
 *
 * 展示房间基本信息（名称/房主/人数）+ join/leave 状态切换（本组件负责调用与展示）；
 * 玩法引擎、WS 对局通道非本期目标，正文区占位提示。
 */
import { useCallback, useEffect, useRef, useState } from "react";
import * as boardgameApi from "../../api/boardgame";
import type { GameRoom } from "../../api/types";
import { ConfirmDialog } from "../ConfirmDialog";
import { FavoriteButton } from "../FavoriteButton";
import { IconBack } from "../icons";
import { useAuthStore } from "../../stores/auth";
import { usePagedMediaList } from "../../hooks/usePagedMediaList";
import { DirectoryLoadMore } from "../DirectoryLoadMore";

export function GameRoomPlaceholder({
  room: suppliedRoom,
  onLeave,
  onBack,
}: {
  room: GameRoom;
  onLeave: () => void;
  onBack: () => void;
}) {
  const [latestRoom, setLatestRoom] = useState(suppliedRoom);
  const room = latestRoom.id === suppliedRoom.id ? latestRoom : suppliedRoom;
  const [isMember, setIsMember] = useState(room.is_member);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const currentUser = useAuthStore((state) => state.currentUser);
  const [actionBusy, setActionBusy] = useState<string | null>(null);
  const isOwner = room.is_owner || room.owner_id === currentUser?.id;
  const [confirmDeleteOpen, setConfirmDeleteOpen] = useState(false);
  const scope = `${room.id}:${currentUser?.id ?? ""}`;
  const currentScope = useRef(scope);
  currentScope.current = scope;
  const [membersInvalidated, setMembersInvalidated] = useState(false);
  const memberRevision = useRef(0);
  const memberSignature = useRef(`${suppliedRoom.id}:${suppliedRoom.member_count}:${suppliedRoom.owner_id}`);
  const nextSignature = `${suppliedRoom.id}:${suppliedRoom.member_count}:${suppliedRoom.owner_id}`;
  const memberScope = useRef(scope);
  if (memberScope.current !== scope) {
    memberScope.current = scope;
    memberSignature.current = nextSignature;
    memberRevision.current += 1;
  }
  const fetchMembers = useCallback(async (cursor: string | null) => {
    const revision = memberRevision.current;
    const page = await boardgameApi.listGameRoomMembersPage(room.id, { cursor, limit: 20 });
    if (memberRevision.current !== revision) throw new Error("成员列表已更新，请刷新后继续");
    return page;
  }, [room.id]);
  const memberPages = usePagedMediaList(`game-members:${scope}`, fetchMembers, isOwner);
  const refreshMembers = useCallback(async () => {
    const revision = memberRevision.current;
    if (await memberPages.refreshPage() && memberRevision.current === revision) setMembersInvalidated(false);
  }, [memberPages.refreshPage]);
  useEffect(() => {
    if (memberSignature.current !== nextSignature) {
      memberSignature.current = nextSignature;
      memberRevision.current += 1;
      setMembersInvalidated(true);
    }
  }, [nextSignature]);

  useEffect(() => {
    setLatestRoom(suppliedRoom);
    setIsMember(suppliedRoom.is_member);
  }, [suppliedRoom]);

  useEffect(() => {
    setBusy(false);
    setActionBusy(null);
    setError(null);
    setConfirmDeleteOpen(false);
    setMembersInvalidated(false);
  }, [scope]);

  const memberAction = async (userId: string, action: "kick" | "transfer") => {
    if (actionBusy) return;
    setActionBusy(userId);
    setError(null);
    try {
      const updated = await boardgameApi.actionGameMember(room.id, userId, action);
      if (currentScope.current !== scope) return;
      setLatestRoom(updated);
      setIsMember(updated.is_member);
      await refreshMembers();
    } catch (e) {
      if (currentScope.current === scope) setError(e instanceof Error ? e.message : "成员操作失败");
    } finally {
      if (currentScope.current === scope) setActionBusy(null);
    }
  };

  const join = async () => {
    setBusy(true);
    setError(null);
    let joined = false;
    try {
      await boardgameApi.joinGameRoom(room.id);
      if (currentScope.current !== scope) return;
      joined = true;
      setIsMember(true);
      const updated = await boardgameApi.getGameRoom(room.id);
      if (currentScope.current === scope) setLatestRoom(updated);
    } catch (e) {
      if (currentScope.current === scope) setError(joined ? "已加入，房间信息刷新失败，请稍后重试" : e instanceof Error ? e.message : "加入失败");
    } finally {
      if (currentScope.current === scope) setBusy(false);
    }
  };

  const leave = async () => {
    setBusy(true);
    setError(null);
    try {
      await boardgameApi.leaveGameRoom(room.id);
      if (currentScope.current !== scope) return;
      setIsMember(false);
      onLeave();
    } catch (e) {
      if (currentScope.current === scope) setError(e instanceof Error ? e.message : "离开失败");
    } finally {
      if (currentScope.current === scope) setBusy(false);
    }
  };

  return (
    <div className="game-room-placeholder">
      <header className="game-room-placeholder-head">
        <button type="button" className="icon-btn-40" onClick={onBack} aria-label="返回">
          <IconBack width={20} height={20} />
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
          {memberPages.items.filter((member) => member.user_id !== currentUser?.id).map((member) => <div key={member.user_id} className="game-room-member-action">
            <span>{member.user.nickname || member.user.username}</span>
            <button type="button" className="btn btn-ghost" disabled={actionBusy !== null} onClick={() => void memberAction(member.user_id, "kick")}>移出</button>
            <button type="button" className="btn btn-ghost" disabled={actionBusy !== null} onClick={() => void memberAction(member.user_id, "transfer")}>转让房主</button>
          </div>)}
          <DirectoryLoadMore {...memberPages} invalidated={membersInvalidated} refresh={refreshMembers} />
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
                .then(() => { if (currentScope.current === scope) onBack(); })
                .catch((e) => { if (currentScope.current === scope) setError(e instanceof Error ? e.message : "删除失败"); });
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
