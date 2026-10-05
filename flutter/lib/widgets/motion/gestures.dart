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
/// `AylaPanelTransition` · `AylaConversationTransition` · `AylaConversationPresence` ·
/// `AylaFullScreenSwipeBack` · `AylaPrimaryNavPage` · `aylaResolveSwipeCommit` · 各手势常量
library;

import 'dart:async';

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
        // 进场：从 edge 的 ±20 到 0；退场：从 0 到 exitEdge 的 ±20。
        //
        // ⚠️ 2026-09-28 修（既有 bug，19 号 §7.5 第三批 C 类第①条）：
        // 退场原写 `outOff = _offsetFor(out) * v` —— 退场走 `_c.reverse()`，v 由 1 递减，
        // 于是位移从 **±20 滑回 0**（**先瞬跳 ±20 再滑回**，方向与 web 相反）。
        // web `auroraquaMotion.ts:49` 的 exit = `{ ...offset(exitEdge), opacity: 0 }`，
        // 即 center（x 0 / opacity 1）→ exitEdge（x ±20 / opacity 0）⇒ 退场必须乘 **(1 - v)**。
        // 进场与退场现在是同一条「±20 × (1 - v)」：进场 v 0→1、退场 v 1→0。
        final Offset off =
            _offsetFor(widget.show ? widget.edge : out) * (1 - v);
        return Opacity(
          opacity: v,
          child: Transform.translate(offset: off, child: child),
        );
      },
      child: widget.child,
    );
  }
}

/// 会话面板「在场」信号（web `framer-motion` 的 `useIsPresent()`）。
///
/// `AylaConversationTransition` 的 `panels: true` 档是**透明宿主**（web
/// `auroraquaPanelOrchestration` 三个变体全空）—— 进出场由子件自己播；子件需要知道
/// 自己处于「在场」（播进场 / 停在 center）还是「退出中」（播退场）。
///
/// 读取方式：[of]（无宿主时返回 `true` ⇒ 独立使用子件的场合不会误判为退场）。
class AylaConversationPresence extends InheritedWidget {
  const AylaConversationPresence({
    super.key,
    required this.present,
    required super.child,
  });

  /// 是否在场（web `useIsPresent()`）。
  final bool present;

  /// 读最近宿主的在场信号（无宿主 ⇒ `true`）。
  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<AylaConversationPresence>()
          ?.present ??
      true;

