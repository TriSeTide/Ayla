/// Android **窗口外直播小窗**的第二引擎那棵树（原生宿主见
/// `android/.../LiveMiniWindowHost.kt`）。
///
/// ## 用户定稿（2026-10-31，逐字）
/// > 「直播小窗也是同样的，要直接用现有的直播小窗让他脱离应用，不要加按钮单独重做一个」
/// > 「**不要造轮子！用现有的悬浮球和直播小窗**」
/// 1.0.41 的 `LiveOverlayFlutterHost.kt`（533 行，自绘 + 自造交互）被评价
/// 「**各种交互都做烂了**」⇒ **不抄它**。
///
/// ## 本文件做什么（只有三件）
/// 1. 建**自己那一路** HLS 播放器（Android 用 `video_player` / ExoPlayer，
///    与主窗口同一个平台实现，见 `lib/player/platforms/hls_platform.dart`）；
/// 2. 把画面注入 **同一份** [AylaLiveMiniPlayer]（`lib/widgets/live/live_mini_player.dart`）
///    —— 外观、关闭键位置、圆角玻璃、hover 配方全部复用，一处都不重画；
/// 3. 把「点画面回房 / 点关闭」接回宿主（跨引擎没有 router）。
///
/// ## 与 Windows 那棵树的差异（有意，登记）
/// | | Windows（`live_window_surface.dart`） | Android（本文件） |
/// |---|---|---|
/// | 窗口几何 | 铺满整个工作区（可拖到任意位置） | **窗口 = 卡片**（overlay 尺寸即热区） |
/// | 拖动 / 缩放 | 组件自己在窗口内改位置与尺寸 | **原生改窗口**（组件走 `compact`） |
/// | 点击穿透 | `SetWindowRgn` 逐像素透明 | 不需要（窗口就是卡片） |
///
/// 两者的**视觉与组件代码完全同一份** —— 差异只在「谁来移动窗口」。
///
/// ## 这一棵树里没有什么
/// 没有 ProviderScope / router / Dio / WS / 登录态 —— 第二引擎是另一个 isolate。
/// 播放地址由主窗口在打开时一次性传入（已归一 + 带鉴权 query）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../player/hls_player.dart';
import '../../player/platforms/hls_platform.dart';
import 'live_mini_player.dart' show AylaLiveMiniPlayer, kLiveCloseInset;

/// 第二引擎 ↔ 原生宿主的**私有**通道（与 `LiveMiniWindowHost.kt` 逐字一致）。
const String kAylaAndroidLiveMiniChannel = 'ayla/live_mini_window';

/// 窗口外直播小窗的根 widget（第二引擎的 `runApp` 目标）。
class AylaAndroidLiveMiniWindowApp extends StatefulWidget {
  const AylaAndroidLiveMiniWindowApp({
    super.key,
    this.initialChannelId,
    this.initialPlayUrl,
  });

  /// 打开时的频道 id（仅用于语义标签与调试）。
  final String? initialChannelId;

  /// 入口参数里的播放地址（宿主 `ready` 之后还会再发一次 `play`；重复是幂等的）。
  final String? initialPlayUrl;

  @override
  State<AylaAndroidLiveMiniWindowApp> createState() =>
      _AylaAndroidLiveMiniWindowAppState();
}

