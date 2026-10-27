/// 语音房音频引擎 —— 采集 → Opus 编码 →（经 [AylaRelayClient]）发送；
/// 接收 → 解码 → 低延迟播放。媒体面 owner，web `livekit/wsRelayRoom.ts` 的
/// WebAudio + WebCodecs 链路的 Flutter 等价物。
///
/// ## 来源
/// 本文件 = PoC-A 的 `lib/poc/audio_engine.dart`（2026-09-17 三端实测验收，见
/// `POC_README.md §3`）提升而来。选型定论（**照抄，不再重新评估**）：
///
/// | 环节 | 选型 | 实测结论 |
/// |---|---|---|
/// | 采集 | `record` `startStream(pcm16bits, 48k, mono)` | Windows ✓ / Android 模拟器需开宿主麦克风 |
/// | 编码 | `opus_codec_dart` **`BufferedOpusEncoder`**（libopus FFI，voip；预分配缓冲） | ✓ |
/// | 解码 | `opus_codec_dart` **`BufferedOpusDecoder`**（预分配缓冲） | ✓ |
/// | 播放 | **`flutter_miniaudio` 本地 fork**（`third_party/`） | 全平台统一（Windows ✓ / Android ✓；flutter_soloud 与 miniaudio_dart 均已实测淘汰） |
///
/// ## 抖动缓冲（2026-10-27，「断断续续」的修复）
/// web 侧 `wsRelayRoom.ts:311–315` 每帧按 slot 维护 playHead，由 **WebAudio 调度器**
/// 自带抖动缓冲（落后 20ms 顺延 / 积压 400ms 重置）；Flutter 侧没有调度器，
/// 只能靠 miniaudio FIFO 自己垫，而旧实现「解码即 write」= 缓冲深度 ~0
/// ⇒ 一次 TCP/frp 抖动或 Dart GC 停顿就把 FIFO 抽干 ⇒ `data_callback` 补零
/// （`miniaudio_bridge.c:162`）⇒ 断断续续。
///
/// 现在改成：**设备 FIFO 是唯一缓冲源**，由 [decideJitterFrame]（纯函数，
/// 定义在 `lib/poc/relay_protocol.dart`）按水位决定 prebuffer / flush / play / drop。
/// 水位常量：起播 [kJitterStartSec]=100ms、稳态目标 [kJitterTargetSec]（= 欠载下限×1.5）、
/// **欠载下限 [kUnderrunFloorSec] = 一次设备回调消耗量 × 2**、积压丢弃 [kJitterResetAtSec]=400ms。
///
/// ⚠️ **欠载判据不能用 web 的 20ms**（2026-10-27 事故，见 [kUnderrunFloorSec] 注释与
/// `docs/flutter/38` §六）：设备一次 data_callback 要吃掉 [kPlaybackBufferFrames] 帧 =
/// 21.3ms，比 20ms 还多 ⇒ 稳态必然被判欠载 ⇒ 只预缓冲不写设备 ⇒ **成段静音**。
/// 用户描述「不像是一直在连着声听的」正是这个特征。
///
/// ## 语义（对齐 `wsRelayRoom.ts`）
/// - **音频帧持续发送**（2026-10-27 设计缺陷修复）；`speaking`（峰值迟滞
///   [kSpeakingOn] / [kSpeakingOff]）**只用于上报 UI 事实**（成员行高亮），
///   **不再门控发帧**。旧实现「仅 speaking 时发帧」会让说话的正常停顿、句尾降调、
///   换气全部变成静音空洞，听感是「有声音才连上去，声音小了就断」（用户实报）。
/// - 静音（`setMicrophoneEnabled(false)`）**完全释放麦克风设备**（隐私：熄灭硬件指示灯），
///   并先发 `mute{on:true}` 事实（web 同序）；
/// - 本地发送增益 0~2（web `setLocalVolume`，UI 的 0~100 映射为 `volume / 50`）——
///   web 是 WebAudio 的 `micGain` 节点，Flutter 侧在**编码前**按样本乘增益（语义等价）；
/// - 远端播放增益按 **user_id**（每 slot 一个，web `setRemoteVolume`）；
/// - `onRemoteAudioLevels` 以 **100ms tick 输出全量快照（含 0）**，上层直接覆盖
///   （web `wsRelayRoom.ts` 的 100ms tick 语义）。
///
/// ⚠️ **音频相关改动必须完整重启 app 验证**：热重载会污染原生音频 FFI 状态
/// （`POC_README.md §3.3`，历史踩过）。
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as ffi_pkg;
import 'package:flutter_miniaudio/flutter_miniaudio.dart';
import 'package:opus_codec/opus_codec.dart' as opus_load;
import 'package:opus_codec_dart/opus_dart.dart';
import 'package:record/record.dart';

