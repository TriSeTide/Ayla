import { useCallback, useState } from "react";
import { Link } from "react-router-dom";
import { listGameRoomsPage } from "../api/boardgame";
import { listLiveChannelsPage } from "../api/live";
import { listPosts } from "../api/posts";
import { usePagedMediaList } from "../hooks/usePagedMediaList";
import { useAuthStore } from "../stores/auth";
import { DirectoryLoadMore } from "./DirectoryLoadMore";

interface ProfileSectionProps {
  title: string;
  emptyText: string;
  list: {
    items: { id: string | number }[];
    total: number;
    loading: boolean;
    loaded: boolean;
    error: string | null;
    hasMore: boolean;
    loadMore: () => Promise<void>;
    refresh: () => Promise<void>;
  };
  children: React.ReactNode;
}

function ProfileSection({ title, emptyText, list, children }: ProfileSectionProps) {
  const [open, setOpen] = useState(false);
  return <section className="profile-section" aria-label={title}>
    <div className="profile-section-head">
      <button type="button" className="profile-section-toggle" onClick={() => setOpen((value) => !value)} aria-expanded={open}>
        <span className="profile-section-title">{title}</span>
        <span className="profile-section-count">{list.loaded ? list.total >= 0 ? list.total : `已载入 ${list.items.length}` : "—"}</span>
        <span className={`profile-section-chevron ${open ? "is-open" : ""}`}>▸</span>
      </button>
    </div>
    {open && <>
      {list.loaded && !list.error && !list.items.length && <p className="profile-section-empty">{emptyText}</p>}
      {children}
      <DirectoryLoadMore {...list} invalidated={false} retainCompletedSpace={false} />
    </>}
  </section>;
}

/** Each content type pages independently after server owner/visibility filtering. */
export function ProfileContentSections({ ownerId, mine = false }: { ownerId: string; mine?: boolean }) {
  const viewerId = useAuthStore((state) => state.currentUser?.id ?? "");
  const key = `profile:${viewerId}:${ownerId}:${mine ? "mine" : "other"}`;
  const getPosts = useCallback(async (cursor: string | null) => {
    const page = await listPosts({ ...(mine ? { scope: "mine" as const } : { owner: ownerId }), limit: 20, cursor });
    return { ...page, total: page.total ?? -1 };
  }, [mine, ownerId]);
  const getLives = useCallback((cursor: string | null) => listLiveChannelsPage({ owner: ownerId, limit: 20, cursor }), [ownerId]);
  const getGames = useCallback((cursor: string | null) => listGameRoomsPage({ ...(mine ? { mine: true } : { owner: ownerId }), limit: 20, cursor }), [mine, ownerId]);
  const posts = usePagedMediaList(`${key}:posts`, getPosts);
  const lives = usePagedMediaList(`${key}:lives`, getLives);
  const games = usePagedMediaList(`${key}:games`, getGames);

  return <div className="solid-card profile-mine">
    <div className="profile-mine-head">
      <h4 className="profile-mine-title">{mine ? "我的内容" : "他的内容"}</h4>
      {mine && <Link to="/favorites" className="profile-favorites-link">我的收藏 →</Link>}
    </div>
    <ProfileSection title={mine ? "我的发帖" : "他的发帖"} emptyText={mine ? "还没有发帖" : "暂无发帖"} list={posts}>
      {posts.items.map((post) => <Link key={post.id} to={`/posts/${post.id}`} className="profile-section-row">{post.title || post.body.slice(0, 30)}</Link>)}
    </ProfileSection>
    <ProfileSection title={mine ? "我的直播间" : "他的直播间"} emptyText={mine ? "还没有直播间" : "暂无直播间"} list={lives}>
      {lives.items.map((channel) => <Link key={channel.id} to={`/live/${channel.id}`} className="profile-section-row">{channel.title}</Link>)}
    </ProfileSection>
    <ProfileSection title={mine ? "正在玩的桌游" : "他的桌游"} emptyText={mine ? "暂无在局桌游" : "暂无桌游"} list={games}>
      {games.items.map((room) => <Link key={room.id} to="/games" className="profile-section-row">{room.name}</Link>)}
    </ProfileSection>
  </div>;
}