class _AylaAndroidLiveMiniWindowAppState
    extends State<AylaAndroidLiveMiniWindowApp> {
  final MethodChannel _channel = const MethodChannel(kAylaAndroidLiveMiniChannel);

  HlsPlaybackController? _player;
  String? _url;
  String? _title;
  bool _disposed = false;

  /// 原生刚拖动/缩放过 ⇒ 抑制紧随其后的一次 tap（拖完不该误触「回直播间」）。
  int _suppressTapTick = 0;

  /// 原生给的窗口尺寸（逻辑 px）——卡片可用区 = 窗口减去关闭键外溢。
  Size _windowSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler(_handleHostCall);
    final String? initial = widget.initialPlayUrl;
    if (initial != null && initial.isNotEmpty) {
      unawaited(_open(initial));
    }
    // 第一帧出图后告诉宿主：窗口先透明出现，不会白闪。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      unawaited(_ready());
    });
  }

  Future<Object?> _handleHostCall(MethodCall call) async {
    switch (call.method) {
      case 'play':
        final Object? raw = call.arguments;
        String url = '';
        String title = '';
        if (raw is Map) {
          final Object? u = raw['url'];
          final Object? t = raw['title'];
          if (u is String) url = u;
          if (t is String) title = t;
        }
        if (!_disposed && title.isNotEmpty) {
          setState(() => _title = title);
        }
        unawaited(_open(url));
      case 'size':
        final Object? raw = call.arguments;
        if (raw is Map) {
          final double w = (raw['width'] as num?)?.toDouble() ?? 0;
          final double h = (raw['height'] as num?)?.toDouble() ?? 0;
          if (!_disposed && w > 0 && h > 0) {
            setState(() => _windowSize = Size(w, h));
          }
        }
      case 'suppressTap':
        if (!_disposed) setState(() => _suppressTapTick++);
      default:
        return null;
    }
    return null;
  }

  /// 起播放器并开流（这一路 HLS 与主窗口那路互不相干）。
  Future<void> _open(String url) async {
    if (url.isEmpty || _disposed) return;
    if (_url == url) return; // 幂等：同地址不重建播放器
    _url = url;
    final HlsPlaybackController? old = _player;
    _player = null;
    if (old != null) {
      unawaited(old.destroy());
    }
    final HlsPlaybackController player = HlsPlaybackController(
      createHlsPlatformPlayer,
      HlsPlayerCallbacks()
        ..onStateChange = (HlsState _) {
          if (!_disposed && mounted) setState(() {});
        },
    );
    if (_disposed) {
      unawaited(player.destroy());
      return;
    }
    setState(() => _player = player);
    try {
      // attach 内部已经起播（见 hls_player.dart 的 attach：挂载后立刻 play）。
      await player.attach(url);
    } catch (_) {
      // 播放失败：组件自身会显示黑底（与 App 内小窗同款降级），不额外造 UI。
    }
  }

  Future<void> _ready() async {
    try {
      await _channel.invokeMethod<bool>('ready');
    } on MissingPluginException {
      // 宿主未实现（画布 / 单测）：静默。
    } on PlatformException {
      // 同上。
    }
  }

  Future<void> _openRoom() async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<bool>('openRoom');
    } on MissingPluginException {
      // 静默。
    } on PlatformException {
      // 静默。
    }
  }

  Future<void> _close() async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<bool>('close');
    } on MissingPluginException {
      // 静默。
    } on PlatformException {
      // 静默。
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _channel.setMethodCallHandler(null);
    final HlsPlaybackController? player = _player;
    _player = null;
    // 播放器必须在这里主动销毁：宿主销毁窗口时 Dart 侧不会自动释放解码器。
    if (player != null) unawaited(player.destroy());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Size real = MediaQuery.sizeOf(context);
    // 窗口 = 卡片 + 关闭键外溢（右上各 kLiveCloseInset）。
    // 卡片画在 (0, kLiveCloseInset)，于是右上角外侧的关闭键正好落在多出来的边距里。
    final double winW = _windowSize.width > 0 ? _windowSize.width : real.width;
    final double winH = _windowSize.height > 0 ? _windowSize.height : real.height;
    final double cardWidth = winW - kLiveCloseInset;
    final double cardHeight = winH - kLiveCloseInset;
    final double width = cardWidth > 0 ? cardWidth : 390;
    final double height = cardHeight > 0 ? cardHeight : width * 9 / 16;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      // 透明底：宿主窗口是 TRANSLUCENT，卡片圆角之外必须透出下面。
      color: Colors.transparent,
      home: Material(
        type: MaterialType.transparency,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            // 视口 = 卡片本身 ⇒ 组件的默认落点与拖动 clamp 都落在卡片内（不溢出窗口）。
            size: Size(width, height),
            padding: EdgeInsets.zero,
            viewPadding: EdgeInsets.zero,
            viewInsets: EdgeInsets.zero,
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              // ⚠️ 必须是 Stack 的**直接**子级：`AylaLiveMiniPlayer` 返回 `Positioned`，
              // 中间再套一层会让它的 offset 不再相对 Stack（关闭键会被裁掉一截）。
              AylaLiveMiniPlayer(
                key: ValueKey<int>(_suppressTapTick),
                // 几何归原生（窗口 = 卡片），组件只负责视觉与点击。
                fixedPosition: Offset.zero,
                initialSize: Size(width, height),
                videoView: _player?.videoView,
                channelTitle: _title ?? '直播间',
                onOpenRoom: _openRoom,
                onClose: _close,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
