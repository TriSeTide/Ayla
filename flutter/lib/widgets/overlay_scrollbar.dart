/// B6-4：全局覆盖层滚动条（OverlayScrollbar.tsx 311 行 + base.css 385–421）。
///
/// ## 事实源（逐条对应 web）
/// ── 常量：THICKNESS **4** / OFFSET **2** / PAD **3** / MIN_VERT **28** / MIN_HORZ **48** /
/// HIDE_DELAY **600ms** / 窄屏 `max-width: 768px` **完全不显示、不参与计算**
/// ── 度量：竖条优先（`scrollHeight > clientHeight + 1`），纯横向容器才画底部条；
/// thumb 长 = `max(MIN, round(track² / scrollSize))`；位置 = `scrollOffset / (scrollSize − track) ×
/// (track − thumb)`；竖条 left = `round(rect.right) − OFFSET − THICKNESS − PAD`、top = `round(rect.top) + top − PAD`；
/// 横条 top = `round(rect.bottom) − OFFSET − THICKNESS − PAD`、left = `round(rect.left) + left − PAD`
/// ── 质感（base.css 388–421）：`position: fixed` · z 2147483000 · `padding: 3px` +
/// `background-clip: content-box`（**视觉条 4px，四边 3px 透明命中区**）·
/// 底 `rgba(126,149,189,.38)` → hover **.55** · 圆角 `THICKNESS/2 + PAD` · 显隐
/// `transition: opacity .18s ease-out`（reduced-motion 无过渡）· `.is-visible` 才 `pointer-events: auto`
/// ── 交互：滚动/悬停时显示（悬停期间**不淡出**），停止 600ms 后淡出；thumb 可拖拽
/// （`pointerdown → setPointerCapture`，`pointermove` 把拾取点换算成 `scrollTop/scrollLeft`，
/// `pointerup/cancel` 结束并按悬停语义重新计时）；窄屏/窗口 resize 时清掉可见态避免几何过期
///
/// ## 与 web 的机制差异（平台语义差，逐条登记）
/// web 是**文档级事件委托**（`document` 的 scroll(capture)/mouseover/mouseout + `window.resize`），
/// thumb 挂在 `body` 上（React 树之外），用 `getBoundingClientRect` 取视口坐标。Flutter 没有
/// 文档级事件与 body 挂载，等价做法：
/// - **滚动信号**：`NotificationListener<ScrollNotification>`（由每个 Scrollable **向上冒泡**）⇒ 本件
///   必须**包住**被观察的子树（用 [child] 参数），而不是 web 那种「无渲染输出、挂一次即可」；
/// - **thumb 宿主**：画在本件自身的 `Stack` 槽位里，坐标用 `localToGlobal(ancestor: 本件)` 换算；
/// - **悬停保持**：`MouseRegion`（包住 child）按指针是否落在被滚容器矩形内判定（等价
///   `target.closest([data-ov-scrollbar])`）；
/// - **拖拽**：`GestureDetector.onPanStart/Update` + `position.jumpTo/`jumpTo`（等价 pointer capture
///   的换算）。
/// ⚠️ 因此**不是** web 的「挂一次即可」：页面层要把它包在应用根（`AylaOverlayScrollbar(child: app)`）。
library;

import 'dart:async';

import 'package:flutter/gestures.dart' show PointerExitEvent, PointerHoverEvent;
import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../theme/preview_theme.dart';
import '../theme/tokens.dart';

/// `.ov-scrollbar-thumb` —— 全局覆盖层滚动条（web OverlayScrollbar）。
class AylaOverlayScrollbar extends StatefulWidget {
  const AylaOverlayScrollbar({
    super.key,
    required this.child,
    this.enabled = true,
  });

  /// 被观察的子树（每个 `Scrollable` 的滚动通知都会冒泡到这里）。
  final Widget child;

  /// 是否启用（false = 完全透传，不绘制、不监听；测试/特殊场景可用）。
  final bool enabled;

  /// 滚动条视觉粗细（`THICKNESS`）。
  static const double thickness = 4;

  /// 距容器边缘的留白（`OFFSET`）。
  static const double offset = 2;

  /// thumb 四边透明命中区（`PAD`）；视觉条保持 [thickness]。
  static const double pad = 3;

