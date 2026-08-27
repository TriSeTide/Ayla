/**
 * GamesHubPage —— 一级桌游 tab（路由 /games，F7）。
 *
 * 房间列表（2 列窄屏 / 4 列宽屏）+ 空态 + 进入占位界面（join 后 GameRoomPlaceholder）。
 * 建房间走右下 FAB（CreateFab handler=game）。窄屏带 NarrowTopBar。
 */
import { useCallback, useEffect, useRef, useState } from "react";
import * as boardgameApi from "../api/boardgame";
import type { GameRoom } from "../api/types";
import { GameRoomCard } from "../components/boardgame/GameRoomCard";
import { GameRoomPlaceholder } from "../components/boardgame/GameRoomPlaceholder";
import { PullToRefresh } from "../components/motion/PullToRefresh";
import { staggerDelay } from "../hooks/useRevealOnEnter";
import { useBoardgameStore, isBoardgameStale } from "../stores/boardgame";
import { useShellStore } from "../stores/shell";

export function GamesHubPage() {
  const rooms = useBoardgameStore((s) => s.rooms);
  const loading = useBoardgameStore((s) => s.roomsLoading);
  const error = useBoardgameStore((s) => s.error);
  const [loadError, setLoadError] = useState<string | null>(null);
  /** 进入的房间（占位界面） */
  const [current, setCurrent] = useState<GameRoom | null>(null);
  // §3.4 刷新动画：刷新完成后递增，key 变化强制桌游列表重挂载 → reveal 重播
  const [revealNonce, setRevealNonce] = useState(0);
  const hubRef = useRef<HTMLDivElement>(null);

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

  // 上拉刷新/刷新键共用：强制重拉桌游室列表（绕过 isBoardgameStale 缓存）
  const refresh = useCallback(async () => {
    const store = useBoardgameStore.getState();
    store.setError(null);
    setLoadError(null);
    try {
      const list = await boardgameApi.listGameRooms();
      store.reconcileRooms(list);
      setRevealNonce((n) => n + 1);
    } catch (e) {
      const message = e instanceof Error ? e.message : "加载失败";
      store.setError(message);
      setLoadError(message);
    }
  }, []);

  // §3.4 RefreshFAB：注册当前页刷新回调（引用守卫见 HomePage）
  useEffect(() => {
    useShellStore.getState().registerRefresh(refresh);
    return () => {
      if (useShellStore.getState().refreshCallback === refresh) {
        useShellStore.getState().registerRefresh(null);
      }
    };
  }, [refresh]);

  // 上拉刷新仅当滚动容器（.games-hub）已在顶部时响应
  const isAtTop = useCallback(() => (hubRef.current?.scrollTop ?? 0) <= 0, []);

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
    <div className="games-hub" ref={hubRef}>
      {(error || loadError) && (
        <div className="chat-notice" role="alert">
          <span>{error || loadError}</span>
        </div>
      )}
      {loading && rooms.length === 0 ? (
        <div className="games-grid games-grid-loading" aria-busy="true">
          <div className="games-skeleton-card">
            <div className="skeleton" style={{ height: 120, borderRadius: 12 }} />
          </div>
          <div className="games-skeleton-card">
            <div className="skeleton" style={{ height: 120, borderRadius: 12 }} />
          </div>
          <span className="home-load-text games-skel-text">正在加载桌游室…</span>
        </div>
      ) : rooms.length === 0 ? (
        <div className="home-state">
          <h2 className="placeholder-title">还没有桌游室</h2>
          <p className="placeholder-desc">点右下角 + 建一个房间</p>
        </div>
      ) : (
        <PullToRefresh isAtTop={isAtTop} onRefresh={refresh}>
          <div className="games-grid" key={revealNonce}>
            {rooms.map((r, idx) => (
              <GameRoomCard
                key={r.id}
                room={r}
                onEnter={() => enterRoom(r)}
                /* 异步内容就绪后才启用 A2 stagger，避免加载前动画跑完（design.md §7.1） */
                revealDelay={!loading ? staggerDelay(idx) : undefined}
              />
            ))}
          </div>
        </PullToRefresh>
      )}
    </div>
  );
}
