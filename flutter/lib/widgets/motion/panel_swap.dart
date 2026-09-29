/// 面板换场动画 —— web `hooks/useTabPanelMotion.ts` / `hooks/usePanelSwapMotion.ts`
/// 的 Flutter 等价物（**1:1**，含两者不同的基线推进语义）。
///
/// 两档都**不重挂**子树（web 原文：`No key, duplicate panel, or remount is introduced:`
/// `sessions, drafts and scroll owners remain with their current components`）——
/// 只在 **identity 变化**时对同一棵子树**就地重播**一段动画。
///
/// | 档 | web 调用点 | 动画 |
/// |---|---|---|
/// | [AylaPanelSwapMode.tab] | `GroupChat.tsx:120–125` 的消息区 | **300ms**：`opacity 0 / x **+20**` → `1 / 0`，缓动 `easeInOut`（`AURORAQUA_MOTION.duration * 1000`）|
/// | [AylaPanelSwapMode.swap] | `GroupChat.tsx:126` 的输入框 | **600ms 双段**：起点（当前样式）→ 0.5 处 `opacity 0 / y **+20**` → 1 处 `1 / 0`，**每段** `easeOut`（`duration * 2000`）|
///
/// ## 基线推进（两条 hook 有意不同，别统一）
/// - **tab 档** = `useTabPanelMotion.ts:28–31`：`if (!ready) return;` 在推进 `previous.current`
///   **之前** ⇒ not-ready 期间基线**冻结**，数据到位后 `changed` 仍为真 ⇒ **补播**；
///   另有 `establishBaseline`（`:24–27`）⇒ 该帧只记基线、不播（首次选中默认组不算「变化」）。
/// - **swap 档** = `usePanelSwapMotion.ts:12–13`：`previous.current = identity` 在 `!enabled`
///   **检查之前** ⇒ 基线**始终推进**、没有补播（保住草稿/焦点，只求「原地抖一下」）。
///
/// ## 公开面
/// `AylaPanelSwapMode` · `AylaPanelSwap` · `aylaPanelSwapSamples()`
library;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';

/// 换场档（见文件头对照表）。
enum AylaPanelSwapMode {
  /// web `useTabPanelMotion`：300ms，`opacity 0 / x +20` → `1 / 0`（easeInOut）。
  tab,

  /// web `usePanelSwapMotion`：600ms 双段，下移淡出（`y +20`）后回位淡入（每段 easeOut）。
  swap,
}

/// 就地重播的换场包装件（**不重挂** [child]）。
class AylaPanelSwap extends StatefulWidget {
  const AylaPanelSwap({
    super.key,
    required this.identity,
    required this.child,
    this.mode = AylaPanelSwapMode.tab,
    this.enabled = true,
    this.establishBaseline = false,
  });

  /// 换场身份（web 的 `selection` / `subgroupSelection`，如 `"<groupId>:<subgroupId>"`）。
  final String identity;

  /// 子树（不重挂：草稿、焦点、滚动 owner 都留在原组件里）。
  final Widget child;

  /// 换场档。
  final AylaPanelSwapMode mode;

  /// web 的 `ready`（tab 档）/ `enabled`（swap 档）—— false 时不播。
  final bool enabled;

  /// web `useTabPanelMotion.ts:24–27`：本帧只把 [identity] 记为基线、**不播**
  /// （首次选中默认组那一帧不算「变化」）。
  final bool establishBaseline;

  /// `AURORAQUA_MOTION.distance` = 20（两档同位移量）。
  static const double distance = 20;

  /// 档位时长：tab = 300ms（`duration * 1000`）、swap = 600ms（`duration * 2000`）。
  static Duration durationOf(AylaPanelSwapMode mode) => mode == AylaPanelSwapMode.tab
      ? AylaDurations.auroraqua
      : const Duration(milliseconds: 600);

  @override
  State<AylaPanelSwap> createState() => _AylaPanelSwapState();
}

