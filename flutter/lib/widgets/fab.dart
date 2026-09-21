/// 右下角浮层按钮族（`layout/CornerFabStack.tsx` / `RefreshFab.tsx` /
/// `ScrollTopFab.tsx` / `QuickMessageFab.tsx` + `shell.css` 423–456 / 679–787）。
///
/// ## 事实源（逐条对应 web，禁自由发挥）
/// ```
/// .corner-fab-stack  shell.css:684–694  fixed; right: calc(32px + (56-44)/2) = 38px;
///                   bottom: calc(32px + 56px + sp3) = 100px; z-index: 40;
///                   flex column / align-items: flex-end / gap: sp3 = 12px;
///                   pointer-events: none（子项 auto）
/// .corner-fab        shell.css:697–720  44×44 / 1px --glass-border / radius-pill /
///                   --glass-bg / blur(18px) saturate(1.4) / --card-shadow；
///                   hover → --glass-bg-strong + 0 2px 12px rgba(70,91,146,.18)
/// .corner-fab-icon   shell.css:742–746  inline-flex 居中（旋转宿主）
/// .is-spinning       shell.css:748–750  animation: ayla-loading-spin 800ms linear infinite
/// .is-bottom-left    shell.css:753–758  fixed left 32 / bottom 32 / z 40
/// .corner-fab-scroll-top     723–739    opacity 0 / visibility hidden / translateY(8px)
/// .is-visible                732–739    opacity 1 / visible / translateY(0)
/// .is-narrow                 762–767    fixed right 16 / bottom calc(64px + safe + sp3)
/// .is-narrow.is-stacked      769–773    right calc(16 + (56-44)/2) = 22px /
///                                       bottom 64 + safe + sp3 + 56 + sp3 = 144 + safe
/// .message-fab       shell.css:423–439  56×56 / left 16 / bottom calc(64px + safe + 12px) /
///                   --glass-bg + blur18 sat1.4 —— 外观由 AylaMessageFab 承载
/// .quick-message-fab         442–450    transition: transform 200ms --ease-out；
///                                       .is-collapsed → translateX(-44px)（仅露 28px 右半）
/// reduced-motion     shell.css:775–787 / auroraqua.css:655–680
///                   scroll-top 只留 opacity（transform: none）、spinning animation: none、
///                   按钮组 hover/active 缩放取消
/// ```
///
/// ## 层叠（易错，已逐条确认）
/// `auroraqua.css:54–94` 把 `.create-fab` / `.message-fab` / `.corner-fab` 一并纳入按钮组：
/// `transition` 全组 **200ms `--auroraqua-ease`** + `:hover { scale: 1.02 }` +
/// `:active { scale: .98 }`。它与 `shell.css` 的 `.corner-fab { transition: … var(--dur-fast) }`
/// **特异性相同（0,1,0）而 auroraqua 后加载** ⇒ 实际是 **200ms**，不是 180ms。
/// Flutter 侧即 [AylaDurations.button] + [AylaCurves.auroraqua]（缩放由 [AylaPressScale] 提供）。
///
/// ## 与 web 的装配差异（组件不写页面）
/// web 的 `CornerFabStack` 只接收两个 bool，子件通过 `useShellStore`（refreshCallback /
/// quickMessagesOpen）与 document 级 scroll 监听自取数据。Flutter 侧没有全局 store，
/// 按既有「展示型 + 注入」模式改为**参数注入**：
/// - 刷新回调 → [AylaRefreshFab.onRefresh]（null = web 的「无回调」：按钮外观与交互照常，
///   点击无动作 —— **不是** disabled）；
/// - 滚动容器 → [AylaScrollTopFab.controller]（页面层注入），缺省回退「最近祖先 Scrollable」
///   （web 用 document capture 监听任意滚动容器；Flutter 无全局 scroll 事件，二者取并集
///   覆盖两种装配）；
/// - 路由切换重置 → Flutter 无 `pathname`：页面层用 `ValueKey(path)` 重建本组件即可
///   （等价 tsx 里 `useEffect([pathname])` 的清引用 + 隐藏）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../theme/app_icons.dart';
import '../theme/buttons.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'tab_badge.dart';

