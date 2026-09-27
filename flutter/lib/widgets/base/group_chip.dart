/// group chip（自 `directory_controls.dart` 拆出：一文件一件）。
///
/// 事实源与逐条对照见 `docs/flutter/17-组件文件头归档（整理前原文）.md` 的 `directory_controls.dart` 一节
/// 与各件的 `///` 头注。
///
/// ## 公开面
/// `AylaGroupChip`

library;

import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';

/// `.group-create-chip` —— 已选成员 / 已选群胶囊（可删）。
///
/// 事实源：`.group-create-chip`（private.css 115–125）+ `.group-create-chip-x`（127–141）——
/// padding `2px 8px 2px 10px` · radius-pill · `--ice-100` 底 · 12/600 · 叉 **16×16**
/// （静息 `--text-secondary`，**hover → `--destructive`**）；gap 4。
///
/// 同一件服务两处（裁决：照 `AylaCheckbox` 先例把私有件提升为公共件）：
/// - `AylaVisibilitySelector` 的「已选群」——叉的 aria 默认「取消选择群 label」；
/// - 建群弹窗的「已选成员」——传 [removeSemanticLabel]「移除 name」（web tsx 131）。
class AylaGroupChip extends StatefulWidget {
  const AylaGroupChip({
    super.key,
    required this.label,
    required this.style,
    this.onRemove,
    this.removeSemanticLabel,
  });

  final String label;

  /// 文本样式来源（调用方从 `AylaTextStyles.of(context)` 取）。
  final AylaTextStyles style;

  /// null = 不显示 ×（锁定群）。
  final VoidCallback? onRemove;

  /// 叉钮的可访问文案；null = 默认「取消选择群 label」。
  final String? removeSemanticLabel;

  @override
  State<AylaGroupChip> createState() => _AylaGroupChipState();
}

class _AylaGroupChipState extends State<AylaGroupChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      // padding: 2px 8px 2px 10px
      padding: const EdgeInsets.fromLTRB(10, 2, 8, 2),
      decoration: BoxDecoration(
        color: AylaColors.ice100, // background: var(--ice-100)
        borderRadius: AylaRadii.pill,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4, // gap: 4px
        children: <Widget>[
          Text(
            widget.label,
            style: widget.style.label.copyWith(
              fontSize: 12, // font-size: 12px
              fontWeight: FontWeight.w600, // font-weight: 600
              color: AylaColors.textPrimary,
            ),
          ),
          if (widget.onRemove != null)
            Semantics(
              button: true,
              label: widget.removeSemanticLabel ?? '取消选择群 ${widget.label}',
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                onEnter: (_) => setState(() => _hovered = true),
                onExit: (_) => setState(() => _hovered = false),
                child: GestureDetector(
                  onTap: widget.onRemove,
                  child: SizedBox(
                    width: 16, // width: 16px
                    height: 16, // height: 16px
                    child: Center(
                      child: Text(
                        '×',
                        style: widget.style.label.copyWith(
                          fontSize: 13,
                          // 静息 --text-secondary；hover → --destructive（.group-create-chip-x:hover）
                          color: _hovered
                              ? AylaColors.destructive
                              : AylaColors.textSecondary,
                        ),
                      ),
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
