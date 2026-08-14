/**
 * GameRoomPlaceholder —— 进入桌游室后的占位界面（R-B1，玩法后续）。
 *
 * 展示房间基本信息（名称/房主/人数）+ join/leave 状态切换（本组件负责调用与展示）；
 * 玩法引擎、WS 对局通道非本期目标，正文区占位提示。
 */
import { useState } from "react";
import * as boardgameApi from "../../api/boardgame";
import type { GameRoom } from "../../api/types";

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
      </header>
      <div className="game-room-placeholder-body">
        <p className="game-room-placeholder-desc">
          桌游玩法后续上线，当前为房间框架占位
        </p>
        <p className="game-room-placeholder-meta">
          {room.member_count} 人 · 房主 {room.owner.nickname || room.owner.username}
        </p>
        {error && <p className="post-editor-error">{error}</p>}
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
