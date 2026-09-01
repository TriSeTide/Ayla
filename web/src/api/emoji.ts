/**
 * 表情包 REST API：与 backend/apps/emoji/views.py 真实契约对齐。
 * 路径挂 /api/v1/emoji/（client.ts 已加 /api/v1 前缀）。
 *
 * 任务 03（群内表情包）：
 * - GET    /emoji/groups/<conv_id>/pack/            群表情包（群成员可见；未创建 404）
 * - PATCH  /emoji/groups/<conv_id>/pack/            群主设置 allow_member_upload 开关
 * - POST   /emoji/groups/<conv_id>/pack/items/      添加群表情 {media_id, tag?}
 * - DELETE /emoji/groups/<conv_id>/pack/items/<id>/  删除群表情（群主/管理员）
 */
import { apiRequest } from "./client";
import type { EmojiItem, EmojiPack } from "./types";

/** 群表情包响应：pack + 权限信息 */
export interface GroupEmojiPackPayload {
  pack: EmojiPack;
  /** 群主设置的"允许普通群成员上传"开关 */
  allow_member_upload: boolean;
  /** 当前用户是否可上传（群主/管理员，或开关开启后的普通成员） */
  can_upload: boolean;
  /** 当前用户是否可删除（群主/管理员） */
  can_delete: boolean;
}

function seg(convId: string): string {
  return encodeURIComponent(convId);
}

/** GET 群表情包；包未创建时后端返回 404（调用方按空态处理） */
export function getGroupEmojiPack(convId: string) {
  return apiRequest<GroupEmojiPackPayload>(`/emoji/groups/${seg(convId)}/pack/`);
}

/** PATCH 群主设置"允许普通群成员上传"开关 */
export function setGroupEmojiUploadPolicy(convId: string, allowMemberUpload: boolean) {
  return apiRequest<GroupEmojiPackPayload>(`/emoji/groups/${seg(convId)}/pack/`, {
    method: "PATCH",
    body: { allow_member_upload: allowMemberUpload },
  });
}

/** POST 添加群表情（media 需已按 kind=emoji 上传） */
export function addGroupEmojiItem(convId: string, mediaId: string, tag = "") {
  return apiRequest<EmojiItem>(`/emoji/groups/${seg(convId)}/pack/items/`, {
    method: "POST",
    body: { media_id: mediaId, tag },
  });
}

/** DELETE 删除群表情（群主/管理员） */
export function deleteGroupEmojiItem(convId: string, itemId: string) {
  return apiRequest<void>(`/emoji/groups/${seg(convId)}/pack/items/${encodeURIComponent(itemId)}/`, {
    method: "DELETE",
  });
}
