/// 语音消息录制（web `hooks/useVoiceRecorder.ts` 的 Flutter 等价）。
///
/// ## 事实源
///
/// | 本文件 | web |
/// |---|---|
/// | [AylaVoiceRecorder] | `useVoiceRecorder.ts`（`MediaRecorder` + `getUserMedia`：`start` / `stop` / `cancel` / `elapsed` / `starting` / `error`） |
/// | 最短时长 0.8s 丢弃 | `MessageInput.tsx:308`（`rec.duration >= 0.8` 才发送） |
/// | 上传用的文件名与 mime | tsx 277（`new File([blob], "voice.webm", { type: rec.mimeType })`） |
///
/// ## 格式（与 web 的差异，已核实后端可接受）
/// web 用浏览器 `MediaRecorder` ⇒ 默认 `audio/webm;codecs=opus`。Flutter 侧用 `record` 包，
/// 默认编码 **AAC-LC / m4a（`audio/mp4`）**（Android / iOS / Windows 三端支持），
/// 编码不可用时回退 **WAV（`audio/x-wav`）**；两者都在后端 voice 允许清单内
/// （`backend/apps/media/services.py:101–102` 的 mime allowlist + 147–153 的 magic bytes）。
///
/// ## 平台能力边界（登记）
/// `isVoiceRecordingSupported()` 的 Flutter 等价 = [AylaVoiceRecorder.isSupported]
/// （`record` 的 `hasPermission` 可用性与编码支持）；**未支持时输入区隐藏录音入口**
/// （与 web 的 `isVoiceRecordingSupported()` 同语义）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ChangeNotifier, Listenable;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// 平台是否支持语音录制（web `isVoiceRecordingSupported()` 的等价）。
///
/// web 判断 `getUserMedia` + `MediaRecorder` 是否可用；Flutter 侧由 `record` 包支持的
/// 平台集合决定（Windows / macOS / Linux / Android / iOS / web）。
/// **输入区据此决定是否渲染录音键**（web 同语义：不支持时隐藏入口）。
bool aylaVoiceRecordingSupported() =>
    Platform.isWindows ||
    Platform.isMacOS ||
    Platform.isLinux ||
    Platform.isAndroid ||
    Platform.isIOS;

/// 一次录音的结果（web `VoiceRecording`：`blob` + `duration` + `mimeType`）。
class AylaVoiceRecording {
  const AylaVoiceRecording({
    required this.path,
    required this.mimeType,
    required this.duration,
    required this.size,
    required this.fileName,
  });

  /// 本地文件路径（web 是内存 blob）。
  final String path;

  /// 上传用 mime（`audio/mp4` / `audio/x-wav`）。
  final String mimeType;

  /// 时长（秒；web 用 `Date.now() - startedAt` 估算）。
  final double duration;

  /// 字节数。
  final int size;

  /// 上传文件名（web 固定 `voice.webm`）。
  final String fileName;
}

/// 语音录制器（可注入替身：测试/预览不触真实麦克风）。
abstract class AylaVoiceRecorder {
  /// 平台是否支持录音（web `isVoiceRecordingSupported()`）。
  bool get isSupported;

  bool get recording;
  bool get starting;

  /// 已录时长（web `voice.elapsed`，录制中每帧刷新）。
  Duration get elapsed;

  /// 变更通知（录制状态/时长/错误），供 UI 用 `ValueListenableBuilder` 刷新。
  Listenable get listenable;

  /// 错误文案（null = 无）。
  String? get error;

  void clearError();

  /// 开始录制（请求麦克风 → `starting` → 录制中）。
  Future<void> start();

  /// 停止并返回结果；未在录制/失败时返回 null。
  Future<AylaVoiceRecording?> stop();

  /// 取消并丢弃。
  Future<void> cancel();

  /// 释放（命名避开 `ChangeNotifier.dispose`，实现侧用组合而非继承该接口）。
  Future<void> close();
}

/// 基于 `record` 包的实现。
class AylaRecordVoiceRecorder extends ChangeNotifier implements AylaVoiceRecorder {
  AylaRecordVoiceRecorder({AudioRecorder? recorder})
      : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  bool _recording = false;
  bool _starting = false;
  String? _error;
  Timer? _ticker;
  DateTime? _startedAt;
  Duration _elapsed = Duration.zero;
  String? _path;

  @override
  bool get isSupported => aylaVoiceRecordingSupported();

  @override
  bool get recording => _recording;

  @override
  bool get starting => _starting;

  @override
  Duration get elapsed => _elapsed;

  @override
  Listenable get listenable => this;