  /// 竖条最小视觉长度（`MIN_VERT`）。
  static const double minVert = 28;

  /// 横条最小视觉长度（`MIN_HORZ`）。
  static const double minHorz = 48;

  /// 停止滚动后淡出延迟（`HIDE_DELAY`）。
  static const Duration hideDelay = Duration(milliseconds: 600);

  /// 显隐过渡（`transition: opacity .18s ease-out`）。
  static const Duration fadeDuration = Duration(milliseconds: 180);

  /// 窄屏断点（≤768 完全不显示；与项目手机断点一致）。
  static const double narrowBreakpoint = 768;

  /// thumb 底色（静息 `rgba(126,149,189,.38)`）。
  static const Color thumbColor = Color(0x617E95BD);

  /// thumb 底色（hover `rgba(126,149,189,.55)`）。
  static const Color thumbHoverColor = Color(0x8C7E95BD);

  /// 圆角：`THICKNESS / 2 + PAD`。
  static const double thumbRadius = thickness / 2 + pad;

  @override
  State<AylaOverlayScrollbar> createState() => _AylaOverlayScrollbarState();
}

/// 单个滚动容器的 thumb 状态（web 的 `WeakMap<Element, thumb>` + 三个 Set 的等价）。
class _ThumbState {
  _ThumbState(this.position);

  /// 目标的滚动位置（`ScrollPosition` 即 web 的滚动元素）。
  final ScrollPosition position;

  /// 淡出计时器（web `timers`）。
  Timer? timer;

  /// 是否可见（web `.is-visible`）。
  bool visible = false;

  /// 指针是否悬停在该容器上（web `hovered`）。
  bool hovered = false;

  /// thumb 自身是否悬停（web `.ov-scrollbar-thumb:hover` 的底色升级）。
  bool thumbHovered = false;

  /// thumb 矩形（本件坐标系；null = 该容器当前不可滚）。
  Rect? rect;

  /// 是否竖向（web `dataset.dir`：竖条优先）。
  bool vertical = true;

  /// 该容器在屏幕上的视口矩形（用于悬停判定）。
  Rect? viewport;
}

class _AylaOverlayScrollbarState extends State<AylaOverlayScrollbar> {
  final GlobalKey _hostKey = GlobalKey();

  /// 活跃滚动容器（web 的 `thumbs/owners/active` 三个集合的合并表达）。
  final List<_ThumbState> _thumbs = <_ThumbState>[];

  /// 正在拖拽的 thumb（web 的 `drag`）。
  _ThumbState? _dragging;

  /// 拾取点在 thumb 元素盒内的偏移（web `grabOffset`）。
  double _grabOffset = 0;

  bool get _narrow =>
      MediaQuery.sizeOf(context).width <= AylaOverlayScrollbar.narrowBreakpoint;

  /// web `narrow()`：窄屏完全不显示、不参与计算。
  bool get _active => widget.enabled && !_narrow;

  RenderBox? get _hostBox =>
      _hostKey.currentContext?.findRenderObject() as RenderBox?;

  @override
  void dispose() {
    for (final _ThumbState t in _thumbs) {
      t.timer?.cancel();
    }
    super.dispose();
  }

  _ThumbState _stateFor(ScrollPosition position) {
    for (final _ThumbState t in _thumbs) {
      if (identical(t.position, position)) return t;
    }
    final _ThumbState created = _ThumbState(position);
    _thumbs.add(created);
    return created;
  }

