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
///
/// ## ⚠️ 玻璃子树：不做整层淡入（2026-09-29，Impeller 校验刷屏修复）
///
/// web 的 `.reveal-item`（`base.css:483–506`）与 `auroraqua-*-in`（`auroraqua.css:8–26`）
/// 都是**一条**「opacity 0→1 + 位移」动画。但 Flutter 的 `Opacity` 会推
/// `OpacityLayer`，而 Impeller **拒绝**把继承不透明度传给 `BackdropFilter` 的 Contents：
///
/// ```
/// [ERROR:flutter/impeller/entity/contents/contents.cc(119)] Break on
/// 'impeller::ImpellerValidationBreak' to inspect point of failure:
/// Contents::SetInheritedOpacity should never be called when Contents::CanAcceptOpacity returns false.
/// ```
///
/// 库内对这条拒绝已有两条口径（13 号 §6.2 末条 + §8.19）：
/// - **禁用态**（`theme/buttons.dart:53–63`、`AylaGlassSurface.dimAlpha`，
///   `theme/glass.dart:409–421`）⇒ 改「按颜色降透明」——因为 web 的
///   `opacity: .55` 在 Flutter 侧**根本不生效**（功能 bug）；
/// - **web 本来就是整层 opacity 的动效**（§8.19 列的 7 处）⇒ 保持整层、接受校验日志。
///
/// 本件走**第三条**：入场动画不能砍（`web` 有淡入，页面层依赖它做编排），
/// 也不改玻璃件（跨组件一致性改动按库规先问用户）⇒ **按调用方声明的档位分流**：
///
/// | `fadeGlass` | 渲染 | 与 web 的差异 |
/// |---|---|---|
/// | `true`（默认） | `Opacity(t)` + 位移 | **无差异**（逐帧等价 web） |
/// | `false`（玻璃安全档） | `Opacity(1.0)` + 位移 | **只有位移、没有淡入** |
///
/// web 事实源：`base.css:483–506` 的 `.reveal-item` 与 `auroraqua.css:8–26` 的
/// `auroraqua-*-in` 都是 `opacity: 0 → 1` **加** `translate` 一条动画
/// ⇒ `fadeGlass: false` 只丢 `opacity` 那一半，位移**保持完整**。
///
/// 为什么 `Opacity(1.0)` 就够了（**依据 = 本机 Flutter 3.47.4 的实现，已逐行回读，
/// 不是旧版印象**）：
/// - `RenderOpacity.paint`（`rendering/proxy_box.dart:947–953`）：
///   `if (child == null || _alpha == 0) return;` ⇒ `alpha == 0` **不 paint 子树**
///   （不会建 `BackdropFilterLayer`）；
/// - `OpacityLayer.addToScene`（`rendering/layer.dart:2186–2200`）：
///   只有 `realizedAlpha < 255` 才 `builder.pushOpacity(...)`，`alpha == 255` 走
///   `builder.pushOffset(...)` ⇒ **不推 opacity** ⇒ 玻璃后代拿不到继承不透明度，
///   Impeller 校验不触发；视觉上等价「不淡入」。
///
/// ⚠️ 库内 `widgets/base/dialogs.dart:565–566` 那句「RenderOpacity 在 alpha == 255 时
/// 跳过 layer」**与本机 3.47.4 实现不符**（3.47.4 仍会建 `OpacityLayer`，只是
/// `addToScene` 换成 `pushOffset`）；那处的**结论**（卡内 `BackdropFilter` 不会长期退化）
/// 仍成立，但依据应以 `layer.dart:2186` 为准。
///
/// 分流由调用方的 [AylaRevealItem.fadeGlass] **显式声明**（默认 `true` = 改前行为）：
/// 子树里出现 `AylaGlassSurface` / `AylaGlassBackdrop` / `AylaGlassButton` /
/// `AylaSidebarCard` / 裸 `BackdropFilter` ⇒ 必须传 `fadeGlass: false`。
///
/// **为什么必须静态声明**（2026-09-29 总控纠偏，勿改回自动探测）：
/// `BuildContext.visitChildElements()` **在 build 期间被 Flutter 明令禁止**
/// —— 实测直接抛
/// `visitChildElements() called during build.`（`create_live_sheet_test` 首例即崩），
/// 且会连锁污染全仓用例；paint 期又拿不到「本帧要不要推 opacity」的决策权
/// ⇒ 自动探测在 Flutter 里**没有可用位置**，只能由调用方声明。
///
/// 更彻底的做法是让玻璃件自己接收父级 alpha（`dimAlpha` 的动态版，
/// 或「父级在动画中就跳过 `BackdropFilter`」）——**属跨组件一致性改动，
/// 按 13 号 §6.2 末条先问用户**，本件不擅自推广。
///
/// ## 公开面
/// `AylaRevealMotion` · `AylaRevealScope` · `AylaRevealScopeState` · `AylaRevealItem`

