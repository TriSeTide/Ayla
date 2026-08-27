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
import * as liveApi from "../api/live";
import { ensureUser } from "../api/users";
import { LiveHall } from "../components/live/LiveHall";
import { PullToRefresh } from "../components/motion/PullToRefresh";
import { useScrollRestore } from "../hooks/useScrollRestore";
import { useLiveStore, isLiveStale } from "../stores/live";
import { useShellStore } from "../stores/shell";

export function LiveHubPage() {
  const navigate = useNavigate();
  const channels = useLiveStore((s) => s.channels);
  const loading = useLiveStore((s) => s.channelsLoading);
  const [onlyLive, setOnlyLive] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [profileError, setProfileError] = useState<string | null>(null);
  const [elysiaUserId, setElysiaUserId] = useState<string | null>(null);
  const [ownerNames, setOwnerNames] = useState<Record<string, string>>({});
  const requestId = useRef(0);
  const hubRef = useRef<HTMLDivElement>(null);
  const { restoring } = useScrollRestore("live-hub", hubRef);
  // §3.4 刷新动画：刷新完成后递增，key 变化强制 LiveHall 重挂载 → reveal 重播
  const [revealNonce, setRevealNonce] = useState(0);

  const load = useCallback(async (only: boolean) => {
    const store = useLiveStore.getState();
    if (
      store.channelsOnlyLive === only
      && store.channels.length > 0
      && !isLiveStale()
      && !store.channelsLoading
    ) return;
    const currentRequest = ++requestId.current;
    store.setChannelsLoading(true);
    setError(null);
    try {
      const list = await liveApi.listLiveChannels({ onlyLive: only });
      if (currentRequest !== requestId.current) return;
      store.setChannels(list, only);
      store.setChannelsLoading(false);
      const ownerIds = [...new Set(list.map((c) => c.owner_id))];
      if (ownerIds.length > 0) {
        const users = await Promise.all(ownerIds.map((id) => ensureUser(id)));
        const names: Record<string, string> = {};
        for (const u of users) {
          if (u) names[u.id] = u.nickname || u.username;
        }
        setOwnerNames((prev) => ({ ...prev, ...names }));
      }
    } catch (e) {
      if (currentRequest !== requestId.current) return;
      store.setChannelsLoading(false);
      setError(e instanceof Error ? e.message : "加载频道失败");
    }
  }, []);

  useEffect(() => {
    void load(onlyLive);
  }, [onlyLive, load]);

  // 下拉刷新/刷新键共用：强制重拉直播列表（绕过 isLiveStale 缓存，不设 channelsLoading 以免骨架闪现）
  const refresh = useCallback(async () => {
    const currentRequest = ++requestId.current;
    setError(null);
    try {
      const list = await liveApi.listLiveChannels({ onlyLive: onlyLive });
      if (currentRequest !== requestId.current) return;
      useLiveStore.getState().setChannels(list, onlyLive);
      setRevealNonce((n) => n + 1);
      const ownerIds = [...new Set(list.map((c) => c.owner_id))];
      if (ownerIds.length > 0) {
        const users = await Promise.all(ownerIds.map((id) => ensureUser(id)));
        const names: Record<string, string> = {};
        for (const u of users) {
          if (u) names[u.id] = u.nickname || u.username;
        }
        setOwnerNames((prev) => ({ ...prev, ...names }));
      }
    } catch (e) {
      if (currentRequest !== requestId.current) return;
      setError(e instanceof Error ? e.message : "加载频道失败");
    }
  }, [onlyLive]);

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
    <div className="live-hub" ref={hubRef}>
      <div className="live-hub-toolbar">
        <label className="live-hall-filter">
          <input
            type="checkbox"
            checked={onlyLive}
            onChange={(e) => setOnlyLive(e.target.checked)}
          />
          只看在播
        </label>
      </div>
      {error && <div className="live-form-error" role="alert">{error}</div>}
      {profileError && <div className="live-form-error" role="alert">爱莉入口暂不可用：{profileError}</div>}
      {loading && visibleChannels.length === 0 ? (
        <div className="conv-loading">
          <div className="skeleton" style={{ height: 96, marginBottom: 8 }} />
          <div className="skeleton" style={{ height: 96 }} />
        </div>
      ) : (
        <PullToRefresh isAtTop={isHubAtTop} onRefresh={refresh}>
          <LiveHall
            key={revealNonce}
            channels={visibleChannels}
            elysiaUserId={elysiaUserId}
            ownerNames={ownerNames}
            onEnter={(id) => navigate(`/live/${id}`)}
            revealItems={!loading && !restoring}
          />
        </PullToRefresh>
      )}
    </div>
  );
}
