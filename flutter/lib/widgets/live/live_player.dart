/// 播放器区域三态渲染（`LivePlayer.tsx` 420 行）。
///
/// ## 事实源
/// ```
/// app.css 3517–3525   .live-player：relative · width 100% · **aspect-ratio 16/9** ·
///                     background rgba(70,91,146,.12) · radius-card · overflow hidden · 1px --glass-border
/// app.css 3528–3533   .live-player-video：100%×100% · object-fit contain · background #000
/// …（逐条 CSS 对照 / 层叠推导**原文**见 `docs/flutter/17-组件文件头归档（整理前原文）.md` 的 `widgets/live/live_player.dart` 一节）
/// ```
///
/// ## 机制差异
/// - **video 元素在 web 由 runtime 持有并在大窗/小窗之间原子迁移**；Flutter 侧由页面把
///   `HlsPlaybackController.videoView`（PoC-B 封装层）作为 [AylaLivePlayer.videoView] 注入，
///   组件只负责摆位与显隐（控制器生命周期属页面）；
/// - **画中画按钮不实现**：web 走浏览器 PiP API（`requestPictureInPicture` /
///   `webkitSetPresentationMode`），Flutter 端无等价物；窄屏本来就 `hidePipButton`，
///   手机端小窗由 [AylaLiveMiniPlayer] 承担 ⇒ 本件不渲染 PiP 键（登记为有意偏离）；
/// - **全屏**：web 用 `requestFullscreen()` 让容器进 top layer；Flutter 侧分两层：
///   ① **内容层** = 插 root Overlay 的全屏呈现（同一控制器、视图在 overlay 里重挂；
///      inline 侧在全屏期间不再挂视频，避免平台视图被同时 attach 两次）；
///   ② **窗口层**（仅桌面平台）= `window_manager.setFullScreen` 让**窗口本身**跳出应用边框，
///      覆盖整块显示器、无标题栏/任务栏 —— 这是 web `requestFullscreen()` 真正对应的行为，
///      只做 ① 时用户看到的是「App 窗口内黑一下」（2026-10 实报）。
///      进入/退出都是 `Win32Window` 的 HWND 变换，**不新建窗口、不新建 engine**；
///      退出时追加 `setTitleBarStyle(normal)` 复位 frameless（见
///      [AylaDesktopWindowController.restoreTitleBar]）。移动端仍走 ① + 锁横屏。
///
/// ## 公开面
/// `AylaLiveSrsStatus` · `AylaLivePlayer` · 样张 `aylaLivePlayerSamples()`

library;

import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show DeviceOrientation, LogicalKeyboardKey, SystemChrome;
import 'package:window_manager/window_manager.dart';

import '../../core/platform/system_ui.dart'
    show aylaSetImmersive, aylaUnlockOrientation;
import '../../layout/app_back.dart'
    show AylaLiveFullscreenBackHandler, aylaLiveFullscreenBackHandler;
import '../../theme/app_icons.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import 'live_hall.dart' show AylaLiveStatus;
import 'video_contain.dart'
    show AylaVideoContain, kAylaLiveVideoAspectRatio;
import '../base/overlays.dart';

/// SRS 直播服务状态（web `LiveSrsStatus`；null = 尚未查到）。
enum AylaLiveSrsStatus { degraded, idle, live }

/// 悬浮按钮无操作自动隐藏时长（tsx 24 `AUTO_HIDE_MS = 3000`）。
const Duration kLivePlayerAutoHide = Duration(milliseconds: 3000);

/// 刷新键旋转时长（app.css 3619 `live-refresh-spin 0.6s`；tsx 328 的复位计时 650ms）。
const Duration kLivePlayerSpin = Duration(milliseconds: 600);
const Duration kLivePlayerSpinReset = Duration(milliseconds: 650);

/// 桌面窗口控制（真·全屏）—— 可注入，便于测试断言「ESC 退出必须还原窗口」。
///
/// 为什么抽成接口而不是直接调 `windowManager`（生产环境的实现就是它）：
/// 组件测试跑在 **Windows 本机**，`defaultTargetPlatform == TargetPlatform.windows`
/// 天然成立 ⇒ 若直接调真实通道，每次进/退全屏都会打进 `window_manager` 的
/// MethodChannel（flutter_test 下无 handler ⇒ `MissingPluginException` 噪声）。
/// 注入替身后既能覆盖「真全屏路径」，又不碰插件。
abstract class AylaDesktopWindowController {
  const AylaDesktopWindowController();

  /// 窗口当前是否最大化。
  ///
  /// ⚠️ 这个查询存在的唯一理由见 [setFullScreen] 的说明：window_manager 在
  /// 「最大化状态进全屏」这条路径上有缺陷，必须**先解除最大化**再进全屏。
  Future<bool> isMaximized();

  /// 解除最大化（还原到普通窗口尺寸）。
  Future<void> unmaximize();

  /// 进入 / 退出窗口级全屏（覆盖整块显示器、无标题栏、无任务栏）。
  ///
  /// ## ⚠️⚠️ 实现必须遵守：进全屏前先解除最大化（2026-10-31 用户实报根因）
  ///
  /// 用户原话：「窗口最大化时点全屏按钮 = **完全没全屏成功**；窗口窗口化时点全屏
  /// = 全屏成功但顶部导航栏没被覆盖」。前者就是下面这条缺陷：
  ///
  /// window_manager 0.5.2 `SetFullScreen`（windows/window_manager.cpp）在进全屏时：
  /// ```cpp
  /// if (!g_maximized_before_fullscreen) {
  ///   SetAsFrameless();                      // ← 只在「进全屏前不是最大化」时才剥边框
  /// }
  /// ::SetWindowLongPtr(GWL_STYLE, style & ~(WS_THICKFRAME | WS_MAXIMIZEBOX));
  /// ```
  /// 而 `SetAsFrameless()` 才是真正让 `WM_NCCALCSIZE` 返回 0（客户区=整窗）的那一步。
  /// 于是**从最大化进全屏**时它被跳过 ⇒ 窗口虽然被 SetWindowPos 拉到 rcMonitor，
  /// 但仍保留非客户区（标题栏/边框）⇒ 看起来「根本没全屏」。
  ///
  /// 对策：进全屏前若 `isMaximized()` 为真，先 `unmaximize()` —— 这样
  /// `g_maximized_before_fullscreen` 变成 false，window_manager 就会走正确分支。
  /// （window_manager 自己在 `waitUntilReadyToShow` 里也是这个顺序：
  ///  `if (await isMaximized()) await unmaximize();`）
  Future<void> setFullScreen(bool fullscreen);

  /// 还原窗口边框样式。
  ///
  /// ⚠️ **退出全屏后必须追加调用**（window_manager 0.5.2 `window_manager.cpp`
  /// `SetFullScreen` 的真实缺陷）：它只在「退出全屏时窗口**不是**最大化」的分支里
  /// 才把 `title_bar_style_` / `is_frameless_` 复位到进全屏前的值
  /// （`if (::IsZoomed(mainWindow))` 的 else 分支）；而「最大化状态下进全屏」会让
  /// 进全屏那一步先 `SetAsFrameless()` 把 `is_frameless_` 置真，
  /// 退出时走的是 IsZoomed 分支 ⇒ **永久留在 frameless**（标题栏再也不回来）。
  /// `setTitleBarStyle(TitleBarStyle.normal)` 是唯一能把这两者都复位的入口。
  Future<void> restoreTitleBar();
}

