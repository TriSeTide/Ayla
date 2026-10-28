/// 语音媒体配置（后端 `join` / `media-token` 响应的 `media` 旁路字段）。
///
/// ## 唯一来源
/// 客户端**只认后端下发的 `media.livekit`**：`url`（信令）、`token`（媒体凭据）、
/// `room_name`、`identity`（用于 identity 纪律自检）、`ttl`/`expires_at`（可观测）。
/// 本地不推导地址、不读环境变量、不缓存 token。
///
/// ## 历史（2026-10-28）
/// 本文件曾同时承载 `AylaVoiceTransport`（livekit/ws_relay 二选一）与
/// `AylaVoiceWsRelayConfig`（WS 中继回退地址）。用户明确要求**只保留 LiveKit、
/// 中继与回退路径整体删除**后，这些结构与 `transport` 字段一并移除：
/// 缺失 `media.livekit` 时改为**显式失败**，不再静默降级。
library;

/// LiveKit 媒体凭据（join 与 media-token 同一形状）。
class AylaVoiceLiveKitConfig {
  const AylaVoiceLiveKitConfig({
    required this.url,
    required this.token,
    this.ttl,
    this.expiresAt,
    this.roomName,
    this.identity,
  });

  /// 信令地址（`wss://host/livekit`）。
  final String url;

  /// 媒体 token（**只作 connect 入参**：不打日志、不缓存、不落盘）。
  final String token;

  /// 有效期（秒）。
  final int? ttl;

  /// 到期时间（ISO-8601；后端给的可观测面）。
  final String? expiresAt;

  /// 房间名（= 后端 `channel.room_name`）。
  final String? roomName;

  /// 后端签发的 identity（**必须裸 user_id**，见库注释；本层只作诊断比对）。
  final String? identity;

  /// 是否可用于连接（url 与 token 都非空）。
  bool get usable => url.isNotEmpty && token.isNotEmpty;

  /// 解析（缺 url 或 token ⇒ null，**不造半份配置**）。
  static AylaVoiceLiveKitConfig? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String url = raw['url']?.toString() ?? '';
    final String token = raw['token']?.toString() ?? '';
    if (url.isEmpty || token.isEmpty) return null;
    return AylaVoiceLiveKitConfig(
      url: url,
      token: token,
      ttl: (raw['ttl'] as num?)?.toInt(),
      expiresAt: raw['expires_at']?.toString(),
      roomName: raw['room_name']?.toString(),
      identity: raw['identity']?.toString(),
    );
  }

  /// 诊断/日志用：**绝不包含 token**。
  @override
  String toString() =>
      'AylaVoiceLiveKitConfig(url: $url, room: ${roomName ?? '-'}, '
      'identity: ${identity ?? '-'}, ttl: ${ttl ?? '-'})';
}

/// join / media-token 响应的 `media` 旁路字段（客户端唯一媒体配置来源）。
class AylaVoiceMediaConfig {
  const AylaVoiceMediaConfig({this.livekit});

  /// LiveKit 凭据（缺失 ⇒ 无法连接，调用方应显式报错）。
  final AylaVoiceLiveKitConfig? livekit;

  /// 是否具备可用凭据。
  bool get usable => livekit?.usable ?? false;

  /// 解析；`media` 缺失/结构非法 ⇒ null（调用方按「后端未下发媒体配置」处理）。
  static AylaVoiceMediaConfig? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final AylaVoiceLiveKitConfig? livekit =
        AylaVoiceLiveKitConfig.fromJson(raw['livekit']);
    // 没有可用 livekit 凭据 ⇒ 视为「后端未下发媒体配置」（显式失败，不静默降级）。
    if (livekit == null) return null;
    return AylaVoiceMediaConfig(livekit: livekit);
  }

  @override
  String toString() =>
      'AylaVoiceMediaConfig(livekit: ${livekit ?? '-'})';
}
