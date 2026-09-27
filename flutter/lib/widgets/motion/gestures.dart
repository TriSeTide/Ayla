/// 手势与转场族（web `components/motion/`：`ConversationTransition.tsx` 55 行 ·
/// `FullScreenSwipeBack.tsx` 45 行 · `PrimaryNavPage.tsx` 110 行 + `auroraquaMotion.ts` panel 段 +
/// `hooks/useSwipeCommit.ts` / `useEdgeSwipeBack.ts` / `useTouchAxisGuard.ts` / `useMotionDrag.ts`）。
///
/// ## 事实源（常量逐条取自 web）
/// ```
/// auroraquaMotion.ts 11–19   distance 20 · fadeScale .95 · duration 0.3s · easeInOut [.42,0,.58,1]
/// auroraquaMotion.ts 37–51   panelVariants(reduced, edge, exitEdge)：enter = 该边 ±20 + opacity 0 →
///                            center 0/1（300ms easeInOut）→ exit = exitEdge ±20 + opacity 0
/// auroraquaMotion.ts 54–68   directionalVariants(reduced, axis)：enter = +direction*20、
///                            exit = −direction*20（**选项卡横滑用**）
/// ConversationTransition     `AnimatePresence mode="wait"`：**旧 owner 播完退出才挂新 owner**，
///                            快速切换不挂中间态；退出期间 `inert` + `aria-hidden` + `pointer-events:none`；
///                            包装层**不画第二个面**（透明编排 auroraquaPanelOrchestration）
/// useSwipeCommit.ts 32–36    SWIPE_FLICK_VELOCITY = 300（px/s）· SWIPE_MIN_FLICK_DISTANCE = 40（px）·
///                            判定：净位移 ≥ size/3 优先 → 同向甩动补充 → 方向锁让位（跨轴占优 ⇒ 不判定）
/// useEdgeSwipeBack.ts        exitThreshold **120px** · flickVelocity **0.3 px/ms（=300px/s）** ·
///                            lockSlop 12 · 退出/回弹各 **200ms** ease-out `[.22,.61,.36,1]`
/// useTouchAxisGuard.ts 26    AXIS_GUARD_SLOP = 6px（小于浏览器手势 slop，抢在接管前定轴）
/// PrimaryNavPage.tsx 27–30   dragConstraints {0,0} · DRAG_ELASTIC = 0.8（80% 跟手 + 边缘阻尼）
/// ```
///
/// ## 机制差异（登记）
/// - **方向锁**：web 用 `touch-action: pan-y` + non-passive touchmove 抢定轴（axis guard）；
///   Flutter 的 `GestureDetector.onHorizontalDrag*` 走**手势竞技场**，纵向滚动胜出时横向回调根本
///   不触发 ⇒ 天然等价「垂直优先」，不需要手写 slop 守卫（[kAylaAxisGuardSlop] 仅作常量登记）。
/// - **弹性阻尼**：framer-motion 的 `dragElastic .8` ⇒ Flutter 侧按 `跟随量 = 位移 × 0.8` 实现。
/// - **`mode="wait"` 宿主**：Flutter 无 AnimatePresence ⇒ [AylaConversationTransition] 自己
///   在新旧之间串行（旧件先播 300ms 退出，再挂新件），快速连切只保留最后一次请求的件。
///
/// ## 公开面
/// `AylaPanelTransition` · `AylaConversationTransition` · `AylaFullScreenSwipeBack` ·
/// `AylaPrimaryNavPage` · `aylaResolveSwipeCommit` · 各手势常量
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// 甩动速度阈值（web `SWIPE_FLICK_VELOCITY`，px/s）。
const double kAylaSwipeFlickVelocity = 300;

/// 甩动最小位移（web `SWIPE_MIN_FLICK_DISTANCE`，px）。
const double kAylaSwipeMinFlickDistance = 40;

