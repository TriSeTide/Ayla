/**
 * PrivacySheet —— 隐私设置弹窗（design.md §12.5 弹层规格，与 ShareSheet 同族）。
 *
 * - portal 到 document.body（规避父级 backdrop-filter stacking context 裁剪 fixed 弹层）；
 * - 窄屏（≤768px）：60% 高度下半屏上滑弹窗；宽屏：中央 modal；遮罩点击/ESC/关闭键关闭；
 * - 视图流（全部在弹窗内完成）：
 *   menu 选项：邮箱换绑 / 更改密码
 *   改密：验证码发至当前绑定邮箱（60s 倒计时重发）+ 新密码两次确认 → changePassword
 *   换绑：step1 当前邮箱验证码（未绑定邮箱则跳过）→ step2 新邮箱 + 发至新邮箱的验证码 → changeEmail
 * - prefers-reduced-motion 关闭位移。
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { AnimatePresence, motion } from "framer-motion";
import { ApiError } from "../api/client";
import { changeEmail, changePassword, sendEmailCode } from "../api/auth";
import { useAuthStore } from "../stores/auth";
import { IconClose } from "./icons";

const CODE_COOLDOWN = 60;
const EASE_OUT: [number, number, number, number] = [0.22, 0.61, 0.36, 1];

type View = "menu" | "password" | "email" | "done";

function prefersReducedMotion(): boolean {
  return (
    typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches
  );
}

function isNarrow(): boolean {
  return typeof window === "undefined" || window.innerWidth <= 768;
}

export function PrivacySheet({ onClose }: { onClose: () => void }) {
  const currentUser = useAuthStore((s) => s.currentUser);
  const [view, setView] = useState<View>("menu");
  const [emailStep, setEmailStep] = useState<1 | 2>(1);
  // 改密：验证码 + 新密码两次
  const [code, setCode] = useState("");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  // 换绑：当前邮箱码 + 新邮箱 + 新邮箱码
  const [curCode, setCurCode] = useState("");
  const [newEmail, setNewEmail] = useState("");
  const [newCode, setNewCode] = useState("");
  // 发码状态
  const [sending, setSending] = useState(false);
  const [countdown, setCountdown] = useState(0);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [doneMsg, setDoneMsg] = useState("");
  const closedRef = useRef(false);

  const boundEmail = currentUser?.email || "";

  // ESC 关闭
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const close = useCallback(() => {
    if (closedRef.current) return;
    closedRef.current = true;
    onClose();
  }, [onClose]);

  // 发码倒计时
  useEffect(() => {
    if (countdown <= 0) return;
    const timer = setInterval(() => setCountdown((c) => c - 1), 1000);
    return () => clearInterval(timer);
  }, [countdown > 0]);

  async function sendCodeTo(target: string) {
    setError(null);
    if (!target.trim()) {
      setError("请先填写邮箱");
      return;
    }
    setSending(true);
    try {
      await sendEmailCode({ email: target.trim() });
      setCountdown(CODE_COOLDOWN);
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "验证码发送失败，请稍后重试");
    } finally {
      setSending(false);
    }
  }

  async function submitPassword() {
    setError(null);
    if (!/^\d{6}$/.test(code.trim())) {
      setError("请输入 6 位数字验证码");
      return;
    }
    if (password.length < 8) {
      setError("新密码至少 8 位");
      return;
    }
    if (password !== confirm) {
      setError("两次输入的密码不一致");
      return;
    }
    setSubmitting(true);
    try {
      await changePassword({ code: code.trim(), new_password: password });
      setDoneMsg("密码已更新");
      setView("done");
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "修改失败，请稍后重试");
    } finally {
      setSubmitting(false);
    }
  }

  async function submitEmail() {
    setError(null);
    if (!/^\d{6}$/.test(newCode.trim())) {
      setError("请输入新邮箱的 6 位数字验证码");
      return;
    }
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(newEmail.trim())) {
      setError("请输入有效的新邮箱地址");
      return;
    }
    setSubmitting(true);
    try {
      await changeEmail({
        current_code: boundEmail ? curCode.trim() : "",
        new_email: newEmail.trim(),
        new_code: newCode.trim(),
      });
      setDoneMsg("邮箱已更新");
      setView("done");
    } catch (err) {
      setError(err instanceof ApiError ? err.message : "换绑失败，请稍后重试");
    } finally {
      setSubmitting(false);
    }
  }

  function openPassword() {
    setError(null);
    setView("password");
  }

  function openEmail() {
    setError(null);
    setEmailStep(boundEmail ? 1 : 2);
    setView("email");
  }

  const reduced = prefersReducedMotion();

  return createPortal(
    <AnimatePresence>
      <motion.div
        key="privacy-overlay"
        className="privacy-sheet-overlay"
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        exit={{ opacity: 0 }}
        transition={{ duration: 0.18 }}
        onClick={close}
      >
        <motion.div
          key="privacy-card"
          className={`privacy-sheet-card${isNarrow() ? " is-narrow" : ""}`}
          initial={reduced ? false : { y: isNarrow() ? "100%" : -12, opacity: 0 }}
          animate={{ y: 0, opacity: 1 }}
          exit={reduced ? undefined : { y: isNarrow() ? "100%" : -12, opacity: 0 }}
          transition={{ duration: 0.25, ease: EASE_OUT }}
          onClick={(e) => e.stopPropagation()}
          role="dialog"
          aria-modal="true"
          aria-label="隐私设置"
        >
          <header className="privacy-sheet-head">
            <span className="privacy-sheet-title">隐私设置</span>
            <button type="button" className="icon-btn-40" onClick={close} aria-label="关闭">
              <IconClose width={18} height={18} />
            </button>
          </header>

          {view === "menu" && (
            <div className="privacy-sheet-body privacy-menu">
              <p className="privacy-menu-hint">变更需要通过绑定邮箱验证</p>
              <button type="button" className="privacy-menu-item" onClick={openEmail}>
                <span className="privacy-menu-item-title">邮箱换绑</span>
                <span className="privacy-menu-item-desc">
                  {boundEmail ? `当前：${boundEmail}` : "当前未绑定邮箱"}
                </span>
              </button>
              <button type="button" className="privacy-menu-item" onClick={openPassword}>
                <span className="privacy-menu-item-title">更改密码</span>
                <span className="privacy-menu-item-desc">通过邮箱验证码修改登录密码</span>
              </button>
            </div>
          )}

          {view === "password" && (
            <div className="privacy-sheet-body">
              <p className="privacy-sheet-hint">
                验证码将发送至{boundEmail ? ` ${boundEmail}` : "你当前绑定的邮箱"}
              </p>
              {error && (
                <div className="auth-error" role="alert">
                  {error}
                </div>
              )}
              <div className="auth-code-row">
                <input
                  className="field"
                  inputMode="numeric"
                  maxLength={6}
                  value={code}
                  onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
                  placeholder="6 位验证码"
                  autoComplete="one-time-code"
                />
                <button
                  type="button"
                  className="btn btn-ghost auth-code-btn"
                  onClick={() => void sendCodeTo(boundEmail)}
                  disabled={sending || countdown > 0 || !boundEmail}
                >
                  {sending ? "发送中…" : countdown > 0 ? `重新发送（${countdown}s）` : "发送验证码"}
                </button>
              </div>
              <label className="auth-field">
                新密码（至少 8 位）
                <input
                  className="field"
                  type="password"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  autoComplete="new-password"
                />
              </label>
              <label className="auth-field">
                确认新密码
                <input
                  className="field"
                  type="password"
                  value={confirm}
                  onChange={(e) => setConfirm(e.target.value)}
                  autoComplete="new-password"
                />
              </label>
              <button type="button" className="btn btn-primary privacy-sheet-submit" disabled={submitting} onClick={() => void submitPassword()}>
                {submitting ? "提交中…" : "确认修改"}
              </button>
            </div>
          )}

          {view === "email" && emailStep === 1 && (
            <div className="privacy-sheet-body">
              <p className="privacy-sheet-hint">
                第一步：验证当前邮箱 <strong>{boundEmail}</strong>
              </p>
              {error && (
                <div className="auth-error" role="alert">
                  {error}
                </div>
              )}
              <div className="auth-code-row">
                <input
                  className="field"
                  inputMode="numeric"
                  maxLength={6}
                  value={curCode}
                  onChange={(e) => setCurCode(e.target.value.replace(/\D/g, ""))}
                  placeholder="6 位验证码"
                  autoComplete="one-time-code"
                />
                <button
                  type="button"
                  className="btn btn-ghost auth-code-btn"
                  onClick={() => void sendCodeTo(boundEmail)}
                  disabled={sending || countdown > 0}
                >
                  {sending ? "发送中…" : countdown > 0 ? `重新发送（${countdown}s）` : "发送验证码"}
                </button>
              </div>
              <button
                type="button"
                className="btn btn-primary privacy-sheet-submit"
                disabled={!/^\d{6}$/.test(curCode.trim())}
                onClick={() => {
                  setError(null);
                  setEmailStep(2);
                }}
              >
                下一步
              </button>
            </div>
          )}

          {view === "email" && emailStep === 2 && (
            <div className="privacy-sheet-body">
              <p className="privacy-sheet-hint">第二步：验证新邮箱</p>
              {error && (
                <div className="auth-error" role="alert">
                  {error}
                </div>
              )}
              <label className="auth-field">
                新邮箱
                <input
                  className="field"
                  type="email"
                  value={newEmail}
                  onChange={(e) => setNewEmail(e.target.value)}
                  autoComplete="email"
                  placeholder="用于接收验证码的新邮箱"
                />
              </label>
              <div className="auth-code-row">
                <input
                  className="field"
                  inputMode="numeric"
                  maxLength={6}
                  value={newCode}
                  onChange={(e) => setNewCode(e.target.value.replace(/\D/g, ""))}
                  placeholder="新邮箱 6 位验证码"
                  autoComplete="one-time-code"
                />
                <button
                  type="button"
                  className="btn btn-ghost auth-code-btn"
                  onClick={() => void sendCodeTo(newEmail)}
                  disabled={sending || countdown > 0 || !newEmail.trim()}
                >
                  {sending ? "发送中…" : countdown > 0 ? `重新发送（${countdown}s）` : "发送验证码"}
                </button>
              </div>
              <button type="button" className="btn btn-primary privacy-sheet-submit" disabled={submitting} onClick={() => void submitEmail()}>
                {submitting ? "提交中…" : "确认换绑"}
              </button>
            </div>
          )}

          {view === "done" && (
            <div className="privacy-sheet-body privacy-done">
              <p className="privacy-done-icon" aria-hidden="true">✓</p>
              <p className="privacy-done-text">{doneMsg}</p>
              <button type="button" className="btn btn-primary privacy-sheet-submit" onClick={close}>
                完成
              </button>
            </div>
          )}
        </motion.div>
      </motion.div>
    </AnimatePresence>,
    document.body,
  );
}
