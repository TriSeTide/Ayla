/// 语音媒体面配置 —— 后端 join / media-token 响应里的 **`media`** 旁路字段。
///
/// ## 契约来源（后端已实现，本文件只解析不裁决）
/// `Ayla/backend/apps/voice/media_config.py` 的 `media_payload()`：
/// ```
/// "media": {
///   "transport": "livekit" | "ws_relay",   # 服务端建议值，不是命令
///   "livekit":  { "url", "token", "ttl", "expires_at", "room_name", "identity" } | null,
///   "ws_relay": { "url": "..." } | null    # 恒下发（回滚路径永远可用）
/// }
/// ```
///
/// ## 三条纪律
/// 1. **双下发、客户端可原地降级**：`transport=livekit` 但连接失败时，直接用手上这份
///    `wsRelay` 配置重试一次，**不回后端、不发版**（回滚速度 = 一次连接尝试）；
/// 2. **transport 只是建议值**：`livekit` 配置缺失/不完整时一律走 `ws_relay`（安全侧，
///    与后端 `configured_transport()` 的非法值回落一致）；
/// 3. **token 只作 connect 入参**：本层不打印、不缓存、不落盘（AGENTS.md §9 凭据纪律）。
///
/// ## identity 纪律（硬约束 1）
/// 后端签发 token 的 `identity` 必须是**裸 `str(user.pk)`**（无 `user_` 前缀）——
/// `backend/apps/voice/audio_consumer.py:93-95` 明写「identity 带前缀会导致全部失配」。
/// 本文件只把后端给的 `identity` 原样带出（供诊断比对），**任何一层都不得改写它**。
library;

/// 媒体传输方式（与后端 `VOICE_MEDIA_TRANSPORT` / `media.transport` 同字面量）。
enum AylaVoiceTransport {
  /// 自托管 LiveKit SFU（单 UDP 端口经 frp 穿透）。
  livekit('livekit'),

  /// WS 音频中继（Opus over WebSocket over TCP）—— **回滚路径**。
  wsRelay('ws_relay');

  const AylaVoiceTransport(this.wire);

  /// 线上字面量（与后端 JSON 逐字节一致）。
  final String wire;

  /// 解析：未知/缺失 ⇒ [wsRelay]（回滚路径；**不猜 livekit**）。
  static AylaVoiceTransport parse(Object? raw) {
    final String text = (raw ?? '').toString().trim().toLowerCase();
    return text == livekit.wire ? livekit : wsRelay;
  }
}

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

/// WS 中继媒体配置（回滚路径）。
class AylaVoiceWsRelayConfig {
  const AylaVoiceWsRelayConfig({required this.url});

  /// 完整地址（后端拼好 `?channel=<id>`；Flutter 侧只作诊断，
  /// 实际连接仍由 `AylaRelayClient` 按 `AYLA_API_BASE` 同源推导 ——
  /// 与现状逐字节一致，不引入第二套入口）。
  final String url;

  static AylaVoiceWsRelayConfig? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String url = raw['url']?.toString() ?? '';
    return url.isEmpty ? null : AylaVoiceWsRelayConfig(url: url);
  }
}

/// join / media-token 响应的 `media` 旁路字段（客户端唯一媒体配置来源）。
class AylaVoiceMediaConfig {
  const AylaVoiceMediaConfig({
    required this.transport,
    this.livekit,
    this.wsRelay,
  });

  /// 服务端建议的传输方式（不是命令；见库注释）。
  final AylaVoiceTransport transport;

  /// LiveKit 凭据（`transport != livekit` 或配置不全时为 null）。
  final AylaVoiceLiveKitConfig? livekit;

  /// WS 中继配置（回滚路径；后端恒下发）。
  final AylaVoiceWsRelayConfig? wsRelay;

  /// **是否真的走 LiveKit**：建议值 + 配置完整，二者缺一即走中继。
  bool get wantsLiveKit =>
      transport == AylaVoiceTransport.livekit && (livekit?.usable ?? false);

  /// 解析；`media` 缺失/结构非法 ⇒ null（调用方按「老后端」处理 = 走中继）。
  static AylaVoiceMediaConfig? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return AylaVoiceMediaConfig(
      transport: AylaVoiceTransport.parse(raw['transport']),
      livekit: AylaVoiceLiveKitConfig.fromJson(raw['livekit']),
      wsRelay: AylaVoiceWsRelayConfig.fromJson(raw['ws_relay']),
    );
  }

  @override
  String toString() => 'AylaVoiceMediaConfig(transport: ${transport.wire}, '
      'livekit: ${livekit ?? '-'}, wsRelay: ${wsRelay?.url ?? '-'})';
}