library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;

import '../../theme/tokens.dart';

/// 玻璃档在「入场尚未开始」阶段使用的 alpha —— **不可见，但会被绘制**。
///
/// ⚠️ 为什么不能用 0（2026-09-30 实机「出现全部卡片时掉帧 + 就位前一帧偏白」的根因）：
/// `RenderOpacity.paint` 在 `_alpha == 0` 时**直接 return**
/// （`rendering/proxy_box.dart:947–953`）⇒ 子树完全不 paint ⇒ `SnapshotWidget` 的捕获
/// （发生在 `paint()` 里）会被推迟到**卡片开始可见的那一帧**。而列表里第
/// `cap / staggerMs` 张之后的卡共用同一个 `delay`（`min(i*50, 300)`）⇒ 它们**同一帧**
/// 开始可见 ⇒ 那一帧要同时做 N 张卡的捕获（同步离屏渲染）⇒ **掉帧**；
/// 且捕获那一刻该帧的 backdrop 可能尚未就绪 ⇒ 纹理偏白 ⇒ **「就位前一帧有一部分卡片偏白」**。
///
/// 取 1/1000：肉眼连 alpha 1/255 都分辨不出（0.25/255 与全透明等价），
/// 但足以让 `OpacityLayer` 成立并驱动子树 paint 一次 —— 于是**捕获发生在卡片还看不见的
/// 时候**，可见帧只画纹理（每帧成本从「模糊」降到「画纹理」）。
const double kAylaInvisibleButPainted = 0.001;

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

/// 同批新项之间允许的最大登记间隔：超过即视为**新批次**（基准时间重置）。
///
/// 依据 web：`useListEntryMotion` 每次 commit 只对**新节点**从 0 计数
/// （`ts:68–80` 的 `let index = 0; … staggerDelay(index++)`）⇒ 一次 commit 的项共享
/// 同一时间原点；分批到达（分页 / WS）则各算一批。200ms 远大于一帧、远小于
/// 「一批加载完到下一批」的间隔。
const Duration kAylaRevealBatchGap = Duration(milliseconds: 200);

/// [AylaRevealScope] 的状态（持有重播信号与**批次时间基准**，供子项监听）。
class AylaRevealScopeState extends State<AylaRevealScope> {
  /// 重播计数：`replayKey` 变化时 +1，随 InheritedWidget 下发给子项。
  int _replayTick = 0;

  /// **本批入场的动画时间原点**（帧时间戳）。
  ///
  /// 为什么需要：web 的 `.reveal-item` 用 CSS `animation-delay`，而**所有卡是同一帧
  /// 拿到那个类的** ⇒ 它们的动画时间轴共享同一个原点。Flutter 侧若把「挂载」分帧摊开
  /// （`AylaChunkedChildren`，避免「一帧突然出现太多卡」把 UI 线程打满），后挂载的项
  /// 会晚几帧才开始计时 ⇒ **动画时机整体后移** = 与 web 有视觉差异。
  /// 这里记录批次原点，[noteBatchMember] 把「已经过去多久」告诉每一项，让它**追赶**
  /// （必要时直接落到对应的动画进度）⇒ 分帧与否，**视觉逐帧一致**。
  Duration? _batchStart;
  Duration _lastNote = Duration.zero;

  /// **重播序号**（replayKey 变化那一轮内从 0 递增）。
  ///
  /// ⚠️ 与「首次入场」的下标语义**不同**（web 两处实现都如此，此前这里用错了）：
  /// - 首次入场用**列表下标**：VoiceChannelList.tsx:40 的
  ///   revealDelay={revealItems ? staggerDelay(index) : undefined}（index = 列表位置），
  ///   所以第 7 张起共用 cap 300ms —— 这是设计如此；
  /// - **重播**用**重播序号**：useListEntryMotion.ts:38–48 对**已入场节点**重新
  ///   let index = 0; … delay: staggerDelay(index++) ⇒ 20 张卡重播是 **0/50/…/300/300…**
  ///   （前 7 张依次浮现），而不是「按列表下标 ⇒ 从第 7 张起全部 300ms ⇒ 十几张同时闪」。
  /// 用错会让「刷新重播」变成一次性十几张卡同时动 = 实机「**看着就像停顿**」（用户 2026-09-30）。
  int _replaySeq = 0;

