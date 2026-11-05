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
///
/// ## 为什么从 2000ms 放宽到 6000ms（2026-11-01 用户实报「画面断断续续」）
///
/// 2 秒判死对低延时 HLS 直播是错的：
/// - 分片本身 1s（hls_fragment 1），播放器必须缓存 2~3 片才能连续出帧；
/// - 网络抖动（实测 RTT 18~105ms、带宽波动数倍）会让某次分片请求超过 2s；
/// - 此时 mpv 状态是 buffering=true，但它是在正常补数据，不是卡死。
///
/// 2 秒就判死 ⇒ 每次网络稍有波动就重建播放器 ⇒ 重建要重新握手 + 拉 playlist
/// （几秒黑屏）⇒ 用户看到「播放一会又黑，过一会才稳定」。
///
/// 6 秒依据：一次完整分片轮询（拉 m3u8 + 拉 1~2 个 ts）在实测抖动下最坏约 3~4s，
/// 留 50% 余量。真正卡死（流断 / 地址不可达）依然会在 6s 内被发现并进入有界重建
/// （B2 的时间窗重置保证不会永久卡住）。
const int kStallTimeoutMs = 6000;
/// 重建冷却同样放宽：重建一次要重新握手（volx 实测 TLS 握手 0.4~4.9s），
/// 4s 冷却会让两次重建叠在一起。8s 覆盖「一次重建真正完成」的时间。
const int kRebuildCooldownMs = 8000;

/// 连续自动重建上限（**本项目新增，web 无对应**）。
///
/// 为什么必须有：地址不可达时（TLS 被重置 / 404 / 流未起）mpv 的状态是
/// `playing=true, buffering=true, position=0` 且**不抛异常** —— 旧实现每 2s 重建一次，
/// 永远停在「黑屏 + 转圈」，用户看不到错误也无从重试（2026-10-18 用户实报截图）。
/// 现在：连续 [kMaxAutoRebuilds] 次仍未起播 ⇒ 上报错误 ⇒ UI 显示「播放失败 + 重试」；
/// 人手重试会重置计数（不设上限）。
///
/// ⚠️ **封顶 ≠ 永久放弃**：封顶只是「本轮不再盲试」，随后由
/// [kRebuildCountResetWindow] 的时间窗重置 + 延迟重试重新开一轮
/// （开发文档 §3 B2；需求 §5.1 S2「自愈失败后必须有界重试，不得永久放弃」）。
const int kMaxAutoRebuilds = 2;

