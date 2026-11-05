/// Ayla 专属 Windows 标题栏（自绘），替换系统原生顶部标题栏。
///
/// ## 需求（用户原话）
/// 「把 windows 窗口原生顶部标题栏去掉，改成 Ayla 专属的美观的融入的标题栏。
///   Ayla 启动默认最大化，标题栏要有最小化、窗口化、关闭」
///
/// ## 为什么必须自绘（原生侧配套，不能分开改）
/// 原生 caption 已由 runner 去掉（`windows/runner/win32_window.*` 的 WM_NCCALCSIZE +
/// WM_NCHITTEST，设计说明见 `win32_window.h` 文件头），于是窗口客户区 = 整个窗口：
/// - **没有系统 caption** ⇒ 标题条只能由 Flutter 画（本文件）；
/// - **没有非客户区** ⇒ 边缘拖拽缩放由原生 WM_NCHITTEST 手工应答；
/// - **拖拽窗口**由本文件驱动（`windowManager.startDragging()` → `SC_MOVE`），
///   **双击标题条 = 最大化/还原**（与系统 caption 行为一致）。
/// ⇒ 标题条几何（高度 / 键尺寸 / 命中区）**只有本文件一处 owner**，原生不猜这些数字。
///
/// ## 视觉：为什么是「透明条」而不是第二块玻璃
/// 应用顶部已经有 `.top-nav` 浮动玻璃卡（`shell.css:162–178` + `auroraqua.css:262–270`：
/// 高 64、外边距 12、圆角 16、模糊 18）。在它上面再加**一条通栏玻璃**会变成两根
/// 并列的横条 —— 那正是用户要否掉的「系统标题栏感」。
/// 因此本条的材质选择是**不画底**：透明条压在 `AylaAuroraBackground` 的极光底上，
/// 只有左侧品牌字与右侧三键是可见的（等价 Windows 11 / Discord 的 「extend content
/// into title bar」做法：chrome 融进内容，而不是另起一块板）。
/// 附带收益：**零 `BackdropFilter`**（不占 `test/perf_audit_test.dart` 的玻璃预算）。
///
/// 各元素的推导（全部来自 design.md / 现有样式，无自创数值）：
/// - **品牌**：渐变字 `linear-gradient(120deg, --indigo-700, --grape-700)`
///   （`shell.css:239–260` 的 `.top-nav-logo`）+ Fredoka（`--font-display`）。
///   字号 13 = 九级排版阶梯里 display 一族的**最小档**（在 microTag 11 之上、
///   body 15 之下，见 `AylaTextStyles`）；本条是 chrome，必须比它下面的一级导航
///   （模块项 15/700、logo 22）更轻。
/// - **品牌圆点**：`--pink-500` 实心 4×4（`AylaSpacing.sp1`）—— 不做辉光
///   （`--glow-shadow` 全屏 ≤3 处，本条不占额度，也就不产生离屏层）。
/// - **窗口键**：命中 **40×40**（design.md §10「≥40px 触达目标」），悬停底为
///   32×32 **胶囊**（`--radius-pill`，与 `.top-nav-icon-btn` 同为 pill 族），色值
///   `--ice-500` + `.18`（`shell.css:207–210` 的模块项 hover 底 —— 全站唯一 hover 底色）。
///   关闭键悬停底 `--destructive`（`#D64D6E`）+ 白图标：**只有它**用危险色。
///   图标 14px：比顶栏图标（20）/ 模块图标（16）再小一档，因为窗口键是低频附属控件。
/// - **条高 32**：`AylaTitleBarMetrics.height`。取 32 而不是 40 —— 40 是命中目标的下限，
///   而键本身自带 40×40 命中区（可以溢出条高），条高只需容纳 14px 图标 + 呼吸；
///   Windows 11 自家标题栏也是 32。
///
/// ## 窗口状态从哪来（不能只信自己的 setState）
/// 最大化 / 还原可能由系统发起（双击、Win+↑、贴边吸附、任务栏右键菜单），所以状态
/// **以 window_manager 的 [WindowListener] 事件为准**：三个键只「请求动作」，不「记账」。
///
/// ## 公开面
/// `AylaTitleBar` · `AylaWindowChromeController` · `AylaWindowEvents`
/// · `AylaTitleBarMetrics` · `aylaUsesCustomTitleBar` · `aylaSetupCustomTitleBar`
library;

import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform, kIsWeb;
// 裸指针拖拽区要判「哪个键按下」（右键不进拖拽）。
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../theme/app_theme.dart';
// 组件画布样张用（样张与件同文件是本仓惯例，见 `widgets/shell/top_nav.dart`
// 的 `aylaTopNavSamples()`）：`AylaAuroraBackground` 提供真实极光底、
// `AylaGlassCard` 模拟紧贴在下面的顶栏玻璃卡。
import '../../theme/aurora_background.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';

/// 窗口动作的可注入面。
///
/// 为什么抽接口（与 `widgets/live/live_player.dart` 的 `AylaDesktopWindowController`
/// 同一理由）：组件测试跑在 Windows 本机，`defaultTargetPlatform` 天然是 windows ⇒
/// 直接调真实通道会让每个用例都打进 `window_manager` 的 MethodChannel
/// （flutter_test 下无 handler ⇒ `MissingPluginException` 噪声 + 行为不可断言）。
abstract class AylaWindowChromeController {
  const AylaWindowChromeController();

  /// 最小化。
  Future<void> minimize();

  /// 最大化。
  Future<void> maximize();

  /// 还原（取消最大化）。
  Future<void> unmaximize();

  /// 关闭窗口。
  Future<void> close();

  /// 开始系统拖动（`WM_SYSCOMMAND / SC_MOVE`）。
  Future<void> startDragging();

  /// 当前是否最大化（首帧同步用；之后以事件为准）。
  Future<bool> isMaximized();
}

/// 窗口事件源（可注入）。
///
/// 生产 = `windowManager`（`addListener` 只是往插件内的观察者列表里加，不碰通道）；
/// 测试注入替身即可**直接派发**事件，不必去驱动 MethodChannel。
abstract class AylaWindowEvents {
  const AylaWindowEvents();

  /// 订阅窗口事件。
  void addListener(WindowListener listener);

  /// 取消订阅（必须成对，否则卸载后仍被回调）。
  void removeListener(WindowListener listener);
}

/// 生产实现：`window_manager` 的单例。
class AylaWindowManagerEvents extends AylaWindowEvents {
  const AylaWindowManagerEvents();

  @override
  void addListener(WindowListener listener) =>
      windowManager.addListener(listener);