/// 生产实现：`window_manager`（纯 HWND 变换，同一个 engine，不新建窗口）。
///
/// 选它而不是自写 Win32 全屏：本仓库 runner 的 `Win32Window` 已经承担
/// WM_NCCALCSIZE / 客户区计算，再挂一套 frameless 的 NCCALCSIZE owner 会互相抢
/// 边框重算 ⇒ 进出全屏闪烁（研究结论）。
class _AylaWindowManagerController extends AylaDesktopWindowController {
  const _AylaWindowManagerController();

  @override
  Future<bool> isMaximized() => windowManager.isMaximized();

  @override
  Future<void> unmaximize() => windowManager.unmaximize();

  @override
  Future<void> setFullScreen(bool fullscreen) =>
      windowManager.setFullScreen(fullscreen);

  @override
  Future<void> restoreTitleBar() =>
      windowManager.setTitleBarStyle(TitleBarStyle.normal);
}

/// 系统栏（状态栏 / 导航栏）的隐藏与恢复 —— 可注入，便于测试断言「进/退全屏各做了什么」。
///
/// 为什么抽成接口而不是直接调 [aylaSetImmersive]（与 [AylaDesktopWindowController]
/// 同一理由）：组件测试跑在 Windows 本机，`defaultTargetPlatform` 天然是 windows
/// ⇒ 直接调真实实现会让「移动端是否隐藏了状态栏」变得不可测；注入替身后
/// 既能覆盖移动端路径，又不需要在每个用例里改平台标志（会被 binding 的
/// `debugAssertAllFoundationVarsUnset` 判为失败）。
abstract class AylaSystemUiController {
  const AylaSystemUiController();

  /// 进入（true）/ 退出（false）沉浸式：隐藏或恢复状态栏与导航栏。
  Future<void> setImmersive(bool enabled);
}

/// 生产实现：[aylaSetImmersive]（Android 走原生通道，iOS 走 SystemChrome）。
class _MobileSystemUiController extends AylaSystemUiController {
  const _MobileSystemUiController();

  @override
  Future<void> setImmersive(bool enabled) => aylaSetImmersive(enabled);
}

/// 本件是否走「窗口级真·全屏」。
///
/// 只对 `window_manager` 真正支持的桌面平台为真（Windows / macOS / Linux）；
/// 移动端（Android / iOS）保持既有「root Overlay + 锁横屏」不变。
/// Web 上没有窗口概念 ⇒ 排除。
bool aylaUsesDesktopFullscreen({
  TargetPlatform? platform,
  bool isWeb = kIsWeb,
}) {
  if (isWeb) return false;
  switch (platform ?? defaultTargetPlatform) {
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
      return true;
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return false;
  }
}

/// 播放器区域三态渲染（`LivePlayer.tsx`）。
class AylaLivePlayer extends StatefulWidget {
  const AylaLivePlayer({
    super.key,
    this.srsStatus,
    this.optimisticStatus,
    this.playerError,
    this.videoView,
    this.videoAspectRatio,
    this.onRetry,
    this.onRefresh,
    this.onSendDanmaku,
    this.danmakuOwner,
    this.danmakuError,
    this.children,
    this.overlayHostBuilder,
    this.onFullscreenChanged,
    this.onEnterMiniPlayer,
    this.desktopWindow,
    this.desktopFullscreen,
    this.systemUi,
    this.flat = false,
  });

  /// SRS 状态；**null = 正在查询**（tsx 332）。
  final AylaLiveSrsStatus? srsStatus;

  /// 频道乐观状态（idle 占位文案区分「等待推流信号」用，tsx 344）。
  final AylaLiveStatus? optimisticStatus;

  /// 播放致命错误（live 但播放失败 → 「播放失败 + 重试」，tsx 352）。
  final String? playerError;

  /// 视频视图（页面注入 `HlsPlaybackController.videoView`；null = 无画面）。
  final Widget? videoView;

  /// 画面宽高比（页面注入 `HlsPlaybackController.videoAspectRatio`）。
  ///
  /// ## 🔒 语义：**限死**，不是「有就用、没有就铺满」（2026-11-01 用户第二轮反馈）
  /// 用户原话：「还是有概率拉伸，直接把全屏播放器的长宽比限死不就行了」——
  /// 上一版写成「null ⇒ 不套等比盒、原样铺满」，于是只要比例**晚于进全屏**上报
  /// （刚进房 / 播放器刚自愈重建）就必然拉伸一次。现在：
  ///
  /// | 注入值 | 用哪个比例 |
  /// |---|---|
  /// | null（默认 / 未上报 / media_kit 不报） | [kAylaLiveVideoAspectRatio]（16:9，锁死） |
  /// | 有效值 | 用它（真实流比例，比 16:9 更准） |
  /// | 非有限 / ≤0 | [kAylaLiveVideoAspectRatio]（不产出 NaN 尺寸） |
  ///
  /// ⇒ **任何时刻都有确定的等比盒**，最坏是「非 16:9 的流按 16:9 收盒」（画面略小 +
  /// 四周留黑），永远不会是拉伸。
  ///
  /// ## 为什么由页面注入而不是组件自己查
  /// 组件只拿得到 [videoView]（一个 Widget），拿不到它背后的控制器；而
  /// `video_player` 的 `Texture` **没有** `fit` 能力（`RenderTexture` 是
  /// RenderProxyBox，尺寸 = 父约束）。实现 `HlsVideoMetrics` 的平台播放器
  /// （Android/iOS）上报的比例就是 `<video>.videoWidth / videoHeight` 的等价物。
  final double? videoAspectRatio;

  /// 重试（tsx 356）。
  final VoidCallback? onRetry;

  /// 跳到直播最新画面（左下刷新键，tsx 325）。
  final VoidCallback? onRefresh;

  /// 全屏发弹幕（tsx 171）；null = 不渲染全屏输入框。
  final Future<bool> Function(String content)? onSendDanmaku;

  /// 全屏草稿的归属（换人不复用草稿，tsx 173）。
  final String? danmakuOwner;

  /// 全屏发送错误文案（tsx 174）。
  final String? danmakuError;

  /// 画面叠加层（飘弹幕层等；渲染时机由调用方控制，tsx 376）。
  final Widget? children;

  /// 全屏呈现的宿主（默认插 root Overlay；测试可注入替身）。
  final OverlayEntry Function(Widget child)? overlayHostBuilder;

  /// 全屏状态变化（web 由 `document.fullscreenchange` 通知 `LiveRoomBody` 冻结 isNarrow，
  /// 防锁横屏导致窄↔宽切换、播放器重建黑屏 —— tsx 96–111）。
  final ValueChanged<bool>? onFullscreenChanged;

  /// 「小窗」键：把直播变成**应用窗口之外**的悬浮小窗（2026-10-31 用户需求）。
  ///
  /// ## 为什么在播放器上，而不是像 web 那样由 `AppShell` 自动渲染
  /// web 的 `LiveMiniPlayer` 是「离开直播间页面 ⇒ 自动出现」（`detachView` 判定窄屏 + 直播中）。
  /// 但**电脑端**用户要的是显式操作：
  /// > 「电脑需要点按钮使直播变为悬浮小窗，但手机退出直播间自动续直播悬浮小窗」
  /// ⇒ 桌面端由本键触发；移动端仍走既有的「退出页面自动续」路径（不渲染本键）。
  ///
  /// **null = 不渲染该键**（移动端 / 测试 / 平台不支持时）。
  final VoidCallback? onEnterMiniPlayer;

  /// 桌面窗口控制器（默认 = `window_manager`；测试注入替身，见
  /// [AylaDesktopWindowController]）。
  final AylaDesktopWindowController? desktopWindow;

