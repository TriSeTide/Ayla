/// 用户公开资料（`Ayla/web/src/api/types.ts:8–33` `UserPublic` 的 chat 域投影）。
///
/// 只承载渲染与在线判定需要的字段（id / 昵称 / 用户名 / 头像 / 状态 / 实时在线 /
/// 后端展示文案 / 跨页面媒体活动事实）—— 与 `post.dart` 的 [AylaPostAuthor]
/// 是**同一契约的两个投影**：帖子卡保留原类（既有调用点不动），chat 域用本类。
/// 后续若两者需要合并，按 `media_kind.dart` 的先例抽公共件。
///
/// 纪律：JSON 键名与后端一致（snake_case）；缺失就是缺失（null），不造默认值。
library;

/// 用户公开资料（`UserPublicSerializer`）。
class AylaUserPublic {
  const AylaUserPublic({
    required this.id,
    this.username,
    this.nickname,
    this.avatar,
    this.status,
    this.online = false,
    this.displayStatus,
    this.isInVoice = false,
    this.isLive = false,
  });

  final String id;
  final String? username;
  final String? nickname;

  /// 头像相对路径（可能指向媒体 content → 必须走签名链路）。
  final String? avatar;

  /// `auto / away / dnd / invisible`。
  final String? status;

  /// 实时在线（Redis presence；隐身对外视为离线）—— 运行事实，由页面注入。
  final bool online;

  /// 后端权威展示文案（auto→在线/离线、dnd→勿扰、away→离开、invisible→离线）。
  final String? displayStatus;

  /// 跨页面媒体活动事实（`is_in_voice` / `is_live`）。
  final bool isInVoice;
  final bool isLive;

  /// 展示名：nickname 优先，其次 username，最后 null（**不造「未知用户」**）。
  String? get displayName {
    final String? nick = _nonEmpty(nickname);
    if (nick != null) return nick;
    return _nonEmpty(username);
  }

  /// 解析；缺 `id` 视为非法 → null。
  static AylaUserPublic? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    if (id == null) return null;
    final String idText = id.toString();
    if (idText.isEmpty) return null;
    return AylaUserPublic(
      id: idText,
      username: raw['username'] as String?,
      nickname: raw['nickname'] as String?,
      avatar: raw['avatar'] as String?,
      status: raw['status'] as String?,
      online: raw['online'] as bool? ?? false,
      displayStatus: raw['display_status'] as String?,
      isInVoice: raw['is_in_voice'] as bool? ?? false,
      isLive: raw['is_live'] as bool? ?? false,
    );
  }
}

String? _nonEmpty(String? value) {
  if (value == null) return null;
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
