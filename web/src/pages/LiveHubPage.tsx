/**
 * LiveHubPage —— 一级直播 tab 聚合视图（路由 /live，F4 改造 LiveHallPage）。
 *
 * 聚合网格（窄屏 2 列 / 宽屏 3-4 列，布局文档 §3.1）+ 来源标识（公开/好友/群名，
 * R-L1）+ 空态引导（F4）。建直播间走右下 FAB（CreateFab handler=live），本页不再
 * 内嵌 LiveCreate 侧栏。窄屏带 NarrowTopBar（五 tab 共用骨架）。
 */
import { useCallback, useEffect, useId, useMemo, useRef, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { getElysiaProfile } from "../api/elysia";
import { ensureUser } from "../api/users";
import { LiveHall } from "../components/live/LiveHall";
import { PullToRefresh } from "../components/motion/PullToRefresh";
import { saveScrollPosition, useScrollRestore } from "../hooks/useScrollRestore";
import { useDirectoryPage } from "../hooks/useDirectoryPage";
import { DirectoryLoadMore } from "../components/DirectoryLoadMore";
import { DirectoryFilters } from "../components/DirectoryFilters";
import { IconVideo } from "../components/icons";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { useListEntryMotion } from "../hooks/useListEntryMotion";
import { useSocialPage } from "../hooks/useSocialPage";
import { useAuthStore } from "../stores/auth";
import { useShellStore } from "../stores/shell";

type LiveFilter = "all" | "live" | "public" | "friends" | "offline" | "mine";
const FILTERS: ReadonlyArray<{ key: LiveFilter; label: string }> = [
  { key: "all", label: "全部" },
  { key: "live", label: "在播" },
  { key: "public", label: "公开" },
  { key: "friends", label: "好友" },
  { key: "offline", label: "停播" },
  { key: "mine", label: "我的" },
];

export function LiveHubPage() {
  const navigate = useNavigate();
  const isNarrow = useMediaQuery(NARROW_QUERY);
  // 分类选项卡：URL ?type= 驱动（与收藏/搜索一致），各 tab 独立滚动位置
  const selectionId = useId();
  const [params, setParams] = useSearchParams();
  const filter = FILTERS.find((item) => item.key === params.get("type"))?.key ?? "all";
  const scope = `live-hub:${filter}`;
  const currentUserId = useAuthStore((s) => s.currentUser?.id);
  // filter 进 directory key：每个 tab 独立游标/加载（切 tab 自动拉取该 tab 过滤后的第一页）；
  // 过滤参数由后端执行（visibility/friends/status/owner），不依赖「全部」分页进度
  const directory = useDirectoryPage("live", {
    filter,
    visibility: filter === "public" ? "public" : undefined,
    friends: filter === "friends" ? true : undefined,
    status: filter === "live" ? "live" : filter === "offline" ? "offline" : undefined,
    owner: filter === "mine" ? currentUserId : undefined,
  });
  const { items: channels, loading, error, refresh } = directory;
  const [elysiaUserId, setElysiaUserId] = useState<string | null>(null);
  const [ownerNames, setOwnerNames] = useState<Record<string, string>>({});
  // §3.4 刷新动画：刷新完成后递增，已入场卡片整批重播浮入（第一页也有动画）
  const [replayNonce, setReplayNonce] = useState(0);
  const hubRef = useRef<HTMLDivElement>(null);
  // 好友 tab：作者是好友（friendIds 集合），不是 visibility=friends 才显示
  const friendsPage = useSocialPage("friends", {});
  const friendIds = useMemo(() => new Set(friendsPage.items.map((f) => f.user.id)), [friendsPage.items]);
  // 过滤全部前端实现（分页加载后过滤够用）；排序保持 directory 原排序（sortLiveChannels）
  const visibleChannels = useMemo(() => {
    if (filter === "all") return channels;
    return channels.filter((channel) => {
      switch (filter) {
        case "live": return channel.status === "live";
        case "public": return channel.visibility === "public";
        case "friends": return friendIds.has(channel.owner_id);
        case "offline": return channel.status !== "live";
        case "mine": return channel.is_owner;
        default: return true;
      }
    });
  }, [channels, filter, friendIds]);
  const { restoring } = useScrollRestore(scope, hubRef, { ready: !loading || channels.length > 0 });
  useListEntryMotion(hubRef, ".live-card-wrap", restoring, replayNonce);

  // 刷新键/下拉刷新共用：刷新完成后重播已入场卡片浮入
  const refreshWithReplay = useCallback(async () => {
    await refresh();
    setReplayNonce((n) => n + 1);
  }, [refresh]);

  useEffect(() => {
    let cancelled = false;
    const ids = [...new Set(channels.filter((item) => !item.owner_nickname).map((item) => item.owner_id))];
    void Promise.all(ids.map((id) => ensureUser(id))).then((users) => {
      if (cancelled) return;
      setOwnerNames((previous) => ({ ...previous, ...Object.fromEntries(users.filter((user) => user != null).map((user) => [user.id, user.nickname || user.username])) }));
    });
    return () => { cancelled = true; };
  }, [channels]);

  // §3.4 RefreshFAB：注册当前页刷新回调（复用下拉刷新通道；引用守卫见 HomePage）
  useEffect(() => {
    useShellStore.getState().registerRefresh(refreshWithReplay);
    return () => {
      if (useShellStore.getState().refreshCallback === refreshWithReplay) {
        useShellStore.getState().registerRefresh(null);
      }
    };
  }, [refreshWithReplay]);

  // 下拉刷新仅当滚动容器（.directory-content）已在顶部时响应
  const isHubAtTop = useCallback(() => (hubRef.current?.scrollTop ?? 0) <= 0, []);

  useEffect(() => {
    let cancelled = false;
    getElysiaProfile()
      .then((p) => {
        if (!cancelled) setElysiaUserId(p.enabled ? p.user.id : null);
      })
      .catch(() => {
        /* 爱莉入口静默降级：加载失败不展示（elysiaUserId 保持 null） */
      });
    return () => {
      cancelled = true;
    };
  }, []);

  // 侧栏统计：X 直播间（directory.total）· Y 在播（已加载数据中 status=live 数）
  const liveCount = useMemo(() => channels.filter((channel) => channel.status === "live").length, [channels]);

  return (
    <div className="live-hub directory-page">
      <div className="directory-body">
        <DirectoryFilters id={selectionId} label="直播分类" options={FILTERS} value={filter} narrow={isNarrow}
          className="live-filters" buttonClassName="live-filter"
          onChange={(next) => {
            saveScrollPosition(scope, hubRef.current);
            setParams(next === "all" ? {} : { type: next }, { replace: true });
          }}
          decor={<IconVideo width={64} height={64} className="directory-filter-decor live-filter-decor" role="presentation" aria-hidden="true" />}
          header={<div className="directory-filter-header">
            <span className="directory-filter-kicker">Live</span>
            <span className="directory-filter-title">直播间</span>
            <span className="directory-filter-stats">{loading ? "… 直播间 · … 在播" : `${directory.total} 直播间 · ${liveCount} 在播`}</span>
          </div>} />
        <div key={scope} className="directory-content live-content" ref={hubRef}
          id={`${selectionId}-panel`} role="tabpanel" aria-labelledby={`${selectionId}-${filter}`} tabIndex={0}
          onScroll={(event) => directory.onScroll(event.currentTarget)}>
          {loading && visibleChannels.length === 0 ? (
            <div className="conv-loading">
              <div className="skeleton" style={{ height: 96, marginBottom: 8 }} />
              <div className="skeleton" style={{ height: 96 }} />
            </div>
          ) : error && channels.length === 0 ? <DirectoryLoadMore {...directory} /> : (
            <PullToRefresh isAtTop={isHubAtTop} onRefresh={refreshWithReplay}>
              {visibleChannels.length === 0 && filter !== "all" ? (
                <div className="home-state">
                  <h3 className="placeholder-title">这个分类还没有直播间</h3>
                  <p className="placeholder-desc">换个分类看看</p>
                </div>
              ) : (
                <LiveHall
                  channels={visibleChannels}
                  elysiaUserId={elysiaUserId}
                  ownerNames={ownerNames}
                  onEnter={(id) => navigate(`/live/${id}`)}
                />
              )}
              <DirectoryLoadMore {...directory} />
            </PullToRefresh>
          )}
        </div>
      </div>
    </div>
  );
}