class _AylaPanelSwapState extends State<AylaPanelSwap>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: AylaPanelSwap.durationOf(widget.mode),
    value: 1, // 静止态 = center
  );

  /// 上一次的换场身份（web 的 `previous.current`）。
  ///
  /// ⚠️ **必须在 `initState` 里赋值，不能用 `late ... = widget.identity` 的惰性初始化**：
  /// 惰性初始化只在**首次读取**时求值，而首次读取就发生在 `didUpdateWidget` 内 ——
  /// 那一刻 `widget` 已经是**新**的 identity ⇒ `_baseline` 直接等于新值 ⇒
  /// `changed` 恒为 false、动画永不播（本轮被 `panel_swap_test.dart` 抓到）。
  late String _baseline;

  bool get _reduced => MediaQuery.disableAnimationsOf(context);

  @override
  void initState() {
    super.initState();
    _baseline = widget.identity;
  }

  @override
  void didUpdateWidget(covariant AylaPanelSwap old) {
    super.didUpdateWidget(old);
    if (old.mode != widget.mode) {
      _c.duration = AylaPanelSwap.durationOf(widget.mode);
    }
    if (widget.establishBaseline) {
      _baseline = widget.identity; // 只记基线
      return;
    }
    // tab 档：not-ready 期间**冻结**基线（`if (!ready) return;` 在推进之前）；
    // swap 档：基线**始终推进**（`previous.current = identity` 在 `!enabled` 检查之前）。
    if (widget.mode == AylaPanelSwapMode.tab && !widget.enabled) return;
    final bool changed = widget.identity != _baseline;
    _baseline = widget.identity;
    if (!changed || !widget.enabled || _reduced) return;
    _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_reduced) return widget.child;
    return AnimatedBuilder(
      animation: _c,
      builder: (BuildContext context, Widget? child) {
        final double t = _c.value;
        if (widget.mode == AylaPanelSwapMode.tab) {
          // useTabPanelMotion：opacity 0 / x +20 → 1 / 0（easeInOut）
          final double p = AylaCurves.auroraquaEaseInOut.transform(t);
          return Opacity(
            opacity: p,
            child: Transform.translate(
              offset: Offset(AylaPanelSwap.distance * (1 - p), 0),
              child: child,
            ),
          );
        }
        // usePanelSwapMotion：0 → 0.5（下移淡出 y +20）→ 1（回位淡入），每段 easeOut
        final bool outbound = t <= 0.5;
        final double p = AylaCurves.auroraquaEaseOut.transform(
          outbound ? t * 2 : (t - 0.5) * 2,
        );
        return Opacity(
          opacity: outbound ? 1 - p : p,
          child: Transform.translate(
            offset: Offset(0, AylaPanelSwap.distance * (outbound ? p : 1 - p)),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

// ======================= 画布样张（可交互） =======================

/// 画布/预览用**可交互**样张：点「切下一个 identity」看两档就地重播。
Widget aylaPanelSwapSamples() => const _PanelSwapDemo();

class _PanelSwapDemo extends StatefulWidget {
  const _PanelSwapDemo();

  @override
  State<_PanelSwapDemo> createState() => _PanelSwapDemoState();
}

class _PanelSwapDemoState extends State<_PanelSwapDemo> {
  int _n = 0;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    Widget card(String label) => AylaGlassSurface(
          radius: AylaRadii.rCard,
          blur: AylaGlass.blurCard,
          shadow: AylaShadows.glass,
          padding: const EdgeInsets.all(AylaSpacing.sp3),
          child: Text(label, style: t.body),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AylaSpacing.sp3,
      children: <Widget>[
        Text(
          '身份 = 子群 ${_n + 1}（点键切换 → 两档各自就地重播，子树不重挂）',
          style: t.caption.copyWith(color: AylaColors.textSecondary),
        ),
        AylaGlassButton(
          label: '切下一个 identity',
          variant: AylaGlassButtonVariant.ghost,
          onPressed: () => setState(() => _n += 1),
        ),
        AylaPanelSwap(
          identity: 'sg-$_n',
          mode: AylaPanelSwapMode.tab,
          child: card('tab 档（消息区）：300ms opacity 0 / x +20 → 1 / 0'),
        ),
        AylaPanelSwap(
          identity: 'sg-$_n',
          mode: AylaPanelSwapMode.swap,
          child: card('swap 档（输入框）：600ms 下移淡出 y +20 后回位淡入'),
        ),
      ],
    );
  }
}
