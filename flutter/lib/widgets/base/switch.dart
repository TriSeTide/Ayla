/// 通用开关（视觉胶囊 Switch）—— 由群信息域 `AylaGroupInfoSwitch`（正确基准）提升为公共件。
///
/// ## 两档事实源（各自独立，**不可混搭**）
/// ```
/// 【compact · 群档】GroupInfo.tsx:584–599 + group.css 1924–1993
///   .group-info-switch-ui     44×24 · position: relative（**容器无边框**）
///   .group-info-switch-track  44×24 · radius pill · background --ice-300 · box-shadow --glass-inset
///   .group-info-switch-thumb  absolute top 3 / left 3 · 18×18 · radius 50% · --surface
///                             + 0 1px 3px rgba(70,91,146,.3)
///   :checked    ⇒ 轨道 --pink-500 · thumb translateX(20px)（left 3 → 23）
///   :disabled   ⇒ 轨道 opacity .6
///   :focus-vis. ⇒ outline var(--focus-ring)（glow-500 2px）· offset 2
///
/// 【regular · 个人档】ProfilePage.tsx:261–278 + profile.css 400–434
///   .profile-switch      48×28 · radius pill · **1px var(--glass-border)** ·
///                        background var(--glass-bg-strong)（**无 backdrop-filter**）
///   .profile-switch-knob absolute top 3 / left 3 · 20×20 · radius pill · --ice-300
///   .is-on        ⇒ 轨道 --sakura-300 + --glow-shadow · thumb --grape-700 + translateX(20px)
///   :focus-visible ⇒ outline var(--focus-ring) · offset 2
///   ```
///
/// ## ⚠️ 1px 边框补偿（用户当场点名的「圆点没上下居中」根因，别再退回）
/// `base.css:6–7` 全局 `* { box-sizing: border-box }` ⇒ `.profile-switch` 的 48×28 **含** 1px 边框；
/// 而 CSS 绝对定位子级的包含块是**padding box**（边框内侧）⇒ `top: 3px / left: 3px` 实际落在距
/// **外框 4px** 处：knob 中心 = 4 + 10 = **14** = 28/2 ✓，`translateX(20px)` 后右侧间隙
/// = 48 − (24 + 20) = **4** ✓（左右对称）。
/// 本库先前把 3 / 23 当成外框坐标 ⇒ knob 中心 = 3 + 10 = 13 ≠ 轨道中心 14 ⇒ **圆点偏上 1px**。
/// ⇒ 本件把「边框宽度」显式加进偏移（[AylaSwitchVariant.regular] 用 4 / 24），
/// 由 `test/switch_test.dart` 的「knob 中心 vs 轨道中心」断言锁死（1px 容差，实测差 0）。
/// compact 档的容器**无边框** ⇒ 偏移仍是 3 / 23（thumb 中心 12 = 24/2 ✓）。
///
/// ## 点击语义（label 转发）
/// web 两处开关都被 `<label>` 包住（`GroupInfo.tsx:585` / `ProfilePage.tsx:261`）⇒ 点整行与点控件
/// 是**同一次**切换。Flutter 若「整行手势 + 控件手势」会各触发一次（净效果 = 状态翻回原位）⇒
/// 行装配的调用方传 `ownTap: false`（本体只保留 Focus 键盘 Enter/Space，不挂手势）。
///
/// ## 公开面
/// `AylaSwitch` · `AylaSwitchVariant` · `AylaSwitchMetrics` · `kAylaSwitchTrackKey` ·
/// `kAylaSwitchKnobKey` · `kAylaSwitchFocusRingKey` · `aylaSwitchSamples()`
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';

/// 轨道测试锚点（几何断言用：量「轨道中心」与「knob 中心」）。
const Key kAylaSwitchTrackKey = Key('aylaSwitchTrack');

/// 滑钮测试锚点。
const Key kAylaSwitchKnobKey = Key('aylaSwitchKnob');

/// focus 环测试锚点（仅聚焦时存在）。
const Key kAylaSwitchFocusRingKey = Key('aylaSwitchFocusRing');

/// 开关档位（两档各自对应一处 web 事实源，见库头注释）。
enum AylaSwitchVariant {
  /// 群信息域档：`.group-info-switch-track` / `-thumb`（44×24 · thumb 18）。
  compact,

  /// 个人主页域档：`.profile-switch` / `.profile-switch-knob`（48×28 · knob 20 · 1px 边框）。
  regular,
}

/// 一档开关的几何与材质度量（公开以便测试与调用方对账）。
class AylaSwitchMetrics {
  const AylaSwitchMetrics({
    required this.trackWidth,
    required this.trackHeight,
    required this.thumbSize,
    required this.knobTop,
    required this.knobLeft,
    required this.knobOnLeft,
    required this.disabledOpacity,
    required this.borderWidth,
    required this.usesInsetHighlight,
    required this.usesGlow,
  });

