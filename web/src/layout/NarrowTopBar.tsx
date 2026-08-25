/**
 * NarrowTopBar —— 窄屏一级界面顶栏（布局文档 §2.1，五个 tab 共用骨架）。
 *
 * 主页三件套：左头像 36px（带光环 → 个人界面，R-H1）、中搜索胶囊（点击进搜索页，R-H2）、
 * 右「三」更多按钮（个人页 / 退出登录；个性化/扫一扫/收藏随 F10 扩展，R-H3）。
 *
 * F2 落于 HomePage 顶部；F4-F7 各一级 tab 页复用同一组件。
 *
 * variant="search"（布局文档 §2.7「搜索界面：TopBar 变搜索输入态」）：
 * 左返回（IconBack → 回上一页）+ 搜索输入框（自动聚焦，回车提交 /search?q=…，
 * 与宽屏 TopNav 同走 URL 参数）+ 右「三」更多。F9 起 SearchPage 复用。
 */
import { useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { Avatar } from "../components/Avatar";
import { IconBack, IconClose, IconDots, IconSearch } from "../components/icons";
import { useAuthStore } from "../stores/auth";

export function NarrowTopBar({ variant = "default" }: { variant?: "default" | "search" }) {
  const currentUser = useAuthStore((s) => s.currentUser);
  const logout = useAuthStore((s) => s.logout);
  const navigate = useNavigate();
  const [moreOpen, setMoreOpen] = useState(false);
  const moreRef = useRef<HTMLDivElement>(null);
  const [searchParams, setSearchParams] = useSearchParams();
  const [query, setQuery] = useState(searchParams.get("q") ?? "");
  const inputRef = useRef<HTMLInputElement>(null);

  // 搜索输入态：进入即自动聚焦（布局文档 §2.7）
  useEffect(() => {
    if (variant === "search") inputRef.current?.focus();
  }, [variant]);

  // URL q 变化（如从历史/结果回退）时同步输入框
  useEffect(() => {
    setQuery(searchParams.get("q") ?? "");
  }, [searchParams]);

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
    // replace：搜索词变更不进历史栈，返回键 navigate(-1) 直接回上一个界面
    navigate(q ? `/search?q=${encodeURIComponent(q)}` : "/search", { replace: true });
  };

  const clearQuery = () => {
    setQuery("");
    // 清空 URL q 让 SearchPage 同步清空结果区；replace 避免清除操作产生历史记录
    setSearchParams({}, { replace: true });
    inputRef.current?.focus();
  };

  const moreMenu = (
    <div className="narrow-topbar-more" ref={moreRef}>
      <button
        type="button"
        className="icon-btn-40"
        aria-label="更多"
        aria-haspopup="menu"
        aria-expanded={moreOpen}
        onClick={() => setMoreOpen((v) => !v)}
      >
        <IconDots width={20} height={20} />
      </button>
      {moreOpen && (
        <div className="narrow-topbar-menu" role="menu">
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
  );

  return (
    <header className="narrow-topbar">
      {variant === "search" ? (
        <>
          <button
            type="button"
            className="icon-btn-40"
            aria-label="返回"
            onClick={() => navigate(-1)}
          >
            <IconBack width={20} height={20} />
          </button>
          <form className="narrow-topbar-search narrow-topbar-search-input" role="search" onSubmit={submitSearch}>
            <input
              ref={inputRef}
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder="搜索用户、群、帖子…"
              aria-label="全局搜索"
            />
            {query && (
              <button
                type="button"
                className="search-box-clear"
                aria-label="清除搜索"
                onClick={clearQuery}
              >
                <IconClose width={14} height={14} />
              </button>
            )}
            <button
              type="submit"
              className="search-box-submit"
              aria-label="搜索"
            >
              <IconSearch width={18} height={18} />
            </button>
          </form>
          {moreMenu}
        </>
      ) : (
        <>
          <Link to="/profile" className="narrow-topbar-avatar" aria-label="个人主页">
            {currentUser && (
              <Avatar
                label={currentUser.nickname || currentUser.username}
                size={36}
                online={currentUser.online}
                imageUrl={currentUser.avatar || null}
              />
            )}
          </Link>

          <Link to="/search" className="narrow-topbar-search" aria-label="全局搜索">
            <IconSearch width={16} height={16} />
            <span>搜索</span>
          </Link>

          {moreMenu}
        </>
      )}
    </header>
  );
}
