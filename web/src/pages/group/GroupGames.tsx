/**
 * GroupGames —— 群内桌游子界面（F7，R-G8）。
 *
 * 该群桌游室卡片列表（filter group === groupId），点卡片进房间占位界面；
 * join 后"正在玩的桌游"成为个人页数据源（F10，后端点 ?mine=1 已支持）。
 * 无房间 → 空态。
 */
import { useCallback, useEffect, useState } from "react";
import * as boardgameApi from "../../api/boardgame";
import type { GameRoom } from "../../api/types";
import { GameRoomCard } from "../../components/boardgame/GameRoomCard";
import { GameRoomPlaceholder } from "../../components/boardgame/GameRoomPlaceholder";

export function GroupGames({ groupId, onExit }: { groupId: string; onExit: () => void }) {
  const [rooms, setRooms] = useState<GameRoom[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [current, setCurrent] = useState<GameRoom | null>(null);

  const load = useCallback(() => {
    setLoading(true);
    setError(null);
    boardgameApi
      .listGameRooms()
      .then((list) => setRooms(list.filter((r) => r.group === groupId)))
      .catch((e) => setError(e instanceof Error ? e.message : "加载桌游室失败"))
      .finally(() => setLoading(false));
  }, [groupId]);

  useEffect(() => {
    load();
  }, [load]);

  const enterRoom = (room: GameRoom) => {
    boardgameApi
      .joinGameRoom(room.id)
      .then(() => setCurrent({ ...room, is_member: true }))
      .catch(() => setCurrent(room));
  };

  if (current) {
    return (
      <GameRoomPlaceholder
        room={current}
        onLeave={() => {
          setCurrent(null);
          load();
        }}
        onBack={() => setCurrent(null)}
      />
    );
  }

  if (loading) {
    return (
      <div className="group-scene-placeholder">
        <div className="skeleton" style={{ height: 120, width: "80%" }} />
      </div>
    );
  }

  if (error) {
    return (
      <div className="group-scene-placeholder" role="alert">
        <h3 className="placeholder-title">桌游室加载失败</h3>
        <p className="placeholder-desc">{error}</p>
        <button type="button" className="btn btn-ghost" onClick={load} disabled={loading}>重试</button>
      </div>
    );
  }

  if (rooms.length === 0) {
    return (
      <div className="group-scene-placeholder">
        <h3 className="placeholder-title">群内还没有桌游室</h3>
        <p className="placeholder-desc">建一个群内桌游室吧</p>
        <button type="button" className="btn btn-ghost" onClick={onExit}>
          返回聊天
        </button>
      </div>
    );
  }

  return (
    <div className="group-games">
      {rooms.map((r) => (
        <GameRoomCard key={r.id} room={r} onEnter={() => enterRoom(r)} />
      ))}
    </div>
  );
}
