/// 分享负载（SharePayload）—— 对齐 web `Ayla/web/src/utils/sharePayload.ts`
/// 与 `api/types.ts` 的 ShareType / SharePayload 契约（逐条同源）。
///
/// ## 事实源
///
/// | 本文件 | web |
/// |---|---|
/// | [AylaShareType] | `api/types.ts:145` ShareType |
/// | [AylaSharePayload] | `api/types.ts:148–160` SharePayload |
/// | [_s] | `utils/sharePayload.ts:13–16` s(value) |
/// | [_normalizeCover] | `utils/sharePayload.ts:8–11` normalizeCover |
/// | 六个工厂 | `utils/sharePayload.ts:19–130` |
///
/// 纪律：JSON 键名与后端一致（snake_case）；字段缺失就是缺失（null），
/// 不猜测、不造默认值。web 的 `SHARE_PAYLOAD_BUILDERS`（按 ShareType 分发）
/// 在 Flutter 侧暂无调用者，不预先创建。
library;

/// 分享来源类型（`types.ts:145`：与后端 `SHARE_TYPES` 一致）。
enum AylaShareType {
  group,
  voice,
  live,
  post,
  boardgame,
  user;

  /// 后端字段值（`share_type`）。
  String get wire => name;

  /// 未知来源返回 null（**不 fallback** 成某个具体类型）。
  static AylaShareType? parse(String? raw) => switch (raw) {
        'group' => AylaShareType.group,
        'voice' => AylaShareType.voice,
        'live' => AylaShareType.live,
        'post' => AylaShareType.post,
        'boardgame' => AylaShareType.boardgame,
        'user' => AylaShareType.user,
        _ => null,
      };
}

/// 分享负载（`Message.share_payload`；发送/渲染共用契约）。
class AylaSharePayload {
  const AylaSharePayload({
    required this.shareType,
    required this.targetId,
    required this.title,
    this.cover,
    this.subtitle,
    this.extra,
  });

  /// 群聊（`sharePayload.ts:19–41`）：群 id/群名/群头像/成员数/加入方式。
  ///
  /// web 入参 `id: string | number` → `String(conv.id)`。
  /// `extra` 恒为对象（成员数与加入方式都没有时为空对象，不是 null）。
  factory AylaSharePayload.group({
    required String id,
    required String title,
    String? avatar,
    int? memberCount,
    String? joinPolicy,
  }) {
    final Map<String, Object?> extra = <String, Object?>{};
    if (memberCount != null && memberCount > 0) {
      extra['member_count'] = memberCount;
    }
    if (joinPolicy != null && joinPolicy.isNotEmpty) {
      extra['join_policy'] = joinPolicy;
    }
    return AylaSharePayload(
      shareType: AylaShareType.group,
      targetId: id,
      title: _s(title),
      cover: _normalizeCover(avatar),
      subtitle: memberCount != null && memberCount > 0 ? '$memberCount 人' : null,
      extra: extra,
    );
  }

  /// 语音房（`sharePayload.ts:44–58`）：频道 id/房名/在线人数/群归属。
  ///
  /// `cover` 恒为 null（web 硬编码）。
  factory AylaSharePayload.voice({
    required String id,
    required String name,
    int? memberCount,
    String? groupId,
  }) {
    return AylaSharePayload(
      shareType: AylaShareType.voice,
      targetId: id,
      title: _s(name),
      cover: null,
      subtitle: memberCount != null && memberCount > 0 ? '$memberCount 人' : null,
      extra: _groupExtra(groupId),
    );
  }

  /// 直播间（`sharePayload.ts:61–76`）：频道 id/标题/封面/主播名/群归属。
  factory AylaSharePayload.live({
    required String id,
    required String title,
    String? cover,
    String? ownerName,
    String? groupId,
  }) {
    return AylaSharePayload(
      shareType: AylaShareType.live,
      targetId: id,
      title: _s(title),
      cover: _normalizeCover(cover),
      subtitle: ownerName != null && ownerName.isNotEmpty ? _s(ownerName) : null,
      extra: _groupExtra(groupId),
    );
  }

