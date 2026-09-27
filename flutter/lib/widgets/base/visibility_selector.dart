/// visibility selector（自 `directory_controls.dart` 拆出：一文件一件）。
///
/// 事实源与逐条对照见 `docs/flutter/17-组件文件头归档（整理前原文）.md` 的 `directory_controls.dart` 一节
/// 与各件的 `///` 头注。
///
/// ## 公开面
/// `AylaVisibilitySelection` · `AylaVisibilitySelector`

library;

import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import 'checkbox.dart';
import 'group_chip.dart';

/// 可见性多选值（`AylaVisibilitySelection`，tsx 10–14）。
///
/// **互斥规则**：`public` 与 `friends` **互斥**；`group`（群白名单）**独立**，
/// 可与二者任一叠加（「公开+群」「好友+群」均合法）。
class AylaVisibilitySelection {
  const AylaVisibilitySelection({
    this.isPublic = false,
    this.friends = false,
    this.group = false,
  });

  /// 公开。
  final bool isPublic;

  /// 好友可见。
  final bool friends;

  /// 指定群可见。
  final bool group;

  AylaVisibilitySelection copyWith({bool? isPublic, bool? friends, bool? group}) =>
      AylaVisibilitySelection(
        isPublic: isPublic ?? this.isPublic,
        friends: friends ?? this.friends,
        group: group ?? this.group,
      );
}

/// 可见性选择器（`VisibilitySelector.tsx` + app.css 92–200 + private.css 108–140）。
///
/// ## 事实源
/// ```
/// .visibility-selector { flex column; gap: sp2; border:none; padding:0; margin:0 }
/// .visibility-selector legend { font-display 12/500; ls .8; --text-secondary }
/// .visibility-selector-options { flex wrap; gap: sp2 }
/// .visibility-selector-options label {
///   inline-flex; center; gap: sp2; min-height:40; padding: 0 sp4;
///   1px --glass-border; radius-pill; --glass-bg; --text-primary; 14/600;
///   transition: background/border-color/box-shadow var(--dur-fast) }
/// label:hover                → background: rgba(249,176,255,.12)
/// label:has(:checked)        → border glow-500 + rgba(249,176,255,.16) + grape-700
/// label:has(:disabled)       → opacity .55
/// label.is-locked:has(:checked) → opacity 1（保持选中视觉、仅禁点）
/// input[type=checkbox]       → 16×16; accent-color: --glow-500
/// .visibility-selector-groups { glass 小卡：sp3 内边距 + radius-input 12 +
///   max-height 200 + overflow-y auto + --glass-shadow-compact + blur }
/// .group-create-chip { inline-flex; gap 4; padding 2px 8px 2px 10px; radius-pill;
///   --ice-100 底; 12/600 } · .group-create-chip-x { 16×16; hover → --destructive }
/// ```
///
/// ## 行为（tsx）
/// - `togglePublic`：勾选公开 → **friends 置 false**（互斥）
/// - `toggleFriends`：勾选好友 → **public 置 false**（互斥）
/// - `toggleGroup`：**独立切换**；取消勾选时**清空已选群**
/// - `lockGroup`（群内创建）：群大类**恒勾选且不可取消**；本群条目
///   `disabled` 且 `is-locked`（保持选中视觉）；其余群仍可多选
/// - 群搜索无结果 → 「没有匹配的群」
class AylaVisibilitySelector extends StatefulWidget {
  const AylaVisibilitySelector({
    super.key,
    required this.value,
    required this.onChange,
    this.selectedGroupIds = const <String>[],
    this.onSelectedGroupIdsChange,
    this.groups = const <({String id, String title})>[],
    this.groupsLoading = false,
    this.initialGroupId,
    this.lockGroup = false,
    this.legend = '可见范围',
  });

  /// 当前值。
  final AylaVisibilitySelection value;

  /// 值变化。
  final ValueChanged<AylaVisibilitySelection> onChange;