  /// 重播轮内取号（由 [AylaRevealItem] 在 build 期间调用，顺序 = 树顺序）。
  int nextReplayIndex() => _replaySeq++;

  /// 由 [AylaRevealItem] 在首帧登记，返回**本批已流逝的时间**。
  ///
  /// ⚠️ **当前未使用（2026-09-30 起停用）**：曾用它让「分帧挂载的后挂载项」追赶批次
  /// 时间轴，但那是**与 web 不同的时序**（后挂载的卡从中间进度开始 = 视觉上「跳一下」，
  /// 用户当场看出「不是掉帧，是动画顿了一下，一定是和 web 实现有差异」）⇒ 已回退为
  /// 「delay 从本项挂载时刻起算」（= CSS `animation-delay` 语义）。
  /// 保留公共面供「同帧挂载 + 需要记录批起点」的未来场景，避免调用方重新发明。
  Duration noteBatchMember() {
    final Duration now = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    if (_batchStart == null || now - _lastNote > kAylaRevealBatchGap) {
      _batchStart = now;
    }
    _lastNote = now;
    return now - _batchStart!;
  }

  @override
  void didUpdateWidget(AylaRevealScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.replayKey != widget.replayKey) {
      // 用状态计数而非 ValueNotifier：重建经 InheritedWidget 依赖机制传播，
      // 子项无需自己管理监听器生命周期（更贴近「列表整批重播」的语义）。
      _replaySeq = 0; // 新的一轮重播 ⇒ 序号从 0 起（= web 的 let index = 0）
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


/// **时间切片挂载** —— 把「同一帧要挂载的一大批卡片」按帧分批交给宿主。
///
/// ## 为什么（2026-09-30 用户实机判断「最后一帧突然出现太多卡」，已量化证实）
/// 官方 `perf/best-practices` 的「Be lazy」（`ListView.builder` 只构建屏幕内可见项）在
/// 本场景**无能为力**：那批卡全在可见区。实测（`test/tmp_mount_frame_probe_test.dart`）：
/// - **一帧挂载 20 张玻璃卡 = UI 线程 282ms**（拆解：纯色卡基座 60ms + 玻璃件
///   build/layout/paint 记录 42ms + 快照捕获 70ms + 首次光栅化 50ms）；
/// - 分 5 帧、每帧 4 张 ⇒ **单帧最大 72ms（≈4×）**。
/// 那 282ms 全在 **Dart / UI 侧**（与 GPU 无关）—— 这正是「原生 app 该发挥优势」的地方。
///
/// ## 视觉为什么**零差异**
/// 必须配合 [AylaRevealScopeState.noteBatchMember] 的**批次时间原点**（本文件已实现）：
/// 后挂载的项会按「本批已流逝的时间」**追赶**（必要时直接落到对应的动画进度）⇒
/// 与「同帧全挂」**逐帧等价**，也与 web 的 CSS `animation-delay` 语义一致
/// （web 是**所有卡同一帧**拿到 `.reveal-item` 类 ⇒ 共享同一时间原点）。
/// 若列表项不在 [AylaRevealScope] 内（拿不到批次原点），分帧会带来每帧 16ms 的时机偏移
/// ⇒ 那时把 [perFrame] 调大或不用本件。
///
/// ## 用法（单元由调用方定义：一行 / 一列 / 一个区块）
/// ```dart
/// AylaChunkedChildren(
///   itemCount: rowCount,
///   layout: (List<Widget> rows) => Column(children: rows, spacing: AylaSpacing.sp3),
///   builder: (BuildContext c, int row) => Row(children: <Widget>[/* row × cols 张卡 */]),
/// )
/// ```
class AylaChunkedChildren extends StatefulWidget {
  const AylaChunkedChildren({
    super.key,
    required this.itemCount,
    required this.builder,
    required this.layout,
    this.perFrame = 2,
    this.resetKey,
  });

  /// 单元数（单元由调用方定义）。
  final int itemCount;

  /// 第 i 个单元的构建（i 是**列表下标**，与 web 的 `staggerDelay(index)` 同源）。
  final Widget Function(BuildContext context, int index) builder;

  /// 宿主装配（把已挂载的单元装进 `Column` / `Wrap` / `Row`）。
  final Widget Function(List<Widget> children) layout;

  /// 每帧最多新挂载几个单元（默认 2）。
  ///
  /// 20 张卡 = 5 行（4 列）⇒ 每帧 2 行 = 8 张卡 ⇒ 3 帧装完
  /// （按实测 ≈20ms/帧，仍在 16.7ms 预算附近；需要更稳就调到 1）。
  final int perFrame;

  /// 内容身份变化时重置分帧（切 tab / 切群 / 换数据源）；相同身份下的**追加**不重置。
  final Object? resetKey;

  @override
  State<AylaChunkedChildren> createState() => _AylaChunkedChildrenState();
}

class _AylaChunkedChildrenState extends State<AylaChunkedChildren> {
  int _visible = 0;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    _visible = math.min(widget.perFrame, widget.itemCount);
    _scheduleNext();
  }

  @override
  void didUpdateWidget(covariant AylaChunkedChildren oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetKey != widget.resetKey) {
      _visible = math.min(widget.perFrame, widget.itemCount);
    } else if (widget.itemCount < _visible) {
      _visible = widget.itemCount; // 列表变短（筛选 / 删除）
    }
    _scheduleNext();
  }