  /// 是否走窗口级真·全屏；null = 按 [aylaUsesDesktopFullscreen] 依当前平台判定。
  final bool? desktopFullscreen;

  /// 系统栏控制器（默认 = 生产实现；测试注入替身断言「进了几次/什么值」）。
  ///
  /// 只在**移动端**全屏时使用：桌面端的系统栏由窗口级全屏吞掉（见
  /// [AylaDesktopWindowController]），不需要这一层。
  final AylaSystemUiController? systemUi;

  /// **扁平档**：圆角与边框交给外层 stage 裁剪（web `.live-room-swipe-item .live-player
  /// { border-radius: 0; border: none }`，live.css 747–751）——窄屏沉浸式用，
  /// 由 `.live-room-stage` 统一收 `--radius-input` 圆角（live.css 825–828）。
  final bool flat;

  @override
  State<AylaLivePlayer> createState() => _AylaLivePlayerState();
}

class _AylaLivePlayerState extends State<AylaLivePlayer> {
  bool _controlsVisible = false;
  bool _spinning = false;
  bool _fullscreen = false;
  Timer? _hideTimer;
  Timer? _spinTimer;
  OverlayEntry? _fsEntry;
  bool _desktopFsActive = false;

  /// 返回键处理器的**稳定实例**（注册与注销必须用同一份引用）。
  ///
  /// 每次求值 tear-off 都会产生新对象；存一份字段后用 [identical] 判定，
  /// 注册/注销的语义就没有任何歧义。
  late final AylaLiveFullscreenBackHandler _backHandler =
      _handleSystemBackInFullscreen;

  bool get _showVideo =>
      widget.srsStatus == AylaLiveSrsStatus.live && widget.playerError == null;

  /// setState 并**同步刷新全屏层**。
  ///
  /// 全屏层插在 root Overlay 里，是**独立于本 State 的一棵子树** —— 本件
  /// `setState` 只会重建 inline 侧；overlay 子树必须显式 [OverlayEntry.markNeedsBuild]
  /// 才会跟着这一帧重建（否则它读到的永远是进全屏那一刻的快照，
  /// 详见 [_toggleFullscreen] 里的根因记录）。
  void _setStateAndSync(VoidCallback change) {
    setState(change);
    // 事件回调 / 计时器回调里调用，不在 build 阶段 ⇒ markNeedsBuild 合法
    _syncFullscreenLayer();
  }

  /// 下次重建是否已经排好（[_syncFullscreen] 去重）。
  bool _fsSyncQueued = false;

  /// 全屏层的**重建代号**（B1）。
  ///
  /// ## 为什么光有 markNeedsBuild 还不够（自定义宿主那条路径）
  /// markNeedsBuild 会让 OverlayEntry 的 builder 重跑，但 builder 里返回的是
  /// overlayHostBuilder 捕获的那个 child —— **同一个 Widget 实例**。而 Flutter 的
  /// Element.updateChild 在「新旧 widget identical」时会直接短路返回、**不重建子树**。
  /// ⇒ 自定义宿主路径下 markNeedsBuild 完全无效，全屏层仍是旧快照。
  ///
  /// 所以自定义宿主拿到的不是 _buildFullscreen() 的结果，而是一个挂着本 notifier
  /// 的 ValueListenableBuilder：代号一变，它自己就会重新调用 _buildFullscreen()
  /// 取到**当前**的 videoView / 比例 / 控件状态。
  final ValueNotifier<int> _fsRevision = ValueNotifier<int>(0);

