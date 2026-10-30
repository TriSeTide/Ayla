/// Android 系统叠加层的**宿主几何胶水**（第二引擎那棵树的 Android 版外壳）。
///
/// ## 这个文件为什么存在（机制差异，不是重画 UI）
/// 视觉组件一份都不重写：
/// - 悬浮球 → 仍是 `AylaSessionActivityIndicator`；
/// - 直播小窗 → 仍是 `AylaLiveMiniPlayer`（168×94 那张卡本身）。
///
/// 但**宿主机制**和 Windows 完全不同，不能共用外壳：
/// | | Windows | Android（本文件） |
/// |---|---|---|
/// | 穿透 | 窗口按工作区高、Dart 坐标 == 屏幕坐标、C++ 侧 `WM_NCHITTEST` 放行 | 窗口只包住球组/卡片，窗口外**根本不存在矩形** |
/// | 拖动 | 组件自己 1:1（窗口不动） | 原生在**手势期间**把窗口撑到整屏，结束后缩回贴合 |
/// | 平移 | 不需要 | 需要 `Transform.translate(-窗口原点)`：窗口只是「取景框」 |
///
/// 所以这里只做两件事：**坐标系映射** 与 **把几何回推给原生**。
///
/// ## 坐标系约定（与 `OverlayFlutterHost.kt` / `LiveOverlayFlutterHost.kt` 逐条对应）
/// 1. 原生把窗口放在「包住球组/卡片」的位置，并把矩形推过来
///    （通道 `overlayWindowRect`，**逻辑 px、屏幕坐标**）；
/// 2. Dart 侧 `MediaQuery` 报**整块屏幕**（宽屏宽 × 屏幕可用高）⇒ 组件的
///    `Positioned(top: 80)` / 拖动 clamp / 卡片默认右下角落点全部落在屏幕坐标系里
///    （与 App 内完全一致 —— 用户要的「外观和交互没有区别」）；
/// 3. 组件树外套 `Transform.translate(-windowOrigin)` ⇒ 屏幕坐标被平移进小窗口；
/// 4. 组件拖动后的新位置用 `setBallGroupTop` / `setCardRect` 回推，原生据此重新贴合窗口。
///
/// ## 公开面
/// `AylaAndroidOverlayBallApp` · `AylaAndroidLiveOverlayApp` ·
/// `AylaAndroidOverlayViewport` · `AylaOverlayWindowRect` · 样张 `aylaAndroidOverlaySamples()`
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../../theme/tokens.dart';
import '../live/live_mini_player.dart' show AylaLiveMiniPlayer;
import 'session_activity.dart'
    show AylaActivitySession, AylaSessionActivityIndicator;

/// 球窗原生 ↔ 叠加层第二引擎的通道名（与 `OverlayFlutterHost.kt` 逐字一致）。
const String kAylaAndroidOverlayChannel = 'ayla/overlay_android';

/// 直播小窗沿用的内层通道名（与 `LiveOverlayFlutterHost.kt` 逐字一致）。
const String kAylaAndroidLiveWindowChannel = 'ayla/desktop_window';

/// 未拿到原生上报时的兜底屏幕宽度（逻辑 px）。
///
/// 只在 entrypoint 参数缺失（画布 / 单测 / 旧原生）时用到；真机一定走原生给的真值。
const double kAylaAndroidOverlayFallbackWidth = 412;

/// 窗口矩形（逻辑 px、屏幕坐标）。
@immutable
class AylaOverlayWindowRect {
  const AylaOverlayWindowRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  /// 全零矩形 = 还没收到原生上报（此时不平移，按窗口内坐标渲染）。
  static const AylaOverlayWindowRect zero =
      AylaOverlayWindowRect(left: 0, top: 0, width: 0, height: 0);

  final double left;
  final double top;
  final double width;
  final double height;

  bool get isEmpty => width <= 0 || height <= 0;