import '../poc/relay_protocol.dart';
import 'relay_client.dart';

/// 远端音量快照的输出节拍（web `wsRelayRoom.ts` 的 100ms tick）。
const Duration kRemoteLevelTick = Duration(milliseconds: 100);

// 播放缓冲的两个常量定义在 `lib/poc/relay_protocol.dart`（与采样率/帧长同处），
// 便于纯 Dart 单测直接 import 而不必拉起 FFI 依赖。

/// 音频引擎状态回调。
class AudioEngineCallbacks {
  /// 本地说话状态变化（UI 指示）。
  void Function(bool speaking)? onSpeakingChanged;

  /// 本地音量 0~1（UI 跳动）。
  void Function(double level)? onLocalLevel;

  /// 解码播放的音频缓冲深度（估计值，ms）。
  void Function(int bufferDelayMs)? onPlaybackDelay;

  /// 远端成员实时音量**全量快照**（user_id → 0~1，**含 0**）——上层直接覆盖。
  void Function(Map<String, double> levels)? onRemoteAudioLevels;

  /// 累计帧计数（每 100 帧打一次）。
  void Function(int sentFrames, int receivedFrames)? onFrameCount;

  void Function(String line)? onLog;
}

/// 音频引擎（采集/编码/解码/播放；生命周期由页面会话层持有）。
class AylaAudioEngine {
  AylaAudioEngine(this._relay, this._events);

  final AylaRelayClient _relay;
  final AudioEngineCallbacks _events;

  AudioRecorder? _recorder;
  StreamSubscription<List<int>>? _recSub;

  /// 采集侧环形缓冲（**不再每 20ms `addAll` + `sublist`/`removeRange`**）。
  ///
  /// 旧实现每帧做两次 O(n) 拷贝（`addAll` + `removeRange` 同一个 List），
  /// 每秒 50 次 × 2 次整缓冲搬运 —— 这些分配正是 GC 停顿的来源，而停顿就落在
  /// 播放回填窗口里。环形缓冲写满一帧就直接交给编码器，全程只拷贝一次。
  late final Uint8List _captureRing = Uint8List(kCaptureRingBytes);
  int _captureWrite = 0;
  int _captureRead = 0;
  int _captureCount = 0;

  /// 编码输入样本的复用缓冲（**每帧只 memcpy，不 malloc**）。
  ///
  /// 编解码器自己的原生缓冲区（`BufferedOpusEncoder.inputBuffer` /
  /// `BufferedOpusDecoder.inputBuffer|outputBuffer`）在 init 时一次分配好；
  /// 播放侧的 Dart 可见缓冲按需扩容（见 [_playSamples] / [_ensurePlayCapacity]）。
  late final Int16List _encodeSamples = Int16List(kFrameSamples);

  /// 播放侧复用缓冲（Dart 侧），容量不足时按需翻倍。
  Int16List _playSamples = Int16List(kFrameSamples);

  /// 播放侧复用的原生小缓冲容量（样本）。一个 20ms 帧 = 960 样本。
  static const int _playPtrCapacity = kFrameSamples;

  /// 播放侧复用的原生小缓冲（只有一个回调周期的量；更大的帧走
  /// `MiniaudioPlayer.writeList` 兜底，见 [_writePtr]）。
  ///
  /// **惰性分配**：构造函数里 malloc 会让「只做静态分析 / 单测」的场景也
  /// 依赖 ffi 堆；[dispose] 后 [_playPtr] 置 null，重进房间时重新分配。
  Pointer<Int16>? _playPtr;

  /// 原生复用缓冲的取用（首次播放时分配）。
  Pointer<Int16> _ensurePlayPtr() {
    final Pointer<Int16>? existing = _playPtr;
    if (existing != null) return existing;
    final Pointer<Int16> created = ffi_pkg.malloc<Int16>(_playPtrCapacity);
    _playPtr = created;
    return created;
  }

  BufferedOpusEncoder? _encoder;
  BufferedOpusDecoder? _decoder;
  bool _libInitialized = false;


  /// 播放侧：flutter_miniaudio MiniaudioPlayer（全平台统一）。
  MiniaudioPlayer? _player;
  bool _miniaudioReady = false;