  /// 只刷新全屏层（[widget] 换了新值但没有本地状态变化时）。
  ///
  /// ⚠️ 必须**排到帧末**：本方法在 [didUpdateWidget] 里被调用，而那时正处于
  /// build 阶段 —— 直接对另一个 Element 调 `markNeedsBuild` 会被框架丢弃
  /// （实测：比例迟到时全屏层仍是旧快照）。帧末排一次即可收敛，且不会自激。
  ///
  /// [force] = 播放器输入（videoView / 比例 / SRS 状态 / 错误）变了（B1）：此时
  /// 即使本帧已经排过一次也要再排一次 —— 排的那一次可能发生在**换视图之前**，
  /// 它拉起来的那一帧读到的还是旧 videoView（全屏黑屏），必须补排。
  /// 仍走帧末回调，所以不会踩「build 阶段改别人 Element」的坑。
  void _syncFullscreen({bool force = false}) {
    if (_fsEntry == null) return;
    if (_fsSyncQueued && !force) return;
    _fsSyncQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fsSyncQueued = false;
      if (!mounted) return;
      _syncFullscreenLayer();
    });
  }

  /// 让全屏层重建一次（B1 的唯一出口：markNeedsBuild + 代号自增）。
  ///
  /// 两条路径各自生效：
  /// · 默认宿主（aylaOverlayEntry 的 WidgetBuilder）⇒ markNeedsBuild 就够；
  /// · 自定义宿主 ⇒ 靠 [_fsRevision] 让那个 ValueListenableBuilder 自己重建
  ///   （markNeedsBuild 会因 identical 短路而无效，见该字段说明）。
  /// 两个都做是幂等的：任一先到达都能拿到最新画面，连做两次只是多一次 setState。
  void _syncFullscreenLayer() {
    final OverlayEntry? entry = _fsEntry;
    if (entry == null) return;
    entry.markNeedsBuild();
    _fsRevision.value += 1;
  }

  /// 是否走窗口级真·全屏（桌面平台）。
  bool get _desktopFullscreen =>
      widget.desktopFullscreen ?? aylaUsesDesktopFullscreen();

  AylaDesktopWindowController get _window =>
      widget.desktopWindow ?? const _AylaWindowManagerController();

  @override
  void dispose() {
    _hideTimer?.cancel();
    _spinTimer?.cancel();
    // 全屏中直接离开页面 ⇒ 返回键处理器必须注销，否则它指向已销毁的 State。
    if (identical(aylaLiveFullscreenBackHandler, _backHandler)) {
      aylaLiveFullscreenBackHandler = null;
    }
    _fsEntry?.remove();
    _fsEntry = null;
    // B1：全屏层的重建代号随 State 一起释放（它被那棵 overlay 子树监听）。
    _fsRevision.dispose();
    // 用户在全屏中直接离开页面 ⇒ 窗口必须还原，否则整个 App 卡在无边框全屏。
    // 不 await：dispose 不能等异步；实现内部是 HWND 变换，异常只打日志不上抛。
    if (_desktopFsActive) {
      _desktopFsActive = false;
      unawaited(_applyDesktopFullscreen(false));
    }
    // 全屏中直接离开页面 ⇒ 系统栏必须恢复，否则整个 App 留在「没有状态栏」的形态。
    // （与 `_fsEntry.remove()` 同一档：dispose 里不能等异步，实现内部吞异常只记日志。）
    if (_fullscreen && !_desktopFullscreen) _applyImmersive(false);
    _unlockOrientation();
    super.dispose();
  }

  /// 窗口级全屏的进入/退出（桌面平台）。
  ///
  /// 顺序与理由：
  /// 1. **进全屏前先解除最大化**（`unmaximize`）—— 这是 2026-10-31 用户实报
  ///    「窗口最大化时点全屏完全没成功」的根因：window_manager 只在
  ///    `!g_maximized_before_fullscreen` 时才调 `SetAsFrameless()`（真正剥掉非客户区
  ///    的那一步），从最大化进全屏会跳过它 ⇒ 窗口拉满显示器但仍带标题栏。
  ///    详见 [AylaDesktopWindowController.setFullScreen] 的注释。
  /// 2. 再 `setFullScreen(true)` —— 此时 window_manager 走正确分支。
  /// 3. 退全屏：`setFullScreen(false)` **之后追加** `restoreTitleBar()`，
  ///    否则「最大化状态进全屏」会永久留在 frameless（见
  ///    [AylaDesktopWindowController.restoreTitleBar] 的缺陷说明）。
  /// 4. 每步都独立 try/catch：窗口控制失败绝不能让播放器状态机卡死
  ///    （否则全屏层已插、窗口没进 —— 用户看到「黑一下」且退不回去）。
  Future<void> _applyDesktopFullscreen(bool fullscreen) async {
    final AylaDesktopWindowController window = _window;
    if (fullscreen) {
      try {
        if (await window.isMaximized()) {
          await window.unmaximize();
        }
      } on Object catch (error, stack) {
        debugPrint('[AYLA-FULLSCREEN] unmaximize 失败：$error\n$stack');
      }
    }
    try {
      await window.setFullScreen(fullscreen);
    } on Object catch (error, stack) {
      debugPrint('[AYLA-FULLSCREEN] setFullScreen($fullscreen) 失败：$error\n$stack');
    }
    if (fullscreen) return;
    try {
      await window.restoreTitleBar();
    } on Object catch (error, stack) {
      debugPrint('[AYLA-FULLSCREEN] restoreTitleBar 失败：$error\n$stack');
    }
  }

  // ---- 悬浮按钮显隐 + 3s 无操作自动隐藏（tsx 243–261）----
  void _clearHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  void _armHideTimer() {
    _clearHideTimer();
    _hideTimer = Timer(kLivePlayerAutoHide, () {
      if (mounted) _setStateAndSync(() => _controlsVisible = false);
    });
  }

  void _showControls() {
    _setStateAndSync(() => _controlsVisible = true);
    _armHideTimer();
  }

  void _hideControls() {
    if (!mounted) return;
    _setStateAndSync(() => _controlsVisible = false);
    _clearHideTimer();
  }

  // ---- 刷新（tsx 321–329：0.65s 后复位；用计时器保证 reduced-motion 下也能复位）----
  void _handleRefresh() {
    _armHideTimer();
    if (_spinning) return;
    _setStateAndSync(() => _spinning = true);
    widget.onRefresh?.call();
    _spinTimer?.cancel();
    _spinTimer = Timer(kLivePlayerSpinReset, () {
      if (mounted) _setStateAndSync(() => _spinning = false);
    });
  }

  // ---- 全屏（web：容器 requestFullscreen；Flutter：root Overlay + 移动端锁横屏）----
  void _lockLandscape() {
    // 桌面/Web 忽略（web 侧同样静默失败，tsx 46–57）
    if (Theme.of(context).platform == TargetPlatform.android ||
        Theme.of(context).platform == TargetPlatform.iOS) {
      unawaited(
        SystemChrome.setPreferredOrientations(<DeviceOrientation>[
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]),
      );
    }
  }

  /// 恢复朝向 —— 与 [aylaUnlockOrientation] 同一实现（统一到 core/platform，见那里）。
  void _unlockOrientation() => unawaited(aylaUnlockOrientation());

  /// 进/退「沉浸式」（隐藏/恢复状态栏与导航栏）。
  ///
  /// ## 为什么是独立的一步（2026-11-01 用户实报「全屏时顶部状态栏要隐藏」）
  ///
  /// 此前全屏只做了「插 root Overlay + 锁横屏」，**从没碰过系统栏** ⇒ 状态栏一直
  /// 压在画面上（横屏时那一截就是黑边里的一块白字）。
  ///
  /// ⚠️ 光调 `SystemChrome.setEnabledSystemUIMode` 在**本工程上无效**：
  /// `targetSdk = 36`（Android 16）下 Flutter 引擎对 `leanBack/immersive/immersiveSticky`
  /// 只是设 legacy flags + `View.setSystemUiVisibility`，而该 API 在 Android 16 已失效
  /// ⇒ 必须走原生 `WindowInsetsController`。完整依据见 `core/platform/system_ui.dart`。
  ///
  /// 顺序：**先**藏系统栏再锁横屏 —— 旋转期间系统栏会自己回弹，藏得早一点能让
  /// 「旋转完成时状态栏已不在」；退出时反过来：先恢复系统栏再解锁朝向。
  ///
  /// 实现可注入（见 [AylaSystemUiController]）：测试用替身断言「进/退各下发了一次」，
  /// 不必改 `defaultTargetPlatform`（会被 binding
  /// 的 `debugAssertAllFoundationVarsUnset` 判为失败）。
  void _applyImmersive(bool enabled) {
    final AylaSystemUiController ui =
        widget.systemUi ?? const _MobileSystemUiController();
    unawaited(ui.setImmersive(enabled));
  }

  void _toggleFullscreen() {
    _armHideTimer();
    if (_fullscreen) {
      _exitFullscreen();
      return;
    }
    setState(() => _fullscreen = true);
    widget.onFullscreenChanged?.call(true);
    // 移动端：藏掉状态栏/导航栏（桌面端由窗口级全屏承担，见下）
    if (!_desktopFullscreen) _applyImmersive(true);
    _lockLandscape();
    // **桌面端真·全屏**：窗口本身跳出应用边框（覆盖整块显示器、无标题栏/任务栏）。
    // 移动端这一步是 no-op，仍是原来的「root Overlay + 锁横屏」。
    if (_desktopFullscreen) {
      _desktopFsActive = true;
      unawaited(_applyDesktopFullscreen(true));
    }
    // ⚠️⚠️ **这里曾有一个运行期崩溃，是「手机端直播无法全屏」的真正根因**（2026-10-19）：
    //
    // 旧写法 `(widget.overlayHostBuilder ?? aylaOverlayEntry)(_buildFullscreen())`
    // 把 overlay 构造函数当成 `(Widget child) => OverlayEntry` 直接调用。
    // 但 [aylaOverlayEntry] 的真实签名是具名参数：
    //     OverlayEntry aylaOverlayEntry({required WidgetBuilder builder})
    // ⇒ 传位置参数必然抛 `NoSuchMethodError: Closure call with mismatched arguments:`
    // `function 'aylaOverlayEntry' ... Found: aylaOverlayEntry({required (BuildContext) => Widget builder})`
    // ⇒ **点全屏键只会抛异常，全屏层永远插不进去**。web 没有这个问题（它走
    // `requestFullscreen()` 原生 API），所以这个缺陷只在 Flutter 侧存在，而且因为
    // 异常被手势回调吞掉、UI 毫无反馈，很容易被误判成"功能没做"。
    //
    // 现在两条路径各自按自己的签名构造，不再混用：
    // · 注入了 [overlayHostBuilder] ⇒ 调用方负责（测试/画布用它替换宿主）；
    // · 未注入 ⇒ 用库内 [aylaOverlayEntry] 的**具名 builder** 形式（自动套文本作用域，
    //   否则 overlay 子树的 Text 会落到 `DefaultTextStyle.fallback` 的红/黄双下划线）。
    // ⚠️⚠️ **这里曾有一个「还是有概率拉伸」的真根因**（2026-11-01 用户复报）：
    //
    // 旧写法把 `_buildFullscreen()` 的**结果**（一个已经构建好的 Widget 实例）captured
    // 进 overlay 的 builder 闭包：
    //     final Widget fullscreen = _buildFullscreen();
    //     aylaOverlayEntry(builder: (ctx) => fullscreen)
    // ⇒ overlay 子树**永远渲染那一份快照**，State 再 setState 也不会重建它。
    //
    // 后果（全部是「看起来偶发」的确定性缺陷）：
    // · `widget.videoAspectRatio` 在**点全屏那一刻**还没上报（刚进房 / HLS 刚自愈重建
    //   播放器）⇒ 全屏层永远停在「比例未知」⇒ 原样铺满 ⇒ **拉伸**，之后再也不会自愈；
    // · `_controlsVisible` 永远停在进全屏那一刻（= true）⇒ 3s 自动隐藏在全屏里**从不生效**；
    // · `_spinning` 同理 ⇒ 全屏里点刷新不转圈。
    //
    // ⇒ 正确形状：builder **每次重建都重新求值**（读当前 widget / 当前 State 字段），
    // 再由 [setState] 统一通过 [markNeedsBuild] 把独立子树拉进这一帧。
    //
    // ---- 【B1】全屏层必须是「活」的，不能是捕获时刻的快照（开发文档 §3 B1）----
    //
    // 用户实报：「全屏中黑屏，点刷新/重试都无效，必须退出全屏再进」（需求 §3.1 B1）。
    // 根因与上一段同源，但**只修默认路径不够**：
    // · 默认路径（aylaOverlayEntry）本来就要求 WidgetBuilder，天然动态；
    // · 自定义路径（[overlayHostBuilder]，测试/画布/宿主替换用）拿的是 `Widget child`，
    //   于是旧写法 `custom(_buildFullscreen())` 又把**已构建实例**交出去 ⇒ 宿主把它塞进
    //   自己的 builder 闭包里 ⇒ 播放器自愈重建、`widget.videoView` 换成新视图后，
    //   全屏层仍渲染**旧 videoView**（旧纹理早已随 rebuild 释放）⇒ 全屏永久黑屏，
    //   而 inline 侧是好的 ⇒ 用户只能「退出全屏再进」才能看到画面。
    //
    // 修法：交给自定义宿主的**也是一个 Builder**（不是构建结果）—— 宿主无论怎么包，
    // 真正的 `_buildFullscreen()` 都要等那棵子树被重建时才求值 ⇒ 两条路径一致。
    // 再配合 [_setStateAndSync] / [_syncFullscreen] 里的 `_fsEntry?.markNeedsBuild()`
    // （播放器状态变化时把 overlay 子树拉进同一帧），自愈重建后全屏层立刻换成新画面。
    final OverlayEntry Function(Widget child)? custom = widget.overlayHostBuilder;
    final OverlayEntry entry = custom != null
        // ⚠️ 这里交出去的**不能**是 `_buildFullscreen()` 的结果，也不能只是 Buffer/Builder：
        // 宿主的 builder 闭合了那个 child 实例 ⇒ Flutter 的 identical 快路径会让
        // markNeedsBuild 空转（见 [_fsRevision] 的说明）。挂上重建代号之后，
        // 宿主怎么包都能在代号变化时重新取到当前画面。
        ? custom(
            ValueListenableBuilder<int>(
              valueListenable: _fsRevision,
              builder: (BuildContext _, int __, Widget? ___) => _buildFullscreen(),
            ),
          )
        : aylaOverlayEntry(
            builder: (BuildContext ctx) => _buildFullscreen(),
          );
    _fsEntry = entry;
    // ⚠️⚠️ **必须插根 Overlay，不能用最近的那个**（2026-10-31 用户实报「全屏后顶部导航栏
    // 仍露在外面」的根因）。
    //
    // 本工程的路由是 `ShellRoute`：`AppShell` 里是
    //   Column[ TopNav, Expanded(ClipRect(shell navigator)), BottomTabs ]
    // 而**页面**跑在 shell navigator 的 Overlay 里。于是：
    // · `Overlay.of(context)`（最近的那个）= shell navigator 的 Overlay ⇒ 全屏层被塞进
    //   `Expanded(ClipRect(...))` 内部 ⇒ **TopNav 与底栏永远压在它上面**，
    //   ClipRect 还会把溢出部分裁掉 ⇒ 看起来就是「App 内一块黑，不是全屏」；
    // · `rootOverlay: true` = Navigator 的根 Overlay（`MaterialApp.builder` 那层之下、
    //   在 TopNav 之上）⇒ 才是真正的整窗覆盖。
    //
    // 旧注释担心的「画布/测试宿主没有 Navigator ⇒ 抛 No Overlay」仍然成立，故保留
    // try/catch 回落：拿不到根 Overlay 就退回最近的那个（画布/单测场景），
    // 真实 App 里根 Overlay 一定存在 ⇒ 走的是正确路径。
    OverlayState? root;
    try {
      root = Overlay.of(context, rootOverlay: true);
    } catch (_) {
      root = null;
    }
    (root ?? Overlay.of(context)).insert(entry);
    // 登记「全屏期间的返回键」处理器（见 `layout/app_back.dart` 的
    // [AylaLiveFullscreenBackHandler]）：手机返回键先退全屏、**不**关直播间。
    aylaLiveFullscreenBackHandler = _backHandler;
  }

  /// 系统返回键落在全屏里时：只退出全屏，返回 true 表示「本次已处理」。
  ///
  /// ⚠️ 必须返回 true：返回 false 会把事件交回框架 ⇒ 走 `context.pop()`
  /// ⇒ 用户直接被弹出直播间（正是修复前实报的现象）。
  bool _handleSystemBackInFullscreen() {
    if (!mounted || !_fullscreen) return false;
    _exitFullscreen();
    return true;
  }

  void _exitFullscreen() {
    // 先注销返回键处理器：退全屏之后返回键应当恢复「离开直播间」的正常语义。
    if (identical(aylaLiveFullscreenBackHandler, _backHandler)) {
      aylaLiveFullscreenBackHandler = null;
    }
    _fsEntry?.remove();
    _fsEntry = null;
    // 先还原窗口（含 frameless 复位），再解方向锁 —— 顺序固定，便于测试断言。
    if (_desktopFsActive) {
      _desktopFsActive = false;
      unawaited(_applyDesktopFullscreen(false));
    }
    // 移动端：恢复系统栏（与进全屏的 [_applyImmersive] 成对，绝不遗留隐藏态）
    if (!_desktopFullscreen) _applyImmersive(false);
    _unlockOrientation();
    widget.onFullscreenChanged?.call(false);
    if (mounted) setState(() => _fullscreen = false);
  }

  /// 全屏呈现：铺满窗口的黑底 + 同一画面 + 同一悬浮控件（含全屏弹幕输入）。
  Widget _buildFullscreen() {
    return _LivePlayerFullscreenHost(
      onExit: _exitFullscreen,
      child: Builder(
        // 全屏里的播放器内容与 inline 共用同一构建函数（同一控制器）
        builder: (BuildContext ctx) => _content(fullscreen: true),
      ),
    );
  }

  @override
  void didUpdateWidget(covariant AylaLivePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 父级把新值（画面比例 / SRS 状态 / 弹幕叠加层 / 播放错误…）喂进来了 ⇒
    // 全屏那棵独立子树必须跟着重建，否则它停在旧快照上（= 「还是有概率拉伸」的
    // 后半段：比例后来才上报，而全屏层从不重读）。
    //
    // ---- 【B1】播放器状态变化 ⇒ 立刻刷新全屏层（开发文档 §3 B1）----
    //
    // 这一条覆盖用户实报的「全屏中黑屏、点刷新/重试都无效」出现频率最高的那条路径：
    // HLS 自愈重建后 `watch` 到的是新的 [videoView]，父级 setState ⇒ 本方法被调用。
    // 若此时不同步 overlay 子树，全屏层**仍然渲染重建前的那个 videoView**（旧纹理已随
    // `dispose()` 释放）⇒ 全屏永久黑屏，而 inline 侧是正常的。
    //
    // 判据取「播放器相关输入是否变了」而不是无条件同步：`_syncFullscreen` 走帧末
    // post-frame 回调，每帧都排一次没有意义（弹幕叠加层等变化由上面的静态分支覆盖）。
    final bool playerInputsChanged =
        !identical(oldWidget.videoView, widget.videoView) ||
            oldWidget.videoAspectRatio != widget.videoAspectRatio ||
            oldWidget.srsStatus != widget.srsStatus ||
            oldWidget.playerError != widget.playerError;
    _syncFullscreen(force: playerInputsChanged);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => _showControls(),
      onHover: (_) => _showControls(), // onMouseMove 等价（tsx 370）
      onExit: (_) => _hideControls(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _showControls, // `onClick={showControls}`（触屏点击视频显示）
        child: _content(fullscreen: false),
      ),
    );
  }

  /// 播放器内容（inline 与全屏共用）。
  ///
  /// ## 两档容器（事实源 `app.css:3517–3525` 与 `:3639–3646`）
  /// - **inline**：`.live-player { aspect-ratio: 16/9; radius-card; 1px 亮边 }`；
  /// - **全屏**：`.live-player:fullscreen { width:100vw; height:100vh;
  ///   aspect-ratio:auto; border-radius:0; border:none; background:#000 }`
  ///   ⇒ **容器铺满整屏**（不再受 16:9 限制），画面在其中 letterbox。
  ///
  /// ⚠️ 此前全屏用的是 `AspectRatio(aspectRatio: 1)`（正方形占位），在展开约束下
  /// 虽被拉伸成整屏、但语义是错的（一旦父级不再强制 expand 就会变成正方形黑块）。
  /// 现在全屏档直接返回「铺满 + 黑底」，比例交给画面自己（见 [_surface] 里的
  /// [AylaVideoContain]）。
  Widget _content({required bool fullscreen}) {
    final Widget surface = _surface(fullscreen: fullscreen);
    if (fullscreen) {
      return ColoredBox(color: Colors.black, child: surface);
    }
    return AspectRatio(
      // `.live-player { aspect-ratio: 16 / 9 }`
      aspectRatio: 16 / 9,
      child: surface,
    );
  }

  /// 播放面：视频（含等比收盒）+ 飘弹幕 + 悬浮控件。
  Widget _surface({required bool fullscreen}) {
    return DecoratedBox(
        decoration: BoxDecoration(
          // 全屏档的底色是**纯黑**（web `.live-player:fullscreen { background: #000 }`，
          // app.css:3639–3646）—— 留黑的那一圈必须是 #000，不能是页面主色的 12% 叠色。
          color: fullscreen
              ? Colors.black
              : const Color(0x1F465B92), // rgba(70,91,146,.12)
          borderRadius: (fullscreen || widget.flat)
              ? BorderRadius.zero
              : BorderRadius.circular(AylaRadii.rCard),
          border: (fullscreen || widget.flat)
              ? null
              : Border.all(color: AylaColors.glassBorder),
        ),
        child: ClipRRect(
          borderRadius: (fullscreen || widget.flat)
              ? BorderRadius.zero
              : BorderRadius.circular(AylaRadii.rCard),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              // 视频（`.live-player-video`：width/height 100% + object-fit contain + #000 底）；
              // 全屏期间 inline 不再挂视频。
              //
              // ⚠️ 不要在 `videoView` 外面**裸**套 `FittedBox`（2026-10-01 直播黑屏根因）：
              // web 的 `object-fit: contain` 挂在 `<video>` 元素**自身**
              // （app.css:3528–3533），元素铺满 100%×100%、由元素内部做 letterbox。
              // media_kit 的 `Video` widget 即 `<video>` 等价物，其自带 `fit`（默认
              // BoxFit.contain）就是 object-fit。裸包 FittedBox 会把无界约束传给 media_kit
              // 内部的 `Stack(fit: expand)`，展开出 Infinity 尺寸 → 缩放矩阵算出 NaN →
              // Flutter 每帧报 `TransformLayer is constructed with an invalid matrix.`
              // 且该层不绘制 ⇒ 黑屏（实测：mpv 侧解码/纹理均正常，rect 已到 1920×1080，
              // 唯独此层报错刷屏）。
              //
              // ✅ 移动端必须补的那一步（2026-11-01「不要拉伸屏幕」）由
              // [AylaVideoContain] 承担：它先算出**有界等比盒**再交给平台视图
              // （`Texture` 是 RenderProxyBox、无 `fit` 能力，不补就按容器拉伸）。
              // 判据是注入的 [widget.videoAspectRatio]：null（media_kit 不报 / 未初始化）
              // ⇒ 原样直传，既不收盒也不会踩上面那条无界约束的坑。
              // ⚠️ **同一时刻只允许挂一处**（对齐 web 的「video 元素原子迁移」语义）。
              //
              // web 的 video 元素由 liveSessionRuntime **唯一持有**，挂在 fixed 暂存容器里
              // 跟随播放器容器位移（LivePlayer.tsx:183–219 的 video.style.display 切换），
              // 页面/全屏里都**没有**第二个 video 元素。Flutter 侧的平台视图（VideoPlayer
              // 的 Texture / media_kit 的 Video）不做跨树迁移，只能「这边卸、那边挂」。
              //
              // 判据因此是 **fullscreen == _fullscreen**：
              // · inline 调用（形参 false）+ 未全屏（_fullscreen == false）⇒ 挂 ✅
              // · inline 调用（形参 false）+ 全屏中（_fullscreen == true）⇒ **不挂**（关键：
              //   旧写法 !fullscreen 恒真，导致 inline 侧在全屏期间仍持有同一个 controller，
              //   与 overlay 里的那份重复 attach ⇒ 手机端点全屏后画面黑掉/卡住）；
              // · 全屏宿主（形参 true）+ 全屏中 ⇒ 挂 ✅。
              // ignore: avoid_print
              if (_showVideo && fullscreen == _fullscreen)
                ColoredBox(
                  color: Colors.black,
                  // **恒收盒**：比例缺失时用 [kAylaLiveVideoAspectRatio] 兜底（锁死），
                  // 所以任何平台、任何时刻都不会出现「铺满父约束 = 拉伸」那条分支。
                  // `AylaVideoContain` 用 LayoutBuilder 给**有界**尺寸，不传导无界约束，
                  // 对 media_kit 同样安全（见该文件头）。
                  child: AylaVideoContain(
                    aspectRatio:
                        widget.videoAspectRatio ?? kAylaLiveVideoAspectRatio,
                    child: widget.videoView ??
                        const SizedBox(width: 160, height: 90),
                  ),
                ),
              // 调用方的叠加层（飘弹幕）
              if (widget.children != null) widget.children!,
              if (_showVideo) _controls(fullscreen: fullscreen),
              if (!_showVideo) _overlay(),
            ],
          ),
        ),
    );
  }

  /// `.live-player-controls`（opacity 0/1 + 隐藏时整层穿透）。
  Widget _controls({required bool fullscreen}) {
    return IgnorePointer(
      ignoring: !_controlsVisible,
      child: AnimatedOpacity(
        opacity: _controlsVisible ? 1 : 0,
        duration: AylaDurations.fast, // transition: opacity var(--dur-fast)
        curve: AylaCurves.easeOut,
        child: Stack(
          children: <Widget>[
            Positioned(
              left: AylaSpacing.sp2,
              bottom: AylaSpacing.sp2,
              child: _btn(
                icon: aylaIconByName('iconRefresh')!,
                label: '跳到最新画面',
                onPressed: _handleRefresh,
                spinning: _spinning,
              ),
            ),
            Positioned(
              right: AylaSpacing.sp2,
              bottom: AylaSpacing.sp2,
              child: Row(
                spacing: AylaSpacing.sp2, // `.live-player-corner { gap: var(--sp-2) }`
                children: <Widget>[
                  // 「小窗」键：把直播变成**应用窗口之外**的悬浮小窗。
                  //
                  // 只在**桌面端**渲染（`onEnterMiniPlayer != null` 由页面按平台决定）：
                  // 用户原话「电脑需要点按钮使直播变为悬浮小窗，但手机退出直播间自动续
                  // 直播悬浮小窗」⇒ 移动端走 `detachView` 的自动续接，不渲染本键。
                  //
                  // 图标沿用库内已有的 `iconPip`（`app_icons_data.dart:243`）——
                  // web 端这一位就是画中画键（`LivePlayer.tsx` 的 IconPip），语义同源。
                  if (widget.onEnterMiniPlayer != null)
                    _btn(
                      icon: aylaIconByName('iconPip')!,
                      label: '小窗',
                      onPressed: widget.onEnterMiniPlayer!,
                    ),
                  _btn(
                    icon: aylaIconByName('iconFullscreen')!,
                    label: '全屏',
                    onPressed: _toggleFullscreen,
                  ),
                ],
              ),
            ),
            if (fullscreen && widget.onSendDanmaku != null)
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: AylaSpacing.sp2),
                  child: _FullscreenDanmakuInput(
                    key: ValueKey<String?>(widget.danmakuOwner),
                    onSend: widget.onSendDanmaku!,
                    serverError: widget.danmakuError,
                    onFocus: _clearHideTimer,
                    onBlur: _armHideTimer,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// `.live-player-btn`（32×32 玻璃圆钮 + 白图标）。
  Widget _btn({
    required AylaIconData icon,
    required String label,
    required VoidCallback onPressed,
    bool spinning = false,
  }) {
    return _PlayerButton(
      icon: icon,
      label: label,
      onPressed: onPressed,
      spinning: spinning,
    );
  }

  /// 占位层（tsx 331–363 的三态 + 播放失败）。
  Widget _overlay() {
    final AylaLiveSrsStatus? status = widget.srsStatus;
    if (status == null) {
      return _placeholder('正在查询直播状态…');
    }
    if (status == AylaLiveSrsStatus.degraded) {
      // `.live-player-degraded { color: var(--warning) }`
      return _placeholder('直播服务状态未知，请稍后再试', color: AylaColors.warning);
    }
    if (status == AylaLiveSrsStatus.idle) {
      final bool waiting = widget.optimisticStatus == AylaLiveStatus.live;
      return _placeholder(waiting ? '等待推流信号…' : '主播未开播');
    }
    // live + playerError
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: AylaSpacing.sp3, // gap: var(--sp-3)
        children: <Widget>[
          Text(
            '播放失败',
            style: AylaTextStyles.of(context).body.copyWith(
              color: AylaColors.destructive, // `.live-player-error`
            ),
          ),
          AylaGlassButton(
            label: '重试',
            variant: AylaGlassButtonVariant.glow, // `.btn.btn-glow`
            onPressed: widget.onRetry,
          ),
        ],
      ),
    );
  }

  Widget _placeholder(String text, {Color? color}) {
    return Center(
      child: Text(
        text,
        style: AylaTextStyles.of(context).body.copyWith(
          color: color ?? AylaColors.textSecondary,
        ),
      ),
    );
  }
}

/// `.live-player-btn`：32×32 圆钮（indigo 半透明底 + 白图标 + blur8 sat1.2）。
class _PlayerButton extends StatefulWidget {
  const _PlayerButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.spinning = false,
  });

  final AylaIconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool spinning;

  @override
  State<_PlayerButton> createState() => _PlayerButtonState();
}

