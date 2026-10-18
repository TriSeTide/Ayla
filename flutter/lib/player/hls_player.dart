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

/// 连续自动重建上限（**本项目新增，web 无对应**）。
///
/// 为什么必须有：地址不可达时（TLS 被重置 / 404 / 流未起）mpv 的状态是
/// `playing=true, buffering=true, position=0` 且**不抛异常** —— 旧实现每 2s 重建一次，
/// 永远停在「黑屏 + 转圈」，用户看不到错误也无从重试（2026-10-18 用户实报截图）。
/// 现在：连续 [kMaxAutoRebuilds] 次仍未起播 ⇒ 上报错误 ⇒ UI 显示「播放失败 + 重试」；
/// 人手重试会重置计数（不设上限）。
const int kMaxAutoRebuilds = 2;

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

  /// 播放位置前进（**已真正出画面**的唯一可靠判据）。
  ///
  /// mpv/ExoPlayer 在「已连上但拿不到数据」时状态仍是 `playing=true, position=0`；
  /// 只看 playing 会把「卡死」当成「已恢复」⇒ 永不触发自愈、也永不报错。
  void Function(Duration position)? onPosition;

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
  HlsPlaybackController(
    this._makePlatform,
    this._events, {
    /// 自愈参数（默认取上面的常量；**仅供测试缩短等待**，生产不要传）。
    this.stallTimeout = const Duration(milliseconds: kStallTimeoutMs),
    this.rebuildCooldown = const Duration(milliseconds: kRebuildCooldownMs),
    this.maxAutoRebuilds = kMaxAutoRebuilds,
  });

  final HlsPlatformPlayer Function() _makePlatform;
  final HlsPlayerCallbacks _events;

  /// 卡顿判定窗口（默认 [kStallTimeoutMs]）。
  final Duration stallTimeout;

  /// 两次自动重建的最小间隔（默认 [kRebuildCooldownMs]）。
  final Duration rebuildCooldown;

  /// 连续自动重建上限（默认 [kMaxAutoRebuilds]）。
  final int maxAutoRebuilds;

  HlsPlatformPlayer? _player;
  String? _currentUrl;
  HlsState _state = HlsState.idle;
  HlsState get state => _state;

  /// 当前视频渲染视图（平台实现给出；未挂载返回 null）。
  Widget? get videoView => _player?.buildView();

  String? _lastPositionKey; // 上一次 position 快照（自愈判定用）
  Timer? _stallTimer;
  DateTime _lastRebuildAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 连续自动重建次数（真正起播即清零；见 [kMaxAutoRebuilds]）。
  int _autoRebuilds = 0;

  /// 本次挂载是否已真正出过画面（位置前进过）。
  bool _started = false;

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
    p.onPosition = _onPlatformPosition;
    try {
      await p.attach(url);
      await p.play();
    } catch (e) {
      _events.onError?.call('播放器挂载失败: $e');
    }
  }

  void _onPlatformState(HlsState s) {
    _setState(s);
    // ⚠️ **不要**在 playing 时无条件 `_onResume()`：mpv 在「连上但没数据」时同样
    // `playing=true`，把它当恢复会取消卡顿计时器 ⇒ 永远停在转圈（用户实报现象）。
    // 恢复只由「位置前进」或「已起播后缓冲结束」驱动。
    if (s == HlsState.playing && _started) _onResume();
  }

  /// 平台播放位置上报（见 [HlsPlatformPlayer.onPosition]）。
  void _onPlatformPosition(Duration pos) => notePosition(pos);

  /// 位置前进 = 真的出画面（[HlsPlatformPlayer.onPosition]）。
  void _markStarted() {
    if (_started) return;
    _started = true;
    _autoRebuilds = 0;
  }

  /// 自动重建（带次数上限；超限改为上报错误）。
  Future<void> _autoRebuild(String url, String reason) async {
    if (_autoRebuilds >= maxAutoRebuilds) {
      _log('自动重建已达上限（$maxAutoRebuilds）→ 上报错误：$reason');
      _events.onError?.call(reason);
      return;
    }
    _autoRebuilds += 1;
    _log('第 $_autoRebuilds/$maxAutoRebuilds 次自动重建：$reason');
    await rebuild(url);
  }

  /// 卡顿信号（isBuffering=true / 无新帧）。
  void _onStall() {
    if (_stallTimer != null) return;
    _stallTimer = Timer(stallTimeout, () {
      _stallTimer = null;
      if (DateTime.now().difference(_lastRebuildAt) < rebuildCooldown) {
        // ⚠️ 旧实现这里只 `return`：计时器已置空且不再重排 ⇒ **永久停在转圈**、
        // 既不重建也不报错（用户实报现象）。现在再等一个冷却窗口后重试；
        // 仍失败会走 [_autoRebuild] 的封顶逻辑，最终把错误交给 UI。
        _log('冷却期内（${rebuildCooldown.inMilliseconds}ms）稍后重试');
        _stallTimer = Timer(rebuildCooldown, () {
          _stallTimer = null;
          final url = _currentUrl;
          if (url != null) {
            unawaited(_autoRebuild(url, '播放卡住（冷却期后仍无画面）'));
          }
        });
        return;
      }
      _log('卡顿 ${stallTimeout.inMilliseconds}ms 未恢复 → 重建播放器');
      final url = _currentUrl;
      if (url != null) {
        unawaited(
          _autoRebuild(url, '播放卡住（${stallTimeout.inMilliseconds}ms 无画面）'),
        );
      }
    });
    _log('stall 计时开始（${stallTimeout.inMilliseconds}ms）');
  }

  /// 恢复信号（isBuffering=false / 新帧到达）。
  void _onResume() {
    _clearStallTimer();
  }

  /// fatal 且不可恢复（web：冷却期外自动重建，冷却期内报播放失败）。
  void _onFatal(String detail) {
    _clearStallTimer();
    if (DateTime.now().difference(_lastRebuildAt) >= rebuildCooldown &&
        _autoRebuilds < maxAutoRebuilds) {
      _log('fatal: $detail → 自动重建');
      final url = _currentUrl;
      if (url != null) unawaited(_autoRebuild(url, detail));
    } else {
      _events.onError?.call(detail);
    }
  }

  void _clearStallTimer() {
    _stallTimer?.cancel();
    _stallTimer = null;
  }

  /// 强制重建（绕过幂等：先 dispose 再 attach）。
  ///
  /// [manual] = 用户点「重试」：**重置自动重建计数**（人手重试不设上限；
  /// 否则自动封顶后手动重试也会立刻报错）。
  Future<void> rebuild(String url, {bool manual = false}) async {
    if (manual) {
      _autoRebuilds = 0;
      _started = false;
    }
    await _player?.dispose();
    _player = null;
    await attach(url);
  }

  /// 用户主动重试（重置自愈计数后重建）。
  Future<void> retry(String url) => rebuild(url, manual: true);

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
    _autoRebuilds = 0;
    _started = false;
    _setState(HlsState.idle);
  }

  /// 记录 position（自愈判定：长时间无新帧 = 卡死）。
  void notePosition(Duration pos) {
    if (pos <= Duration.zero) return;
    _markStarted();
    final key = '${pos.inMilliseconds ~/ 500}';
    if (_lastPositionKey != null && _lastPositionKey == key) return;
    _lastPositionKey = key;
    // position 前进即视为恢复
    _onResume();
  }
}