  @override
  bool updateShouldNotify(AylaConversationPresence oldWidget) =>
      oldWidget.present != present;
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
    this.panels = true,
    this.childOwnsPanels = false,
  });

  /// 会话身份（web `key={identity}`）。
  final String identity;

  /// 内容构建（按当前 identity）。
  final Widget Function(BuildContext context, String identity) builder;

  /// 面板编排档（web `ConversationTransition.tsx:12` 的 `panels`，默认 true）。
  ///
  /// - `true`：宿主**透明**（web `auroraquaPanelOrchestration` 三个变体全空）——
  ///   只做「旧件退完再挂新件」的编排，自身不位移/不淡入；进出场由子件自己播
  ///   （如 `AylaPrivateChatPane` 的 `panelMotion`）。
  /// - `false`：宿主**自己播** `panelVariants(reduced, "right", "left")`（tsx:50）——
  ///   进场 = 右侧 +20 / opacity 0 → center；退场 = center → 左侧 −20 / opacity 0，
  ///   300ms `easeInOut`；reduced ⇒ 位移 0、时长 0（子件档见 `AylaPanelTransition`）。
  ///
  /// 事实源 = `MessagesPage.tsx:190`：`panels={activeChatId != null}` ⇒ **空会话态**这一档走 false。
  final bool panels;

  /// 子件自己持有进出场（`panels: true` 语义的完整版；web `useIsPresent()` + 子件变体传播）。
  ///
  /// - `false`（默认）：退出中的旧件由**宿主整体淡出**（`FadeTransition(opacity: _c)`）——
  ///   对没接面板动效的子件是兜底；
  /// - `true`：旧件**不整体淡出**，由子件读 [AylaConversationPresence] 后按自己的
  ///   分区变体播退场（web `.private-chat.chat-motion-panels` 的 `auroraquaPanelOrchestration`
  ///   宿主透明、三区各自 exit）。宿主只保留 `IgnorePointer` / `ExcludeSemantics`。
  ///
  /// ⚠️ 传 `true` 就必须让 builder 里的子件真正消费 [AylaConversationPresence]
  /// （如 `AylaPrivateChatPane(panelMotion: true)`），否则旧件会瞬移消失。
  final bool childOwnsPanels;

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

  /// reduced-motion（web `usePrefersReducedMotion`；首帧依赖解析一次）。
  bool _reduced = false;

  bool _depsResolved = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_depsResolved) return;
    _depsResolved = true;
    _reduced = MediaQuery.disableAnimationsOf(context);
    if (_reduced) _c.duration = Duration.zero;
    // panels:false ⇒ 挂载即播进场（web `initial={reduced ? false : "enter"}`，tsx:47）
    if (!widget.panels && !_reduced) {
      _c.value = 0;
      _c.forward();
    }
  }

  /// `panels: false` 档：宿主自己套 `panelVariants(reduced, "right", "left")`（tsx:50）。
  ///
  /// - 进场（`entering`）：+20 / opacity 0 → center（v 0→1）
  /// - 退场：center → −20 / opacity 0（v 1→0）
  /// - reduced：位移 0；进场不淡入（opacity 1）、退场直接 opacity 0（时长 0）
  Widget _wrapHostPanel(Widget child, {required bool entering}) {
    return AnimatedBuilder(
      animation: _c,
      builder: (BuildContext context, Widget? c) {
        final double v = _c.value;
        final double dx = _reduced
            ? 0
            : (entering ? kAylaPanelDistance : -kAylaPanelDistance) * (1 - v);
        return Opacity(
          opacity: _reduced ? (entering ? 1 : 0) : v,
          child: Transform.translate(offset: Offset(dx, 0), child: c),
        );
      },
      child: child,
    );
  }

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
    if (leaving == null) {
      final Widget live = AylaConversationPresence(
        present: true,
        child: active,
      );
      return widget.panels ? live : _wrapHostPanel(live, entering: true);
    }
    final Widget leavingChild = KeyedSubtree(
      key: ValueKey<String>(leaving),
      child: Builder(
        builder: (BuildContext context) => widget.builder(context, leaving),
      ),
    );
    // 退出中的旧件：不在场（web `useIsPresent() == false`）⇒ 子件播退场；
    // 且不可点、语义排除（web `inert` + `aria-hidden` + `pointer-events:none`）。
    final Widget leavingPresent = AylaConversationPresence(
      present: false,
      child: leavingChild,
    );
    return Stack(
      children: <Widget>[
        ExcludeSemantics(
          child: IgnorePointer(
            child: widget.panels
                // panels:true + 子件自持 ⇒ 宿主透明，三区各自 exit（web 语义完整版）
                ? (widget.childOwnsPanels
                    ? leavingPresent
                    // panels:true（子件未接面板动效）⇒ 宿主整体淡出兜底
                    : FadeTransition(opacity: _c, child: leavingPresent))
                // panels:false ⇒ center → 左 −20 + 淡出（tsx:50）
                : _wrapHostPanel(leavingPresent, entering: false),
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
    this.replayKey = '',
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

  /// 方向变体的**重播键**：值变化即从 `enter` 重播入场动画（即使 [direction] 不变）。
  ///
  /// 事实源：web `AppShell.tsx:116` 的 `<PrimaryNavPage key={pathname} direction …>` ——
  /// **每次路由变化都重挂实例**（旧实例由 `AnimatePresence` 保管退场），因此每次切换必播；
  /// 本件是 Flutter 侧的无 key 等价物（壳层不能让外层带 key：`ShellRoute` 的 child 携带
  /// `GlobalObjectKey(navigatorKey.hashCode)`，换 key 会波及 shell navigator 的 Element 复用）。
  ///
  /// 默认空串 = **不启用**（沿用只比较 [direction] 的旧行为，画布样张与既有测试不受影响）；
  /// 壳层传 `pathname` —— 少了它，连续两次同方向切换（快速连滑两次）
  /// 第二次 `old.direction == widget.direction` 而不重播（审查报告 **BUG-2**）。
  final String replayKey;

  @override
  State<AylaPrimaryNavPage> createState() => _AylaPrimaryNavPageState();
}

class _AylaPrimaryNavPageState extends State<AylaPrimaryNavPage>
    with TickerProviderStateMixin {
  /// 方向变体进场（enter → center）= 300ms（web `auroraquaRouteTransition`）。
  ///
  /// ⚠️ 本控制器**只驱动入场动画**（opacity + `direction × 20` 位移）。
  /// 松手回弹**不得复用它** —— 见 [_snap] 的说明。
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: kAylaPanelDuration,
  );

  /// 松手回弹（未提交时 `_raw` → 0）**专用**控制器，200ms。
  ///
  /// ## ⚠️ 为什么必须与 [_c] 分开（用户 2026-10-05 实报）
  /// 早前把回弹也挂在 [_c] 上（`_c..duration = 200ms; ..value = 0; _c.forward()`）：
  /// 而 [build] 里 `v = t.value` 同时驱动 **opacity** 与 **入场位移**
  /// ⇒ 回弹把 `_c` 从 0 推到 1 ⇒ **整页透明度 0→1 + 入场位移 20→0 被重播一遍**。
  /// 用户观感：「滑动未达标准时取消，重新加载了入场动画，不该加载」。
  ///
  /// ⇒ 位移与入场**必须是两条独立时间线**。范本 = 群内页面 `group_page.dart:1151–1165`
  /// 的 `_resetDrag`：`_dragDx` 是纯数值、回弹由**独立的** `TweenAnimationBuilder`（200ms
  /// `--ease-out`）驱动，**完全不碰入场控制器**。
  ///
  /// 曲线用线性（与 [AylaFullScreenSwipeBack] 的既有 200ms 回弹一致；
  /// web 侧 framer 的 `dragSnapToOrigin` 是 spring，此处取同量程近似 —— 已登记）。
  late final AnimationController _snap = AnimationController(
    vsync: this,
    duration: kAylaEdgeSwipeDuration, // 200ms（web `SPRING_BACK_DURATION`）
  );

  /// 原始累计位移（判定用；web `info.offset.x`）。
  double _raw = 0;

  /// 本次回弹的**起点位移**（null = 无回弹在途）。
  ///
  /// 回弹值由控制器曲线直接求值（而不是给控制器挂一个 setState 监听器）：
  /// [build] 的 [AnimatedBuilder] 每帧已监听本控制器 ⇒ 曲线推进即触发重绘，
  /// 松手后**所有中间帧都可观测**（用户此前实报的「跳变回弹」正是因为瞬时归零）。
  double? _snapBackFrom;

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
    // 重播判据 = `direction` 变化 **或** [AylaPrimaryNavPage.replayKey] 变化。
    // 只看 direction 会漏掉「连续两次同方向切换」（快速连滑两次，审查 BUG-2）；
    // 壳层传 `replayKey: pathname` 覆盖该情形，未传时行为与旧实现一致。
    if (old.direction != widget.direction || old.replayKey != widget.replayKey) {
      // ① 在途回弹让位给换页转场（web `useMotionDrag.ts:33–43`：路由离场时
      //    `offset.stop()`，不再继续 snap-back）—— 两条时间线各自停，互不影响；
      // ② 入场动画从 0 重播（`_c` 时长恒为 [kAylaPanelDuration]，回弹不再改它）。
      _snap.stop();
      _snapBackFrom = null;
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    // 两条独立时间线各自释放（见 [_snap]）。
    _c.dispose();
    _snap.dispose();
    super.dispose();
  }

  /// 起手：停掉在途回弹，并把跟手基准对齐到**当前显示位置**。
  ///
  /// 事实源：web `useMotionDrag.ts:52–57` —— 「a new pointer down stops this animation
  /// through Framer's own drag owner before taking over the same motion value」，
  /// 即再次按下时从回弹的当前帧继续，而不是跳回松手位置。
  void _onStart(DragStartDetails d) {
    final double? from = _snapBackFrom;
    if (from == null) return;
    final double shown = from * (1 - _snap.value); // 回弹当前**原始**量
    _snap.stop();
    setState(() {
      _raw = shown;
      _snapBackFrom = null;
    });
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
    // ---- 回弹（web `dragConstraints {0,0}` + `dragSnapToOrigin` 的 spring 回弹）----
    //
    // ⚠️ **必须是 200ms 动画，不能瞬时归零**（审查 BUG-1）：早前写的是
    // `setState(() => _raw = 0)` ⇒ 渲染位移 `dragElastic × _raw` 在松手那一帧直接塌回 0，
    // 观感就是「跳变回弹」—— 用户在 group_page 反复实报过同一现象
    // （`group_page.dart:1027` 注释：「此前直接 `Transform.translate(_dragDx)` 且松手瞬时
    //   归零 ⇒ 未过阈值时**跳变**」）。页面侧当时已按同法修好（200ms），本件漏修。
    //
    // 范式照抄同文件 [AylaFullScreenSwipeBack] 的 `_onEnd`（`gestures.dart:504–512`）：
    // **冻结起点 → 控制器 200ms 走完 → 归零**；显示位移 = 曲线值 × [kAylaDragElastic]
    // （与跟手层同源，回弹量不额外打折）。
    if (commit == 0) {
      // ⚠️ 用**独立的** [_snap]（不是 [_c]）：复用入场控制器会把整页的
      //    opacity 与入场位移一起重播（用户 2026-10-05 实报「取消时重新加载了入场动画」）。
      _snapBackFrom = _raw;
      _snap
        ..stop()
        ..value = 0;
      // 冻结起点后立刻 setState：让 build 走 `snappingFrom != null` 分支
      // （否则本帧仍按 `_dx` 画，等于没冻结）。
      setState(() {});
      unawaited(
        _snap.forward().whenComplete(() {
          // ⚠️ **两个字段一起清**：只清 `_snapBackFrom` 会让下一次 build 回落到
          // `_dx = _raw × 弹性`（= 松手值）⇒ 归零的瞬间又跳回起点（实测踩到）。
          if (mounted) {
            setState(() {
              _raw = 0;
              _snapBackFrom = null;
            });
          }
        }),
      );
      return;
    }

    // ---- 提交：位移交位给换页转场 ----
    // 新页（= 本 State 的新 child，`ShellRoute` 复用同一 Element）必须**从 0 起**，
    // 否则 held offset 会把新页也推离中心。web 侧由「每次路由变化重挂一个实例」
    // （`AppShell.tsx:116` 的 `key={pathname}`：旧实例保留 held offset 淡出、新实例从 0 起）
    // 天然成立，Flutter 侧只有一个 State ⇒ 必须在换页那一刻归零（登记为结构差异）。
    setState(() {
      _raw = 0;
      _snapBackFrom = null;
    });
    // web 原样交付：`+1` = **下一项**（手指左滑 / 上滑），`-1` = 上一项
    widget.onNavigate?.call(commit);
  }

  @override
  Widget build(BuildContext context) {
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    final bool on = widget.enabled && !reduced;
    final Animation<double> t = CurvedAnimation(
      parent: _c,
      curve: AylaCurves.auroraquaEaseInOut,
    );
    // ⚠️ **两个控制器一起监听**：`_c` 驱动入场（opacity + direction 位移）、
    // [_snap] 驱动松手回弹（纯位移）。两者是**独立时间线**（见 [_snap] 的说明）。
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[t, _snap]),
      builder: (BuildContext context, Widget? child) {
        final double v = reduced ? 1 : t.value;
        // directionalVariants：enter = +direction*20 → 0（退出由上一层宿主负责）
        final double dx = widget.direction * kAylaPanelDistance * (1 - v);
        // 回弹期的显示位移：起点冻结在松手位移上，沿**专用回弹控制器** [_snap]
        // （200ms）走到 0 —— **不读 `_c`**，否则会把入场动画一起重播。
        //
        // ⚠️ **必须写在 builder 内**（每帧求值）：写在 `build` 里只会算一次，
        // 于是「回弹」看起来仍是停住不动（实测：半程位移恒为松手值）。
        final double? snappingFrom = _snapBackFrom;
        final double dragDx = snappingFrom == null
            ? _dx
            : snappingFrom * kAylaDragElastic * (1 - _snap.value);
        return Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(dx + (on ? dragDx : 0), 0),
            child: child,
          ),
        );
      },
      child: on
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: _onStart,
              onHorizontalDragUpdate: _onUpdate,
              onHorizontalDragEnd: _onEnd,
              child: widget.child,
            )
          : widget.child,
    );
  }
}