  /// 解析原生 `overlayWindowRect` 的参数（失败返回 null —— 叠加层是可选增强，不抛）。
  static AylaOverlayWindowRect? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final double? x = _asDouble(raw['x']);
    final double? y = _asDouble(raw['y']);
    final double? w = _asDouble(raw['width']);
    final double? h = _asDouble(raw['height']);
    if (x == null || y == null || w == null || h == null) return null;
    return AylaOverlayWindowRect(left: x, top: y, width: w, height: h);
  }

  static double? _asDouble(Object? value) {
    if (value is! num) return null;
    final double v = value.toDouble();
    return v.isFinite ? v : null;
  }

  @override
  bool operator ==(Object other) =>
      other is AylaOverlayWindowRect &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);

  @override
  String toString() =>
      'AylaOverlayWindowRect($left, $top, ${width}x$height)';
}

/// 把「屏幕坐标」映射进叠加层小窗口的那一层（**唯一**的坐标系翻译点）。
///
/// ## 画卷尺寸必须 = **屏幕**尺寸（2026-11-01 实测订正）
/// 两个组件都用 `Positioned` 定位，而 `Positioned.right/bottom` 是相对**画卷**解析的：
/// - 球组：`right: 24`；
/// - 卡片：`left = viewport.width - 168 - 16`（读 `MediaQuery`）。
/// ⇒ 画卷一旦不是屏幕尺寸，它们就会落到屏幕外（我第一版把画卷写成 1280，
/// 卡片的 left 算出来是 585 —— 在 412 宽的手机上直接看不见）。
/// ⇒ 画卷 = 屏幕逻辑尺寸；`MediaQuery` 也报同一个尺寸（两者必须一致，否则
/// 组件的断点/默认落点和实际画卷不符）。
///
/// 代价（已登记）：屏幕逻辑宽 ≤768 的手机（平板多窗口/折叠态）上，组件会走
/// **窄屏档**（`right: 16` / `top: 104`），与 App 内的窄屏档**完全一致** ——
/// 那是 web 在窄屏的真值，不是降级。桌面端才走宽屏档（`right: 24` / `top: 80`）。
class AylaAndroidOverlayViewport extends StatelessWidget {
  const AylaAndroidOverlayViewport({
    super.key,
    required this.viewportWidth,
    required this.viewportHeight,
    required this.windowRect,
    required this.child,
  });

  /// 屏幕逻辑宽度（px）。
  final double viewportWidth;

  /// 屏幕可用高度（逻辑 px）。组件拖动 clamp 的上限读它。
  final double viewportHeight;

