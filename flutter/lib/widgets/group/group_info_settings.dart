/// 群信息**设置面**（web `pages/group/GroupInfo.tsx:531–624 / 709–718 / 754` +
/// `styles/group.css 1678–1687 / 1796–1826 / 1923–2047 / 2109–2116`）。
///
/// ## 事实源（逐条 web 文件:行 → 数值/结构）
/// ```
/// GroupInfo.tsx 531–583   div.group-info-settings > div.group-info-setting-row（「加入方式」）：
///                         owner ⇒ span.group-info-select-wrap > button.group-info-select-btn
///                           （aria-haspopup=listbox / aria-expanded / Escape 关闭）
///                           > span 文案 + IconChevronDown 14（.group-info-select-btn-arrow[.is-open]）
///                           + div.group-info-select-menu[role=listbox] > button.group-info-select-option[role=option]
///                             > IconCheck 14(.group-info-select-check) + span 文案
///                         非 owner ⇒ span.group-info-setting-value（只读值）
/// group.css 1796–1802     .group-info-settings：flex column · **padding 0 sp3** · radius-input ·
///                         background rgba(157,191,230,.1)
/// group.css 1804–1810     .group-info-setting-row：flex · align-items center · justify-content space-between ·
///                         gap sp3(12) · **min-height 44**
/// group.css 1812–1814     .group-info-setting-row + .group-info-setting-row { border-top: 1px rgba(157,191,230,.22) }
///                         （**相邻兄弟选择器 ⇒ 首行无上边线**）
/// group.css 1816–1820     .group-info-setting-label：14 / w600 / --text-primary
/// group.css 1822–1826     .group-info-setting-value：13 / --text-secondary / white-space nowrap
/// group.css 1829–1833     .group-info-select-wrap：relative · inline-flex · flex none
/// group.css 1835–1851     .group-info-select-btn：inline-flex · center · gap sp2 · min-height 32 ·
///                         padding 4px 10px 4px 14px · radius pill · 1px rgba(157,191,230,.55) ·
///                         background linear-gradient(135deg, rgba(157,191,230,.22), rgba(249,176,255,.14)) ·
///                         color --indigo-700 · --font-body 13 / w700 · cursor pointer ·
///                         transition border-color+background 180ms ease-out
///                         ⚠️ 该按钮**在 auroraqua 按钮组内**（auroraqua.css 55–62 的 :is() 名单）⇒
///                         200ms 组过渡 + hover scale 1.02 + active .98 + ::after 扫光
/// group.css 1853–1861     :hover:not(:disabled) ⇒ border-color --ice-500 + 渐变增强(.32/.2)；
///                         :disabled ⇒ cursor not-allowed + opacity .6
/// group.css 1863–1870     .group-info-select-btn-arrow：color --text-secondary · transition transform 180ms；
///                         .is-open ⇒ rotate(180deg)
/// group.css 1872–1888     .group-info-select-menu：absolute top calc(100% + 6px) / **right 0** · min-width 148 ·
///                         padding sp1 · radius-card 16 · background --glass-bg-strong ·
///                         backdrop-filter --glass-filter(blur24 sat1.4) · 1px --glass-border · --glass-shadow ·
///                         z-index 40 · flex column · gap 2px
/// group.css 1890–1904     .group-info-select-option：flex · center · gap sp2 · min-height 36 · padding 0 sp3 ·
///                         radius-sm 8 · color --text-primary · --font-body 13 / w600 · transition background 180ms
/// group.css 1906–1908     :hover ⇒ background rgba(157,191,230,.22)
/// group.css 1910–1921     .group-info-select-check：flex none · color transparent（占位）；
///                         .is-selected ⇒ option color --grape-700 + check color --pink-500
///                         tsx 547 按钮文案 = `conv.join_policy === "public" ? "公开加入" : "申请加入"`；
///                         tsx 557 选中判定 = `(conv.join_policy ?? "application") === v`（缺值按申请制）
///
/// GroupInfo.tsx 584–599   label.group-info-setting-row.group-info-switch > span.group-info-setting-label
///                           + span.group-info-switch-ui > input[type=checkbox]（opacity 0，覆盖整轨）
///                             + span.group-info-switch-track > span.group-info-switch-thumb
///                         （owner 且 emojiPolicyLoaded 才渲染；disabled = busyAction !== null）
/// group.css 1924–1931     .group-info-switch：flex · center · space-between · gap sp3 · width 100% · cursor pointer
///                         （与 .group-info-setting-row 同元素 ⇒ 继承 min-height 44 与相邻行分隔线）
/// group.css 1933–1941     .group-info-switch-ui：relative · inline-flex · center · **44×24** · flex none
/// group.css 1942–1955     input：absolute inset 0 · z 1 · 100%×100% · margin 0 · **opacity 0** · cursor pointer
///                         （:disabled ⇒ cursor not-allowed）
/// group.css 1957–1964     .group-info-switch-track：44×24 · radius pill · background --ice-300 ·
///                         **box-shadow: var(--glass-inset)**（顶沿 1px 内高光）· transition background 180ms
/// group.css 1966–1976     .group-info-switch-thumb：absolute top 3 / left 3 · **18×18** · radius 50% ·
///                         background --surface(#FFFAFB) · box-shadow 0 1px 3px rgba(70,91,146,.3) ·
///                         transition transform 180ms
/// group.css 1978–1984     :checked ⇒ track background --pink-500；thumb translateX(20px)（⇒ left 23）
/// group.css 1986–1993     :disabled ⇒ track **opacity .6**；:focus-visible ⇒ track outline --focus-ring · offset 2
///
/// GroupInfo.tsx 602–624   div.group-info-requests > h4.group-info-requests-title
///                           「入群申请审批 · 待处理（{joinPage.total}）」
///                         + 有申请 ⇒ div.group-info-request（每条）
///                             > div.group-info-request-main > span.group-info-request-name
///                                 + （message 非空才渲染）span.group-info-request-msg
///                             + button.btn.btn-primary「同意」+ button.btn.btn-ghost「拒绝」
///                         + 无申请 ⇒ p.group-info-placeholder（加载中… / 申请加载失败 / 暂无待处理申请）
/// group.css 1996–2000     .group-info-requests：flex column · gap sp2(8)
/// group.css 2002–2006     .group-info-requests-title：13 / w700 / --text-primary
/// group.css 2008–2015     .group-info-request：flex · center · gap sp2 · padding sp2 sp3 · radius-input ·
///                         background rgba(157,191,230,.1)
/// group.css 2017–2039     .group-info-request-main：flex 1 · min-width 0 · flex column；
///                         -name：13 / w700 / --text-primary / 单行省略；-msg：12 / --text-secondary / 单行省略
/// group.css 2041–2047     .group-info-request .btn：flex none · **min-height 30** · padding 2px 12px ·
///                         font-size 12 · **border-radius pill**
/// group.css 1684–1687     .group-info-placeholder：13 / --text-secondary
///
/// GroupInfo.tsx 709–718   子群「查看更多/收起」：subgroups.length > SUBGROUP_PREVIEW_COUNT(3) 才渲染
///                         button.btn.btn-ghost.group-info-expand-btn[aria-expanded]
///                         文案 = showAllSubgroups ?「收起」: `查看更多（N）`（N = 总数 − 3）
/// group.css 2109–2116     .group-info-expand-btn：width 100% · min-height 36 · **margin-top sp2** ·
///                         font-size 13 · radius-input
///
/// GroupInfo.tsx 754       成员搜索：input.field（placeholder「搜索成员」· aria-label「搜索群成员」）
///                         **无搜索图标、无额外包装**（.group-info-members 卡 padding sp4，见 group.css 1678–1682）
/// app.css 70–88           .field：width 100% · padding 12px 16px · radius-input · 1px --glass-border ·
///                         --glass-bg · focus ⇒ --glow-500 边 + --glow-shadow · ::placeholder --slate-500
///                         （auroraqua.css 502–518 覆写：叠加 --glass-inset + blur24 sat1.4）
/// base.css 6–7            * { box-sizing: border-box } ⇒ 44×24 / 18×18 均含边框口径（与 Flutter 一致）
/// ```
///
/// ## 缩放口径
/// web CSS px == Flutter 逻辑 px（DPR 1.25 只影响物理像素，见 theme/aurora_background.dart:43–45）
/// ⇒ 全部数值原样使用。
///
/// ## 机制差异（有意偏离，登记）
/// ① 下拉菜单在 web 是 position: absolute / right: 0（相对按钮 wrap，z-index 40）。Flutter 的溢出子级
///    **收不到命中测试**（RenderBox.hitTest 先判 self size）⇒ 本件走库内约定 aylaOverlayEntry：
///    菜单插 root Overlay，右边缘与按钮右边缘对齐、top = 按钮底 + 6。
/// ② web 的 input[type=checkbox]（opacity 0）在 Flutter 用 Focus + 键盘（Enter/Space）表达；
///    整行可点（label 转发点击，同 AylaProfileSwitch 的处理）。
/// ③ --glass-inset 无 Flutter inset 阴影变体 ⇒ 用 AylaInset.topHighlight(24)（stops = 1/高度）。
///
/// ## 公开面
/// AylaGroupInfoSettingsBox · AylaGroupInfoSettingRow · AylaGroupInfoSwitch ·
/// AylaGroupInfoSelect · AylaGroupJoinRequest · AylaGroupJoinRequests ·
/// AylaGroupMemberSearchField · AylaGroupSubgroupExpandButton · kAylaGroupJoinPolicyOptions
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, LogicalKeyboardKey;

