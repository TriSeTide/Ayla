/// 入场动画公共件 —— `.reveal-item` 与 `auroraqua-*-in` 的 Flutter 等价。
///
/// 事实源（逐条对应 web 源码，无自由发挥）：
/// - `Ayla/web/src/components/motion/auroraquaMotion.ts`：
///   `distance: 20` / `duration: 0.3` / `easeOut: [0,0,.58,1]` / `staggerMs: 50`
/// - `Ayla/web/src/hooks/useListEntryMotion.ts`：
///   列表批量入场——**只播新提交的节点**（已入场节点永不重播），
///   `staggerDelay(i) = min(i*50, 300)`；`suppressed`（滚动恢复命中）只阻止**启动**
///   新入场、不取消已开始的动画；`replayKey` 变化时对**已入场**节点整批重播一次
///   （刷新反馈，`suppressed` 不参与抑制）。
/// - `Ayla/web/src/styles/base.css` 483–506（`.reveal-item`：opacity 0→1 + 下 20px）
/// - `Ayla/web/src/styles/auroraqua.css` 8–26
///   （`auroraqua-sidebar-in` 左入 / `auroraqua-panel-from-top` 上入 / `-from-bottom`）
///
/// 为什么要有这个文件（2026-09-20 组件库审查 R7）：
/// 迁移前库内存在**两套私有实现**——`group_card.dart` 的 `_RevealItem`（带 delay）与
/// `profile_and_filters.dart` 的 `_EnterFrom`（带方向），配方完全一致却各写一份，
/// 且 B5 帖子流还要第三套（stagger + 抑制 + 重播）。此处收敛为公共件，全部复用。
///
/// ⚠️ **步长不可互抄**：web 两条链路的 stagger 不同——
/// 列表（`useListEntryMotion`）为 `min(i*50,300)`；群卡网格为 `min(i*80,300)`
/// （见 `group_card.dart` 的 `staggerDelay(i)` 注释）。故 [AylaRevealItem.delay]
/// 支持显式传入，不强制用本文件的默认步长。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../theme/app_theme.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';

/// 入场动画的公共参数（web `AURORAQUA_MOTION`）。
abstract final class AylaRevealMotion {
  /// `distance: 20` —— `.reveal-item` 与 `auroraqua-*-in` 的位移量（px）。
  static const double distance = 20;

  /// `staggerMs: 50` —— 列表逐条入场的步长。
  static const int staggerMs = 50;

  /// stagger 上限 300ms（`staggerDelay` 的 cap）。
  static const int maxStaggerMs = 300;

  /// `staggerDelay(index, gap, cap) = min(index * gap, cap)`。
  static Duration staggerDelay(
    int index, {
    int staggerMs = AylaRevealMotion.staggerMs,
    int capMs = AylaRevealMotion.maxStaggerMs,
  }) {
    final int ms = math.min(math.max(index, 0) * staggerMs, capMs);
    return Duration(milliseconds: ms);
  }
}

/// 列表级编排（对应 `useListEntryMotion` 的两个列表状态）。
///
/// - [suppress]：滚动恢复命中时为 true → 期间**新挂载**的项直接显示、不播入场
///   （已开始的动画不取消，对齐 web 注释）。
/// - [replayKey]：变化时让所有**已入场**子项重播一次（刷新反馈）；**不受
///   [suppress] 影响**（web：用 restoring 抑制重播会导致切 tab 后刷新永远没动画）。
///
/// 未包在 scope 内的 [AylaRevealItem] 也能独立工作（无抑制、无重播）。
class AylaRevealScope extends StatefulWidget {
  const AylaRevealScope({
    super.key,
    required this.child,
    this.suppress = false,
    this.replayKey,
    this.staggerMs = AylaRevealMotion.staggerMs,
    this.maxStaggerMs = AylaRevealMotion.maxStaggerMs,
  });

  /// 内容。
  final Widget child;

