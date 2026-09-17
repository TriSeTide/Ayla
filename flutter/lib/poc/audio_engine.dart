/// PoC-A 音频引擎：采集 → Opus 编码 → （经 RelayClient）发送；接收 → 解码 → 低延迟播放。
///
/// 采集：record 6.x `startStream(RecordConfig(encoder: pcm16bits, sampleRate: 48000,
/// numChannels: 1))` → PCM16 字节流 → 按 kFrameBytes(1920) 切帧。
/// 编码：opus_codec_dart `SimpleOpusEncoder`（libopus FFI，48k 单声道，voip）。
/// 播放：flutter_miniaudio `MiniaudioPlayer`（全平台统一；miniaudio 底层 WASAPI/AAudio 等）
///   —— 选型实测（2026-09-17 定论）：
///   * flutter_soloud 3.5.4 弃用：Windows buffer stream 积压"停止才 flush"、
///     loadWaveform→play 卡死、deinit 卡死；
///   * miniaudio_dart 1.0.10 弃用：FFI native assets 缺失（hook/ 目录空、需手动
///     cmake 构建），运行时 Native asset 加载失败；
///   * flutter_miniaudio：标准 CMake 插件构建（自动编译）、push 式 write(Int16)、
///     bufferLatency 可测，实时 VoIP 定位（README）。
/// 语义对齐 wsRelayRoom.ts：仅 speaking（峰值迟滞 0.02/0.012）时发帧；
/// 静音不发帧；服务端仅转发 speaking=True 连接的音频。
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as ffi_pkg;
import 'package:flutter_miniaudio/flutter_miniaudio.dart';
import 'package:opus_codec/opus_codec.dart' as opus_load;
import 'package:opus_codec_dart/opus_dart.dart';
import 'package:record/record.dart';

import 'relay_client.dart';
import 'relay_protocol.dart';

/// 音频引擎状态回调
class AudioEngineCallbacks {
  /// 本地说话状态变化（UI 指示）
  void Function(bool speaking)? onSpeakingChanged;

  /// 本地音量 0~1（UI 跳动）
  void Function(double level)? onLocalLevel;

  /// 解码播放的音频缓冲深度（估计值，ms）
  void Function(int bufferDelayMs)? onPlaybackDelay;

  /// 累计帧计数（每 100 帧打一次）
  void Function(int sentFrames, int receivedFrames)? onFrameCount;

  void Function(String line)? onLog;
}

class AudioEngine {
  AudioEngine(this._relay, this._events);

  final RelayClient _relay;
  final AudioEngineCallbacks _events;

  AudioRecorder? _recorder;
  StreamSubscription<List<int>>? _recSub;
  final List<int> _captureBuf = [];

  SimpleOpusEncoder? _encoder;
  SimpleOpusDecoder? _decoder;
  bool _libInitialized = false;

  /// 播放侧：flutter_miniaudio MiniaudioPlayer（全平台统一）
  MiniaudioPlayer? _player;
  bool _miniaudioReady = false;

  /// 说话状态与迟滞
  bool _speaking = false;
  bool get speaking => _speaking;

  /// 统计
  int _sentFrames = 0;
  int _receivedFrames = 0;

  void _log(String line) => _events.onLog?.call('[audio] $line');

  /// 诊断用（VM service evaluate 从外部库访问）
  bool get debugLibInit => _libInitialized;
  bool get debugMiniaudioReady => _miniaudioReady;
  bool get debugEncoderReady => _encoder != null;
  bool get debugDecoderReady => _decoder != null;