/// `.corner-fab-refresh` 的定位档（web `position?: "corner" | "bottom-left"`）。
enum AylaRefreshFabPosition {
  /// 由 [AylaCornerFabStack] 容器承载定位（右下堆叠）。
  corner,

  /// `.is-bottom-left`：宽屏私信列表独立放左下角（`left: 32px; bottom: 32px`）。
  bottomLeft,
}

/// `.corner-fab-scroll-top` 的定位档（web `position?: "corner" | "narrow"`）。
enum AylaScrollTopFabPosition {
  /// 由 [AylaCornerFabStack] 容器承载定位（宽屏右下堆叠）。
  corner,

  /// `.is-narrow`：窄屏独立定位（右下，避让底栏与 CreateFAB）。
  narrow,
}

// ======================= 堆叠容器 =======================

/// `.corner-fab-stack` —— 右下角浮层按钮组容器（`CornerFabStack.tsx` 1–26）。
///
/// **返回 [Positioned]**（web 是 `position: fixed`），
/// 因此必须放在页面最外层 `Stack` 的**直接子级**（与 `TabBadge` 的 positioned 档同约定）。
/// `CreateFAB` 不在此容器内（web 由 AppShell 独立挂载），容器 bottom 已经为它让出
/// `32 + 56 + 12`。
class AylaCornerFabStack extends StatelessWidget {
  const AylaCornerFabStack({
    super.key,
    this.refresh = false,
    this.scrollTop = false,
    this.onRefresh,
    this.scrollController,
  });

  /// 渲染刷新钮（web `props.refresh`）。
  final bool refresh;

  /// 渲染回顶钮（web `props.scrollTop`；名字同 web，含义是「是否渲染」而非滚动量）。
  final bool scrollTop;

  /// 透传给 [AylaRefreshFab.onRefresh]。
  final Future<void> Function()? onRefresh;

  /// 透传给 [AylaScrollTopFab.controller]。
  final ScrollController? scrollController;

  /// `right: calc(32px + (56px - 44px) / 2)` = 38px（与 56px 的 CreateFAB 水平居中）。
  static const double stackRight = 32 + (56 - 44) / 2;

  /// `bottom: calc(32px + 56px + var(--sp-3))` = 100px。
  static const double stackBottom = 32 + 56 + 12;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: stackRight,
      bottom: stackBottom,
      // `pointer-events: none`（容器不吃指针、子项 auto）——Flutter 裸 Column
      // 不参与命中测试，天然等价，无需显式 IgnorePointer（那会连子项一起忽略）。
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end, // align-items: flex-end
        spacing: AylaSpacing.sp3, // gap: var(--sp-3)
        children: <Widget>[
          // JSX 顺序：回顶（上）→ 刷新（下）
          if (scrollTop) AylaScrollTopFab(controller: scrollController),
          if (refresh) AylaRefreshFab(onRefresh: onRefresh),
        ],
      ),
    );
  }
}

// ======================= 刷新 =======================

/// `.corner-fab.corner-fab-refresh` —— 44px 玻璃刷新圆钮（`RefreshFab.tsx` 1–39）。
///
/// **无回调 ≠ 禁用**：web `if (!fn) return` —— 按钮外观与 hover/按压照常，只是点击无动作。
/// 故这里恒传可点回调，禁用外观（`.55`）只在调用方显式传 `onPressed` 时才可能出现。
class AylaRefreshFab extends StatefulWidget {
  const AylaRefreshFab({
    super.key,
    this.onRefresh,
    this.position = AylaRefreshFabPosition.corner,
  });

  /// 刷新回调（等价 web `useShellStore.refreshCallback`）。
  final Future<void> Function()? onRefresh;

  /// 定位档。
  final AylaRefreshFabPosition position;

  @override
  State<AylaRefreshFab> createState() => _AylaRefreshFabState();
}

