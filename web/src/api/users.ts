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