  /// 抖动缓冲状态（**只由 [decideJitterFrame] 的返回值写**）。
  ///
  /// 设备 FIFO（`MiniaudioPlayer.fifoAvailableFrames`）是唯一缓冲源：
  /// 预缓冲阶段的帧先攒在这里，起播时一次性灌入设备，此后逐帧直写。
  final List<Int16List> _jitterPending = <Int16List>[];
  bool _jitterPlaying = false;
  bool _jitterCatchingUp = false;

  /// 最近一次决策（诊断 / 单测）。null = 尚未收到任何音频帧。
  JitterDecision? _lastJitterDecision;

  /// 播放侧统计（诊断；`_log` 用，不参与控制流）。
  int _jitterDroppedFrames = 0;
  int _jitterUnderruns = 0;

  /// 说话状态与迟滞。
  bool _speaking = false;
  bool get speaking => _speaking;

  /// 本地发送增益 0~2（web `setLocalVolume`；1.0 = 原始）。
  double _localGain = 1.0;

  /// 麦克风是否开（媒体事实）。
  bool _micEnabled = false;
  bool get micEnabled => _micEnabled;

  /// 远端实时音量累积（slot → 峰值），每 tick 输出一次全量快照。
  final Map<int, double> _remotePeak = <int, double>{};

  /// 本地麦克风最近峰值（web `wsRelayRoom.ts:456` 的 `localPeak`）。
  ///
  /// 由采集帧更新、由 [_startLevelTick] 采样并衰减 ⇒ 与远端同一节奏输出。
  double _localPeak = 0;
  Timer? _levelTick;

  /// 统计。
  int _sentFrames = 0;
  int _receivedFrames = 0;
  int get sentFrames => _sentFrames;
  int get receivedFrames => _receivedFrames;

  void _log(String line) => _events.onLog?.call('[audio] $line');

  /// 诊断用。
  bool get debugLibInit => _libInitialized;
  bool get debugMiniaudioReady => _miniaudioReady;
  bool get debugEncoderReady => _encoder != null;
  bool get debugDecoderReady => _decoder != null;

  /// 初始化 libopus（全局一次）与 miniaudio 播放器。失败返回 false（**不伪造成功**）。
  Future<bool> init() async {
    try {
      if (!_libInitialized) {
        _log('init: 加载 libopus 动态库…');
        // `load()` 返回 Object（web 上是 wasm_ffi 的 DynamicLibrary）；
        // `initOpus(Object)` 接受同一形态（opus_codec_dart:98）。
        final Object lib = await opus_load.load();
        initOpus(lib);
        _libInitialized = true;
        _log('libopus v${getOpusVersion()} 已加载');
      }
      if (!_miniaudioReady) {
        _log('init: 创建 MiniaudioPlayer（48k mono，'
            '$kPlaybackBufferFrames 帧缓冲 / '
            '$kPlaybackFifoCapacityFrames 帧 FIFO）…');
        final MiniaudioPlayer p = MiniaudioPlayer(
          sampleRate: kSampleRate,
          channels: 1,
          bufferFrames: kPlaybackBufferFrames,
          fifoCapacityFrames: kPlaybackFifoCapacityFrames,
        );
        _player = p;
        p.start();
        _miniaudioReady = true;
        _log('MiniaudioPlayer 已启动（48k mono，'
            '$kPlaybackBufferFrames 帧 ≈'
            '${(kPlaybackBufferFrames * 1000 / kSampleRate).toStringAsFixed(1)}ms，'
            'FIFO ${(kPlaybackFifoCapacityFrames * 1000 / kSampleRate).round()}ms）');
      }
      _log('init: 创建 opus 编解码器（预分配缓冲）…');
      // init 可重入（`voice_media` 在 connect 与 startAudio 都会调）：
      // 先回收上一轮的编解码器，否则原生堆会随重进房间逐次累积。
      _encoder?.destroy();
      _decoder?.destroy();
      // ⚠️ 参数一个都不能动（仍 48k mono / Application.voip / 20ms）：
      // 本轮只改「缓冲策略」，不改编码语义与音质。
      _encoder = BufferedOpusEncoder(
        sampleRate: kSampleRate,
        channels: 1,
        application: Application.voip,
        // 只编 20ms s16le 帧 ⇒ 960 样本 × 2 字节 = 1920 字节就够；
        // 给 2 帧余量，万一上层喂来合并帧也不会越界。
        maxInputBufferSizeBytes: kFrameBytes * 2,
        // kOpusBitrate 上限对应 32000/8/50 = 80 字节/帧；宽松给 2 倍仍远小于
        // 库默认 maxDataBytes(3825)，省下的是原生堆占用。
        maxOutputBufferSizeBytes: kOpusMaxPacketBytes,
      );
      _decoder = BufferedOpusDecoder(
        sampleRate: kSampleRate,
        channels: 1,
        maxInputBufferSizeBytes: kOpusMaxPacketBytes,
        // 20ms 单声道 s16le = 1920 字节；给 2 帧余量。
        maxOutputBufferSizeBytes: kFrameBytes * 2,
      );
      _startLevelTick();
      _jitterPending.clear();
      _jitterPlaying = false;
      _jitterCatchingUp = false;
      _lastJitterDecision = null;
      _log('Opus 编解码器就绪（${kSampleRate}Hz mono ${kFrameMs}ms，'
          'BufferedOpusEncoder / BufferedOpusDecoder）');
      return true;
    } catch (e) {
      _log('音频引擎初始化失败: $e');
      return false;
    }
  }