  /// 已选群 id。
  final List<String> selectedGroupIds;

  /// 已选群变化。
  final ValueChanged<List<String>>? onSelectedGroupIdsChange;

  /// 可搜索的群列表（真实数据由 `useSocialPage('conversations')` 提供）。
  final List<({String id, String title})> groups;

  /// 群列表是否加载中。
  final bool groupsLoading;

  /// 群内创建时的本群 id（锁定项）。
  final String? initialGroupId;

  /// 锁定群可见（本群强制勾选且不可取消）。
  final bool lockGroup;

  /// legend 文案（默认「可见范围」）。
  final String legend;

  @override
  State<AylaVisibilitySelector> createState() => _AylaVisibilitySelectorState();
}

class _AylaVisibilitySelectorState extends State<AylaVisibilitySelector> {
  final TextEditingController _query = TextEditingController();

  /// 群复选框实际勾选状态（lockGroup 时恒 true）。
  bool get _groupChecked => widget.lockGroup ? true : widget.value.group;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _togglePublic(bool checked) {
    // 公开与好友互斥；群可见独立保留
    widget.onChange(widget.value.copyWith(
      isPublic: checked,
      friends: checked ? false : widget.value.friends,
    ));
  }

  void _toggleFriends(bool checked) {
    widget.onChange(widget.value.copyWith(
      friends: checked,
      isPublic: checked ? false : widget.value.isPublic,
    ));
  }

  void _toggleGroup(bool checked) {
    if (widget.lockGroup) return; // 锁定大类不可取消（双保险）
    widget.onChange(widget.value.copyWith(group: checked));
    if (!checked) {
      widget.onSelectedGroupIdsChange?.call(<String>[]); // 取消勾选清空已选群
    }
  }

  List<({String id, String title})> get _filtered {
    final String q = _query.text.trim();
    if (q.isEmpty) return widget.groups;
    return widget.groups
        .where((({String id, String title}) g) => g.title.contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final List<({String id, String title})> filtered = _filtered;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AylaSpacing.sp2, // gap: var(--sp-2)
      children: <Widget>[
        // legend（font-display 12/500 ls .8 secondary）
        Text(
          widget.legend,
          style: TextStyle(
            fontFamily: AylaFonts.display,
            fontFamilyFallback: AylaFonts.cjkFallback,
            fontSize: 12, // font-size: 12px
            fontWeight: FontWeight.w500, // font-weight: 500
            letterSpacing: 0.8, // letter-spacing: 0.8px
            color: AylaColors.textSecondary,
          ),
        ),
        // ---------- 三个大类 ----------
        Wrap(
          spacing: AylaSpacing.sp2, // gap: var(--sp-2)
          runSpacing: AylaSpacing.sp2,
          children: <Widget>[
            _OptionChip(
              label: '公开',
              checked: widget.value.isPublic,
              onChanged: _togglePublic,
              style: t,
            ),
            _OptionChip(
              label: '好友可见',
              checked: widget.value.friends,
              onChanged: _toggleFriends,
              style: t,
            ),
            _OptionChip(
              label: '指定群可见',
              checked: _groupChecked,
              // lockGroup → disabled 但保持选中视觉（.is-locked）
              locked: widget.lockGroup,
              onChanged: _toggleGroup,
              style: t,
            ),
          ],
        ),
        // ---------- 群选择区（仅 groupChecked 时） ----------
        if (_groupChecked) _buildGroupPicker(t, filtered),
      ],
    );
  }