  /// 每帧只新增 [AylaChunkedChildren.perFrame] 个单元 —— 这是本件的全部意义。
  void _scheduleNext() {
    if (_scheduled || _visible >= widget.itemCount) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      _scheduled = false;
      if (!mounted || _visible >= widget.itemCount) return;
      setState(() {
        _visible = math.min(_visible + widget.perFrame, widget.itemCount);
      });
      _scheduleNext();
    });
  }

  @override
  Widget build(BuildContext context) {
    final int n = math.min(_visible, widget.itemCount);
    final List<Widget> children = <Widget>[
      for (int i = 0; i < n; i += 1) widget.builder(context, i),
    ];
    return widget.layout(children);
  }
}

/// 入场进度的继承广播（**玻璃子树的安全淡入通道**）。
///
/// ## 为什么需要它
/// web 的 `.reveal-item`（`base.css:483–506`）与 WAAPI 链路（`useListEntryMotion.ts:74–80`）都是
/// **`opacity 0→1` + `translateY(20px)→0` 同步**。Flutter 侧若用 `Opacity` 包整棵子树，
/// 一旦子树里有 `BackdropFilter`（全站主要卡片都是玻璃）就会被 Impeller 拒绝并刷校验日志
/// （见文件头「玻璃子树」段）——这正是 40+ 个调用点传 `fadeGlass: false` 的原因，
/// 代价是**整站卡片入场都没有淡入**（用户 2026-09-30 实报「动画淡入淡出都没做」）。
///
/// 本件把**动画进度本身**（`Animation<double>`）下发给子树，让玻璃件自己表达淡入：
/// 模糊强度 × t、面层/亮边/内高光/阴影按颜色 × t（`AylaGlassSurface`）——
/// **不产生 `OpacityLayer`** ⇒ 不触发 Impeller 校验，也不需要调用方声明 `fadeGlass`。
///
/// ## 为什么携带 `Animation` 而不是数值
/// InheritedWidget 的值每帧变化会让**依赖者每帧 rebuild**（卡片内容连带重建）。
/// 携带 `Animation` 实例则 `updateShouldNotify` 恒 false（实例不变），
/// 消费方在**自己的** `AnimatedBuilder` 里监听 ⇒ 每帧只重建需要的那几层，
/// 内容 `child` 复用（与 `AylaRevealItem` 的 `child` 隔离同口径）。
class AylaRevealProgress extends InheritedWidget {
  const AylaRevealProgress({
    super.key,
    required this.progress,
    this.snapshot,
    required super.child,
  });

  /// 入场进度（0→1；缓动已由 `AylaRevealItem` 的 curve 应用）。
  final Animation<double> progress;

  /// 玻璃档的入场快照 controller（非玻璃档为 null）。
  ///
  /// 消费方 = `AylaGlassSurface`：入场期间把**「模糊层 + 卡面」**冻成纹理
  ///（模糊跟着一起淡 ⇒ 不再变色；移动纹理 ⇒ 不再重采样）。
  ///
  /// ⚠️ **阴影必须留在快照之外** —— `SnapshotWidget` 按 child 边界捕获并裁剪，
  /// 画在形状之外的 `box-shadow` 环带会被裁掉（实机「阴影等卡片就位了才渲染」的根因）。
  final SnapshotController? snapshot;