  /// 轨道宽（44 / 48）。
  final double trackWidth;

  /// 轨道高（24 / 28）。
  final double trackHeight;

  /// 滑钮边长（18 / 20）。
  final double thumbSize;

  /// 滑钮上偏移（**含 1px 边框补偿**：compact 3 / regular 4）。
  final double knobTop;

  /// 滑钮左偏移（off 态；compact 3 / regular 4）。
  final double knobLeft;

  /// 滑钮左偏移（on 态 = off + web 的 translateX(20px)；compact 23 / regular 24）。
  final double knobOnLeft;

  /// 禁用档整轨透明度（compact .6 / regular .55——两处 web 值不同，逐档照抄）。
  final double disabledOpacity;

  /// 容器边框宽（compact 0 / regular 1）。
  final double borderWidth;

  /// 是否铺 `--glass-inset` 顶沿内高光（compact 有 / regular 无）。
  final bool usesInsetHighlight;

  /// 选中是否叠 `--glow-shadow`（regular 有 / compact 无）。
  final bool usesGlow;

  /// 群档度量（`.group-info-switch-*`，group.css 1933–1993）。
  static const AylaSwitchMetrics compact = AylaSwitchMetrics(
    trackWidth: 44,
    trackHeight: 24,
    thumbSize: 18,
    knobTop: 3,
    knobLeft: 3,
    knobOnLeft: 23,
    disabledOpacity: 0.6,
    borderWidth: 0,
    usesInsetHighlight: true,
    usesGlow: false,
  );

  /// 个人档度量（`.profile-switch*/`，profile.css 400–434；含 1px 边框补偿）。
  static const AylaSwitchMetrics regular = AylaSwitchMetrics(
    trackWidth: 48,
    trackHeight: 28,
    thumbSize: 20,
    knobTop: 4, // = CSS top 3 + 1px 边框（padding box 基准）
    knobLeft: 4, // = CSS left 3 + 1px 边框
    knobOnLeft: 24, // = CSS left 3 + 20(translateX) + 1px 边框
    disabledOpacity: 0.55, // base.css button:disabled 兜底（profile 开关无 :disabled 规则）
    borderWidth: 1,
    usesInsetHighlight: false,
    usesGlow: true,
  );
}

/// 通用开关本体（轨道 + 滑钮 + focus 环 + 键盘）。
///
/// 行装配（label 转发）由调用方负责，见库头「点击语义」。
class AylaSwitch extends StatefulWidget {
  const AylaSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.variant = AylaSwitchVariant.compact,
    this.ownTap = true,
    this.semanticLabel,
    this.focusNode,
    this.ownSemantics = true,
  });

  /// 开关值（web `:checked` / `aria-checked`）。
  final bool value;

  /// 切换回调；null ⇒ 禁用档。
  final ValueChanged<bool>? onChanged;

  /// 档位（几何 + 材质，见 [AylaSwitchMetrics]）。
  final AylaSwitchVariant variant;

  /// 是否由本体处理点击。
  ///
  /// `false` ⇒ 由外层行（web 的 `<label>` 转发语义）代管点击：本件只保留 Focus
  /// （键盘 Enter/Space）与语义，**不挂手势**，避免与行手势各触发一次。
  final bool ownTap;

  /// 无障碍名称（web：label 文本；如「成员可上传表情包」/「向他人展示内容」）。
  final String? semanticLabel;

  /// 外部焦点节点（可空；不传则由本件自持）。画布样张用它主动请求焦点展示 focus 环。
  final FocusNode? focusNode;

  /// 是否由本件提供 `toggled` 语义（默认 true，独立使用档）。
  ///
  /// `false` ⇒ 由外层行统一提供（web 是 `<label>` 关联控件，语义树里只有一个可切换节点）；
  /// 行装配的调用方传 false，避免同一状态出现「行节点 + 控件节点」两个 toggled 节点。
  final bool ownSemantics;

  /// 本档度量。
  AylaSwitchMetrics get metrics => switch (variant) {
    AylaSwitchVariant.compact => AylaSwitchMetrics.compact,
    AylaSwitchVariant.regular => AylaSwitchMetrics.regular,
  };

  @override
  State<AylaSwitch> createState() => _AylaSwitchState();
}

class _AylaSwitchState extends State<AylaSwitch> {
  bool _focused = false;

  bool get _enabled => widget.onChanged != null;

  void _toggle() => widget.onChanged?.call(!widget.value);

