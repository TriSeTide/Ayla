/**
 * 帖子 REST 封装（F6，对齐 backend/apps/posts/views.py + urls.py）。
 *
 * - GET /posts/?scope=feed|group:<id>|mine&cursor=&limit= → {results, next_cursor, has_more}
 *   游标分页（created_at+id 降序，cursor 由后端编解码）；
 * - POST /posts/ 发帖（body 必填；images ≤9 张 media_id；group 可选归属群）；
 * - GET/PATCH/DELETE /posts/<id>/；GET/POST /posts/<id>/comments/（reply_to 须在本帖）；
 * - DELETE /comments/<id>/。
 */
import { apiRequest } from "./client";
import type { Post, PostComment, PostListPage, PostScope } from "./types";

/** GET /posts/ —— 信息流游标分页 */
export function listPosts(params: {
  scope?: PostScope;
  cursor?: string | null;
  limit?: number;
} = {}) {
  const qs = new URLSearchParams();
  if (params.scope && params.scope !== "feed") qs.set("scope", params.scope);
  if (params.cursor) qs.set("cursor", params.cursor);
  if (params.limit != null) qs.set("limit", String(params.limit));
  const suffix = qs.toString() ? `?${qs.toString()}` : "";
  return apiRequest<PostListPage>(`/posts/${suffix}`);
}

/** POST /posts/ —— 发帖（group 归属群；images 为 media_id 列表） */
export function createPost(payload: {
  title?: string;
  body: string;
  group?: string | null;
  visibility?: "public" | "friends" | "group";
  images?: string[];
}) {
  return apiRequest<Post>("/posts/", { method: "POST", body: payload });
}

/** GET /posts/<id>/ —— 详情 */
export function getPost(postId: number) {
  return apiRequest<Post>(`/posts/${postId}/`);
}

/** PATCH /posts/<id>/ —— 编辑（仅作者） */
export function updatePost(postId: number, payload: { title?: string; body?: string }) {
  return apiRequest<Post>(`/posts/${postId}/`, { method: "PATCH", body: payload });
}

/** DELETE /posts/<id>/ —— 删除（仅作者） */
export function deletePost(postId: number) {
  return apiRequest<{ deleted: boolean }>(`/posts/${postId}/`, { method: "DELETE" });
}

/** GET /posts/<id>/comments/ —— 评论列表（按 created_at 升序） */
export function listComments(postId: number) {
  return apiRequest<PostComment[]>(`/posts/${postId}/comments/`);
}

/** POST /posts/<id>/comments/ —— 发评论（reply_to 可选须在本帖；media_id 可选图片评论） */
export function createComment(
  postId: number,
  payload: { body: string; reply_to?: number | null; media_id?: string | null },
) {
  return apiRequest<PostComment>(`/posts/${postId}/comments/`, {
    method: "POST",
    body: payload,
  });
}

/** DELETE /posts/comments/<id>/ —— 删评论（仅评论作者） */
export function deleteComment(commentId: number) {
  return apiRequest<{ deleted: boolean }>(`/posts/comments/${commentId}/`, {
    method: "DELETE",
  });
}
