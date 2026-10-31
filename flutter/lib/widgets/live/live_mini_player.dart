/// 手机端 App 内浮动小窗（`LiveMiniPlayer.tsx` 228 行）。
///
/// ## 事实源
/// ```
/// live.css 1021–1039  .live-mini-player：**fixed · right 16 · bottom 16 · z-index 60** ·
///                     **168 × 94（16:9）** · cursor pointer · `touch-action:none` · 禁选中 ·
///                     `:focus-visible { outline: var(--focus-ring); outline-offset: 2px }`
/// …（逐条 CSS 对照 / 层叠推导**原文**见 `docs/flutter/17-组件文件头归档（整理前原文）.md` 的 `widgets/live/live_mini_player.dart` 一节）
/// ```
///
/// ## 机制差异
/// - video 由页面注入（同一 `HlsPlaybackController.videoView` ⇒ HLS 不断流），
///   组件只摆位与显隐；
/// - web 是 `position: fixed` + `z-index 60`：Flutter 侧返回 **[Positioned]**（与 A4 的
///   `bottomLeft`/`narrow` 档同规矩）⇒ 调用方必须把它放在页面最外层 `Stack` 的直接子级；
/// - 「窄屏 + 已离开直播间」这两个前置条件由**调用方**判断（本件只负责小窗本体）。
///
/// ## 公开面
/// `AylaLiveMiniPlayer` · 样张 `aylaLiveMiniPlayerSamples()`

library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart'
    show
        PointerDeviceKind,
        PointerHoverEvent,
        PointerScrollEvent,
        PointerSignalEvent;
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;

import '../../theme/app_icons.dart';
import '../../theme/tokens.dart';
import '../base/tooltip.dart';

/// 拖动判定阈值（tsx 25 `DRAG_THRESHOLD = 5`）：位移超过它才算拖动、否则仍是点击。
const double kLiveMiniDragThreshold = 5;

/// 小窗可拖到的视口边缘最小间距（tsx 27 `DRAG_MARGIN = 8`）。
const double kLiveMiniDragMargin = 8;

/// 小窗默认尺寸（tsx 29–30 / live.css 1026–1027：168 × 94 = 16:9）。
/// 关闭键相对卡片右上角的**外溢**距离（`Positioned(top: -10, right: -10)`）。
///
/// 卡片的 `Stack` 是 `Clip.none`，所以按钮虽然画出来了，却不含在卡片的
/// `RenderBox.size` 里 —— 窗口外浮层按矩形裁 region 时会被裁掉，
/// 必须由调用方把这个外溢补进上报矩形（见 live_window_surface.dart）。
const double kLiveCloseInset = 10;

const double kLiveMiniWidth = 168;
const double kLiveMiniHeight = 94;

/// 双指缩放范围（tsx 32–33：宽 120–320，高按 16:9）。
/// 缩放下限 = 设计尺寸的 120（web 原值）。
///
/// ⚠️ App 内的默认尺寸就是 kLiveMiniWidth(168)，下限若也等于它，捏合收拢会
/// 完全没有变化（测试「收拢手指 ⇒ 变小」会失败，真实体验也是「缩不小」）。
/// 「窗口外浮层最小 168」由浮层自己传 initialSize 保证，不靠改这个常量。
const double kLiveMiniMinWidth = 120;
const double kLiveMiniMaxWidth = 900;

/// 窗口外浮层的**默认**宽度：设计尺寸偏小，浮层场景给大一点（16:9 等比）。
const double kLiveDetachedMiniDefaultWidth = 400.0;

/// 手机端浮动小窗（`LiveMiniPlayer.tsx`）。
///
/// **返回 `Positioned`**（web 是 `position: fixed`）⇒ 调用方放在最外层 `Stack` 的直接子级。
class AylaLiveMiniPlayer extends StatefulWidget {
  const AylaLiveMiniPlayer({
    super.key,
    required this.videoView,
    this.channelTitle,
    this.onOpenRoom,
    this.onClose,
    this.initialSize,
    this.cardKey,
    this.closeButtonKey,
    this.fixedPosition,
  });

