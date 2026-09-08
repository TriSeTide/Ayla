/**
 * ProfilePage —— 个人页：资料查看与编辑、在线状态、三分区（我的发帖/我的直播间/正在玩的桌游）、
 * 收藏入口、账号区（登出）。契约：PATCH /me/profile/（nickname/avatar/signature/status）。
 */
import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { updateProfile } from "../api/auth";
import { ApiError } from "../api/client";
import { mediaContentUrl, uploadMediaFile, validateImageFile } from "../api/media";
import { Avatar } from "../components/Avatar";
import { ProfileContentSections } from "../components/ProfileContentSections";
import { IconBack, IconLogout } from "../components/icons";
import { FullScreenSwipeBack } from "../components/motion/FullScreenSwipeBack";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { useAuth } from "../hooks/useAuth";
import { useAuthStore } from "../stores/auth";
import { usePresenceOnline } from "../utils/displayStatus";

const STATUS_OPTIONS = [
  { value: "auto", label: "自动" },
  { value: "away", label: "离开" },
  { value: "dnd", label: "勿扰" },
  { value: "invisible", label: "隐身" },
] as const;

export function ProfilePage() {
  const navigate = useNavigate();
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const { logout } = useAuth();
  const currentUser = useAuthStore((s) => s.currentUser);
  const setUser = useAuthStore((s) => s.setUser);
  // 自身光环跟随 WS 实时在线（presence 增量）
  const currentUserOnline = usePresenceOnline(currentUser);

  const [nickname, setNickname] = useState(currentUser?.nickname ?? "");
  const [signature, setSignature] = useState(currentUser?.signature ?? "");
  const [status, setStatus] = useState(currentUser?.status ?? "auto");
  const [showContent, setShowContent] = useState(currentUser?.show_content ?? false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);

  // 头像上传（M5-2.1）：选择 → 本地校验 → 预览 → 保存时三步上传 + PATCH，失败保留可重试
  const [avatarFile, setAvatarFile] = useState<File | null>(null);
  const [avatarPreview, setAvatarPreview] = useState<string | null>(null);
  const [avatarError, setAvatarError] = useState<string | null>(null);

  useEffect(() => {
    const account = useAuthStore.getState().currentUser;
    setNickname(account?.nickname ?? "");
    setSignature(account?.signature ?? "");
    setStatus(account?.status ?? "auto");
    setShowContent(account?.show_content ?? false);
    setAvatarFile(null);
    setAvatarPreview(null);
    setAvatarError(null);
    setError(null);
    setSaved(false);
    setSaving(false);
  }, [currentUser?.id]);

  // 释放 objectURL（卸载时）
  useEffect(() => {
    return () => {
      if (avatarPreview) URL.revokeObjectURL(avatarPreview);
    };
  }, [avatarPreview]);

  const pickAvatar = (file: File | undefined) => {
    if (!file) return;
    const invalid = validateImageFile(file);
    if (invalid) {
      setAvatarError(invalid);
      return;
    }
    setAvatarError(null);
    if (avatarPreview) URL.revokeObjectURL(avatarPreview);
    setAvatarFile(file);
    setAvatarPreview(URL.createObjectURL(file));
    setSaved(false);
  };

  if (!currentUser) {
    return (
      <div className="profile-page profile-page-split">
        <div className="profile-column">
          <div className="solid-card profile-card">
            <p className="profile-signature">正在加载个人资料…</p>
          </div>
        </div>
      </div>
    );
  }

  const dirty =
    nickname !== (currentUser.nickname ?? "") ||
    signature !== (currentUser.signature ?? "") ||
    status !== (currentUser.status ?? "auto") ||
    showContent !== (currentUser.show_content ?? false) ||
    avatarFile != null;

  async function onSave() {
    if (saving || !currentUser) return;
    const submitted = { nickname, signature, status, showContent, avatarFile, avatarPreview, userId: currentUser.id };
    setSaving(true);
    setError(null);
    setSaved(false);
    try {
      // 有本地新头像：先完成三步上传，再用 content URL 保存（失败保留文件可重试）
      let avatarUrl: string | undefined;
      if (avatarFile) {
        const uploaded = await uploadMediaFile(avatarFile, "image");
        avatarUrl = mediaContentUrl(uploaded.media_id);
      }
      const updated = await updateProfile({
        nickname: nickname.trim() || undefined,
        signature: signature.trim(),
        status,
        show_content: showContent,
        avatar: avatarUrl,
      });
      if (useAuthStore.getState().currentUser?.id !== submitted.userId) return;
      setUser(updated);
      // A successful save normalizes only the submitted draft; newer edits stay local.
      setNickname((value) => value === submitted.nickname ? updated.nickname ?? "" : value);
      setSignature((value) => value === submitted.signature ? updated.signature ?? "" : value);
      setStatus((value) => value === submitted.status ? updated.status ?? "auto" : value);
      setShowContent((value) => value === submitted.showContent ? updated.show_content ?? false : value);
      setAvatarFile((value) => value === submitted.avatarFile ? null : value);
      setAvatarPreview((value) => value === submitted.avatarPreview ? null : value);
      setAvatarError(null);
      setSaved(true);
    } catch (e) {
      if (useAuthStore.getState().currentUser?.id === submitted.userId) {
        setError(e instanceof ApiError ? e.message : "保存失败，请稍后重试");
      }
    } finally {
      if (useAuthStore.getState().currentUser?.id === submitted.userId) setSaving(false);
    }
  }

  const displayName = currentUser.nickname || currentUser.username;

  return (
    <FullScreenSwipeBack onBack={() => navigate(-1)} enabled={isNarrow}>
      <div className="profile-page profile-page-split">
      <div className="profile-column">
        <div className="profile-side">
        <div className="solid-card profile-card">
          <div className="profile-identity">
            <button
              type="button"
              className="icon-btn-40 profile-card-back"
              onClick={() => navigate(-1)}
              aria-label="返回"
            >
              <IconBack width={20} height={20} />
            </button>
            <div className="profile-avatar-block">
              <Avatar
                label={displayName}
                size={64}
                online={currentUserOnline}
                imageUrl={avatarPreview ?? (currentUser.avatar || null)}
              />
            </div>
            <div className="profile-names">
              <span className="profile-nickname">{displayName}</span>
              <span className="profile-username">@{currentUser.username}</span>
            </div>
          </div>
          <div className="profile-avatar-actions">
            <label className="btn btn-ghost profile-avatar-btn">
              更换头像
              <input
                type="file"
                accept="image/*"
                hidden
                onChange={(e) => {
                  pickAvatar(e.target.files?.[0]);
                  e.target.value = "";
                }}
              />
            </label>
            {avatarPreview && (
              <span className="profile-avatar-hint">新头像将在保存后生效</span>
            )}
            {avatarError && (
              <span className="profile-avatar-error" role="alert">
                {avatarError}
              </span>
            )}
          </div>

          <div className="profile-form">
            <div className="profile-form-row">
              在线状态
              <div className="status-chips" role="radiogroup" aria-label="在线状态">
                {STATUS_OPTIONS.map((opt) => (
                  <button
                    key={opt.value}
                    type="button"
                    role="radio"
                    aria-checked={status === opt.value}
                    className={`status-chip ${status === opt.value ? "active" : ""}`}
                    onClick={() => {
                      setStatus(opt.value);
                      setSaved(false);
                    }}
                  >
                    {opt.label}
                  </button>
                ))}
              </div>
            </div>

            <label className="profile-form-row">
              昵称
              <input
                className="field"
                value={nickname}
                onChange={(e) => {
                  setNickname(e.target.value);
                  setSaved(false);
                }}
                placeholder={currentUser.username}
              />
            </label>

            <label className="profile-form-row">
              个性签名
              <textarea
                className="field"
                value={signature}
                onChange={(e) => {
                  setSignature(e.target.value);
                  setSaved(false);
                }}
                rows={3}
                placeholder="写点什么…"
              />
            </label>

            <label className="profile-form-row profile-show-content-row">
              <span className="profile-show-content-label">
                向他人展示内容
                <small>开启后，他人可在你的主页看到「他的内容」（发帖/直播间/桌游）</small>
              </span>
              <button
                type="button"
                role="switch"
                aria-checked={showContent}
                className={`profile-switch ${showContent ? "is-on" : ""}`}
                onClick={() => {
                  setShowContent((v) => !v);
                  setSaved(false);
                }}
              >
                <span className="profile-switch-knob" />
              </button>
            </label>

            {error && (
              <div className="auth-error" role="alert">
                {error}
              </div>
            )}

            <div className="profile-actions">
              {saved && !dirty && <span className="profile-saved">已保存</span>}
              <button
                type="button"
                className="btn btn-primary"
                onClick={() => void onSave()}
                disabled={saving || !dirty}
              >
                {saving ? "保存中…" : "保存修改"}
              </button>
              <button
                type="button"
                className="btn btn-destructive profile-logout-btn"
                onClick={logout}
              >
                <IconLogout width={15} height={15} />
                退出登录
              </button>
            </div>
          </div>
        </div>

        </div>
        <div className="profile-main">
          <ProfileContentSections key={currentUser.id} ownerId={currentUser.id} mine />
      </div>
      </div>
      </div>
    </FullScreenSwipeBack>
  );
}