/// 连续失败的时间窗重置窗口（开发文档 §3 B2 的 `kRebuildCountResetWindow`）。
///
/// ## 为什么必须有（用户实报「过一会才恢复**甚至不恢复**」的 B2 那一半）
/// 旧实现（`hls_player.dart` 改前的 `_autoRebuild`）在
/// `_autoRebuilds >= maxAutoRebuilds` 时**只**调 `onError` 后 `return`：
/// - `_autoRebuilds` 只在真正起播（position 前进）时清零；
/// - 一旦封顶，**没有任何后续重试路径** ⇒ 网络抖动几秒就永久停在「播放失败」，
///   必须用户手动点重试（需求 §3.1 B2 / §5.1 S2）。
///
/// ## 语义
/// 距**上次失败**超过本窗口 ⇒ 视为新一轮，计数归零（不是永久封顶）；
/// 封顶时再排一个本窗口后的延迟重试（[_scheduleRetryAfterCooldown]）。
/// 60s 的选择来自开发文档 §3 B2 / §5.3：强于一次瞬时抖动、弱于用户放弃的耐心。
const Duration kRebuildCountResetWindow = Duration(seconds: 60);

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

  /// **非 fatal** 的分片级故障（分片 404 / 超时 / 解析失败）。
  ///
  /// 与 [onFatal] 的区别：hls.js 与 mpv/ExoPlayer 都会自行重试分片级失败，
  /// 这类事件不致命，但**此前 Ayla 完全丢弃它们** —— 分片持续失败时画面卡住，
  /// UI 却没有任何信号（与 Web 端 hls.ts 的 P1-4 是同一缺陷）。
  ///
  /// 语义约束（与 Web 对齐）：**只做观测上报，不改变播放器的恢复流程**。
  /// 调用方不得因收到本回调而中断播放或触发重建 —— 恢复仍由
  /// [onStall] / [onFatal] / 位置信号驱动。
  ///
  /// 默认 null（平台不实现即为「不观测」），不影响任何现有行为。
  void Function(String detail)? onFragmentError;

  /// 挂载并初始化播放器（不自动播放，由调用方 [play]）。
  Future<void> attach(String url);

  /// 开始播放（live 起播尽量贴近边缘）。
  Future<void> play();

  /// 跳到直播最新；成功返回 true，失败返回 false（调用方重建兜底）。
  Future<bool> seekToLiveEdge();

  /// 视频渲染视图（无画面需求的场景返回 null，如纯音频链路）。
  Widget? buildView();

  /// 设置静音 / 取消静音（= web 的 video.muted）。
  ///
  /// ## 为什么是**必填**成员而不是可选能力接口
  /// 音量不是「有就用」的增强：任何平台播放器都有音量，漏实现就等于直播永远满音量。
  /// 所以这里定成抽象成员，平台实现必须给出明确落地
  /// （Windows = mpv 音量 0/100；Android/iOS = 0.0/1.0）。
  ///
  /// 实现纪律：**不得抛异常**。静音只是「没生效」，不能让它打断挂载与起播
  /// （画面优先于声音，与 [HlsPlaybackController] 的自愈状态机同一条优先级）。
  Future<void> setMuted(bool muted);

  /// 销毁（幂等）。
  Future<void> dispose();
}

