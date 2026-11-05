/// HLS 平台实现：media_kit（Windows/mpv 内核）。
///
/// - mpv 运行库经 media_kit_libs_windows_video 打包（CMake 构建时校验
///   build/windows/x64/mpv-dev-*.7z 的 MD5，匹配则跳过下载）；
/// - 事件：player.stream.playing/buffering/error/position 映射为
///   onStateChange/onStall/onResume/onFatal 信号；
/// - 视图：VideoController + Video widget（media_kit_video）。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/net/live_play_url.dart'
    show aylaIsVolxPullHost, kAylaVolxPullSniHost;
import '../hls_player.dart';
import '../live_edge.dart';
import '../texture_size.dart';

class MediaKitHls implements HlsPlatformPlayer {
  @override
  void Function(HlsState state)? onStateChange;

  @override
  void Function()? onStall;

  @override
  void Function()? onResume;

  @override
  void Function(String detail)? onFatal;

  @override
  void Function(String detail)? onFragmentError;

  @override
  void Function(Duration position)? onPosition;

  Player? _player;
  VideoController? _videoController;
  final List<StreamSubscription> _subs = [];
  bool _initialized = false;

  /// 纹理尺寸决策器（B4；`dispose` 时取消其去抖计时器）。
  AylaTextureSizeDecider? _sizeDecider;

  /// 是否已经真正出过画面（position 前进过）。
  ///
  /// **B4 的前置条件**：`VideoController.setSize()` 只能在 `VideoOutput` 已注册后调用，
  /// 而注册发生在 `Video` widget 首次 build（即真的开始渲染）。attach 阶段还没 build，
  /// 此时下发 setSize 会命中未注册的 handle ⇒ 原生段错误（详见 attach 里的说明）。
  /// position 前进是「已经出帧」最可靠的判据（mpv 在没数据时 position 恒 0）。
  bool _hasRenderedFrame = false;

  /// 起播计时（诊断用；`[AYLA-BOOT]` 打点，用户看不到）。
  static final Stopwatch _bootWatch = Stopwatch();

