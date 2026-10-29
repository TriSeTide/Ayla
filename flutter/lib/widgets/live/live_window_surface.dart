
/// 电脑端「脱离应用」的独立直播小窗 —— **第二引擎那棵树**的界面外壳。
///
/// ## 这不是普通的 App 内组件
/// 它跑在一个**独立的 Flutter engine** 里（见 `windows/runner/live_window.cpp` +
/// `lib/main.dart` 的 `aylaLiveWindowMain`），宿主窗口是：
/// `WS_POPUP | WS_CLIPCHILDREN | WS_CLIPSIBLINGS` + `WS_EX_TOPMOST | WS_EX_TOOLWINDOW`
/// ⇒ 无标题栏、恒置顶、**不进 Alt-Tab / 任务栏**，主窗口最小化后仍然可见。
///
/// ## 事实源（不自由发挥）
/// 视觉全部来自 App 内已有的小窗本体，逐条对照：
/// - `web/src/styles/live.css:1021–1090`（`.live-mini-player` / `-video-wrap` / `-close`）；
/// - Flutter 侧同源实现 `lib/widgets/live/live_mini_player.dart` 的
///   `_AylaMiniCloseButton`（24×24 玻璃圆钮 · 白描边 `0x47FFFFFF` ·
///   底色 `0x52465B92` / hover `0x85465B92` · 图标 `iconClose` 14px）；
///
/// ## 与 App 内小窗的**有意差异**（登记）
/// 1. 关闭键在**画面内部**右上角（内缩 6），不是 web 的外侧 -10：
///    宿主窗口是 `WS_POPUP`（无外扩面积），放外侧会被窗口裁掉一半。
/// 2. 整块画面可点 = 「回主窗口」：等价于 web 小窗「点主体 navigate(sourceRoute)」，
///    但跨引擎没有 router，只能回传原生（`activateMain`），由主窗口侧
///    `AylaDetachedLiveEvents.liveWindowClosed` 接回 **App 内小窗**（不销毁会话）。
/// 3. **不**挂 `AylaAuroraBackground` / ProviderScope / router / Dio / WS：这个引擎
///    只负责「黑底 + 一路 HLS + 两个键」，任何全局依赖都可能第二次跑起来（或拿不到数据）。
///    播放地址由主窗口在打开时一次性传入（`openLiveWindow.playUrl`，已归一 + 带鉴权 query）。
///
/// ## 公开面
/// `AylaDetachedLiveWindowApp`（小窗根 widget）· `AylaDetachedLiveWindowSurface`（纯视图，
/// 便于样张与测试注入假画面）
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../theme/app_icons.dart';
import '../../theme/tokens.dart';

/// 宿主窗口 ↔ 第二引擎的私有通道（`live_window.cpp` 的
/// `AylaLiveWindowHost::CreateChannel` 逐字一致；**不是**给主引擎用的那条）。
const String kAylaDetachedWindowInnerChannel = 'ayla/desktop_window';

/// 关闭键尺寸（web `.live-mini-player-close` = 24×24）。
const double kAylaDetachedCloseSize = 24;

/// 关闭键在画面内的内缩（见文件头「有意差异 1」）。
const double kAylaDetachedCloseInset = 6;

/// 关闭键图标尺寸（web tsx 224 行 = 14）。
const double kAylaDetachedCloseIconSize = 14;

/// 独立直播小窗的根 widget（第二引擎的 `runApp` 目标）。
class AylaDetachedLiveWindowApp extends StatefulWidget {
  const AylaDetachedLiveWindowApp({
    super.key,
    this.onReady,
    this.initialUrl,
    this.initialTitle,
  });

  /// 第一帧渲染完成后的回调。
  final VoidCallback? onReady;

  /// 从 entrypoint 参数里读到的播放地址（宿主 `play` 指令的**兜底**：
  /// 若平台→Dart 那条消息在极端时序下丢了，这里仍然能起播）。
  final String? initialUrl;

  /// 同上：初始标题（只用于语义标签）。
  final String? initialTitle;

  @override
  State<AylaDetachedLiveWindowApp> createState() =>
      _AylaDetachedLiveWindowAppState();
}

class _AylaDetachedLiveWindowAppState extends State<AylaDetachedLiveWindowApp> {
  final AylaDetachedWindowChannel _channel = AylaDetachedWindowChannel();

  Player? _player;
  VideoController? _videoController;
  String? _status = '连接中…';
  String _title = '直播小窗';
  bool _disposed = false;

  /// 已经在播的地址（入口参数与宿主 `play` 指令会各来一次，必须幂等）。
  String? _openedUrl;