/// 可选能力：平台播放器能报出**画面宽高比**（= web `<video>.videoWidth/videoHeight`）。
///
/// ## 为什么是独立接口而不是给 [HlsPlatformPlayer] 加成员
/// [HlsPlatformPlayer] 有 5 个测试替身用 `implements` 实现它 —— 给抽象类加成员会让
/// 那些替身全部编译失败。这里用**可选能力接口**：实现了就报，没实现就当「不知道」，
/// 调用方一律按 null 处理（`media_kit` 就是这一类：它自己的 `Video` 已经
/// `BoxFit.contain`，不需要外部再收一次，见 `widgets/live/video_contain.dart`）。
abstract class HlsVideoMetrics {
  /// 当前画面宽高比（宽 / 高）；未知（未初始化 / 无画面）⇒ null。
  double? get videoAspectRatio;
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
    this.rebuildCountResetWindow = kRebuildCountResetWindow,
  });

  final HlsPlatformPlayer Function() _makePlatform;
  final HlsPlayerCallbacks _events;

  /// 卡顿判定窗口（默认 [kStallTimeoutMs]）。
  final Duration stallTimeout;

  /// 两次自动重建的最小间隔（默认 [kRebuildCooldownMs]）。
  final Duration rebuildCooldown;

  /// 连续自动重建上限（默认 [kMaxAutoRebuilds]）。
  final int maxAutoRebuilds;

  /// 连续失败计数的时间窗重置窗口（默认 [kRebuildCountResetWindow]）。
  final Duration rebuildCountResetWindow;

  HlsPlatformPlayer? _player;
  String? _currentUrl;
  HlsState _state = HlsState.idle;
  HlsState get state => _state;

  /// 当前视频渲染视图（平台实现给出；未挂载返回 null）。
  Widget? get videoView => _player?.buildView();

  /// 当前画面宽高比（平台实现实现 [HlsVideoMetrics] 才有值；见该接口说明）。
  ///
  /// 消费者：`AylaLivePlayer` 用它把播放面收成等比盒（= `object-fit: contain`），
  /// 避免全屏时把 16:9 的画面拉伸成手机屏幕比例。
  double? get videoAspectRatio {
    // 声明成 `Object?`：这样 `is HlsVideoMetrics` 才能把它提升成该类型
    // （两个抽象类互不为子类，声明成 `HlsPlatformPlayer?` 时不会发生提升）
    final Object? player = _player;
    if (player is HlsVideoMetrics) return player.videoAspectRatio;
    return null;
  }

  /// 当前是否静音（控制器记住的偏好状态；见 [_muted]）。
  bool get isMuted => _muted;

  /// 设置静音 / 取消静音，并**记住**该状态。
  ///
  /// 幂等：重复设同一个值仍会重新下发一次 —— 平台实例可能刚被重建、或上一次下发
  /// 时实例还没建好，重复下发是唯一能自愈的写法，代价只是一次属性写。
  /// 不抛异常（[HlsPlatformPlayer.setMuted] 的契约）：静音失败不能让播放链路崩。
  Future<void> setMuted(bool muted) async {
    _muted = muted;
    final HlsPlatformPlayer? p = _player;
    if (p == null) return;
    try {
      await p.setMuted(muted);
    } catch (e) {
      // 平台实例已释放 / 属性不可写 ⇒ 只记日志：静音是「没生效」，不是播放失败。
      _log('下发静音失败（$muted）：$e');
    }
  }

  /// 切换静音（音量键的语义）。
  Future<void> toggleMuted() => setMuted(!_muted);

  String? _lastPositionKey; // 上一次 position 快照（自愈判定用）
  Timer? _stallTimer;
  DateTime _lastRebuildAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 连续自动重建次数（真正起播即清零；见 [kMaxAutoRebuilds]）。
  int _autoRebuilds = 0;

  /// 上一次「失败」（一次自动重建 / 封顶上报）发生的时刻。
  ///
  /// 判据是 [rebuildCountResetWindow]：距此超过窗口 ⇒ 视为新一轮、计数归零
  /// （B2；见 [kRebuildCountResetWindow] 的根因说明）。
  DateTime _lastFailureAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 封顶后的延迟重试计时器（B2；[destroy] / [dispose] 必须取消）。
  Timer? _retryTimer;

  /// 正在重建（防重入）。
  ///
  /// 为什么需要：封顶后的延迟重试与「卡顿计时器重排」「fatal 自动重建」三条路径可能
  /// 在同一时刻撞上 —— 旧实现没有防重入，两个并发的 `rebuild()` 会各自
  /// `dispose()` 一次、再各建一个平台播放器 ⇒ 前者刚挂上就被后者 dispose，
  /// 表现为「刚有画面又黑了」（B2/B3 共同的假象来源）。
  bool _rebuilding = false;

  /// 本次挂载是否已真正出过画面（位置前进过）。
  bool _started = false;

  /// 当前是否静音（**控制器记住的状态**，不是平台播放器的瞬时值）。
  ///
  /// ## 为什么必须由控制器持有（2026-11-04 需求的关键点）
  /// 自愈重建（[rebuild]）与每次 [attach] 都会 **new 一个平台播放器**
  /// （`_makePlatform()`），新实例的音量是平台默认值（mpv 100 / video_player 1.0）
  /// ⇒ 只要不同步重新下发，**重建一次就恢复满音量**：用户明明静音了，画面黑一下
  /// 自愈之后声音又炸出来。所以状态记在这里，[attach] 里每建好一个实例就立刻回放。
  ///
  /// 默认 `false`（不静音）：平台播放器自身的默认态就是有声，控制器不必额外下发一次。
  bool _muted = false;

  /// 平台播放器实例是否**健康**（B3）。
  ///
  /// ## 为什么幂等条件不能只比 URL（开发文档 §3 B3）
  /// 旧实现：`if (_player != null && _currentUrl == url) return;`
  /// —— URL 没变但**平台实例已经死了**（mpv 进程侧 EOF/错误、ExoPlayer 的
  /// Source error 之后内部播放器处于不可用状态）时，attach 永远幂等跳过
  /// ⇒ 永久黑屏，点刷新、退出重进以外的任何操作都不恢复（需求 §3.1 B3）。
  ///
  /// 置 true 的时机：平台真的出过画面 —— [onPosition] 上报位置前进，
  /// 或 [onStateChange] 进入 playing（见 [_onPlatformState] 的说明：
  /// playing 单独不足以判定"有画面"，但**足以判定"实例还活着"**）。
  /// 置 false 的时机：[attach] 新建实例、[rebuild]、[destroy]、平台 fatal。
  bool _platformHealthy = false;

  void _log(String line) => _events.onLog?.call('[hls] $line');

  void _setState(HlsState s) {
    _state = s;
    _events.onStateChange?.call(s);
  }

  /// 挂载播放器并开始播放。
  ///
  /// ## 幂等条件（B3，开发文档 §3 B3）
  /// **相同 url 且平台实例仍健康** ⇒ 直接返回（切场景零黑屏）；
  /// 相同 url 但实例**不健康** ⇒ 必须强制重建，否则永久黑屏（需求 §5.1 S3
  /// 「播放器实例失效必须能被检测并强制重建」）。
  ///
  /// ⚠️ 走的是「先释放再新建」的完整路径，**不递归调用自己** —— 健康标志在
  /// 本方法开头就复位成 false，跑完这条路径自然就是"重建"；若在这里回调
  /// [rebuild] 会再次进入 attach（rebuild 内部也调 attach），可能无限递归。
  Future<void> attach(String url) async {
    if (_player != null && _currentUrl == url) {
      if (_platformHealthy) {
        _log('attach 幂等跳过（$url 已挂载且实例健康）');
        return;
      }
      // B3：URL 没变但实例已死 ⇒ 幂等命中也要真的重建。
      _log('attach 幂等命中但实例不健康 ⇒ 强制重建（$url）');
    }
    await _player?.dispose();
    _player = null;
    // B3：新实例的健康状态一律从 false 起算 —— 只有真的出画面/进 playing 才置真。
    _platformHealthy = false;
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
    p.onFragmentError = _onFragmentError;
    try {
      await p.attach(url);
      // ⚠️ **每次 attach 之后必须重新下发静音**（2026-11-04 需求的关键点）：
      // `_makePlatform()` 每次都是**新的平台播放器**，音量回到平台默认（有声）。
      // 自愈重建走 [rebuild] → [attach]，同样经过这里 ⇒ 一处下发覆盖所有重建路径。
      // 放在 play() 之前：先静音再出声，避免重建后有一瞬间满音量的声音漏出来。
      if (_muted) await setMuted(true);
      await p.play();
    } catch (e) {
      _events.onError?.call('播放器挂载失败: $e');
    }
  }

  void _onPlatformState(HlsState s) {
    _setState(s);
    // B3：playing 说明平台实例**还活着**（能推进播放状态机）——
    // 它不足以证明「有画面」（mpv 连上但没数据时 playing 同样为真），
    // 但对 attach 的幂等判定来说，这个证据已经足够：实例死了不会报 playing。
    if (s == HlsState.playing) _platformHealthy = true;
    // ⚠️ **不要**在 playing 时无条件 `_onResume()`：mpv 在「连上但没数据」时同样
    // `playing=true`，把它当恢复会取消卡顿计时器 ⇒ 永远停在转圈（用户实报现象）。
    // 恢复只由「位置前进」或「已起播后缓冲结束」驱动。
    if (s == HlsState.playing && _started) _onResume();
  }

  /// 平台播放位置上报（见 [HlsPlatformPlayer.onPosition]）。
  void _onPlatformPosition(Duration pos) => notePosition(pos);

  /// 位置前进 = 真的出画面（[HlsPlatformPlayer.onPosition]）。
  void _markStarted() {
    // B3：位置前进是最强证据 —— 实例不仅活着，而且真的在出画面。
    _platformHealthy = true;
    if (_started) return;
    _started = true;
    _autoRebuilds = 0;
  }

  /// 自动重建（带次数上限；超限上报错误 + **排延迟重试**，不再永久放弃）。
  ///
  /// ## B2（开发文档 §3 B2；需求 §3.1 B2 / §5.1 S2）
  /// 旧实现封顶后只 `onError` 就 `return`：没有时间窗重置、没有后续重试
  /// ⇒ 「连续 2 次自动重建仍无画面」就永久停在「播放失败」，
  /// 网络抖动几秒也会触发（用户实报「过一会才恢复**甚至不恢复**」）。
  ///
  /// 现在两条出路：
  /// 1. **时间窗重置**：距上次失败 ≥ [rebuildCountResetWindow] ⇒ 本轮计数归零；
  /// 2. **封顶后延迟重试**：`onError`（UI 照常显示「播放失败 + 重试」，人不必干等）
  ///    **并且**排一个窗口后的 [_scheduleRetryAfterCooldown]，到点自己再来一轮。
  ///
  /// `_rebuilding` 是防重入闸门（见该字段注释）：并发进入时后来者直接放弃 ——
  /// 它要做的重建已经有人在做。
  Future<void> _autoRebuild(String url, String reason) async {
    if (_rebuilding) {
      _log('已有重建在进行中，跳过本次自动重建：$reason');
      return;
    }
    // 时间窗重置：距上次失败超过窗口 ⇒ 视为新一轮，计数归零（不是永久封顶）。
    final bool newRound =
        DateTime.now().difference(_lastFailureAt) >= rebuildCountResetWindow;
    if (newRound) {
      if (_autoRebuilds > 0) {
        _log('距上次失败已超过 ${rebuildCountResetWindow.inSeconds}s ⇒ 重建计数归零');
      }
      _autoRebuilds = 0;
    }
    _lastFailureAt = DateTime.now();
    if (_autoRebuilds >= maxAutoRebuilds) {
      _log('自动重建已达上限（$maxAutoRebuilds）→ 上报错误并排延迟重试：$reason');
      _events.onError?.call(reason);
      // ★ B2 的关键：不再 `return` 了事，窗口后再来一轮。
      _scheduleRetryAfterCooldown(url);
      return;
    }
    _autoRebuilds += 1;
    _log('第 $_autoRebuilds/$maxAutoRebuilds 次自动重建：$reason');
    await rebuild(url);
  }

  /// 封顶后的延迟重试（B2；开发文档 §3 B2 的 `_scheduleRetryAfterCooldown`）。
  ///
  /// 为什么延后一个 [rebuildCountResetWindow] 而不是立刻重试：
  /// 1. 封顶意味着「短时间内连续失败」，立刻再来只会继续失败并刷日志/刷错误；
  /// 2. 等一个窗口后 [_autoRebuild] 的时间窗重置会**天然**把计数归零，
  ///    于是这一轮重试又是一次完整的「有界」尝试（有界 + 可恢复，需求 §5.2）。
  ///
  /// 幂等：重复调用只保留最后一个计时器（`_retryTimer?.cancel()`）。
  /// URL 变了 / 会话销毁了 ⇒ 到点直接放弃（不再替新地址重建）。
  void _scheduleRetryAfterCooldown(String url) {
    _retryTimer?.cancel();
    _retryTimer = Timer(rebuildCountResetWindow, () {
      _retryTimer = null;
      if (_currentUrl != url) return;
      _autoRebuilds = 0;
      _log('时间窗后自动重试：$url');
      unawaited(_autoRebuild(url, '时间窗后自动重试'));
    });
  }

  /// 取消封顶后的延迟重试（[destroy] / [dispose] / 手动重试成功时调用）。
  void _clearRetryTimer() {
    _retryTimer?.cancel();
    _retryTimer = null;
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
  ///
  /// ⚠️ B2：**冷却期外一律交给 [_autoRebuild]**（不再自己带「次数未超上限」的判定）
  /// —— 封顶判定与「封顶后排延迟重试」只允许有**一处**。
  /// 旧实现在这里提前走到 `else → onError` 就返回了，于是「fatal 打满上限」这条最常见的
  /// 失败路径**永远排不出重试**（用户看到的就是永久「播放失败」，需求 §3.1 B2）。
  void _onFatal(String detail) {
    _clearStallTimer();
    // B3：fatal = 平台实例已经不可用；幂等条件必须随之失效，
    // 否则下一次同 URL 的 attach 会被 `_currentUrl == url` 挡住（永久黑屏）。
    _platformHealthy = false;
    final String? url = _currentUrl;
    if (url == null) {
      _events.onError?.call(detail);
      return;
    }
    if (DateTime.now().difference(_lastRebuildAt) >= rebuildCooldown) {
      _log('fatal: $detail → 自动重建');
      unawaited(_autoRebuild(url, detail));
      return;
    }
    // 冷却期内不重建，但先报错给 UI；若已封顶还要排上延迟重试，
    // 保证「任何失败路径都有后续」（B2 的不变量）。
    _lastFailureAt = DateTime.now();
    if (_autoRebuilds >= maxAutoRebuilds) _scheduleRetryAfterCooldown(url);
    _events.onError?.call(detail);
  }

  void _clearStallTimer() {
    _stallTimer?.cancel();
    _stallTimer = null;
  }

  /// 非 fatal 的分片级故障（P1-4，与 Web hls.ts 的 onFragmentError 同语义）。
  ///
  /// **只记录日志，不做任何状态迁移**：hls.js / mpv / ExoPlayer 都会自行重试
  /// 分片级失败，这里的作用是让「分片在持续失败」这件事从不可见变成可见
  /// （此前完全丢弃，画面卡住时 UI 毫无信号）。
  ///
  /// 显式约束：**不得**在此触发重建、上报错误或改动 [_stallTimer] ——
  /// 恢复路径只允许由 [onStall]/[onFatal]/位置信号驱动，否则会把
  /// 「播放器自己能恢复的抖动」误判成故障。
  void _onFragmentError(String detail) {
    _log('分片级故障（已由播放器自行重试）: $detail');
  }

  /// 强制重建（绕过幂等：先 dispose 再 attach）。
  ///
  /// [manual] = 用户点「重试」：**重置自动重建计数**（人手重试不设上限；
  /// 否则自动封顶后手动重试也会立刻报错）。
  ///
  /// ## 三重防护（B2 + B3）
  /// 1. **防重入**：重建期间再有请求进来直接返回（否则两个并发 rebuild 会互相
  ///    dispose 对方的实例，画面刚出来又黑）；
  /// 2. **B3 健康标志复位**：新实例在真的出画面之前一律按「不健康」算 ⇒ 这段时间里
  ///    若有人再用同一 URL 调 attach，不会被幂等跳过；
  /// 3. 清理 B2 的延迟重试计时器：既然现在就在重建，那个「窗口后再试」已经多余
  ///    （留着会在窗口后凭空再来一次重建，等于双倍抖动）。
  Future<void> rebuild(String url, {bool manual = false}) async {
    if (_rebuilding) {
      _log('已在重建中，忽略重复的 rebuild 请求（$url）');
      return;
    }
    _rebuilding = true;
    try {
      _clearRetryTimer();
      if (manual) {
        _autoRebuilds = 0;
        _started = false;
      }
      // B3：实例即将被释放，健康标志必须立刻失效。
      _platformHealthy = false;
      await _player?.dispose();
      _player = null;
      await attach(url);
    } finally {
      _rebuilding = false;
    }
  }

  /// 用户主动重试（重置自愈计数后重建）。
  Future<void> retry(String url) => rebuild(url, manual: true);

  /// 让平台播放器继续播（App 回到前台时用；B5 的**移动端**那一半）。
  ///
  /// ## 为什么需要（开发文档 §3 B5 / 需求 §5.1 S5 / G3）
  /// Windows 侧靠 media_kit `Video` 的 resumeUponEnteringForegroundMode 自动恢复
  /// （见 `media_kit_impl.dart` 的 buildView）。但**移动端没有这对参数**：
  /// `video_player` 的 `VideoPlayer` widget 不接受生命周期配置，切后台后
  /// ExoPlayer/AVPlayer 会被系统停下或丢掉 surface ⇒ 回到前台是一张黑画面。
  ///
  /// 这里只做最小动作：让平台层 play() 一次；**不重建**（重建是几秒黑屏 + 重新握手，
  /// 只在确实播不动时由自愈状态机 / 刷新键来做）。已经 playing 时是 no-op。
  Future<void> resumePlayback() async {
    final HlsPlatformPlayer? p = _player;
    if (p == null) return;
    if (_state == HlsState.playing) return;
    try {
      await p.play();
    } catch (_) {
      // 平台实例已不可用 ⇒ 交给自愈状态机（卡顿计时器）/ B3 健康判定兜底。
    }
  }

  /// 跳到直播**真实边缘**（刷新键）。
  ///
  /// ## R1（开发文档 §3 R1；需求 §3.3 R1 / §5.3 I1）
  /// 语义落在平台实现的 [HlsPlatformPlayer.seekToLiveEdge] 上：
  /// · media_kit：读 mpv 的 `seekable-ranges`，目标 = 最后一段 `end - 2s`；
  /// · video_player：Dart 侧没有 seekable API ⇒ `duration - 2s` 兜底。
  /// 两者都由 `lib/player/live_edge.dart` 的纯函数算出目标（可单测）。
  ///
  /// **兜底顺序固定为「先 seek，失败才 rebuild」**（开发文档 §3 R3）：
  /// 顺手重建一次就是几秒黑屏 + 重新握手，能 seek 就不要重建。
  ///
  /// ⚠️ 旧实现的第一行是 `if (p == null) return;` —— 播放器实例缺失时刷新键
  /// **什么都不做**（用户点了没反应）。现在改为走重建兜底：那正是「实例没了」
  /// 的唯一正确处置（与 B3 的强制重建同一个语义）。
  Future<void> refreshToLiveEdge() async {
    final HlsPlatformPlayer? p = _player;
    if (p != null) {
      final bool ok = await p.seekToLiveEdge();
      if (ok) return;
      _log('贴边 seek 失败 ⇒ 重建兜底（先 seek 失败才 rebuild）');
    } else {
      _log('播放器实例缺失 ⇒ 刷新走重建兜底');
    }
    final String? url = _currentUrl;
    if (url == null) return;
    // 走「手动」语义：用户亲手点刷新，计数归零（同 retry）。
    await rebuild(url, manual: true);
  }

  /// 销毁（幂等）。
  ///
  /// ⚠️ **必须取消 B2 的延迟重试计时器**：它是 60s 级别的 Timer，句柄挂在
  /// 本对象上；不取消的话，会话已经销毁 60s 后它仍会触发一次重建 —— 轻则白白
  /// 起一个平台播放器再 immediately 被丢（日志噪音 + 一次真实拉流），重则
  /// 在已 dispose 的会话上写状态（`used after being disposed`）。
  Future<void> destroy() async {
    _clearStallTimer();
    _clearRetryTimer();
    await _player?.dispose();
    _player = null;
    _currentUrl = null;
    _autoRebuilds = 0;
    _started = false;
    // B3：没有实例了 ⇒ 健康状态回到「未知/不健康」。
    _platformHealthy = false;
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
