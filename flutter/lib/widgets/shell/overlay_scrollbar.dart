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
///   的换算）；
/// - **页面滚动重算**：web 在 document 级 scroll 回调里对**全部**活跃容器重算（tsx 229–234），
///   因为容器会随页面滚动在视口里整体位移；Flutter 的滚动通知只从各自 Scrollable 冒泡 ⇒
///   收到任一滚动通知时，对**其余**活跃容器一并重算（`_onScroll`）；
/// - **失效容器回收**：web 用 MutationObserver + `pruneDetachedOwners`（tsx 89–94）清掉已从
///   文档移除的容器；Flutter 在每次滚动时检查滚动容器的 `ScrollContext` 是否仍挂载
///   （`_pruneDetached`），否则失效的 `ScrollPosition` 会在下一次重算时被访问并留下幽灵条。
/// ⚠️ 因此**不是** web 的「挂一次即可」：页面层要把它包在应用根（`AylaOverlayScrollbar(child: app)`）。
library;

import 'dart:async';

import 'package:flutter/gestures.dart' show PointerExitEvent, PointerHoverEvent;
import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

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

  /// 抓起那一刻的**视觉条起点**（web 的换算基准：`top = 抓取时的条位置 + 指针位移`）。
  double _grabBarTop = 0;

  /// 是否已排帧后几何重算（去重，避免同一帧重复排队）。
  bool _recomputeQueued = false;

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

  /// web `update(el)`；返回几何是否变化（供「重算其余容器」决定是否重绘）。
  bool _update(_ThumbState t) {
    final Rect? before = t.rect;
    _updateGeometry(t);
    return t.rect != before;
  }

  /// web `update(el)`（tsx 154–198）：重算几何（不可滚 ⇒ 收起并不参与悬停）。
  void _updateGeometry(_ThumbState t) {
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

  /// 该 thumb 的滚动容器是否仍在树上（web `pruneDetachedOwners` 的判据）。
  ///
  /// ⚠️ 不能直接读 `storageContext` 判断：`ScrollableState` 卸载后 `State.context` getter 会抛
  /// 「This widget has been unmounted…」（实测）；`State.mounted` 不碰 context，是安全的判据。
  bool _attached(_ThumbState t) {
    // 声明成 Object 才能让 `is State` 触发类型提升（ScrollContext 与 State 无子类型关系）
    final Object ctx = t.position.context;
    return ctx is! State || ctx.mounted;
  }

  /// web `pruneDetachedOwners`（tsx 89–94）：清掉已从树上移除的容器持有的 thumb。
  ///
  /// 返回是否真的清掉了东西（决定是否需要重绘）。不清的话会留下永不消失的幽灵条，
  /// 且下一次重算会去访问已经失效的 `ScrollPosition`。
  bool _pruneDetached() {
    final List<_ThumbState> dead = <_ThumbState>[
      for (final _ThumbState t in _thumbs)
        if (!_attached(t)) t,
    ];
    for (final _ThumbState t in dead) {
      t.timer?.cancel();
      if (identical(_dragging, t)) _dragging = null;
      _thumbs.remove(t);
    }
    return dead.isNotEmpty;
  }

  /// 帧后重算**全部** thumb 的几何。
  ///
  /// 滚动通知发生在 layout 之前 ⇒ 通知里读到的 render 变换是上一帧的（容器随祖先滚动的
  /// 位移尚未生效）。帧后回调跑在 layout/paint 之后，几何才是本帧真实值；有变化再排一帧重绘。
  /// 对齐 web：web 在 document 级 scroll 回调里同步 `getBoundingClientRect()`，无此延迟。
  void _scheduleRecomputeAll() {
    if (_recomputeQueued) return;
    _recomputeQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _recomputeQueued = false;
      if (!mounted) return;
      bool changed = _pruneDetached();
      for (final _ThumbState t in _thumbs) {
        if (_update(t)) changed = true;
      }
      if (changed) setState(() {});
    });
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
    final bool pruned = _pruneDetached();
    final _ThumbState t = _stateFor(p);
    // 自身几何也要重绘：只在「首次可见」时 setState 会让滚动中的条停在原地
    final bool self = _update(t);
    // web 229–234：滚动会整体改变**其它**容器在视口中的位置（web 在 document 级 scroll 里
    // 对全部活跃容器重算）⇒ 存在其它活跃容器时排一次帧后重算。
    // ⚠️ 不能就地重算：滚动通知早于本帧 layout（viewport 的 paintOffset 要等本帧 layout 才
    //    更新），此刻读到的 render 变换还是上一帧的 ⇒ 内层条会原地不动。
    bool others = false;
    for (final _ThumbState other in _thumbs) {
      if (identical(other.position, p)) continue;
      others = true;
    }
    if (others) _scheduleRecomputeAll();
    final bool dirty = pruned || self || others;
    if (t.rect == null) {
      // 不再可滚：清掉可见态（web 的 display none 分支）
      if (t.visible) {
        setState(() => t.visible = false);
      } else if (dirty) {
        setState(() {});
      }
      return false;
    }
    _show(t);
    _scheduleHide(t);
    if (dirty) setState(() {});
    return false;
  }

  /// web `onEnter/onLeave`：指针落在某滚动容器矩形内 ⇒ hovered（悬停期间不淡出）。
  void _onHover(PointerHoverEvent event) {
    if (!_active) return;
    final bool pruned = _pruneDetached();
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
    if ((changed || pruned) && mounted) setState(() {});
  }

  void _onHoverExit(PointerExitEvent event) {
    if (!_active) return;
    _pruneDetached();
    for (final _ThumbState t in _thumbs) {
      if (!t.hovered) continue;
      t.hovered = false;
      _scheduleHide(t);
    }
    if (mounted) setState(() {});
  }

  /// web `pointerdown` + `pointermove`：拾取点偏移 → scrollTop/scrollLeft 实时换算。
  void _onPanStart(_ThumbState t, DragStartDetails details) {
    if (!_attached(t)) {
      // 容器已卸载：丢弃这条幽灵条，别去碰失效的 ScrollPosition
      _pruneDetached();
      if (mounted) setState(() {});
      return;
    }
    _dragging = t;
    final Rect? r = t.rect;
    // 换算基准 = 抓起那一刻的视觉条起点（web 用 `thumb.getBoundingClientRect()` 现场取值）
    _grabBarTop = r == null
        ? 0
        : (t.vertical ? r.top : r.left) + AylaOverlayScrollbar.pad;
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
    if (!_attached(t)) {
      _dragging = null;
      _pruneDetached();
      if (mounted) setState(() {});
      return;
    }
    const double pad = AylaOverlayScrollbar.pad;
    final double visual = (t.vertical ? r.height : r.width) - pad * 2;
    final double track = t.position.viewportDimension;
    final double maxOffset = track - visual;
    if (maxOffset <= 0) return;
    final double raw = (t.vertical ? details.localPosition.dy : details.localPosition.dx);
    // web tsx 132/138：`top = 抓取时的条起点 + 指针位移`，再夹到 [0, maxTop]。
    // ⚠️ 位移是 `localPosition − 抓取点`（两者同属按下时的局部坐标系 ⇒ 纯位移）；
    // 曾经漏掉「抓取时的条起点」这一项，退化成 `位移 + PAD` ⇒ 一拖就从轨道起点重新算，
    // 表现为「抓着中间的条一拖就跳到顶部附近」（2026-09-25 由 overlay_scrollbar_test 实测抓出）。
    final double moved = (_grabBarTop + (raw - _grabOffset)).clamp(0.0, maxOffset);
    t.position.jumpTo(moved / maxOffset * t.position.maxScrollExtent);
    _update(t);
  }

  void _onPanEnd(_ThumbState t) {
    _dragging = null;
    if (!_attached(t)) {
      _pruneDetached();
      return;
    }
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
            // ⚠️ 必须按容器绑定 Element：同一 Stack 里多个 thumb 时，无 key 会按**索引**复用元素，
            // 把一个容器的显隐/悬停状态串到另一个容器上（尤其某条被回收之后）。
            key: ValueKey<Object>(t.position),
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

// ======================= 样张 =======================

/// 覆盖层滚动条样张（**可交互**：滚动内容，或直接拖右缘的细条）。
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
                  Text('示例行 $i', style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
