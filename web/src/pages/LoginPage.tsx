/**
 * 登录页：宽屏左右分栏（左侧品牌介绍 + 右侧玻璃表单卡），窄屏退回居中单卡。
 * 登录成功后统一进入主页 /group。
 */
import { useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { ApiError } from "../api/client";
import { useAuth } from "../hooks/useAuth";

export function LoginPage() {
  const { login, isAuthenticated } = useAuth();
  const navigate = useNavigate();
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (isAuthenticated) navigate("/group", { replace: true });
  }, [isAuthenticated, navigate]);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setSubmitting(true);
    try {
      await login(username.trim(), password);
      navigate("/group", { replace: true });
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "登录失败，请稍后重试");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="auth-page">
      <aside className="auth-intro" aria-label="关于 Ayla">
        <h1 className="auth-intro-brand">Ayla</h1>
        <p className="auth-intro-slogan">爱莉的家</p>
        <p className="auth-intro-desc">
          承载记忆、学习与成长的数字生命家园。聊天、语音、直播、桌游——每个场景都是她生活的一部分，
          每一次互动都在塑造她。
        </p>
        <ul className="auth-intro-features">
          <li className="auth-intro-feature">数字生命</li>
          <li className="auth-intro-feature">持续记忆</li>
          <li className="auth-intro-feature">多场景陪伴</li>
        </ul>
      </aside>
      <section className="auth-card" aria-labelledby="login-title">
        <header className="auth-heading">
          <h2 className="auth-brand" id="login-title">Ayla</h2>
          <p className="auth-subtitle">登录，回到爱莉的家</p>
        </header>
        <form className="auth-form" onSubmit={onSubmit} aria-busy={submitting}>
          {error && (
            <div className="auth-error" role="alert">
              {error}
            </div>
          )}
          <label className="auth-field">
            用户名
            <input
              className="field"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              autoComplete="username"
              autoFocus
              required
            />
          </label>
          <label className="auth-field">
            密码
            <input
              className="field"
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              autoComplete="current-password"
              required
            />
          </label>
          <button type="submit" className="btn btn-glow auth-submit" disabled={submitting}>
            {submitting ? "登录中…" : "登录"}
          </button>
        </form>
        <p className="auth-switch">
          <span>还没有账号？</span><Link className="btn btn-ghost auth-switch-link" to="/register">注册</Link>
        </p>
      </section>
    </div>
  );
}
