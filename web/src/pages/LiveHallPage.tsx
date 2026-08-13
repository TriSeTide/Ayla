/**
 * LiveHallPage —— 直播大厅（路由 /live，M5-4）。
 *
 * 频道列表（?only_live=1 只看在播）+ 建频道（含推流指引一次性回显）；
 * owner 是爱莉 user 的频道按普通频道渲染（加"爱莉"角标，无特殊数据通道）。
 */
import { useCallback, useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { getElysiaProfile } from "../api/elysia";
import * as liveApi from "../api/live";
import { ensureUser } from "../api/users";
import { LiveCreate } from "../components/live/LiveCreate";
import { LiveHall } from "../components/live/LiveHall";
import { useLiveStore } from "../stores/live";

export function LiveHallPage() {
  const navigate = useNavigate();
  const channels = useLiveStore((s) => s.channels);
  const loading = useLiveStore((s) => s.channelsLoading);
  const [onlyLive, setOnlyLive] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [elysiaUserId, setElysiaUserId] = useState<string | null>(null);
  const [ownerNames, setOwnerNames] = useState<Record<string, string>>({});

  const load = useCallback(async (only: boolean) => {
    const store = useLiveStore.getState();
    store.setChannelsLoading(true);
    setError(null);
    try {
      const list = await liveApi.listLiveChannels(only);
      store.setChannels(list);
      store.setChannelsLoading(false);
      // 补齐主播昵称（列表 descriptor 不含 owner 信息）
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
      store.setChannelsLoading(false);
      setError(e instanceof Error ? e.message : "加载频道失败");
    }
  }, []);

  useEffect(() => {
    void load(onlyLive);
  }, [onlyLive, load]);

  // 爱莉 profile（"爱莉"角标判断，复用 M5-2/M5-3 的 profile 路径）
  useEffect(() => {
    let cancelled = false;
    getElysiaProfile()
      .then((p) => {
        if (!cancelled) setElysiaUserId(p.enabled ? p.user.id : null);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <div className="live-page">
      <aside className="live-sidebar">
        <div className="chat-sidebar-head">
          <span className="chat-brand">直播</span>
          <button
            type="button"
            className="msg-action-btn"
            onClick={() => navigate("/chat")}
            aria-label="返回聊天"
          >
            聊天
          </button>
        </div>
        <LiveCreate onCreated={(ch) => navigate(`/live/${ch.id}`)} />
      </aside>
      <main className="live-main">
        <div className="live-hall-toolbar">
          <label className="live-hall-filter">
            <input
              type="checkbox"
              checked={onlyLive}
              onChange={(e) => setOnlyLive(e.target.checked)}
            />
            只看在播
          </label>
          <button
            type="button"
            className="msg-action-btn"
            onClick={() => void load(onlyLive)}
          >
            刷新
          </button>
        </div>
        {error && <div className="live-form-error">{error}</div>}
        {loading && channels.length === 0 ? (
          <div className="conv-loading">
            <div className="skeleton" style={{ height: 96, marginBottom: 8 }} />
            <div className="skeleton" style={{ height: 96 }} />
          </div>
        ) : (
          <LiveHall
            channels={channels}
            elysiaUserId={elysiaUserId}
            ownerNames={ownerNames}
            onEnter={(id) => navigate(`/live/${id}`)}
          />
        )}
      </main>
    </div>
  );
}