  @override
  void removeListener(WindowListener listener) =>
      windowManager.removeListener(listener);
}

/// 生产实现：`window_manager`。
class _AylaWindowManagerChrome extends AylaWindowChromeController {
  const _AylaWindowManagerChrome();

  @override
  Future<void> minimize() => windowManager.minimize();

  @override
  Future<void> maximize() => windowManager.maximize();

  @override
  Future<void> unmaximize() => windowManager.unmaximize();

  @override
  Future<void> close() => windowManager.close();

  @override
  Future<void> startDragging() => windowManager.startDragging();

  @override
  Future<bool> isMaximized() => windowManager.isMaximized();
}

/// 窗口键种类（视觉顺序：最小化 / 窗口化 / 关闭）。
enum AylaWindowButtonKind { minimize, restore, close }

/// 标题条度量 —— **唯一事实源**：原生侧不重复这些数字（见库文档）。
abstract final class AylaTitleBarMetrics {
  /// 条高 —— **整条都是可拖拽区**，且条内不留任何空白带。
  ///
  /// 演变（每一步都是用户实报驱动的）：
  /// 1. 最初 32：条下面还有 `.top-nav` 的 `margin-top: 12px`（`auroraqua.css:263`），
  ///    那 12px 属于内容区 ⇒ 点在那里拖不动窗口（「有时点得到有时点不到」）；
  /// 2. 于是加到 44 并把顶栏外边距清零（那 12px 归标题条）—— 拖动范围对了，
  ///    但**品牌行贴在条顶**、条底替下 12px 成了纯空白带 ⇒ 用户截图圈红要求删掉；
  /// 3. 现在：条高 = 品牌行高 = **32**，顶栏外边距仍为 0（`wideMarginUnderTitleBar`）。
  ///    于是「窗口顶边缘 → 顶栏玻璃卡」之间没有多余留白，标题栏上下对称协调，
  ///    可拖拽区仍然严丝合缝等于那片可见空间（不会出现「看得到却拖不动」）。
  static const double height = 32;

  /// 品牌行自身的高度（= 条高；窗口键按它居中）。
  static const double brandRowHeight = 32;

  /// 窗口键命中边长（design.md §10 最小触达目标 40）。
  static const double hitSize = 40;

  /// 窗口键悬停胶囊边长（`.top-nav-icon-btn` 的 40 − 4×2 呼吸）。
  static const double chipSize = 32;

  /// 窗口键图标边长。
  ///
  /// 取 **16** = 一级导航模块图标同值（`shell.css:214–219` 的 `.top-nav-module-icon`）。
  /// 此前用 14：在 24 viewBox 上等比缩放后描边只有约 1px，非整像素落点被抗锯齿抹淡，
  /// 用户实报「窗口化图标甚至缺线」。16 让 2px 描边渲染成约 1.33px，与全站图标同厚度。
  static const double glyphSize = 16;

  /// 品牌圆点直径（`AylaSpacing.sp1` = 4）。
  static const double brandDot = AylaSpacing.sp1;

  /// 品牌圆点与字之间（`AylaSpacing.sp2`）。
  static const double brandGap = AylaSpacing.sp2;

  /// 品牌字左边距 = 宽屏顶栏卡的 `margin-left`（`.top-nav` 的 12），
  /// 让标题字的左沿与下面玻璃卡的左沿**同一条竖线**。
  static const double brandInset = AylaSpacing.sp3;

  /// 条自身的内高（不含溢出命中区）。
  static const double stripHeight = height;
}

/// Ayla 自绘标题栏（桌面）。
///
/// 非桌面平台**不要挂**：那些平台没有可去掉的系统标题栏（且已有窄屏 / 宽屏顶栏）。
class AylaTitleBar extends StatefulWidget {
  const AylaTitleBar({
    super.key,
    this.title = 'Ayla',
    this.controller = const _AylaWindowManagerChrome(),
    this.events = const AylaWindowManagerEvents(),
    this.fullscreenActive = false,
    this.windowKeysLocked = false,
  });

  /// 品牌文案（默认品牌名）。
  final String title;

  /// 窗口动作实现。
  final AylaWindowChromeController controller;

  /// 窗口状态事件源（生产 = `windowManager`；测试注入替身以直接派发事件）。
  final AylaWindowEvents events;

  /// 窗口是否处在**直播窗口级全屏**（铺满整块显示器）。
  ///
  /// true ⇒ 整条标题栏让位（高度归零），把屏幕让给视频画面。
  ///
  /// ⚠️ 由调用方（`main.dart` 的 `_AppRootState`）用播放器广播的
  /// `aylaLiveWindowFullscreen` 驱动，**不能**靠 [events] 的进/退全屏事件：
  /// window_manager 只在 `wParam == SIZE_MAXIMIZED` 时才发那两个事件，
  /// 而本 app 进全屏走 `SetWindowPos` 铺满显示器 ⇒ 事件永不发出。
  /// （回归锁：`test/title_bar_test.dart` 的「全屏信号契约」一例。）
  final bool fullscreenActive;

  /// 是否禁用三个窗口键（最小化 / 最大化 / 关闭）。
  ///
  /// ## 为什么需要（2026-11-05）
  /// 标题栏在 `main.dart` 里是 `Column[标题栏, Expanded(Stack[Navigator])]` 的**第一个**
  /// 子级，而所有根 Overlay（含强制更新弹窗）都在 Navigator 里 ⇒ **任何弹窗都盖不住
  /// 这 32px**。强制更新期间若窗口键仍可点，用户点 X 就能关掉 App，等于绕过更新。
  ///
  /// 拖拽与边缘缩放**不**受此限制（它们不构成逃逸）。
  ///
  /// 生产由 `main.dart` 传 `aylaUpdateBlocksWindowChrome`（模块级标志，更新宿主维护）。
  final bool windowKeysLocked;

  @override
  State<AylaTitleBar> createState() => _AylaTitleBarState();
}

class _AylaTitleBarState extends State<AylaTitleBar> {
  /// 当前是否最大化（以窗口事件为准）。
  bool _maximized = false;

  /// 是否正在等一次窗口动作返回（防连点：`SC_MOVE` 是系统级模态）。
  bool _busy = false;

  /// 事件适配器（`WindowListener` 是观察者列表，需成对移除）。
  WindowListener? _listener;

  @override
  void initState() {
    super.initState();
    _bindListener();
    unawaited(_syncMaximized());
  }

