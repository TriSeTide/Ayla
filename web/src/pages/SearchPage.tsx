/**
 * SearchPage —— 全局搜索页（路由 /search，F9，R-S1~S4）。
 *
 * 搜索输入（自动聚焦）+ 历史 chips（可清空）+ 五类分组结果（用户/群/帖子/直播间/桌游室）+
 * 每组截断 + "查看更多"；用户点击弹资料卡（加好友/发消息），其余跳对应界面。
 * 可见性过滤由后端完成，前端仅展示（R-S3）。
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { search } from "../api/search";
import type { SearchResults, UserPublic } from "../api/types";
import { Avatar } from "../components/Avatar";
import { UserProfileCard } from "../components/UserProfileCard";
import { IconSearch } from "../components/icons";
import { NarrowTopBar } from "../layout/NarrowTopBar";
import { useSearchStore } from "../stores/search";

export function SearchPage() {
  const navigate = useNavigate();
  const { history, pushHistory, clearHistory } = useSearchStore();
  const [q, setQ] = useState("");
  const [results, setResults] = useState<SearchResults | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [selectedUser, setSelectedUser] = useState<UserPublic | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  const doSearch = useCallback((query: string) => {
    const trimmed = query.trim();
    if (!trimmed) return;
    setLoading(true);
    setError(null);
    pushHistory(trimmed);
    search({ q: trimmed, limit: 3 })
      .then(setResults)
      .catch((e) => setError(e instanceof Error ? e.message : "搜索失败"))
      .finally(() => setLoading(false));
  }, [pushHistory]);

  const onSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    doSearch(q);
  };

  return (
    <div className="search-page">
      <NarrowTopBar />
      <form className="search-input-wrap" onSubmit={onSubmit}>
        <IconSearch width={16} height={16} />
        <input
          ref={inputRef}
          className="search-input"
          placeholder="搜索用户、群、帖子、直播间、桌游室"
          value={q}
          onChange={(e) => setQ(e.target.value)}
        />
      </form>

      {history.length > 0 && !results && (
        <div className="search-history">
          {history.map((h) => (
            <button key={h} type="button" className="search-chip" onClick={() => { setQ(h); doSearch(h); }}>
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

      {results && (
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