import '../../theme/app_icons.dart';
import '../../theme/app_theme.dart';
import '../../theme/css_gradient.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import '../base/overlays.dart';

/// 加入方式选项（web GroupInfo.tsx:556–573 的 public / application 两项）。
class AylaGroupJoinPolicyOption {
  const AylaGroupJoinPolicyOption({required this.value, required this.label});

  /// 值（web `public` / `application`）。
  final String value;

  /// 文案（web「公开加入」/「申请加入」）。
  final String label;
}

/// web 两项的 1:1 投影（顺序同 web：public 在前）。
const List<AylaGroupJoinPolicyOption> kAylaGroupJoinPolicyOptions =
    <AylaGroupJoinPolicyOption>[
  AylaGroupJoinPolicyOption(value: 'public', label: '公开加入'),
  AylaGroupJoinPolicyOption(value: 'application', label: '申请加入'),
];

/// 设置块容器（.group-info-settings）：浅冰蓝底 + 左右 sp3 内距 + **相邻行顶部 1px 分隔线**。
class AylaGroupInfoSettingsBox extends StatelessWidget {
  const AylaGroupInfoSettingsBox({super.key, required this.children});

  /// 行（.group-info-setting-row / .group-info-switch）。
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp3),
      decoration: BoxDecoration(
        color: AylaColors.ice500.withValues(alpha: 0.1), // rgba(157,191,230,.1)
        borderRadius: BorderRadius.circular(AylaRadii.rInput),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < children.length; i++) ...<Widget>[
            // .group-info-setting-row + .group-info-setting-row { border-top: 1px … }
            if (i > 0)
              Container(
                height: 1,
                color: AylaColors.ice500.withValues(alpha: 0.22),
              ),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// 设置行（.group-info-setting-row）：label + 值/控件，min-height 44、两端对齐。
class AylaGroupInfoSettingRow extends StatelessWidget {
  const AylaGroupInfoSettingRow({
    super.key,
    required this.label,
    this.value,
    this.trailing,
    this.labelStyle,
  });

  /// 行标签（.group-info-setting-label：14 / w600 / --text-primary）。
  final String label;

  /// 只读值（.group-info-setting-value：13 / --text-secondary / nowrap）。
  final String? value;

  /// 右侧控件（下拉 / 开关…）；给了 [trailing] 就忽略 [value]。
  final Widget? trailing;

  /// 标签样式覆盖（默认 14 / w600 / --text-primary）。
  final TextStyle? labelStyle;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final String? textValue = value;
    final Widget? slot = trailing;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: labelStyle ??
                  t.body.copyWith(
                    // .group-info-setting-label：14 / w600 / --text-primary
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AylaColors.textPrimary,
                  ),
            ),
          ),
          const SizedBox(width: AylaSpacing.sp3), // gap: var(--sp-3)
          if (slot != null)
            slot
          else if (textValue != null)
            Text(
              textValue,
              style: t.body.copyWith(
                // .group-info-setting-value：13 / --text-secondary / nowrap
                fontSize: 13,
                color: AylaColors.textSecondary,
              ),
            ),
        ],
      ),
    );
  }
}