  /// 抑制期（滚动恢复命中）：新项不播入场，直接显示。
  final bool suppress;

  /// 变化即触发「已入场项整批重播」。
  final Object? replayKey;

  /// 子项默认步长（未显式传 [AylaRevealItem.delay] 时生效）。
  final int staggerMs;

  /// 子项默认步长上限。
  final int maxStaggerMs;

  @override
  State<AylaRevealScope> createState() => AylaRevealScopeState();
}

/// [AylaRevealScope] 的状态（持有重播信号，供子项监听）。
class AylaRevealScopeState extends State<AylaRevealScope> {
  /// 重播计数：`replayKey` 变化时 +1，随 InheritedWidget 下发给子项。
  int _replayTick = 0;

  @override
  void didUpdateWidget(AylaRevealScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.replayKey != widget.replayKey) {
      // 用状态计数而非 ValueNotifier：重建经 InheritedWidget 依赖机制传播，
      // 子项无需自己管理监听器生命周期（更贴近「列表整批重播」的语义）。
      setState(() => _replayTick += 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _AylaRevealScopeData(
      suppress: widget.suppress,
      replayTick: _replayTick,
      staggerMs: widget.staggerMs,
      maxStaggerMs: widget.maxStaggerMs,
      child: widget.child,
    );
  }
}

/// scope 数据（InheritedWidget；项通过它读抑制态与重播信号）。
class _AylaRevealScopeData extends InheritedWidget {
  const _AylaRevealScopeData({
    required this.suppress,
    required this.replayTick,
    required this.staggerMs,
    required this.maxStaggerMs,
    required super.child,
  });

  final bool suppress;

  /// 重播计数（`replayKey` 每次变化 +1）。
  final int replayTick;

  final int staggerMs;
  final int maxStaggerMs;

  static _AylaRevealScopeData? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_AylaRevealScopeData>();

  @override
  bool updateShouldNotify(_AylaRevealScopeData oldWidget) =>
      suppress != oldWidget.suppress ||
      replayTick != oldWidget.replayTick ||
      staggerMs != oldWidget.staggerMs ||
      maxStaggerMs != oldWidget.maxStaggerMs;
}

/// 单项入场：`opacity 0→1` + 位移 [offset]→0、[duration] `--auroraqua-ease-out`。
///
/// ⚠️ [enabled] == false 时**完全不挂动画**（返回 [child] 本体）——这对应 web
/// 「列表只在需要时给节点加 `.reveal-item` 类」：滚动恢复/历史节点不加类。
/// 迁移前的 `_RevealItem(delay: null)` 就是这一语义，勿改为「延迟 0 的动画」。
class AylaRevealItem extends StatefulWidget {
  const AylaRevealItem({
    super.key,
    required this.child,
    this.enabled = true,
    this.delay,
    this.index = 0,
    this.offset = const Offset(0, AylaRevealMotion.distance),
    this.duration = AylaDurations.auroraqua,
    this.curve = AylaCurves.auroraquaEaseOut,
  });

  /// 内容。
  final Widget child;

  /// 是否入场（false = 直接显示，不挂动画）。
  final bool enabled;

  /// 显式延迟；null = 按 [index] 与 scope 步长推导（`staggerDelay`）。
  final Duration? delay;

  /// 同批序号（用于推导 stagger 延迟）。
  final int index;

  /// 起始位移（y 向下为正；上入用 `Offset(0, -20)`、左入 `Offset(-20, 0)`）。
  final Offset offset;

  /// 时长（默认 300ms `--auroraqua-duration`）。
  final Duration duration;

  /// 缓动（默认 `--auroraqua-ease-out`）。
  final Curve curve;

  @override
  State<AylaRevealItem> createState() => _AylaRevealItemState();
}

class _AylaRevealItemState extends State<AylaRevealItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  Timer? _delayTimer;
  int _replayTick = 0;
  bool _started = false;

