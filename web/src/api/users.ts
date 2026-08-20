/**
 * 用户 / 好友 API 骨架。
 * M5-1 只留数据契约；界面在 M5-2 起实现。
 */
import { apiRequest } from "./client";
import type { FriendRequest, FriendRequestPayload, Friendship, UserPublic } from "./types";

/** GET /users/search/?q= */
export function searchUsers(q: string) {
  return apiRequest<UserPublic[]>(`/users/search/?q=${encodeURIComponent(q)}`);
}

/** GET /users/<id>/ —— 他人主页：公开资料 + 与我的好友关系（relation 字段） */
export function getUserDetail(userId: string) {
  return apiRequest<UserPublic>(`/users/${encodeURIComponent(userId)}/`);
}

/* ---------- 用户资料懒拉缓存（M5-3：语音成员昵称/头像不在 voice store 复制数据源） ----------
 * 优先走 GET /users/<id>/（精确 id，含头像/在线状态/好友关系）；
 * 该接口不可用或 404 时回退 users/search 按 username/nickname 模糊匹配。 */

const userCache = new Map<string, UserPublic>();
const pending = new Map<string, Promise<UserPublic | null>>();

/** 已缓存则同步返回（渲染层无闪烁用） */
export function getCachedUser(userId: string): UserPublic | null {
  return userCache.get(userId) ?? null;
}

/** 把已有 UserPublic 写入缓存（来自会话成员等已有数据源，避免重复请求） */
export function cacheUser(user: UserPublic): void {
  userCache.set(user.id, user);
}

/**
 * 按 user_id 懒拉公开资料并缓存；失败/未命中返回 null（不抛错，渲染层回退为首字符）。
 * 并发去重：同一 user_id 只发一次请求。
 */
export function ensureUser(userId: string): Promise<UserPublic | null> {
  const cached = userCache.get(userId);
  if (cached) return Promise.resolve(cached);
  const inFlight = pending.get(userId);
  if (inFlight) return inFlight;
  // 精确 id 拉取（有头像/在线状态）；失败回退模糊搜索
  const p = getUserDetail(userId)
    .then((u) => {
      userCache.set(userId, u);
      return u;
    })
    .catch(() =>
      searchUsers(userId).then((list) => {
        const hit = list.find((u) => u.id === userId) ?? null;
        if (hit) userCache.set(userId, hit);
        return hit;
      }),
    )
    .catch(() => null)
    .finally(() => {
      pending.delete(userId);
    });
  pending.set(userId, p);
  return p;
}

/** 批量懒拉（成员对账后预热） */
export function ensureUsers(userIds: string[]): void {
  for (const id of userIds) void ensureUser(id);
}

/** 测试用：清空缓存 */
export function _clearUserCache(): void {
  userCache.clear();
  pending.clear();
}

/** GET /friends/ */
export function listFriends() {
  return apiRequest<Friendship[]>("/friends/");
}

/** GET /friends/requests/ */
export function listFriendRequests() {
  return apiRequest<FriendRequest[]>("/friends/requests/");
}

/** POST /friends/requests/ */
export function createFriendRequest(payload: FriendRequestPayload) {
  return apiRequest<FriendRequest>("/friends/requests/", {
    method: "POST",
    body: payload,
  });
}

/** POST /friends/requests/<id>/action/ */
export function actionFriendRequest(
  requestId: number,
  action: "accept" | "reject",
) {
  return apiRequest<{ detail: string; status: string }>(
    `/friends/requests/${requestId}/action/`,
    { method: "POST", body: { action } },
  );
}

/** DELETE /friends/<user_id>/ */
export function deleteFriend(userId: string) {
  return apiRequest<void>(`/friends/${encodeURIComponent(userId)}/`, {
    method: "DELETE",
  });
}
