import { useCallback, useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import * as favoritesApi from "../api/favorites";
import type { Favorite, FavoriteTargetType } from "../api/types";
import { IconBack } from "../components/icons";
import { FullScreenSwipeBack } from "../components/motion/FullScreenSwipeBack";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { usePostsStore } from "../stores/posts";
import { chatWS } from "../ws/chat";

const FILTERS: Array<{ key: FavoriteTargetType | "all"; label: string }> = [
  { key: "all", label: "全部" },
  { key: "message", label: "消息" },
  { key: "post", label: "帖子" },
  { key: "live", label: "直播" },
  { key: "voice", label: "语音房" },
  { key: "game", label: "桌游房" },
  { key: "group", label: "群" },
];

const TYPE_LABEL: Record<FavoriteTargetType, string> = {
  message: "消息",
  post: "帖子",
  live: "直播间",
  voice: "语音房",
  game: "桌游房",
  group: "群",
};

type FavoriteTarget = {
  title?: string;
  body?: string;
  name?: string;
  content?: string;
  conversation_id?: string;
};

function targetText(favorite: Favorite): string {
  const target = favorite.target as FavoriteTarget | null;
  return target?.title || target?.name || target?.content || target?.body || TYPE_LABEL[favorite.target_type];
}

function openTarget(navigate: ReturnType<typeof useNavigate>, favorite: Favorite) {
  const target = favorite.target as FavoriteTarget | null;
  switch (favorite.target_type) {
    case "post":
      navigate(`/posts/${favorite.target_id}`);
      break;
    case "live":
      navigate(`/live/${favorite.target_id}`);
      break;
    case "voice":
      // 直达具体语音房（/voice/:channelId 路由已存在，VoiceHubPage 支持直达进房）
      navigate(`/voice/${favorite.target_id}`);
      break;
    case "game":
      // 直达具体桌游房（/games/:roomId 路由，GamesHubPage 自动 join 进房）
      navigate(`/games/${favorite.target_id}`);
      break;
    case "message":
      if (target?.conversation_id) navigate(`/chat/${target.conversation_id}`);
      break;
    case "group":
      navigate(`/group/${favorite.target_id}`);
      break;
  }
}

export function FavoritesPage() {
  const navigate = useNavigate();
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const [filter, setFilter] = useState<FavoriteTargetType | "all">("all");
  const [favorites, setFavorites] = useState<Favorite[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);

  const load = useCallback(() => {
    setLoading(true);
    setError(null);
    const request = filter === "all" ? favoritesApi.listFavorites() : favoritesApi.listFavorites(filter);
    request
      .then((list) => {
        setFavorites(list);
        if (filter === "post" || filter === "all") usePostsStore.getState().loadFavorites(list.filter((item) => item.target_type === "post"));
      })
      .catch((e) => setError(e instanceof Error ? e.message : "加载收藏失败"))
      .finally(() => setLoading(false));
  }, [filter]);

  useEffect(() => {
    load();
  }, [load]);

  // WS 热更新（任务 07）：收藏/取消收藏后收藏页实时同步。
  // removed → 本地移除该条（favorite_id 即被删收藏 id）；added → 重新拉权威列表
  // （含 target 摘要；帖子收藏态由 chatWS dispatch 统一更新 posts store）。
  useEffect(() => {
    return chatWS.onFrame((frame) => {
      if (frame.type !== "favorite.changed") return;
      const d = frame.data;
      if (d.action === "removed") {
        setFavorites((prev) => prev.filter((item) => item.id !== d.favorite_id));
      } else {
        load();
      }
    });
  }, [load]);

  const remove = useCallback((favorite: Favorite) => {
    setActionError(null);
    favoritesApi
      .removeFavorite(favorite.id)
      .then(() => {
        setFavorites((prev) => prev.filter((item) => item.id !== favorite.id));
        if (favorite.target_type === "post") usePostsStore.getState().setFavorite(favorite.target_id, null);
      })
      .catch((e) => setActionError(e instanceof Error ? e.message : "取消收藏失败，请重试"));
  }, []);

  return (
    <FullScreenSwipeBack onBack={() => navigate(-1)} enabled={isNarrow}>
      <div className="favorites-page">
      <div className="favorites-topbar">
        <button type="button" className="icon-btn-40" onClick={() => navigate(-1)} aria-label="返回">
          <IconBack width={20} height={20} />
        </button>
        <h2 className="favorites-title">我的收藏</h2>
      </div>
      <div className="favorites-filters" role="tablist" aria-label="收藏分类">
        {FILTERS.map((item) => (
          <button
            key={item.key}
            type="button"
            role="tab"
            aria-selected={filter === item.key}
            className={`favorites-filter ${filter === item.key ? "is-active" : ""}`}
            onClick={() => setFilter(item.key)}
          >
            {item.label}
          </button>
        ))}
      </div>
      {actionError && <div className="chat-notice" role="alert">{actionError}</div>}
      {loading ? (
        <div className="favorites-skeleton">
          <div className="skeleton" style={{ height: 64, marginBottom: 8 }} />
          <div className="skeleton" style={{ height: 64 }} />
        </div>
      ) : error ? (
        <div className="home-state" role="alert">
          <p className="placeholder-desc">{error}</p>
          <button type="button" className="btn btn-ghost" onClick={load}>重试</button>
        </div>
      ) : favorites.length === 0 ? (
        <div className="home-state">
          <h3 className="placeholder-title">这个分类还没有收藏</h3>
          <p className="placeholder-desc">在对应场景点收藏，内容会出现在这里</p>
        </div>
      ) : (
        <div className="favorites-list">
          {favorites.map((favorite) => (
            <div key={favorite.id} className="favorite-item">
              <button type="button" className="favorite-item-main" onClick={() => openTarget(navigate, favorite)}>
                <span className="favorite-item-type">{TYPE_LABEL[favorite.target_type]}</span>
                <span className="favorite-item-title">{targetText(favorite)}</span>
                {favorite.target_type === "post" && (favorite.target as FavoriteTarget | null)?.body && (
                  <span className="favorite-item-body">{(favorite.target as FavoriteTarget).body}</span>
                )}
              </button>
              <button type="button" className="msg-action-btn" onClick={() => remove(favorite)}>取消收藏</button>
            </div>
          ))}
        </div>
      )}
      </div>
    </FullScreenSwipeBack>
  );
}