  /// 开/关麦。静音时释放麦克风（对齐 web：先发 mute 事实再释放设备）。
  Future<void> setMicrophoneEnabled(bool enabled) async {
    _micEnabled = enabled;
    if (enabled) {
      await _startCapture();
      _relay.setMicEnabled(true);
      _relay.sendControl('mute', on: false);
    } else {
      _relay.setMicEnabled(false);
      _relay.sendControl('mute', on: true);
      await _stopCapture();
      if (_speaking) {
        _speaking = false;
        _events.onSpeakingChanged?.call(false);
      }
      _events.onLocalLevel?.call(0);
    }
  }

  /// 本地麦克风发送增益 0~2（web `setLocalVolume(volume / 50)`）。
  void setLocalGain(double gain) => _localGain = gain.clamp(0.0, 2.0);

  /// 远端成员本地播放增益 0~1（转发给中继客户端的 per-slot gain）。
  void setRemoteVolume(String userId, double volume) =>
      _relay.setRemoteVolume(userId, volume);

  /// 电平衰减系数（web `wsRelayRoom.ts:461/470` 的 `*= 0.6`）。
  ///
  /// ⚠️ **这是「波动感」的核心**，不是性能细节：峰值被采样后逐 tick 衰减，形成
  /// 自然起伏；若直接归零（旧实现 `_remotePeak.clear()`），只会在**恰好有音频帧**
  /// 的那一 tick 闪现一下就归 0 ⇒ 视觉上「完全不跳」。
  static const double _kLevelDecay = 0.6;

  /// 远端成员实时音量快照 + 本地电平（web `wsRelayRoom.ts:455–471` 的 100ms tick）。
  void _startLevelTick() {
    _levelTick?.cancel();
    _levelTick = Timer.periodic(kRemoteLevelTick, (_) {
      // ⚠️ `_relay.slotIdentity` 是 **getter**，每次访问 `Map.unmodifiable` 造新副本
      //（`relay_client.dart:141`）⇒ 循环内逐 slot 取会复制 N 次整表。提到循环外。
      final Map<int, String> identities = _relay.slotIdentity;
      final Map<String, double> snapshot = <String, double>{};
      for (final MapEntry<int, double> e in _remotePeak.entries) {
        if (e.key == _relay.mySlot) continue; // web `if (slot === mySlot) continue`
        final String? identity = identities[e.key];
        if (identity == null || identity.isEmpty) continue;
        snapshot[identity] = e.value.clamp(0.0, 1.0);
        // web：采样后衰减（不是清零）——下一 tick 起按 0.6 倍回落。
        _remotePeak[e.key] = (e.value * _kLevelDecay).clamp(0.0, 1.0);
      }
      // 已不再出现在 `_remotePeak` 里的 slot 自然收不到值 ⇒ 上层按「缺失 = 0」处理
      //（`setRemoteAudioLevels` 对快照里没有的成员归 0），无需在这里 clear。
      _events.onRemoteAudioLevels?.call(snapshot);

      // 本地电平：未开麦恒 0（契约：未开麦连续回调 0），开麦用最近峰值并衰减。
      // web `wsRelayRoom.ts:458–463`。旧实现直接转发原始 peak（无衰减、无开麦门控）
      // ⇒ 未开麦时也会残留旧值，开麦时跳动生硬。
      final double local = _micEnabled ? _localPeak : 0;
      _events.onLocalLevel?.call(local.clamp(0.0, 1.0));
      _localPeak *= _kLevelDecay;
    });
  }

