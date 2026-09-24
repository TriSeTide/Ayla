/// 爱莉档案（`Ayla/web/src/api/types.ts:434–444` `ElysiaProfile` 的 Dart 对应）。
///
/// 本模型只承载**渲染所需字段**：`user` 在 web 里是完整 `UserPublic`，
/// Flutter 侧摊平为 [userId]（会话列表/入口卡不需要其余字段；需要时按同一先例扩展）。
///
/// 纪律：`display_name` 仅 UI 展示 —— 前端不生成爱莉的第一人称内容（AGENTS.md §4.1）。
library;

/// `chat_type`：私聊 / 群聊（`ElysiaProfileSerializer` 读字段）。
enum AylaElysiaChatType {
  private,
  group;

  String get wire => name;

  /// 未知取值返回 null（**不 fallback**）。
  static AylaElysiaChatType? parse(String? raw) => switch (raw) {
        'private' => AylaElysiaChatType.private,
        'group' => AylaElysiaChatType.group,
        _ => null,
      };
}

/// 爱莉档案（`ElysiaProfileSerializer`）。
class AylaElysiaProfile {
  const AylaElysiaProfile({
    required this.id,
    required this.displayName,
    required this.enabled,
    this.userId,
    this.streamId,
    this.platform,
    this.chatType,
    this.createdAt,
  });

  final int id;

  /// 展示名（`display_name`；空则由调用方回退「爱莉」）。
  final String displayName;

  /// 是否启用（入口卡副标题与头像在线态都取它）。
  final bool enabled;

  /// `user.id`（摊平）。
  final String? userId;

  final String? streamId;
  final String? platform;
  final AylaElysiaChatType? chatType;
  final String? createdAt;

  /// 解析；缺 `id` 视为非法 → null。
  static AylaElysiaProfile? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    if (id is! num) return null;
    final Object? user = raw['user'];
    return AylaElysiaProfile(
      id: id.toInt(),
      displayName: (raw['display_name'] as String?) ?? '',
      enabled: raw['enabled'] as bool? ?? false,
      userId: user is Map ? user['id']?.toString() : null,
      streamId: raw['stream_id'] as String?,
      platform: raw['platform'] as String?,
      chatType: AylaElysiaChatType.parse(raw['chat_type'] as String?),
      createdAt: raw['created_at'] as String?,
    );
  }
}
