/**
 * GroupGames —— 群内桌游子界面（F7，R-G8）。
 *
 * 该群桌游室卡片列表（filter group === groupId），点卡片进房间占位界面；
 * join 后"正在玩的桌游"成为个人页数据源（F10，后端点 ?mine=1 已支持）。
 * 无房间 → 空态。
 */
import { useCallback, useEffect, useRef, useState } from "react";
import * as boardgameApi from "../../api/boardgame";
import type { GameRoom } from "../../api/types";
import { GameRoomCard } from "../../components/boardgame/GameRoomCard";
import { GameRoomPlaceholder } from "../../components/boardgame/GameRoomPlaceholder";
import { PullToRefresh } from "../../components/motion/PullToRefresh";
import { staggerDelay } from "../../hooks/useRevealOnEnter";
import { useBoardgameStore, isBoardgameStale } from "../../stores/boardgame";
import { useShellStore } from "../../stores/shell";

export function GroupGames({ groupId, onExit }: { groupId: string; onExit: () => void }) {
  const allRooms = useBoardgameStore((s) => s.rooms);
  const rooms = allRooms.filter((room) =>
    String(room.group) === String(groupId)
    || (room.allowed_group_ids ?? []).some((allowedId) => String(allowedId) === String(groupId)),
  );
  const loading = useBoardgameStore((s) => s.roomsLoading);
  const error = useBoardgameStore((s) => s.error);
  const [current, setCurrent] = useState<GameRoom | null>(null);
  // §3.4 刷新动画：刷新完成后递增，key 变化强制桌游列表重挂载 → reveal 重播
  const [revealNonce, setRevealNonce] = useState(0);
  const hubRef = useRef<HTMLDivElement>(null);

  const load = useCallback(() => {
    // 全量可见房间写入全局 store（后端 visible_queryset 已含本用户所有群的
    // group/allowed_groups 房间），再按 groupId 前端投影当前群；
    // 不能用 scope=group:<id> 直接覆盖 store，否则跨群切换时全局列表被单群数据污染。
    const store = useBoardgameStore.getState();
    store.setRoomsLoading(true);
    store.setError(null);
    boardgameApi
      .listGameRooms()
      .then((list) => store.reconcileRooms(list))
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

  // 上拉刷新/刷新键共用：强制重拉桌游室列表
  const refresh = useCallback(async () => {
    const store = useBoardgameStore.getState();
    store.setError(null);
    try {
      const list = await boardgameApi.listGameRooms();
      store.reconcileRooms(list);
      setRevealNonce((n) => n + 1);
    } catch (e) {
      store.setError(e instanceof Error ? e.message : "加载桌游室失败");
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

  // 上拉刷新仅当滚动容器（.group-games）已在顶部时响应
  const isAtTop = useCallback(() => (hubRef.current?.scrollTop ?? 0) <= 0, []);

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

  // 渲染群内桌游框架：.group-games 为滚动容器，列表分支内 .group-games-grid 保持
  // 2 列 grid（PullToRefresh 包裹后 grid 移到内层，避免包裹层破坏 grid 子项关系），
  // 数据区按错误/加载/空/列表呈现——加载/空/错误子项跨全宽，不整页骨架替换。
  return (
    <div className="group-games" ref={hubRef}>
      <div className="group-scene-head">
        <div className="group-scene-head-copy">
          <h3 className="group-scene-title">群内桌游</h3>
          <p className="group-scene-desc">选择一个房间加入，或创建新的群内桌游室</p>
        </div>
      </div>
      {error ? (
        <div className="group-scene-placeholder group-games-full" role="alert">
          <p className="placeholder-desc">{error}</p>
          <button type="button" className="btn btn-ghost" onClick={load} disabled={loading}>重试</button>
        </div>
      ) : loading ? (
        <div className="group-games-loading" aria-busy="true">
          <span className="skeleton games-skel-card" />
          <span className="skeleton games-skel-card" />
          <span className="home-load-text games-skel-text">正在加载桌游室…</span>
        </div>
      ) : rooms.length === 0 ? (
        <div className="group-scene-placeholder group-games-full">
          <h3 className="placeholder-title">群内还没有桌游室</h3>
          <p className="placeholder-desc">建一个群内桌游室吧</p>
          <button type="button" className="btn btn-ghost" onClick={onExit}>
            返回聊天
          </button>
        </div>
      ) : (
        <PullToRefresh isAtTop={isAtTop} onRefresh={refresh}>
          <div className="group-games-grid" key={revealNonce}>
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