  /// 当前窗口在屏幕上的矩形（逻辑 px）。
  final AylaOverlayWindowRect windowRect;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Size raw = MediaQuery.sizeOf(context);
    final double width =
        viewportWidth.isFinite && viewportWidth > 0 ? viewportWidth : raw.width;
    final double height = viewportHeight.isFinite && viewportHeight > 0
        ? viewportHeight
        : raw.height;
    final Offset shift = windowRect.isEmpty
        ? Offset.zero
        : Offset(-windowRect.left, -windowRect.top);
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        // 报**屏幕**尺寸：断点、拖动 clamp 上限、卡片的默认落点全部据此计算。
        size: Size(width, height),
        padding: EdgeInsets.zero,
        viewPadding: EdgeInsets.zero,
        viewInsets: EdgeInsets.zero,
        disableAnimations: false,
      ),
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Transform.translate(
              offset: shift,
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: 0,
                minHeight: 0,
                maxWidth: double.infinity,
                maxHeight: double.infinity,
                child: SizedBox(
                  // 画卷 = 屏幕尺寸：`Positioned` 的坐标系必须与屏幕一致。
                  width: width,
                  height: height,
                  child: child,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
// ======================= 球窗 =======================

/// Android 叠加层里的悬浮球窗根（第二引擎 `aylaOverlayWindowMain` 的 runApp 目标）。
///
/// 与 Windows 的 `AylaOverlayBallWindowApp` **职责相同、机制不同**：
/// 共同点是「build 同一份 [AylaSessionActivityIndicator]，会话集合由主引擎推 payload」；
/// 差异是这里必须把拖动后的 top 回推原生（原生据此把窗口贴回球组），
/// 并把原生上报的窗口矩形用于坐标平移。
class AylaAndroidOverlayBallApp extends StatefulWidget {
  const AylaAndroidOverlayBallApp({
    super.key,
    this.initialPayload,
    this.initialViewportWidth = 0,
    this.initialViewportHeight = 0,
    this.initialWindowRect,
  });

  /// 从 entrypoint 参数读到的首个投影（原生 `ready` 后还会再推一次，重复幂等）。
  final Object? initialPayload;

  /// 从 entrypoint 参数读到的屏幕逻辑宽度（px）；<= 0 表示未知。
  final double initialViewportWidth;

  /// 从 entrypoint 参数读到的屏幕可用高度（逻辑 px）；<= 0 表示未知。
  final double initialViewportHeight;

  /// 从 entrypoint 参数读到的窗口矩形；null = 未知。
  final AylaOverlayWindowRect? initialWindowRect;

  @override
  State<AylaAndroidOverlayBallApp> createState() =>
      _AylaAndroidOverlayBallAppState();
}

class _AylaAndroidOverlayBallAppState extends State<AylaAndroidOverlayBallApp> {
  final MethodChannel _channel = const MethodChannel(kAylaAndroidOverlayChannel);

  /// 会话投影（第二引擎没有登录态 / store，集合只能由主引擎推过来）。
  AylaActivitySession? _voice;
  AylaActivitySession? _live;

  /// 屏幕逻辑宽度（px）—— 画卷宽度与 `right: 24` 的参照。
  double _viewportWidth = 0;

  /// 屏幕可用高度（逻辑 px）。
  double _viewportHeight = 0;

  /// 原生上报的窗口矩形。
  AylaOverlayWindowRect _windowRect = AylaOverlayWindowRect.zero;

  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _viewportWidth = widget.initialViewportWidth;
    _viewportHeight = widget.initialViewportHeight;
    final AylaOverlayWindowRect? initial = widget.initialWindowRect;
    if (initial != null) _windowRect = initial;
    _applyPayload(widget.initialPayload, rebuild: false);
    _channel.setMethodCallHandler(_handleHostCall);
    // 第一帧出图后再告诉宿主：窗口先透明出现，不会白闪。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      unawaited(_ready());
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  /// 解析一条投影。
  ///
  /// 只取本文件真正用到的六个字段：`overlay_window_app.dart` 的 `AylaOverlayPayload`
  /// 属于 Windows 侧外壳，Android 不复用它的生命周期语义，避免任一平台改内部时
  /// 静默影响另一个。
  void _applyPayload(Object? raw, {required bool rebuild}) {
    Map<Object?, Object?>? map;
    if (raw is String && raw.isNotEmpty) {
      try {
        final Object? decoded = jsonDecode(raw);
        if (decoded is Map) map = decoded;
      } catch (_) {
        // 非法 JSON：叠加层是可选增强，静默忽略（不崩整棵树）。
      }
    } else if (raw is Map) {
      map = raw;
    }
    if (map == null) return;
    final Map<Object?, Object?> data = map;

    String text(Object? value) => value == null ? '' : '$value';

    AylaActivitySession? session(
      String idKey,
      String titleKey,
      String routeKey,
    ) {
      final String id = text(data[idKey]);
      if (id.isEmpty) return null;
      return AylaActivitySession(
        sessionId: id,
        sourceRoute: text(data[routeKey]),
        title: text(data[titleKey]),
      );
    }

    final AylaActivitySession? voice =
        session('voiceSessionId', 'voiceTitle', 'voiceRoute');
    final AylaActivitySession? live =
        session('liveSessionId', 'liveTitle', 'liveRoute');
    if (rebuild) {
      setState(() {
        _voice = voice;
        _live = live;
      });
    } else {
      _voice = voice;
      _live = live;
    }
  }

  Future<Object?> _handleHostCall(MethodCall call) async {
    if (_disposed) return null;
    switch (call.method) {
      case 'ballPayload':
        final Object? raw = call.arguments;
        if (raw is Map) _applyPayload(raw['payload'], rebuild: true);
      case 'overlayWindowRect':
        final AylaOverlayWindowRect? rect =
            AylaOverlayWindowRect.tryParse(call.arguments);
        if (rect != null && rect != _windowRect) {
          setState(() => _windowRect = rect);
        }
    }
    return null;
  }

  Future<void> _ready() async {
    try {
      await _channel.invokeMethod<bool>('ready');
    } on MissingPluginException {
      // 宿主未实现（画布 / 单测）：静默，不影响渲染。
    } on PlatformException {
      // 同上。
    }
  }

  /// 拖动把手 ⇒ 把**屏幕坐标系**下的新 top 交给原生（原生据此把窗口贴回去）。
  ///
  /// 这里**不移动任何窗口**：手势期间的窗口变化由原生做（它还把窗口临时撑到整屏），
  /// Dart 只负责「球最终在哪里」这一条事实。
  Future<void> _reportGroupTop(double top) async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<bool>('setBallGroupTop', <String, Object?>{
        'top': top,
      });
    } on MissingPluginException {
      // 静默。
    } on PlatformException {
      // 静默。
    }
  }

  /// 点球 ⇒ 交回主引擎导航（本窗口**不关闭**：用户可能还要看另一个会话）。
  ///
  /// **不**在这里做「唤起 App」：那是原生的事 —— App 在后台时主引擎可能已暂停，
  /// Dart 回调拦不住窗口焦点（见 `OverlayFlutterHost.kt` 的 `ballTap` 分支）。
  Future<void> _openSession(AylaActivitySession session, String kind) async {
    try {
      await _channel.invokeMethod<bool>('ballTap', <String, Object?>{
        'kind': kind,
        'sourceRoute': session.sourceRoute,
      });
    } on MissingPluginException {
      // 静默。
    } on PlatformException {
      // 静默。
    }
  }

  @override
  Widget build(BuildContext context) {
    final AylaActivitySession? voice = _voice;
    final AylaActivitySession? live = _live;
    // 无会话 ⇒ 组件按 tsx 135 零渲染（主引擎会顺手关窗）。
    if (voice == null && live == null) return const SizedBox.shrink();
    final String liveId = live?.sessionId ?? '';
    return Material(
      // 透明底：叠加层窗口本身是 TRANSLUCENT，背景必须让出来。
      type: MaterialType.transparency,
      child: AylaAndroidOverlayViewport(
        viewportWidth: _viewportWidth,
        viewportHeight: _viewportHeight,
        windowRect: _windowRect,
        child: Stack(
          children: <Widget>[
            // 现有组件原样（它返回 Positioned ⇒ 必须是 Stack 的直接子级）。
            AylaSessionActivityIndicator(
              voice: voice,
              live: live,
              onOpenSession: (AylaActivitySession session) {
                final String kind =
                    session.sessionId == liveId ? 'live' : 'voice';
                unawaited(_openSession(session, kind));
              },
              // 拖动后的新 top（屏幕坐标）→ 原生把窗口贴回去。
              onTopChanged: (double top) => unawaited(_reportGroupTop(top)),
            ),
          ],
        ),
      ),
    );
  }
}

