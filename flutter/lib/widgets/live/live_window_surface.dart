/// 电脑端「脱离应用」的独立直播小窗 —— **第二引擎那棵树**的界面外壳。
///
/// ## 这不是普通的 App 内组件
/// 它跑在一个**独立的 Flutter engine** 里（见 `windows/runner/live_window.cpp` +
/// `lib/main.dart` 的 `aylaLiveWindowMain`），宿主窗口是：
/// `WS_POPUP | WS_CLIPCHILDREN | WS_CLIPSIBLINGS` + `WS_EX_TOPMOST | WS_EX_TOOLWINDOW`
/// ⇒ 无标题栏、恒置顶、**不进 Alt-Tab / 任务栏**，主窗口最小化后仍然可见。
///
/// ## 用户需求（2026-10-31 明确，务必照做）
/// 「直播小窗也是同样的，要直接用现有的直播小窗让他脱离应用，不要加按钮单独重做一个」
/// ⇒ 本文件**不画任何自己的视觉**：小窗本体就是 App 内那一个
/// [AylaLiveMiniPlayer]（同一份代码、同样的 168×94 圆角玻璃卡、同样外侧的
/// 关闭/脱离键位、同样的 hover/focus 配方），这里只负责：
/// 1. 把 `media_kit` 的播放面作为 `videoView` 注进去（第二引擎自己那一路 HLS）；
/// 2. 给它一块**恰好等于小窗本体**的窗口（`MediaQuery` 视口按 194×120 报，
///    于是组件默认落点 = (10,10)、168×94 刚好居中留出 10px 给"外侧"键位）；
/// 3. 把「点小窗 / 点关闭」接回宿主窗口（跨引擎没有 router）。
///
/// ## 为什么窗口要透明（2026-10-31）
/// `AylaLiveMiniPlayer` 的关闭键/脱离键在卡片**外侧**（`top/right: -10`，
/// `clipBehavior: Clip.none`）。宿主窗口若是纯黑不透明，那 10px 会变成黑边。
/// 所以 `live_window.cpp` 对两种浮层都开了逐像素透明
/// （`DwmExtendFrameIntoClientArea` + `ACCENT_ENABLE_TRANSPARENTGRADIENT`）。
///
/// ## 与 App 内小窗的**有意差异**（登记）
/// 1. 不挂 `AylaAuroraBackground` / ProviderScope / router / Dio / WS：这个引擎
///    只负责「一路 HLS + 小窗本体」，任何全局依赖都可能第二次跑起来（或拿不到数据）。
///    播放地址由主窗口在打开时一次性传入（`openLiveWindow.playUrl`，已归一 + 带鉴权 query）。
/// 2. 不再有「脱离应用」键：它**本身已经**脱离应用，再给一个同样的键是重复语义
///    （用户 2026-10-31 明确要求删掉那个键，组件侧已不再有该参数）。
/// 3. 拖动/双指缩放在独立窗口里只能移动**窗口内**的位置（改不了宿主窗口几何），
///    这是已知限制：组件原样复用优先于为它加一个「脱离态专用」分支。
///
/// ## 公开面
/// `AylaDetachedLiveWindowApp`（第二引擎的 runApp 目标）· `AylaDetachedWindowChannel`
/// （内层通道）· 样张 `aylaDetachedLiveWindowSamples()`
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../theme/tokens.dart';
import 'live_mini_player.dart' show AylaLiveMiniPlayer, kLiveMiniHeight, kLiveMiniWidth;

/// 宿主窗口 ↔ 第二引擎的私有通道（`live_window.cpp` 的
/// `AylaLiveWindowHost::CreateChannel` 逐字一致；**不是**给主引擎用的那条）。
const String kAylaDetachedWindowInnerChannel = 'ayla/desktop_window';

/// 卡片外侧键位需要的留白（`AylaLiveMiniPlayer` 的关闭键在 `top/right: -10`）。
const double kAylaDetachedMiniInset = 10;

/// 宿主窗口的逻辑尺寸 = 小窗本体 + 四周各 [kAylaDetachedMiniInset]。
///
/// ⚠️ 必须与 `windows/runner/live_window.cpp` 的 `kLiveWindowWidth/Height` 一致
/// （那里按 DPI 放大成物理像素；Flutter 侧看到的逻辑尺寸就是这个值）。
const double kAylaDetachedMiniWindowWidth =
    kLiveMiniWidth + kAylaDetachedMiniInset * 2;
const double kAylaDetachedMiniWindowHeight =
    kLiveMiniHeight + kAylaDetachedMiniInset * 2;