/// 全屏右滑返回的位移阈值（web `exitThreshold` 默认，px）。
const double kAylaEdgeSwipeExitThreshold = 120;

/// 全屏右滑返回的甩动速度阈值（web `flickVelocity`，px/s）。
const double kAylaEdgeSwipeFlickVelocity = 300;

/// 定轴起步位移（web `AXIS_GUARD_SLOP`，px；Flutter 走手势竞技场，仅登记不参与运行时）。
const double kAylaAxisGuardSlop = 6;

/// 拖拽跟手弹性（web `DRAG_ELASTIC`）。
const double kAylaDragElastic = 0.8;

/// 面板位移量（web `AURORAQUA_MOTION.distance`）。
const double kAylaPanelDistance = 20;

/// 面板转场时长（web `duration` = 0.3s）。
const Duration kAylaPanelDuration = Duration(milliseconds: 300);

/// 边缘返回的退出/回弹时长（web `EXIT_DURATION` / `SPRING_BACK_DURATION` = 0.2s）。
const Duration kAylaEdgeSwipeDuration = Duration(milliseconds: 200);

/// 手势边缘枚举（web `PanelEdge`）。
enum AylaPanelEdge { left, right, top, bottom }

/// 松手判定（web `useSwipeCommit.ts:66–89` **逐行对齐**）。
///
/// ```
/// if (|cross| >= |net|) return 0;                 // 方向锁让位（含相等）
/// forward = net < 0;                              // **x 左滑 / y 上滑 → next**
/// if (|net| >= threshold ?? size/3) return forward ? 1 : -1;   // 慢拖到位也切，不看速度
/// if (|net| >= 40 && |velocity| >= 300 && sign(velocity) === sign(net))
///   return forward ? 1 : -1;                      // 同向甩动补充
/// return 0;
/// ```
/// ⚠️ 我此前把符号写成 `net > 0 ? 1 : -1`（臆断），导致「切换选项卡」落点整体反了；
/// **web 本来就和用户规则一致**（左滑 = 下一项），不存在偏离。
int aylaResolveSwipeCommit({
  required double net,
  required double cross,
  required double velocity,
  required double size,
  double? threshold,
}) {
  // 方向锁让位：交叉轴净位移**占优或相等** ⇒ 不判定
  if (cross.abs() >= net.abs()) return 0;

  // web：`forward = net < 0`（x 左滑 / y 上滑 → next）
  final bool forward = net < 0;
  final double distance = net.abs();
  if (distance >= (threshold ?? size / 3)) return forward ? 1 : -1;

  // 同向甩动补充：速度达标 + 有意义的最小位移 + **方向一致**
  if (distance >= kAylaSwipeMinFlickDistance &&
      velocity.abs() >= kAylaSwipeFlickVelocity &&
      velocity.sign == net.sign) {
    return forward ? 1 : -1;
  }
  return 0;
}

/// 面板转场（web `panelVariants`）：从 [edge] 进、向 [exitEdge] 出（各 ±20 + 透明度，300ms easeInOut）。
///
/// [show] 由调用方驱动：true ⇒ 进场；false ⇒ 退场（播完由调用方卸载）。
class AylaPanelTransition extends StatefulWidget {
  const AylaPanelTransition({
    super.key,
    required this.child,
    this.edge = AylaPanelEdge.right,
    this.exitEdge,
    this.show = true,
    this.animateOnMount = true,
  });

  /// 页面内容。
  final Widget child;

  /// 进场边。
  final AylaPanelEdge edge;

  /// 退场边（默认与 [edge] 同边，web 默认参数）。
  final AylaPanelEdge? exitEdge;

  /// 显示（false ⇒ 播退出动画）。
  final bool show;

  /// 挂载时是否播进场（web：`initial="enter"`）。
  final bool animateOnMount;

  @override
  State<AylaPanelTransition> createState() => _AylaPanelTransitionState();
}

