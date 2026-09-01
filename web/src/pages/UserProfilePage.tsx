/**
 * UserProfilePage —— 他人个人主页（路由 /user/:userId）。
 *
 * 展示目标用户公开资料（头像/昵称/签名/在线状态/加入时间），并按与我的好友关系
 * relation（后端 GET /users/<id>/ 提供）显示操作按钮：
 * - none：加好友（发起申请）
 * - pending_sent：申请已发送（待对方处理）
 * - pending_received：对方申请我（可去消息中心处理）
 * - friend：已是好友 →「发消息」（进入私聊）
 * - self：不应出现（路由层重定向 /profile）
 * 风格与 ProfilePage 统一（glass 顶部栏 + solid 资料卡），返回用返回键。
 */
import { useCallback, useEffect, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { openPrivateConversation } from "../api/chat";
import { createFriendRequest, getUserDetail } from "../api/users";
import * as postsApi from "../api/posts";
import * as liveApi from "../api/live";
import * as boardgameApi from "../api/boardgame";
import type { GameRoom, LiveChannelDescriptor, Post, UserPublic } from "../api/types";
import { Avatar } from "../components/Avatar";
import { IconBack } from "../components/icons";
import { useDisplayStatus, usePresenceOnline } from "../utils/displayStatus";

export function UserProfilePage() {
  const { userId } = useParams<{ userId: string }>();
  const navigate = useNavigate();
  const [user, setUser] = useState<UserPublic | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<"friend" | "chat" | null>(null);
  const [actionMsg, setActionMsg] = useState<string | null>(null);
  // 在线状态：presence 实时增量优先，REST 快照兜底；文案按 display_status 规则
  const online = usePresenceOnline(user);
  const displayStatus = useDisplayStatus(user);

  // 「他的内容」（对方开启向他人展示内容时才拉取；收藏永不展示）
  const [theirPosts, setTheirPosts] = useState<Post[]>([]);
  const [theirLives, setTheirLives] = useState<LiveChannelDescriptor[]>([]);
  const [theirGames, setTheirGames] = useState<GameRoom[]>([]);
  const [theirContentError, setTheirContentError] = useState<string | null>(null);
  const [sectionsOpen, setSectionsOpen] = useState<Record<string, boolean>>({
    posts: false,
    lives: false,
    games: false,
  });
  const toggleSection = (key: string) =>
    setSectionsOpen((prev) => ({ ...prev, [key]: !prev[key] }));

  const load = useCallback(() => {
    if (!userId) return;
    setLoading(true);
    setError(null);
    getUserDetail(userId)
      .then((u) => {
        setUser(u);
        setLoading(false);
      })
      .catch((e) => {
        setError(e instanceof Error ? e.message : "加载用户资料失败");
        setLoading(false);
      });
  }, [userId]);

  useEffect(() => {
    load();
  }, [load]);

  // 对方开启「向他人展示内容」时，并行拉取其内容（可见性由后端过滤）
  useEffect(() => {
    if (!userId || !user?.show_content) {
      setTheirPosts([]);
      setTheirLives([]);
      setTheirGames([]);
      return;
    }
    let cancelled = false;
    setTheirContentError(null);
    Promise.all([
      postsApi.listPosts({ owner: userId, limit: 20 }).then((p) => p.results),
      liveApi.listLiveChannels({ owner: userId }),
      boardgameApi.listGameRooms({ owner: userId }),
    ])
      .then(([posts, lives, games]) => {
        if (cancelled) return;
        setTheirPosts(posts);
        setTheirLives(lives);
        setTheirGames(games);
      })
      .catch((e) => {
        if (!cancelled) setTheirContentError(e instanceof Error ? e.message : "加载对方内容失败");
      });
    return () => {
      cancelled = true;
    };
  }, [userId, user?.show_content]);

  // 路由层保护：自己 -> /profile（避免出现"加自己好友"）
  useEffect(() => {
    if (user && user.relation === "self") {
      navigate("/profile", { replace: true });
    }
  }, [user, navigate]);

  const addFriend = async () => {
    if (!user) return;
    setBusy("friend");
    setActionMsg(null);
    try {
      await createFriendRequest({ to_user_id: user.id });
      setUser({ ...user, relation: "pending_sent" });
      setActionMsg("好友申请已发送");
    } catch (e) {
      setError(e instanceof Error ? e.message : "发起申请失败");
    } finally {
      setBusy(null);
    }
  };

  const sendMessage = async () => {
    if (!user) return;
    setBusy("chat");
    setActionMsg(null);
    try {
      const conv = await openPrivateConversation(user.id);
      navigate(`/chat/${conv.id}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : "进入私聊失败");
    } finally {
      setBusy(null);
    }
  };

  return (
    <div className="profile-page">
      <div className="profile-column">
        <div className="glass-card profile-topbar">
          <button
            type="button"
            className="icon-btn-40"
            onClick={() => navigate(-1)}
            aria-label="返回"
          >
            <IconBack width={20} height={20} />
          </button>
          <span className="profile-topbar-title">个人主页</span>
        </div>

        {loading ? (
          <div className="solid-card profile-card">
            <div className="skeleton" style={{ height: 96, marginBottom: 12 }} />
            <div className="skeleton" style={{ height: 12, width: "60%" }} />
          </div>
        ) : error || !user ? (
          <div className="solid-card profile-card">
            <p className="profile-signature">{error ?? "用户不存在"}</p>
            <button type="button" className="btn btn-ghost" onClick={() => navigate(-1)}>
              返回
            </button>
          </div>
        ) : (
          <>
            {actionMsg && <div className="chat-notice" role="status">{actionMsg}</div>}
            {error && <div className="chat-notice" role="alert">{error}</div>}
            <div className="solid-card profile-card">
              <div className="profile-identity">
                <div className="profile-avatar-block">
                  <Avatar
                    label={user.nickname || user.username}
                    size={64}
                    online={online}
                    imageUrl={user.avatar || null}
                  />
                </div>
                <div className="profile-names">
                  <span className="profile-nickname">{user.nickname || user.username}</span>
                  <span className="profile-username">@{user.username}</span>
                </div>
                <span className={`profile-presence ${online ? "is-online" : ""}`}>
                  {displayStatus}
                </span>
              </div>

              {user.signature && (
                <p className="profile-signature-row">{user.signature}</p>
              )}

              {user.relation === "friend" ? (
                <div className="profile-actions">
                  <button
                    type="button"
                    className="btn btn-primary"
                    onClick={() => void sendMessage()}
                    disabled={busy === "chat"}
                  >
                    {busy === "chat" ? "进入中…" : "发消息"}
                  </button>
                </div>
              ) : user.relation === "pending_sent" ? (
                <div className="profile-actions">
                  <button type="button" className="btn btn-ghost" disabled>
                    申请已发送
                  </button>
                </div>
              ) : user.relation === "pending_received" ? (
                <div className="profile-actions">
                  <p className="profile-signature-row">
                    对方已向你发送好友申请，可在消息中心处理
                  </p>
                  <button type="button" className="btn btn-ghost" onClick={() => navigate("/messages")}>
                    去处理
                  </button>
                </div>
              ) : (
                <div className="profile-actions">
                  <button
                    type="button"
                    className="btn btn-primary"
                    onClick={() => void addFriend()}
                    disabled={busy === "friend"}
                  >
                    {busy === "friend" ? "发送中…" : "添加好友"}
                  </button>
                  <button
                    type="button"
                    className="btn btn-ghost"
                    onClick={() => void sendMessage()}
                    disabled={busy === "chat"}
                  >
                    {busy === "chat" ? "进入中…" : "发消息"}
                  </button>
                </div>
              )}
            </div>

            {/* 他的内容：对方开启「向他人展示内容」才显示；收藏永不对外展示 */}
            {user.show_content && (
              <div className="solid-card profile-mine">
                <div className="profile-mine-head">
                  <h4 className="profile-mine-title">他的内容</h4>
                </div>
                {theirContentError && (
                  <div className="chat-notice" role="alert">{theirContentError}</div>
                )}

                <section className="profile-section">
                  <div className="profile-section-head">
                    <button type="button" className="profile-section-toggle" onClick={() => toggleSection("posts")} aria-expanded={sectionsOpen.posts}>
                      <span className="profile-section-title">他的发帖</span>
                      <span className="profile-section-count">{theirPosts.length}</span>
                      <span className={`profile-section-chevron ${sectionsOpen.posts ? "is-open" : ""}`}>▸</span>
                    </button>
                  </div>
                  {sectionsOpen.posts && (
                    theirPosts.length === 0 ? (
                      <p className="profile-section-empty">暂无发帖</p>
                    ) : (
                      theirPosts.map((p) => (
                        <Link key={p.id} to={`/posts/${p.id}`} className="profile-section-row">
                          {p.title || p.body.slice(0, 30)}
                        </Link>
                      ))
                    )
                  )}
                </section>

                <section className="profile-section">
                  <div className="profile-section-head">
                    <button type="button" className="profile-section-toggle" onClick={() => toggleSection("lives")} aria-expanded={sectionsOpen.lives}>
                      <span className="profile-section-title">他的直播间</span>
                      <span className="profile-section-count">{theirLives.length}</span>
                      <span className={`profile-section-chevron ${sectionsOpen.lives ? "is-open" : ""}`}>▸</span>
                    </button>
                  </div>
                  {sectionsOpen.lives && (
                    theirLives.length === 0 ? (
                      <p className="profile-section-empty">暂无直播间</p>
                    ) : (
                      theirLives.map((l) => (
                        <Link key={l.id} to={`/live/${l.id}`} className="profile-section-row">
                          {l.title}
                        </Link>
                      ))
                    )
                  )}
                </section>

                <section className="profile-section">
                  <div className="profile-section-head">
                    <button type="button" className="profile-section-toggle" onClick={() => toggleSection("games")} aria-expanded={sectionsOpen.games}>
                      <span className="profile-section-title">他的桌游</span>
                      <span className="profile-section-count">{theirGames.length}</span>
                      <span className={`profile-section-chevron ${sectionsOpen.games ? "is-open" : ""}`}>▸</span>
                    </button>
                  </div>
                  {sectionsOpen.games && (
                    theirGames.length === 0 ? (
                      <p className="profile-section-empty">暂无桌游</p>
                    ) : (
                      theirGames.map((g) => (
                        <Link key={g.id} to="/games" className="profile-section-row">
                          {g.name}
                        </Link>
                      ))
                    )
                  )}
                </section>
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
}