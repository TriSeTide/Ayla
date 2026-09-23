/// live 域最后一批（B2-6）之二：手机端 App 内浮动小窗（`LiveMiniPlayer.tsx` 228 行）。
///
/// ## 事实源（逐条对应 web，禁自由发挥）
/// ```
/// live.css 1021–1039  .live-mini-player：**fixed · right 16 · bottom 16 · z-index 60** ·
///                     **168 × 94（16:9）** · cursor pointer · `touch-action:none` · 禁选中 ·
///                     `:focus-visible { outline: var(--focus-ring); outline-offset: 2px }`
/// live.css 1042–1063  .live-mini-player-video-wrap：absolute inset 0 · radius-input ·
///                     **--glass-bg-strong** · --glass-filter（blur24 sat1.4）· 1px 亮边 ·
///                     --glass-shadow-compact · overflow hidden（**外层不裁剪**，关闭键才能突出在外）
///                     + video：100%×100% · object-fit contain · background #000
/// live.css 1065–1095  .live-mini-player-close：**top -10 / right -10** · 24×24 · pill ·
///                     rgba(70,91,146,.32) · 1px rgba(255,255,255,.28) · #fff · blur8 sat1.2 ·
///                     `0 2px 8px rgba(70,91,146,.2)` · hover → .52 · focus-visible 环
/// tsx 25–33           DRAG_THRESHOLD 5 / DRAG_MARGIN 8 / **MINI 168×94** /
///                     双指缩放 **宽 120–320**（高按 16:9）、**右下角锚定**
/// tsx 36–41           默认位置 = 右下角（`innerWidth - 168 - 8` / `innerHeight - 94 - 8`）
/// tsx 84–96           点击小窗 → 回直播间（`navigate(sourceRoute)`）
/// tsx 93–96           关闭 → 完整销毁会话（hls → WS → 轮询 → store → 活动态；幂等）
/// tsx 189–211         role=button + tabIndex=0 + **Enter/Space** 打开；aria「返回直播间」；
///                     title = 频道标题；拖动/缩放后抑制合成 click（tsx 70/182–186）
/// tsx 12–15（头注释）  仅**窄屏**离开直播间页面且直播中出现；同一时刻至多一个 owner
/// ```
///
/// ## 与 web 的装配差异（组件不写页面）
/// - video 由页面注入（同一 `HlsPlaybackController.videoView` ⇒ HLS 不断流），
///   组件只摆位与显隐；
/// - web 是 `position: fixed` + `z-index 60`：Flutter 侧返回 **[Positioned]**（与 A4 的
///   `bottomLeft`/`narrow` 档同规矩）⇒ 调用方必须把它放在页面最外层 `Stack` 的直接子级；
/// - 「窄屏 + 已离开直播间」这两个前置条件由**调用方**判断（本件只负责小窗本体）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;
import 'package:flutter/widget_previews.dart';

import '../theme/app_icons.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';

/// 拖动判定阈值（tsx 25 `DRAG_THRESHOLD = 5`）：位移超过它才算拖动、否则仍是点击。
const double kLiveMiniDragThreshold = 5;

/// 小窗可拖到的视口边缘最小间距（tsx 27 `DRAG_MARGIN = 8`）。
const double kLiveMiniDragMargin = 8;

/// 小窗默认尺寸（tsx 29–30 / live.css 1026–1027：168 × 94 = 16:9）。
const double kLiveMiniWidth = 168;
const double kLiveMiniHeight = 94;