  @override
  Future<void> attach(String url) async {
    _bootWatch.reset();
    _bootWatch.start();
    if (!_initialized) {
      MediaKit.ensureInitialized();
      _initialized = true;
    }
    debugPrint('[AYLA-BOOT] init=${_bootWatch.elapsedMilliseconds}ms');
    final p = Player();
    _player = p;
    _videoController = VideoController(p);

    _subs.add(p.stream.playing.listen((v) {
      onStateChange?.call(v ? HlsState.playing : HlsState.buffering);
      if (v) onResume?.call();
    }));
    _subs.add(p.stream.buffering.listen((v) {
      if (v) {
        onStall?.call();
        onStateChange?.call(HlsState.buffering);
      }
    }));
    _subs.add(p.stream.error.listen((e) {
      onFatal?.call(e);
    }));
    // 非 fatal 的分片级故障（P1-4）：mpv 把「分片拉取失败但已自行重试」记在
    // 日志里而不是 error 流里 —— 只上报 error 会让这类事件完全不可见。
    // 只观测 mpv/ffmpeg 的 hls 与网络相关行，避免日志噪音；
    // **不改变任何恢复行为**（重试仍由 mpv 自己做）。
    _subs.add(p.stream.log.listen((entry) {
      final text = entry.text;
      if (text.isEmpty) return;
      final lower = text.toLowerCase();
      final looksLikeSegmentFailure =
          (lower.contains('hls') || lower.contains('segment')) &&
          (lower.contains('failed') ||
              lower.contains('error') ||
              lower.contains('404') ||
              lower.contains('timeout'));
      if (looksLikeSegmentFailure) {
        onFragmentError?.call(text);
      }
    }));
    // 位置前进 = 真的出画面（mpv 在「连上但没数据」时 playing 也为 true，
    // 不能只靠 playing 判定 —— 见 hls_player.dart 的 kMaxAutoRebuilds 注释）。
    _subs.add(p.stream.position.listen((pos) {
      // B4 的门槛：真的出过画面之后才允许 setSize（见 [_hasRenderedFrame]）。
      // 首次 position 前进时补发一次当前分辨率 —— 订阅期间可能已经上报过 width/height，
      // 但那时被 `_hasRenderedFrame == false` 挡住了，这里补上。
      if (!_hasRenderedFrame && pos > Duration.zero) {
        _hasRenderedFrame = true;
        debugPrint('[AYLA-BOOT] firstFrame=${_bootWatch.elapsedMilliseconds}ms');
        _sizeDecider?.offer(p.state.width, p.state.height);
      }
      onPosition?.call(pos);
    }));

    // ---- 【B4】把纹理尺寸钉在**视频原生分辨率**上 -------------------------------
    //
    // 为什么必须做（开发文档 §3 B4，Flutter 独有）：media_kit_video 的
    // VideoOutput::CheckAndResize() 在「视频要求尺寸 ≠ 当前纹理尺寸」时会
    // UnregisterTexture + 新建纹理（third_party/media_kit_video/windows/
    // video_output.cc:241–266），而 GetVideoWidth() 在 width_ 为空时读的是
    // video-out-params 的 dw/dh ⇒ 窗口尺寸变化让 mpv 重算输出参数 ⇒ 纹理被注销重建
    // ⇒ 用户看到「窗口一动就闪黑/黑屏」。显式 setSize() 之后 required 恒定
    // ⇒ CheckAndResize 恒走 early-return（:261–264）⇒ 不再重建纹理。
    //
    // 只在**分辨率真的变化时**调（同分辨率重复调 setSize 无意义），并做 200ms 去抖
    // （一次切换会连续上报 width/height 两次，见 AylaTextureSizeDecider 的说明）。
    // ⚠️ 必须同时监听 width 与 height：两条流各自只在**自己**变化时触发，
    // 若只监听 width，则「先到 width、height 随后才到」的那一轮永远配不上高度。
    // ⚠️⚠️ **B4 在 attach 阶段完全不启用**（2026-11-01 崩溃根因，第二次）
    //
    // 段错误机制（退出码 139，无 Dart 堆栈）：
    // `VideoController.setSize()` → `NativeVideoController.setSize`
    // （third_party/media_kit_video/.../native_video_controller/real.dart:204）
    // 会 `await player.handle` 后立刻 `_channel.invokeMethod('VideoOutputManager.SetSize')`。
    // 而 Windows 侧 `VideoOutputManager::SetSize`（video_output_manager.cc:30-37）：
    // ```cpp
    // if (video_outputs_.find(handle) != video_outputs_.end())
    //   video_outputs_[handle]->SetSize(width, height);
    // ```
    // **VideoOutput 的注册发生在 `Video` widget 首次 build 时**（Create → 注册），
    // 而 attach 阶段还没 build ⇒ 若此处并发调用 setSize，原生侧 handle 未就绪，
    // 在部分构建里就是访问无效指针 ⇒ SIGSEGV。
    //
    // 结论：**setSize 只能在播放器真正出帧之后调用**（此时 VideoOutput 必然已注册）。
    // 本方法先完全不碰 setSize；B4 的正确实现见 `_maybeApplyTextureSize`（在
    // 首个 position 前进后才允许下发）。
    // B4 整体禁用（2026-11-01 决定性实验）：setSize 会驱动原生 VideoOutput::Resize()
    // 销毁并重建纹理，是播放路径上唯一会改写渲染管线状态的调用，优先排除。
    _sizeDecider = null;

    // ---- 拉流入口的证书主机名声明（Windows 裸 IP 直连）------------------------
    //
    // 背景见 core/net/live_play_url.dart：Windows 的直播地址被重写到 volx 裸 IP
    // （47.108.85.223:7882），而那里的证书 SAN 是 *.trise.top ⇒ 用 IP 连接必然
    // hostname mismatch。
    //
    // ⚠️ 实测结论（2026-11-01，直接驱动本仓库打包的 libmpv-2.dll）：这个
    // ffmpeg/mbedTLS 构建**默认就不校验证书**（expired / self-signed / wrong-host
    // 三个必坏证书全部握手通过）；反过来打开校验（tls_verify=1）连 example.com 都
    // 握手失败，因为该构建没有可用的 CA 源。所以裸 IP 本来就是通的，
    // **这里不是靠 tls_verify=0 才生效的**。
    //
    // 那为什么还要设？这里只设 verifyhost：
    // 1. 它是 lavf 里**唯一**能「在仍校验证书链的前提下，把比对的主机名换成证书
    //    真正覆盖的名字」的入口（tls_host_name 在本构建中并不存在，实测被当作未知
    //    选项静默忽略）。裸 IP 的证书比对必然失败，声明 verifyhost=live.trise.top
    //    之后，证书若真被校验，比对的是域名而不是 IP。
    // 2. 将来换一版「默认开启校验」的 ffmpeg 时，这行不会变成死代码，也不会因为
    //    IP 不匹配而直接黑屏。
    //
    // **刻意不设 tls_verify=0**：那会在真能校验的构建上把校验关掉，属于安全降级；
    // 当前构建本来就不校验，设了等于没设，却会误导后人以为「为了连上才关的」。
    // 也不追加 tls-ca-file：实测导出的 Windows 根证书被
    // mbedtls_x509_crt_parse_file ... returned 2 拒绝，写进去只会制造假象。
    // ---- 起播加速（2026-11-02 用户实报「Windows 比手机慢 2~3 秒」）------------
    //
    // 实测差距来源（不是网络）：
    // · 首片下载两端只差 162ms（Windows 494ms / Android 332ms）；
    // · 但 Windows 多了一步**串行等待**：setProperty 默认
    //   waitForInitialization=true ⇒ 先 await mpv 初始化才设属性，
    //   然后才 open ⇒ 起播被推迟数百毫秒；
    // · mpv/ffmpeg 的 HLS demuxer 初始化比 ExoPlayer 重（ANGLE 上下文 +
    //   FFmpeg 全量探测），默认 probesize/analyzeduration 会多花约 1s。
    //
    // 三项优化（都不改变播放语义，只改「多久出第一帧」）：
    //
    // ① verifyhost 不阻塞起播：它当前**实际无效**（该 ffmpeg 构建默认不校验
    //    证书，实测三张必坏证书全部通过），保留只为「将来换会校验的构建时不会
    //    因 IP 不匹配而失败」。既然无效，就不该让它排在 open 前面 ——
    //    改成 open 之后异步补，起播路径上少一次 await。
    // ② analyzeduration / probesize 收紧：ffmpeg 默认会「多读一段再判定流格式」，
    //    直播场景不需要这么保守。1000000us(1s) + 500KB 足够识别 H264/AAC，
    //    实测能省下数百毫秒。
    // ③ cache-pause-initial=no：默认 mpv 会「先缓冲再播」，直播应立刻出帧。
    // ⚠️ **`demuxer-lavf-o` 必须保留 media_kit 自己的默认项**（2026-11-02 实测定论）。
    //
    // media_kit 1.2.6（real.dart:2428-2433）在 Player 初始化时写：
    //   seg_max_retry=5, strict=experimental, allowed_extensions=ALL, protocol_whitelist=[...]
    // 这是 mpv 属性，**同名属性后写覆盖前写** ⇒ 上一版只写
    // analyzeduration/probesize 就把它们全冲掉了。
    //
    // **seg_max_retry=5 丢失是致命的**：HLS 分片偶发 404（volx 隧道下实测 5 次 1 次）
    // 时不再重试 ⇒ ffmpeg 卡住等超时 ⇒ 起播从 ~1s 变成 5~6s。
    // 实测证据：[AYLA-BOOT] opened=505ms 之后 6 秒内 ffmpeg **零日志输出**
    // （不是在下载，是在等），然后才 firstFrame=6459ms。
    // ---- HLS 起播位置：必须从**最后一个分片**开始（2026-11-02 实测）------
    //
    // FFmpeg 的 HLS demuxer 默认 `live_start_index = -3`（从边缘前 3 片起播）。
    // 而 SRS 的 playlist 有 hls_window 秒之多（当前 window=60 + fragment=1 ⇒ **61 片**），
    // -3 意味着要先把前面 58 片的位置「跳过去」，加上 media_kit 默认
    // `cache=yes` + `demuxer-max-bytes=32MB` 会尝试填充缓存 ⇒
    // **起播要等好几秒**（实测 opened=172ms → firstFrame=3355ms，中间零 ffmpeg 日志）。
    //
    // `live_start_index=-1` = 直接从最后一个分片起播，这是「直播跟边缘」的正确语义，
    // 也是本项目 POC_README 里记过、但一直没落到代码里的那条。
    // ⚠️⚠️ **不要加 `live_start_index`**（2026-11-02 实测定论）。
    //
    // 试过 `live_start_index=-1`（想直接从最后一个分片起播）：
    //   Opening 次数 98 → **2**，之后 7.3 秒零 ffmpeg 日志，firstFrame 反而从
    //   3355ms 劣化到 7517ms。
    // 说明该参数在本 mpv/ffmpeg 构建 + SRS playlist（61 片）组合下**不兼容**：
    // 播放器只拉了 2 次 master m3u8 就停在那里，一个分片都不请求。
    //
    // 只保留「无害且有用」的重连/持久连接项。
    const String lavfBase = 'seg_max_retry=5,strict=experimental,'
        'allowed_extensions=ALL,http_persistent=1';
    await Future.wait(<Future<void>>[
      if (_isVolxPullUrl(url))
        _setMpvOption(p, 'stream-lavf-o',
            'verifyhost=$kAylaVolxPullSniHost'),
      _setMpvOption(p, 'demuxer-lavf-o',
          '$lavfBase,analyzeduration=1000000,probesize=500000'),
      _setMpvOption(p, 'cache-pause-initial', 'no'),
      // 缓存上限收紧：media_kit 默认 32MB，1080p 下能囤十几秒；
      // 直播只需「够播放即可」，囤多了反而让起播变慢、延时变大。
      _setMpvOption(p, 'cache-secs', '2'),
      _setMpvOption(p, 'demuxer-max-bytes', '8388608'),
    ]);

    debugPrint('[AYLA-BOOT] options=${_bootWatch.elapsedMilliseconds}ms');
    onStateChange?.call(HlsState.loading);
    await p.open(Media(url), play: true);
    debugPrint('[AYLA-BOOT] opened=${_bootWatch.elapsedMilliseconds}ms');
  }