  Widget _buildGroupPicker(AylaTextStyles t, List<({String id, String title})> filtered) {
    final BorderRadius r = BorderRadius.circular(AylaRadii.rInput); // 12
    final bool opaque = AylaGlassConfig.useOpaqueFallback;

    Widget face = Container(
      padding: const EdgeInsets.all(AylaSpacing.sp3), // padding: var(--sp-3)
      constraints: const BoxConstraints(maxHeight: 200), // max-height: 200px
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: AylaSpacing.sp1, // gap: var(--sp-1)
          children: <Widget>[
            // 搜索框：**复用组件库 AylaGlassInput**（2026-09-20 审查 R4——原
            // _GroupSearchField 手搓 `.field`，缺 --glass-inset 内高光、
            // focus 辉光边与 blur(24)+saturate(1.4) 玻璃层）。
            // 位置覆写：`.visibility-selector-groups .field { padding-block: sp2;
            //   min-height: 40px }`（app.css 186–189）。
            AylaGlassInput(
              controller: _query,
              hintText: '搜索群', // placeholder
              minHeight: 40,
              padding: const EdgeInsets.symmetric(
                horizontal: AylaSpacing.sp4,
                vertical: AylaSpacing.sp2,
              ),
              onChanged: (_) => setState(() {}),
            ),
            // 已选群 chips
            if (widget.selectedGroupIds.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: AylaSpacing.sp2), // margin-top: sp2
                child: Wrap(
                  spacing: AylaSpacing.sp2,
                  runSpacing: AylaSpacing.sp2,
                  children: <Widget>[
                    for (final String id in widget.selectedGroupIds)
                      AylaGroupChip(
                        label: widget.groups
                                .where((({String id, String title}) g) => g.id == id)
                                .map((({String id, String title}) g) => g.title)
                                .firstOrNull ??
                            '群 $id',
                        // 锁定本群不显示 ×
                        onRemove: (widget.lockGroup && id == widget.initialGroupId)
                            ? null
                            : () => widget.onSelectedGroupIdsChange?.call(
                                  widget.selectedGroupIds
                                      .where((String x) => x != id)
                                      .toList(),
                                ),
                        style: t,
                      ),
                  ],
                ),
              ),
            // 列表 / 空态
            if (!widget.groupsLoading && filtered.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: AylaSpacing.sp1),
                child: Text(
                  '没有匹配的群',
                  style: t.caption.copyWith(color: AylaColors.textSecondary),
                ),
              )
            else
              for (final ({String id, String title}) g in filtered)
                _GroupOption(
                  title: g.title,
                  // 锁定本群：恒勾选且 disabled
                  locked: widget.lockGroup && g.id == widget.initialGroupId,
                  checked: (widget.lockGroup && g.id == widget.initialGroupId) ||
                      widget.selectedGroupIds.contains(g.id),
                  onChanged: () {
                    final bool isSelected =
                        widget.selectedGroupIds.contains(g.id);
                    widget.onSelectedGroupIdsChange?.call(
                      isSelected
                          ? widget.selectedGroupIds
                              .where((String x) => x != g.id)
                              .toList()
                          : <String>[...widget.selectedGroupIds, g.id],
                    );
                  },
                  style: t,
                ),
          ],
        ),
      ),
    );

    Widget layered = face;
    if (!opaque) {
      layered = Stack(
        children: <Widget>[
          Positioned.fill(
            // 背后内容层统一走 AylaGlassBackdrop（质量档 owner，§8.17）。
            child: AylaGlassBackdrop(
              radius: r,
              filter: AylaGlassConfig.backdropFilter(sigma: AylaGlass.blurCard),
            ),
          ),
          face,
        ],
      );
    }

    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        // --glass-shadow-compact（含 --glass-inset）——只画形状之外
        // （2026-09-20 审查 R2：裸 boxShadow 会染进半透明玻璃内部）
        Positioned.fill(
          child: IgnorePointer(
            child: AylaGlassShadow.ring(
              radius: r,
              shadows: AylaShadows.compact,
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: AylaGlassConfig.resolveBackground(strong: false),
            borderRadius: r,
            border: Border.all(color: AylaColors.glassBorder),
          ),
          child: ClipRRect(borderRadius: r, child: layered),
        ),
      ],
    );
  }
}

