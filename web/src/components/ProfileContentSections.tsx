/**
 * ProfileContentSections —— 个人主页右侧内容卡片（重构版）。
 *
 * 按固定顺序展示完整卡片（不再折叠）：
 * 1. 正在直播的直播间（最多 1 个）：owner.is_live + live_room_id → 频道详情；
 * 2. 正在语音的语音房（最多 1 个）：owner.is_in_voice + voice_room_id → 频道详情；
 * 3. 帖子（最多 3 条）+「更多帖子」按钮 → 该用户的帖子界面；
 * 4. 正在玩的桌游（占位，玩法未实现）。
 *
 * 材料纪律（design.md §4）：外层 wrapper 透明，每类内容一张独立玻璃卡，
 * 不叠卡片（避免实心底 + 玻璃行叠出不透明）。
 *
 * 数据来源：
 * - mine：owner 为 auth store 的 currentUser（is_live/is_in_voice 由 WS 实时更新）；
 * - other：owner 为 getUserDetail 结果（父组件已按 show_content 守卫）。
 * 直播/语音详情走 can_view 过滤，不可见（403）时静默不展示。
 */
import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { getLiveChannel } from "../api/live";
import { listPosts } from "../api/posts";
import { getVoiceChannel } from "../api/voice";
import type { LiveChannelDescriptor, Post, UserPublic, VoiceChannelDescriptor } from "../api/types";
import { IconGame, IconMic, IconPost, IconVideo } from "./icons";
import { ResourceImage } from "./ResourceImage";

function formatTime(iso: string): string {
  try {
    const d = new Date(iso);
    if (!Number.isFinite(d.getTime())) return "";
    const now = new Date();
    const diff = now.getTime() - d.getTime();
    if (diff < 60_000) return "刚刚";
    if (diff < 3600_000) return `${Math.floor(diff / 60_000)} 分钟前`;
    if (diff < 86400_000) return `${Math.floor(diff / 3600_000)} 小时前`;
    return d.toLocaleDateString("zh-CN");
  } catch {
    return "";
  }
}

/** 内容卡统一外壳：玻璃卡 + 标题头（图标 + 标题 + 尾部徽标/动作）。 */
function ContentCard({ icon, title, badge, children }: {
  icon: React.ReactNode;
  title: string;
  badge?: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <section className="profile-content-card" aria-label={title}>
      <div className="profile-content-head">
        <span className="profile-content-title">
          {icon}
          {title}
        </span>
        {badge}
      </div>
      {children}
    </section>
  );
}