  /// 初始化 libopus（全局一次）与 miniaudio StreamPlayer。
  Future<bool> init() async {
    try {
      if (!_libInitialized) {
        _log('init: 加载 libopus 动态库…');
        final lib = await opus_load.load();
        initOpus(lib);
        _libInitialized = true;
        _log('libopus v${getOpusVersion()} 已加载');
      }
      if (!_miniaudioReady) {
        _log('init: 创建 MiniaudioPlayer（48k mono，512 帧缓冲）…');
        // flutter_miniaudio：标准 CMake 插件构建，push 式 write(Int16)。
        // bufferFrames=512（~10.7ms @48k）低延迟起点；如 underrun 再调大。
        final p = MiniaudioPlayer(
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
      _log('Opus 编解码器就绪（${kSampleRate}Hz mono ${kFrameMs}ms）');
      return true;
    } catch (e) {
      _log('音频引擎初始化失败: $e');
      return false;
    }
  }

  /// 开/关麦。静音时释放麦克风（对齐 web：先发 mute 事实再释放设备）。
  Future<void> setMicrophoneEnabled(bool enabled) async {
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
    }
  }

  Future<void> _startCapture() async {
    if (_recSub != null) return;
    try {
      _recorder = AudioRecorder();
      final stream = await _recorder!.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: kSampleRate,
        numChannels: 1,
      ));
      _log('录音流已开（48k mono pcm16）');
      _recSub = stream.listen(_onPcmChunk, onError: (e) {
        _log('录音流错误: $e');
      });
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
      final frame = _captureBuf.sublist(0, kFrameBytes);
      _captureBuf.removeRange(0, kFrameBytes);
      _processFrame(frame);
    }
  }

  void _processFrame(List<int> pcm16Bytes) {
    // PCM16 LE → Int16List（960 样本）
    final samples = Int16List(kFrameSamples);
    for (var i = 0; i < kFrameSamples; i++) {
      samples[i] = (pcm16Bytes[i * 2] | (pcm16Bytes[i * 2 + 1] << 8)).toSigned(16);
    }

    // 说话检测（迟滞，对齐 wsRelayRoom.ts）
    var peak = 0.0;
    for (var i = 0; i < kFrameSamples; i++) {
      final a = (samples[i] / 32768.0).abs();
      if (a > peak) peak = a;
    }
    _events.onLocalLevel?.call(peak.clamp(0.0, 1.0));
    final nowSpeaking =
        _speaking ? peak > kSpeakingOff : peak > kSpeakingOn;
    if (nowSpeaking != _speaking) {
      _speaking = nowSpeaking;
      _relay.sendControl('speaking', on: nowSpeaking);
      _events.onSpeakingChanged?.call(nowSpeaking);
    }
    if (!nowSpeaking) return; // 静音不发帧（对齐 web：带宽由客户端兜一层）

    final enc = _encoder;
    if (enc == null) return;
    try {
      final packet = enc.encode(input: samples);
      _relay.sendOpus(packet);
      _sentFrames++;
      if (_sentFrames % 100 == 0) {
        _events.onFrameCount?.call(_sentFrames, _receivedFrames);
      }
    } catch (e) {
      _log('编码失败: $e');
    }
  }

  /// 接收侧：服务端 binary 帧 → 解码 → 喂 MiniaudioPlayer。
  Future<void> onRemoteAudio(int slot, Uint8List opus) async {
    final dec = _decoder;
    if (dec == null) return;
    try {
      final pcm = dec.decode(input: opus);
      if (pcm.isEmpty) return;
      _receivedFrames++;

      final p = _player;
      if (!_miniaudioReady || p == null) {
        _log('播放器未就绪，丢帧 ${pcm.length * 2}B');
        return;
      }
      // Int16 → 原生 Pointer → write（frames：单声道时 == 样本数）
      final ptr = ffi_pkg.malloc<Int16>(pcm.length);
      try {
        ptr.asTypedList(pcm.length).setAll(0, pcm);
        var written = 0;
        var guard = 0;
        while (written < pcm.length && guard < 64) {
          final n = p.write(ptr + written, pcm.length - written);
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

  /// 发送测试音（双端延迟实测）：生成 200ms 1kHz 正弦 → 编码经中继发送 → 本地播放。
  /// T1 打点在发送循环前一刻（避免本地播放初始化污染测量）；
  /// 服务端仅转发 speaking=True 连接的音频（audio_relay.may_relay），
  /// 因此先发 speaking on，发完帧再 off。
  Future<void> sendTestTone() async {
    const toneMs = 200;
    final totalSamples = kSampleRate * toneMs ~/ 1000; // 9600
    final sine = Int16List(totalSamples);
    const freq = 1000.0;
    for (var i = 0; i < totalSamples; i++) {
      sine[i] = (32767 * 0.5 * math.sin(2 * math.pi * freq * i / kSampleRate)).round();
    }
    // 经中继发送（Opus 每帧 960 样本 = 20ms；200ms 音切成 10 帧逐个编码）
    final enc = _encoder;
    if (enc == null) {
      _log('编码器未就绪，测试音无法发送');
      return;
    }
    _log('[LAT] T1 ${DateTime.now().millisecondsSinceEpoch} 发送测试音');
    _relay.sendControl('speaking', on: true);
    var sent = 0;
    for (var i = 0; i < totalSamples; i += kFrameSamples) {
      final frame = Int16List.sublistView(sine, i, i + kFrameSamples);
      _relay.sendOpus(enc.encode(input: frame));
      sent++;
    }
    _relay.sendControl('speaking', on: false);
    _sentFrames += sent;
    _log('测试音已发送（200ms 1kHz，$sent 帧）');
    // 本地播放（扬声器出音，验证本端链路；放发送后避免污染测量）
    final p = _player;
    if (!_miniaudioReady || p == null) return;
    final ptr = ffi_pkg.malloc<Int16>(totalSamples);
    try {
      ptr.asTypedList(totalSamples).setAll(0, sine);
      var written = 0;
      var guard = 0;
      while (written < totalSamples && guard < 96) {
        final n = p.write(ptr + written, totalSamples - written);
        if (n <= 0) break;
        written += n;
        guard++;
      }
    } finally {
      ffi_pkg.malloc.free(ptr);
    }
  }

  Future<void> dispose() async {
    await _stopCapture();
    _encoder?.destroy();
    _decoder?.destroy();
    _player?.dispose();
    _player = null;
    _miniaudioReady = false;
  }
}