  /// web `update(el)`：重算几何（不可滚 ⇒ 收起并不参与悬停）。
  void _update(_ThumbState t) {
    final ScrollPosition p = t.position;
    final RenderBox? host = _hostBox;
    final RenderObject? child = p.context.storageContext.findRenderObject();
    if (host == null || child is! RenderBox || !child.hasSize) {
      t.rect = null;
      t.viewport = null;
      return;
    }
    final Rect viewport =
        (child.localToGlobal(Offset.zero, ancestor: host)) & child.size;
    t.viewport = viewport;

    // web：scrollHeight > clientHeight + 1（Flutter 的 Scrollable 单轴 ⇒ 用 maxScrollExtent 判定）
    final double track = p.viewportDimension;
    final double extent = p.maxScrollExtent + track;
    if (!p.hasPixels || !p.hasViewportDimension || p.maxScrollExtent <= 1) {
      t.rect = null;
      return;
    }

    const double thickness = AylaOverlayScrollbar.thickness;
    const double pad = AylaOverlayScrollbar.pad;
    const double inset = AylaOverlayScrollbar.offset;
    final bool vertical = p.axis == Axis.vertical;
    t.vertical = vertical;

    // thumb 长 = max(MIN, round(track² / scrollSize))（web 同式）
    final double visual = vertical
        ? (track * track / extent)
                .roundToDouble()
                .clamp(AylaOverlayScrollbar.minVert, double.infinity)
        : (track * track / extent)
                .roundToDouble()
                .clamp(AylaOverlayScrollbar.minHorz, double.infinity);
    final double maxOffset = track - visual;
    final double pos = maxOffset <= 0
        ? 0
        : (p.pixels / p.maxScrollExtent * maxOffset).roundToDouble();

    t.rect = vertical
        ? Rect.fromLTWH(
            viewport.right.roundToDouble() - inset - thickness - pad,
            viewport.top.roundToDouble() + pos - pad,
            thickness + pad * 2,
            visual + pad * 2,
          )
        : Rect.fromLTWH(
            viewport.left.roundToDouble() + pos - pad,
            viewport.bottom.roundToDouble() - inset - thickness - pad,
            visual + pad * 2,
            thickness + pad * 2,
          );
  }

  /// web `show(el)`：立即显示并重置淡出计时。
  void _show(_ThumbState t) {
    t.timer?.cancel();
    t.timer = null;
    if (!t.visible) setState(() => t.visible = true);
  }

  /// web `scheduleHide(el)`：HIDE_DELAY 后淡出（悬停中/拖拽中不淡出）。
  void _scheduleHide(_ThumbState t) {
    t.timer?.cancel();
    t.timer = Timer(AylaOverlayScrollbar.hideDelay, () {
      if (!mounted) return;
      if (t.hovered || identical(_dragging, t)) return;
      if (t.visible) setState(() => t.visible = false);
    });
  }

  /// web `onScroll`：更新 + 显示 + 计时。
  bool _onScroll(ScrollNotification n) {
    if (!_active) return false;
    // 滚动通知从各 Scrollable 向上冒泡；用它定位目标 ScrollPosition
    final BuildContext? ctx = n.context;
    final ScrollPosition? p =
        ctx == null ? null : Scrollable.maybeOf(ctx)?.position;
    if (p == null) return false;
    final _ThumbState t = _stateFor(p);
    _update(t);
    if (t.rect == null) {
      // 不再可滚：清掉可见态（web 的 display none 分支）
      if (t.visible) setState(() => t.visible = false);
      return false;
    }
    _show(t);
    _scheduleHide(t);
    return false;
  }

  /// web `onEnter/onLeave`：指针落在某滚动容器矩形内 ⇒ hovered（悬停期间不淡出）。
  void _onHover(PointerHoverEvent event) {
    if (!_active) return;
    final Offset local = event.localPosition;
    bool changed = false;
    for (final _ThumbState t in _thumbs) {
      final Rect? vp = t.viewport;
      final bool inside = vp != null && vp.contains(local);
      if (inside != t.hovered) {
        t.hovered = inside;
        changed = true;
        if (inside) {
          _update(t);
          if (t.rect != null) _show(t);
        }
      }
      if (t.hovered) _scheduleHide(t);
    }
    if (changed && mounted) setState(() {});
  }

  void _onHoverExit(PointerExitEvent event) {
    if (!_active) return;
    for (final _ThumbState t in _thumbs) {
      if (!t.hovered) continue;
      t.hovered = false;
      _scheduleHide(t);
    }
    if (mounted) setState(() {});
  }

  /// web `pointerdown` + `pointermove`：拾取点偏移 → scrollTop/scrollLeft 实时换算。
  void _onPanStart(_ThumbState t, DragStartDetails details) {
    _dragging = t;
    if (t.vertical) {
      _grabOffset = details.localPosition.dy;
    } else {
      _grabOffset = details.localPosition.dx;
    }
    t.timer?.cancel();
  }

