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

/// 单个 opus 包的字节上限（编解码器的输入/输出复用缓冲都按它分配）。
///
/// 依据：[kOpusBitrate] = 32000 bps / 8 / 50 帧每秒 = **80 字节/帧**；
/// 即便码率翻倍到 64k 也只有 160 字节。取 512 字节 = 6.4 倍余量，
/// 既覆盖 libopus 的突发（CBR 下不会超），又比库默认 `maxDataBytes`(3825) 省内存。
const int kOpusMaxPacketBytes = 512;

/// 采集侧环形缓冲字节数 = **4 帧**（3840 字节）。
///
/// 只需容纳「一次回调最多一整帧 + 半帧余量」：`record` 的 pcm16bits 流按
/// 1024 样本左右回调，4 帧既能吸收回调抖动，又不会把延迟垫大。
const int kCaptureRingBytes = kFrameBytes * 4;

/// 设备回调周期（帧）。1024 帧 @48k = **21.3ms**（≈1.07 个 20ms 语音帧）。
///
/// 取舍（为什么不是 512 / 2048）：
/// - 512 帧 = 10.7ms（旧值）：一次 data_callback 补零只丢 10.7ms，但回调频率
///   高达 94 次/秒 ⇒ 主 isolate 的一次 GC 停顿就能连丢好几个回调；
/// - 1024 帧 = 21.3ms：回调降到 47 次/秒，且**不小于一个语音帧**，孤帧也填得满；
/// - 2048 帧 = 42.7ms：回调 23 次/秒更稳，但设备级延迟翻倍，说话人反馈会明显
///   拖，而抖动缓冲本身已经垫了 60ms，再叠 42.7ms 就不值得。
/// 净延迟 = 抖动缓冲 60ms + 设备周期 21ms ≈ 81ms（web 侧同类方案 20~80ms）。
const int kPlaybackBufferFrames = 1024;

/// 播放器 FIFO 容量（帧）。36000 帧 @48k = **750ms**。
///
/// 默认 8192 帧只有 171ms，**比 [kJitterResetAtSec]（400ms）还浅** ⇒ 高水位
/// 判断永远命不中，等于没有防积压能力。这里按「高水位 400ms × 1.5 余量 +
/// 静音期余量」取 750ms（mono Int16 ⇒ 72000 字节，内存可忽略）。
const int kPlaybackFifoCapacityFrames = 36000;

/// 编码码率 —— **文档常量，当前仍不在代码里生效**（2026-10-17 核查；
/// 2026-10-27 卡顿修复时复核，结论未变）。
///
/// web 事实源：`wsRelayRoom.ts:516` 的 `encoder.configure({ bitrate: 32000 })`。
///
/// 历史沿革（重要，别按旧结论推理）：
/// - 2026-10-17 时本工程用非缓冲的 `SimpleOpusEncoder`
///   （`opus_codec_dart` 3.0.5，`opus_dart_encoder.dart:33`），公开面只有
///   `encode / encodeFloat / destroy`，**完全没有码率入口**；
/// - 2026-10-27 卡顿修复把编码路径换成了 `BufferedOpusEncoder`（预分配缓冲），
///   它**确实**暴露了 `encoderCtl({required int request, required int value})`
///   （同文件 :290–293），理论上可以调
///   `opus_encoder_ctl(OPUS_SET_BITRATE_REQUEST=4002, kOpusBitrate)` 了；
/// - 但那一轮的任务边界是「只修卡顿，不动音质/码率」（用户明确约束），
///   ⇒ **仍然不启用**：换码率会让对端听感变化，必须单独一轮并单独验收。
/// ⇒ 保留为**文档常量**：数值仍是 web 权威值，将来启用时直接用；
/// **不要**误以为它在生效（`grep kOpusBitrate` 只应命中本文件）。
/// 实际码率由 libopus `Application.voip` 模式按输入自选（≈20–40kbps @48k mono）。
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

// ---------------------------------------------------------------------------
// 抖动缓冲（playout jitter buffer）：水位常量 + **纯决策函数**
//
// web 事实源：`Ayla/web/src/livekit/wsRelayRoom.ts:311–315`
// ```
// const at = playHead.get(slot) ?? 0;
// // 抖动缓冲：落后 20ms 内顺延播放；积压超 400ms 视为断流，重置追赶
// if (at < now + 0.02 || at > now + 0.4) at = now + 0.02;
// src.start(at); playHead.set(slot, at + buf.duration);
// ```
// 浏览器那套是**带前瞻的调度器**（WebAudio 按 playHead 排播），本身就是抖动
// 缓冲；Flutter 侧没有调度器，只能靠 miniaudio FIFO 自己垫，所以不能照搬
// 「1 帧 lead」，必须显式垫到 [kJitterStartSec]。语义映射：
//   web `at < now + 0.02`（顺延）  ⇒ 本文件 [kJitterAheadTargetSec] = 欠载判定
//   web `at > now + 0.4`（重置追赶）⇒ 本文件 [kJitterResetAtSec] = 高水位
//   web 无对应（调度器自带）        ⇒ 本文件 [kJitterStartSec] / [kJitterTargetSec]
// ---------------------------------------------------------------------------

/// 单帧 lead（秒）—— web `wsRelayRoom.ts:313` 的 `at < now + 0.02`。
///
/// Flutter 侧语义：设备 FIFO 深度低于「一帧」就等于**没有提前量**，下一次
/// data_callback 必然补零（`third_party/flutter_miniaudio/src/miniaudio_bridge.c:162`），
/// 即欠载。故它就是欠载判定阈值。
const double kJitterAheadTargetSec = 0.02;

