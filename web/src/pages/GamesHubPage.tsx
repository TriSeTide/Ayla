/**
 * GamesHubPage —— 一级桌游 tab（路由 /games，F7）。
 *
 * 房间列表（2 列窄屏 / 4 列宽屏）+ 空态 + 进入占位界面（join 后 GameRoomPlaceholder）。
 * 建房间走右下 FAB（CreateFab handler=game）。窄屏带 NarrowTopBar。
 */
import { useCallback, useEffect, useState } from "react";
import * as boardgameApi from "../api/boardgame";
import type { GameRoom } from "../api/types";
import { GameRoomCard } from "../components/boardgame/GameRoomCard";
import { GameRoomPlaceholder } from "../components/boardgame/GameRoomPlaceholder";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { NarrowTopBar } from "../layout/NarrowTopBar";
import { useBoardgameStore, isBoardgameStale } from "../stores/boardgame";

export function GamesHubPage() {
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const rooms = useBoardgameStore((s) => s.rooms);
  const loading = useBoardgameStore((s) => s.roomsLoading);
  const error = useBoardgameStore((s) => s.error);
  const [loadError, setLoadError] = useState<string | null>(null);
  /** 进入的房间（占位界面） */
  const [current, setCurrent] = useState<GameRoom | null>(null);

  const load = useCallback(() => {
    const store = useBoardgameStore.getState();
    store.setRoomsLoading(true);
    store.setError(null);
    setLoadError(null);
    boardgameApi
      .listGameRooms()
      .then((list) => store.reconcileRooms(list))
      .catch((e) => {
        const message = e instanceof Error ? e.message : "加载失败";
        store.setRoomsLoading(false);
        store.setError(message);
        setLoadError(message);
      });
  }, []);

  useEffect(() => {
    const store = useBoardgameStore.getState();
    if (store.rooms.length > 0 && !isBoardgameStale()) return;
    load();
  }, [load]);

  const enterRoom = useCallback(
    (room: GameRoom) => {
      // 已在局直接进占位；未在局先 join（幂等）再进
      boardgameApi
        .joinGameRoom(room.id)
        .then(() => setCurrent({ ...room, is_member: true }))
        .catch(() => setCurrent(room));
    },
    [],
  );

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

  return (
    <div className="games-hub">
      {isNarrow && <NarrowTopBar />}
      {(error || loadError) && (
        <div className="chat-notice" role="alert">
          <span>{error || loadError}</span>
        </div>
      )}
      {loading && rooms.length === 0 ? (
        <div className="conv-loading">
          <div className="skeleton" style={{ height: 120, marginBottom: 8 }} />
          <div className="skeleton" style={{ height: 120 }} />
        </div>
      ) : rooms.length === 0 ? (
        <div className="home-state">
          <h2 className="placeholder-title">还没有桌游室</h2>
          <p className="placeholder-desc">点右下角 + 建一个房间</p>
        </div>
      ) : (
        <div className="games-grid">
          {rooms.map((r) => (
            <GameRoomCard key={r.id} room={r} onEnter={() => enterRoom(r)} />
          ))}
        </div>
      )}
    </div>
  );
}
