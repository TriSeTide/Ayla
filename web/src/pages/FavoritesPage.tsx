import { useCallback, useEffect, useId, useRef, useState, type ReactNode } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import * as favoritesApi from "../api/favorites";
import type { Favorite, FavoriteTargetType } from "../api/types";
import { IconBack } from "../components/icons";
import { FullScreenSwipeBack } from "../components/motion/FullScreenSwipeBack";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { useMasonryColumns } from "../hooks/useMasonryColumns";
import { useListEntryMotion } from "../hooks/useListEntryMotion";
import { saveScrollPosition, useScrollRestore } from "../hooks/useScrollRestore";
import { DirectoryLoadMore } from "../components/DirectoryLoadMore";
import { DirectoryFilters } from "../components/DirectoryFilters";
import { FavoriteResultCard } from "../components/cards/DirectoryResultCards";
import { useAuthStore } from "../stores/auth";
import { usePostsStore } from "../stores/posts";
import { chatWS } from "../ws/chat";
import { IconHeart } from "../components/icons";

const FILTERS: Array<{ key: FavoriteTargetType | "all"; label: string }> = [
  { key: "all", label: "全部" },
  { key: "message", label: "消息" },
  { key: "post", label: "帖子" },
  { key: "live", label: "直播" },
  { key: "voice", label: "语音房" },
  { key: "game", label: "桌游房" },
  { key: "group", label: "群" },
];

type FavoriteTarget = { conversation_id?: string };

function openTarget(navigate: ReturnType<typeof useNavigate>, favorite: Favorite) {
  const target = favorite.target as FavoriteTarget | null;
  switch (favorite.target_type) {
    case "post":
      navigate(`/posts/${favorite.target_id}`);
      break;
    case "live":
      navigate(`/live/${favorite.target_id}`);
      break;
    case "voice":
      // 直达具体语音房（/voice/:channelId 路由已存在，VoiceHubPage 支持直达进房）
      navigate(`/voice/${favorite.target_id}`);
      break;
    case "game":
      // 直达具体桌游房（/games/:roomId 路由，GamesHubPage 自动 join 进房）
      navigate(`/games/${favorite.target_id}`);
      break;
    case "message":
      if (target?.conversation_id) navigate(`/chat/${target.conversation_id}`);
      break;
    case "group":
      navigate(`/group/${favorite.target_id}`);
      break;
  }
}

/** 与帖子流共用分列机制；只在数据就绪后挂载，让量高观察器绑定真实列。 */
function FavoritesList({ favorites, isNarrow, filter, suppressEntry, onOpen, onRemove }: {
  favorites: Favorite[];
  isNarrow: boolean;
  filter: FavoriteTargetType | "all";
  suppressEntry: boolean;
  onOpen: (favorite: Favorite) => void;
  onRemove: (favorite: Favorite) => void;
}) {
  const singleColumn = isNarrow;
  const listRef = useRef<HTMLDivElement>(null);
  useListEntryMotion(listRef, ".favorite-item", suppressEntry);
  const { columns, columnRefs } = useMasonryColumns(
    favorites,
    singleColumn ? 1 : 2,
    (favorite) => favorite.id,
    `favorites:${favorites[0].user_id}:${filter}`,
  );

  return (
    <div className={`favorites-list${singleColumn ? "" : " is-masonry"}`} ref={listRef}>
      {columns.map((column, columnIndex) => (
        <div key={columnIndex} className="favorites-masonry-col" ref={columnRefs[columnIndex]}>
          {column.map((favorite) => (
            <div key={favorite.id} className="favorite-item typed-result-card" data-favorite-id={favorite.id} data-result-type={favorite.target_type}>
              <FavoriteResultCard favorite={favorite} onOpen={() => onOpen(favorite)} action={
                <button type="button" className="msg-action-btn typed-card-remove" onClick={(event) => {
                  event.stopPropagation(); onRemove(favorite);
                }}>取消收藏</button>
              } />
            </div>
          ))}
        </div>
      ))}
    </div>
  );
}

type Filter = FavoriteTargetType | "all";
type FavoritePageState = {
  rows: Favorite[];
  cursor: string | null;
  hasMore: boolean;
  total: number;
  loaded: boolean;
  loading: boolean;
  error: string | null;
  errorKind: "first" | "append" | null;
  stale: boolean;
  updatedAt: number;
};
const favoritePages = new Map<string, FavoritePageState>();
let favoriteSession = 0;
/** Transient list snapshots never survive account/logout boundaries. */
useAuthStore.subscribe((state, previous) => {
  if (state.currentUser?.id !== previous.currentUser?.id || Boolean(state.accessToken) !== Boolean(previous.accessToken)) {
    favoriteSession += 1;
    favoritePages.clear();
  }
});
export function clearFavoritePageMemory() { favoritePages.clear(); }
function favoriteAccount() { return `${useAuthStore.getState().currentUser?.id ?? "anonymous"}:${favoriteSession}`; }
const emptyFavoritePage = (): FavoritePageState => ({ rows: [], cursor: null, hasMore: false, total: 0, loaded: false, loading: false, error: null, errorKind: null, stale: false, updatedAt: 0 });