  @override
  void didUpdateWidget(covariant AylaTitleBar old) {
    super.didUpdateWidget(old);
    if (!identical(old.events, widget.events)) {
      _unbindListener();
      _bindListener();
    }
  }

  @override
  void dispose() {
    _unbindListener();
    super.dispose();
  }

  void _bindListener() {
    final _ChromeListener listener = _ChromeListener(this);
    _listener = listener;
    widget.events.addListener(listener);
  }

  void _unbindListener() {
    final WindowListener? listener = _listener;
    _listener = null;
    if (listener == null) return;
    widget.events.removeListener(listener);
  }

  /// 首帧同步真实状态（事件只覆盖「变化」，不覆盖「启动时就已经最大化」）。
  Future<void> _syncMaximized() async {
    try {
      final bool maximized = await widget.controller.isMaximized();
      if (!mounted || maximized == _maximized) return;
      setState(() => _maximized = maximized);
    } on Object catch (error) {
      // 窗口查询失败不能影响 UI：保持当前值（默认 false）即可。
      debugPrint('[AYLA-TITLEBAR] isMaximized 失败：$error');
    }
  }

  void _onWindowMaximized(bool maximized) {
    if (!mounted || maximized == _maximized) return;
    setState(() => _maximized = maximized);
  }


  /// 执行一次窗口动作（独立 try/catch：任何失败都必须复位 [_busy]）。
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    _busy = true;
    try {
      await action();
    } on Object catch (error) {
      debugPrint('[AYLA-TITLEBAR] 窗口动作失败：$error');
    } finally {
      _busy = false;
    }
  }

  /// 双击标题条 = 最大化 / 还原（与系统 caption 行为一致）。
  Future<void> _toggleMaximize() => _run(
        () => _maximized
            ? widget.controller.unmaximize()
            : widget.controller.maximize(),
      );

  @override
  Widget build(BuildContext context) {
    // 窗口级全屏（直播）时让位：高度归零，页面吃满整屏。
    if (widget.fullscreenActive) return const SizedBox(width: double.infinity);
    final AylaTextStyles t = AylaTextStyles.of(context);
    // ⚠️ 本条**不铺任何底色/模糊**（理由见库文档「视觉」节）：
    // 它直接坐在 AylaAuroraBackground 的极光上，只有品牌字与三键可见。
    //
    // 命中区层级（Stack 后者在上，先拿指针）——这个顺序就是优先级，别调换：
    //   ① 整条拖拽区（含条下方那 12px）；
    //   ② 上边 4px 缩放带；③ 左上/右上角 12×12 缩放角；
    //   ④ 三个窗口键（**最上**：压在缩放带之上，右上角的关闭键永远点得到）。
    return SizedBox(
      height: AylaTitleBarMetrics.stripHeight,
      child: Stack(
        children: <Widget>[
          // ---- ① 整条可拖拽 + 双击最大化 ----
          Positioned.fill(child: _dragArea(t)),
          // ---- ② 上边缘缩放（窗口化时才存在）----
          if (resizable)
            Positioned(
              left: AylaResizeEdges.cornerSize,
              right: AylaResizeEdges.cornerSize,
              top: 0,
              height: AylaResizeEdges.grabBand,
              child: _resizeBand(
                cursor: SystemMouseCursors.resizeUpDown,
                edge: ResizeEdge.top,
              ),
            ),
          // ---- ③ 两个上角 ----
          if (resizable)
            Positioned(
              left: 0,
              top: 0,
              width: AylaResizeEdges.cornerSize,
              height: AylaResizeEdges.cornerSize,
              child: _resizeBand(
                cursor: SystemMouseCursors.resizeUpLeftDownRight,
                edge: ResizeEdge.topLeft,
              ),
            ),
          if (resizable)
            Positioned(
              right: 0,
              top: 0,
              width: AylaResizeEdges.cornerSize,
              height: AylaResizeEdges.cornerSize,
              child: _resizeBand(
                cursor: SystemMouseCursors.resizeUpRightDownLeft,
                edge: ResizeEdge.topRight,
              ),
            ),
          // ---- ④ 三个窗口键（最上层）----
          Positioned(
            right: 0,
            top: 0,
            height: AylaTitleBarMetrics.brandRowHeight,
            child: Row(
              children: <Widget>[
                // ⚠️ 强制更新期间（`windowKeysLocked`）三键全部置灰：
                // 弹窗盖不住标题栏（见 [AylaTitleBar.windowKeysLocked] 的推导），
                // 放行「关闭」= 用户可绕过强制更新。
                _WindowButton(
                  kind: AylaWindowButtonKind.minimize,
                  label: '最小化',
                  onPressed: widget.windowKeysLocked
                      ? null
                      : () => _run(widget.controller.minimize),
                ),
                _WindowButton(
                  kind: AylaWindowButtonKind.restore,
                  label: _maximized ? '还原' : '最大化',
                  maximized: _maximized,
                  onPressed: widget.windowKeysLocked ? null : _toggleMaximize,
                ),
                _WindowButton(
                  kind: AylaWindowButtonKind.close,
                  label: '关闭',
                  onPressed: widget.windowKeysLocked
                      ? null
                      : () => _run(widget.controller.close),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
  /// 是否可缩放：最大化时窗口已铺满工作区，没有可拖的边。
  bool get resizable => !_maximized && !widget.fullscreenActive;


  /// 起一次原生缩放（`WM_SYSCOMMAND / SC_SIZE`，与系统边框同源）。
  Future<void> _resize(ResizeEdge edge) async {
    try {
      await windowManager.startResizing(edge);
    } on Object catch (error) {
      debugPrint('[AYLA-TITLEBAR] startResizing($edge) 失败：$error');
    }
  }

  /// 一条透明缩放带（只换光标 + 起原生缩放，不画东西）。
  Widget _resizeBand({required MouseCursor cursor, required ResizeEdge edge}) {
    return MouseRegion(
      cursor: cursor,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => unawaited(_resize(edge)),
        child: const SizedBox.expand(),
      ),
    );
  }

  /// 拖拽区：整条（`Positioned.fill`），品牌字只是它内部居中的内容。
  ///
  /// 用 [AylaCaptionDragArea]（裸指针）而不是 `GestureDetector.onPanStart`：
  /// 后者有 18px slop，在 32px 高的条里等不到，还会被双击识别器抢手势竞技场 ——
  /// 这正是「有时点得到有时点不到」的根因（详见该类文档）。
  Widget _dragArea(AylaTextStyles t) {
    return AylaCaptionDragArea(
      controller: widget.controller,
      onDoubleTap: () => unawaited(_toggleMaximize()),
      // 条高 == 品牌行高 ⇒ 内容直接铺满整条（不需要再套 Align/SizedBox，
      // 那两层在 44 时代用来把品牌行压在上半部，现在反而会让命中区与视觉脱节）。
      child: Center(
          child: Padding(
            padding: const EdgeInsets.only(
              left: AylaTitleBarMetrics.brandInset,
              right: _windowButtonsInset,
            ),
            child: Row(
              children: <Widget>[
                const _BrandDot(),
                const SizedBox(width: AylaTitleBarMetrics.brandGap),
                Flexible(
                  child: ShaderMask(
                    shaderCallback: (Rect bounds) => const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: AylaGradients.brand,
                    ).createShader(bounds),
                    blendMode: BlendMode.srcIn,
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.microTag.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ),
    );
  }

  /// 品牌行右侧给三个窗口键留出的宽度（键是 40×40 命中区）。
  static const double _windowButtonsInset = AylaTitleBarMetrics.hitSize * 3;
}

/// `window_manager` 事件 → 本件状态（最小适配器，只消费两个状态 + 全屏）。
class _ChromeListener with WindowListener {
  const _ChromeListener(this._state);

  final _AylaTitleBarState _state;

  @override
  void onWindowMaximize() => _state._onWindowMaximized(true);

  @override
  void onWindowUnmaximize() => _state._onWindowMaximized(false);


}

/// 品牌圆点（`--pink-500` 实心点；不带辉光阴影 ⇒ 不产生离屏层）。
class _BrandDot extends StatelessWidget {
  const _BrandDot();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: AylaTitleBarMetrics.brandDot,
      height: AylaTitleBarMetrics.brandDot,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AylaColors.pink500,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// 单个窗口键：40×40 命中区 + 32×32 悬停胶囊 + 14px 图标。
class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.kind,
    required this.label,
    required this.onPressed,
    this.maximized = false,
  });

  final AylaWindowButtonKind kind;
  final String label;

  /// null = 禁用（强制更新期间锁窗口键，见 [AylaTitleBar.windowKeysLocked]）。
  final VoidCallback? onPressed;

  /// 仅窗口化键使用：最大化时画「还原」双框，否则画单框。
  final bool maximized;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hovered = false;

  bool get _danger => widget.kind == AylaWindowButtonKind.close;

  /// 禁用态（`base.css:343 button:disabled { cursor: not-allowed; opacity: 0.55 }`）。
  bool get _enabled => widget.onPressed != null;

  @override
  Widget build(BuildContext context) {
    // 关闭键悬停：危险底 + 白图标（白 = `--surface`，对 #D64D6E 对比度足够）；
    // 其余两键悬停：全站唯一 hover 底 `--ice-500` `.18`。
    final bool hovered = _enabled && _hovered;
    final Color iconColor = _danger && hovered
        ? AylaColors.surface
        : AylaColors.textSecondary;
    final Color? background = hovered
        ? (_danger
            ? AylaColors.destructive
            : AylaColors.ice500.withValues(alpha: 0.18))
        : null;

    return MouseRegion(
      // 禁用时与全站 `button:disabled` 同口径：不可点的控件不给手型/默认箭头差异，
      // 用 `forbidden` 明确表达「现在不能关」。
      cursor: _enabled
          ? SystemMouseCursors.basic
          : SystemMouseCursors.forbidden,
      onEnter: _enabled ? (_) => setState(() => _hovered = true) : null,
      onExit: _enabled ? (_) => setState(() => _hovered = false) : null,
      child: Semantics(
        button: true,
        enabled: _enabled,
        label: widget.label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: SizedBox(
            width: AylaTitleBarMetrics.hitSize,
            height: AylaTitleBarMetrics.hitSize,
            child: Center(
              child: AnimatedContainer(
                duration: AylaDurations.fast, // 180ms（shell.css 图标钮过渡档）
                curve: AylaCurves.easeOut,
                width: AylaTitleBarMetrics.chipSize,
                height: AylaTitleBarMetrics.chipSize,
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: AylaRadii.pill,
                ),
                child: Opacity(
                  // `base.css:343 button:disabled { opacity: 0.55 }`
                  opacity: _enabled ? 1 : 0.55,
                  child: _WindowGlyph(
                    kind: widget.kind,
                    maximized: widget.maximized,
                    size: AylaTitleBarMetrics.glyphSize,
                    color: iconColor,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 窗口键字形 —— 它们是 **OS chrome**，不属于 web `components/icons.tsx` 的业务
/// 图标集（`kAylaIcons` 由 icons.tsx 生成，禁止手加），故本件自带极简 painter。
/// 三个字形都按 Windows 系统窗口键的几何比例绘制（不是业务图标）。
class _WindowGlyph extends StatelessWidget {
  const _WindowGlyph({
    required this.kind,
    required this.size,
    required this.color,
    this.maximized = false,
  });

  final AylaWindowButtonKind kind;
  final double size;
  final Color color;
  final bool maximized;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _WindowGlyphPainter(
          kind: kind,
          color: color,
          maximized: maximized,
        ),
      ),
    );
  }
}

class _WindowGlyphPainter extends CustomPainter {
  const _WindowGlyphPainter({
    required this.kind,
    required this.color,
    required this.maximized,
  });

  final AylaWindowButtonKind kind;
  final Color color;
  final bool maximized;

  /// 绘制坐标系边长（与 `kAylaIcons` 一致 = 24）。
  ///
  /// ⚠️ 字体几何**必须**在 24 坐标系里写好再整体缩放：上一版直接在 14px 画布上按
  /// 比例乘系数（`w * 0.16` 之类），既看不出与图标库的关系，也在非整数倍缩放下把
  /// 1.3px 描边画得粗细不匀、端点发虚 —— 用户实报「窗口化图标缺线」就是描边落在
  /// 半像素上被抗锯齿抹掉的结果。现在与 [AylaIcon] / [AylaSvgGlyph] 走同一条
  /// 「24 viewBox + 等比缩放 + 固定描边宽」的路子。
  static const double viewBox = 24;

  @override
  void paint(Canvas canvas, Size size) {
    // 等比缩放：24 坐标系 → 实际边长。
    final double scale = size.width / viewBox;
    canvas.save();
    canvas.scale(scale);

    // 描边宽 = **2px / 24 viewBox**，与 `kAylaIcons` 全量图标同值（`icons.tsx` 的
    // `base()` = strokeWidth 2）。不要为了「看起来细」调小：16px 下 2 个单位 =
    // 1.33 设备像素，再小就只剩 ~1px 且被抗锯齿抹淡（上一版 1.3px 的实测后果就是
    // 用户看到的「缺线」）。
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    switch (kind) {
      case AylaWindowButtonKind.minimize:
        // Lucide `minus`：`M5 12h14` —— 与库内 [kAylaIcons] 的 `iconPlus` 同一几何
        // （plus 是 `M12 5v14M5 12h14`，即加减同源），所以最小化键看上去就是
        // 「把 plus 的竖线拿掉」，与库里其它图标浑然一体。
        canvas.drawLine(const Offset(5, 12), const Offset(19, 12), stroke);
      case AylaWindowButtonKind.restore:
        if (maximized) {
          // Lucide `copy` 的几何（`rect 8,8,14,14` + `M4 16c-1.1 0-2-.9-2-2V4...`），
          // 但按窗口 chrome 语义简化为两个错位方框：后框只画「上 + 左」，
          // 露出前框的右上角 —— 这正是系统「还原」键的画法，也保证两条线不重叠。
          const Rect front = Rect.fromLTWH(8.5, 8.5, 11, 11);
          canvas.drawRRect(
            RRect.fromRectAndRadius(front, const Radius.circular(1.2)),
            stroke,
          );
          final Path back = Path()
            ..moveTo(4.5, 15.5)
            ..lineTo(4.5, 4.5)
            ..lineTo(15.5, 4.5);
          canvas.drawPath(back, stroke);
        } else {
          // Lucide `square`：`rect 3,3,18,18` 收一档到 4.5–19.5，让四个窗口键的
          // 视觉重量与「−」「✕」一致（Lucide 的 square 铺满 24 会显得比另两个大）。
          const Rect frame = Rect.fromLTWH(4.5, 4.5, 15, 15);
          canvas.drawRRect(
            RRect.fromRectAndRadius(frame, const Radius.circular(1.6)),
            stroke,
          );
        }
      case AylaWindowButtonKind.close:
        // Lucide `x`：`M18 6 6 18M6 6l12 12` —— **逐字**照 `iconClose` 的 d 数据，
        // 这样关闭键与全站其它关闭入口是同一个字形。
        canvas.drawLine(const Offset(6, 6), const Offset(18, 18), stroke);
        canvas.drawLine(const Offset(18, 6), const Offset(6, 18), stroke);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WindowGlyphPainter old) =>
      old.kind != kind || old.color != color || old.maximized != maximized;
}



/// 标题条拖拽区 —— **裸指针实现**（不走 `GestureDetector` 的 pan 识别器）。
///
/// ## 为什么不能用 `onPanStart`（2026-11-04 用户实报「有时候点得到有时候点不到」）
/// 两个独立原因，都会让拖拽「时灵时不灵」：
///
/// 1. **`PanGestureRecognizer` 有 slop**：指针必须先移动 `kTouchSlop`(18) 逻辑像素才宣告
///    胜利。条高只有 32px ⇒ 用户按下去横向轻拖几下都在阈值内 ⇒ **窗口纹丝不动**，
///    看起来就是「点了没反应」；而一旦拖够 18px 窗口才突然弹出去，观感是「很粘」。
/// 2. **与 `onDoubleTap` 抢手势竞技场**：`DoubleTapGestureRecognizer` 会在按下的瞬间进场并
///    暂缓判决，pan 只能等它超时。于是「双击最大化」的等待窗口内拖拽被压住 ——
///    命中率取决于双击计时器与移动速度的赛跑，正是「有时行有时不行」的来源。
///
/// 裸 `Listener` 没有竞技场、没有 slop：自己用一个 3px 阈值就能在**第一次移动**时立刻
/// 起 `SC_MOVE`，双击也由自己按「时间 + 位移」判定，两条路径互不干扰。
///
/// ## 为什么不 `await`
/// `windowManager.startDragging()` 原生侧是 `SendMessage(WM_SYSCOMMAND, SC_MOVE)`，
/// 它**阻塞到用户松开鼠标**才返回。若 await 它，调用方那个「防连点」标志会被整段拖拽
/// 占住 ⇒ 拖完立刻双击无效。这里 fire-and-forget，失败只记日志。
class AylaCaptionDragArea extends StatefulWidget {
  const AylaCaptionDragArea({
    super.key,
    required this.child,
    required this.controller,
    this.onDoubleTap,
    this.cursor = SystemMouseCursors.basic,
  });

  /// 拖拽区内容（**不得**含可点击子件：本件会把指针整个吃掉）。
  final Widget child;

  /// 窗口动作实现。
  final AylaWindowChromeController controller;

  /// 双击回调（生产 = 最大化/还原）。
  final VoidCallback? onDoubleTap;

  /// 指针光标（系统 caption 是普通箭头）。
  final MouseCursor cursor;

  /// 起拖阈值（逻辑像素）。
  ///
  /// 3px：小到「一动手就动窗」，又大到能把「按下时的手抖」和小幅点击区分开。
  /// 系统 caption 自己的阈值同样是几个像素级（`SM_CXDRAG` 默认 4，但它走的是
  /// `SC_MOVE` 的模态循环内部判定，我们这里必须自己判）。
  static const double dragSlop = 3;

  /// 双击判定的最大间隔（与 Flutter `kDoubleTapTimeout` 同值 300ms）。
  static const Duration doubleTapTimeout = Duration(milliseconds: 300);

  /// 双击判定的最大位移（第二次按下不得离第一次太远）。
  static const double doubleTapSlop = 8;

  @override
  State<AylaCaptionDragArea> createState() => _AylaCaptionDragAreaState();
}

class _AylaCaptionDragAreaState extends State<AylaCaptionDragArea> {
  /// 本次按下起点（null = 没有按着）。
  Offset? _downAt;

  /// 本次按下是否已经转成拖拽。
  bool _dragging = false;

  /// 上一次「无位移点击」的时刻与位置（双击判定）。
  Duration? _lastTapAt;
  Offset? _lastTapPos;

  void _onDown(PointerDownEvent event) {
    _downAt = event.position;
    _dragging = false;
    // 右键不参与拖拽（系统 caption 右键是窗口菜单，我们不做）。
    if (event.buttons == kSecondaryMouseButton) return;
  }

  void _onMove(PointerMoveEvent event) {
    final Offset? from = _downAt;
    if (from == null || _dragging) return;
    if ((event.position - from).distance < AylaCaptionDragArea.dragSlop) return;
    _dragging = true;
    // fire-and-forget：原生 `SC_MOVE` 会阻塞到用户松手，绝不能 await（见类文档）。
    widget.controller.startDragging().catchError((Object error) {
      debugPrint('[AYLA-TITLEBAR] startDragging 失败：$error');
    });
  }

  void _onUp(PointerUpEvent event) {
    final bool moved = _dragging;
    _downAt = null;
    _dragging = false;
    // 拖过就不是点击：不参与双击判定。
    if (moved) {
      _lastTapAt = null;
      _lastTapPos = null;
      return;
    }
    final VoidCallback? onDoubleTap = widget.onDoubleTap;
    if (onDoubleTap == null) return;
    final Duration now = event.timeStamp;
    final Duration? lastAt = _lastTapAt;
    final Offset? lastPos = _lastTapPos;
    final bool isDouble = lastAt != null &&
        lastPos != null &&
        now - lastAt <= AylaCaptionDragArea.doubleTapTimeout &&
        (event.position - lastPos).distance <= AylaCaptionDragArea.doubleTapSlop;
    if (isDouble) {
      _lastTapAt = null;
      _lastTapPos = null;
      onDoubleTap();
      return;
    }
    _lastTapAt = now;
    _lastTapPos = event.position;
  }

  void _onCancel(PointerCancelEvent event) {
    _downAt = null;
    _dragging = false;
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.cursor,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onDown,
        onPointerMove: _onMove,
        onPointerUp: _onUp,
        onPointerCancel: _onCancel,
        child: widget.child,
      ),
    );
  }
}


/// 要挂哪几条缩放边（[AylaResizeEdges.edges]）。
///
/// 用位标志而不是 `Set<ResizeEdge>`：`edges` 是 const 构造参数，位组合能写成
/// 编译期常量（`const AylaResizeEdgeSet(...)`），Set 不能。
class AylaResizeEdgeSet {
  const AylaResizeEdgeSet({
    required this.top,
    required this.bottom,
    required this.left,
    required this.right,
  });

  final bool top;
  final bool bottom;
  final bool left;
  final bool right;

  /// 四条边全挂（整窗内容都在本组件里时用）。
  static const AylaResizeEdgeSet all = AylaResizeEdgeSet(
    top: true,
    bottom: true,
    left: true,
    right: true,
  );

  /// 不含上边：上边归 [AylaTitleBar]（窗口键必须优先于缩放带），
  /// 只给「标题条之下的页面区」用这一档。
  static const AylaResizeEdgeSet content = AylaResizeEdgeSet(
    top: false,
    bottom: true,
    left: true,
    right: true,
  );

  /// 什么都不挂。
  static const AylaResizeEdgeSet none = AylaResizeEdgeSet(
    top: false,
    bottom: false,
    left: false,
    right: false,
  );
}
/// 窗口边缘的**鼠标缩放带**（桌面；自绘边框下原生 WM_NCHITTEST 收不到）。
///
/// ## 为什么一定要在 Dart 做（实测引擎源码，不是猜）
/// Flutter 的视图是一个 `WS_CHILD` 子窗口，铺满客户区（`host_window.cc` 的
/// `SetChildContent` 用 `SetParent` 把它挂上顶层窗口）。Windows 命中测试先问子窗口，
/// 而子窗口过程对自身表面上的点一律返回 `HTCLIENT` —— `HTCLIENT` 会**终止**命中搜索，
/// 所以顶层窗口的 `WM_NCHITTEST` 对手持指针落点根本不会被调用。
/// runner 里那条原生边界（`win32_window.cpp` 的 `HitTestFrame`）仍然保留，覆盖
/// 「窗口未激活时按下」等系统确实发给顶层窗口的情形，但**不能**承担手持缩放。
/// ⇒ 缩放只在指针事件真正到达的这一层做：本组件叠在页面之上，用 4–8px 的透明带
/// 触发 `windowManager.startResizing`（原生 `WM_SYSCOMMAND / SC_SIZE`，与系统边框同源）。
///
/// ## 命中与可见性
/// - 带宽 `_grabBand`：**6 逻辑像素**（约等于 DPI 100% 时 Windows 的
///   `SM_CXSIZEFRAME + SM_CXPADDEDBORDER` = 4+4 → 视觉 6–8），窄到不遮挡内容、
///   宽到好抓；
/// - 四角用 12×12（角比边好抓是系统一贯做法，`ResizeEdge` 的四角枚举已覆盖）；
/// - 带是**透明**的（`Colors.transparent` + `MouseRegion` 换光标），不画任何描边 ——
///   自绘 chrome 不能出现「画出来的边框」；
/// - 最大化 / 窗口级全屏时**整组移除**（最大化窗口没有可拖的边，全屏由直播独占）。
///
/// ## 为什么不用插件自带的 `DragToResizeArea`
/// 它把 edge 画成**不透明色块**（`resizeEdgeColor`）并固定 8px 且四角另算，
/// 无法满足「透明 + 6px + 只在离开全屏时生效」；语义与 `startResizing` 完全相同，
/// 所以这里直接用同一个 API，只是自己掌握几何与显隐。
class AylaResizeEdges extends StatelessWidget {
  const AylaResizeEdges({
    super.key,
    required this.child,
    this.enabled = true,
    this.edges = AylaResizeEdgeSet.all,
    this.onResizeStart,
  });

  /// 被包裹的页面内容（本组件只叠一层透明命中带，不改变布局）。
  final Widget child;

  /// 是否启用（最大化 / 全屏时为 false —— 那时没有可拖的边）。
  final bool enabled;

  /// 要挂哪几条边。
  ///
  /// 内容区传 [AylaResizeEdgeSet.content]（不含上边）：上边属于标题条的拖拽区，
  /// 由 [AylaTitleBar] 自己那层负责 —— 这样窗口键永远压在缩放带之上，
  /// 关闭键不会因为落在右上角就被缩放带吃掉（原生 Windows 同样是按钮优先）。
  final AylaResizeEdgeSet edges;

  /// 缩放开始回调（可注入；默认走 `windowManager.startResizing`）。
  final Future<void> Function(ResizeEdge edge)? onResizeStart;

  /// 边缘带宽（逻辑像素）。
  static const double grabBand = 6;

  /// 四角命中边长（角比边好抓）。
  static const double cornerSize = 12;

  Future<void> _start(ResizeEdge edge) async {
    try {
      if (onResizeStart case final Future<void> Function(ResizeEdge) cb) {
        await cb(edge);
      } else {
        await windowManager.startResizing(edge);
      }
    } on Object catch (error) {
      debugPrint('[AYLA-TITLEBAR] startResizing($edge) 失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!enabled || edges == AylaResizeEdgeSet.none) return child;
    final double band = grabBand;
    final double corner = cornerSize;
    final AylaResizeEdgeSet e = edges;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        child,
        // ---- 四条边（端点让开四角）----
        if (e.top)
          Positioned(
            left: e.left ? corner : 0,
            right: e.right ? corner : 0,
            top: 0,
            height: band,
            child: _band(ResizeEdge.top, SystemMouseCursors.resizeUpDown),
          ),
        if (e.bottom)
          Positioned(
            left: e.left ? corner : 0,
            right: e.right ? corner : 0,
            bottom: 0,
            height: band,
            child: _band(ResizeEdge.bottom, SystemMouseCursors.resizeUpDown),
          ),
        if (e.left)
          Positioned(
            top: e.top ? corner : 0,
            bottom: e.bottom ? corner : 0,
            left: 0,
            width: band,
            child: _band(ResizeEdge.left, SystemMouseCursors.resizeLeftRight),
          ),
        if (e.right)
          Positioned(
            top: e.top ? corner : 0,
            bottom: e.bottom ? corner : 0,
            right: 0,
            width: band,
            child: _band(ResizeEdge.right, SystemMouseCursors.resizeLeftRight),
          ),
        // ---- 四角（覆盖两侧边的端点）----
        if (e.top && e.left)
          Positioned(
            left: 0,
            top: 0,
            width: corner,
            height: corner,
            child: _band(
              ResizeEdge.topLeft,
              SystemMouseCursors.resizeUpLeftDownRight,
            ),
          ),
        if (e.top && e.right)
          Positioned(
            right: 0,
            top: 0,
            width: corner,
            height: corner,
            child: _band(
              ResizeEdge.topRight,
              SystemMouseCursors.resizeUpRightDownLeft,
            ),
          ),
        if (e.bottom && e.left)
          Positioned(
            left: 0,
            bottom: 0,
            width: corner,
            height: corner,
            child: _band(
              ResizeEdge.bottomLeft,
              SystemMouseCursors.resizeUpRightDownLeft,
            ),
          ),
        if (e.bottom && e.right)
          Positioned(
            right: 0,
            bottom: 0,
            width: corner,
            height: corner,
            child: _band(
              ResizeEdge.bottomRight,
              SystemMouseCursors.resizeUpLeftDownRight,
            ),
          ),
      ],
    );
  }

  /// 一条透明命中带：只换光标 + 起缩放，不画任何东西。
  Widget _band(ResizeEdge edge, MouseCursor cursor) {
    return MouseRegion(
      cursor: cursor,
      // `opaque` 才能吃到指针：带内是透明的，没有子件可命中。
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => unawaited(_start(edge)),
        child: const SizedBox.expand(),
      ),
    );
  }
}


/// 窗口键的**悬停态静态样张**（只给组件画布用）。
///
/// 为什么需要它：悬停是 `MouseRegion.onEnter` 驱动的运行时状态，静态画面里无法通过
/// 传参触发；而「悬停胶囊长什么样」正是本次要用户肉眼验收的部分之一。
/// 因此把键内部的视觉抽成这个可直传 `hovered` 的展示件（生产路径仍走 [AylaTitleBar]
/// 里的 `_WindowButton`，两者共用同一个 painter 与同一套 token）。
class AylaTitleBarHoverPreview extends StatelessWidget {
  const AylaTitleBarHoverPreview({
    super.key,
    required this.kind,
    required this.hovered,
  });

  /// 键种类（决定字形与悬停色：只有 close 用危险色）。
  final AylaWindowButtonKind kind;

  /// 是否画成悬停态。
  final bool hovered;

  @override
  Widget build(BuildContext context) {
    final bool danger = kind == AylaWindowButtonKind.close;
    final Color iconColor = danger && hovered
        ? AylaColors.surface
        : AylaColors.textSecondary;
    final Color? background = hovered
        ? (danger
            ? AylaColors.destructive
            : AylaColors.ice500.withValues(alpha: 0.18))
        : null;
    return SizedBox(
      width: AylaTitleBarMetrics.hitSize,
      height: AylaTitleBarMetrics.hitSize,
      child: Center(
        child: AnimatedContainer(
          duration: AylaDurations.fast,
          curve: AylaCurves.easeOut,
          width: AylaTitleBarMetrics.chipSize,
          height: AylaTitleBarMetrics.chipSize,
          decoration: BoxDecoration(
            color: background,
            borderRadius: AylaRadii.pill,
          ),
          child: _WindowGlyph(
            kind: kind,
            maximized: kind == AylaWindowButtonKind.restore,
            size: AylaTitleBarMetrics.glyphSize,
            color: iconColor,
          ),
        ),
      ),
    );
  }
}

/// 当前平台是否应该挂自绘标题栏（桌面）。
///
/// Web 无窗口概念；Android / iOS 没有可去掉的系统标题栏（且已有窄屏 / 宽屏顶栏）；
/// macOS 侧尚未接原生去框（本需求只覆盖 Windows），保持系统标题栏。
bool aylaUsesCustomTitleBar({TargetPlatform? platform, bool isWeb = kIsWeb}) {
  if (isWeb) return false;
  switch (platform ?? defaultTargetPlatform) {
    case TargetPlatform.windows:
    case TargetPlatform.linux:
      return true;
    case TargetPlatform.macOS:
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return false;
  }
}

/// 桌面窗口会话：把「去原生标题栏」在启动期做一次（幂等）。
///
/// 原生侧 `Win32Window` 已经让客户区 = 整个窗口（WM_NCCALCSIZE 返回 0），本函数
/// **只需要**告诉 window_manager「标题栏风格 = 无」—— 它会复位内部
/// `is_frameless_` / `title_bar_style_` 并 `ForceRefresh`，这也是**退出直播全屏后**
/// 让窗口边框回到本设计状态的关键一步（`live_player.dart` 的 `restoreTitleBar`
/// 走同一个入口）。
///
/// ⚠️ 必须在首帧之前调用：否则第一帧会以「有 caption」的客户区尺寸布局，随后跳一次。
Future<void> aylaSetupCustomTitleBar() async {
  if (!aylaUsesCustomTitleBar()) return;
  try {
    await windowManager.ensureInitialized();
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    // 最小窗口尺寸：宽屏三列（服务器栏 + 频道栏 + 内容）不被挤坏的下限。
    // 取 960×600 逻辑像素（> 宽屏断点 768），保证内容区仍有可用宽度。
    await windowManager.setMinimumSize(const Size(960, 600));
  } on Object catch (error) {
    // 去标题栏是「外观增强」：失败只该退化成系统标题栏，不该拦住启动。
    debugPrint('[AYLA-TITLEBAR] 去原生标题栏失败（保持系统标题栏）：$error');
  }
}

// ---------------------------------------------------------------------------
// AylaTitleBar 样张（Windows 自绘标题栏）
// ---------------------------------------------------------------------------

/// 样张里三键的调用记录（画布是**可交互**的验收面，点一下要能看见发生了什么）。
final List<String> _aylaTitleBarCalls = <String>[];

/// `AylaTitleBar` 的分档样张。
///
/// ## 为什么这里画的是「带极光底的完整条」而不是孤立白底条
/// 本条**不铺任何底色**（设计取舍见 `widgets/shell/title_bar.dart` 的库文档）：
/// 放在白底上会看不出它到底融不融得进应用顶部。所以每一档都用
/// `AylaAuroraBackground` 做底、并把它紧贴在一条**模拟的顶栏玻璃卡**之上 ——
/// 那正是生产里的真实叠放顺序，验收时看到的对比关系才成立。
///
/// ## 四档（对应生产会遇到的四种窗口状态）
/// 1. **窗口化**：键图标为单框（最大化）；上/左/右缩放带存在（肉眼不可见，属正常）；
/// 2. **最大化**：键图标变双框（还原）+ 整组缩放带消失；
/// 3. **直播窗口级全屏**：整条让位（高度归零，只剩下面的页面）；
/// 4. **悬停态**：关闭键悬停（玫红底白叉）与窗口化键悬停（冰蓝胶囊）的对照 ——
///    这一档**不可交互**，用 `MouseRegion` 无法在静态画面里表达，故用两个
///    已置悬停的窗口键样张并排展示。
Widget aylaTitleBarSamples() {
  return StatefulBuilder(
    builder: (BuildContext context, StateSetter setLocal) {
      void rebake() => setLocal(() {});
      // 画布里的三键不碰真实窗口（那会真的把用户窗口关掉/最小化）：
      // 用记录回调的替身，点一下在下方「最近调用」里显示。
      final AylaWindowChromeController fake = _AylaGalleryChrome(reBake: rebake);
      final AylaWindowEvents noEvents = _AylaGalleryEvents();

      Widget framed({required Widget child, required String caption}) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              caption,
              style: AylaTextStyles.of(context).caption.copyWith(
                color: AylaColors.textSecondary,
              ),
            ),
            const SizedBox(height: AylaSpacing.sp2),
            ClipRRect(
              borderRadius: BorderRadius.circular(AylaRadii.rCard),
              child: SizedBox(
                height: 200,
                child: AylaAuroraBackground(
                  animate: false,
                  child: Column(
                    children: <Widget>[
                      child,
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(AylaSpacing.sp3),
                          child: AylaGlassCard(
                            padding: EdgeInsets.zero,
                            radius: AylaRadii.rCard,
                            blur: AylaGlass.blurNav,
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: AylaSpacing.sp6),
          ],
        );
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          framed(
            caption: '① 窗口化（键图标＝单框；上/左/右缩放带存在但不可见）',
            child: AylaTitleBar(controller: fake, events: noEvents),
          ),
          framed(
            caption: '② 最大化（键图标＝双框还原；缩放带整组移除）',
            child: AylaTitleBar(
              controller: _AylaGalleryChrome(reBake: rebake, maximized: true),
              events: noEvents,
            ),
          ),
          framed(
            caption: '③ 直播窗口级全屏（整条让位：高度归零）',
            child: AylaTitleBar(
              controller: fake,
              events: _AylaGalleryEvents(),
              // 全屏档直接传参：生产里由 main.dart 的 _AppRootState 用播放器广播的
              // aylaLiveWindowFullscreen 驱动（不能靠 window_manager 的事件，见该字段文档）。
              fullscreenActive: true,
            ),
          ),
          // 悬停态：静态画面无法触发 hover，故直接画两个「已悬停」的键。
          framed(
            caption: '④ 悬停对照（左＝关闭键危险底；右＝窗口化键冰蓝胶囊）',
            child: SizedBox(
              height: AylaTitleBarMetrics.brandRowHeight,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: const <Widget>[
                  AylaTitleBarHoverPreview(
                    kind: AylaWindowButtonKind.close,
                    hovered: true,
                  ),
                  AylaTitleBarHoverPreview(
                    kind: AylaWindowButtonKind.restore,
                    hovered: true,
                  ),
                  AylaTitleBarHoverPreview(
                    kind: AylaWindowButtonKind.minimize,
                    hovered: false,
                  ),
                ],
              ),
            ),
          ),
          // 最近调用（可交互的证据）
          Container(
            padding: const EdgeInsets.all(AylaSpacing.sp3),
            decoration: BoxDecoration(
              color: AylaColors.glassBg,
              borderRadius: BorderRadius.circular(AylaRadii.rCard),
              border: Border.all(color: AylaColors.glassBorder),
            ),
            child: Text(
              _aylaTitleBarCalls.isEmpty
                  ? '点上面的窗口键：命中区 40×40、悬停出 32×32 胶囊；这里会记录回调名。'
                  : '最近调用：${_aylaTitleBarCalls.join(' → ')}',
              style: AylaTextStyles.of(context).caption.copyWith(
                color: AylaColors.textPrimary,
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// 样张用窗口控制器：只记录、不碰真实窗口。
class _AylaGalleryChrome extends AylaWindowChromeController {
  _AylaGalleryChrome({required this.reBake, this.maximized = false});

  final VoidCallback reBake;
  final bool maximized;

  void _record(String name) {
    _aylaTitleBarCalls.add(name);
    if (_aylaTitleBarCalls.length > 6) _aylaTitleBarCalls.removeAt(0);
    reBake();
  }

  @override
  Future<void> minimize() async => _record('minimize');

  @override
  Future<void> maximize() async => _record('maximize');

  @override
  Future<void> unmaximize() async => _record('unmaximize');

  @override
  Future<void> close() async => _record('close');

  @override
  Future<void> startDragging() async => _record('startDragging');

  @override
  Future<bool> isMaximized() async => maximized;
}

/// 样张用事件源：只吞掉订阅（不往真实通道注册任何监听）。
///
/// 全屏那一档不再经过事件源 —— 由 `AylaTitleBar.fullscreenActive` 直接给。
class _AylaGalleryEvents extends AylaWindowEvents {
  _AylaGalleryEvents();

  @override
  void addListener(WindowListener listener) {}

  @override
  void removeListener(WindowListener listener) {}
}
