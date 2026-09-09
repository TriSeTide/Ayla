/**
 * UserPostsRoute —— 他人帖子界面路由守卫（/user/:userId/posts）。
 *
 * 路由守卫：对方必须开启「向他人展示内容」（show_content）才能查看其帖子界面；
 * 未开启 → 显示提示页（不渲染帖子内容），避免绕过个人主页直接访问。
 * 通过 → 渲染 MyPostsPage（owner 模式）。
 */
import { useEffect, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { getUserDetail } from "../api/users";
import { useAuthStore } from "../stores/auth";
import { MyPostsPage } from "./MyPostsPage";

type GuardState = "loading" | "ok" | "blocked";

/** /posts/mine —— 我的帖子：ownerId 取当前登录用户（ProtectedRoute 已保证登录）。 */
export function MinePostsRoute() {
  const currentUserId = useAuthStore((state) => state.currentUser?.id ?? null);
  if (!currentUserId) return null;
  return <MyPostsPage ownerId={currentUserId} />;
}

export function UserPostsRoute() {
  const { userId } = useParams<{ userId: string }>();
  const navigate = useNavigate();
  const [state, setState] = useState<GuardState>("loading");

  useEffect(() => {
    if (!userId) {
      navigate("/", { replace: true });
      return;
    }
    let cancelled = false;
    setState("loading");
    getUserDetail(userId)
      .then((u) => {
        if (cancelled) return;
        setState(u.show_content ? "ok" : "blocked");
      })
      .catch(() => {
        if (!cancelled) setState("blocked");
      });
    return () => { cancelled = true; };
  }, [userId, navigate]);

  if (state === "loading") {
    return (
      <div className="posts-hub my-posts-page">
        <div className="posts-skeleton">
          <div className="skeleton" style={{ height: 120 }} />
          <div className="skeleton" style={{ height: 120 }} />
        </div>
      </div>
    );
  }

  if (state === "blocked") {
    return (
      <div className="posts-hub my-posts-page">
        <div className="home-state" role="alert">
          <h2 className="placeholder-title">对方未开启内容展示</h2>
          <p className="placeholder-desc">对方关闭了「向他人展示内容」，暂时无法查看其帖子</p>
          <button type="button" className="btn btn-ghost" onClick={() => navigate(`/user/${encodeURIComponent(userId ?? "")}`, { replace: true })}>
            返回主页
          </button>
        </div>
      </div>
    );
  }

  return <MyPostsPage ownerId={userId!} />;
}