class _PlayerButtonState extends State<_PlayerButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final Widget icon = AylaIcon(widget.icon, size: 16, color: Colors.white);
    return Semantics(
      button: true,
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Focus(
          onFocusChange: (bool has) => setState(() => _focused = has),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: _hovered
                    ? const Color(0x85465B92) // hover rgba(70,91,146,.52)
                    : const Color(0x52465B92), // rgba(70,91,146,.32)
                borderRadius: AylaRadii.pill,
                border: Border.all(
                  // `:focus-visible { outline: var(--focus-ring) }` = 2px glow-500；
                  // Flutter 侧按「边色换 glow」表达（32px 圆钮上加外环会顶破 8px 边距）
                  color: _focused
                      ? AylaColors.glow500
                      : const Color(0x47FFFFFF), // rgba(255,255,255,.28)
                  width: _focused ? 2 : 1,
                ),
              ),
              alignment: Alignment.center,
              child: widget.spinning
                  // `live-refresh-spin 0.6s`（reduced-motion → 不转，仅复位计时照跑）
                  ? TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0, end: 1),
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : kLivePlayerSpin,
                      curve: AylaCurves.easeOut,
                      builder:
                          (BuildContext context, double t, Widget? child) =>
                              Transform.rotate(
                                angle: t * 2 * 3.141592653589793,
                                child: child,
                              ),
                      child: icon,
                    )
                  : icon,
            ),
          ),
        ),
      ),
    );
  }
}

