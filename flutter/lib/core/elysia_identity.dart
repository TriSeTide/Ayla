/// 「谁是爱莉」的唯一判定点（对齐 web 侧 `utils/elysiaIdentity.ts`）。
///
/// 后端用 ElysiaProfile 绑一个真实 user，她在 Ayla 里是普通账号：有 username、
/// 有好友、有私聊会话。前端拿不到 ElysiaProfile（桥接内部模型），username 是
/// 唯一还活着且不改的身份来源（改名只改 nickname）。
///
/// 只用于装饰（粉色底、呼吸光环、气泡配色），**不参与权限或数据可见性判断**。
library;

/// 爱莉在 Ayla 里的登录名。
const String elysiaUsername = 'elysia';

/// 该 username 是不是爱莉。null / 空串一律 false。
bool isElysiaUsername(String? username) => username == elysiaUsername;