/// 轨道开关行（.group-info-switch + -switch-ui/-track/-thumb，GroupInfo.tsx:584–599）。
///
/// ⚠️ 与 AylaProfileSwitch（个人主页域，48×28 / glass-bg-strong 底 / sakura 选中）**不是同一件**：
/// 本件 **44×24** 轨道 · --ice-300 底 + --glass-inset 内高光 · 选中 --pink-500 · 滑钮 18×18 --surface。
class AylaGroupInfoSwitch extends StatefulWidget {
  const AylaGroupInfoSwitch({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  /// 行标签（web「成员可上传表情包」）。
  final String label;

  /// 开关值（:checked）。
  final bool value;

  /// 切换回调；null ⇒ 禁用（web disabled={busyAction !== null}）。
  final ValueChanged<bool>? onChanged;

  @override
  State<AylaGroupInfoSwitch> createState() => _AylaGroupInfoSwitchState();
}

class _AylaGroupInfoSwitchState extends State<AylaGroupInfoSwitch> {
  bool _focused = false;

  bool get _enabled => widget.onChanged != null;

  void _toggle() => widget.onChanged?.call(!widget.value);

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final Duration dur = reduceMotion ? Duration.zero : AylaDurations.fast;

    // .group-info-switch-track：44×24 · pill · --ice-300 · box-shadow --glass-inset（顶沿 1px 内高光）
    // :checked ⇒ --pink-500；:disabled ⇒ opacity .6（整轨）
    Widget track = SizedBox(
      width: 44,
      height: 24,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: AnimatedContainer(
              duration: dur,
              curve: AylaCurves.easeOut,
              decoration: BoxDecoration(
                color: widget.value
                    ? AylaColors.pink500 // :checked background
                    : AylaColors.ice300, // .group-info-switch-track background
                borderRadius: AylaRadii.pill,
              ),
              child: ClipRRect(
                borderRadius: AylaRadii.pill,
                child: DecoratedBox(
                  // box-shadow: var(--glass-inset) —— 顶沿 1px 内高光（stops = 1/24）
                  decoration: BoxDecoration(
                    gradient: AylaInset.topHighlight(24),
                  ),
                ),
              ),
            ),
          ),
          AnimatedPositioned(
            duration: dur,
            curve: AylaCurves.easeOut,
            // .group-info-switch-thumb：absolute top 3 / left 3 · 18×18；
            // :checked ⇒ translateX(20px)（⇒ left 23）
            left: widget.value ? 23 : 3,
            top: 3,
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: AylaColors.surface, // background: var(--surface)
                borderRadius: BorderRadius.circular(AylaRadii.rPill),
                // box-shadow: 0 1px 3px rgba(70,91,146,.3)（滑钮自身阴影，非玻璃环）
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x4D465B92),
                    blurRadius: 3,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
            ),
          ),
          // :focus-visible ~ .group-info-switch-track { outline: var(--focus-ring); offset 2 }
          if (_focused && _enabled)
            Positioned(
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

    if (!_enabled) track = Opacity(opacity: 0.6, child: track); // :disabled opacity .6

    // 整行（label 转发点击）
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Focus(
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
        child: Semantics(
          toggled: widget.value,
          enabled: _enabled,
          label: widget.label,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _enabled ? _toggle : null,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(
                  child: Text(
                    widget.label,
                    style: t.body.copyWith(
                      // .group-info-setting-label
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AylaColors.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: AylaSpacing.sp3),
                track,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 「加入方式」自绘下拉（.group-info-select-*，GroupInfo.tsx:534–582）。
///
/// 非 owner 场景**不要用本件** —— web 那边是只读值（[AylaGroupInfoSettingRow.value]）。
class AylaGroupInfoSelect extends StatefulWidget {
  const AylaGroupInfoSelect({
    super.key,
    required this.value,
    required this.onChanged,
    this.options = kAylaGroupJoinPolicyOptions,
    this.enabled = true,
    this.semanticLabel = '加入方式',
  });

  /// 当前值（web conv.join_policy；非 `public` 一律按「申请加入」显示，判定同 web）。
  final String? value;

  /// 选中回调（web patchConversation({ join_policy })）。
  final ValueChanged<String>? onChanged;

  /// 选项表。
  final List<AylaGroupJoinPolicyOption> options;

  /// 是否可用（web disabled={busyAction !== null}）。
  final bool enabled;

  /// listbox 的可访问名（web aria-label="加入方式"）。
  final String semanticLabel;

  @override
  State<AylaGroupInfoSelect> createState() => _AylaGroupInfoSelectState();
}

class _AylaGroupInfoSelectState extends State<AylaGroupInfoSelect> {
  final GlobalKey _buttonKey = GlobalKey();
  OverlayEntry? _menuEntry;
  bool _open = false;
  bool _hovered = false;
  bool _pressed = false;

  bool get _enabled => widget.enabled && widget.onChanged != null;

  /// 显示文案：web `conv.join_policy === "public" ? "公开加入" : "申请加入"`。
  String get _label => widget.value == 'public' ? '公开加入' : '申请加入';

  /// 选中判定：web `(conv.join_policy ?? "application") === v`。
  bool _isSelected(String value) => (widget.value ?? 'application') == value;

  @override
  void dispose() {
    _menuEntry?.remove();
    _menuEntry = null;
    super.dispose();
  }

  void _removeMenu() {
    _menuEntry?.remove();
    _menuEntry = null;
    if (_open) {
      HardwareKeyboard.instance.removeHandler(_onKeyEvent);
      _open = false;
    }
  }

  /// Esc 关菜单（web tsx 543–545：按钮 onKeyDown `Escape` ⇒ setPolicyOpen(false)）。
  ///
  /// 用全局键盘监听而不是 Shortcuts：菜单插在 **root Overlay**（独立子树），
  /// 焦点树与宿主页面不连续，Shortcuts 拿不到事件（2026-09-28 实测：Esc 用例红）。
  /// 范式同库内 mention_picker（web 监听 document 的场合一律走 HardwareKeyboard）。
  bool _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.escape) return false;
    _close();
    return true;
  }

  void _close() {
    if (_menuEntry == null) return;
    setState(_removeMenu);
  }

  void _toggleMenu() {
    if (!_enabled) return;
    if (_menuEntry != null) {
      _close();
      return;
    }
    final RenderBox? box =
        _buttonKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    // 菜单右边缘对齐按钮右边缘（web: right 0）、top = 按钮底 + 6
    final Offset topRight = box.localToGlobal(box.size.topRight(Offset.zero));
    final OverlayEntry entry = aylaOverlayEntry(
      builder: (BuildContext context) => _SelectMenu(
        anchor: topRight,
        options: widget.options,
        isSelected: _isSelected,
        semanticLabel: widget.semanticLabel,
        onSelect: (String value) {
          _close();
          widget.onChanged?.call(value);
        },
        onDismiss: _close,
      ),
    );
    _menuEntry = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    setState(() => _open = true);
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    // ⚠️ 本按钮在 auroraqua 按钮组内：200ms 组过渡 + hover 1.02 + active .98
    final Duration dur = reduceMotion ? Duration.zero : AylaDurations.button;
    final bool hovered = _hovered && _enabled;
    final bool pressed = _pressed && _enabled;

    // .group-info-select-btn：min-height 32 · padding 4 10 4 14 · radius pill ·
    // 1px rgba(157,191,230,.55) · 135deg 渐变底 · indigo-700 · 13 / w700
    Widget button = AnimatedScale(
      duration: dur,
      curve: AylaCurves.auroraqua,
      scale: pressed ? 0.98 : (hovered ? 1.02 : 1.0),
      child: AnimatedContainer(
        key: _buttonKey,
        duration: dur,
        curve: AylaCurves.auroraqua,
        constraints: const BoxConstraints(minHeight: 32),
        padding: const EdgeInsets.fromLTRB(14, 4, 10, 4),
        decoration: BoxDecoration(
          gradient: cssLinearGradient(
            angleDeg: 135,
            colors: hovered
                // :hover:not(:disabled) 渐变增强（.32 / .2）
                ? <Color>[
                    AylaColors.ice500.withValues(alpha: 0.32),
                    AylaColors.sakura300.withValues(alpha: 0.2),
                  ]
                : <Color>[
                    AylaColors.ice500.withValues(alpha: 0.22),
                    AylaColors.sakura300.withValues(alpha: 0.14),
                  ],
          ),
          borderRadius: AylaRadii.pill,
          border: Border.all(
            color: hovered
                ? AylaColors.ice500 // :hover border-color
                : AylaColors.ice500.withValues(alpha: 0.55),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              _label,
              style: t.body.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AylaColors.indigo700,
              ),
            ),
            const SizedBox(width: AylaSpacing.sp2), // gap: var(--sp-2)
            AnimatedRotation(
              // .group-info-select-btn-arrow[.is-open] ⇒ rotate(180deg)
              duration: dur,
              curve: AylaCurves.easeOut,
              turns: _open ? 0.5 : 0,
              child: AylaIcon(
                aylaIconByName('iconChevronDown')!,
                size: 14,
                color: AylaColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );

    if (!_enabled) button = Opacity(opacity: 0.6, child: button); // :disabled opacity .6

    return MouseRegion(
      cursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Listener(
        onPointerDown: (_) => setState(() => _pressed = true),
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: Semantics(
          button: true,
          expanded: _open, // aria-expanded
          enabled: _enabled,
          label: '$_label，${widget.semanticLabel}',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _enabled ? _toggleMenu : null,
            child: button,
          ),
        ),
      ),
    );
  }
}

/// 下拉菜单（插 root Overlay；点外部 / Esc / 选中关闭）。
class _SelectMenu extends StatelessWidget {
  const _SelectMenu({
    required this.anchor,
    required this.options,
    required this.isSelected,
    required this.semanticLabel,
    required this.onSelect,
    required this.onDismiss,
  });

  /// 按钮右上角（全局坐标）。
  final Offset anchor;
  final List<AylaGroupJoinPolicyOption> options;
  final bool Function(String value) isSelected;
  final String semanticLabel;
  final ValueChanged<String> onSelect;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.sizeOf(context).width;
    return SizedBox.expand(
      child: Stack(
        children: <Widget>[
          // 点外部关闭（web outside-click 语义）
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onDismiss,
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            right: screenWidth - anchor.dx,
            top: anchor.dy + 6, // top: calc(100% + 6px)
            // ⚠️ Positioned 只给 right/top ⇒ child 拿到**无界宽度**约束（const BoxConstraints()），
            // Column(stretch) 会直接崩（BoxConstraints forces an infinite width，2026-09-28 实测）。
            // web 的菜单是「min-width 148 + 内容自适应」⇒ 这里先给上限（220），再让 IntrinsicWidth
            // 按内容取宽，内层 ConstrainedBox 保 min-width 148。三者顺序不可颠倒。
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: IntrinsicWidth(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 148),
                  child: _SelectMenuCard(
                    options: options,
                    isSelected: isSelected,
                    semanticLabel: semanticLabel,
                    onSelect: onSelect,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectMenuCard extends StatelessWidget {
  const _SelectMenuCard({
    required this.options,
    required this.isSelected,
    required this.semanticLabel,
    required this.onSelect,
  });

  final List<AylaGroupJoinPolicyOption> options;
  final bool Function(String value) isSelected;
  final String semanticLabel;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    // Esc 关闭归 State 的全局监听（见 _onKeyEvent）；这里只画卡片本体。
    return AylaGlassCard(
            // .group-info-select-menu：padding sp1 · radius-card · --glass-bg-strong + blur + 1px 边 + 阴影
            padding: const EdgeInsets.all(AylaSpacing.sp1),
            radius: AylaRadii.rCard,
            strong: true,
            child: Semantics(
              container: true,
              explicitChildNodes: true,
              label: semanticLabel,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (int i = 0; i < options.length; i++) ...<Widget>[
                    if (i > 0) const SizedBox(height: 2), // gap: 2px
                    _SelectOption(
                      option: options[i],
                      selected: isSelected(options[i].value),
                      onTap: () => onSelect(options[i].value),
                    ),
                  ],
                ],
              ),
            ),
          );
  }
}

class _SelectOption extends StatefulWidget {
  const _SelectOption({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final AylaGroupJoinPolicyOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SelectOption> createState() => _SelectOptionState();
}

class _SelectOptionState extends State<_SelectOption> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    // .group-info-select-option：min-height 36 · padding 0 sp3 · radius-sm · 13 / w600 ·
    // hover ⇒ rgba(157,191,230,.22)；.is-selected ⇒ grape-700 + check pink-500
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.option.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: AylaDurations.fast,
            curve: AylaCurves.easeOut,
            constraints: const BoxConstraints(minHeight: 36),
            padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp3),
            decoration: BoxDecoration(
              color: _hovered
                  ? AylaColors.ice500.withValues(alpha: 0.22)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(AylaRadii.rSm),
            ),
            child: Row(
              children: <Widget>[
                AylaIcon(
                  aylaIconByName('iconCheck')!,
                  size: 14,
                  // .group-info-select-check { color: transparent }；.is-selected 时 --pink-500
                  color: widget.selected
                      ? AylaColors.pink500
                      : Colors.transparent,
                ),
                const SizedBox(width: AylaSpacing.sp2),
                Text(
                  widget.option.label,
                  style: t.body.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: widget.selected
                        ? AylaColors.grape700
                        : AylaColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 入群申请条目（web .group-info-request 的数据投影）。
class AylaGroupJoinRequest {
  const AylaGroupJoinRequest({
    required this.id,
    required this.name,
    this.message,
  });

  /// 申请 id（web request.id）。
  final String id;

  /// 申请人名（web nickname || username）。
  final String name;

  /// 申请留言（web request.message；null/空 ⇒ 不渲染 msg 行）。
  final String? message;
}

/// 入群申请审批块（.group-info-requests，GroupInfo.tsx:602–624）。
class AylaGroupJoinRequests extends StatelessWidget {
  const AylaGroupJoinRequests({
    super.key,
    required this.total,
    required this.requests,
    this.loading = false,
    this.error = false,
    this.busy = false,
    this.onAccept,
    this.onReject,
    this.title = '入群申请审批 · 待处理',
    this.loadingLabel = '加载中…',
    this.errorLabel = '申请加载失败',
    this.emptyLabel = '暂无待处理申请',
    this.acceptLabel = '同意',
    this.rejectLabel = '拒绝',
  });

  /// 待处理总数（web joinPage.total，用于标题计数）。
  final int total;

  /// 当前页申请。
  final List<AylaGroupJoinRequest> requests;

  /// 加载中（web joinPage.loading）。
  final bool loading;

  /// 加载失败（web joinPage.error）。
  final bool error;

  /// 有动作在跑（web busyAction !== null ⇒ 两键均 disabled）。
  final bool busy;

  /// 同意回调；null ⇒ 该键禁用。
  final ValueChanged<AylaGroupJoinRequest>? onAccept;

  /// 拒绝回调；null ⇒ 该键禁用。
  final ValueChanged<AylaGroupJoinRequest>? onReject;

  /// 标题前缀（web 原文「入群申请审批 · 待处理」）。
  final String title;

  /// 空态文案（web「加载中…」）。
  final String loadingLabel;

  /// 错误文案（web「申请加载失败」）。
  final String errorLabel;

  /// 无申请文案（web「暂无待处理申请」）。
  final String emptyLabel;

  /// 同意键文案（web「同意」）。
  final String acceptLabel;

  /// 拒绝键文案（web「拒绝」）。
  final String rejectLabel;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: AylaSpacing.sp2, // gap: var(--sp-2)
      children: <Widget>[
        Text(
          // web：入群申请审批 · 待处理（{joinPage.total}）
          '$title（$total）',
          style: t.body.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: AylaColors.textPrimary,
          ),
        ),
        if (requests.isNotEmpty)
          for (final AylaGroupJoinRequest request in requests)
            _JoinRequestRow(
              request: request,
              busy: busy,
              onAccept: onAccept,
              onReject: onReject,
              acceptLabel: acceptLabel,
              rejectLabel: rejectLabel,
            )
        else
          Text(
            loading ? loadingLabel : (error ? errorLabel : emptyLabel),
            style: t.body.copyWith(
              fontSize: 13,
              color: AylaColors.textSecondary,
            ),
          ),
      ],
    );
  }
}

class _JoinRequestRow extends StatelessWidget {
  const _JoinRequestRow({
    required this.request,
    required this.busy,
    required this.onAccept,
    required this.onReject,
    required this.acceptLabel,
    required this.rejectLabel,
  });

  final AylaGroupJoinRequest request;
  final bool busy;
  final ValueChanged<AylaGroupJoinRequest>? onAccept;
  final ValueChanged<AylaGroupJoinRequest>? onReject;
  final String acceptLabel;
  final String rejectLabel;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final String? message = request.message;
    // .group-info-request：flex · center · gap sp2 · padding sp2 sp3 · radius-input ·
    // background rgba(157,191,230,.1)
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp3,
        vertical: AylaSpacing.sp2,
      ),
      decoration: BoxDecoration(
        color: AylaColors.ice500.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AylaRadii.rInput),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            // .group-info-request-main：flex 1 · min-width 0 · column
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  request.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.body.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AylaColors.textPrimary,
                  ),
                ),
                if (message != null && message.isNotEmpty)
                  Text(
                    message,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.body.copyWith(
                      fontSize: 12,
                      color: AylaColors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AylaSpacing.sp2),
          AylaGlassButton(
            label: acceptLabel,
            minHeight: 30, // .group-info-request .btn
            padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp3),
            fontSize: 12,
            borderRadius: AylaRadii.rPill, // border-radius: var(--radius-pill)
            onPressed: busy || onAccept == null
                ? null
                : () => onAccept!(request),
          ),
          const SizedBox(width: AylaSpacing.sp2),
          AylaGlassButton(
            label: rejectLabel,
            variant: AylaGlassButtonVariant.ghost,
            minHeight: 30,
            padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp3),
            fontSize: 12,
            borderRadius: AylaRadii.rPill,
            onPressed: busy || onReject == null
                ? null
                : () => onReject!(request),
          ),
        ],
      ),
    );
  }
}

/// 群成员搜索框（GroupInfo.tsx:754：input.field，placeholder「搜索成员」· aria-label「搜索群成员」）。
///
/// ⚠️ web **没有搜索图标、没有额外包装**（不像 .group-create-search 那种带图标的搜索档）
/// —— 本件只是 .field 档 + 语义标签的薄装配，材质/焦点全部来自 AylaGlassInput。
class AylaGroupMemberSearchField extends StatelessWidget {
  const AylaGroupMemberSearchField({
    super.key,
    required this.controller,
    this.onChanged,
    this.enabled = true,
    this.hintText = '搜索成员',
    this.semanticLabel = '搜索群成员',
    this.focusNode,
  });

