/**
 * ProfilePage —— 个人页：资料查看与编辑、在线状态、三分区（我的发帖/我的直播间/正在玩的桌游）、
 * 收藏入口、账号区（登出）。契约：PATCH /me/profile/（nickname/avatar/signature/status）。
 */
import { useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { updateProfile } from "../api/auth";
import * as boardgameApi from "../api/boardgame";
import { ApiError } from "../api/client";
import * as liveApi from "../api/live";
import { mediaContentUrl, uploadMediaFile, validateAvatarFile } from "../api/media";
import * as postsApi from "../api/posts";
import type { GameRoom, LiveChannelDescriptor, Post } from "../api/types";
import { Avatar } from "../components/Avatar";
import { IconBack, IconLogout } from "../components/icons";
import { useAuth } from "../hooks/useAuth";
import { useAuthStore } from "../stores/auth";

const STATUS_OPTIONS = [
  { value: "online", label: "在线" },
  { value: "away", label: "离开" },
  { value: "dnd", label: "勿扰" },
  { value: "invisible", label: "隐身" },
] as const;

export function ProfilePage() {
  const navigate = useNavigate();
  const { logout } = useAuth();
  const currentUser = useAuthStore((s) => s.currentUser);
  const setUser = useAuthStore((s) => s.setUser);

  const [nickname, setNickname] = useState(currentUser?.nickname ?? "");
  const [signature, setSignature] = useState(currentUser?.signature ?? "");
  const [status, setStatus] = useState(currentUser?.status ?? "online");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);

  // 头像上传（M5-2.1）：选择 → 本地校验 → 预览 → 保存时三步上传 + PATCH，失败保留可重试
  const [avatarFile, setAvatarFile] = useState<File | null>(null);
  const [avatarPreview, setAvatarPreview] = useState<string | null>(null);
  const [avatarError, setAvatarError] = useState<string | null>(null);

  // 释放 objectURL（卸载时）
  useEffect(() => {
    return () => {
      if (avatarPreview) URL.revokeObjectURL(avatarPreview);
    };
  }, [avatarPreview]);

  const pickAvatar = (file: File | undefined) => {
    if (!file) return;
    const invalid = validateAvatarFile(file);
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

  // F10 三分区数据
  const [myPosts, setMyPosts] = useState<Post[]>([]);
  const [myLives, setMyLives] = useState<LiveChannelDescriptor[]>([]);
  const [myGames, setMyGames] = useState<GameRoom[]>([]);
  const [contentError, setContentError] = useState<string | null>(null);

  useEffect(() => {
    if (!currentUser) return;
    setContentError(null);
    Promise.all([
      postsApi.listPosts({ scope: "mine", limit: 5 }).then((p) => setMyPosts(p.results)),
      liveApi.listLiveChannels().then((l) => setMyLives(l.filter((c) => c.owner_id === currentUser.id))),
      boardgameApi.listGameRooms(true).then(setMyGames),
    ]).catch((e) => setContentError(e instanceof Error ? e.message : "加载我的内容失败"));
  }, [currentUser?.id]); // eslint-disable-line react-hooks/exhaustive-deps

  if (!currentUser) {
    return (
      <div className="profile-page">
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
    status !== (currentUser.status ?? "online") ||
    avatarFile != null;

  async function onSave() {
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
        avatar: avatarUrl,
      });
      setUser(updated);
      if (avatarPreview) URL.revokeObjectURL(avatarPreview);
      setAvatarFile(null);
      setAvatarPreview(null);
      setAvatarError(null);
      setSaved(true);
    } catch (e) {
      setError(e instanceof ApiError ? e.message : "保存失败，请稍后重试");
    } finally {
      setSaving(false);
    }
  }

  const displayName = currentUser.nickname || currentUser.username;

  return (
    <div className="profile-page">
      <div className="profile-column">
        <div className="glass-card profile-topbar">
          <button
            type="button"
            className="msg-action-btn"
            onClick={() => navigate("/home")}
            aria-label="返回主页"
          >
            <IconBack width={14} height={14} style={{ verticalAlign: "-2px", marginRight: 4 }} />
            返回
          </button>
          <span className="profile-topbar-title">个人页</span>
        </div>

        {contentError && <div className="chat-notice" role="alert">{contentError}</div>}
        <div className="solid-card profile-card">
          <div className="profile-identity">
            <div className="profile-avatar-block">
              <Avatar
                label={displayName}
                size={64}
                online={currentUser.online}
                imageUrl={avatarPreview ?? (currentUser.avatar || null)}
              />
              <label className="btn btn-ghost profile-avatar-btn">
                更换头像
                <input
                  type="file"
                  accept="image/png,image/jpeg,image/gif,image/webp"
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
            <div className="profile-names">
              <span className="profile-nickname">{displayName}</span>
              <span className="profile-username">@{currentUser.username}</span>
            </div>
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
                style={{ resize: "vertical" }}
              />
            </label>

            {error && (
              <div className="auth-error" role="alert">
                {error}
              </div>
            )}

            <div className="profile-actions">
              {saved && <span className="profile-saved">已保存</span>}
              <button
                type="button"
                className="btn btn-primary"
                onClick={() => void onSave()}
                disabled={saving || !dirty}
              >
                {saving ? "保存中…" : "保存修改"}
              </button>
            </div>
          </div>
        </div>

        <div className="solid-card profile-mine">
          <h4 className="profile-mine-title">我的内容</h4>

          <section className="profile-section">
            <div className="profile-section-head">
              <span className="profile-section-title">我的发帖</span>
              <span className="profile-section-count">{myPosts.length}</span>
            </div>
            {myPosts.length === 0 ? (
              <p className="profile-section-empty">还没有发帖</p>
            ) : (
              myPosts.map((p) => (
                <Link key={p.id} to={`/posts/${p.id}`} className="profile-section-row">
                  {p.title || p.body.slice(0, 30)}
                </Link>
              ))
            )}
          </section>

          <section className="profile-section">
            <div className="profile-section-head">
              <span className="profile-section-title">我的直播间</span>
              <span className="profile-section-count">{myLives.length}</span>
            </div>
            {myLives.length === 0 ? (
              <p className="profile-section-empty">还没有直播间</p>
            ) : (
              myLives.map((l) => (
                <Link key={l.id} to={`/live/${l.id}`} className="profile-section-row">
                  {l.title}
                </Link>
              ))
            )}
          </section>

          <section className="profile-section">
            <div className="profile-section-head">
              <span className="profile-section-title">正在玩的桌游</span>
              <span className="profile-section-count">{myGames.length}</span>
            </div>
            {myGames.length === 0 ? (
              <p className="profile-section-empty">暂无在局桌游</p>
            ) : (
              myGames.map((g) => (
                <Link key={g.id} to="/games" className="profile-section-row">
                  {g.name}
                </Link>
              ))
            )}
          </section>

          <Link to="/favorites" className="profile-favorites-link">
            我的收藏 →
          </Link>
        </div>

        <div className="solid-card profile-danger">
          <span className="profile-danger-text">
            退出登录会断开当前连接，需要重新登录才能继续。
          </span>
          <button type="button" className="btn btn-destructive" onClick={logout}>
            <IconLogout width={15} height={15} />
            退出登录
          </button>
        </div>
      </div>
    </div>
  );
}
