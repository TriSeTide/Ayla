/**
 * 受保护主布局：左侧导航 + 主区域 Outlet。
 * M5-1 只搭架子：侧边栏放占位项（会话/设置），后续里程碑往里填内容。
 */
import { NavLink, Outlet } from "react-router-dom";
import { checkLive } from "../api/health";
import { useAuth } from "../hooks/useAuth";
import { usePresenceStore } from "../stores/presence";
import { useEffect, useState } from "react";

const NAV_ITEMS = [
  { to: "/chat", label: "会话", end: true },
  { to: "/settings", label: "设置", end: false },
];

export function HomeLayout() {
  const { currentUser, logout } = useAuth();
  const connection = usePresenceStore((s) => s.connection);
  const [backendAlive, setBackendAlive] = useState<boolean | null>(null);

  // 启动自检：后端存活探针
  useEffect(() => {
    let cancelled = false;
    checkLive().then((r) => {
      if (!cancelled) setBackendAlive(r?.status === "alive");
    });
    return () => {
      cancelled = true;
    };
  }, []);

  const presenceLabel =
    connection === "online"
      ? "在线"
      : connection === "connecting"
        ? "连接中…"
        : "离线";

  return (
    <div className="home-layout">
      <aside className="sidebar">
        <div className="sidebar-brand">Elysia</div>
        <nav className="sidebar-nav">
          {NAV_ITEMS.map((item) => (
            <NavLink
              key={item.to}
              to={item.to}
              end={item.end}
              className={({ isActive }) => (isActive ? "nav-item active" : "nav-item")}
            >
              {item.label}
            </NavLink>
          ))}
        </nav>
        <div className="sidebar-status">
          <div className="status-row">
            <span className={`dot ${connection}`} />
            Presence {presenceLabel}
          </div>
          <div className="status-row">
            <span className={`dot ${backendAlive === true ? "online" : "offline"}`} />
            后端 {backendAlive === null ? "检测中" : backendAlive ? "正常" : "不可用"}
          </div>
        </div>
        <div className="sidebar-footer">
          {currentUser && (
            <div className="user-line">
              <span className="avatar">{currentUser.nickname?.[0] ?? currentUser.username[0]}</span>
              <span className="user-name">{currentUser.nickname || currentUser.username}</span>
            </div>
          )}
          <button className="logout-btn" onClick={logout}>
            退出登录
          </button>
        </div>
      </aside>
      <main className="content">
        <Outlet />
      </main>
    </div>
  );
}