  /// 下发纹理尺寸（B4；`VideoController.setSize` 内部会 await 平台实例，
  /// 失败（含已 dispose）不得让调用方崩 —— 尺寸固定是**优化**，不是播放的前提）。
  Future<void> _applyTextureSize(AylaTextureSize size) async {
    final VideoController? vc = _videoController;
    if (vc == null) return;
    try {
      await vc.setSize(width: size.width, height: size.height);
    } catch (_) {
      // 视频输出已销毁 / 平台不支持 ⇒ 忽略：纹理跟随视频分辨率，只是少了 B4 的保护。
    }
  }

  /// [url] 是否指向 volx 裸 IP 拉流入口（见 `core/net/live_play_url.dart`）。
  ///
  /// 只对裸 IP 生效：其他来源（含已经收敛到樱花的移动端地址）一律不碰 mpv 的
  /// lavf 选项，避免把「本来好好的普通 HTTPS 流」也加上主机名覆盖。
  static bool _isVolxPullUrl(String url) {
    final Uri? parsed = Uri.tryParse(url.trim());
    return parsed != null && aylaIsVolxPullHost(parsed.host);
  }

  /// 给内部 mpv 实例下发一个选项；失败**不得**让 attach 抛出去。
  ///
  /// 证书/网络选项是**起播的辅助条件**，不是前提：某些构建没有该选项、
  /// 或 player 已 dispose 时它只应该退化为「没有这层保护」，不能让直播直接黑屏。
  ///
  /// ## ⚠️⚠️ 绝不能传 `waitForInitialization: false`（2026-11-01 崩溃根因）
  ///
  /// `NativePlayer.setProperty`（media_kit 1.2.6 real.dart:1223）在
  /// `waitForInitialization: false` 时**跳过** `await waitForPlayerInitialization`，
  /// 直接执行：
  /// ```dart
  /// mpv.mpv_set_property_string(ctx, name.cast(), data.cast());
  /// ```
  /// 而 `ctx` 的声明是 `Pointer<generated.mpv_handle> ctx = nullptr`
  /// （real.dart:2658），只有在 `Player` 的构造初始化流程里（real.dart:2361
  /// `ctx = await Initializer(mpv).create(...)`）才会被赋成有效句柄。
  ///
  /// `attach()` 里 `Player()` 刚创建、紧接着就下发本选项 ⇒ `ctx` 仍是 **nullptr**
  /// ⇒ `mpv_set_property_string(nullptr, ...)` **原生层直接访问空指针**
  /// ⇒ **SIGSEGV（退出码 139）**，进程瞬间消失、**没有任何 Dart 异常/堆栈**
  /// （表现为用户实报的「一进直播间就闪退/卡死」）。
  ///
  /// 所以这里必须用默认值 `waitForInitialization: true`：它会先 await
  /// `waitForPlayerInitialization`，保证 `ctx` 已就绪再写属性。
  static Future<void> _setMpvOption(Player p, String key, String value) async {
    try {
      // `Player.platform` 的类型是 `PlatformPlayer?`（未初始化 / Web 上可能为空），
      // 这里必须先按可空接住再做类型提升 —— 直接声明成非空会让整个 lib 编译失败。
      final PlatformPlayer? platform = p.platform;
      if (platform is NativePlayer) {
        // ⚠️ 不传 waitForInitialization:false —— 见上面的崩溃根因说明。
        await platform.setProperty(key, value);
      }
    } catch (_) {
      // 选项不存在 / 原生侧拒绝 / 已 dispose ⇒ 忽略（见上面的注释）。
    }
  }