  @override
  Widget build(BuildContext context) {
    final AylaSwitchMetrics m = widget.metrics;
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final Duration dur = reduceMotion ? Duration.zero : AylaDurations.fast;

    // ---------- 轨道 ----------
    // compact：--ice-300 → :checked --pink-500 + --glass-inset 顶沿内高光
    // regular：--glass-bg-strong + 1px --glass-border → .is-on --sakura-300 + --glow-shadow
    final Color trackColor = widget.value
        ? (widget.variant == AylaSwitchVariant.compact
              ? AylaColors.pink500 // :checked background
              : AylaColors.sakura300) // .profile-switch.is-on background
        : (widget.variant == AylaSwitchVariant.compact
              ? AylaColors.ice300 // .group-info-switch-track background
              : AylaGlassConfig.resolveBackground(strong: true)); // --glass-bg-strong

    Widget track = AnimatedContainer(
      key: kAylaSwitchTrackKey,
      duration: dur,
      curve: AylaCurves.easeOut,
      width: m.trackWidth,
      height: m.trackHeight,
      decoration: BoxDecoration(
        color: trackColor,
        borderRadius: AylaRadii.pill,
        border: m.borderWidth == 0
            ? null
            : Border.all(color: AylaColors.glassBorder),
        // .profile-switch.is-on { box-shadow: var(--glow-shadow) }（profile.css 423–426）
        // ⚠️ **不降 30%**：≤768 的辉光降档只在 app.css 3195–3199、选择器仅
        // `.btn-glow / .avatar-halo.is-elysia / .elysia-entry:hover`；`--glow-shadow` 全仓只在
        // tokens.css:73 定义一次、profile.css 的 5 条 .profile-switch 规则全在顶层无媒体覆写
        // ⇒ 个人档开关在窄屏仍是 16px / .45（2026-09-28 独立审计抓到的覆盖关系误判，已修；
        // design.md §9 的通用「≤768 降 30%」说法与 web 实际不符，登记为待裁决）。
        boxShadow: widget.value && m.usesGlow ? AylaShadows.glow : null,
      ),
      child: m.usesInsetHighlight
          // box-shadow: var(--glass-inset) —— 顶沿 1px 内高光（stops = 1/height）
          ? ClipRRect(
              borderRadius: AylaRadii.pill,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: AylaInset.topHighlight(m.trackHeight),
                ),
              ),
            )
          : null,
    );

    // ---------- 滑钮 ----------
    // compact：--surface + 0 1px 3px rgba(70,91,146,.3) · off --ice-300 → on 保持 --surface
    // regular：--ice-300 → :checked --grape-700（无自身阴影）
    final Widget knob = AnimatedContainer(
      key: kAylaSwitchKnobKey,
      duration: dur,
      curve: AylaCurves.easeOut,
      width: m.thumbSize,
      height: m.thumbSize,
      decoration: BoxDecoration(
        color: widget.variant == AylaSwitchVariant.compact
            ? AylaColors.surface // .group-info-switch-thumb background
            : (widget.value
                  ? AylaColors.grape700 // .is-on .knob background
                  : AylaColors.ice300), // .profile-switch-knob background
        borderRadius: m.usesInsetHighlight
            ? BorderRadius.circular(AylaRadii.rPill)
            : AylaRadii.pill,
        boxShadow: m.usesInsetHighlight
            ? const <BoxShadow>[
                // box-shadow: 0 1px 3px rgba(70,91,146,.3)（滑钮自身阴影，非玻璃环）
                BoxShadow(
                  color: Color(0x4D465B92),
                  blurRadius: 3,
                  offset: Offset(0, 1),
                ),
              ]
            : null,
      ),
    );

    // ---------- 轨道 + 滑钮 + focus 环 ----------
    Widget rail = SizedBox(
      width: m.trackWidth,
      height: m.trackHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          track,
          AnimatedPositioned(
            duration: dur,
            curve: AylaCurves.easeOut,
            // ⚠️ 偏移已含 1px 边框补偿（见库头）：regular = 4 / 24，compact = 3 / 23。
            left: widget.value ? m.knobOnLeft : m.knobLeft,
            top: m.knobTop,
            child: knob,
          ),
          // :focus-visible { outline: var(--focus-ring); outline-offset: 2px }
          // outline 2px + offset 2 ⇒ 外扩 4；环不吃指针、不参与布局（库内约定）。
          if (_focused && _enabled)
            Positioned(
              key: kAylaSwitchFocusRingKey,
              left: -4,
              top: -4,
              right: -4,
              bottom: -4,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: AylaColors.glow500, width: 2),
                    borderRadius: BorderRadius.circular(AylaRadii.rPill + 2),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    // :disabled ⇒ 整轨 opacity（compact .6 / regular .55，逐档照抄）
    if (!_enabled) {
      rail = Opacity(opacity: m.disabledOpacity, child: rail);
    }

    // ---------- 交互壳（Focus + 语义 [+ 手势]）----------
    Widget shell = Focus(
      focusNode: widget.focusNode,
      onFocusChange: (bool has) => setState(() => _focused = has),
      onKeyEvent: (FocusNode node, KeyEvent event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final bool activate =
            event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.space;
        if (!activate || !_enabled) return KeyEventResult.ignored;
        _toggle();
        return KeyEventResult.handled;
      },
      child: rail,
    );

    if (widget.ownTap) {
      shell = MouseRegion(
        cursor: _enabled
            ? SystemMouseCursors.click // cursor: pointer
            : SystemMouseCursors.forbidden, // :disabled cursor: not-allowed（Flutter 最近等价物）
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _enabled ? _toggle : null,
          child: shell,
        ),
      );
    }

    if (!widget.ownSemantics) return shell;

    return Semantics(
      toggled: widget.value, // role=switch + aria-checked / input:checked
      enabled: _enabled,
      label: widget.semanticLabel,
      child: shell,
    );
  }
}