function FavoriteResults({ scope, filter, isNarrow, pageRef, filterId, onOpen }: {
  scope: string;
  filter: Filter;
  isNarrow: boolean;
  pageRef: React.RefObject<HTMLDivElement>;
  filterId: string;
  onOpen: (favorite: Favorite) => void;
}) {
  const account = favoriteAccount();
  const [state, setState] = useState<FavoritePageState>(() => {
    const cached = favoritePages.get(scope);
    return cached ? { ...cached, loading: false, stale: cached.stale || Date.now() - cached.updatedAt > 60_000 } : emptyFavoritePage();
  });
  const stateRef = useRef(state);
  const owner = useRef({ active: false, revision: 0, busy: false, changes: 0, removed: new Set<number>() });
  const [actionError, setActionError] = useState<string | null>(null);
  const [resumeEntry, setResumeEntry] = useState(false);
  const { restoring } = useScrollRestore(scope, pageRef, { ready: state.loaded });
  const wrapResults = (children: ReactNode) => <div className="directory-content favorites-content" ref={pageRef}
    id={`${filterId}-panel`} role="tabpanel" aria-labelledby={`${filterId}-${filter}`} tabIndex={0}
    data-favorite-filter={filter}>{children}</div>;
  const update = useCallback((change: (current: FavoritePageState) => FavoritePageState) => {
    const next = change(stateRef.current);
    stateRef.current = next;
    setState(next);
    if (next.loaded) {
      favoritePages.delete(scope);
      favoritePages.set(scope, { ...next, loading: false });
      while (favoritePages.size > 14) favoritePages.delete(favoritePages.keys().next().value!);
    }
  }, [scope]);

  const requestPage = useCallback(async (append = false) => {
    const currentOwner = owner.current;
    const current = stateRef.current;
    if (!currentOwner.active || currentOwner.busy || (append && !current.hasMore)) return;
    const cursor = append ? current.cursor : null;
    const revision = ++currentOwner.revision;
    const changes = currentOwner.changes;
    currentOwner.busy = true;
    const isCurrent = () => currentOwner.active && currentOwner.revision === revision && favoriteAccount() === account;
    update((value) => ({ ...value, loading: true, error: null, errorKind: null }));
    try {
      // 游标缺失/未推进（防御性检查，正常不触发）：静默降级，不打扰用户
      if (append && !cursor) return;
      const page = await favoritesApi.listFavoritesPage({ type: filter === "all" ? undefined : filter, limit: 20, cursor });
      if (!isCurrent()) return;
      if (page.has_more && (!page.next_cursor || page.next_cursor === cursor)) return;
      const rows = new Map((append ? stateRef.current.rows : []).map((favorite) => [favorite.id, favorite]));
      for (const favorite of page.results) {
        if (currentOwner.removed.has(favorite.id)) continue;
        rows.set(favorite.id, favorite);
        // A page is only a partial index; it must not clear favorites outside it.
        if (favorite.target_type === "post") usePostsStore.getState().setFavorite(favorite.target_id, favorite.id);
      }
      if (append || current.loaded) setResumeEntry(true);
      update((value) => ({ ...value, rows: [...rows.values()], cursor: page.next_cursor,
        hasMore: page.has_more, total: page.total, loaded: true, error: null, errorKind: null,
        stale: (append && value.stale) || currentOwner.changes !== changes, updatedAt: Date.now() }));
    } catch (error) {
      if (isCurrent()) update((value) => ({ ...value, error: error instanceof Error ? error.message : "加载收藏失败", errorKind: append ? "append" : "first" }));
    } finally {
      if (isCurrent()) {
        currentOwner.busy = false;
        update((value) => ({ ...value, loading: false }));
      }
    }
  }, [account, filter, update]);

  useEffect(() => {
    const currentOwner = owner.current;
    currentOwner.active = true;
    if (!stateRef.current.loaded) void requestPage();
    return () => { currentOwner.active = false; currentOwner.revision += 1; currentOwner.busy = false; };
  }, [requestPage]);

  const removeLocal = useCallback((favoriteId: number, targetType: FavoriteTargetType) => {
    if (owner.current.removed.has(favoriteId)) return;
    owner.current.removed.add(favoriteId);
    owner.current.changes += 1;
    // Other cached filters for this account must not resurrect a removed item.
    for (const [key, cached] of favoritePages) {
      if (!key.startsWith(`favorites:${account}:`)) continue;
      favoritePages.set(key, { ...cached, rows: cached.rows.filter((row) => row.id !== favoriteId), stale: true });
    }
    update((value) => ({ ...value, rows: value.rows.filter((row) => row.id !== favoriteId),
      total: Math.max(0, value.total - (filter === "all" || filter === targetType ? 1 : 0)) }));
  }, [account, filter, update]);

  useEffect(() => chatWS.onFrame((frame) => {
    if (frame.type !== "favorite.changed" || !owner.current.active || favoriteAccount() !== account) return;
    const data = frame.data;
    if (data.action === "removed") removeLocal(data.favorite_id, data.target_type);
    else {
      owner.current.changes += 1;
      for (const [key, cached] of favoritePages) {
        if (key.startsWith(`favorites:${account}:`)) favoritePages.set(key, { ...cached, stale: true });
      }
      // A new first-page item does not invalidate older keyset positions.
      // Preserve the current view until the automatic head refresh completes.
      update((value) => ({ ...value, stale: true }));
    }
  }), [account, removeLocal, update]);

  const remove = useCallback(async (favorite: Favorite) => {
    setActionError(null);
    try {
      await favoritesApi.removeFavorite(favorite.id);
      if (!owner.current.active || favoriteAccount() !== account) return;
      if (!owner.current.removed.has(favorite.id)) removeLocal(favorite.id, favorite.target_type);
      if (favorite.target_type === "post") usePostsStore.getState().setFavorite(favorite.target_id, null);
    } catch (error) {
      if (owner.current.active && favoriteAccount() === account) setActionError(error instanceof Error ? error.message : "取消收藏失败，请重试");
    }
  }, [account, removeLocal]);

  // 收藏可能过时（请求期间收藏变化/缓存过期）→ 自动重新拉取，不打扰用户；
  // 刷新失败（真实错误）停止自动刷新，显示错误+重试；刷新期间再有收藏变化
  // 会保持 stale 继续刷新，直到数据稳定。
  useEffect(() => {
    if (state.stale && !state.loading && !state.error) void requestPage();
  }, [state.stale, state.loading, state.error, requestPage]);

  if (!state.loaded && !state.error) return wrapResults(<div className="favorites-skeleton" role="status" aria-label="正在加载收藏">
    <div className="skeleton" style={{ height: 64, marginBottom: 8 }} />
    <div className="skeleton" style={{ height: 64 }} />
  </div>);
  if (!state.loaded && state.error) return wrapResults(<div className="home-state" role="alert">
    <p className="placeholder-desc">{state.error}</p>
    <button type="button" className="btn btn-ghost" onClick={() => void requestPage()}>重试</button>
  </div>);
  return wrapResults(<>
    {actionError && <div className="chat-notice" role="alert">{actionError}</div>}
    {state.rows.length === 0 ? <div className="home-state">
      <h3 className="placeholder-title">这个分类还没有收藏</h3>
      <p className="placeholder-desc">在对应场景点收藏，内容会出现在这里</p>
    </div> : <FavoritesList favorites={state.rows} isNarrow={isNarrow} filter={filter}
      suppressEntry={restoring && !resumeEntry} onOpen={onOpen} onRemove={(favorite) => void remove(favorite)} />}
    <DirectoryLoadMore loading={state.loading} error={state.error} hasMore={state.hasMore} invalidated={false}
      loadMore={() => requestPage(state.errorKind !== "first")} refresh={() => requestPage()} />
  </>);
}

