/**
 * FavoritesPage —— 收藏页（路由 /favorites，F10，R-U3）。
 *
 * 本期展示帖子收藏列表（target 摘要直接展示，不额外拉帖子详情）+ 取消收藏即时生效。
 * 直播间/语音房/桌游室/群收藏类型后端预留，界面占位（R-U3）。
 */
import { useCallback, useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import * as favoritesApi from "../api/favorites";
import type { Favorite } from "../api/types";
import { NarrowTopBar } from "../layout/NarrowTopBar";
import { NARROW_QUERY, useMediaQuery } from "../hooks/useMediaQuery";
import { usePostsStore } from "../stores/posts";

export function FavoritesPage() {
  const isNarrow = useMediaQuery(NARROW_QUERY);
  const navigate = useNavigate();
  const [favorites, setFavorites] = useState<Favorite[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);

  const load = useCallback(() => {
    setLoading(true);
    setError(null);
    favoritesApi
      .listFavorites("post")
      .then((list) => {
        setFavorites(list);
        // 同步收藏集合到 posts store（取消收藏后存储一致）
        usePostsStore.getState().loadFavorites(list);
      })
      .catch((e) => setError(e instanceof Error ? e.message : "加载失败"))
      .finally(() => setLoading(false));
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const remove = useCallback((fav: Favorite) => {
    setActionError(null);
    favoritesApi
      .removeFavorite(fav.id)
      .then(() => {
        setFavorites((prev) => prev.filter((f) => f.id !== fav.id));
        usePostsStore.getState().setFavorite(fav.target_id, null);
      })
      .catch((e) => setActionError(e instanceof Error ? e.message : "取消收藏失败，请重试"));
  }, []);

  return (
    <div className="favorites-page">
      {isNarrow && <NarrowTopBar />}
      <h2 className="favorites-title">我的收藏</h2>
      {actionError && <div className="chat-notice" role="alert">{actionError}</div>}
      {loading ? (
        <div className="favorites-skeleton">
          <div className="skeleton" style={{ height: 64, marginBottom: 8 }} />
          <div className="skeleton" style={{ height: 64 }} />
        </div>
      ) : error ? (
        <div className="home-state" role="alert">
          <p className="placeholder-desc">{error}</p>
          <button type="button" className="btn btn-ghost" onClick={load}>
            重试
          </button>
        </div>
      ) : favorites.length === 0 ? (
        <div className="home-state">
          <h3 className="placeholder-title">还没有收藏的帖子</h3>
          <p className="placeholder-desc">在帖子里点收藏，会出现在这里</p>
        </div>
      ) : (
        <div className="favorites-list">
          {favorites.map((f) => {
            const t = f.target as { title?: string; body?: string } | null;
            return (
              <div key={f.id} className="favorite-item">
                <button
                  type="button"
                  className="favorite-item-main"
                  onClick={() => navigate(`/posts/${f.target_id}`)}
                >
                  <span className="favorite-item-title">{t?.title || t?.body || "帖子"}</span>
                  {t?.body && t.body !== t.title && <span className="favorite-item-body">{t.body}</span>}
                </button>
                <button type="button" className="msg-action-btn" onClick={() => remove(f)}>
                  取消收藏
                </button>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