  /// 读当前入场进度；**无入场上下文 ⇒ null**（调用方按「完全显示」处理，零行为变化）。
  static Animation<double>? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AylaRevealProgress>()
      ?.progress;

  /// 读快照 controller（无入场上下文 ⇒ null ⇒ 消费方走无快照路径）。
  static SnapshotController? snapshotOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AylaRevealProgress>()
      ?.snapshot;

  @override
  bool updateShouldNotify(AylaRevealProgress oldWidget) =>
      progress != oldWidget.progress || snapshot != oldWidget.snapshot;
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
    this.fadeGlass = true,
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

  /// 是否对**含玻璃（`BackdropFilter`）的子树**做整层淡入（默认 `true` = 改前行为）。
  ///
  /// ⚠️ **子树里出现 `AylaGlassSurface` / `AylaGlassBackdrop` / `AylaGlassButton` /
  /// `AylaSidebarCard` / 裸 `BackdropFilter` 时必须传 `false`**：Impeller 会拒绝
  /// 「`Opacity` 祖先 + `BackdropFilter`」组合并刷屏（见文件头「玻璃子树」段）。
  ///
  /// - `true`（默认）：整层 `Opacity(t)` + 位移 —— 与 web 的 `.reveal-item` /
  ///   `auroraqua-*-in`（`base.css:483–506` / `auroraqua.css:8–26`）逐帧一致；
  /// - `false`（玻璃安全档）：`Opacity` 恒 1.0 + 位移 —— `OpacityLayer.addToScene`
  ///   在 `alpha == 255` 时走 `pushOffset`（`rendering/layer.dart:2186`），**不推
  ///   opacity** ⇒ 玻璃后代拿不到继承不透明度，**只有位移、没有淡入**。
  ///
  /// 默认值取 `true` 的理由：与改前行为**完全一致**（含玻璃的调用点在本次一并显式
  /// 声明为 `false`），既不在无声中改变其余调用点的观感，也让「漏声明」表现为
  /// **可见的刷屏**而不是静默的视觉退化 —— 前者能被日志立刻抓到。
  final bool fadeGlass;

  @override
  State<AylaRevealItem> createState() => _AylaRevealItemState();
}