/// 全屏宿主：黑底铺满窗口（web `:fullscreen` 的等价），点空白/按 ESC 退出。
class _LivePlayerFullscreenHost extends StatelessWidget {
  const _LivePlayerFullscreenHost({required this.child, required this.onExit});

  final Widget child;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (DismissIntent intent) {
              onExit();
              return null;
            },
          ),
        },
        child: FocusScope(
          autofocus: true,
          // ⚠️ 兜底（桌面真·全屏必需）：窗口被 window_manager 改成全屏后，
          // 若此时窗口本身还没拿到前台焦点，FocusScope 的 autofocus 请求可能被拒 ⇒
          // 子树里没有任何可聚焦节点 ⇒ 按键事件停在 root scope，而 [Shortcuts]
          // 在这层（root 之下）收不到 ⇒ **ESC 退出失效、用户被锁在全屏里**。
          // 这里显式给一个 autofocus 的 Focus，保证全屏子树内始终有焦点归属。
          // 快捷键本身的映射仍是上面 Shortcuts + Actions（Escape → DismissIntent）。
          child: Focus(
            autofocus: true,
            child: ColoredBox(
              color: Colors.black,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  child,
                  // 退出键（右上，与悬浮控件同风格；全屏里也要能退出）
                  Positioned(
                    top: AylaSpacing.sp2,
                    right: AylaSpacing.sp2,
                    child: _PlayerButton(
                      icon: aylaIconByName('iconClose')!,
                      label: '退出全屏',
                      onPressed: onExit,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 全屏弹幕输入（tsx 74–139 + live.css 939–1005）。
class _FullscreenDanmakuInput extends StatefulWidget {
  const _FullscreenDanmakuInput({
    super.key,
    required this.onSend,
    this.serverError,
    this.onFocus,
    this.onBlur,
  });

  final Future<bool> Function(String content) onSend;
  final String? serverError;
  final VoidCallback? onFocus;
  final VoidCallback? onBlur;

  @override
  State<_FullscreenDanmakuInput> createState() =>
      _FullscreenDanmakuInputState();
}

class _FullscreenDanmakuInputState extends State<_FullscreenDanmakuInput> {
  final TextEditingController _draft = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _sending = false;
  String? _failed;
  int _revision = 0; // 提交期间用户改过草稿 ⇒ 成功后不清空（tsx 105–108）

  @override
  void dispose() {
    _draft.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String content = _draft.text.trim();
    if (content.isEmpty || _sending) return;
    final int submitted = _revision;
    setState(() {
      _sending = true;
      _failed = null;
    });
    try {
      final bool ok = await widget.onSend(content);
      if (!mounted) return;
      if (ok) {
        if (_revision == submitted) {
          _revision += 1;
          _draft.clear();
        }
        _focus.requestFocus();
      } else {
        setState(() => _failed = '发送失败，请重试');
      }
    } on Object {
      if (mounted) setState(() => _failed = '发送失败，请重试');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return ConstrainedBox(
      // `width: min(320px, calc(100% - 120px))` + `min-height: 50px`
      constraints: const BoxConstraints(maxWidth: 320, minHeight: 50),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_failed != null || widget.serverError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AylaSpacing.sp2),
              child: DecoratedBox(
                // `.live-player-fs-error`：玻璃小片 + 12px 居中
                decoration: BoxDecoration(
                  color: AylaColors.glassBg,
                  borderRadius: BorderRadius.circular(AylaRadii.rSm),
                  border: Border.all(color: AylaColors.glassBorder),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Text(
                    widget.serverError ?? _failed!,
                    textAlign: TextAlign.center,
                    style: t.body.copyWith(fontSize: 12, height: 1.5),
                  ),
                ),
              ),
            ),
          Container(
            // `.live-player-fs-input`：玻璃外框持有背景，内 input 透明
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            decoration: BoxDecoration(
              color: AylaColors.glassBg,
              borderRadius: BorderRadius.circular(AylaRadii.rInput),
              border: Border.all(color: AylaColors.glassBorder),
            ),
            child: Row(
              spacing: AylaSpacing.sp2,
              children: <Widget>[
                Expanded(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 40),
                    child: TextField(
                      controller: _draft,
                      focusNode: _focus,
                      maxLength: 200,
                      onChanged: (_) => _revision += 1,
                      onSubmitted: (_) => unawaited(_submit()),
                      onTap: widget.onFocus,
                      onTapOutside: (_) => widget.onBlur?.call(),
                      style: t.body.copyWith(
                        fontSize: 14,
                        color: AylaColors.textPrimary,
                      ),
                      cursorColor: AylaColors.glow500,
                      decoration: InputDecoration(
                        isDense: true,
                        counterText: '',
                        border: InputBorder.none,
                        hintText: '发条弹幕吧', // tsx 129
                        hintStyle: t.body.copyWith(color: AylaColors.slate500),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                ),
                AylaGlassButton(
                  // `.live-player-fs-send`：40×40 · `.btn-primary`
                  label: '',
                  icon: AylaIcon(
                    aylaIconByName('iconSend')!,
                    size: 16,
                    color: AylaColors.surface,
                  ),
                  variant: AylaGlassButtonVariant.primary,
                  minWidth: 40,
                  minHeight: 40,
                  padding: EdgeInsets.zero,
                  semanticLabel: '发送弹幕', // tsx 134
                  onPressed: _sending || _draft.text.trim().isEmpty
                      ? null
                      : () => unawaited(_submit()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ======================= 预览样张 =======================

/// 播放器三态 + 悬浮控件 + 全屏样张（可交互：悬停/点击显示控件、3s 自动隐藏、刷新旋转、全屏）。
Widget aylaLivePlayerSamples() {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      _Stage(
        viewport: const Size(640, 360),
        label:
            '播放器 · live（`.live-player` 16:9 / rgba(70,91,146,.12) / radius 16 / 1px 亮边）· 可交互：**悬停或点击**显示悬浮键（左下刷新 / 右下全屏），显示后 **3s 无操作自动隐藏**；点刷新看 0.6s 旋转',
        child: _PlayerDemo(
          srsStatus: AylaLiveSrsStatus.live,
          video: true,
        ),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(640, 640),
        label:
            '四态占位 · 正在查询（`srsStatus == null`）/ degraded（`--warning`）/ idle（`主播未开播`）/ idle+乐观已开播（`等待推流信号…`）· 播放失败 = `播放失败`（destructive）+ `.btn-glow`「重试」',
        child: const _PlayerStatesDemo(),
      ),
    ],
  );
}

class _PlayerDemo extends StatelessWidget {
  const _PlayerDemo({required this.srsStatus, this.video = false});

  final AylaLiveSrsStatus? srsStatus;
  final bool video;

  @override
  Widget build(BuildContext context) {
    return AylaLivePlayer(
      srsStatus: srsStatus,
      optimisticStatus: AylaLiveStatus.live,
      videoView: video ? const _FakeVideo() : null,
      onRefresh: () {},
      onRetry: () {},
      onSendDanmaku: (String content) async => true,
    );
  }
}

/// 样张用的假画面（真实视频由页面的 `HlsPlaybackController.videoView` 注入）。
class _FakeVideo extends StatelessWidget {
  const _FakeVideo();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF2A3550),
      child: Center(
        child: Text(
          'HLS videoView（页面注入）',
          style: AylaTextStyles.of(context).body.copyWith(
            color: Colors.white70,
          ),
        ),
      ),
    );
  }
}

class _PlayerStatesDemo extends StatelessWidget {
  const _PlayerStatesDemo();

  @override
  Widget build(BuildContext context) {
    Widget cell(Widget child) => Expanded(child: AspectRatio(aspectRatio: 16 / 9, child: child));
    return Column(
      mainAxisSize: MainAxisSize.min,
      spacing: AylaSpacing.sp2,
      children: <Widget>[
        Row(
          spacing: AylaSpacing.sp2,
          children: <Widget>[
            cell(const AylaLivePlayer()),
            cell(
              const AylaLivePlayer(srsStatus: AylaLiveSrsStatus.degraded),
            ),
          ],
        ),
        Row(
          spacing: AylaSpacing.sp2,
          children: <Widget>[
            cell(const AylaLivePlayer(srsStatus: AylaLiveSrsStatus.idle)),
            cell(
              const AylaLivePlayer(
                srsStatus: AylaLiveSrsStatus.idle,
                optimisticStatus: AylaLiveStatus.live,
              ),
            ),
          ],
        ),
        Row(
          spacing: AylaSpacing.sp2,
          children: <Widget>[
            cell(
              const AylaLivePlayer(
                srsStatus: AylaLiveSrsStatus.live,
                playerError: '播放失败',
              ),
            ),
            const Spacer(),
          ],
        ),
      ],
    );
  }
}

/// 固定视口的样张舞台。
class _Stage extends StatelessWidget {
  const _Stage({
    required this.viewport,
    required this.label,
    required this.child,
  });

  final Size viewport;
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          width: viewport.width,
          height: viewport.height,
          child: Builder(
            builder: (BuildContext inner) => MediaQuery(
              data: MediaQuery.of(inner).copyWith(size: viewport),
              child: child,
            ),
          ),
        ),
        const SizedBox(height: AylaSpacing.sp1),
        SizedBox(
          width: viewport.width,
          child: Text(label, style: const TextStyle(fontSize: 11)),
        ),
      ],
    );
  }
}