class _AylaRefreshFabState extends State<AylaRefreshFab>
    with SingleTickerProviderStateMixin {
  bool _spinning = false;

  /// `--loading-spin-duration` 800ms linear infinite（shell.css:748–750）。
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: AylaDurations.spin,
  );

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  Future<void> _handleTap() async {
    final Future<void> Function()? fn = widget.onRefresh;
    if (fn == null) return; // web `if (!fn) return;`
    setState(() => _spinning = true);
    _spin.repeat();
    try {
      await fn();
    } finally {
      if (mounted) {
        _spin.stop();
        _spin.value = 0;
        setState(() => _spinning = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // shell.css:784–786：reduced-motion 下 `animation: none`（功能保留、不旋转）
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final Widget icon = AylaIcon(aylaIconByName('iconRetry')!, size: 20);

    final Widget button = AylaCornerFab(
      // `.corner-fab-icon` 是旋转宿主（inline-flex 居中，尺寸由图标决定）
      icon: _spinning && !reduceMotion
          ? RotationTransition(turns: _spin, child: icon)
          : icon,
      onPressed: () => unawaited(_handleTap()),
      semanticLabel: '刷新当前页', // aria-label="刷新当前页"
    );

    // `.corner-fab-refresh.is-bottom-left { position: fixed; left: 32px; bottom: 32px }`
    if (widget.position == AylaRefreshFabPosition.bottomLeft) {
      return Positioned(left: 32, bottom: 32, child: button);
    }
    return button;
  }
}

// ======================= 回到顶部 =======================

/// `.corner-fab.corner-fab-scroll-top` —— 44px 玻璃回顶圆钮（`ScrollTopFab.tsx` 1–75）。
///
/// 出现条件（tsx:18–21 / 43–49）：
/// 1. 命中的滚动源必须是**主滚动容器** —— 可滚（`scrollHeight > clientHeight`）
///    且 `clientHeight >= 40% 视口高`（排除消息列表/弹幕等内嵌小滚动区）；
/// 2. `scrollTop > window.innerHeight`（滚过一屏）才浮入。
///
/// Flutter 等价：滚动源取「注入的 [controller] 优先，否则最近祖先 `Scrollable`」；
/// 视口高取 `MediaQuery.size.height`（= web `window.innerHeight`）；
/// 容器高取 `ScrollPosition.viewportDimension`（= web `clientHeight`）。
class AylaScrollTopFab extends StatefulWidget {
  const AylaScrollTopFab({
    super.key,
    this.controller,
    this.position = AylaScrollTopFabPosition.corner,
    this.stacked = false,
  });

  /// 页面主滚动容器（页面层注入；null → 用最近祖先 `Scrollable`）。
  final ScrollController? controller;

  /// 定位档。
  final AylaScrollTopFabPosition position;

  /// `.is-stacked`：窄屏是否再抬高到 CreateFAB 之上（`fabAction != null` 时）。
  final bool stacked;

  /// 主滚动容器判定的高度下限比例（tsx `window.innerHeight * 0.4`）。
  static const double mainScrollerMinHeightFactor = 0.4;

  /// `.is-narrow { right: 16px }` / `.is-narrow.is-stacked { right: calc(16px + 6px) }`。
  static const double narrowRight = 16;

  /// `.is-narrow { bottom: calc(64px + safe + sp3) }` 的固定部分（不含 safe-area）。
  static const double narrowBottomBase = 64 + 12;

  /// `.is-stacked` 再抬高的量（CreateFAB 56 + 间距 12）。
  static const double stackedExtra = 56 + 12;

  /// 平滑回顶时长。
  ///
  /// web 是 `scrollTo({ behavior: "smooth" })`（时长由浏览器实现，CSS 未给数值）；
  /// 与库内既有的平滑滚动口径统一取 **300ms `--ease-out`**
  /// （`channel_sidebar.dart` 的「滚到吸顶位」同一取值）。
  static const Duration smoothDuration = Duration(milliseconds: 300);

  @override
  State<AylaScrollTopFab> createState() => _AylaScrollTopFabState();
}

class _AylaScrollTopFabState extends State<AylaScrollTopFab> {
  ScrollPosition? _position;
  ScrollController? _boundController;
  double _viewportHeight = 0;
  bool _visible = false;
  bool _recomputeQueued = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _viewportHeight = MediaQuery.sizeOf(context).height;
    _syncController();
    _bindSource();
    // ⚠️ 不能在 didChangeDependencies 里直接 _recompute()：首帧 `MediaQuery` 正在
    // update/notifyClients，此时 setState 会让依赖关系断言失败
    // （实测 `_MediaQueryFromView` 的 "check that it really is our descendant"）；
    // 且首帧 layout 尚未发生，`viewportDimension` 仍是 null。统一排到帧后。
    _scheduleRecompute();
  }

  @override
  void didUpdateWidget(AylaScrollTopFab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      _boundController?.removeListener(_bindSource);
      _boundController = null;
      _syncController();
      _bindSource();
      _scheduleRecompute();
    }
  }

  @override
  void dispose() {
    _boundController?.removeListener(_bindSource);
    _position?.removeListener(_onScroll);
    super.dispose();
  }

  /// 最近祖先 `Scrollable` 的滚动位置（库内范本：`group_card.dart` 的可见性绑定）。
  ScrollPosition? _ancestorPosition() {
    ScrollPosition? found;
    context.visitAncestorElements((Element element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        found = (element.state as ScrollableState).position;
        return false;
      }
      return true;
    });
    return found;
  }

  /// 记住注入的 controller（滚动时它自身会 notify，用于重取 position）。
  void _syncController() {
    final ScrollController? controller = widget.controller;
    if (identical(controller, _boundController)) return;
    _boundController?.removeListener(_bindSource);
    _boundController = controller;
    _boundController?.addListener(_bindSource);
  }

  /// ⚠️ `ScrollController.attach()` **不会** notifyListeners（它只把 notifyListeners
  /// 挂到 position 上）→ 首帧时列表往往尚未 attach，`positions` 为空。
  /// 故在 build 里补一次 postFrame 兜底绑定（`_bindSource` 幂等，绑上后不再排队）。
  void _ensureBound() {
    if (_position != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _bindSource();
    });
  }

  void _bindSource() {
    final ScrollController? controller = widget.controller;
    final ScrollPosition? next;
    if (controller == null) {
      next = _ancestorPosition();
    } else if (controller.hasClients && controller.positions.isNotEmpty) {
      next = controller.position;
    } else {
      next = null;
    }
    if (identical(next, _position)) return;
    _position?.removeListener(_onScroll);
    _position = next;
    _position?.addListener(_onScroll);
    _scheduleRecompute();
  }

  /// 排到帧后重算（首帧 `viewportDimension` / `pixels` 可能尚未就绪）。
  void _scheduleRecompute() {
    if (_recomputeQueued) return;
    _recomputeQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _recomputeQueued = false;
      if (mounted) _recompute();
    });
  }

  void _onScroll() => _recompute();

  void _recompute() {
    final ScrollPosition? p = _position;
    // `viewportDimension` / `pixels` 在首帧 layout 之前是 null（读会抛 Null check）
    final bool next = p != null &&
        p.hasViewportDimension &&
        p.hasPixels &&
        p.viewportDimension >=
            _viewportHeight * AylaScrollTopFab.mainScrollerMinHeightFactor &&
        p.pixels > _viewportHeight;
    if (next != _visible) setState(() => _visible = next);
  }

  void _scrollToTop() {
    final ScrollPosition? p = _position;
    if (p == null || !p.hasPixels) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      p.jumpTo(0); // web `behavior: "auto"`（reduced-motion 直切）
    } else {
      unawaited(p.animateTo(
        0,
        duration: AylaScrollTopFab.smoothDuration,
        curve: AylaCurves.easeOut,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    _ensureBound(); // 首帧 controller 尚未 attach 时的兜底绑定
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    // shell.css:775–782：reduced-motion 只保留透明度渐变、`transform: none`
    final Duration duration =
        reduceMotion ? Duration.zero : AylaDurations.button; // 200ms（auroraqua 覆写）
    final double offsetY = reduceMotion || _visible ? 0 : 8;

    final Widget button = AylaCornerFab(
      icon: AylaIcon(aylaIconByName('iconArrowUp')!, size: 20),
      onPressed: _scrollToTop,
      semanticLabel: '回到顶部', // aria-label="回到顶部"
    );

    final Widget body = IgnorePointer(
      ignoring: !_visible, // `visibility: hidden` 时不可点
      child: ExcludeSemantics(
        excluding: !_visible, // aria-hidden={!visible}
        child: AnimatedOpacity(
          opacity: _visible ? 1 : 0,
          duration: duration,
          curve: AylaCurves.auroraqua,
          child: TweenAnimationBuilder<double>(
            // 只给 end：首帧即落在目标位移（隐藏态 = 8px），之后变化才做过渡
            tween: Tween<double>(end: offsetY),
            duration: duration,
            curve: AylaCurves.easeOut, // `--ease-out`
            builder: (BuildContext context, double dy, Widget? child) =>
                Transform.translate(offset: Offset(0, dy), child: child),
            child: button,
          ),
        ),
      ),
    );

    // 隐藏态仍占位（web `visibility: hidden` 保留 flex 占位 → 下方刷新钮不下移）
    if (widget.position == AylaScrollTopFabPosition.narrow) {
      return Positioned(
        right: widget.stacked
            ? AylaScrollTopFab.narrowRight + (56 - 44) / 2 // 22px：与 56px CreateFAB 居中
            : AylaScrollTopFab.narrowRight,
        bottom: AylaScrollTopFab.narrowBottomBase +
            MediaQuery.paddingOf(context).bottom +
            (widget.stacked ? AylaScrollTopFab.stackedExtra : 0),
        child: body,
      );
    }
    return body;
  }
}

// ======================= 红点快捷消息 =======================

/// `.message-fab.quick-message-fab` —— 红点快捷消息圆钮（`QuickMessageFab.tsx` 1–54）。
///
/// 与 `MessageFab` 同外观（复用 [AylaMessageFab]），差别在点击语义与半贴交互：
/// 展开态点击 → [onOpenQuickMessages]；半贴态点击 → 先点出来（展开）；
/// 展开后 [collapseDelay] 内无点击 → 半贴（`translateX(-44px)`，仅露 28px 右半）。
class AylaQuickMessageFab extends StatefulWidget {
  const AylaQuickMessageFab({
    super.key,
    this.unread = 0,
    this.quickMessagesOpen = false,
    this.onOpenQuickMessages,
    this.collapseDelay = defaultCollapseDelay,
  });

  /// 未读数（>0 挂 `.tab-badge`，99+ 截断由 [TabBadge] 处理）。
  final int unread;

  /// 快捷消息栏是否已打开（等价 web `useShellStore.quickMessagesOpen`）——
  /// 打开期间暂停半贴计时（bug 修复：快捷栏不随红点归零关闭）。
  final bool quickMessagesOpen;

  /// 展开态点击回调（打开快捷消息栏）。
  final VoidCallback? onOpenQuickMessages;

  /// 半贴等待时长（tsx `COLLAPSE_DELAY_MS = 4000`；测试/演示可注入更短值）。
  final Duration collapseDelay;

  /// tsx `const COLLAPSE_DELAY_MS = 4000`。
  static const Duration defaultCollapseDelay = Duration(milliseconds: 4000);

  /// `.is-collapsed { transform: translateX(-44px) }`。
  static const double collapseShift = 44;

  @override
  State<AylaQuickMessageFab> createState() => _AylaQuickMessageFabState();
}

class _AylaQuickMessageFabState extends State<AylaQuickMessageFab> {
  /// true = 半贴（侧边只露半截）；false = 完整展开（tsx 内部 state）。
  bool _collapsed = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _restartTimer();
  }

  @override
  void didUpdateWidget(AylaQuickMessageFab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.quickMessagesOpen != widget.quickMessagesOpen ||
        oldWidget.collapseDelay != widget.collapseDelay) {
      _restartTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 展开态停留超时 → 半贴；半贴态或快捷栏打开态不启动计时（tsx:28–32）。
  void _restartTimer() {
    _timer?.cancel();
    if (widget.quickMessagesOpen || _collapsed) return;
    _timer = Timer(widget.collapseDelay, () {
      if (mounted) setState(() => _collapsed = true);
    });
  }

  void _handleTap() {
    if (_collapsed) {
      setState(() => _collapsed = false); // 半贴 → 点出来
      _restartTimer();
      return;
    }
    widget.onOpenQuickMessages?.call(); // 展开 → 打开快捷消息栏
  }

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final String label = _collapsed
        ? '展开消息'
        : widget.unread > 0
            ? '消息，${widget.unread} 条未读'
            : '消息';

    final Widget button = AylaMessageFab(
      // `.message-fab` 里图标是 24px（`<IconMessage width={24} height={24} />`）
      icon: AylaIcon(aylaIconByName('iconMessage')!, size: 24),
      onPressed: _handleTap,
      badge: widget.unread > 0 ? TabBadge(count: widget.unread) : null,
      semanticLabel: label,
    );

    return TweenAnimationBuilder<double>(
      // 只给 end：首帧落在当前状态，之后（半贴/展开）才做 200ms 过渡
      tween: Tween<double>(end: _collapsed ? 1 : 0),
      // `.quick-message-fab { transition: transform 200ms --ease-out }`；
      // reduced-motion（shell.css:452–456）→ `transition: none`（立即跳变）
      duration: reduceMotion ? Duration.zero : AylaDurations.button,
      curve: AylaCurves.easeOut,
      builder: (BuildContext context, double v, Widget? child) => Transform.translate(
        // 精确像素位移：不用 AnimatedSlide（其基准是 child 尺寸，56 ≠ 44）
        offset: Offset(-AylaQuickMessageFab.collapseShift * v, 0),
        child: child,
      ),
      child: button,
    );
  }
}

