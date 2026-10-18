/// PoC-A 中继协议常量与帧类型。
///
/// 对照翻译：`Ayla/web/src/livekit/wsRelayRoom.ts`（客户端协议）
/// 与 `Ayla/backend/apps/voice/audio_consumer.py` + `audio_relay.py`（服务端实现）。
/// 帧协议：
///   C→S binary : 一个 20ms Opus 包（仅 speaking 时发送）
///   S→C binary : [1 字节 slot][Opus 包]
///   text       : joined / member_joined / member_left / speaking / muted / pong / error
library;

import 'dart:convert';

/// 采样率（与 wsRelayRoom.ts SAMPLE_RATE 一致）
const int kSampleRate = 48000;

/// 帧长（20ms）
const int kFrameMs = 20;

/// 每帧样本数（48k * 20ms / 1000 = 960，wsRelayRoom.ts FRAME_SAMPLES）
const int kFrameSamples = 960;

/// 每帧 PCM16 字节数（960 样本 * 2 字节）
const int kFrameBytes = kFrameSamples * 2;

/// 编码码率 —— **文档常量，当前不在代码里生效**（2026-10-17 核查结论）。
///
/// web 事实源：`wsRelayRoom.ts:516` 的 `encoder.configure({ bitrate: 32000 })`。
///
/// Flutter 侧**无法**设置该值，原因是所选库的 API 边界（不是遗漏）：
/// - 本工程用 `SimpleOpusEncoder`（`opus_codec_dart` 3.0.5，`opus_dart_encoder.dart:33`），
///   公开面只有 `encode / encodeFloat / destroy`，**没有码率入口**；
/// - 底层 `opus_encoder_ctl(OPUS_SET_BITRATE_REQUEST=4002, …)` 确实被包到了
///   `BufferedOpusEncoder.encoderCtl({request, value})`（同文件 :290–293），
///   但那是另一条编码路径（自带 native 输入/输出缓冲，要手工管 `inputBuffer` /
///   `inputBufferIndex`），换过去要重写整个 `_onPcmChunk` 编码链；收益仅
///   「32000 vs libopus VOIP 自选（≈20–40kbps @48k mono）」，与本轮风险不成比例。
/// ⇒ 保留为**文档常量**：数值仍是 web 权威值，供将来换编码路径时直接用；
/// **不要**误以为它在生效（`grep kOpusBitrate` 只应命中本文件）。
/// 实际码率由 libopus `Application.voip` 模式按输入自选（`audio_engine.dart:143`）。
const int kOpusBitrate = 32000;

/// 说话判定迟滞阈值（wsRelayRoom.ts SPEAKING_ON/SPEAKING_OFF；
/// 单阈值会导致 speaking 在阈值附近每几百 ms 翻转，对端听到断续"颤音"）
const double kSpeakingOn = 0.02;
const double kSpeakingOff = 0.012;

/// 握手超时（wsRelayRoom.ts HANDSHAKE_TIMEOUT_MS = 10s）
const int kHandshakeTimeoutMs = 10000;

/// 重连退避（wsRelayRoom.ts RECONNECT_BASE_MS / RECONNECT_MAX_MS）
const int kReconnectBaseMs = 1000;
const int kReconnectMaxMs = 30000;
const int kReconnectGiveUpAfter = 6;

/// 心跳间隔（wsRelayRoom.ts PING_INTERVAL_MS = 25s）
const int kPingIntervalMs = 25000;

/// 抖动缓冲：落后 20ms 内顺延播放；积压超 400ms 视为断流重置（wsRelayRoom.ts）
const double kJitterAheadTargetSec = 0.02;
const double kJitterResetAtSec = 0.4;

/// 服务端控制帧（audio_consumer.py send_json 载荷）
class RelayServerFrame {
  final String type;
  final int? slot;
  final String? identity;
  final bool? on;
  final List<RelayMember>? members;
  final int? ts;
  final String? detail;

  const RelayServerFrame({
    required this.type,
    this.slot,
    this.identity,
    this.on,
    this.members,
    this.ts,
    this.detail,
  });

  factory RelayServerFrame.fromJson(Map<String, dynamic> json) {
    return RelayServerFrame(
      type: json['type'] as String? ?? '',
      slot: (json['slot'] as num?)?.toInt(),
      identity: json['identity'] as String?,
      on: json['on'] as bool?,
      members: (json['members'] as List?)
          ?.map((m) => RelayMember.fromJson(m as Map<String, dynamic>))
          .toList(),
      ts: (json['ts'] as num?)?.toInt(),
      detail: json['detail'] as String?,
    );
  }
}

/// joined 帧的成员项（slot ↔ identity 映射）
class RelayMember {
  final int slot;
  final String identity;
  final bool? speaking;
  final bool? muted;

  const RelayMember({
    required this.slot,
    required this.identity,
    this.speaking,
    this.muted,
  });

  factory RelayMember.fromJson(Map<String, dynamic> json) {
    return RelayMember(
      slot: (json['slot'] as num?)?.toInt() ?? -1,
      identity: json['identity'] as String? ?? '',
      speaking: json['speaking'] as bool?,
      muted: json['muted'] as bool?,
    );
  }
}

/// 客户端 → 服务端控制帧（wsRelayRoom.ts sendControl）
String controlJson(String type, {bool? on, int? ts}) {
  final m = <String, dynamic>{'type': type};
  if (on != null) m['on'] = on;
  if (ts != null) m['ts'] = ts;
  return jsonEncode(m);
}