  /// 文本控制器（web memberQuery state）。
  final TextEditingController controller;

  /// 输入变化（web setMemberQuery；防抖由页面负责）。
  final ValueChanged<String>? onChanged;

  /// 是否可编辑。
  final bool enabled;

  /// 占位文案（web「搜索成员」）。
  final String hintText;

  /// 可访问名（web aria-label="搜索群成员"）。
  final String semanticLabel;

  /// 焦点节点（可选）。
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return AylaGlassInput(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      enabled: enabled,
      hintText: hintText,
      semanticLabel: semanticLabel,
    );
  }
}

/// 子群「查看更多 / 收起」（.group-info-expand-btn，GroupInfo.tsx:709–718）。
///
/// web 只在 subgroups.length > SUBGROUP_PREVIEW_COUNT(3) 时渲染 ⇒ 由调用方决定是否放进来。
class AylaGroupSubgroupExpandButton extends StatelessWidget {
  const AylaGroupSubgroupExpandButton({
    super.key,
    required this.hiddenCount,
    required this.expanded,
    required this.onPressed,
    this.expandedLabel = '收起',
    this.moreLabel = '查看更多',
  });

  /// 被折叠的数量（web subgroups.length − SUBGROUP_PREVIEW_COUNT）。
  final int hiddenCount;

  /// 是否已展开（web showAllSubgroups，同时是 aria-expanded）。
  final bool expanded;

  /// 切换回调。
  final VoidCallback? onPressed;

  /// 展开态文案（web「收起」）。
  final String expandedLabel;

  /// 折叠态文案前缀（web「查看更多」，实际渲染「查看更多（N）」）。
  final String moreLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AylaSpacing.sp2), // margin-top: var(--sp-2)
      child: Semantics(
        expanded: expanded, // aria-expanded
        child: AylaGlassButton(
          label: expanded ? expandedLabel : '$moreLabel（$hiddenCount）',
          variant: AylaGlassButtonVariant.ghost,
          minHeight: 36, // .group-info-expand-btn
          fontSize: 13,
          expand: true, // width: 100%
          onPressed: onPressed,
        ),
      ),
    );
  }
}