/// 断流 / 积压重置阈值（秒）—— web `wsRelayRoom.ts:313` 的 `at > now + 0.4`。
///
/// Flutter 侧语义：FIFO 深度达到该值即停止写入新帧（不进 FIFO），
/// 否则延迟会无限累积。与 web 的差异（有意，登记）：web 能直接把 playHead
/// 前跳丢掉已排队的 380ms；miniaudio FIFO 没有 flush 接口（fork 未导出清空），
/// 所以这里只能「丢掉后续入场帧，等设备把积压放完」——等效于一次性 ~400ms
/// 的空档，而不是 web 的瞬间前跳。
const double kJitterResetAtSec = 0.4;

/// 起播水位（秒）—— Flutter 侧新增（web 由调度器隐式保证）。
///
/// 60ms = 3 帧：覆盖「连续丢 2 帧」或「一次 20~40ms 的 TCP/frp 抖动 + Dart
/// GC 停顿」；再大就明显增加对话延迟，再小则 frp 抖动下仍会欠载。
const double kJitterStartSec = 0.06;

/// 稳态目标深度（秒）—— 追赶时下探到该值以下才算「已排空」。
///
/// 比欠载阈值 [kJitterAheadTargetSec] 留 10ms 余量：若追赶到恰好 20ms 就
/// 重新起播，一次调度抖动又会立刻欠载，形成「抖—停—抖」循环。
const double kJitterTargetSec = 0.03;

/// 抖动缓冲对单帧的处置动作。
enum JitterAction {
  /// 缓冲不足：本帧先压入 Dart 侧预缓冲，**暂不写设备**（避免设备回调补零）。
  prebuffer,

  /// 缓冲已够：把预缓冲队列连同本帧一起灌进设备（= 起播 / 重新起播）。
  flush,

  /// 稳态：本帧直接写设备。
  play,

  /// 积压过深 / 追赶中：丢弃本帧，防止延迟累积。
  drop,
}

/// 抖动缓冲决策结果（[decideJitterFrame] 的返回值）。
class JitterDecision {
  const JitterDecision({
    required this.action,
    required this.playing,
    required this.catchingUp,
    required this.fifoDepthSec,
  });

  /// 本帧怎么处置。
  final JitterAction action;

  /// 决策后的「稳态播放中」标志 —— 调用方原样存回即可。
  final bool playing;

  /// 决策后的「追赶中」标志（积压过深时置真，排空后转回预缓冲）。
  final bool catchingUp;

  /// 决策前的设备 FIFO 深度（秒；诊断用）。
  final double fifoDepthSec;

  @override
  String toString() =>
      'JitterDecision(${action.name}, playing: $playing, catchingUp: $catchingUp, '
      'fifo: ${(fifoDepthSec * 1000).toStringAsFixed(1)}ms)';
}

/// **纯函数**：给定「设备 FIFO 当前深度 / 待发预缓冲深度 / 本帧长度 / 当前状态」，
/// 决定本帧该 prebuffer / flush / play / drop。
///
/// 抽成顶层纯函数（不在 State 里）是为了能被单测逐档覆盖 —— 见
/// `test/voice_audio_jitter_test.dart`。
///
/// - [fifoDepthSec] 设备 FIFO 当前深度（**不含**本帧）；
/// - [pendingSec] Dart 侧预缓冲里已攒的时长；
/// - [frameSec] 本帧时长（20ms 帧 = 0.02）；
/// - [playing] 上一帧决策后的稳态标志；
/// - [catchingUp] 上一帧决策后的追赶标志。
JitterDecision decideJitterFrame({
  required double fifoDepthSec,
  required double pendingSec,
  required double frameSec,
  required bool playing,
  required bool catchingUp,
}) {
  // ① 追赶中：一直丢，直到 FIFO 下探到稳态目标水位 —— 然后交出控制权，
  //    本帧仍然丢掉，让下一次决策从预缓冲重新起播（不在深积压上叠写）。
  if (catchingUp) {
    final bool drained = fifoDepthSec <= kJitterTargetSec;
    return JitterDecision(
      action: JitterAction.drop,
      playing: false,
      catchingUp: !drained,
      fifoDepthSec: fifoDepthSec,
    );
  }

  // ② 积压过深：进入追赶（对齐 web 的「断流重置」）。
  if (fifoDepthSec >= kJitterResetAtSec) {
    return JitterDecision(
      action: JitterAction.drop,
      playing: false,
      catchingUp: true,
      fifoDepthSec: fifoDepthSec,
    );
  }

  // ③ 未起播：攒够起播水位再一次性灌入。
  if (!playing) {
    final bool enough =
        fifoDepthSec + pendingSec + frameSec >= kJitterStartSec;
    return JitterDecision(
      action: enough ? JitterAction.flush : JitterAction.prebuffer,
      playing: enough,
      catchingUp: false,
      fifoDepthSec: fifoDepthSec,
    );
  }

  // ④ 稳态：FIFO 浅于一帧 lead ⇒ 欠载，退回预缓冲重新攒水位。
  if (fifoDepthSec < kJitterAheadTargetSec) {
    return JitterDecision(
      action: JitterAction.prebuffer,
      playing: false,
      catchingUp: false,
      fifoDepthSec: fifoDepthSec,
    );
  }

  return JitterDecision(
    action: JitterAction.play,
    playing: true,
    catchingUp: false,
    fifoDepthSec: fifoDepthSec,
  );
}

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