  @override
  String? get error => _error;

  @override
  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  /// 编码与扩展名（web 无此选择；见文件头「格式」）。
  Future<({AudioEncoder encoder, String mimeType, String ext})> _pickFormat() async {
    if (await _recorder.isEncoderSupported(AudioEncoder.aacLc)) {
      return (encoder: AudioEncoder.aacLc, mimeType: 'audio/mp4', ext: 'm4a');
    }
    if (await _recorder.isEncoderSupported(AudioEncoder.wav)) {
      return (encoder: AudioEncoder.wav, mimeType: 'audio/x-wav', ext: 'wav');
    }
    // 都不支持：仍尝试 aacLc（部分平台 isEncoderSupported 保守返回 false）
    return (encoder: AudioEncoder.aacLc, mimeType: 'audio/mp4', ext: 'm4a');
  }

  @override
  Future<void> start() async {
    if (_recording || _starting) return;
    _starting = true;
    _error = null;
    notifyListeners();
    try {
      if (!await _recorder.hasPermission()) {
        _error = '麦克风权限被拒绝';
        return;
      }
      final ({AudioEncoder encoder, String mimeType, String ext}) fmt =
          await _pickFormat();
      final Directory dir = await getTemporaryDirectory();
      final String path =
          '${dir.path}${Platform.pathSeparator}voice-${DateTime.now().millisecondsSinceEpoch}.${fmt.ext}';
      await _recorder.start(
        RecordConfig(encoder: fmt.encoder, bitRate: 64000, sampleRate: 44100),
        path: path,
      );
      _path = path;
      _startedAt = DateTime.now();
      _elapsed = Duration.zero;
      _recording = true;
      // web 的 elapsed 由 hook 定时刷新；这里 200ms 一次（红点呼吸与计时文案同步）
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(milliseconds: 200), (Timer _) {
        final DateTime? at = _startedAt;
        if (at == null || !_recording) return;
        _elapsed = DateTime.now().difference(at);
        notifyListeners();
      });
    } catch (e) {
      _error = '$e';
    } finally {
      _starting = false;
      notifyListeners();
    }
  }

  @override
  Future<AylaVoiceRecording?> stop() async {
    if (!_recording) return null;
    _ticker?.cancel();
    _ticker = null;
    final DateTime? at = _startedAt;
    final Duration duration =
        at == null ? Duration.zero : DateTime.now().difference(at);
    _recording = false;
    _startedAt = null;
    notifyListeners();
    try {
      final String? stopped = await _recorder.stop();
      final String target = stopped ?? _path ?? '';
      _path = null;
      if (target.isEmpty) return null;
      final File file = File(target);
      if (!file.existsSync()) return null;
      final ({AudioEncoder encoder, String mimeType, String ext}) fmt =
          await _pickFormat();
      return AylaVoiceRecording(
        path: target,
        mimeType: fmt.mimeType,
        duration: duration.inMilliseconds / 1000,
        size: file.lengthSync(),
        // web 固定 `voice.webm`；这里按实际容器命名，上传后 content 即文件名
        fileName: 'voice.${fmt.ext}',
      );
    } catch (e) {
      _error = '$e';
      notifyListeners();
      return null;
    }
  }

  @override
  Future<void> cancel() async {
    _ticker?.cancel();
    _ticker = null;
    _recording = false;
    _starting = false;
    _startedAt = null;
    _elapsed = Duration.zero;
    notifyListeners();
    try {
      await _recorder.cancel();
      final String? path = _path;
      _path = null;
      if (path != null) {
        final File file = File(path);
        if (file.existsSync()) file.deleteSync();
      }
    } catch (_) {
      // 取消路径不抛（web 的 `voice.cancel()` 同样静默）
    }
  }

  @override
  Future<void> close() async {
    _ticker?.cancel();
    _ticker = null;
    await _recorder.dispose();
    super.dispose();
  }
}

/// 测试/预览用的空实现（不触麦克风；`isSupported=false` ⇒ UI 隐藏录音入口）。
class AylaNoopVoiceRecorder extends ChangeNotifier implements AylaVoiceRecorder {
  @override
  bool get isSupported => false;

  @override
  bool get recording => false;

  @override
  bool get starting => false;

  @override
  Duration get elapsed => Duration.zero;

  @override
  Listenable get listenable => this;

  @override
  String? get error => null;

  @override
  void clearError() {}

  @override
  Future<void> start() async {}

  @override
  Future<AylaVoiceRecording?> stop() async => null;

  @override
  Future<void> cancel() async {}

  @override
  Future<void> close() async => super.dispose();
}