  bool get _reduceMotion =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 不能在 initState 读 MediaQuery（本项目已踩过两次）→ 首帧决策放这里。
    final _AylaRevealScopeData? data = _AylaRevealScopeData.maybeOf(context);
    if (!_started) {
      _started = true;
      // 只在首帧记录基线 tick：后续的重播对比必须留给 build 里的
      // _syncReplayTick（若在这里覆盖 tick，重播会被自己吃掉——实测踩过）。
      _replayTick = data?.replayTick ?? 0;
      _startEntry(data);
    }
  }

  @override
  void didUpdateWidget(AylaRevealItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
    }
  }

  /// scope 的 replayKey 变化（tick 前进）→ 已入场项重播一次。
  ///
  /// 依赖 InheritedWidget 的重建时机：`didChangeDependencies` 先于 `build`，
  /// 故这里重置动画后当帧即以 opacity 0 呈现。
  void _syncReplayTick(int tick) {
    if (tick == _replayTick) return;
    _replayTick = tick;
    if (!mounted || !widget.enabled || _reduceMotion) return;
    _delayTimer?.cancel();
    _controller
      ..value = 0
      ..forward();
  }

  void _startEntry(_AylaRevealScopeData? data) {
    if (!widget.enabled || _reduceMotion) {
      _controller.value = 1;
      return;
    }
    if (data?.suppress ?? false) {
      // 滚动恢复命中：直接显示（web：suppressed 只阻止启动新的入场动画）
      _controller.value = 1;
      return;
    }
    final Duration delay = widget.delay ??
        AylaRevealMotion.staggerDelay(
          widget.index,
          staggerMs: data?.staggerMs ?? AylaRevealMotion.staggerMs,
          capMs: data?.maxStaggerMs ?? AylaRevealMotion.maxStaggerMs,
        );
    if (delay == Duration.zero) {
      _controller.forward();
      return;
    }
    _delayTimer = Timer(delay, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 依赖重建时 didChangeDependencies 会先跑（但不覆盖 tick）→ 这里对比触发重播。
    _syncReplayTick(_AylaRevealScopeData.maybeOf(context)?.replayTick ?? _replayTick);
    if (!widget.enabled || _reduceMotion) return widget.child;
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        final double t = widget.curve.transform(_controller.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(
              widget.offset.dx * (1 - t),
              widget.offset.dy * (1 - t),
            ),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

// ======================= 预览 =======================

/// 入场动画：三种位移来源（下入 20 / 上入 20 / 左入 20）+ 关闭态。
@Preview(
  group: 'Widgets',
  name: 'AylaRevealItem 下入/左入/不挂动画',
  size: Size(460, 330), // 4 行样张 + 间距 + 内沿，220 会 RenderFlex 溢出
  wrapper: previewTheme,
)
Widget aylaRevealItemPreview() {
  return AylaRevealScope(
    child: Padding(
      padding: const EdgeInsets.all(AylaSpacing.sp6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: AylaSpacing.sp3,
        children: <Widget>[
          for (int i = 0; i < 3; i++)
            AylaRevealItem(
              index: i,
              child: _RevealSample(label: '下入 · index $i'),
            ),
          const AylaRevealItem(
            enabled: false,
            offset: Offset(-AylaRevealMotion.distance, 0),
            child: _RevealSample(label: '左入 · offset(0,-20) 方向'),
          ),
        ],
      ),
    ),
  );
}

/// 预览样张（真实玻璃卡 + 文案，非占位）。
class _RevealSample extends StatelessWidget {
  const _RevealSample({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Container(
      height: 44,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp3),
      decoration: BoxDecoration(
        color: AylaColors.glassBg,
        borderRadius: BorderRadius.circular(AylaRadii.rInput),
        border: Border.all(color: AylaColors.glassBorder),
      ),
      child: Text(label, style: t.label.copyWith(fontSize: 13)),
    );
  }
}
