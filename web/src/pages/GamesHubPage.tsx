/**
 * GamesHubPage —— 一级桌游 tab（路由 /games，F7）。
 *
 * 房间列表（2 列窄屏 / 4 列宽屏）+ 空态 + 进入占位界面（join 后 GameRoomPlaceholder）。
 * 建房间走右下 FAB（CreateFab handler=game）。窄屏带 NarrowTopBar。
 */
import { useCallback, useEffect, useId, useMemo, useRef, useState } from "react";
import { useNavigate, useParams, useSearchParams } from "react-router-dom";
import * as boardgameApi from "../api/boardgame";
import type { GameRoom } from "../api/types";
import { GameRoomCard } from "../components/boardgame/GameRoomCard";
import { GameRoomPlaceholder } from "../components/boardgame/GameRoomPlaceholder";
import { PullToRefresh } from "../components/motion/PullToRefresh";
import { FullScreenSwipeBack } from "../components/motion/FullScreenSwipeBack";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { useBoardgameStore } from "../stores/boardgame";
import { useDirectoryPage } from "../hooks/useDirectoryPage";
import { useListEntryMotion } from "../hooks/useListEntryMotion";
import { saveScrollPosition, useScrollRestore } from "../hooks/useScrollRestore";
import { DirectoryLoadMore } from "../components/DirectoryLoadMore";
import { DirectoryFilters } from "../components/DirectoryFilters";
import { IconGame } from "../components/icons";
import { useShellStore } from "../stores/shell";

type GameFilter = "all" | "public" | "friends" | "mine" | "waiting" | "playing";
const FILTERS: ReadonlyArray<{ key: GameFilter; label: string }> = [
  { key: "all", label: "全部" },
  { key: "public", label: "公开" },
  { key: "friends", label: "好友" },
  { key: "mine", label: "我的" },
  { key: "waiting", label: "等待中" },
  { key: "playing", label: "对局中" },
];

export function GamesHubPage() {
  const navigate = useNavigate();
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const { roomId } = useParams<{ roomId?: string }>();
  const directory = useDirectoryPage("game", {}, !roomId);
  const { items: rooms, loading, error, refresh } = directory;
  const [loadError, setLoadError] = useState<string | null>(null);
  /** 进入的房间（占位界面） */
  const [current, setCurrent] = useState<GameRoom | null>(null);
  // 记录上次已触发 join 的路由房间 id：仅当 routeRoomId 变化时才 join，
  // 避免离开清空 current 后、navigate 尚未更新路由的窗口里被 effect 误判为
  // "需要重新加入"而把用户拉回房间（对齐 VoiceHubPage 的 lastJoinRouteRef 模式）。
  const lastJoinRouteRef = useRef<string | null>(null);
  const hubRef = useRef<HTMLDivElement>(null);
  // §3.4 刷新动画：刷新完成后递增，已入场卡片整批重播浮入（第一页也有动画）
  const [replayNonce, setReplayNonce] = useState(0);
  // 分类选项卡：URL ?type= 驱动（与收藏/搜索一致），各 tab 独立滚动位置
  const selectionId = useId();
  const [params, setParams] = useSearchParams();
  const filter = FILTERS.find((item) => item.key === params.get("type"))?.key ?? "all";
  const scope = `games-hub:${filter}`;
  // 过滤全部前端实现（分页加载后过滤够用）；排序保持 directory 原排序（created_at 倒序）
  const visibleRooms = useMemo(() => {
    if (filter === "all") return rooms;
    return rooms.filter((room) => {
      switch (filter) {
        case "public": return room.visibility === "public";
        case "friends": return room.visibility === "friends";
        case "mine": return room.is_owner;
        case "waiting": return room.status === "waiting";
        case "playing": return room.status === "playing";
        default: return true;
      }
    });
  }, [rooms, filter]);
  const { restoring } = useScrollRestore(scope, hubRef, { ready: !loading || rooms.length > 0 });
  useListEntryMotion(hubRef, ".game-room-card-wrap", restoring, replayNonce);
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

  // 上拉刷新仅当滚动容器（.directory-content）已在顶部时响应
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
    <div className="games-hub directory-page">
      <div className="directory-body">
        <DirectoryFilters id={selectionId} label="桌游分类" options={FILTERS} value={filter} narrow={isNarrow}
          className="games-filters" buttonClassName="games-filter"
          onChange={(next) => {
            saveScrollPosition(scope, hubRef.current);
            setParams(next === "all" ? {} : { type: next }, { replace: true });
          }}
          decor={<IconGame width={64} height={64} className="directory-filter-decor games-filter-decor" role="presentation" aria-hidden="true" />}
          header={<div className="directory-filter-header">
            <span className="directory-filter-kicker">Games</span>
            <span className="directory-filter-title">桌游室</span>
            {directory.total > 0 && <span className="directory-filter-stats">{directory.total} 个房间</span>}
          </div>} />
        <div key={scope} className="directory-content games-content" ref={hubRef}
          id={`${selectionId}-panel`} role="tabpanel" aria-labelledby={`${selectionId}-${filter}`} tabIndex={0}
          onScroll={(event) => directory.onScroll(event.currentTarget)}>
          {loadError && (
            <div className="chat-notice" role="alert">
              <span>{loadError}</span>
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
          ) : error && rooms.length === 0 ? <DirectoryLoadMore {...directory} /> : rooms.length === 0 ? (
            <div className="home-state">
              <h2 className="placeholder-title">还没有桌游室</h2>
              <p className="placeholder-desc">点右下角 + 建一个房间</p>
            </div>
          ) : (
            <PullToRefresh isAtTop={isAtTop} onRefresh={refreshWithReplay}>
              {visibleRooms.length === 0 && filter !== "all" ? (
                <div className="home-state">
                  <h2 className="placeholder-title">这个分类还没有桌游室</h2>
                  <p className="placeholder-desc">换个分类看看</p>
                </div>
              ) : (
                <div className="games-grid">
                  {visibleRooms.map((r) => (
                    <GameRoomCard
                      key={r.id}
                      room={r}
                      onEnter={() => enterRoom(r)}
                    />
                  ))}
                </div>
              )}
              <DirectoryLoadMore {...directory} />
            </PullToRefresh>
          )}
        </div>
      </div>
    </div>
  );
}
