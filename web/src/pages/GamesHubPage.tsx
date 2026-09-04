/**
 * GamesHubPage —— 一级桌游 tab（路由 /games，F7）。
 *
 * 房间列表（2 列窄屏 / 4 列宽屏）+ 空态 + 进入占位界面（join 后 GameRoomPlaceholder）。
 * 建房间走右下 FAB（CreateFab handler=game）。窄屏带 NarrowTopBar。
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import * as boardgameApi from "../api/boardgame";
import type { GameRoom } from "../api/types";
import { GameRoomCard } from "../components/boardgame/GameRoomCard";
import { GameRoomPlaceholder } from "../components/boardgame/GameRoomPlaceholder";
import { PullToRefresh } from "../components/motion/PullToRefresh";
import { FullScreenSwipeBack } from "../components/motion/FullScreenSwipeBack";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { staggerDelay } from "../hooks/useRevealOnEnter";
import { useBoardgameStore, isBoardgameStale } from "../stores/boardgame";
import { useShellStore } from "../stores/shell";

export function GamesHubPage() {
  const navigate = useNavigate();
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const { roomId } = useParams<{ roomId?: string }>();
  const rooms = useBoardgameStore((s) => s.rooms);
  const loading = useBoardgameStore((s) => s.roomsLoading);
  const error = useBoardgameStore((s) => s.error);
  const [loadError, setLoadError] = useState<string | null>(null);
  /** 进入的房间（占位界面） */
  const [current, setCurrent] = useState<GameRoom | null>(null);
  // 记录上次已触发 join 的路由房间 id：仅当 routeRoomId 变化时才 join，
  // 避免离开清空 current 后、navigate 尚未更新路由的窗口里被 effect 误判为
  // "需要重新加入"而把用户拉回房间（对齐 VoiceHubPage 的 lastJoinRouteRef 模式）。
  const lastJoinRouteRef = useRef<string | null>(null);
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
      // 进房 = 路由切换（/games/:roomId），由下方路由 effect 统一 join + 渲染房内，
      // 与语音房（/voice/:channelId）同模式：URL 是房内态的唯一事实。
      navigate(`/games/${room.id}`);
    },
    [navigate],
  );

  // 直达进房：/games/:roomId（收藏跳转 / 刷新后恢复）→ 自动 join 并进入房内占位。
  // 仅当路由 id 变化时才 join（离房时清空标记以支持再次进入），避免 leave 后误判重进。
  useEffect(() => {
    if (!roomId) {
      lastJoinRouteRef.current = null;
      return;
    }
    if (lastJoinRouteRef.current === roomId) return;
    lastJoinRouteRef.current = roomId;
    const roomIdNum = Number(roomId);
    if (!Number.isFinite(roomIdNum)) {
      setLoadError("桌游房不存在");
      navigate("/games", { replace: true });
      return;
    }
    const store = useBoardgameStore.getState();
    const known = store.rooms.find((r) => r.id === roomIdNum);
    const roomPromise = known ? Promise.resolve(known) : boardgameApi.getGameRoom(roomIdNum);
    roomPromise
      .then((room) => {
        // 已在局直接进占位；未在局先 join（幂等）再进（对齐 enterRoom 语义）
        boardgameApi
          .joinGameRoom(room.id)
          .then(() => setCurrent({ ...room, is_member: true }))
          .catch(() => setCurrent(room));
      })
      .catch(() => {
        // 房间不存在/无权访问：回大厅并明确提示，不伪造进房。
        setLoadError("桌游房不存在或无权访问");
        navigate("/games", { replace: true });
      });
  }, [navigate, roomId]);

  // 离开/返回：清空房内态；从路由进入时回大厅路由（与语音房一致）
  const exitRoom = useCallback(() => {
    setCurrent(null);
    if (roomId) navigate("/games");
  }, [navigate, roomId]);

  if (current) {
    return (
      <FullScreenSwipeBack onBack={exitRoom} enabled={isNarrow}>
        <GameRoomPlaceholder
          room={current}
          onLeave={() => {
            exitRoom();
            load();
          }}
          onBack={exitRoom}
        />
      </FullScreenSwipeBack>
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