export function ProfileContentSections({ owner, mine = false }: { owner: UserPublic; mine?: boolean }) {
  const [liveChannel, setLiveChannel] = useState<LiveChannelDescriptor | null>(null);
  const [voiceChannel, setVoiceChannel] = useState<VoiceChannelDescriptor | null>(null);
  const [posts, setPosts] = useState<Post[]>([]);
  const [postsLoading, setPostsLoading] = useState(true);
  const [postsError, setPostsError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    // 正在直播（最多 1 个）：详情走 can_view，不可见（403）→ 不展示
    if (owner.is_live && owner.live_room_id != null) {
      getLiveChannel(owner.live_room_id)
        .then((ch) => { if (!cancelled) setLiveChannel(ch); })
        .catch(() => { if (!cancelled) setLiveChannel(null); });
    } else {
      setLiveChannel(null);
    }
    // 正在语音（最多 1 个）：同上
    if (owner.is_in_voice && owner.voice_room_id != null) {
      getVoiceChannel(String(owner.voice_room_id))
        .then((ch) => { if (!cancelled) setVoiceChannel(ch); })
        .catch(() => { if (!cancelled) setVoiceChannel(null); });
    } else {
      setVoiceChannel(null);
    }
    // 帖子：mine 走 scope=mine（自己不受 show_content 限制）；他人走 owner 过滤
    setPostsLoading(true);
    setPostsError(null);
    listPosts(mine ? { scope: "mine", limit: 3 } : { owner: owner.id, limit: 3 })
      .then((page) => {
        if (cancelled) return;
        setPosts(page.results);
        setPostsLoading(false);
      })
      .catch((e) => {
        if (cancelled) return;
        setPostsError(e instanceof Error ? e.message : "帖子加载失败");
        setPostsLoading(false);
      });
    return () => { cancelled = true; };
  }, [owner.id, owner.is_live, owner.live_room_id, owner.is_in_voice, owner.voice_room_id, mine]);

  const postsHref = mine ? "/posts/mine" : `/user/${encodeURIComponent(owner.id)}/posts`;
  const displayName = owner.nickname || owner.username;

  return (
    <div className="profile-mine">
      {/* 1+2. 正在直播 / 正在语音：一左一右平均分配宽度 */}
      {(liveChannel || voiceChannel) && (
        <div className="profile-media-row">
          {liveChannel && (
            <ContentCard
              icon={<IconVideo width={16} height={16} aria-hidden="true" />}
              title="正在直播"
              badge={<span className="profile-live-badge">LIVE</span>}
            >
              <Link to={`/live/${liveChannel.id}`} className="profile-content-row">
                {liveChannel.cover ? (
                  <ResourceImage src={liveChannel.cover} alt="" className="profile-live-cover" />
                ) : (
                  <span className="profile-live-cover profile-live-cover-empty" aria-hidden="true">
                    <IconVideo width={20} height={20} />
                  </span>
                )}
                <span className="profile-content-row-main">
                  <span className="profile-content-row-title">{liveChannel.title}</span>
                  <span className="profile-content-row-sub">
                    {liveChannel.owner_nickname || displayName} 正在直播
                  </span>
                </span>
              </Link>
            </ContentCard>
          )}

          {voiceChannel && (
            <ContentCard
              icon={<IconMic width={16} height={16} aria-hidden="true" />}
              title="正在语音"
              badge={voiceChannel.member_count > 0
                ? <span className="profile-voice-count">{voiceChannel.member_count} 人在麦</span>
                : undefined}
            >
              <Link to={`/voice/${voiceChannel.id}`} className="profile-content-row">
                <span className="profile-content-row-icon" aria-hidden="true">
                  <IconMic width={18} height={18} />
                </span>
                <span className="profile-content-row-main">
                  <span className="profile-content-row-title">{voiceChannel.name}</span>
                  <span className="profile-content-row-sub">
                    {voiceChannel.owner_nickname || displayName} 的语音房
                  </span>
                </span>
              </Link>
            </ContentCard>
          )}
        </div>
      )}

      {/* 3. 帖子（最多 3 条）+ 更多帖子按钮 */}
      <ContentCard
        icon={<IconPost width={16} height={16} aria-hidden="true" />}
        title="帖子"
        badge={posts.length > 0 ? <span className="profile-content-count">{posts.length}</span> : undefined}
      >
        {postsLoading ? (
          <div className="profile-posts-skeleton">
            <div className="skeleton" style={{ height: 44 }} />
            <div className="skeleton" style={{ height: 44 }} />
            <div className="skeleton" style={{ height: 44 }} />
          </div>
        ) : postsError ? (
          <p className="profile-content-empty" role="alert">{postsError}</p>
        ) : posts.length === 0 ? (
          <p className="profile-content-empty">{mine ? "还没有发帖" : "暂无帖子"}</p>
        ) : (
          <>
            <div className="profile-posts-list">
              {posts.map((post) => (
                <Link key={post.id} to={`/posts/${post.id}`} className="profile-content-row">
                  <span className="profile-content-row-main">
                    <span className="profile-post-title">{post.title || post.body.slice(0, 40)}</span>
                    <span className="profile-content-row-sub">
                      {post.title ? post.body.slice(0, 40) : ""}
                      {post.created_at ? `${post.title ? " · " : ""}${formatTime(post.created_at)}` : ""}
                    </span>
                  </span>
                </Link>
              ))}
            </div>
            <Link to={postsHref} className="btn btn-ghost profile-more-posts">
              更多帖子
            </Link>
          </>
        )}
      </ContentCard>

      {/* 4. 正在玩的桌游（占位，玩法未实现） */}
      <ContentCard
        icon={<IconGame width={16} height={16} aria-hidden="true" />}
        title="正在玩的桌游"
      >
        <div className="profile-game-placeholder">
          <IconGame width={28} height={28} aria-hidden="true" />
          <span>桌游玩法即将上线</span>
        </div>
      </ContentCard>
    </div>
  );
}