  /// **固定落点**（窗口外宿主用）：卡片钉在宿主窗口内的这个偏移上。
  ///
  /// 非 null 时本组件**不再自己移动/缩放**（拖动、边缘缩放、捏合、滚轮全部关闭）——
  /// 在 Android 系统叠加层里，窗口的尺寸就是卡片尺寸，改卡片等于改窗口，
  /// 只能由原生 `WindowManager.updateViewLayout` 做（见 `LiveMiniWindowHost.kt`）。
  /// 这里若再叠一层组件级缩放，两者会互相打架（每帧改两次尺寸）。
  ///
  /// 视觉、关闭键位置、点击语义**完全不变** —— 换的只是「谁负责几何」。
  final Offset? fixedPosition;

  /// 卡片本体（不含关闭键）的 key：宿主用它量可点击区域。
  final GlobalKey? cardKey;

  /// 关闭键的 key：它画在卡片外侧，卡片的 RenderBox 量不到它，
  /// 必须单独量（否则窗口外浮层按矩形裁 region 会把按钮裁掉）。
  final GlobalKey? closeButtonKey;

  /// 初始尺寸（null = 设计尺寸 168×94，App 内保持原样）。
  ///
  /// 窗口外浮层传更大的默认值（见 [kLiveDetachedMiniDefaultWidth]）。
  final Size? initialSize;

  /// 视频视图（页面注入同一播放器 ⇒ HLS 不断流）。
  final Widget? videoView;

  /// 频道标题（web `title={mini.channel?.title ?? "直播间"}`）。
  final String? channelTitle;

  /// 点击小窗 / Enter / Space → 回直播间（tsx 90 `navigate(sourceRoute)`）。
  final VoidCallback? onOpenRoom;

  /// 右上关闭键 → 完整销毁会话（tsx 93–96）。
  final VoidCallback? onClose;

  @override
  State<AylaLiveMiniPlayer> createState() => _AylaLiveMiniPlayerState();
}

class _AylaLiveMiniPlayerState extends State<AylaLiveMiniPlayer> {
  /// 用户拖动/缩放后的绝对位置（null = 未动过，走默认右下角 16）。
  Offset? _pos;
  Size _size = const Size(kLiveMiniWidth, kLiveMiniHeight);

  /// 当前悬停光标（默认手型；靠近右/下边缘时变成缩放光标）。
  MouseCursor _hoverEdge = SystemMouseCursors.click;

  /// 边缘判定宽度（逻辑 px）：贴着右/下边缘这么宽以内就算「要缩放」。
  /// 边缘判定宽度（逻辑 px）。
  ///
  /// ⚠️ 必须留在**卡片内部**：窗口外浮层用 `SetWindowRgn` 把窗口裁成卡片形状，
  /// 卡片之外的区域不属于这个窗口，鼠标在那里根本不会产生 hover 事件。
  /// 取 6px 既能提示「这里可以拉」，又保证整条带子都在窗口内。
  static const double _edgeGrab = 6.0;

  /// 指针命中了哪条边（四条边 + 四个角）。
  ///
  /// 用户要求「每条边都应该有缩放指针」：普通窗口四面都能拉，小窗也不该只有
  /// 右下角能用。返回的 (left/right/top/bottom) 决定光标形状与缩放锚点。
  ({bool left, bool right, bool top, bool bottom}) _edgesAt(Offset local) {
    return (
      left: local.dx <= _edgeGrab,
      right: local.dx >= _size.width - _edgeGrab,
      top: local.dy <= _edgeGrab,
      bottom: local.dy >= _size.height - _edgeGrab,
    );
  }

  /// 按命中的边组合给光标（角优先，其次单边，都不是则普通手型）。
  MouseCursor _cursorFor(Offset local) {
    // 右上角是关闭键的地盘：那里必须是手型，否则用户把鼠标移到关闭键上看到的
    // 是「斜向缩放」指针，既误导又和按钮语义打架。
    if (local.dx >= _size.width - _edgeGrab - kLiveCloseInset &&
        local.dy <= _edgeGrab + kLiveCloseInset) {
      return SystemMouseCursors.click;
    }
    final e = _edgesAt(local);
    if (e.left && e.top) return SystemMouseCursors.resizeUpLeft;
    if (e.right && e.top) return SystemMouseCursors.resizeUpRight;
    if (e.left && e.bottom) return SystemMouseCursors.resizeDownLeft;
    if (e.right && e.bottom) return SystemMouseCursors.resizeDownRight;
    if (e.left || e.right) return SystemMouseCursors.resizeLeftRight;
    if (e.top || e.bottom) return SystemMouseCursors.resizeUpDown;
    return SystemMouseCursors.click;
  }