// ======================= 直播小窗 =======================

/// Android 叠加层里的直播小窗根（第二引擎 `aylaLiveWindowMain` 的 runApp 目标）。
///
/// ## 用户要求（2026-11-01 逐字）
/// > 「手机端直播小窗重做，打开的小窗仍然不是原来的小窗口，而是直接打开了重新搓的那个新的，
/// >   **新的删掉，用我原来的窗口**」
///
/// ⇒ 这里 build 的就是**同一份** [AylaLiveMiniPlayer]（168×94 圆角玻璃卡 +
/// 右上外侧关闭键），视频面来自**本引擎自己注册的 video_player**
/// （`LiveOverlayFlutterHost.kt` 只注册它一个插件）。
///
/// ## 为什么不复用 `live_window_surface.dart` 的 `AylaDetachedLiveWindowApp`
/// 那个实现用 **media_kit** 起播。本工程只打包了 `media_kit_libs_windows_video`
/// （`pubspec.yaml` 原文：「Android/iOS 上没有 libmpv」）⇒ Android 上必然黑屏。
/// ⇒ Android 走 video_player（与主引擎 Android 同一套 HLS 实现：
///   `lib/player/platforms/hls_platform.dart` → `video_player_impl.dart`）。
class AylaAndroidLiveOverlayApp extends StatefulWidget {
  const AylaAndroidLiveOverlayApp({
    super.key,
    this.initialUrl,
    this.initialTitle,
    this.initialViewportWidth = 0,
    this.initialViewportHeight = 0,
    this.initialWindowRect,
  });

