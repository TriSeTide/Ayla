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
import { useBoardgameStore, isBoardgameStale } from "../../stores/boardgame";

export function GroupGames({ groupId, onExit }: { groupId: string; onExit: () => void }) {
  const allRooms = useBoardgameStore((s) => s.rooms);
  const rooms = allRooms.filter((room) =>
    String(room.group) === String(groupId)
    || (room.allowed_group_ids ?? []).some((allowedId) => String(allowedId) === String(groupId)),
  );
  const loading = useBoardgameStore((s) => s.roomsLoading);
  const error = useBoardgameStore((s) => s.error);
  const [current, setCurrent] = useState<GameRoom | null>(null);

  const load = useCallback(() => {
    // 全量可见房间写入全局 store（后端 visible_queryset 已含本用户所有群的
    // group/allowed_groups 房间），再按 groupId 前端投影当前群；
    // 不能用 scope=group:<id> 直接覆盖 store，否则跨群切换时全局列表被单群数据污染。
    const store = useBoardgameStore.getState();
    store.setRoomsLoading(true);
    store.setError(null);
    boardgameApi
      .listGameRooms()
      .then((list) => store.setRooms(list))
      .catch((e) => {
        store.setRoomsLoading(false);
        store.setError(e instanceof Error ? e.message : "加载桌游室失败");
      });
  }, [groupId]);

  useEffect(() => {
    const store = useBoardgameStore.getState();
    if (store.rooms.length > 0 && !isBoardgameStale()) return;
    load();
  }, [load]);

  // 兼容同页创建后的本地事件；跨客户端变化由 ChatWS -> BoardgameStore 驱动。
  useEffect(() => {
    const reconcile = () => load();
    window.addEventListener("boardgame:room-created", reconcile);
    window.addEventListener("boardgame:room-deleted", reconcile);
    return () => {
      window.removeEventListener("boardgame:room-created", reconcile);
      window.removeEventListener("boardgame:room-deleted", reconcile);
    };
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