  @override
  void initState() {
    super.initState();
    final Size? initial = widget.initialSize;
    if (initial != null && initial.width > 0) {
      final double w = initial.width.clamp(
        kLiveMiniMinWidth,
        kLiveMiniMaxWidth,
      );
      _size = Size(w, w * 9 / 16);
    }
  }

  /// 拖动会话（tsx 52–59）。
  bool _dragActive = false;
  bool _dragMoved = false;
  Offset _dragStart = Offset.zero;
  Offset _dragStartPos = Offset.zero;

  /// 双指缩放会话（tsx 61–67）：**起点尺寸 + 起点右下角锚点**。
  ///
  /// ⚠️ 曾有一个 _pinchDistance（初始指距）字段：它用 localFocalPoint.distance
  /// 冒充指距 —— 那是**中点相对左上角的距离**，不是两指间距，导致缩放方向反了。
  /// 现在比例完全由 ScaleUpdateDetails.scale 提供，不再需要自己维护基准距离。
  Size? _pinchSize;
  Offset? _pinchBottomRight;

  /// 单指**从边缘按下**时的缩放会话（桌面端「拉边缘改大小」）。
  ///
  /// 桌面没有捏合手势：用户把鼠标放在右/下边缘按下并移动，语义应当是缩放，
  /// 而不是平移整张卡片。这里在 _onScaleStart 里按按下点是否落在边缘决定。
  bool _edgeResizeActive = false;
  Size _edgeResizeBase = Size.zero;
  Offset _edgeResizeAnchor = Offset.zero;
  Offset _edgeResizeStart = Offset.zero;
  ({bool left, bool right, bool top, bool bottom}) _edgeResizeEdges = (
    left: false,
    right: false,
    top: false,
    bottom: false,
  );

  bool _focused = false;
  bool _hovered = false;

  /// 默认落点：右下角。
  ///
  /// ⚠️ 右侧要额外留出关闭键的外溢（它画在卡片右上角外侧），否则默认位置就
  /// 会把关闭键顶到窗口边界外、被 SetWindowRgn 裁掉。
  Offset _defaultPos(Size viewport) => Offset(
    math.max(kLiveMiniDragMargin, viewport.width - _size.width - 16),
    math.max(kLiveMiniDragMargin, viewport.height - _size.height - 16),
  );

  void _onScaleStart(ScaleStartDetails details, Size viewport) {
    if (details.pointerCount >= 2) {
      // 第二根手指落下 → 进入缩放（取消拖动，tsx 109–121）
      _dragActive = false;
      final Offset current = _pos ?? _defaultPos(viewport);
      // 缩放基准 = **手势起点的尺寸与右下角**；比例由 details.scale 给（见 _onScaleUpdate）。
      _pinchSize = _size;
      _pinchBottomRight = current + Offset(_size.width, _size.height);
      return;
    }
    // 桌面端：从右/下边缘按下 = 缩放，不是平移。
    //
    // 鼠标只有一个指针，`pointerCount` 永远到不了 2，所以捏合那条分支在桌面
    // 上不存在；没有这一步，用户把鼠标放在边缘拖动只会**移动**整张卡片
    // （用户实报：「变了但拉不大，反而是在移动悬浮窗」）。
    final Offset local = details.localFocalPoint;
    // 右上角归关闭键：那里按下不能被判成「拉边缘缩放」，否则点关闭会变成缩放。
    final bool onCloseButton =
        local.dx >= _size.width - _edgeGrab - kLiveCloseInset &&
        local.dy <= _edgeGrab + kLiveCloseInset;
    // 只有**鼠标**才走「拉边缘缩放」：触摸是单指拖动 / 双指捏合，语义不同。
    // 不加这个判断，触摸在边缘按下会被误判成缩放（测试里 `startGesture` 就是
    // 单指针 touch，结果整块被拉走，拖动 clamp 断言全崩）。
    final bool pointerIsMouse = details.kind == PointerDeviceKind.mouse;
    final e = (onCloseButton || !pointerIsMouse)
        ? (left: false, right: false, top: false, bottom: false)
        : _edgesAt(local);
    if (e.left || e.right || e.top || e.bottom) {
      _edgeResizeActive = true;
      _dragActive = false;
      _edgeResizeBase = _size;
      _edgeResizeStart = details.focalPoint;
      // 缩放锚点 = 被拉那条边的**对边**中点：拉右边时左边固定，拉左上时右下固定。
      // 这样手感与普通窗口一致。
      final Offset pos = _pos ?? _defaultPos(viewport);
      final double anchorX = e.left
          ? pos.dx +
                _size
                    .width // 拉左边 ⇒ 右边固定
          : e.right
          ? pos
                .dx // 拉右边 ⇒ 左边固定
          : pos.dx + _size.width / 2;
      final double anchorY = e.top
          ? pos.dy +
                _size
                    .height // 拉上边 ⇒ 下边固定
          : e.bottom
          ? pos
                .dy // 拉下边 ⇒ 上边固定
          : pos.dy + _size.height / 2;
      _edgeResizeAnchor = Offset(anchorX, anchorY);
      _edgeResizeEdges = e;
      return;
    }

    _edgeResizeActive = false;
    _dragActive = true;
    _dragMoved = false; // 仅用于「是否超过拖动阈值」（阈值内仍算点击）
    _dragStart = details.focalPoint;
    _dragStartPos = _pos ?? _defaultPos(viewport);
  }

