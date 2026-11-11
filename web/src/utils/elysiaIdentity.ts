/**
 * 「谁是爱莉」的唯一判定点。
 *
 * 后端用 ElysiaProfile 绑定一个真实 user（apps/elysia_bridge/models.py：
 * enabled=True + user__is_active=True），她在 Ayla 里就是一个普通账号，
 * 有 username、有好友、有私聊会话。
 *
 * ��前判据是 username，理由：
 * - 前端拿不到 ElysiaProfile（那是桥接内部模型，不对外暴露）；
 * - username 是登录标识、全局唯一、不可改（改名只改 nickname）；
 * - 之前的 profile 接口已经删除，这里是唯一还活着的身份来源。
 *
 * 只用于装饰（粉色底、呼吸光环、气泡配色、直播角标），**不参与权限或
 * 数据可见性判断**——审美层判断错了只是难看，不能让它变成授权依据。
 */
export const ELYSIA_USERNAME = "elysia";

/** 该用户是不是爱莉。传 null/undefined 一律 false。 */
export function isElysiaUser(
  user: { username?: string | null } | null | undefined,
): boolean {
  return user?.username === ELYSIA_USERNAME;
}
