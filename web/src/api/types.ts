/**
 * 与 Ayla/backend 序列化器对齐的 TS 类型。
 * 契约来源：backend/apps/accounts/serializers.py（UserPublicSerializer / RegisterSerializer / ProfileSerializer）
 * 注意：user.id 为字符串（UUID），与后端 CharField 对齐。
 */

/** UserPublicSerializer 字段 */
export interface UserPublic {
  id: string;
  username: string;
  nickname: string;
  avatar: string;
  signature: string;
  /** User.status：online / away / dnd / invisible */
  status: string;
  /** 实时在线（Redis presence，隐身对外视为离线） */
  online: boolean;
  /** ISO 时间字符串 */
  date_joined: string;
}

/** 注册入参（RegisterSerializer） */
export interface RegisterPayload {
  username: string;
  email: string;
  password: string;
  nickname?: string;
}

/** 登录入参（SimpleJWT TokenObtainPairView） */
export interface LoginPayload {
  username: string;
  password: string;
}

/** 令牌对 */
export interface TokenPair {
  access: string;
  refresh: string;
}

/** POST /auth/register/ 返回 */
export interface RegisterResult {
  user: UserPublic;
  access: string;
  refresh: string;
}

/** POST /auth/login/ 返回（ROTATE_REFRESH_TOKENS=True 时 refresh 也会返回） */
export interface LoginResult {
  access: string;
  refresh: string;
}

/** POST /auth/refresh/ 返回：旋转开启时同时返回新 refresh */
export interface RefreshResult {
  access: string;
  refresh?: string;
}

/** 个人资料修改（ProfileSerializer 字段） */
export interface ProfileUpdatePayload {
  nickname?: string;
  avatar?: string;
  signature?: string;
  status?: string;
}

/** 好友关系（FriendshipSerializer） */
export interface Friendship {
  id: number;
  user: UserPublic;
  created_at: string;
}

/** 好友申请（FriendRequestSerializer） */
export interface FriendRequest {
  id: number;
  from_user: UserPublic;
  to_user: UserPublic;
  message: string;
  status: "pending" | "accepted" | "rejected";
  created_at: string;
}

/** 发起好友申请入参 */
export interface FriendRequestPayload {
  to_user_id: string;
  message?: string;
}

/** 后端 DRF 错误结构：{detail} 或 {field: [msg]} 或 {field: msg} */
export type ApiErrorBody = Record<string, unknown>;