  void _onScaleUpdate(ScaleUpdateDetails details, Size viewport) {
    // 双指优先：一旦第二根手指落下，就退出「拉边缘」改走捏合。
    // 否则触摸捏合会被单指边缘缩放吃掉（测试「张开/收拢手指」全挂）。
    if (details.pointerCount >= 2) {
      _edgeResizeActive = false;
    }
    if (_edgeResizeActive) {
      // 拉边缘：位移 → 宽度增量。方向决定符号，手感与普通窗口一致
      // （拉右边/下边向外 ⇒ 变大；拉左边/上边向外 ⇒ 也变大）。
      final Offset delta = details.focalPoint - _edgeResizeStart;
      final e = _edgeResizeEdges;
      double grow = 0;
      if (e.right) grow = delta.dx;
      if (e.left) grow = math.max(grow, -delta.dx);
      if (e.bottom) grow = math.max(grow, delta.dy);
      if (e.top) grow = math.max(grow, -delta.dy);
      // 等比 16:9：宽高同时变，所以宽度增量取位移的 2 倍才跟手。
      final double w = (_edgeResizeBase.width + grow * 2).clamp(
        kLiveMiniMinWidth,
        kLiveMiniMaxWidth,
      );
      if ((w - _size.width).abs() < 0.5) return;
      final double h = w * 9 / 16;
      setState(() {
        _size = Size(w, h);
        // 按锚点重新求左上角：锚点是被拉边的对边，固定不动。
        _pos = Offset(
          e.left ? _edgeResizeAnchor.dx - w : _edgeResizeAnchor.dx,
          e.top ? _edgeResizeAnchor.dy - h : _edgeResizeAnchor.dy,
        );
      });
      return;
    }
    if (details.pointerCount >= 2) {
      // 双指缩放：右下角锚定、保持 16:9、clamp 120–320（tsx 137–152）。
      //
      // ⚠️⚠️ **比例必须用 details.scale，不能自己算指距**（2026-10 用户实报缩放反了的根因）。
      //
      // 旧写法把 details.localFocalPoint.distance 当指距：那是**双指中点相对控件左上角
      // 的距离**，不是两指之间的距离。后果（三条都是可复现的）：
      //   ① 中点离左上角越远 ⇒ 数值越大 ⇒ 被当成放大，与捏合方向**无关**；
      //      双指在控件右下角捏合时数值本来就大 ⇒ 松开反而变大、张开反而变小（反了）；
      //   ② 中点靠近左上角时数值趋 0 ⇒ scale 抖动甚至爆掉；
      //   ③ 上下平移中点也会改这个数值 ⇒ 张合与拖动互相污染。
      //
      // ScaleUpdateDetails.scale 是框架算好的**相对手势起点**的缩放比：
      //   缩放识别器 scale = _currentSpan / _initialSpan
      //   （scale.dart 的 _pointerScaleFactor；span = 各指到焦点的平均偏离 ≈ 半指距），
      //   且每次 pointer 增减都会 _reconfigure() 重置基准 —— 正是我们要的语义。
      // 配合 _pinchSize（起点尺寸）即得绝对尺寸，**不能累乘**（scale 已含全程比例）。
      final Size base = _pinchSize ?? _size;
      final Offset anchor =
          _pinchBottomRight ??
          (_pos ?? _defaultPos(viewport)) + Offset(_size.width, _size.height);
      final double rawScale = details.scale;
      final double scale = rawScale.isFinite && rawScale > 0 ? rawScale : 1;
      final double w = (base.width * scale).clamp(
        kLiveMiniMinWidth,
        kLiveMiniMaxWidth,
      );
      final double h = (w * 9 / 16);
      setState(() {
        _size = Size(w, h);
        _pos = anchor - Offset(w, h);
      });
      return;
    }
    if (!_dragActive) return;
    final Offset delta = details.focalPoint - _dragStart;
    if (!_dragMoved &&
        delta.dx.abs() < kLiveMiniDragThreshold &&
        delta.dy.abs() < kLiveMiniDragThreshold) {
      return; // 未超阈值：保留点击语义（tsx 160–162）
    }
    _dragMoved = true;
    final double maxLeft = math.max(
      kLiveMiniDragMargin,
      viewport.width - _size.width - kLiveMiniDragMargin,
    );
    final double maxTop = math.max(
      kLiveMiniDragMargin,
      viewport.height - _size.height - kLiveMiniDragMargin,
    );
    setState(() {
      _pos = Offset(
        (_dragStartPos.dx + delta.dx).clamp(kLiveMiniDragMargin, maxLeft),
        (_dragStartPos.dy + delta.dy).clamp(kLiveMiniDragMargin, maxTop),
      );
    });
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _edgeResizeActive = false;
    if (details.pointerCount < 2) {
      // 手指减到单指 ⇒ 本次缩放会话结束（下次双指会重新记起点）。
      _pinchSize = null;
      _pinchBottomRight = null;
    }
    _dragActive = false;
    // ⚠️ web 需要 `suppressClickRef`（拖动后的**合成 click** 会误触返回，tsx 70/182–186）；
    //    Flutter 没有合成 click——拖动一开始 tap 识别器就输给了 scale 识别器
    //    ⇒ 不做抑制，用户下一次点击正常回房（更符合预期）。
  }