/// 画布样张（两档 × 各状态）。
Widget aylaSwitchSamples() => const _SwitchSamplesDemo();

class _SwitchSamplesDemo extends StatefulWidget {
  const _SwitchSamplesDemo();

  @override
  State<_SwitchSamplesDemo> createState() => _SwitchSamplesDemoState();
}

class _SwitchSamplesDemoState extends State<_SwitchSamplesDemo> {
  bool _compactOff = false;
  bool _compactOn = true;
  bool _regularOff = false;
  bool _regularOn = true;
  bool _row = true;
  int _rowTaps = 0;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Widget _label(String text) => Text(
    text,
    style: const TextStyle(
      fontSize: 12,
      color: AylaColors.textSecondary,
      fontFamily: 'SpaceGrotesk',
    ),
  );

  Widget _cell(String caption, Widget child) => Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      child,
      const SizedBox(height: 6),
      _label(caption),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('① compact 群档（.group-info-switch 44×24 · thumb 18）', style: t.body),
        const SizedBox(height: 12),
        Wrap(
          spacing: 32,
          runSpacing: 16,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: <Widget>[
            _cell(
              'off',
              AylaSwitch(
                value: _compactOff,
                semanticLabel: 'compact off',
                onChanged: (bool v) => setState(() => _compactOff = v),
              ),
            ),
            _cell(
              'on（粉轨）',
              AylaSwitch(
                value: _compactOn,
                semanticLabel: 'compact on',
                onChanged: (bool v) => setState(() => _compactOn = v),
              ),
            ),
            _cell(
              'disabled（整轨 .6）',
              const AylaSwitch(
                value: false,
                semanticLabel: 'compact disabled',
                onChanged: null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text('② regular 个人档（.profile-switch 48×28 · knob 20 · 1px 边）', style: t.body),
        const SizedBox(height: 12),
        Wrap(
          spacing: 32,
          runSpacing: 16,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: <Widget>[
            _cell(
              'off',
              AylaSwitch(
                value: _regularOff,
                variant: AylaSwitchVariant.regular,
                semanticLabel: 'regular off',
                onChanged: (bool v) => setState(() => _regularOff = v),
              ),
            ),
            _cell(
              'on（樱粉底 + 辉光）',
              AylaSwitch(
                value: _regularOn,
                variant: AylaSwitchVariant.regular,
                semanticLabel: 'regular on',
                onChanged: (bool v) => setState(() => _regularOn = v),
              ),
            ),
            _cell(
              'disabled（.55）',
              const AylaSwitch(
                value: true,
                variant: AylaSwitchVariant.regular,
                semanticLabel: 'regular disabled',
                onChanged: null,
              ),
            ),
            _cell(
              'focus 环（--focus-ring offset 2）',
              AylaSwitch(
                value: _regularOff,
                variant: AylaSwitchVariant.regular,
                focusNode: _focusNode,
                semanticLabel: 'regular focus',
                onChanged: (bool v) => setState(() => _regularOff = v),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text('③ 行装配（label 转发：整行一次手势，ownTap: false）', style: t.body),
        const SizedBox(height: 12),
        SizedBox(
          width: 420,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _row
                  ? () => setState(() {
                      _row = !_row;
                      _rowTaps++;
                    })
                  : null,
              child: Row(
                children: <Widget>[
                  const Expanded(
                    child: Text(
                      '成员可上传表情包',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AylaColors.textPrimary,
                      ),
                    ),
                  ),
                  AylaSwitch(
                    value: _row,
                    ownTap: false,
                    semanticLabel: '成员可上传表情包',
                    onChanged: (bool v) => setState(() {
                      _row = v;
                      _rowTaps++;
                    }),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        _label('点击次数 = $_rowTaps（一次点击只应 +1）'),
        const SizedBox(height: 8),
        _label(
          '④ focus 环锚点：$kAylaSwitchFocusRingKey —— 上方第 4 格已用 FocusNode 请求焦点',
        ),
      ],
    );
  }
}