  Future<void> _startCapture() async {
    if (_recSub != null) return;
    try {
      _recorder = AudioRecorder();
      final Stream<List<int>> stream = await _recorder!.startStream(
        // 采前处理三项（AEC / NS / AGC）—— web 事实源 `wsRelayRoom.ts:492–494`：
        // `echoCancellation: true, noiseSuppression: true, autoGainControl: true`
        // （浏览器 `getUserMedia` 的约束，三项全开）。
        // Flutter 侧 `record` 6.x 的等价字段是 `RecordConfig.echoCancel /
        // noiseSuppress / autoGain`（`record_platform_interface-1.6.0/lib/src/types/
        // record_config.dart:45/50/55`，默认全 false ⇒ **必须显式开**）。
        // 2026-10-17 补齐：此前三项一项未传 ⇒ 语音房互听有回声/底噪、远讲音量偏小。
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: kSampleRate,
          numChannels: 1,
          echoCancel: true, // wsRelayRoom.ts:492
          noiseSuppress: true, // wsRelayRoom.ts:493
          autoGain: true, // wsRelayRoom.ts:494
        ),
      );
      _log('录音流已开（48k mono pcm16）');
      _recSub = stream.listen(
        _onPcmChunk,
        onError: (Object e) => _log('录音流错误: $e'),
      );
    } catch (e) {
      _log('开麦失败: $e');
    }
  }

  Future<void> _stopCapture() async {
    await _recSub?.cancel();
    _recSub = null;
    try {
      await _recorder?.stop();
    } catch (_) {}
    _recorder = null;
    _captureWrite = 0;
    _captureRead = 0;
    _captureCount = 0;
  }

  /// 采集流回调：把 chunk 灌进环形缓冲，攒满 [kFrameBytes] 就切一帧编码。
  ///
  /// 旧实现是「整块 addAll 进一个 List」+ 每帧 `sublist`/`removeRange`
  /// —— 每 20ms 两次整缓冲 O(n) 搬运 + 两次 List 分配（见字段注释）。
  void _onPcmChunk(List<int> chunk) {
    int i = 0;
    final int n = chunk.length;
    while (i < n) {
      // ① 先把环形缓冲写满
      final int space = kCaptureRingBytes - _captureCount;
      final int take = (n - i) < space ? (n - i) : space;
      for (int k = 0; k < take; k++) {
        _captureRing[_captureWrite] = chunk[i + k];
        _captureWrite = (_captureWrite + 1) % kCaptureRingBytes;
      }
      _captureCount += take;
      i += take;
      // ② 每攒满一帧就出队编码（写指针可能绕回，故按字节逐帧读）
      while (_captureCount >= kFrameBytes) {
        _drainOneFrame();
        _processFrame();
      }
    }
  }

  /// 从环形缓冲取出一帧到 [_encodeSamples]（PCM16 LE → Int16）。
  void _drainOneFrame() {
    final Int16List samples = _encodeSamples;
    int r = _captureRead;
    for (int i = 0; i < kFrameSamples; i++) {
      final int lo = _captureRing[r];
      r = (r + 1) % kCaptureRingBytes;
      final int hi = _captureRing[r];
      r = (r + 1) % kCaptureRingBytes;
      samples[i] = (lo | (hi << 8)).toSigned(16);
    }
    _captureRead = r;
    _captureCount -= kFrameBytes;
  }

  /// 编码并发送 [_encodeSamples] 这一帧。
  ///
  /// ## 2026-10-27 设计缺陷修复（用户实报「有声音才连上去，声音小了就跟断了一样」）
  ///
  /// 旧实现把 `speaking`（一个**UI 提示**概念：谁在说话，用于成员行高亮）
  /// 当成**媒体传输门控**：
  ///
  /// ```dart
  /// if (!nowSpeaking) return;   // ← 峰值低于 0.02 就整帧不发
  /// ```
  ///
  /// 后果：人说话的正常停顿、句尾降调、换气、轻辅音，峰值都会跌破 0.02 ⇒
  /// **停止发帧** ⇒ 服务端 `may_relay` 因 `not member.speaking` 丢弃 ⇒
  /// 对端只收到「有声音的那几段」⇒ 听感正是「**有声音才连上去，声音小了就断**」。
  ///
  /// 这是设计错误，不是调阈值能解决的（把阈值调到 0 等于永不判定说话，
  /// 成员行高亮就废了）。正确做法是**两件事解耦**：
  /// - `speaking` 只上报 UI 事实（阈值迟滞不变，仍在峰值上判断）；
  /// - **音频帧持续发送**，与说话状态无关。
  ///
  /// 带宽代价（实测估算）：静音帧在 libopus VOIP VBR 下仅 ~25 字节，
  /// 持续发送每人约 2 KB/s（峰值 3.9 KB/s），20 人房间服务器总吞吐 ~6.3 Mbps，
  /// 远低于樱花隧道 24 Mibit/s。**带宽不是阻碍**，见 `docs/flutter/39`。
  void _processFrame() {
    final Int16List samples = _encodeSamples;

    // 本地发送增益（web micGain；0~2，越界按 Int16 边界钳制）
    if (_localGain != 1.0) {
      for (int i = 0; i < kFrameSamples; i++) {
        final int v = (samples[i] * _localGain).round();
        samples[i] = v > 32767 ? 32767 : (v < -32768 ? -32768 : v);
      }
    }

    // 说话检测（迟滞，对齐 wsRelayRoom.ts SPEAKING_ON/OFF）
    double peak = 0.0;
    for (int i = 0; i < kFrameSamples; i++) {
      final double a = (samples[i] / 32768.0).abs();
      if (a > peak) peak = a;
    }
    // ⚠️ **2026-10-26 修复（用户实报「听得见声音但音频条完全不跳动」）**：
    // web 的口径是「**记录峰值 → 100ms tick 统一衰减上报**」
    //（`wsRelayRoom.ts:458–463`：`events.onLocalAudioLevel(micEnabled ? localPeak : 0)`
    //  然后 `localPeak *= 0.6`）。这里此前是**每帧直接上报原始 peak**（无衰减、
    // 无开麦门控），且与 tick 里的远端快照不同步 ⇒ 视觉上条子几乎不动。
    // 改为只记录峰值，由 [_startLevelTick] 统一衰减输出（与远端同一节奏）。
    if (peak > _localPeak) _localPeak = peak;
    final bool nowSpeaking = _speaking ? peak > kSpeakingOff : peak > kSpeakingOn;
    if (nowSpeaking != _speaking) {
      _speaking = nowSpeaking;
      _relay.sendControl('speaking', on: nowSpeaking);
      _events.onSpeakingChanged?.call(nowSpeaking);
    }
    // ⚠️ **不要在这里按 speaking 门控发帧**（2026-10-27 设计缺陷修复）：
    // `nowSpeaking` 只用于上报 UI 事实与计费级 speaking 控制帧；
    // 音频流**必须持续发送**，否则对端只能收到「有声片段」，听感就是成段断音。
    // 详见 [_processFrame] 的文档注释与 docs/flutter/39。

    final BufferedOpusEncoder? enc = _encoder;
    if (enc == null) return;
    try {
      // 预分配路径：样本直接 write 进编码器的原生 inputBuffer（**inputBufferIndex
      // 的单位是「字节」**，不是样本数 —— 写错会静默编出半帧/错帧）。
      // 这里只做一次 memcpy，不像旧的非缓冲实现每帧 malloc 输入 + 输出。
      final Uint8List src = samples.buffer.asUint8List(
        samples.offsetInBytes,
        samples.lengthInBytes,
      );
      final int frameBytes = samples.lengthInBytes;
      enc.inputBuffer.setRange(0, frameBytes, src);
      enc.inputBufferIndex = frameBytes;
      final Uint8List packet = enc.encode();
      // ⚠️ sendOpus 只把 packet 交给 WebSocket sink，不在本帧之外持有引用；
      // outputBuffer 是**拷贝**（opus_dart_encoder.dart:229），因此这里安全。
      _relay.sendOpus(packet);
      _sentFrames++;
      if (_sentFrames % 100 == 0) {
        _events.onFrameCount?.call(_sentFrames, _receivedFrames);
      }
    } catch (e) {
      _log('编码失败: $e');
    }
  }

  /// 接收侧：服务端 binary 帧 → 解码 → 按 slot 增益 → **抖动缓冲** → 喂 MiniaudioPlayer。
  ///
  /// 缓冲策略见文件头「抖动缓冲」一节与 [decideJitterFrame]：设备 FIFO 是唯一
  /// 缓冲源，欠载时先把帧攒在 [_jitterPending] 而不写设备，攒够
  /// [kJitterStartSec] 再一次性灌入（起播）；积压达到 [kJitterResetAtSec]
  /// 则丢弃入场帧进入追赶。
  Future<void> onRemoteAudio(int slot, Uint8List opus) async {
    final BufferedOpusDecoder? dec = _decoder;
    if (dec == null) return;
    final MiniaudioPlayer? p = _player;
    if (!_miniaudioReady || p == null) {
      _log('播放器未就绪，丢帧');
      return;
    }
    try {
      // ⚠️ 拷进 Dart 侧复用缓冲：解码器的输出缓冲下一帧就会被覆盖，
      // 预缓冲阶段必须先把样本搬出来，否则攒的全是同一帧。
      final int sampleCount = _decodeIntoPlayBuffer(dec, opus);
      if (sampleCount <= 0) return;
      _receivedFrames++;

      final Int16List buf = _playSamples;
      // 远端实时音量采样（100ms tick 输出快照）
      double peak = 0.0;
      for (int i = 0; i < sampleCount; i++) {
        final double a = (buf[i] / 32768.0).abs();
        if (a > peak) peak = a;
      }
      final double prev = _remotePeak[slot] ?? 0;
      _remotePeak[slot] = peak > prev ? peak : prev;

      // 每 slot 增益（web setRemoteVolume；静音 = 0）
      final double gain = _relay.gainOfSlot(slot);
      if (gain <= 0) {
        _events.onPlaybackDelay?.call((p.bufferLatency * 1000).round());
        return;
      }
      if (gain != 1.0) {
        for (int i = 0; i < sampleCount; i++) {
          final int v = (buf[i] * gain).round();
          buf[i] = v > 32767 ? 32767 : (v < -32768 ? -32768 : v);
        }
      }

      _pumpJitter(p, sampleCount);
      // 缓冲深度打点（bufferLatency 秒 → ms）
      _events.onPlaybackDelay?.call((p.bufferLatency * 1000).round());
    } catch (e) {
      _log('解码/播放失败: $e');
    }
  }

  /// 解码一帧到 [_playSamples]，返回样本数（mono ⇒ 样本数 == 帧数）。
  ///
  /// 走 BufferedOpusDecoder：输入写进它自己的原生 inputBuffer（**单位是字节**），
  /// 输出由 opus_decode 直接写进它的原生缓冲 —— 全程无 malloc。
  /// 这里再把结果搬进我们自己复用的 [_playSamples]（一次 setRange），换掉
  /// 旧的非缓冲解码器每次 decode 的「malloc 输入 + malloc 输出 + 两次 fromList」。
  int _decodeIntoPlayBuffer(BufferedOpusDecoder dec, Uint8List opus) {
    if (opus.isEmpty) return 0;
    // 直接拷进解码器的原生输入缓冲（唯一一次拷贝；上层已用
    // `Uint8List.fromList` 给出独立缓冲，见 relay_client._handleBinary）。
    final int take = opus.length < kOpusMaxPacketBytes
        ? opus.length
        : kOpusMaxPacketBytes;
    dec.inputBuffer.setRange(0, take, opus);
    dec.inputBufferIndex = take;
    // ⚠️ 输入/输出缓冲由解码器复用：必须在下一次 decode 前把输出搬走。
    final Int16List pcm = dec.decode();
    if (pcm.isEmpty) return 0;
    _ensurePlayCapacity(pcm.length);
    _playSamples.setRange(0, pcm.length, pcm);
    return pcm.length;
  }

  /// 播放复用缓冲按需扩容（正常永远是 960 样本，不会触发）。
  void _ensurePlayCapacity(int samples) {
    if (_playSamples.length >= samples) return;
    Int16List grown = Int16List(samples);
    grown.setRange(0, _playSamples.length, _playSamples);
    _playSamples = grown;
  }

  /// 把当前帧（已在 [_playSamples]，共 [sampleCount] 个样本）交给抖动缓冲决策。
  void _pumpJitter(MiniaudioPlayer p, int sampleCount) {
    final double frameSec = sampleCount / kSampleRate;
    final double fifoDepthSec = p.fifoAvailableFrames / kSampleRate;
    int pendingSamples = 0;
    for (final Int16List c in _jitterPending) {
      pendingSamples += c.length;
    }

    final JitterDecision d = decideJitterFrame(
      fifoDepthSec: fifoDepthSec,
      pendingSec: pendingSamples / kSampleRate,
      frameSec: frameSec,
      playing: _jitterPlaying,
      catchingUp: _jitterCatchingUp,
    );
    final bool wasPlaying = _jitterPlaying;
    _lastJitterDecision = d;
    _jitterPlaying = d.playing;
    _jitterCatchingUp = d.catchingUp;

    switch (d.action) {
      case JitterAction.prebuffer:
        // 只有「本来在播、被抽干」才算一次真欠载；首次攒水位的 3 帧不算。
        if (wasPlaying) _jitterUnderruns++;
        _pushPending(sampleCount);
      case JitterAction.drop:
        _jitterDroppedFrames++;
        if (d.catchingUp) _jitterPending.clear();
      case JitterAction.flush:
        _pushPending(sampleCount);
        for (final Int16List chunk in _jitterPending) {
          _writeSamples(p, chunk);
        }
        _jitterPending.clear();
      case JitterAction.play:
        _writePtr(p, sampleCount);
    }
  }

  /// 把当前帧拷进预缓冲队列（必须拷贝：[_playSamples] 下一帧就被复用）。
  void _pushPending(int sampleCount) {
    // 一次分配 + 区间拷贝（`sublist` 会先建中间列表再 `fromList` 再拷一遍）。
    final Int16List copy = Int16List(sampleCount);
    copy.setRange(0, sampleCount, _playSamples);
    _jitterPending.add(copy);
    // 兜底：预缓冲不该无限长（正常在攒到 kJitterStartSec 时就会被 flush）。
    // 万一水位判定因设备异常长期不满足，丢最旧的帧而不是让内存/延迟增长。
    while (_jitterPending.length > 16) {
      _jitterPending.removeAt(0);
    }
  }

  /// 把 [_playSamples] 的前 [sampleCount] 个样本写进设备 FIFO。
  ///
  /// - `frames == samples`（mono）：走 `write(Pointer, frames)`，先搬进复用的
  ///   原生小缓冲 [_playPtr]（一个回调周期 960 样本足够）；
  /// - 万一将来出现更大的合并包，退到 `MiniaudioPlayer.writeList`
  ///   （它直接写自己拥有的 FIFO，不需要临时原生内存）。
  void _writePtr(MiniaudioPlayer p, int sampleCount) {
    if (sampleCount <= _playPtrCapacity) {
      final Pointer<Int16> ptr = _ensurePlayPtr();
      // ⚠️ 必须用 `setRange` 而不是 `setAll`：[_playSamples] 可能已被
      // `_ensurePlayCapacity` 扩容（长度 > sampleCount），`setAll` 会越界。
      ptr.asTypedList(sampleCount).setRange(0, sampleCount, _playSamples);
      _writeNative(p, ptr, sampleCount);
      return;
    }
    p.writeList(_playSamples.sublist(0, sampleCount));
  }

  /// 把 Dart 侧一段样本写进设备 FIFO（搬进复用的原生缓冲，不额外 malloc）。
  void _writeSamples(MiniaudioPlayer p, Int16List samples) {
    if (samples.length <= _playPtrCapacity) {
      final Pointer<Int16> ptr = _ensurePlayPtr();
      ptr.asTypedList(samples.length).setRange(0, samples.length, samples);
      _writeNative(p, ptr, samples.length);
      return;
    }
    p.writeList(samples);
  }

  /// 把 [ptr] 里的前 [sampleCount] 个样本真正推进设备 FIFO。
  void _writeNative(MiniaudioPlayer p, Pointer<Int16> ptr, int sampleCount) {
    int written = 0;
    int guard = 0;
    // fifo 满时 `write` 返回**实际写入帧数**（可能 0 / 部分，见
    // `miniaudio_bridge.c:354–385`：`ma_bridge_write_device_fifo` 会截断并把
    // 截断后的帧数返回）；写不完就放弃余量，绝不阻塞接收线程。
    while (written < sampleCount && guard < 64) {
      final int n = p.write(ptr + written, sampleCount - written);
      if (n <= 0) break;
      written += n;
      guard++;
    }
  }

  /// 诊断用：最近一次抖动缓冲决策（null = 尚未收到帧）。
  JitterDecision? get debugLastJitterDecision => _lastJitterDecision;

  /// 诊断用：预缓冲里当前攒了几帧。
  int get debugJitterPendingFrames => _jitterPending.length;

  /// 诊断用：累计被抖动缓冲丢掉的帧数（积压追赶）。
  int get debugJitterDroppedFrames => _jitterDroppedFrames;

  /// 诊断用：累计欠载次数（进入预缓冲的次数）。
  int get debugJitterUnderruns => _jitterUnderruns;

  Future<void> dispose() async {
    _levelTick?.cancel();
    _levelTick = null;
    await _stopCapture();
    _encoder?.destroy();
    _decoder?.destroy();
    _encoder = null;
    _decoder = null;
    _jitterPending.clear();
    _jitterPlaying = false;
    _jitterCatchingUp = false;
    _player?.dispose();
    _player = null;
    _miniaudioReady = false;
    // 原生复用缓冲：只在引擎销毁时释放一次（malloc 与 free 必须成对，
    // 否则每次重进语音房会泄漏 1920 字节；重复 free 会直接崩进程）。
    final Pointer<Int16>? ptr = _playPtr;
    if (ptr != null) {
      ffi_pkg.malloc.free(ptr);
      _playPtr = null; // 置空 ⇒ dispose 天然幂等，且重进房间会重新分配
    }
  }
}
