/**
 * GroupGames —— 群内桌游子界面（F7，R-G8）。
 *
 * 该群桌游室卡片列表（服务端 group_id + allowed_groups 过滤后游标分页），点卡片进房间占位界面；
 * join 后"正在玩的桌游"成为个人页数据源（F10，后端点 ?mine=1 已支持）。
 * 无房间 → 空态。
 */
import { useCallback, useEffect, useRef, useState } from "react";
import * as boardgameApi from "../../api/boardgame";
import type { GameRoom } from "../../api/types";
import { GameRoomCard } from "../../components/boardgame/GameRoomCard";
import { GameRoomPlaceholder } from "../../components/boardgame/GameRoomPlaceholder";
import { PullToRefresh } from "../../components/motion/PullToRefresh";
import { useDirectoryPage } from "../../hooks/useDirectoryPage";
import { useListEntryMotion } from "../../hooks/useListEntryMotion";
import { DirectoryLoadMore } from "../../components/DirectoryLoadMore";
import { useShellStore } from "../../stores/shell";

export function GroupGames({ groupId, onExit }: { groupId: string; onExit: () => void }) {
  const directory = useDirectoryPage("game", { groupId });
  const { items: rooms, loading, error, refresh } = directory;
  const [current, setCurrent] = useState<GameRoom | null>(null);
  const hubRef = useRef<HTMLDivElement>(null);
  // §3.4 刷新动画：刷新完成后递增，已入场卡片整批重播浮入（第一页也有动画）
  const [replayNonce, setReplayNonce] = useState(0);
  useListEntryMotion(hubRef, ".game-room-card-wrap", false, replayNonce);
  const load = refresh;
  // 刷新键/下拉刷新共用：刷新完成后重播已入场卡片浮入
  const refreshWithReplay = useCallback(async () => {
    await refresh();
    setReplayNonce((n) => n + 1);
  }, [refresh]);

  // §3.4 RefreshFAB：注册当前页刷新回调（引用守卫见 HomePage）
  useEffect(() => {
    useShellStore.getState().registerRefresh(refreshWithReplay);
    return () => {
      if (useShellStore.getState().refreshCallback === refreshWithReplay) {
        useShellStore.getState().registerRefresh(null);
      }
    };
  }, [refreshWithReplay]);

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
    <div className="group-games" ref={hubRef} onScroll={(event) => directory.onScroll(event.currentTarget)}>
      <div className="group-scene-head">
        <div className="group-scene-head-copy">
          <h3 className="group-scene-title">群内桌游</h3>
          <p className="group-scene-desc">选择一个房间加入，或创建新的群内桌游室</p>
        </div>
      </div>
      {error && rooms.length === 0 ? (
        <div className="group-scene-placeholder group-games-full" role="alert">
          <p className="placeholder-desc">{error}</p>
          <button type="button" className="btn btn-ghost" onClick={load} disabled={loading}>重试</button>
        </div>
      ) : loading && rooms.length === 0 ? (
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
        <PullToRefresh isAtTop={isAtTop} onRefresh={refreshWithReplay}>
          <div className="group-games-grid">
            {rooms.map((r) => (
              <GameRoomCard
                key={r.id}
                room={r}
                onEnter={() => enterRoom(r)}
              />
            ))}
          </div>
          <DirectoryLoadMore {...directory} />
        </PullToRefresh>
      )}
    </div>
  );
}