  /// 从 entrypoint 参数读到的播放地址（宿主 `play` 指令的兜底）。
  final String? initialUrl;

  /// 初始标题（小窗 title / 语义标签）。
  final String? initialTitle;

  /// 屏幕逻辑宽度（px）；<= 0 表示未知（此时读 `MediaQuery`）。
  final double initialViewportWidth;

  /// 屏幕可用高度（逻辑 px）；<= 0 表示未知（此时读 `MediaQuery`）。
  final double initialViewportHeight;

  /// 窗口矩形；null = 未知。
  final AylaOverlayWindowRect? initialWindowRect;

  @override
  State<AylaAndroidLiveOverlayApp> createState() =>
      _AylaAndroidLiveOverlayAppState();
}

class _AylaAndroidLiveOverlayAppState extends State<AylaAndroidLiveOverlayApp> {
  final MethodChannel _channel =
      const MethodChannel(kAylaAndroidLiveWindowChannel);

  /// 卡片的 RenderObject 定位键 —— 用来测量「卡片在屏幕上的真实矩形」。
  final GlobalKey _cardKey = GlobalKey();

  VideoPlayerController? _controller;
  String? _status = '连接中…';
  String _title = '直播间';
  String _openedUrl = '';

  double _viewportWidth = 0;
  double _viewportHeight = 0;
  AylaOverlayWindowRect _windowRect = AylaOverlayWindowRect.zero;

  /// 上一次上报给原生的卡片矩形（去重：每帧都推通道没有意义）。
  Rect? _reportedCardRect;

  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _viewportWidth = widget.initialViewportWidth;
    _viewportHeight = widget.initialViewportHeight;
    final AylaOverlayWindowRect? initial = widget.initialWindowRect;
    if (initial != null) _windowRect = initial;
    final String? initialTitle = widget.initialTitle;
    if (initialTitle != null && initialTitle.isNotEmpty) _title = initialTitle;
    _channel.setMethodCallHandler(_handleHostCall);
    final String? initialUrl = widget.initialUrl;
    if (initialUrl != null && initialUrl.isNotEmpty) {
      // 兜底路径：不等宿主指令，直接起播（重复的 `play` 由 `_open` 的幂等守卫吃掉）。
      unawaited(Future<void>.microtask(() => _open(initialUrl)));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      unawaited(_ready());
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _channel.setMethodCallHandler(null);
    final VideoPlayerController? controller = _controller;
    _controller = null;
    // 播放器必须显式销毁：第二引擎的窗口被宿主销毁时 Dart 不会自动释放 ExoPlayer。
    if (controller != null) {
      controller.removeListener(_onTick);
      unawaited(controller.dispose());
    }
    super.dispose();
  }

  Future<Object?> _handleHostCall(MethodCall call) async {
    if (_disposed) return null;
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
        if (title.isNotEmpty && title != _title) {
          setState(() => _title = title);
        }
        unawaited(_open(url));
      case 'overlayWindowRect':
        final AylaOverlayWindowRect? rect =
            AylaOverlayWindowRect.tryParse(call.arguments);
        if (rect != null && rect != _windowRect) {
          setState(() => _windowRect = rect);
        }
    }
    return null;
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

