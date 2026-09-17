/// PoC-B HLS 播放器封装层：状态机 + 黑屏自愈 + 跳边 + 平台分发。
///
/// 对照翻译 `Ayla/web/src/player/hls.ts` 与 `runtime/liveSessionRuntime.ts`：
/// - 自愈：waiting/stalled（Flutter = isBuffering）持续 [kStallTimeoutMs] 未恢复且
///   距上次重建 ≥ [kRebuildCooldownMs] → 重建播放器（黑屏自动恢复）；
///   恢复（isBuffering=false / position 前进）即取消；
/// - attach 幂等：相同 url 已挂载 → 不重建（切场景零黑屏）；
/// - refreshToLiveEdge：跳到直播最新（duration 有效 → seekTo 末尾；否则重建兜底）；
/// - destroy 幂等：重复调用不抛错。
///
/// 平台实现：Android/iOS = video_player（ExoPlayer/AVPlayer）；Windows 选型待定
/// （media_kit 需 mpv 运行库下载受阻 / video_player_win 预案），当前以 stub 占位。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

/// 自愈参数（web 端 liveSessionRuntime.ts STALL_TIMEOUT_MS / REBUILD_COOLDOWN_MS）
const int kStallTimeoutMs = 2000;
const int kRebuildCooldownMs = 4000;

/// 播放器对外状态
enum HlsState { idle, loading, playing, buffering, error }

/// 平台播放器抽象（Android/iOS = video_player；Windows = media_kit/mpv）。
///
/// 平台实现差异点（对照 03-平台适配与实施路线.md §1）：
/// - Android：ExoPlayer（video_player_android）——HLS 原生支持；
/// - iOS：AVPlayer（video_player_avfoundation）——原生 HLS + 全屏 AVPlayerViewController 语义；
/// - Windows：media_kit（mpv 内核，运行库已随 media_kit_libs_windows_video 打包）。
abstract class HlsPlatformPlayer {
  /// 平台状态变化（loading/playing/buffering/error）
  void Function(HlsState state)? onStateChange;

  /// 卡顿信号（进入缓冲/无新帧）
  void Function()? onStall;

  /// 恢复信号（缓冲结束/新帧到达）
  void Function()? onResume;

  /// fatal 不可恢复错误
  void Function(String detail)? onFatal;

  /// 挂载并初始化播放器（不自动播放，由调用方 [play]）。
  Future<void> attach(String url);

  /// 开始播放（live 起播尽量贴近边缘）。
  Future<void> play();

  /// 跳到直播最新；成功返回 true，失败返回 false（调用方重建兜底）。
  Future<bool> seekToLiveEdge();

  /// 视频渲染视图（无画面需求的场景返回 null，如纯音频链路）。
  Widget? buildView();

  /// 销毁（幂等）。
  Future<void> dispose();
}

/// 事件回调
class HlsPlayerCallbacks {
  void Function(HlsState state)? onStateChange;
  void Function(String detail)? onError;
  void Function(String line)? onLog;
}

/// HLS 播放器封装（状态机 + 自愈编排，平台实现经 [HlsPlatformPlayer] 注入）。
class HlsPlaybackController {
  HlsPlaybackController(this._makePlatform, this._events);

  final HlsPlatformPlayer Function() _makePlatform;
  final HlsPlayerCallbacks _events;

  HlsPlatformPlayer? _player;
  String? _currentUrl;
  HlsState _state = HlsState.idle;
  HlsState get state => _state;

  /// 当前视频渲染视图（平台实现给出；未挂载返回 null）。
  Widget? get videoView => _player?.buildView();

  String? _lastPositionKey; // 上一次 position 快照（自愈判定用）
  Timer? _stallTimer;
  DateTime _lastRebuildAt = DateTime.fromMillisecondsSinceEpoch(0);

  void _log(String line) => _events.onLog?.call('[hls] $line');

  void _setState(HlsState s) {
    _state = s;
    _events.onStateChange?.call(s);
  }

  /// 挂载播放器并开始播放。幂等：相同 url 已挂载 → 直接返回（不重建）。
  Future<void> attach(String url) async {
    if (_player != null && _currentUrl == url) {
      _log('attach 幂等跳过（$url 已挂载）');
      return;
    }
    await _player?.dispose();
    _player = null;
    _currentUrl = url;
    _lastRebuildAt = DateTime.now();
    _clearStallTimer();
    _setState(HlsState.loading);
    _log('attach $url');

    final p = _makePlatform();
    _player = p;
    p.onStateChange = _onPlatformState;
    p.onStall = _onStall;
    p.onResume = _onResume;
    p.onFatal = _onFatal;
    try {
      await p.attach(url);
      await p.play();
    } catch (e) {
      _events.onError?.call('播放器挂载失败: $e');
    }
  }

  void _onPlatformState(HlsState s) {
    _setState(s);
    if (s == HlsState.playing) _onResume();
  }

  /// 卡顿信号（isBuffering=true / 无新帧）。
  void _onStall() {
    if (_stallTimer != null) return;
    _stallTimer = Timer(const Duration(milliseconds: kStallTimeoutMs), () {
      _stallTimer = null;
      if (DateTime.now().difference(_lastRebuildAt).inMilliseconds <
          kRebuildCooldownMs) {
        _log('冷却期内（${kRebuildCooldownMs}ms）放弃自愈');
        return;
      }
      _log('卡顿 ${kStallTimeoutMs}ms 未恢复 → 重建播放器');
      final url = _currentUrl;
      if (url != null) unawaited(rebuild(url));
    });
    _log('stall 计时开始（${kStallTimeoutMs}ms）');
  }

  /// 恢复信号（isBuffering=false / 新帧到达）。
  void _onResume() {
    _clearStallTimer();
  }

  /// fatal 且不可恢复（web：冷却期外自动重建，冷却期内报播放失败）。
  void _onFatal(String detail) {
    _clearStallTimer();
    if (DateTime.now().difference(_lastRebuildAt).inMilliseconds >=
        kRebuildCooldownMs) {
      _log('fatal: $detail → 自动重建');
      final url = _currentUrl;
      if (url != null) unawaited(rebuild(url));
    } else {
      _events.onError?.call(detail);
    }
  }

  void _clearStallTimer() {
    _stallTimer?.cancel();
    _stallTimer = null;
  }

  /// 强制重建（绕过幂等：先 dispose 再 attach）。
  Future<void> rebuild(String url) async {
    await _player?.dispose();
    _player = null;
    await attach(url);
  }

  /// 跳到直播最新画面。duration 有效 → seekTo 末尾；否则重建兜底。
  Future<void> refreshToLiveEdge() async {
    final p = _player;
    if (p == null) return;
    final ok = await p.seekToLiveEdge();
    if (!ok) {
      _log('跳边兜底：重建播放器');
      final url = _currentUrl;
      if (url != null) await rebuild(url);
    }
  }

  /// 销毁（幂等）。
  Future<void> destroy() async {
    _clearStallTimer();
    await _player?.dispose();
    _player = null;
    _currentUrl = null;
    _setState(HlsState.idle);
  }

  /// 记录 position（自愈判定：长时间无新帧 = 卡死）。
  void notePosition(Duration pos) {
    final key = '${pos.inMilliseconds ~/ 500}';
    if (_lastPositionKey != null && _lastPositionKey == key) return;
    _lastPositionKey = key;
    // position 前进即视为恢复
    _onResume();
  }
}