// ======================= 预览 =======================

/// FAB 族样张（画布与 @Preview 共用；**可交互**）。
///
/// - 左下「模拟页面」是一个真实 `ListView` + 注入 `ScrollController`：
///   往下滚超过一屏，右下**回顶钮浮入**（点它平滑回顶，滚回顶后自动隐去）；
/// - 右下「刷新」点一下 → 图标转 800ms（注入 900ms 的假刷新）；
/// - 右侧消息钮 4s 后自动半贴（点一下点出来，再点一下触发打开回调，回调计数显示在下方）。
Widget aylaFabSamples() => const _FabDemo();

class _FabDemo extends StatefulWidget {
  const _FabDemo();

  @override
  State<_FabDemo> createState() => _FabDemoState();
}

class _FabDemoState extends State<_FabDemo> {
  final ScrollController _pageScroll = ScrollController();
  int _openCount = 0;

  @override
  void dispose() {
    _pageScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 模拟页面视口 375×420：回顶钮的判定基准是 `MediaQuery.size.height`
    // （= web `window.innerHeight`）⇒ 画布里「一屏」= 420，往下滚 420px 即浮入。
    const Size page = Size(375, 420);
    return Wrap(
      spacing: AylaSpacing.sp6,
      runSpacing: AylaSpacing.sp6,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        // ① 模拟窄屏页面：真实滚动容器 + 堆叠两钮（回顶/刷新）+ 独立消息钮
        _Stage(
          viewport: page,
          label: '模拟页面 375×420（一屏 = 420）· 往下滚过一屏 → 右下回顶钮浮入 · '
              '点 ⟳ 看旋转 · 消息钮 4s 后半贴 · 打开快捷栏 $_openCount 次',
          scroller: _pageScroll,
          builder: (ScrollController? scroller) => <Widget>[
            AylaCornerFabStack(
              refresh: true,
              scrollTop: true,
              onRefresh: () =>
                  Future<void>.delayed(const Duration(milliseconds: 900)),
              scrollController: scroller,
            ),
            Positioned(
              left: 16,
              // `.message-fab { left: 16; bottom: calc(64px + safe-area + 12px) }`
              // —— 舞台底部代表「窄屏底栏之下」，故保留 76（+ safe）的真实位置
              bottom: 64 + MediaQuery.paddingOf(context).bottom + 12,
              child: AylaQuickMessageFab(
                unread: 3,
                onOpenQuickMessages: () => setState(() => _openCount++),
              ),
            ),
          ],
        ),
        // ② 单件档位：左下刷新（宽屏私信列表用）+ 窄屏回顶（不堆叠 / 堆叠）。
        // 两个回顶舞台**自带滚动容器并预先滚过一屏**：既让「浮入态」可见，
        // 也把它绑到舞台自己的容器上——否则会回退到**画布自己的** `Scrollable`，
        // 在没滚动的舞台里也亮着（首版就是这个现象）。
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          spacing: AylaSpacing.sp4,
          children: <Widget>[
            _Stage(
              viewport: const Size(260, 120),
              label: 'RefreshFab · bottomLeft（left 32 / bottom 32，无 safe-area）',
              builder: (ScrollController? _) => <Widget>[
                const AylaRefreshFab(
                  position: AylaRefreshFabPosition.bottomLeft,
                ),
              ],
            ),
            _Stage(
              viewport: const Size(260, 150),
              label: 'ScrollTopFab · narrow（right 16 / bottom 76 + safe）',
              scrollTo: 150 + 8, // > 一屏 → 浮入态可见
              builder: (ScrollController? scroller) => <Widget>[
                AylaScrollTopFab(
                  controller: scroller,
                  position: AylaScrollTopFabPosition.narrow,
                ),
              ],
            ),
            _Stage(
              viewport: const Size(260, 220),
              label:
                  'ScrollTopFab · narrow + stacked（right 22 / bottom 144 + safe）',
              scrollTo: 220 + 8, // > 一屏 → 浮入态可见
              builder: (ScrollController? scroller) => <Widget>[
                AylaScrollTopFab(
                  controller: scroller,
                  position: AylaScrollTopFabPosition.narrow,
                  stacked: true,
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

/// 固定视口的样张舞台。
///
/// - FAB / 弹层的**定位与判定都读 `MediaQuery` 视口** → 必须覆写局部视口，
///   否则会按预览宿主窗口走（`13-工作进度与待办.md` §6.6 同一纪律）；
/// - [scroller] 给出时，舞台内置一个真实 `ListView` 用该 controller（模拟页面的滚动源）；
/// - [scrollTo] 给出时，舞台自建滚动容器并**预先滚到该位置**（> 一屏 → 回顶钮浮入态可见）。
///   没有它的话，回顶钮会回退到**画布自己的** `Scrollable`（画布已滚动 ⇒ 舞台里也亮着）；
///   而舞台内的 `ListView` 与 FAB 是 `Stack` 的**兄弟**，祖先查找找不到它 ⇒ 必须显式注入。
class _Stage extends StatefulWidget {
  const _Stage({
    required this.viewport,
    required this.label,
    required this.builder,
    this.scroller,
    this.scrollTo,
  });

  final Size viewport;
  final String label;

  /// `Stack` 的 children（定位档要放在 Stack 里才成立）；参数是舞台的滚动 controller。
  final List<Widget> Function(ScrollController? scroller) builder;

  /// 外部提供的滚动 controller（模拟页面复用用户可滚的那一个）。
  final ScrollController? scroller;

  /// 非 null：自建滚动容器并预滚到该位置。
  final double? scrollTo;

  @override
  State<_Stage> createState() => _StageState();
}

class _StageState extends State<_Stage> {
  ScrollController? _own;

  ScrollController? get _scroller => widget.scroller ?? _own;

  /// 需要内置滚动容器？（有外部 controller 或需要预滚）
  bool get _hasList => widget.scroller != null || widget.scrollTo != null;

  @override
  void initState() {
    super.initState();
    if (widget.scroller == null && widget.scrollTo != null) {
      _own = ScrollController();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final double? target = widget.scrollTo;
        if (target != null && _own!.hasClients) _own!.jumpTo(target);
      });
    }
  }

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          width: widget.viewport.width,
          height: widget.viewport.height,
          child: Builder(
            builder: (BuildContext inner) => MediaQuery(
              data: MediaQuery.of(inner).copyWith(size: widget.viewport),
              child: Stack(
                children: <Widget>[
                  if (_hasList)
                    ListView.builder(
                      controller: _scroller,
                      itemCount: 40, // 40 × 40 = 1600 高，足够滚过任何舞台视口
                      itemBuilder: (BuildContext context, int i) => SizedBox(
                        height: 40,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '条目 $i',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ),
                    ),
                  ...widget.builder(_scroller),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        // 说明文字放在舞台**下方**（不再叠在内容上——首版压着列表条目，读不清）
        SizedBox(
          width: widget.viewport.width,
          child: Text(widget.label, style: const TextStyle(fontSize: 11)),
        ),
      ],
    );
  }
}

/// FAB 族（堆叠 / 左下刷新 / 窄屏回顶 / 半贴消息）—— 可交互。
@Preview(
  group: 'Widgets',
  name: 'FAB 族（堆叠 + 左下刷新 + 窄屏回顶 + 半贴消息）',
  size: Size(1000, 1000),
  wrapper: previewTheme,
)
Widget aylaFabPreview() => aylaFabSamples();