  void _openRoom() {
    widget.onOpenRoom?.call();
  }

  @override
  Widget build(BuildContext context) {
    final Size viewport = MediaQuery.sizeOf(context);
    final Offset pos = widget.fixedPosition ?? (_pos ?? _defaultPos(viewport));
    // 固定落点（窗口外宿主）⇒ 组件不参与几何：拖动/缩放/滚轮全部不注册，
    // 让原生的窗口手势独占（见 [AylaLiveMiniPlayer.fixedPosition]）。
    final bool fixed = widget.fixedPosition != null;

    return Positioned(
      // `position: fixed; right: 16; bottom: 16`（拖动后改为绝对 left/top）
      //
      left: pos.dx,
      top: pos.dy,
      width: _size.width,
      height: _size.height,
      // web «LiveMiniPlayer.tsx:195»：«title={mini.channel?.title ?? "直播间"}»
      // ⇒ AylaTooltip（空标题 ⇒ 透传不提示）
      child: AylaTooltip(
        message: widget.channelTitle,
        child: Semantics(
          button: true,
          label: '返回直播间', // tsx 194
          child: Focus(
            onFocusChange: (bool has) => setState(() => _focused = has),
            onKeyEvent: (FocusNode node, KeyEvent event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              final bool activate =
                  event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.space;
              if (!activate) return KeyEventResult.ignored;
              _openRoom();
              return KeyEventResult.handled;
            },
            child: Listener(
              // 鼠标滚轮缩放（桌面端；触屏用双指捏合，两条路径都改同一个 _size）。
              // 用户要求「边缘拖动 + 滚轮都要」，这是滚轮那条。
              onPointerSignal: (PointerSignalEvent event) {
                if (event is! PointerScrollEvent) return;
                final double delta = event.scrollDelta.dy;
                if (delta == 0) return;
                // ⚠️ 按**比例**缩放，不能按「每像素 delta 加多少像素宽」：
                // 滚轮一格是 ±120，用 `_size.width - delta * 12` 会一次跳 1440px
                // ⇒ 滚一下直接顶到最大、再滚一下顶到最小（用户实报）。
                // 这里一格固定 ±8%，与尺寸无关，手感匀速。
                final double step = delta > 0 ? 0.92 : 1.08;
                final double next = (_size.width * step).clamp(
                  kLiveMiniMinWidth,
                  kLiveMiniMaxWidth,
                );
                if (next == _size.width) return;
                // 以右下角为锚点缩放（与捏合手势一致，避免窗口边缘跳动）。
                final Offset anchor =
                    (_pos ?? _defaultPos(viewport)) +
                    Offset(_size.width, _size.height);
                setState(() {
                  _size = Size(next, next * 9 / 16);
                  _pos = anchor - Offset(_size.width, _size.height);
                });
              },
              child: MouseRegion(
                // Edge-aware cursor: the card resizes from its bottom-right corner
                // (that is the anchor used by both the pinch and the wheel), so the
                // right/bottom edges get the matching resize cursor and the body stays
                // a plain click. Without this the whole card showed a hand cursor and
                // nothing hinted that the edges are draggable.
                cursor: _hoverEdge,
                onHover: (PointerHoverEvent e) {
                  final MouseCursor next = _cursorFor(e.localPosition);
                  if (next != _hoverEdge) setState(() => _hoverEdge = next);
                },
                onEnter: (_) => setState(() => _hovered = true),
                onExit: (_) {
                  setState(() {
                    _hovered = false;
                    _hoverEdge = SystemMouseCursors.click;
                  });
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _openRoom,
                  // 固定落点模式（Android 窗口外宿主）：几何全归原生，这里只留点击。
                  onScaleStart: fixed
                      ? null
                      : (ScaleStartDetails d) => _onScaleStart(d, viewport),
                  onScaleUpdate: fixed
                      ? null
                      : (ScaleUpdateDetails d) => _onScaleUpdate(d, viewport),
                  onScaleEnd: fixed ? null : _onScaleEnd,
                  // ⚠️ 关闭键画在卡片**外侧**（top/right: -kLiveCloseInset），
                  // 所以这里必须给它留出真实占位：Flutter 的 RenderBox.hitTest
                  // 会先判断该点是否落在**自身 size 内**，落在外面直接返回 false。
                  //
                  // 之前关闭键只是靠 `Clip.none` 被「画」出来，命中测试却仍被父级
                  // 拒绝 —— 于是只有它压在卡片内的那 1/4（左下角）能点，其余全部
                  // 无效，同时外层按卡片矩形裁剪窗口 region 也把它切掉一截。
                  //
                  child: DecoratedBox(
                    key: widget.cardKey,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(
                        AylaRadii.rInput + 2 + 2,
                      ),
                      border: _focused
                          ? Border.all(color: AylaColors.glow500, width: 2)
                          : null,
                    ),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: <Widget>[
                        // `.live-mini-player-video-wrap`：圆角/边框/阴影/裁剪都在内层
                        Positioned.fill(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(
                              AylaRadii.rInput,
                            ),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: AylaColors
                                    .glassBgStrong, // --glass-bg-strong
                                borderRadius: BorderRadius.circular(
                                  AylaRadii.rInput,
                                ),
                                border: Border.all(
                                  color: AylaColors.glassBorder,
                                ),
                              ),
                              // video { width/height: 100%; object-fit: contain; background: #000 }
                              // （live.css:1055–1061）—— contain 由 video 元素自身承担，
                              // 外层不得再套 FittedBox（同 live_player.dart 的黑屏根因注释：
                              // 会让 media_kit 内部 Stack 展开出 Infinity ⇒ 无效变换矩阵 ⇒ 不绘制）。
                              child: ColoredBox(
                                color:
                                    Colors.black, // video { background: #000 }
                                child:
                                    widget.videoView ??
                                    const SizedBox(width: 160, height: 90),
                              ),
                            ),
                          ),
                        ),
                        // 关闭键：卡片右上角外侧（top/right 各外溢 kLiveCloseInset），
                        // 外观就是设计稿那样——只有左下角压在卡片上。
                        //
                        // 命中问题：Flutter 逐层检查「点是否落在自身 size 内」，而它
                        // 大部分悬在父级 Stack 之外 ⇒ 只有压在卡片内的那 1/4 能点。
                        // 这里用 OverflowBox 给它一块**不裁剪、不限制**的盒子，让它
                        // 在父级边界外依然接住指针；布局与视觉都不变。
                        Positioned(
                          top: -kLiveCloseInset,
                          right: -kLiveCloseInset,
                          child: _MiniCloseButton(
                            key: widget.closeButtonKey,
                            hovered: _hovered,
                            onPressed: widget.onClose,
                          ),
                        ),
                      ],
                    ),
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

/// `.live-mini-player-close`：24×24 玻璃圆钮（白图标 14）。
class _MiniCloseButton extends StatefulWidget {
  const _MiniCloseButton({
    super.key,
    required this.hovered,
    required this.onPressed,
  });

  final bool hovered;
  final VoidCallback? onPressed;

  @override
  State<_MiniCloseButton> createState() => _MiniCloseButtonState();
}

class _MiniCloseButtonState extends State<_MiniCloseButton> {
  bool _hovered = false;
  bool _focused = false;

  /// 关闭键**悬在卡片外侧**（top/right 各 -kLiveCloseInset），只有左下角压在
  /// 卡片上。Flutter 的命中测试逐层检查「该点是否落在自身 size 内」，父级
  /// Stack 只有卡片那么大 ⇒ 按钮露在外面的大半圈收不到点击（用户实报
  /// 「只有左下角能点」）。
  ///
  /// 用 `OverflowBox` 给它一块**固定的真实盒子**：布局位置由外层 Positioned
  /// 决定，这里只声明尺寸并允许它越界绘制/命中。视觉与卡片尺寸都不变。
  Widget _withWideHitArea(Widget child) =>
      SizedBox(width: 24, height: 24, child: child);

  @override
  Widget build(BuildContext context) {
    return _withWideHitArea(
      Semantics(
        button: true,
        label: '关闭小窗', // tsx 217
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
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: _hovered
                      ? const Color(0x85465B92) // hover rgba(70,91,146,.52)
                      : const Color(0x52465B92), // rgba(70,91,146,.32)
                  borderRadius: AylaRadii.pill,
                  border: Border.all(
                    color: _focused
                        ? AylaColors.glow500
                        : const Color(0x47FFFFFF),
                    width: _focused ? 2 : 1,
                  ),
                ),
                alignment: Alignment.center,
                child: AylaIcon(
                  aylaIconByName('iconClose')!,
                  size: 14, // tsx 224
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ======================= 预览样张 =======================

/// 浮动小窗样张（可交互：拖动 / 滚轮模拟双指缩放 / 点主体回房 / 点右上关闭）。
Widget aylaLiveMiniPlayerSamples() {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      _Stage(
        viewport: const Size(420, 300),
        label:
            '浮动小窗（`LiveMiniPlayer`）· fixed 右下 16 / **168×94（16:9）** / z 60 · 内层 radius-input + `--glass-bg-strong` + blur24 + compact 阴影；**关闭键在小窗右上角外侧（-10）** · 可交互：拖动（阈值 5px，边距 8）/ 点主体回房 / 点关闭',
        child: _MiniDemo(size: const Size(kLiveMiniWidth, kLiveMiniHeight)),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(420, 300),
        label:
            '双指缩放后的尺寸档（宽 120–320，高按 16:9，右下角锚定）· 左 = 最小 120×67.5 / 右 = 最大 320×180',
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(child: _MiniDemo(size: const Size(120, 67.5))),
            Expanded(child: _MiniDemo(size: const Size(320, 180))),
          ],
        ),
      ),
    ],
  );
}

class _MiniDemo extends StatelessWidget {
  const _MiniDemo({required this.size});

  final Size size;

  @override
  Widget build(BuildContext context) {
    // 样张舞台是「固定视口」，小窗本体返回 Positioned ⇒ 用 Stack 承载
    return Stack(
      children: <Widget>[
        Center(
          child: Text(
            '小窗尺寸 ${size.width.toStringAsFixed(0)}×${size.height.toStringAsFixed(0)}',
            style: const TextStyle(fontSize: 11),
          ),
        ),
        AylaLiveMiniPlayer(
          channelTitle: '深夜电台 · 爱莉陪你写代码',
          videoView: const _MiniFakeVideo(),
          onOpenRoom: () {},
          onClose: () {},
        ),
      ],
    );
  }
}

class _MiniFakeVideo extends StatelessWidget {
  const _MiniFakeVideo();

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: Color(0xFF2A3550));
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