  /// 起播（与主引擎 Android 同一条路径：video_player / ExoPlayer，原生支持 HLS）。
  Future<void> _open(String url) async {
    if (url.isEmpty) {
      if (!_disposed) setState(() => _status = '无播放地址');
      return;
    }
    // 幂等：入口参数与宿主 `play` 指令是同一个地址时只起一次播放器
    // （两个 ExoPlayer 实例会各自解一路 HLS，白烧带宽还会双声道重叠）。
    if (_openedUrl == url) return;
    _openedUrl = url;
    final VideoPlayerController? previous = _controller;
    _controller = null;
    if (previous != null) {
      previous.removeListener(_onTick);
      await previous.dispose();
    }
    if (_disposed) return;
    setState(() => _status = '连接中…');
    final VideoPlayerController controller =
        VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await controller.initialize();
    } catch (error) {
      await controller.dispose();
      if (!_disposed) {
        _openedUrl = '';
        setState(() => _status = '播放失败：$error');
      }
      return;
    }
    if (_disposed) {
      await controller.dispose();
      return;
    }
    // live 贴边：先 seek 到末尾再播（与 `video_player_impl.dart` 同一策略）。
    if (controller.value.duration > Duration.zero) {
      await controller.seekTo(controller.value.duration);
    }
    await controller.play();
    if (_disposed) {
      await controller.dispose();
      return;
    }
    controller.addListener(_onTick);
    setState(() {
      _controller = controller;
      _status = null;
    });
  }

  void _onTick() {
    final VideoPlayerController? controller = _controller;
    if (controller == null || _disposed) return;
    if (controller.value.hasError) {
      final String? detail = controller.value.errorDescription;
      setState(() => _status = '播放失败：${detail ?? '未知错误'}');
    }
  }

  /// 每帧后测量「卡片在**屏幕坐标**里的真实矩形」并回推原生（窗口据此贴合）。
  ///
  /// 为什么是测量而不是自己算：卡片的 `left/top/size` 由组件内部状态持有
  /// （默认右下角 16、拖动与双指缩放都会改），外面算不出来。
  ///
  /// 收敛性：原生移动窗口 → 推 `overlayWindowRect` → 本层重建 → 再测量时
  /// 卡片在屏幕上的位置**没变**（窗口与坐标系一起挪）⇒ [_reportedCardRect] 去重命中，
  /// 不再推通道，循环终止。
  void _scheduleCardReport() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      final BuildContext? ctx = _cardKey.currentContext;
      if (ctx == null) return;
      final RenderObject? ro = ctx.findRenderObject();
      if (ro is! RenderBox || !ro.hasSize) return;
      unawaited(_reportCardRect(aylaAndroidScreenRectOf(ro, _windowRect)));
    });
  }

  /// 卡片矩形（屏幕坐标）→ 原生把它当窗口贴合目标。
  Future<void> _reportCardRect(Rect rect) async {
    if (_disposed) return;
    if (rect.width <= 0 || rect.height <= 0) return;
    final Rect? previous = _reportedCardRect;
    if (previous != null &&
        (previous.left - rect.left).abs() < 0.5 &&
        (previous.top - rect.top).abs() < 0.5 &&
        (previous.width - rect.width).abs() < 0.5 &&
        (previous.height - rect.height).abs() < 0.5) {
      return;
    }
    _reportedCardRect = rect;
    try {
      await _channel.invokeMethod<bool>('setCardRect', <String, Object?>{
        'left': rect.left,
        'top': rect.top,
        'width': rect.width,
        'height': rect.height,
      });
    } on MissingPluginException {
      // 静默。
    } on PlatformException {
      // 静默。
    }
  }

  Future<void> _close() async {
    try {
      await _channel.invokeMethod<bool>('close');
    } on MissingPluginException {
      // 静默。
    } on PlatformException {
      // 静默。
    }
  }

  Future<void> _openRoom() async {
    try {
      await _channel.invokeMethod<bool>('activateMain');
    } on MissingPluginException {
      // 静默。
    } on PlatformException {
      // 静默。
    }
  }

  /// 画面面（未就绪时是黑底 + 一行状态文案）。
  ///
  /// 状态文案**放在画面里**（而不是盖在窗口上）：它跟着卡片一起被裁剪、一起拖动/缩放，
  /// 不需要额外知道卡片在哪。
  Widget _videoSurface() {
    final VideoPlayerController? controller = _controller;
    final String? status = _status;
    final Widget base = controller == null
        ? const ColoredBox(color: Colors.black)
        : VideoPlayer(controller);
    if (status == null) return base;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        base,
        Center(
          child: Text(
            status,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xCCFFFFFF),
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    _scheduleCardReport();
    return Material(
      // 透明底：叠加层窗口本身是 TRANSLUCENT，卡片之外必须真的透出下面。
      type: MaterialType.transparency,
      color: Colors.transparent,
      child: AylaAndroidOverlayViewport(
        viewportWidth: _viewportWidth,
        viewportHeight: _viewportHeight,
        windowRect: _windowRect,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            // 现有组件原样（返回 Positioned ⇒ 必须是 Stack 的直接子级）。
            AylaLiveMiniPlayer(
              key: _cardKey,
              videoView: _videoSurface(),
              channelTitle: _title,
              onOpenRoom: () => unawaited(_openRoom()),
              onClose: () => unawaited(_close()),
            ),
          ],
        ),
      ),
    );
  }
}