/// 双指缩放范围（tsx 32–33：宽 120–320，高按 16:9）。
const double kLiveMiniMinWidth = 120;
const double kLiveMiniMaxWidth = 320;

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
  });

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

  /// 拖动会话（tsx 52–59）。
  bool _dragActive = false;
  bool _dragMoved = false;
  Offset _dragStart = Offset.zero;
  Offset _dragStartPos = Offset.zero;

  /// 双指缩放会话（tsx 61–67）：初始距离 + 初始尺寸/右下角锚点。
  double? _pinchDistance;
  Size? _pinchSize;
  Offset? _pinchBottomRight;

  bool _focused = false;
  bool _hovered = false;

  Offset _defaultPos(Size viewport) => Offset(
    math.max(kLiveMiniDragMargin, viewport.width - _size.width - 16),
    math.max(kLiveMiniDragMargin, viewport.height - _size.height - 16),
  );

  void _onScaleStart(ScaleStartDetails details, Size viewport) {
    if (details.pointerCount >= 2) {
      // 第二根手指落下 → 进入缩放（取消拖动，tsx 109–121）
      _dragActive = false;
      final Offset current = _pos ?? _defaultPos(viewport);
      _pinchDistance = null; // 首次 move 时以当时的指距为基准
      _pinchSize = _size;
      _pinchBottomRight = current + Offset(_size.width, _size.height);
      return;
    }
    _dragActive = true;
    _dragMoved = false; // 仅用于「是否超过拖动阈值」（阈值内仍算点击）
    _dragStart = details.focalPoint;
    _dragStartPos = _pos ?? _defaultPos(viewport);
  }

  void _onScaleUpdate(ScaleUpdateDetails details, Size viewport) {
    if (details.pointerCount >= 2) {
      // 双指缩放：右下角锚定、保持 16:9、clamp 120–320（tsx 137–152）
      final double dist = details.localFocalPoint.distance; // 缩放中的指距近似
      _pinchDistance ??= dist <= 0 ? 1 : dist;
      final Size base = _pinchSize ?? _size;
      final Offset anchor =
          _pinchBottomRight ?? _pos ?? _defaultPos(viewport) +
              Offset(_size.width, _size.height);
      final double scale = dist <= 0 ? 1 : dist / _pinchDistance!;
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
    if (details.pointerCount < 2) {
      _pinchDistance = null;
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
    final Offset pos = _pos ?? _defaultPos(viewport);

    return Positioned(
      // `position: fixed; right: 16; bottom: 16`（拖动后改为绝对 left/top）
      left: pos.dx,
      top: pos.dy,
      width: _size.width,
      height: _size.height,
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
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openRoom,
              onScaleStart: (ScaleStartDetails d) => _onScaleStart(d, viewport),
              onScaleUpdate: (ScaleUpdateDetails d) => _onScaleUpdate(d, viewport),
              onScaleEnd: _onScaleEnd,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AylaRadii.rInput + 2 + 2),
                  border: _focused
                      ? Border.all(color: AylaColors.glow500, width: 2)
                      : null,
                ),
                child: Stack(
                  clipBehavior: Clip.none, // 关闭键在小窗**外侧**（top/right -10）
                  children: <Widget>[
                    // `.live-mini-player-video-wrap`：圆角/边框/阴影/裁剪都在内层
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(AylaRadii.rInput),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: AylaColors.glassBgStrong, // --glass-bg-strong
                            borderRadius: BorderRadius.circular(
                              AylaRadii.rInput,
                            ),
                            border: Border.all(color: AylaColors.glassBorder),
                          ),
                          child: ColoredBox(
                            color: Colors.black, // video { background: #000 }
                            child: FittedBox(
                              fit: BoxFit.contain,
                              child:
                                  widget.videoView ??
                                  const SizedBox(width: 160, height: 90),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 关闭键：右上角**外侧**（top -10 / right -10），独立点击目标
                    Positioned(
                      top: -10,
                      right: -10,
                      child: _MiniCloseButton(
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
    );
  }
}

/// `.live-mini-player-close`：24×24 玻璃圆钮（白图标 14）。
class _MiniCloseButton extends StatefulWidget {
  const _MiniCloseButton({required this.hovered, required this.onPressed});

  final bool hovered;
  final VoidCallback? onPressed;

  @override
  State<_MiniCloseButton> createState() => _MiniCloseButtonState();
}

class _MiniCloseButtonState extends State<_MiniCloseButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
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
        child: _MiniDemo(
          size: const Size(kLiveMiniWidth, kLiveMiniHeight),
        ),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(420, 300),
        label: '双指缩放后的尺寸档（宽 120–320，高按 16:9，右下角锚定）· 左 = 最小 120×67.5 / 右 = 最大 320×180',
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
  Widget build(BuildContext context) => const ColoredBox(color: Color(0xFF2A3550));
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

/// 手机端浮动小窗。
@Preview(
  group: 'Widgets',
  name: '直播浮动小窗',
  size: Size(460, 900),
  wrapper: previewTheme,
)
Widget aylaLiveMiniPlayerPreview() => aylaLiveMiniPlayerSamples();