  void _onPanUpdate(_ThumbState t, DragUpdateDetails details) {
    final Rect? r = t.rect;
    if (r == null) return;
    const double pad = AylaOverlayScrollbar.pad;
    final double visual = (t.vertical ? r.height : r.width) - pad * 2;
    final double track = t.position.viewportDimension;
    final double maxOffset = track - visual;
    if (maxOffset <= 0) return;
    final double raw = (t.vertical ? details.localPosition.dy : details.localPosition.dx);
    final double moved = (raw - _grabOffset + pad).clamp(0.0, maxOffset);
    t.position.jumpTo(moved / maxOffset * t.position.maxScrollExtent);
    _update(t);
  }

  void _onPanEnd(_ThumbState t) {
    _dragging = null;
    // web endDrag：按悬停语义重新计时
    _scheduleHide(t);
  }

  /// thumb 自身 hover 只换底色（web `.ov-scrollbar-thumb:hover`）。
  void _setThumbHover(_ThumbState t, bool hovered) {
    if (t.thumbHovered == hovered) return;
    setState(() => t.thumbHovered = hovered);
  }

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final List<Widget> thumbs = <Widget>[
      for (final _ThumbState t in _thumbs)
        if (t.rect != null)
          Positioned(
            left: t.rect!.left,
            top: t.rect!.top,
            width: t.rect!.width,
            height: t.rect!.height,
            child: IgnorePointer(
              // `.is-visible` 才 `pointer-events: auto`
              ignoring: !t.visible,
              child: MouseRegion(
                onEnter: (_) => _setThumbHover(t, true),
                onExit: (_) => _setThumbHover(t, false),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (DragStartDetails e) => _onPanStart(t, e),
                  onPanUpdate: (DragUpdateDetails e) => _onPanUpdate(t, e),
                  onPanEnd: (_) => _onPanEnd(t),
                  onPanCancel: () => _onPanEnd(t),
                  child: AnimatedOpacity(
                    opacity: t.visible ? 1 : 0,
                    duration: reduceMotion
                        ? Duration.zero
                        : AylaOverlayScrollbar.fadeDuration,
                    curve: AylaCurves.easeOut,
                    child: Padding(
                      // `padding: 3px` + `background-clip: content-box` ⇒ 视觉条 4px、四边 3px 透明命中区
                      padding: const EdgeInsets.all(AylaOverlayScrollbar.pad),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: t.thumbHovered
                              ? AylaOverlayScrollbar.thumbHoverColor
                              : AylaOverlayScrollbar.thumbColor,
                          borderRadius: BorderRadius.circular(
                            AylaOverlayScrollbar.thumbRadius,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
    ];

    return MouseRegion(
      onHover: _onHover,
      onExit: _onHoverExit,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: Stack(
          key: _hostKey,
          children: <Widget>[widget.child, ...thumbs],
        ),
      ),
    );
  }
}

// ======================= 预览 =======================

/// 覆盖层滚动条样张（画布与 @Preview 共用；**可交互**：滚动内容或直接拖 thumb）。
///
/// 一档足够：`SizedBox(420×320)` 里放一段可滚列表 —— 滚动时右缘出现 4px 细条、
/// 停 600ms 淡出；指针停在列表上则一直可见（web 的悬停保持）；窄屏舞台（≤768）完全不显示。
Widget aylaOverlayScrollbarSamples() => const _OverlayScrollbarDemo();

class _OverlayScrollbarDemo extends StatelessWidget {
  const _OverlayScrollbarDemo();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 420,
      height: 320,
      child: AylaOverlayScrollbar(
        child: ScrollConfiguration(
          // 桌面端 Scrollable 默认挂 Scrollbar —— 本件是自绘覆盖层条，关掉原生条避免双条
          // （web 侧由 base.css 全局隐藏原生滚动条）
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AylaSpacing.sp3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: AylaSpacing.sp3,
              children: <Widget>[
                for (int i = 1; i <= 24; i++)
                  Text(
                    "第 \${i} 行 · 滚动我，右缘出现覆盖层细条",
                    style: const TextStyle(fontSize: 13),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 覆盖层滚动条（滚动/悬停显示、600ms 淡出、可拖拽、窄屏不显示）。
@Preview(
  group: 'Widgets',
  name: '覆盖层滚动条（OverlayScrollbar：滚动/悬停/拖拽）',
  size: Size(900, 700),
  wrapper: previewTheme,
)
Widget aylaOverlayScrollbarPreview() => aylaOverlayScrollbarSamples();
