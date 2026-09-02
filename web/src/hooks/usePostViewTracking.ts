/**
 * usePostViewTracking —— 帖子视口浏览上报（浏览与已读同源）。
 *
 * 观察滚动容器内所有 `[data-post-id]` 元素：**进入视口即视为浏览**（无需点击），
 * 去抖批量上报 `POST /posts/views/`（后端幂等去重，每人每帖最多 1 次，作者不计）。
 *
 * 上报成功后：
 * - posts store 标记该帖 is_viewed=true 并更新 view_count；
 * - onViewed 回调同步调用方本地副本（如 GroupPosts 的 groupPosts state）。
 *
 * 群未读红点递减不由本 hook 负责：后端广播 `post.viewed`（本人频道）后由
 * ws/chat.ts 统一递减——避免 REST 响应与 WS 事件同一条浏览被减多次导致红点跳动
 * （Bug：批量浏览时左侧栏红点疯狂跳变）。
 *
 * 用法：给每个帖子卡片容器加 `data-post-id={post.id}`，把滚动容器 ref 传入。
 */
import { useEffect, type RefObject } from "react";
import * as postsApi from "../api/posts";
import { usePostsStore } from "../stores/posts";

/** 进入视口后批量上报的合并窗口（ms） */
const FLUSH_DELAY_MS = 300;

export function usePostViewTracking(
  containerRef: RefObject<HTMLElement | null>,
  onViewed?: (updated: Record<string, number>) => void,
) {
  useEffect(() => {
    const root = containerRef.current;
    if (!root || typeof IntersectionObserver === "undefined") return;

    const pending = new Set<number>();
    let timer: ReturnType<typeof setTimeout> | null = null;

    const flush = () => {
      if (timer != null) {
        clearTimeout(timer);
        timer = null;
      }
      if (pending.size === 0) return;
      const ids = [...pending];
      pending.clear();
      postsApi
        .reportPostViews(ids)
        .then(({ updated }) => {
          if (Object.keys(updated).length === 0) return;
          // 本地已读态/浏览量落地；红点递减由后端 post.viewed WS 事件统一负责
          usePostsStore.getState().markViewedBatch(updated);
          onViewed?.(updated);
        })
        .catch(() => {
          // 上报失败保持原态（不伪造已读），下次进入视口会再次触发
        });
    };

    const schedule = () => {
      if (timer == null) timer = setTimeout(flush, FLUSH_DELAY_MS);
    };

    const io = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          const id = Number((entry.target as HTMLElement).dataset.postId);
          if (Number.isInteger(id) && id > 0) pending.add(id);
        }
        schedule();
      },
      // 进入视口即算浏览（rootMargin 底部留 5% 缓冲，避免贴边误报）
      { root, rootMargin: "0px 0px -5% 0px" },
    );

    const observeAll = () => {
      root
        .querySelectorAll<HTMLElement>("[data-post-id]")
        .forEach((el) => io.observe(el));
    };
    observeAll();
    // 分页/刷新动态插入的卡片：MutationObserver 补观察
    const mo = new MutationObserver(observeAll);
    mo.observe(root, { childList: true, subtree: true });

    return () => {
      io.disconnect();
      mo.disconnect();
      if (timer != null) clearTimeout(timer);
    };
  }, [containerRef, onViewed]);
}