/// 报给 [AylaLiveMiniPlayer] 的**视口**尺寸。
///
/// 组件按 `viewport.width - 168 - 16` 算默认 left ⇒ 要让落点正好等于
/// [kAylaDetachedMiniInset]，视口必须比窗口再大 16px。
const Size kAylaDetachedMiniViewport = Size(
  kAylaDetachedMiniWindowWidth + 16,
  kAylaDetachedMiniWindowHeight + 16,
);

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

  /// 同上：初始标题（小窗的 title / 语义标签）。
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
  String _title = '直播间';
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
      setState(() => _title = title.isEmpty ? _title : title);
      unawaited(_open(url));
    });
    final String? initialUrl = widget.initialUrl;
    if (initialUrl != null && initialUrl.isNotEmpty) {
      // 兜底路径：不等宿主指令，直接起播（重复的 `play` 由 `_open` 的
      // 「同 URL 不重建」守卫吃掉）。
      unawaited(Future<void>.microtask(() => _open(initialUrl)));
    }
    // 第一帧出图后再告诉宿主：窗口先透明出现，不会白闪。
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
  /// shared_preferences / flutter_secure_storage / Dio / WS —— 见文件头第 1 条。
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
    // 播放面：与 App 内同一个用法（只交画面、不叠 media_kit 控制条、不申请唤醒锁
    // —— 第二个引擎只注册了 media_kit_video）。
    final Widget video = controller == null
        ? const ColoredBox(color: Colors.black)
        : Video(
            controller: controller,
            controls: NoVideoControls,
            wakelock: false,
            fit: BoxFit.contain,
            fill: Colors.black,
          );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      // 透明底：宿主窗口逐像素透明，卡片之外的 10px 必须透出桌面。
      color: Colors.transparent,
      home: AylaDetachedMiniPlayerHost(
        videoView: video,
        title: _title,
        statusText: _status,
        onOpenRoom: () => unawaited(_channel.activateMain()),
        onClose: () => unawaited(_channel.close()),
      ),
    );
  }
}

/// 独立小窗的**宿主外壳**：只给 [AylaLiveMiniPlayer] 摆位（纯复用，不重画）。
///
/// 视口用 [kAylaDetachedMiniViewport] 覆写 ⇒ 组件默认落点 (10,10)，
/// 168×94 的卡片 + 外侧键位正好落在 [kAylaDetachedMiniWindowWidth] ×
/// [kAylaDetachedMiniWindowHeight] 的宿主窗口内。
class AylaDetachedMiniPlayerHost extends StatelessWidget {
  const AylaDetachedMiniPlayerHost({
    super.key,
    this.videoView,
    this.title,
    this.statusText,
    this.onOpenRoom,
    this.onClose,
  });

  /// 视频画面（`media_kit` 的 `Video`）。
  final Widget? videoView;

  /// 频道标题（小窗 title / 语义标签）。
  final String? title;

  /// 画面未就绪时的状态文案（连接中 / 失败）——覆盖在画面上居中显示。
  final String? statusText;

  /// 点小窗主体 = 回主窗口。
  final VoidCallback? onOpenRoom;

  /// 关闭键 = 关掉独立小窗（会话本身不销毁）。
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final String? status = statusText;
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        size: kAylaDetachedMiniViewport,
        padding: EdgeInsets.zero,
        viewPadding: EdgeInsets.zero,
        viewInsets: EdgeInsets.zero,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            // 现有组件原样（返回 Positioned ⇒ 必须是 Stack 的直接子级）。
            AylaLiveMiniPlayer(
              videoView: videoView,
              channelTitle: title,
              onOpenRoom: onOpenRoom,
              onClose: onClose,
            ),
            if (status != null)
              // 状态文案只是**叠加**在画面之上的一行字，不改小窗本体。
              Positioned(
                left: kAylaDetachedMiniInset,
                top: kAylaDetachedMiniInset,
                width: kLiveMiniWidth,
                height: kLiveMiniHeight,
                child: IgnorePointer(
                  child: Center(
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
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 第二引擎 → 宿主窗口的**内层**通道（方向与主引擎的 `ayla/desktop_window` 相反）。
///
/// 由第二引擎发起的 `ready` / `close` / `activateMain` / `ballTap` 由
/// `live_window.cpp` 处理；宿主发来的 `play` / `ballPayload` 由对应 setter 接住。
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

  /// 关闭窗口（不产生关闭回调：Dart 侧已经知道是它自己关的）。
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

  /// 点了悬浮球（宿主把 (kind, sourceRoute) 转给主引擎；本窗口不关闭）。
  Future<void> ballTap({required String kind, required String sourceRoute}) async {
    try {
      await _channel.invokeMethod<bool>('ballTap', <String, Object?>{
        'kind': kind,
        'sourceRoute': sourceRoute,
      });
    } on MissingPluginException {
      // 静默。
    } on PlatformException {
      // 静默。
    }
  }

  /// 注册宿主 → 本引擎的指令回调（`play` / `ballPayload`）。
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
///
/// 舞台尺寸 = 宿主窗口的逻辑尺寸（[kAylaDetachedMiniWindowWidth] ×
/// [kAylaDetachedMiniWindowHeight]），背景刻意画成「桌面色」——
/// 透明窗口里这部分应当完全看不见。
Widget aylaDetachedLiveWindowSamples() {
  Widget stage(String label, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          width: kAylaDetachedMiniWindowWidth,
          height: kAylaDetachedMiniWindowHeight,
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
          width: kAylaDetachedMiniWindowWidth,
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
        '脱离应用的直播小窗 · 有画面（现有 AylaLiveMiniPlayer 原样 · 168×94 · '
        '宿主窗口 ${kAylaDetachedMiniWindowWidth.toInt()}×'
        '${kAylaDetachedMiniWindowHeight.toInt()} 透明，四周各 10px 留给外侧键位）',
        AylaDetachedMiniPlayerHost(
          title: '深夜电台 · 爱莉陪你写代码',
          videoView: const ColoredBox(color: Color(0xFF2A3550)),
          onOpenRoom: () {},
          onClose: () {},
        ),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      stage(
        '同一小窗 · 加载中（画面未就绪时的状态文案叠在画面上）',
        const AylaDetachedMiniPlayerHost(
          title: '深夜电台',
          statusText: '连接中…',
          onOpenRoom: null,
          onClose: null,
        ),
      ),
    ],
  );
}
