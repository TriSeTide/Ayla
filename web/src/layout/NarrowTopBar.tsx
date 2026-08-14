/**
 * NarrowTopBar —— 窄屏一级界面顶栏（布局文档 §2.1，五个 tab 共用骨架）。
 *
 * 主页三件套：左头像 36px（带光环 → 个人界面，R-H1）、中搜索胶囊（点击进搜索页，R-H2）、
 * 右「三」更多按钮（个人页 / 退出登录；个性化/扫一扫/收藏随 F10 扩展，R-H3）。
 *
 * F2 落于 HomePage 顶部；F4-F7 各一级 tab 页复用同一组件。
 */
import { useEffect, useRef, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { Avatar } from "../components/Avatar";
import { IconDots, IconSearch } from "../components/icons";
import { useAuthStore } from "../stores/auth";

export function NarrowTopBar() {
  const currentUser = useAuthStore((s) => s.currentUser);
  const logout = useAuthStore((s) => s.logout);
  const navigate = useNavigate();
  const [moreOpen, setMoreOpen] = useState(false);
  const moreRef = useRef<HTMLDivElement>(null);

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

  return (
    <header className="narrow-topbar">
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
                logout();
                navigate("/login");
              }}
            >
              退出登录
            </button>
          </div>
        )}
      </div>
    </header>
  );
}