class _AylaRevealItemState extends State<AylaRevealItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  /// 已应用 [AylaRevealItem.curve] 的进度 —— **直接交给 `FadeTransition`/`AnimatedBuilder`**。
  ///
  /// 这样消费方（如 `AylaGlassSurface`）用 `FadeTransition(opacity: _curved)` 即可驱动
  /// `OpacityLayer`：**每帧不重建任何 widget**（对比「按颜色 × t 重建卡面」在实机
  /// 12+ 张卡同时入场时明显掉帧）。
  late final Animation<double> _curved =
      _controller.drive(CurveTween(curve: widget.curve));

  Timer? _delayTimer;
  int _replayTick = 0;
  bool _started = false;

  /// 玻璃档的**入场快照**（2026-09-30，查官方文档后落地）。
  ///
  /// 官方依据（`SnapshotWidget` 文档原话）：「a **frozen texture-backed representation** …
  /// useful for **short animations** that would otherwise be expensive or that cannot rely
  /// on raster caching … **as are blurs** … can be **replaced with a snapshot of itself and
  /// manipulated instead」。
  ///
  /// 它同时解决两件事：
  /// ① **变色** —— Impeller 拒绝把继承 opacity 传给 `BackdropFilter`，直接整层 `Opacity`
  ///    会让**模糊保持满强度、只有面层变淡**（实机「动画过程中变色」）；快照把模糊层冻进
  ///    纹理 ⇒ opacity 作用在纹理上 ⇒ **与 web 的整层 opacity 等价**；
  /// ② **性能** —— 入场期间移动的是纹理 ⇒ **不再每帧重采样 + 重模糊**（web 靠合成层纹理
  ///    缓存，这就是 Flutter 的等价物）。实测 raster 收益 **22×**
  ///    （`test/tmp_snapshot_gain_probe_test.dart`，软件光栅化对照）。
  ///
  /// 冻结范围 = `AylaGlassSurface` 的**背底层**（`glass.dart` 的 `useSnapshot` 分支）；
  /// 卡面与阴影留在快照之外、由外层整层 `Opacity` 统一淡入。
  SnapshotController? _snapshot;

  /// 入场期间是否把快照下发给玻璃子树（[AylaRevealProgress.snapshot]）。
  ///
  /// ⚠️ **解冻 = 把 `snapshot` 传回 null（整棵快照子树被替换），而不是
  /// `allowSnapshotting = false`**（2026-09-30 实机「卡片就位时消失」的根治）：
  /// 后者让 `SnapshotWidget` 在**同一棵子树**里从「画纹理」切回「画 child」，而
  /// `_RenderSnapshotWidget._paintAndDetachToImage` 用**独立离屏 `OffsetLayer`** 捕获，
  /// 捕获后 `offsetLayer.dispose()` 会连同被 detach 进来的 repaint-boundary layer 一起销毁
  /// （`snapshot_widget.dart:297–321`）⇒ 解冻时该 RenderObject 的 `_needsPaint` 已为 false，
  /// 重新附加的是**已 dispose 的空 layer**，真实引擎上那一帧可能什么都画不出来。
  /// 传 null 则由 `glass.dart` 的槽位结构接管：槽位（背底层 / 阴影 / 卡面）不变，
  /// 只有 slot0 换内容 ⇒ 必然全量重绘，且卡面 element 稳定复用（调用方 State 不丢）。
  ///
  /// 用 [ValueNotifier] 而非 `setState`：解冻发生在动画 tick 的监听器里
  /// （`_onProgress`），而 `_syncReplayTick` 在 **build 期间**也要重新冻结 ——
  /// `setState` 在 build 里非法，`ValueNotifier` 只通知自己的监听者。
  final ValueNotifier<bool> _snapshotting = ValueNotifier<bool>(false);

  /// 「错峰启用快照」的定时器（见 [_installSnapshot]）。
  Timer? _bootTimer;

  /// 最近的 [AylaRevealScopeState]（提供**批次动画时间原点**，见 [noteBatchMember]）。
  AylaRevealScopeState? _scope;

  bool get _reduceMotion =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  /// 本项入场的 stagger 延迟（[`_startEntry`] / [`_syncReplayTick`] 同一推导）。
  Duration _entryDelay(_AylaRevealScopeData? data) =>
      widget.delay ??
      AylaRevealMotion.staggerDelay(
        widget.index,
        staggerMs: data?.staggerMs ?? AylaRevealMotion.staggerMs,
        capMs: data?.maxStaggerMs ?? AylaRevealMotion.maxStaggerMs,
      );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 不能在 initState 读 MediaQuery（本项目已踩过两次）→ 首帧决策放这里。
    final _AylaRevealScopeData? data = _AylaRevealScopeData.maybeOf(context);
    _scope = context.findAncestorStateOfType<AylaRevealScopeState>();
    if (!_started) {
      _started = true;
      // 只在首帧记录基线 tick：后续的重播对比必须留给 build 里的
      // _syncReplayTick（若在这里覆盖 tick，重播会被自己吃掉——实测踩过）。
      _replayTick = data?.replayTick ?? 0;
      _startEntry(data);
      _installSnapshot();
    }
  }

  /// 玻璃档：入场期间冻结背底层（**不等 postFrame**）+ **按 index 错峰启用**。
  ///
  /// 为什么不等一帧：`_RenderSnapshotWidget.paint` 在 `_childRaster == null` 时
  /// **当帧捕获并当帧使用**（`snapshot_widget.dart:346–361`）⇒ 启用帧就有纹理。
  /// 等一帧会让入场首帧露出「模糊满强度」的卡块 —— 正是 web 没有、用户实报的「空态帧」。
  /// （若首帧尺寸还是 0，`paint` 会跳过捕获，下一帧自动补 —— 自带自愈。）
  ///
  /// ⚠️ **错峰**（2026-09-30 实机「出现全部卡片时掉帧」）：捕获是**同步离屏渲染**
  /// （`_paintAndDetachToImage`），发生在子树首次 paint 那一帧。列表里第
  /// `cap/staggerMs` 张之后的卡共用同一个 `delay`（`min(i*50, 300)`）⇒ 若全部同帧启用，
  /// 就是「N 张卡同帧捕获」的峰值帧。这里按 index 每 ~8ms 放行一张（60Hz 下每帧 1–2 张），
  /// 且**必须早于本卡可见时刻**（留 1 帧余量）—— 宁可退回「立即启用」也不让首帧走实时模糊。
  void _installSnapshot() {
    if (widget.fadeGlass) return;
    // 不播入场的三档（禁用 / reduced-motion / 滚动恢复抑制）在 [_startEntry] 里
    // 直接把进度置 1 ⇒ 此时装快照会**永远等不到解冻**（没有 tick 触发 `_onProgress`）
    // ⇒ 卡内内容再也不会更新。故先判进度。
    if (_curved.value >= 1.0) return;
    _snapshot = SnapshotController(allowSnapshotting: true);
    _curved.addListener(_onProgress);
    // ⚠️ **按 index 错峰启用捕获**（用户「不是掉帧，是好好的动画顿了一下」的既有
    // 结构性原因）：列表里第 `cap/staggerMs` 张之后的卡共用同一 delay
    // （`min(i*50, 300)`）⇒ 它们的**首次绘制在同一帧** ⇒ 那一帧要跑 N 次 backdrop 模糊
    // （web 靠浏览器合成器缓存，Flutter 每次都得真算）⇒ raster 峰值 = 那「一帧的顿」。
    // 错峰即：让每张卡在**本卡 delay 结束前**、按 8ms 步长依次完成预捕获
    // （捕获只需子树被 paint 一次 —— 由上面的 `kAylaInvisibleButPainted` 提供）。
    final Duration entryDelay = _entryDelay(_AylaRevealScopeData.maybeOf(context));
    final Duration stagger = Duration(milliseconds: widget.index * 8);
    const int oneFrameMs = 17;
    if (widget.index == 0 ||
        entryDelay.inMilliseconds < stagger.inMilliseconds + oneFrameMs) {
      _snapshotting.value = true;
      return;
    }
    _bootTimer = Timer(stagger, () {
      if (mounted && _curved.value < 1.0) _snapshotting.value = true;
    });
  }

  /// 入场结束 ⇒ 解冻（[AylaRevealProgress.snapshot] 传回 null ⇒ 结构切回普通档）。
  ///
  /// 只触发一次：切换后 `_snapshotting.value` 已是 false，后续 tick 直接返回。
  void _onProgress() {
    if (!_snapshotting.value) return;
    if (_curved.value >= 1.0) _snapshotting.value = false;
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
    // web 的 `replayKey` 变化会对**已入场节点整批重播**，且 `index` 重新从 0 计数 ⇒
    // 重播**同样带 stagger**（`useListEntryMotion.ts:38–48` 的 `delay: staggerDelay(index++)`）。
    // 此前这里直接 `forward()` ⇒ 整批同时闪动，与 web 的逐条节奏不符（用户 2026-09-30 实报）。
    _controller.value = 0;
    // 重播同样受益于快照 ⇒ 重新冻结。⚠️ 这里在 **build 期间**（`_syncReplayTick` 由 build 调用），
    // 直接改 [ValueNotifier] 会让 `ValueListenableBuilder` 在 build 中 setState ⇒ 挪到帧后。
    if (!widget.fadeGlass && _snapshot != null && !_snapshotting.value) {
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (mounted && _curved.value < 1.0) _snapshotting.value = true;
      });
    }
    final _AylaRevealScopeData? data = _AylaRevealScopeData.maybeOf(context);
    // ⚠️ **重播用「重播序号」而不是列表下标**（2026-09-30 实机「看着就像停顿」的根因）：
    // web 的 `useListEntryMotion.ts:38–48` 在重播时对**已入场节点**重新 `let index = 0`，
    // 所以 20 张卡重播是 0/50/…/300/300…（前 7 张依次浮现）；若沿用列表下标（第 7 张起
    // 已是 cap 300ms），最后十几张会**同时**重播 ⇒ 一次性成本 + 与 web 节奏不符 = 停顿感。
    final int replayIndex = _scope?.nextReplayIndex() ?? 0;
    final Duration delay = widget.delay ??
        AylaRevealMotion.staggerDelay(
          replayIndex,
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
    // ⚠️ **与 web 逐帧一致的时序**（2026-09-30 实机：「不是掉帧，是很流畅的，但是好好的
    // 动画就是顿了一下，一定是和 web 实现有差异」）：
    // web 的 `.reveal-item` 是 `animation: … var(--auroraqua-duration) ; animation-delay: Nms`
    // ⇒ **delay 从元素拿到类那一刻起算**，且**所有卡是同一帧拿到类** ⇒ 共享同一起点。
    // 这里同义：`Timer(delay)` 后 `forward()`（delay 期内 `Opacity(0)` = CSS 的
    // `fill: backwards`，都是「第一帧的样子」）。
    // ⚠️ **不要引入「批次时间原点追赶」**（曾试过）：分帧挂载时它会让后挂载的卡
    // **从中间进度开始**，视觉上是「跳一下」而不是「淡入」—— 用户当场看出与 web 的差异。
    final Duration delay = _entryDelay(data);
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
    _bootTimer?.cancel();
    _delayTimer?.cancel();
    _curved.removeListener(_onProgress);
    _snapshotting.dispose();
    _snapshot?.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 依赖重建时 didChangeDependencies 会先跑（但不覆盖 tick）→ 这里对比触发重播。
    _syncReplayTick(_AylaRevealScopeData.maybeOf(context)?.replayTick ?? _replayTick);
    if (!widget.enabled || _reduceMotion) return widget.child;
    // ⚠️ **统一整层 opacity**（2026-09-30 用户裁决「一比一还原 web」）。
    //
    // web 的 `.reveal-item`（`base.css:495–499`）与 `auroraqua-*-in`（`auroraqua.css:8–26`）
    // 都是**整层 opacity**：卡片本体、**卡片之外的浮层**（收藏/分享键等）、
    // 玻璃滤镜层**一起**淡入。
    //
    // 此前按 `fadeGlass` 分流（玻璃档只位移、淡入交给玻璃件自表达）会漏掉**玻璃件之外**
    // 的元素 ⇒ 实机出现「只有爱心浮在空背景上」的**空态帧**（用户截图；web 没有这一帧）。
    // ⇒ 无条件整层 `Opacity`（`fadeGlass` **仍然分流**：玻璃档额外套一层
    // [SnapshotWidget]，让 opacity 作用在**冻结纹理**上而不是 `BackdropFilter` 祖先上 ——
    // 见 [_installSnapshot] 的注释：这样模糊会**跟着一起淡**（不再「变色」），
    // 位移也只移动纹理（不再每帧重采样）。
    //
    // 代价：`Opacity` 祖先 + `BackdropFilter` 后代触发 Impeller 的 **debug 期**校验日志
    //（release 无）。快照档下只持续到捕获完成的那一帧。
    final Widget moved = AnimatedBuilder(
      // alpha 只依赖 `_curved`（见上面的注释）⇒ 回到最朴素的每帧重建。
      animation: _curved,
      builder: (BuildContext context, Widget? child) {
        final double t = _curved.value;
        // 玻璃档在**进度为 0 且快照已下发**时用「不可见但会被绘制」的 alpha：
        // 让它在本卡 delay 期内就完成一次 `SnapshotWidget` 捕获 ⇒ 那一帧的
        // backdrop 模糊提前到**卡片还看不见的时候**、并按 index 错峰 ⇒ 削掉
        // 「同一 delay 的一批卡在同帧首次绘制」的 raster 峰值。
        // 视觉上 0.001 ≈ 0.4/255，与 web 的 `fill: backwards`（opacity 0）不可辨。
        final double alpha =
            !widget.fadeGlass && _snapshotting.value && t <= 0
                ? kAylaInvisibleButPainted
                : t;
        return Opacity(
          opacity: alpha,
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
    // 玻璃档：把进度与快照 controller 一起下发 —— 快照由 `AylaGlassSurface` 在**件内部**
    // 使用（只包「模糊层 + 卡面」，**阴影留在快照之外**，否则会被快照的边界裁掉，
    // 表现为「阴影等卡片就位了才渲染」）。整棵子树仍由上面的 `Opacity` 统一淡入，
    // 因此卡片外的浮层（收藏/分享键）也一起淡入。
    if (widget.fadeGlass) return moved;
    // 只在冻结↔解冻切换时重建 [AylaRevealProgress]（`moved` 作为 child 复用，
    // 内部仍由自己的 `AnimatedBuilder` 每帧驱动）⇒ **入场期间不重建任何玻璃件**。
    return ValueListenableBuilder<bool>(
      valueListenable: _snapshotting,
      builder: (BuildContext context, bool frozen, Widget? child) {
        return AylaRevealProgress(
          progress: _curved,
          // 冻结期间下发 controller（玻璃件把背底层冻成纹理）；
          // 解冻即传 null ⇒ 结构切回普通档（见 [_snapshotting] 的注释）。
          snapshot: frozen ? _snapshot : null,
          child: child!,
        );
      },
      child: moved,
    );
  }
}