  @override
  void initState() {
    super.initState();
    final String? initialTitle = widget.initialTitle;
    if (initialTitle != null && initialTitle.isNotEmpty) {
      _title = initialTitle;
    }
    // 宿主在收到 `ready` 之后才会把播放地址发过来：这样 `play` 不可能早于
    // handler 注册（平台→Dart 的消息在 handler 未挂时会被丢弃）。
    _channel.setHandler((String url, String title) {
      if (_disposed) return;
      _title = title.isEmpty ? _title : title;
      unawaited(_open(url));
    });
    final String? initialUrl = widget.initialUrl;
    if (initialUrl != null && initialUrl.isNotEmpty) {
      // 兜底路径：不等宿主指令，直接起播（重复的 `play` 由 `_open` 的
      // 「同 URL 不重建」守卫吃掉）。
      unawaited(Future<void>.microtask(() => _open(initialUrl)));
    }
    // 第一帧出图后再告诉宿主：窗口先黑底出现，不会白闪。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      unawaited(_channel.ready());
      widget.onReady?.call();
    });
  }

  /// 起播放器并开流（这一路 HLS 与主窗口那路互不相干：mpv 实例是每引擎独立的）。
  ///
  /// ⚠️ 这里**只**依赖 `package:media_kit`（FFI，无平台通道）与
  /// `package:media_kit_video`（第二个引擎里已单独注册）。不碰
  /// shared_preferences / flutter_secure_storage / Dio / WS —— 见文件头第 3 条。
  Future<void> _open(String url) async {
    if (url.isEmpty) {
      if (!_disposed) setState(() => _status = '无播放地址');
      return;
    }
    // 幂等：入口参数与宿主 `play` 指令是同一个地址时只起一次播放器
    // （两个 mpv 实例会各自解一路 HLS，白烧带宽还会双声道重叠）。
    if (_openedUrl == url) return;
    _openedUrl = url;
    await _player?.dispose();
    _player = null;
    _videoController = null;
    try {
      MediaKit.ensureInitialized();
    } catch (error) {
      if (!_disposed) setState(() => _status = '播放内核不可用：$error');
      return;
    }
    if (_disposed) return;

    final Player player = Player();
    final VideoController controller = VideoController(player);
    setState(() {
      _player = player;
      _videoController = controller;
      _status = null;
    });

    player.stream.error.listen((String error) {
      if (_disposed) return;
      setState(() => _status = '播放失败：$error');
    });

    try {
      await player.open(Media(url), play: true);
    } catch (error) {
      if (!_disposed) setState(() => _status = '播放失败：$error');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    // 播放器必须在这里主动销毁：第二引擎的窗口被宿主销毁时，Dart 侧不会自动
    // 释放 mpv 实例（那会泄漏 render context 与纹理）。
    final Player? player = _player;
    _player = null;
    _videoController = null;
    if (player != null) {
      unawaited(player.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final VideoController? controller = _videoController;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      color: Colors.black,
      home: AylaDetachedLiveWindowSurface(
        title: _title,
        statusText: _status,
        video: controller == null
            ? null
            : Video(
                controller: controller,
                controls: NoVideoControls,
                // 第二个引擎不申请唤醒锁（那要过 wakelock_plus 的平台通道，
                // 而这个引擎只注册了 media_kit_video）。
                wakelock: false,
                // 与 App 内一致：只交画面，不叠 media_kit 自带的控制条。
                fit: BoxFit.contain,
                fill: Colors.black,
              ),
        onClose: () => unawaited(_channel.close()),
        onActivateMain: () => unawaited(_channel.activateMain()),
      ),
    );
  }
}

/// 独立直播小窗的纯视图层（可注入假画面，用于样张 / 单测）。
///
/// 视觉 = 黑底铺满 + 画面 + 右上 24×24 玻璃圆钮关闭键。
class AylaDetachedLiveWindowSurface extends StatefulWidget {
  const AylaDetachedLiveWindowSurface({
    super.key,
    this.video,
    this.title,
    this.onClose,
    this.onActivateMain,
    this.statusText,
  });

  /// 视频画面（`media_kit` 的 `Video` 或任何 widget；null = 纯黑）。
  final Widget? video;

  /// 频道标题（窗口无标题栏 ⇒ 不渲染；保留给语义标签）。
  final String? title;

  /// 关闭键（内层通道 `close`）。
  final VoidCallback? onClose;

  /// 点画面主体（内层通道 `activateMain`：回主窗口）。
  final VoidCallback? onActivateMain;

  /// 画面未就绪时的状态文案（连接中 / 失败）。
  final String? statusText;

  @override
  State<AylaDetachedLiveWindowSurface> createState() =>
      _AylaDetachedLiveWindowSurfaceState();
}

class _AylaDetachedLiveWindowSurfaceState
    extends State<AylaDetachedLiveWindowSurface> {
  bool _closeHovered = false;
  bool _closeFocused = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Semantics(
        label: widget.title ?? '直播小窗',
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // 画面主体：可点 ⇒ 回主窗口（见文件头「有意差异 2」）。
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onActivateMain,
              child: ColoredBox(
                color: Colors.black,
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    if (widget.video != null)
                      Center(
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: widget.video!,
                        ),
                      ),
                    if (widget.statusText != null)
                      Center(
                        child: Text(
                          widget.statusText!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xCCFFFFFF),
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // 关闭键：内缩 6 摆在画面右上（见文件头「有意差异 1」）。
            Positioned(
              top: kAylaDetachedCloseInset,
              right: kAylaDetachedCloseInset,
              child: _AylaDetachedCloseButton(
                hovered: _closeHovered,
                focused: _closeFocused,
                onHover: (bool has) => setState(() => _closeHovered = has),
                onFocus: (bool has) => setState(() => _closeFocused = has),
                onPressed: widget.onClose,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 24×24 玻璃圆钮关闭键（与 `live_mini_player.dart` 的 `_AylaMiniCloseButton` 同配方）。
class _AylaDetachedCloseButton extends StatelessWidget {
  const _AylaDetachedCloseButton({
    required this.hovered,
    required this.focused,
    required this.onHover,
    required this.onFocus,
    required this.onPressed,
  });

  final bool hovered;
  final bool focused;
  final ValueChanged<bool> onHover;
  final ValueChanged<bool> onFocus;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '关闭直播小窗',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => onHover(true),
        onExit: (_) => onHover(false),
        child: Focus(
          onFocusChange: onFocus,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onPressed,
            child: Container(
              width: kAylaDetachedCloseSize,
              height: kAylaDetachedCloseSize,
              decoration: BoxDecoration(
                // hover rgba(70,91,146,.52) / 常态 rgba(70,91,146,.32)
                color: hovered
                    ? const Color(0x85465B92)
                    : const Color(0x52465B92),
                borderRadius: AylaRadii.pill,
                border: Border.all(
                  color: focused
                      ? AylaColors.glow500
                      : const Color(0x47FFFFFF),
                  width: focused ? 2 : 1,
                ),
              ),
              alignment: Alignment.center,
              child: AylaIcon(
                aylaIconByName('iconClose')!,
                size: kAylaDetachedCloseIconSize,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 第二引擎 → 宿主窗口的**内层**通道（方向与主引擎的 `ayla/desktop_window` 相反）。
///
/// 由第二引擎发起的 `ready` / `close` / `activateMain` 由 `live_window.cpp` 处理；
/// 宿主发来的 `play`{url,title} 由 [setHandler] 接住。
class AylaDetachedWindowChannel {
  AylaDetachedWindowChannel({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel(kAylaDetachedWindowInnerChannel);

  final MethodChannel _channel;

  /// 告诉宿主「引擎已起来、第一帧已出」（宿主 `Show()` 据此结束等待）。
  Future<void> ready() async {
    try {
      await _channel.invokeMethod<bool>('ready');
    } on MissingPluginException {
      // 宿主未实现（例如被单独拿来跑）：静默，不影响播放。
    } on PlatformException {
      // 同上。
    }
  }

  /// 关闭窗口（不产生 `onLiveWindowClosed`：Dart 侧已经知道是它自己关的）。
  Future<void> close() async {
    try {
      await _channel.invokeMethod<bool>('close');
    } on MissingPluginException {
      // 静默。
    } on PlatformException {
      // 静默。
    }
  }

  /// 回主窗口（宿主会 restore + `SetForegroundWindow` 主窗口并关掉本窗）。
  Future<void> activateMain() async {
    try {
      await _channel.invokeMethod<bool>('activateMain');
    } on MissingPluginException {
      // 静默。
    } on PlatformException {
      // 静默。
    }
  }

  /// 注册宿主 → 本引擎的指令回调（目前只有 `play`）。
  void setHandler(void Function(String url, String title) onPlay) {
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'play') return null;
      final Object? raw = call.arguments;
      String url = '';
      String title = '';
      if (raw is Map) {
        final Object? u = raw['url'];
        final Object? t = raw['title'];
        if (u is String) url = u;
        if (t is String) title = t;
      }
      onPlay(url, title);
      return null;
    });
  }
}

// ======================= 画布样张 =======================

/// 独立小窗样张（画布验收面）：有画面 / 加载中两档。
Widget aylaDetachedLiveWindowSamples() {
  Widget stage(String label, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          width: 360,
          height: 202,
          child: ClipRect(child: child),
        ),
        const SizedBox(height: AylaSpacing.sp1),
        SizedBox(
          width: 360,
          child: Text(label, style: const TextStyle(fontSize: 11)),
        ),
      ],
    );
  }

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      stage(
        '脱离应用的直播小窗 · 有画面（360×202 = 16:9 · 宿主 WS_POPUP 无边框 · '
        '关闭键 24×24 内缩 6）',
        AylaDetachedLiveWindowSurface(
          title: '深夜电台 · 爱莉陪你写代码',
          video: const ColoredBox(color: Color(0xFF2A3550)),
          onClose: () {},
          onActivateMain: () {},
        ),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      stage(
        '同一小窗 · 加载中（画面未就绪时的状态文案）',
        AylaDetachedLiveWindowSurface(
          title: '深夜电台',
          statusText: '连接中…',
          onClose: () {},
          onActivateMain: () {},
        ),
      ),
    ],
  );
}