export function FavoritesPage() {
  const selectionId = useId();
  const navigate = useNavigate();
  const isNarrow = useMediaQuery(NARROW_QUERY);
  // Subscribe to both actor and logout transitions; tokens are never stored in snapshots.
  useAuthStore((state) => `${state.currentUser?.id ?? "anonymous"}:${Boolean(state.accessToken)}`);
  const [params, setParams] = useSearchParams();
  const filter = FILTERS.find((item) => item.key === params.get("type"))?.key ?? "all";
  const scope = `favorites:${favoriteAccount()}:${filter}`;
  const pageRef = useRef<HTMLDivElement | null>(null);
  const onOpen = (favorite: Favorite) => {
    saveScrollPosition(scope, pageRef.current);
    openTarget(navigate, favorite);
  };
  return <FullScreenSwipeBack onBack={() => navigate(-1)} enabled={isNarrow}>
    <div className="favorites-page directory-page">
      <div className="directory-body">
        <DirectoryFilters id={selectionId} label="收藏分类" options={FILTERS} value={filter} narrow={isNarrow}
          className="favorites-filters" buttonClassName="favorites-filter" onChange={(next) => {
            saveScrollPosition(scope, pageRef.current);
            setParams(next === "all" ? {} : { type: next }, { replace: true });
          }}
          leading={<button type="button" className="icon-btn-40 directory-filter-back" onClick={() => navigate(-1)} aria-label="返回"><IconBack width={20} height={20} /></button>}
          decor={<IconHeart width={52} height={52} className="directory-filter-decor favorites-filter-decor" role="presentation" aria-hidden="true" />} />
        <FavoriteResults key={scope} scope={scope} filter={filter} isNarrow={isNarrow} pageRef={pageRef}
          filterId={selectionId} onOpen={onOpen} />
      </div>
    </div>
  </FullScreenSwipeBack>;
}
