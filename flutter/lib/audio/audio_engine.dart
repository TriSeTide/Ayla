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
/// | 编码 | `opus_codec_dart` `SimpleOpusEncoder`（libopus FFI，voip） | ✓ |
/// | 播放 | **`flutter_miniaudio` 本地 fork**（`third_party/`） | 全平台统一（Windows ✓ / Android ✓；flutter_soloud 与 miniaudio_dart 均已实测淘汰） |
///
/// ## 语义（对齐 `wsRelayRoom.ts`）
/// - **仅 speaking 时发帧**（峰值迟滞 [kSpeakingOn] / [kSpeakingOff]）；静音不发帧
///   （服务端只转发 speaking 连接的音频）；
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
  final List<int> _captureBuf = <int>[];

  SimpleOpusEncoder? _encoder;
  SimpleOpusDecoder? _decoder;
  bool _libInitialized = false;

  /// 播放侧：flutter_miniaudio MiniaudioPlayer（全平台统一）。
  MiniaudioPlayer? _player;
  bool _miniaudioReady = false;

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
        _log('init: 创建 MiniaudioPlayer（48k mono，512 帧缓冲）…');
        // bufferFrames = 512（~10.7ms @48k）低延迟起点；如 underrun 再调大。
        final MiniaudioPlayer p = MiniaudioPlayer(
          sampleRate: kSampleRate,
          channels: 1,
          bufferFrames: 512,
        );
        _player = p;
        p.start();
        _miniaudioReady = true;
        _log('MiniaudioPlayer 已启动（48k mono，512 帧 ≈10.7ms）');
      }
      _log('init: 创建 opus 编解码器…');
      _encoder = SimpleOpusEncoder(
        sampleRate: kSampleRate,
        channels: 1,
        application: Application.voip,
      );
      _decoder = SimpleOpusDecoder(sampleRate: kSampleRate, channels: 1);
      _startLevelTick();
      _log('Opus 编解码器就绪（${kSampleRate}Hz mono ${kFrameMs}ms）');
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

  /// 远端成员实时音量快照（web 的 `onRemoteAudioLevels` 输出）。
  void _startLevelTick() {
    _levelTick?.cancel();
    _levelTick = Timer.periodic(kRemoteLevelTick, (_) {
      final Map<String, double> snapshot = <String, double>{};
      for (final MapEntry<int, double> e in _remotePeak.entries) {
        final String? identity = _relay.slotIdentity[e.key];
        if (identity == null || identity.isEmpty) continue;
        snapshot[identity] = e.value.clamp(0.0, 1.0);
      }
      _remotePeak.clear();
      _events.onRemoteAudioLevels?.call(snapshot);
    });
  }

  Future<void> _startCapture() async {
    if (_recSub != null) return;
    try {
      _recorder = AudioRecorder();
      final Stream<List<int>> stream = await _recorder!.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: kSampleRate,
          numChannels: 1,
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
    _captureBuf.clear();
  }

  void _onPcmChunk(List<int> chunk) {
    _captureBuf.addAll(chunk);
    while (_captureBuf.length >= kFrameBytes) {
      final List<int> frame = _captureBuf.sublist(0, kFrameBytes);
      _captureBuf.removeRange(0, kFrameBytes);
      _processFrame(frame);
    }
  }

  void _processFrame(List<int> pcm16Bytes) {
    // PCM16 LE → Int16List（960 样本）
    final Int16List samples = Int16List(kFrameSamples);
    for (int i = 0; i < kFrameSamples; i++) {
      samples[i] = (pcm16Bytes[i * 2] | (pcm16Bytes[i * 2 + 1] << 8)).toSigned(16);
    }

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
    _events.onLocalLevel?.call(peak.clamp(0.0, 1.0));
    final bool nowSpeaking = _speaking ? peak > kSpeakingOff : peak > kSpeakingOn;
    if (nowSpeaking != _speaking) {
      _speaking = nowSpeaking;
      _relay.sendControl('speaking', on: nowSpeaking);
      _events.onSpeakingChanged?.call(nowSpeaking);
    }
    if (!nowSpeaking) return; // 静音不发帧（对齐 web：带宽由客户端兜一层）

    final SimpleOpusEncoder? enc = _encoder;
    if (enc == null) return;
    try {
      final Uint8List packet = enc.encode(input: samples);
      _relay.sendOpus(packet);
      _sentFrames++;
      if (_sentFrames % 100 == 0) {
        _events.onFrameCount?.call(_sentFrames, _receivedFrames);
      }
    } catch (e) {
      _log('编码失败: $e');
    }
  }

  /// 接收侧：服务端 binary 帧 → 解码 → 按 slot 增益 → 喂 MiniaudioPlayer。
  Future<void> onRemoteAudio(int slot, Uint8List opus) async {
    final SimpleOpusDecoder? dec = _decoder;
    if (dec == null) return;
    try {
      final Int16List pcm = dec.decode(input: opus);
      if (pcm.isEmpty) return;
      _receivedFrames++;

      // 远端实时音量采样（100ms tick 输出快照）
      double peak = 0.0;
      for (int i = 0; i < pcm.length; i++) {
        final double a = (pcm[i] / 32768.0).abs();
        if (a > peak) peak = a;
      }
      final double prev = _remotePeak[slot] ?? 0;
      _remotePeak[slot] = peak > prev ? peak : prev;

      final MiniaudioPlayer? p = _player;
      if (!_miniaudioReady || p == null) {
        _log('播放器未就绪，丢帧 ${pcm.length * 2}B');
        return;
      }
      // 每 slot 增益（web setRemoteVolume；静音 = 0）
      final double gain = _relay.gainOfSlot(slot);
      if (gain <= 0) return;
      if (gain != 1.0) {
        for (int i = 0; i < pcm.length; i++) {
          final int v = (pcm[i] * gain).round();
          pcm[i] = v > 32767 ? 32767 : (v < -32768 ? -32768 : v);
        }
      }

      // Int16 → 原生 Pointer → write（frames：单声道时 == 样本数）
      final Pointer<Int16> ptr = ffi_pkg.malloc<Int16>(pcm.length);
      try {
        ptr.asTypedList(pcm.length).setAll(0, pcm);
        int written = 0;
        int guard = 0;
        while (written < pcm.length && guard < 64) {
          final int n = p.write(ptr + written, pcm.length - written);
          if (n <= 0) break;
          written += n;
          guard++;
        }
      } finally {
        ffi_pkg.malloc.free(ptr);
      }
      // 缓冲深度打点（bufferLatency 秒 → ms）
      _events.onPlaybackDelay?.call((p.bufferLatency * 1000).round());
    } catch (e) {
      _log('解码/播放失败: $e');
    }
  }

  Future<void> dispose() async {
    _levelTick?.cancel();
    _levelTick = null;
    await _stopCapture();
    _encoder?.destroy();
    _decoder?.destroy();
    _player?.dispose();
    _player = null;
    _miniaudioReady = false;
  }
}