  @override
  /// 开始播放（**与手机端同构：先贴边、再播**）。
  ///
  /// ## 为什么必须在起播时贴边（2026-11-02 用户实报「电脑端比手机端慢 3 秒」）
  ///
  /// 手机端 `video_player_impl.play()` 做的是：
  /// ```dart
  /// final target = aylaLiveEdgeSeekTarget(duration: c.value.duration);
  /// if (target != null) await c.seekTo(target);   // ← 主动跳到直播边缘
  /// await c.play();
  /// ```
  /// 而本端原来只有一句 `await _player?.play()`，**从 playlist 靠前处开始解析**：
  /// SRS 的 playlist 有 hls_window 个分片（当前 60+1 片），mpv/ffmpeg 需要遍历、
  /// 请求、解码多个分片才出第一帧 ⇒ 实测 firstFrame 3355ms（手机端约 2s）。
  ///
  /// 贴边 seek 之后只需 1~2 个分片就能出画面，与手机端走同一条路径。
  ///
  /// ⚠️ 与 `live_start_index=-1`（已证伪、见 attach 里的说明）的区别：那个是
  /// demuxer 内部参数，会让播放器**不请求分片**；这里是播放器已就绪后的显式
  /// seek，走正常的 seek 管线。
  @override
  /// 开始播放。
  ///
  /// ## 起播前绝不能 seek（2026-11-02 两次实测证伪）
  ///
  /// 用户实报「电脑端比手机端慢 3 秒」，对比两端代码发现手机端 play() 里有
  /// `await c.seekTo(duration - 2s)`（贴边）而本端没有。但照搬到 mpv 行不通：
  ///
  /// - await p.seek(t) 再 await p.play()  =>  卡死：seek 永不返回（缓冲为空时
  ///   mpv 等的「定位完成」信号不会来）；Opening 98 -> 6，播放失败；
  /// - await p.play() 再 unawaited(p.seek(t))  =>  仍无效：Opening 98 -> 1，无画面。
  ///
  /// 根因：ExoPlayer 的 seekTo 是「发请求即返回」的异步语义，mpv 的 seek 是
  /// 「等定位完成」。在直播 HLS（playlist 几十片）上对 mpv 提前 seek 会打乱它
  /// 的起播分片选择逻辑，反而一个分片都不请求。
  ///
  /// 结论：本端保持「直接 play」（= 优化前已验证可播的形态，firstFrame 3355ms）。
  /// 贴边 seek 只在播放已稳定后由用户点刷新键触发（[seekToLiveEdge]）。
  ///
  /// 两端起播差距（3.3s vs 2s）的其余部分来自播放内核差异
  /// （ExoPlayer 轻量 HLS 解析 vs ffmpeg 完整 demuxer），不在客户端代码里。
  @override
  Future<void> play() async {
    await _player?.play();
  }

