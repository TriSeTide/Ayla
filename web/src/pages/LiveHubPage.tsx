/**
 * LiveHubPage —— 一级直播 tab 聚合视图（路由 /live，F4 改造 LiveHallPage）。
 *
 * 聚合网格（窄屏 2 列 / 宽屏 3-4 列，布局文档 §3.1）+ 来源标识（公开/好友/群名，
 * R-L1）+ 空态引导（F4）。建直播间走右下 FAB（CreateFab handler=live），本页不再
 * 内嵌 LiveCreate 侧栏。窄屏带 NarrowTopBar（五 tab 共用骨架）。
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { getElysiaProfile } from "../api/elysia";
import { ensureUser } from "../api/users";
import { LiveHall } from "../components/live/LiveHall";
import { PullToRefresh } from "../components/motion/PullToRefresh";
import { useScrollRestore } from "../hooks/useScrollRestore";
import { useDirectoryPage } from "../hooks/useDirectoryPage";
import { DirectoryLoadMore } from "../components/DirectoryLoadMore";
import { useListEntryMotion } from "../hooks/useListEntryMotion";
import { useShellStore } from "../stores/shell";

export function LiveHubPage() {
  const navigate = useNavigate();
  const [onlyLive, setOnlyLive] = useState(false);
  const directory = useDirectoryPage("live", { onlyLive });
  const { items: channels, loading, error, refresh } = directory;
  const [profileError, setProfileError] = useState<string | null>(null);
  const [elysiaUserId, setElysiaUserId] = useState<string | null>(null);
  const [ownerNames, setOwnerNames] = useState<Record<string, string>>({});
  const hubRef = useRef<HTMLDivElement>(null);
  const { restoring } = useScrollRestore("live-hub", hubRef);
  useListEntryMotion(hubRef, ".live-card-wrap", restoring);

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
    useShellStore.getState().registerRefresh(refresh);
    return () => {
      if (useShellStore.getState().refreshCallback === refresh) {
        useShellStore.getState().registerRefresh(null);
      }
    };
  }, [refresh]);

  // 下拉刷新仅当滚动容器（.live-hub）已在顶部时响应
  const isHubAtTop = useCallback(() => (hubRef.current?.scrollTop ?? 0) <= 0, []);

  const visibleChannels = onlyLive
    ? channels.filter((channel) => channel.status === "live")
    : channels;

  useEffect(() => {
    let cancelled = false;
    getElysiaProfile()
      .then((p) => {
        if (!cancelled) setElysiaUserId(p.enabled ? p.user.id : null);
      })
      .catch((e) => {
        if (!cancelled) setProfileError(e instanceof Error ? e.message : "加载爱莉资料失败");
      });
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <div className="live-hub" ref={hubRef} onScroll={(event) => directory.onScroll(event.currentTarget)}>
      <div className="live-hub-toolbar">
        <label className="live-hall-filter">
          <input
            className="live-hall-filter-input"
            type="checkbox"
            checked={onlyLive}
            onChange={(e) => setOnlyLive(e.target.checked)}
          />
          <span className="live-hall-switch" aria-hidden="true">
            <span className="live-hall-switch-thumb" />
          </span>
          只看在播
        </label>
      </div>
      {profileError && <div className="live-form-error" role="alert">爱莉入口暂不可用：{profileError}</div>}
      {loading && visibleChannels.length === 0 ? (
        <div className="conv-loading">
          <div className="skeleton" style={{ height: 96, marginBottom: 8 }} />
          <div className="skeleton" style={{ height: 96 }} />
        </div>
      ) : error && channels.length === 0 ? <DirectoryLoadMore {...directory} /> : (
        <PullToRefresh isAtTop={isHubAtTop} onRefresh={refresh}>
          <LiveHall
            channels={visibleChannels}
            elysiaUserId={elysiaUserId}
            ownerNames={ownerNames}
            onEnter={(id) => navigate(`/live/${id}`)}
          />
          <DirectoryLoadMore {...directory} />
        </PullToRefresh>
      )}
    </div>
  );
}
