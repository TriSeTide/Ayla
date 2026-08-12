/**
 * 注册页：与登录页同构的居中单卡。
 * 校验（密码 ≥8 位、两次一致）错误紧贴字段下方，不放顶部汇总。
 */
import { useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { ApiError } from "../api/client";
import { useAuth } from "../hooks/useAuth";

export function RegisterPage() {
  const { register, isAuthenticated } = useAuth();
  const navigate = useNavigate();
  const [username, setUsername] = useState("");
  const [email, setEmail] = useState("");
  const [nickname, setNickname] = useState("");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [fieldError, setFieldError] = useState<{ password?: string; confirm?: string }>({});
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (isAuthenticated) navigate("/", { replace: true });
  }, [isAuthenticated, navigate]);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    const fe: { password?: string; confirm?: string } = {};
    if (password.length < 8) fe.password = "密码至少 8 位";
    if (password !== confirm) fe.confirm = "两次输入的密码不一致";
    setFieldError(fe);
    if (fe.password || fe.confirm) return;
    setSubmitting(true);
    try {
      await register({
        username: username.trim(),
        email: email.trim(),
        password,
        nickname: nickname.trim() || undefined,
      });
      navigate("/", { replace: true });
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "注册失败，请稍后重试");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="auth-page">
      <div className="auth-card">
        <h1 className="auth-brand">创建账号</h1>
        <p className="auth-subtitle">加入 Ayla</p>
        <form className="auth-form" onSubmit={onSubmit}>
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
            邮箱
            <input
              className="field"
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              autoComplete="email"
              required
            />
          </label>
          <label className="auth-field">
            昵称（可选）
            <input
              className="field"
              value={nickname}
              onChange={(e) => setNickname(e.target.value)}
              placeholder="留空则使用用户名"
            />
          </label>
          <label className="auth-field">
            密码（至少 8 位）
            <input
              className="field"
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              autoComplete="new-password"
              required
            />
            {fieldError.password && <span className="field-error">{fieldError.password}</span>}
          </label>
          <label className="auth-field">
            确认密码
            <input
              className="field"
              type="password"
              value={confirm}
              onChange={(e) => setConfirm(e.target.value)}
              autoComplete="new-password"
              required
            />
            {fieldError.confirm && <span className="field-error">{fieldError.confirm}</span>}
          </label>
          <button type="submit" className="btn btn-glow" disabled={submitting}>
            {submitting ? "注册中…" : "注册"}
          </button>
        </form>
        <p className="auth-switch">
          已有账号？<Link to="/login">登录</Link>
        </p>
      </div>
    </div>
  );
}