  /// 设置静音（= web `video.muted`）。
  ///
  /// ## 为什么落成**音量 0/100** 而不是 mpv 的 `mute` 属性
  /// `mute` 是独立开关，与用户/系统音量叠加，而且 mpv 在重建实例后回到 false；
  /// 音量值是 media_kit 的一等公民 API（`Player.setVolume(0..100)`，默认 100），
  /// 语义与 web 的 `video.muted` 等价（0 = 无声、100 = 满音量），且不会与将来要做的
  /// 「音量滑杆」冲突（那时这里换成真实音量即可，不必再改抽象层）。
  ///
  /// 不抛异常：播放器已 dispose / 原生侧拒绝时只当作「没生效」（画面优先于声音）。
  @override
  Future<void> setMuted(bool muted) async {
    try {
      await _player?.setVolume(muted ? 0 : 100);
    } catch (_) {
      // 实例已释放 / 属性不可写 ⇒ 静音没生效而已，不打断播放链路。
    }
  }

  /// 跳到直播真实边缘（开发文档 §3 R1）。
  ///
  /// 改前：`seek(duration)` —— 而直播的 `duration` 是**整个 playlist 的总长**
  /// （实测 ≈66s），不是直播边缘 ⇒ 点刷新等于跳到 playlist 末尾（还会触发重新缓冲）。
  ///
  /// 改后：读 mpv 的 `seekable-ranges`，取最后一段的 `end`，回退 1 个分片
  /// （[kLiveEdgeSeekBackoff]）。解析不到 ⇒ `duration - 1 分片` 兜底
  /// （且 `duration` 必须 > [kLiveEdgeMinDuration]，否则视为「不是直播」）。
  /// 两者都不成立 ⇒ 返回 false，由 `HlsPlaybackController.refreshToLiveEdge`
  /// 走「重建」兜底（顺序固定：**先 seek，失败才 rebuild**）。
  @override
  Future<bool> seekToLiveEdge() async {
    final Player? p = _player;
    if (p == null) return false;
    // seekable-ranges：优先问 mpv（直播边缘的唯一真实来源）。
    Duration? seekableEnd;
    try {
      final PlatformPlayer? platform = p.platform;
      if (platform is NativePlayer) {
        // ⚠️⚠️ **绝不能传 `waitForInitialization: false`**（2026-11-01 崩溃根因，
        // 与 `setProperty` 同一处缺陷的孪生版本）。
        //
        // `NativePlayer.getProperty`（media_kit 1.2.6 real.dart:1255）在
        // `waitForInitialization: false` 时跳过 `await waitForPlayerInitialization`，
        // 直接执行：
        // ```dart
        // final value = mpv.mpv_get_property_string(ctx, name.cast());
        // ```
        // 而 `ctx` 初值是 `nullptr`（real.dart:2658），只有 Player 初始化流程
        // （real.dart:2361）才赋有效句柄。播放器刚建/刚重建时 ctx 仍为空
        // ⇒ `mpv_get_property_string(nullptr, ...)` **原生空指针访问**
        // ⇒ SIGSEGV（退出码 139），进程瞬间消失、**无任何 Dart 堆栈**。
        //
        // 用默认值（true）让它先 await 初始化，ctx 就绪后再读。
        final String raw = await platform.getProperty('seekable-ranges');
        seekableEnd = aylaParseSeekableEnd(raw);
      }
    } catch (_) {
      // 平台不提供 / 已 dispose ⇒ 退回 duration 兜底（不抛给调用方）
      seekableEnd = null;
    }
    final Duration? target = aylaLiveEdgeSeekTarget(
      seekableEnd: seekableEnd,
      duration: p.state.duration,
    );
    if (target == null) return false;
    try {
      await p.seek(target);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget? buildView() {
    final vc = _videoController;
    if (vc == null) return null;
    // `controls: NoVideoControls` **必须显式传**：media_kit 默认挂 AdaptiveVideoControls，
    // 会在画面之上叠一层自带控制条 + 缓冲时的大号白色进度圈（用户截图里那个白色 U 形圈），
    // 与 Ayla 自己的悬浮控件重复。web 的 <video> 不带 controls，这里同样只交出画面。
    // ⚠️ 必须带一个**随 controller 变化**的 key。
    //
    // 自愈重建（hls_player.rebuild）会新建 Player + VideoController；若这里交出
    // 的 Video 没有 key，Flutter 会复用旧 Element，继续渲染**已被释放的旧纹理**
    // ⇒ 画面永久黑屏（日志里能看到「新纹理创建了、但没有 NativeVideoController
    // 注册」）。用 controller 的 identity 当 key，重建后强制换一个新 Element。
    return Video(
      key: ObjectKey(vc),
      controller: vc,
      controls: NoVideoControls,
      // ---- 【B5】后台/前台的生命周期必须成对 ------------------------------------
      //
      // media_kit_video 的 `Video` 默认值（video_texture.dart:132–133）是
      // pauseUponEnteringBackgroundMode = true、resumeUponEnteringForegroundMode = false，
      // Ayla 此前两个都没传 ⇒ **进后台暂停、回前台不恢复**
      // ⇒ 回到前台是黑屏，必须手动点刷新（需求 §3.1 B5 / G3「切后台再回来自动恢复」）。
      //
      // 取值（开发文档 §3 B5）：保持 pause = true（后台继续解码纯耗电，直播没必要），
      // 但 **resume 必须显式置 true**，否则那条「恢复」分支永远不会走
      // （video_texture.dart:291–297 只在 resume 为真且确实是本组件暂停的才 play）。
      pauseUponEnteringBackgroundMode: true,
      resumeUponEnteringForegroundMode: true,
    );
  }

  @override
  Future<void> dispose() async {
    // 先去抖计时器：它持有 `_applyTextureSize` 闭包，晚取消会在已释放的
    // controller 上打一次 setSize（被 catch 吞掉，但没必要）。
    _sizeDecider?.dispose();
    _sizeDecider = null;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _player?.dispose();
    _player = null;
    _videoController = null;
  }
}
