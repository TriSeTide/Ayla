/**
 * TopNav —— 宽屏顶部常驻导航（design.md §12.2，布局文档 §3.1）。
 *
 * 玻璃 64px 常驻：左起 头像（40px 带光环 → 个人界面）→ 一级模块链
 * （当前模块 --text-primary + 底部 2px --glow-500 指示条）→ 消息（未读徽标，
 * F8 接线）→ 搜索框（240px 胶囊，回车进 /search；内联下拉结果面板属 F9）
 * → 更多菜单（个人主页 / 退出登录；个性化 / 扫一扫 / 收藏属 F10）。
 */
import { useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import { Link, useNavigate } from "react-router-dom";
import { search as searchApi } from "../api/search";
import type { SearchResults } from "../api/types";
import { Avatar } from "../components/Avatar";
import { IconDots, IconMessage, IconSearch } from "../components/icons";
import { useAuthStore } from "../stores/auth";
import type { ModuleKey } from "./shellConfig";
import { PRIMARY_MODULES } from "./shellConfig";

export function TopNav({
  moduleKey,
  messagesActive = false,
  messageBadge = 0,
}: {
  moduleKey: ModuleKey | null;
  /** 消息路由选中态（/messages、/chat/:id）：消息项底部指示条高亮 */
  messagesActive?: boolean;
  /** 消息未读聚合（F8 接 me/badges；F1 恒 0） */
  messageBadge?: number;
}) {
  const currentUser = useAuthStore((s) => s.currentUser);
  const logout = useAuthStore((s) => s.logout);
  const navigate = useNavigate();
  const [query, setQuery] = useState("");
  const [moreOpen, setMoreOpen] = useState(false);
  const [searchOpen, setSearchOpen] = useState(false);
  const [searchResults, setSearchResults] = useState<SearchResults | null>(null);
  const moreRef = useRef<HTMLDivElement>(null);

  // 更多菜单：点击外部 / ESC 关闭
  useEffect(() => {
    if (!moreOpen) return;
    const onPointerDown = (e: PointerEvent) => {
      if (moreRef.current && !moreRef.current.contains(e.target as Node)) setMoreOpen(false);
    };
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === "Escape") setMoreOpen(false);
    };
    document.addEventListener("pointerdown", onPointerDown);
    document.addEventListener("keydown", onKeyDown);
    return () => {
      document.removeEventListener("pointerdown", onPointerDown);
      document.removeEventListener("keydown", onKeyDown);
    };
  }, [moreOpen]);

  const submitSearch = (e: FormEvent) => {
    e.preventDefault();
    const q = query.trim();
    navigate(q ? `/search?q=${encodeURIComponent(q)}` : "/search");
    setSearchOpen(false);
  };

  // 内联搜索下拉（去抖 300ms，输入非空才拉）
  useEffect(() => {
    const trimmed = query.trim();
    if (!trimmed) {
      setSearchResults(null);
      return;
    }
    const timer = window.setTimeout(() => {
      searchApi({ q: trimmed, limit: 3 })
        .then((r) => {
          setSearchResults(r);
          setSearchOpen(true);
        })
        .catch(() => {});
    }, 300);
    return () => window.clearTimeout(timer);
  }, [query]);

  const hasDropResults =
    searchResults != null &&
    ((searchResults.users?.total ?? 0) > 0 ||
      (searchResults.groups?.total ?? 0) > 0 ||
      (searchResults.posts?.total ?? 0) > 0 ||
      (searchResults.lives?.total ?? 0) > 0 ||
      (searchResults.games?.total ?? 0) > 0);

  return (
    <header className="top-nav">
      <Link to="/profile" className="top-nav-avatar" aria-label="个人主页">
        {currentUser && (
          <Avatar
            label={currentUser.nickname || currentUser.username}
            size={40}
            online={currentUser.online}
            imageUrl={currentUser.avatar || null}
          />
        )}
      </Link>

      <nav className="top-nav-modules" aria-label="一级模块">
        {PRIMARY_MODULES.map((m) => (
          <Link
            key={m.key}
            to={m.path}
            className={`top-nav-module ${moduleKey === m.key ? "is-active" : ""}`}
            aria-current={moduleKey === m.key ? "page" : undefined}
          >
            {m.label}
          </Link>
        ))}
      </nav>

      <div className="top-nav-right">
        <Link
          to="/messages"
          className={`top-nav-icon-btn ${messagesActive ? "is-active" : ""}`}
          aria-label="消息"
          aria-current={messagesActive ? "true" : undefined}
        >
          <IconMessage width={20} height={20} />
          {messageBadge > 0 && (
            <span className="tab-badge" aria-label={`${messageBadge} 条未读`}>
              {messageBadge > 99 ? "99+" : messageBadge}
            </span>
          )}
        </Link>

        <div className="top-nav-search-wrap">
          <form className="top-nav-search" role="search" onSubmit={submitSearch}>
            <IconSearch width={16} height={16} />
            <input
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              onFocus={() => hasDropResults && setSearchOpen(true)}
              onBlur={() => window.setTimeout(() => setSearchOpen(false), 150)}
              placeholder="搜索"
              aria-label="全局搜索"
            />
          </form>
          {searchOpen && hasDropResults && (
            <div className="top-nav-search-panel" role="listbox">
              {(searchResults!.users?.items ?? []).map((u) => (
                <button key={u.id} type="button" className="search-drop-row" onMouseDown={() => navigate(`/search?q=${encodeURIComponent(query)}`)}>
                  <Avatar label={u.nickname || u.username} size={28} online={u.online} imageUrl={u.avatar || null} />
                  <span>{u.nickname || u.username}</span>
                </button>
              ))}
              {(searchResults!.groups?.items ?? []).map((g) => (
                <button key={g.id} type="button" className="search-drop-row" onMouseDown={() => navigate(`/group/${g.id}`)}>
                  <span>群 · {g.title}</span>
                </button>
              ))}
              {(searchResults!.posts?.items ?? []).map((p) => (
                <button key={p.id} type="button" className="search-drop-row" onMouseDown={() => navigate(`/posts/${p.id}`)}>
                  <span>帖子 · {(p.title || p.body).slice(0, 20)}</span>
                </button>
              ))}
              {(searchResults!.lives?.items ?? []).map((l) => (
                <button key={l.id} type="button" className="search-drop-row" onMouseDown={() => navigate(`/live/${l.id}`)}>
                  <span>直播 · {l.title}</span>
                </button>
              ))}
              {(searchResults!.games?.items ?? []).map((g) => (
                <button key={g.id} type="button" className="search-drop-row" onMouseDown={() => navigate("/games")}>
                  <span>桌游 · {g.name}</span>
                </button>
              ))}
            </div>
          )}
        </div>

        <div className="top-nav-more" ref={moreRef}>
          <button
            type="button"
            className="top-nav-icon-btn"
            aria-label="更多"
            aria-haspopup="menu"
            aria-expanded={moreOpen}
            onClick={() => setMoreOpen((v) => !v)}
          >
            <IconDots width={20} height={20} />
          </button>
          {moreOpen && (
            <div className="top-nav-more-menu" role="menu">
              <button
                type="button"
                role="menuitem"
                onClick={() => {
                  setMoreOpen(false);
                  navigate("/profile");
                }}
              >
                个人主页
              </button>
              <button
                type="button"
                role="menuitem"
                onClick={() => {
                  setMoreOpen(false);
                  navigate("/favorites");
                }}
              >
                我的收藏
              </button>
              <button
                type="button"
                role="menuitem"
                onClick={() => {
                  setMoreOpen(false);
                  logout();
                  navigate("/login");
                }}
              >
                退出登录
              </button>
            </div>
          )}
        </div>
      </div>
    </header>
  );
}
