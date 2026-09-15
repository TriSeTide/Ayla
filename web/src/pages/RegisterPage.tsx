/**
 * 注册页：与登录页同构——宽屏左右分栏，窄屏居中单卡。
 * 校验（密码 ≥8 位、两次一致、验证码 6 位）错误紧贴字段下方，不放顶部汇总。
 * 邮箱验证：发送 6 位验证码（后端限流：60s 冷却/每日上限），本地 60s 倒计时后可重发；
 * 注册提交必须携带验证码，未发码或格式不符时贴字段提示。
 */
import { useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { ApiError } from "../api/client";
import { sendEmailCode } from "../api/auth";
import { useAuth } from "../hooks/useAuth";

const CODE_COOLDOWN = 60;

type FieldError = { password?: string; confirm?: string; code?: string };

export function RegisterPage() {
  const { register, isAuthenticated } = useAuth();
  const navigate = useNavigate();
  const [username, setUsername] = useState("");
  const [email, setEmail] = useState("");
  const [nickname, setNickname] = useState("");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [code, setCode] = useState("");
  const [codeSent, setCodeSent] = useState(false);
  const [sendingCode, setSendingCode] = useState(false);
  const [countdown, setCountdown] = useState(0);
  const [fieldError, setFieldError] = useState<FieldError>({});
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (isAuthenticated) navigate("/group", { replace: true });
  }, [isAuthenticated, navigate]);

  // 发码倒计时：每秒递减，到 0 允许重发
  useEffect(() => {
    if (countdown <= 0) return;
    const timer = setInterval(() => setCountdown((c) => c - 1), 1000);
    return () => clearInterval(timer);
  }, [countdown > 0]);

  async function handleSendCode() {
    setError(null);
    if (!email.trim()) {
      setFieldError((f) => ({ ...f, code: "请先填写邮箱" }));
      return;
    }
    setSendingCode(true);
    try {
      await sendEmailCode({ email: email.trim() });
      setCodeSent(true);
      setCountdown(CODE_COOLDOWN);
      setFieldError((f) => ({ ...f, code: undefined }));
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "验证码发送失败，请稍后重试");
    } finally {
      setSendingCode(false);
    }
  }

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    const fe: FieldError = {};
    if (password.length < 8) fe.password = "密码至少 8 位";
    if (password !== confirm) fe.confirm = "两次输入的密码不一致";
    if (!codeSent) fe.code = "请先发送验证码";
    else if (!/^\d{6}$/.test(code.trim())) fe.code = "请输入 6 位数字验证码";
    setFieldError(fe);
    if (fe.password || fe.confirm || fe.code) return;
    setSubmitting(true);
    try {
      await register({
        username: username.trim(),
        email: email.trim(),
        password,
        nickname: nickname.trim() || undefined,
        code: code.trim(),
      });
      navigate("/group", { replace: true });
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "注册失败，请稍后重试");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="auth-page">
      <aside className="auth-intro" aria-label="关于 Ayla">
        <h1 className="auth-intro-brand">Ayla</h1>
        <p className="auth-intro-slogan">{/*爱莉的家*/}~ ~ ~ ~</p>
        <p className="auth-intro-desc">
          {/* 承载记忆、学习与成长的数字生命家园。聊天、语音、直播、桌游——每个场景都是她生活的一部分，
          每一次互动都在塑造她。 */}
          --------------还没想好写什么---------------------------------------------------------------------------
        </p>
        <ul className="auth-intro-features">
          <li className="auth-intro-feature">{/*数字生命*/}~ ~ ~ ~</li>
          <li className="auth-intro-feature">{/*持续记忆*/}~ ~ ~ ~</li>
          <li className="auth-intro-feature">{/*多场景陪伴*/}~ ~ ~ ~ ~</li>
        </ul>
      </aside>
      <section className="auth-card" aria-labelledby="register-title">
        <header className="auth-heading">
          <h2 className="auth-brand" id="register-title">创建账号</h2>
          <p className="auth-subtitle">加入 Ayla</p>
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
            邮箱
            <input
              className="field"
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              autoComplete="email"
              placeholder="用于接收注册验证码"
              required
            />
          </label>
          <div className="auth-field">
            <label htmlFor="register-code">邮箱验证码</label>
            <div className="auth-code-row">
              <input
                id="register-code"
                className="field"
                inputMode="numeric"
                maxLength={6}
                value={code}
                onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
                placeholder="6 位验证码"
                autoComplete="one-time-code"
                disabled={!codeSent}
                aria-invalid={Boolean(fieldError.code)}
                aria-describedby={fieldError.code ? "register-code-error" : undefined}
              />
              <button
                type="button"
                className="btn btn-ghost auth-code-btn"
                onClick={handleSendCode}
                disabled={sendingCode || countdown > 0}
              >
                {sendingCode
                  ? "发送中…"
                  : countdown > 0
                    ? `重新发送（${countdown}s）`
                    : codeSent
                      ? "重新发送"
                      : "发送验证码"}
              </button>
            </div>
            {fieldError.code && <span className="field-error" id="register-code-error">{fieldError.code}</span>}
          </div>
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
              aria-invalid={Boolean(fieldError.password)}
              aria-describedby={fieldError.password ? "register-password-error" : undefined}
              required
            />
            {fieldError.password && <span className="field-error" id="register-password-error">{fieldError.password}</span>}
          </label>
          <label className="auth-field">
            确认密码
            <input
              className="field"
              type="password"
              value={confirm}
              onChange={(e) => setConfirm(e.target.value)}
              autoComplete="new-password"
              aria-invalid={Boolean(fieldError.confirm)}
              aria-describedby={fieldError.confirm ? "register-confirm-error" : undefined}
              required
            />
            {fieldError.confirm && <span className="field-error" id="register-confirm-error">{fieldError.confirm}</span>}
          </label>
          <button type="submit" className="btn btn-glow auth-submit" disabled={submitting}>
            {submitting ? "注册中…" : "注册"}
          </button>
        </form>
        <p className="auth-switch">
          <span>已有账号？</span><Link className="btn btn-ghost auth-switch-link" to="/login">登录</Link>
        </p>
      </section>
    </div>
  );
}