  /// 帖子（`sharePayload.ts:79–93`）：帖子 id/标题/正文摘要/群归属/首图封面。
  ///
  /// 正文先按 `\s+` 归一为单空格再截断：超过 24 个 UTF-16 码元取前 24 + 省略号。
  /// web 入参 `post.id: number` → `String(post.id)`。
  factory AylaSharePayload.post({
    required String id,
    required String title,
    String? body,
    String? group,
    String? cover,
  }) {
    final String normalized = _s(body).replaceAll(RegExp(r'\s+'), ' ');
    return AylaSharePayload(
      shareType: AylaShareType.post,
      targetId: id,
      title: _s(title),
      cover: _normalizeCover(cover),
      subtitle: normalized.isEmpty
          ? null
          : (normalized.length > 24
              ? '${normalized.substring(0, 24)}\u2026'
              : normalized),
      extra: _groupExtra(group),
    );
  }

  /// 桌游室（`sharePayload.ts:96–113`）：房间 id/房名/群归属/玩法类型。
  ///
  /// `cover` 恒为 null；`extra` 无内容时为 null（与 group 的空对象不同，
  /// web 原样如此）。
  factory AylaSharePayload.boardgame({
    required String id,
    required String name,
    String? group,
    String? gameType,
  }) {
    final Map<String, Object?> extra = <String, Object?>{};
    if (group != null && group.isNotEmpty) {
      extra['group_id'] = group;
    }
    if (gameType != null && gameType.isNotEmpty) {
      extra['game_type'] = gameType;
    }
    return AylaSharePayload(
      shareType: AylaShareType.boardgame,
      targetId: id,
      title: _s(name),
      cover: null,
      subtitle: gameType != null && gameType.isNotEmpty ? _s(gameType) : null,
      extra: extra.isEmpty ? null : extra,
    );
  }

  /// 用户名片（`sharePayload.ts:116–130`）：用户 id/昵称/头像。
  ///
  /// 标题回退链 `nickname → username → 用户`（各自 trim 后判空）。
  factory AylaSharePayload.user({
    required String id,
    String? nickname,
    String? username,
    String? avatar,
  }) {
    final String nick = _s(nickname);
    final String name = _s(username);
    return AylaSharePayload(
      shareType: AylaShareType.user,
      targetId: id,
      title: nick.isNotEmpty ? nick : (name.isNotEmpty ? name : '用户'),
      cover: _normalizeCover(avatar),
      subtitle: null,
      extra: null,
    );
  }

  /// 来源类型。
  final AylaShareType shareType;

  /// 分享目标 id（群 id/语音频道 id/直播频道 id/帖子 id/桌游房 id/用户 id）。
  final String targetId;

  /// 展示标题（群名/房名/直播标题/帖子标题/用户昵称）。
  final String title;

  /// 封面：站内相对路径（`/api/v1/media/...`）或 null。
  final String? cover;

  /// 副标题（人数/作者名/正文摘要），可为 null。
  final String? subtitle;

  /// 附加字段（`group_id` / `member_count` / `join_policy` / `game_type`）。
  final Map<String, Object?>? extra;

  /// 发送给后端的 JSON（键名与 web 对象字面量一致，null 字段保留为 null）。
  Map<String, Object?> toJson() => <String, Object?>{
        'share_type': shareType.wire,
        'target_id': targetId,
        'title': title,
        'cover': cover,
        'subtitle': subtitle,
        'extra': extra,
      };
}

/// `s(value)`（`sharePayload.ts:13–16`）：`String(value ?? "").trim()`。
String _s(Object? value) => (value ?? '').toString().trim();

/// `normalizeCover`（`sharePayload.ts:8–11`）：只保留「以 / 开头且长度 > 1」
/// 的站内相对路径，其余（绝对 URL/空串/占位）归一为 null。
String? _normalizeCover(String? cover) {
  if (cover != null && cover.startsWith('/') && cover.length > 1) {
    return cover;
  }
  return null;
}

/// 群归属附加字段：`group_id` 非空时 `{group_id: ...}`，否则 null。
Map<String, Object?>? _groupExtra(String? groupId) {
  if (groupId != null && groupId.isNotEmpty) {
    return <String, Object?>{'group_id': groupId};
  }
  return null;
}
