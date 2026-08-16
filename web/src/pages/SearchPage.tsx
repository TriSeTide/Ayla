/**
 * SearchPage —— 全局搜索页（路由 /search，F9，R-S1~S4）。
 *
 * 顶栏复用窄屏 TopBar（variant="search"：自动聚焦 + 左返回 + 输入框，布局文档 §2.7），
 * 搜索词走 URL ?q=（与宽屏 TopNav 同一通道）；宽屏由 AppShell TopNav 承载搜索框。
 * 历史 chips（可清空）+ 五类分组结果（用户/群/帖子/直播间/桌游室）+
 * 每组截断 + "查看更多"；用户点击弹资料卡（加好友/发消息），其余跳对应界面。
 * 可见性过滤由后端完成，前端仅展示（R-S3）。
 */
import { useCallback, useEffect, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { search } from "../api/search";
import type { SearchResults, UserPublic } from "../api/types";
import { Avatar } from "../components/Avatar";
import { UserProfileCard } from "../components/UserProfileCard";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { NarrowTopBar } from "../layout/NarrowTopBar";
import { useSearchStore } from "../stores/search";

export function SearchPage() {
  const navigate = useNavigate();
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const [searchParams, setSearchParams] = useSearchParams();
  const q = searchParams.get("q") ?? "";
  const { history, pushHistory, clearHistory } = useSearchStore();
  const [results, setResults] = useState<SearchResults | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [selectedUser, setSelectedUser] = useState<UserPublic | null>(null);

  const doSearch = useCallback(
    (query: string) => {
      const trimmed = query.trim();
      if (!trimmed) return;
      setLoading(true);
      setError(null);
      pushHistory(trimmed);
      search({ q: trimmed, limit: 3 })
        .then(setResults)
        .catch((e) => setError(e instanceof Error ? e.message : "搜索失败"))
        .finally(() => setLoading(false));
    },
    [pushHistory],
  );

  // 五类分组是否全空（决定无结果空态）
  const hasAnyResult = useCallback((r: SearchResults | null): boolean => {
    if (!r) return false;
    return [r.users, r.groups, r.posts, r.lives, r.games].some(
      (g) => (g?.total ?? 0) > 0,
    );
  }, []);

  // URL q 驱动：进入 /search?q=… 或顶栏/历史更新 q 时自动搜索
  useEffect(() => {
    if (!q) {
      setResults(null);
      setLoading(false);
      setError(null);
      return;
    }
    doSearch(q);
  }, [q, doSearch]);

  /** 历史 chips / 表单提交统一走 URL，与顶栏输入框同步 */
  const submitQuery = (query: string) => {
    const trimmed = query.trim();
    if (!trimmed) return;
    setSearchParams({ q: trimmed });
  };

  return (
    <div className="search-page">
      {isNarrow && <NarrowTopBar variant="search" />}

      {!q && history.length > 0 && (
        <div className="search-history">
          {history.map((h) => (
            <button key={h} type="button" className="search-chip" onClick={() => submitQuery(h)}>
              {h}
            </button>
          ))}
          <button type="button" className="search-clear" onClick={clearHistory}>
            清空
          </button>
        </div>
      )}

      {loading && <div className="search-loading">搜索中…</div>}
      {error && <p className="search-error">{error}</p>}

      {results && hasAnyResult(results) && (
        <div className="search-results">
          <ResultGroup
            title="用户"
            count={results.users?.total ?? 0}
            onMore={() => doSearch(q)}
          >
            {(results.users?.items ?? []).map((u) => (
              <button key={u.id} type="button" className="search-row" onClick={() => setSelectedUser(u)}>
                <Avatar label={u.nickname || u.username} size={36} online={u.online} imageUrl={u.avatar || null} />
                <span className="search-row-title">{u.nickname || u.username}</span>
                {u.signature && <span className="search-row-sub">{u.signature}</span>}
              </button>
            ))}
          </ResultGroup>

          <ResultGroup title="群聊" count={results.groups?.total ?? 0} onMore={() => doSearch(q)}>
            {(results.groups?.items ?? []).map((g) => (
              <button key={g.id} type="button" className="search-row" onClick={() => navigate(`/group/${g.id}`)}>
                <span className="search-row-title">{g.title}</span>
              </button>
            ))}
          </ResultGroup>

          <ResultGroup title="帖子" count={results.posts?.total ?? 0} onMore={() => doSearch(q)}>
            {(results.posts?.items ?? []).map((p) => (
              <button key={p.id} type="button" className="search-row" onClick={() => navigate(`/posts/${p.id}`)}>
                <span className="search-row-title">{p.title || p.body.slice(0, 30)}</span>
              </button>
            ))}
          </ResultGroup>

          <ResultGroup title="直播间" count={results.lives?.total ?? 0} onMore={() => doSearch(q)}>
            {(results.lives?.items ?? []).map((l) => (
              <button key={l.id} type="button" className="search-row" onClick={() => navigate(`/live/${l.id}`)}>
                <span className="search-row-title">{l.title}</span>
              </button>
            ))}
          </ResultGroup>

          <ResultGroup title="桌游室" count={results.games?.total ?? 0} onMore={() => doSearch(q)}>
            {(results.games?.items ?? []).map((g) => (
              <button key={g.id} type="button" className="search-row" onClick={() => navigate("/games")}>
                <span className="search-row-title">{g.name}</span>
              </button>
            ))}
          </ResultGroup>
        </div>
      )}

      {results && !hasAnyResult(results) && !loading && !error && (
        <div className="search-empty" role="status">
          <h3 className="placeholder-title">未找到「{q}」相关结果</h3>
          <p className="placeholder-desc">换个关键词试试，或检查是否有拼写错误</p>
        </div>
      )}

      {selectedUser && (
        <div className="user-profile-overlay" onClick={() => setSelectedUser(null)}>
          <div onClick={(e) => e.stopPropagation()}>
            <UserProfileCard user={selectedUser} onClose={() => setSelectedUser(null)} />
          </div>
        </div>
      )}
    </div>
  );
}

function ResultGroup({ title, count, children, onMore }: {
  title: string;
  count: number;
  children: React.ReactNode;
  onMore?: () => void;
}) {
  if (count === 0) return null;
  return (
    <section className="search-group">
      <header className="search-group-head">
        <span className="search-group-title">{title}</span>
        {onMore && count > 3 && <button type="button" className="search-more" onClick={onMore}>查看更多</button>}
      </header>
      <div className="search-group-body">{children}</div>
    </section>
  );
}