/// `.visibility-selector-options label` —— 胶囊大选项（40 高，选中转粉辉光）。
class _OptionChip extends StatefulWidget {
  const _OptionChip({
    required this.label,
    required this.checked,
    required this.onChanged,
    required this.style,
    this.locked = false,
  });

  final String label;
  final bool checked;
  final ValueChanged<bool> onChanged;
  final AylaTextStyles style;

  /// 锁定（`.is-locked`：保持选中视觉、仅禁点）。
  final bool locked;

  @override
  State<_OptionChip> createState() => _OptionChipState();
}

class _OptionChipState extends State<_OptionChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // 选中态：border glow-500 + rgba(249,176,255,.16) + grape-700
    final Color bg = widget.checked
        ? const Color(0x29F9B0FF) // rgba(249,176,255,.16)
        : (_hovered
            ? const Color(0x1FF9B0FF) // rgba(249,176,255,.12)
            : AylaGlassConfig.resolveBackground(strong: false));
    final Color border =
        widget.checked ? AylaColors.glow500 : AylaColors.glassBorder;
    final Color fg =
        widget.checked ? AylaColors.grape700 : AylaColors.textPrimary;

    return Semantics(
      checked: widget.checked,
      enabled: !widget.locked,
      label: widget.label,
      child: MouseRegion(
        cursor: widget.locked
            ? SystemMouseCursors.forbidden // cursor: not-allowed
            : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.locked ? null : () => widget.onChanged(!widget.checked),
          child: AnimatedContainer(
            duration: AylaDurations.fast, // --dur-fast
            curve: AylaCurves.easeOut,
            constraints: const BoxConstraints(minHeight: 40), // min-height: 40px
            padding: const EdgeInsets.symmetric(
              horizontal: AylaSpacing.sp4, // padding: 0 var(--sp-4)
            ),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: AylaRadii.pill, // radius-pill
              border: Border.all(color: border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: AylaSpacing.sp2, // gap: var(--sp-2)
              children: <Widget>[
                AylaCheckbox(checked: widget.checked, locked: widget.locked),
                Text(
                  widget.label,
                  style: widget.style.label.copyWith(
                    fontSize: 14, // font-size: 14px
                    fontWeight: FontWeight.w600, // font-weight: 600
                    // :has(:disabled) → .55；但 .is-locked:has(:checked) → 1。
                    // 性能（2026-09-27 §8.17）：单行文本无重叠 ⇒ 把 .55 乘进
                    // 文字色与整层 Opacity 等价（文本抗锯齿是 coverage×color
                    // over 背景，逐色 alpha 与 group opacity 数学等价），
                    // 省掉一次 saveLayer。
                    color: widget.locked && !widget.checked
                        ? fg.withValues(alpha: fg.a * 0.55)
                        : fg,
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

/// `.visibility-group-option` —— 群列表行（40 高、radius-sm、14px）。
class _GroupOption extends StatelessWidget {
  const _GroupOption({
    required this.title,
    required this.checked,
    required this.onChanged,
    required this.style,
    this.locked = false,
  });

  final String title;
  final bool checked;
  final VoidCallback onChanged;
  final AylaTextStyles style;

  /// 锁定（恒勾选 + disabled，视觉保持正常 —— 同 `.is-locked` 语义）。
  final bool locked;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      checked: checked,
      enabled: !locked,
      label: title,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: locked ? null : onChanged,
        child: Container(
          constraints: const BoxConstraints(minHeight: 40), // min-height: 40px
          padding: const EdgeInsets.symmetric(
            horizontal: AylaSpacing.sp2, // padding: 0 var(--sp-2)
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AylaRadii.rSm), // radius-sm 8
          ),
          child: Row(
            spacing: AylaSpacing.sp2, // gap: var(--sp-2)
            children: <Widget>[
              AylaCheckbox(checked: checked, locked: locked),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style.label.copyWith(
                    fontSize: 14, // font-size: 14px
                    fontWeight: FontWeight.w400, // 行内非加粗（CSS 未设 weight）
                    color: AylaColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