class _AylaPanelTransitionState extends State<AylaPanelTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: kAylaPanelDuration,
  );

  @override
  void initState() {
    super.initState();
    _c.value = widget.show ? 1 : 0;
    if (widget.show && widget.animateOnMount) {
      _c.value = 0;
      _c.forward();
    }
  }

  @override
  void didUpdateWidget(AylaPanelTransition old) {
    super.didUpdateWidget(old);
    if (old.show == widget.show) return;
    if (widget.show) {
      _c.forward(from: 0);
    } else {
      _c.reverse();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Offset _offsetFor(AylaPanelEdge edge) => switch (edge) {
    AylaPanelEdge.left => const Offset(-kAylaPanelDistance, 0),
    AylaPanelEdge.right => const Offset(kAylaPanelDistance, 0),
    AylaPanelEdge.top => const Offset(0, -kAylaPanelDistance),
    AylaPanelEdge.bottom => const Offset(0, kAylaPanelDistance),
  };

  @override
  Widget build(BuildContext context) {
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    final AylaPanelEdge out = widget.exitEdge ?? widget.edge;
    final Animation<double> t = CurvedAnimation(
      parent: _c,
      curve: AylaCurves.auroraquaEaseInOut,
    );
    return AnimatedBuilder(
      animation: t,
      builder: (BuildContext context, Widget? child) {
        final double v = reduced ? (widget.show ? 1 : 0) : t.value;
        // 进场：从 edge 的 ±20 到 0；退场：从 0 到 exitEdge 的 ±20
        final Offset inOff = _offsetFor(widget.edge) * (1 - v);
        final Offset outOff = _offsetFor(out) * v;
        final Offset off = widget.show ? inOff : outOff;
        return Opacity(
          opacity: v,
          child: Transform.translate(offset: off, child: child),
        );
      },
      child: widget.child,
    );
  }
}

/// 会话转场宿主（web `ConversationTransition`，`AnimatePresence mode="wait"` 等价物）。
///
/// [identity] 变化：**旧件先播 300ms 退出**（期间不可点、语义排除），**播完才挂新件**；
/// 快速连续切换只保留最后一次请求的 identity（中间态不挂载）。
class AylaConversationTransition extends StatefulWidget {
  const AylaConversationTransition({
    super.key,
    required this.identity,
    required this.builder,
  });

  /// 会话身份（web `key={identity}`）。
  final String identity;

  /// 内容构建（按当前 identity）。
  final Widget Function(BuildContext context, String identity) builder;

  @override
  State<AylaConversationTransition> createState() =>
      _AylaConversationTransitionState();
}

class _AylaConversationTransitionState extends State<AylaConversationTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: kAylaPanelDuration,
    value: 1,
  );

  /// 正在退出的旧 identity（null ⇒ 无）。
  String? _leaving;

  /// 当前挂载的 identity。
  late String _current = widget.identity;

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((AnimationStatus s) {
      if (s == AnimationStatus.dismissed && mounted) {
        setState(() {
          _current = widget.identity; // 旧件播完 ⇒ 挂最新请求的件
          _leaving = null;
        });
        _c.forward(from: 0);
      }
    });
  }

  @override
  void didUpdateWidget(AylaConversationTransition old) {
    super.didUpdateWidget(old);
    if (old.identity == widget.identity) return;
    if (_leaving == null) {
      _leaving = _current;
      _c.reverse(); // mode="wait"：旧件先退，退完再挂新件
    }
    // 已在退出中 ⇒ 只更新 widget.identity（status listener 会挂最新那个 ⇒ 中间态不挂载）
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget active = KeyedSubtree(
      key: ValueKey<String>(_current),
      child: Builder(
        builder: (BuildContext context) => widget.builder(context, _current),
      ),
    );
    final String? leaving = _leaving;
    if (leaving == null) return active;
    // 退出中的旧件：不可点、语义排除（web `inert` + `aria-hidden` + `pointer-events:none`）
    return Stack(
      children: <Widget>[
        ExcludeSemantics(
          child: IgnorePointer(
            child: FadeTransition(
              opacity: _c,
              child: KeyedSubtree(
                key: ValueKey<String>(leaving),
                child: Builder(
                  builder: (BuildContext context) =>
                      widget.builder(context, leaving),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 全屏右滑返回（web `FullScreenSwipeBack` / `useEdgeSwipeBack from:'full'`）。
///
/// 跟手 1:1 右移；松手 `dx ≥ 120px` 或速度 `≥ 300px/s` ⇒ 播 200ms 退出后 [onBack]，
/// 否则 200ms 回弹。纵向滚动优先（Flutter 手势竞技场天然让位）。
class AylaFullScreenSwipeBack extends StatefulWidget {
  const AylaFullScreenSwipeBack({
    super.key,
    required this.child,
    this.onBack,
    this.enabled = true,
  });

  /// 内容（由调用方撑满）。
  final Widget child;

  /// 返回回调（过阈值 / 快速滑后调用）。
  final VoidCallback? onBack;

  /// 是否启用手势（窄屏才启用；群内场景传 false）。
  final bool enabled;

  @override
  State<AylaFullScreenSwipeBack> createState() =>
      _AylaFullScreenSwipeBackState();
}

class _AylaFullScreenSwipeBackState extends State<AylaFullScreenSwipeBack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: kAylaEdgeSwipeDuration,
  );

  /// 当前横向位移（跟手量）。
  double _dx = 0;

  /// 本次手势的速度（px/s，用最近一次 update 的时间差估算）。
  double _velocity = 0;
  Duration _lastTime = Duration.zero;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _onStart(DragStartDetails d) {
    _c.stop();
    _lastTime = Duration.zero;
    _velocity = 0;
  }

  void _onUpdate(DragUpdateDetails d) {
    // 只允许向右（返回方向）；向左不跟手（web：`dx > 0`）
    final double next = (_dx + d.delta.dx).clamp(0.0, double.infinity);
    final Duration now = d.sourceTimeStamp ?? Duration.zero;
    if (_lastTime != Duration.zero) {
      final double ms = (now - _lastTime).inMicroseconds / 1000.0;
      if (ms > 0) _velocity = d.delta.dx / ms * 1000; // px/s
    }
    _lastTime = now;
    setState(() => _dx = next);
  }

  Future<void> _onEnd(DragEndDetails d) async {
    final double width = context.size?.width ?? 375;
    final double v = d.velocity.pixelsPerSecond.dx.abs() > _velocity.abs()
        ? d.velocity.pixelsPerSecond.dx
        : _velocity;
    final bool commit =
        _dx > 0 &&
        (_dx >= kAylaEdgeSwipeExitThreshold ||
            v >= kAylaEdgeSwipeFlickVelocity);
    if (commit) {
      // 上层滑出右屏（200ms ease-out）后 onBack
      final double target = width;
      final Tween<double> tween = Tween<double>(begin: _dx, end: target);
      _c
        ..reset()
        ..addListener(() => setState(() => _dx = tween.evaluate(_c)));
      await _c.forward();
      widget.onBack?.call();
      if (mounted) setState(() => _dx = 0);
    } else {
      // 回弹（200ms）
      final Tween<double> tween = Tween<double>(begin: _dx, end: 0);
      _c
        ..reset()
        ..addListener(() => setState(() => _dx = tween.evaluate(_c)));
      await _c.forward();
      if (mounted) setState(() => _dx = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    final bool on = widget.enabled && !reduced;
    final Widget content = Transform.translate(
      offset: Offset(_dx, 0),
      child: widget.child,
    );
    if (!on) return content;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: _onStart,
      onHorizontalDragUpdate: _onUpdate,
      onHorizontalDragEnd: _onEnd,
      child: content,
    );
  }
}

/// 一级页横滑转场（web `PrimaryNavPage`）：`drag="x"` + 弹性 .8 + 松手判定 + 方向相关进出动画。
///
/// [direction]（1 / -1 / 0）由调用方按一级 tab 顺序索引差给出；0 ⇒ 只淡入淡出（无横向位移）。
class AylaPrimaryNavPage extends StatefulWidget {
  const AylaPrimaryNavPage({
    super.key,
    required this.child,
    this.direction = 0,
    this.onNavigate,
    this.enabled = true,
  });

  /// 页面内容。
  final Widget child;

  /// 本次切换方向（1 右→左、-1 左→右、0 无方向）。
  final int direction;

  /// 松手判定通过后请求切页：`+1` = **下一项**、`-1` = 上一项。
  ///
  /// 与 web 完全一致（`resolveSwipeCommit` 的 `forward = net < 0`）：
  /// **手指左滑 ⇒ 下一项**、右滑 ⇒ 上一项；调用方按 `(idx + step + len) % len` 落页（web 同）。
  final ValueChanged<int>? onNavigate;

  /// 是否启用横滑（reduced-motion 关）。
  final bool enabled;

  @override
  State<AylaPrimaryNavPage> createState() => _AylaPrimaryNavPageState();
}

class _AylaPrimaryNavPageState extends State<AylaPrimaryNavPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: kAylaPanelDuration,
  );

  /// 原始累计位移（判定用；web `info.offset.x`）。
  double _raw = 0;

  /// 跟手显示位移 = 原始位移 × 弹性（web `dragElastic .8`）。
  double get _dx => _raw * kAylaDragElastic;

  @override
  void initState() {
    super.initState();
    _c.value = 1;
    if (widget.direction != 0) {
      _c.value = 0;
      _c.forward();
    }
  }

  @override
  void didUpdateWidget(AylaPrimaryNavPage old) {
    super.didUpdateWidget(old);
    if (old.direction != widget.direction) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _onUpdate(DragUpdateDetails d) {
    // ⚠️ 弹性**只能作用在显示量上**：早前写成 `_dx = (_dx + delta) * 0.8` ⇒ 每帧把累计量乘 0.8，
    //    位移指数衰减、几帧就归零，实测表现就是「切换选项卡划不动」（用户实测指出）。
    setState(() => _raw += d.delta.dx);
  }

  void _onEnd(DragEndDetails d) {
    final double width = context.size?.width ?? 375;
    final int commit = aylaResolveSwipeCommit(
      net: _raw, // 判定用**原始**位移（web 同：`info.offset.x`）；+1 = 手指右移
      cross: 0, // 纵向由手势竞技场让位，这里只剩横向
      velocity: d.velocity.pixelsPerSecond.dx,
      size: width,
    );
    setState(() => _raw = 0); // 回弹（dragConstraints {0,0}）
    // web 原样交付：`+1` = **下一项**（手指左滑 / 上滑），`-1` = 上一项
    if (commit != 0) widget.onNavigate?.call(commit);
  }

  @override
  Widget build(BuildContext context) {
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    final bool on = widget.enabled && !reduced;
    final Animation<double> t = CurvedAnimation(
      parent: _c,
      curve: AylaCurves.auroraquaEaseInOut,
    );
    return AnimatedBuilder(
      animation: t,
      builder: (BuildContext context, Widget? child) {
        final double v = reduced ? 1 : t.value;
        // directionalVariants：enter = +direction*20 → 0（退出由上一层宿主负责）
        final double dx = widget.direction * kAylaPanelDistance * (1 - v);
        return Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(dx + (on ? _dx : 0), 0),
            child: child,
          ),
        );
      },
      child: on
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: _onUpdate,
              onHorizontalDragEnd: _onEnd,
              child: widget.child,
            )
          : widget.child,
    );
  }
}
