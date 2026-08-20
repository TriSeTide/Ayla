/**
 * 桌游 REST 封装（F7，对齐 backend/apps/boardgame/views.py + urls.py）。
 *
 * - GET /rooms/（可见性过滤 + 可选 ?mine=1 我在局）/ POST /rooms/（创建）；
 * - GET/DELETE /rooms/<id>/；POST /rooms/<id>:join/（幂等）；POST /rooms/<id>:leave/。
 * 玩法引擎、WS 对局通道非本期目标（进入房间后前端为占位界面）。
 */
import { apiRequest } from "./client";
import type { GameRoom, GameRoomMember } from "./types";

/** GET /rooms/ —— 房间列表（mine=1 仅我在局；?scope=group:<id> 群内过滤；?owner=<id> 他人主页） */
export function listGameRooms(params?: { mine?: boolean; scope?: string; owner?: string }) {
  const queryParts: string[] = [];
  if (params?.mine) queryParts.push("mine=1");
  if (params?.scope) queryParts.push(`scope=${encodeURIComponent(params.scope)}`);
  if (params?.owner) queryParts.push(`owner=${encodeURIComponent(params.owner)}`);
  const qs = queryParts.length > 0 ? `?${queryParts.join("&")}` : "";
  return apiRequest<GameRoom[]>(`/boardgame/rooms/${qs}`);
}

/** POST /rooms/ —— 创建房间（group 归属群；game_type 默认 boardgame） */
export async function createGameRoom(payload: {
  name: string;
  group?: string | null;
  visibility?: "public" | "friends" | "group";
  game_type?: string;
  allowed_group_ids?: string[];
}) {
  const room = await apiRequest<GameRoom>("/boardgame/rooms/", { method: "POST", body: payload });
  // 群桌游页可能仍挂载（创建弹层关闭后导航到同一路由），主动通知其刷新列表。
  if (typeof window !== "undefined") {
    window.dispatchEvent(new CustomEvent("boardgame:room-created", { detail: room }));
  }
  return room;
}

/** GET /rooms/<id>/ —— 详情 */
export function getGameRoom(roomId: number) {
  return apiRequest<GameRoom>(`/boardgame/rooms/${roomId}/`);
}

/** DELETE /rooms/<id>/ —— 删除（仅房主） */
export async function deleteGameRoom(roomId: number) {
  const result = await apiRequest<{ deleted: boolean }>(`/boardgame/rooms/${roomId}/`, {
    method: "DELETE",
  });
  if (typeof window !== "undefined") {
    window.dispatchEvent(new CustomEvent("boardgame:room-deleted", { detail: { roomId } }));
  }
  return result;
}

/** POST /rooms/<id>:join/ —— 加入（幂等） */
export function joinGameRoom(roomId: number) {
  return apiRequest<GameRoomMember>(`/boardgame/rooms/${roomId}:join/`, {
    method: "POST",
  });
}

export function actionGameMember(roomId: number, userId: string, action: "kick" | "transfer") {
  return apiRequest<GameRoom>(`/boardgame/rooms/${roomId}/members/${encodeURIComponent(userId)}/action/`, { method: "POST", body: { action } });
}

/** POST /rooms/<id>:leave/ —— 离开（仅成员，非成员 400） */
export function leaveGameRoom(roomId: number) {
  return apiRequest<{ left: boolean }>(`/boardgame/rooms/${roomId}:leave/`, {
    method: "POST",
  });
}