/// 把 RenderBox 换算成「屏幕坐标矩形」（窗口原点补偿）。
///
/// 抽成纯函数是为了能被单测直接驱动 —— 它是本文件唯一的几何换算点。
@visibleForTesting
Rect aylaAndroidScreenRectOf(RenderBox box, AylaOverlayWindowRect windowRect) {
  final Rect local = box.localToGlobal(Offset.zero) & box.size;
  return local.shift(Offset(windowRect.left, windowRect.top));
}

// ======================= 样张 =======================

/// Android 叠加层样张（画布验收面）：球窗 / 小窗各一档。
///
/// 舞台背景刻意画成「桌面色」——在真实透明窗口里，这部分应当完全看不见。
Widget aylaAndroidOverlaySamples() {
  Widget stage(String label, Size size, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          width: size.width,
          height: size.height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AylaColors.surface,
              borderRadius: BorderRadius.circular(AylaRadii.rCard),
            ),
            child: child,
          ),
        ),
        const SizedBox(height: AylaSpacing.sp1),
        SizedBox(
          width: size.width,
          child: Text(label, style: const TextStyle(fontSize: 11)),
        ),
      ],
    );
  }

  return Wrap(
    spacing: AylaSpacing.sp6,
    runSpacing: AylaSpacing.sp6,
    crossAxisAlignment: WrapCrossAlignment.start,
    children: <Widget>[
      stage(
        'Android 叠加层球窗 · 窗口只包住球组（160×60），窗口外天然穿透 · '
        '组件仍是同一份 AylaSessionActivityIndicator（屏幕坐标 right 24 / top 80）',
        const Size(160, 60),
        const AylaAndroidOverlayBallApp(
          initialViewportWidth: 412,
          initialViewportHeight: 780,
          initialWindowRect: AylaOverlayWindowRect(
            left: 0,
            top: 74,
            width: 160,
            height: 60,
          ),
        ),
      ),
      stage(
        'Android 叠加层直播小窗 · 窗口包住卡片 168×94（+外侧关闭键余量）· '
        '组件仍是同一份 AylaLiveMiniPlayer，视频面来自本引擎注册的 video_player',
        const Size(188, 114),
        const AylaAndroidLiveOverlayApp(
          initialTitle: '深夜电台 · 爱莉陪你写代码',
          initialViewportWidth: 412,
          initialViewportHeight: 780,
          initialWindowRect: AylaOverlayWindowRect(
            left: 0,
            top: 0,
            width: 188,
            height: 114,
          ),
        ),
      ),
    ],
  );
}