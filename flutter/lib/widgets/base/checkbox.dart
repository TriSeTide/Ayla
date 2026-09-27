/// checkbox（自 `directory_controls.dart` 拆出：一文件一件）。
///
/// 事实源与逐条对照见 `docs/flutter/17-组件文件头归档（整理前原文）.md` 的 `directory_controls.dart` 一节
/// 与各件的 `///` 头注。
///
/// ## 公开面
/// `AylaCheckbox`

library;

import 'package:flutter/material.dart';
import '../../theme/tokens.dart';

/// 复选框（native `input[type=checkbox]` + `accent-color: var(--glow-500)` 的等价自绘件）。
///
/// 事实源（两处 native 尺寸不同，故提升为公共件 + [size] 档，**不新造第二份**）：
/// - `.visibility-selector input[type="checkbox"]`（app.css 186 区）**16×16** —— 默认；
/// - `.subgroup-dialog-mute input[type="checkbox"]`（group.css 2191–2197）**18×18**。
///
/// 自绘比例按 16 档实测值等比：圆角 = size×0.25（16→4）、勾 = size×0.75（16→12）、
/// 描边恒 1.5。选中 = `--glow-500` 实底 + 白勾；未选中 = 透明底 + `--text-secondary` 描边。
class AylaCheckbox extends StatelessWidget {
  const AylaCheckbox({
    super.key,
    required this.checked,
    this.locked = false,
    this.size = 16,
  });

  /// 是否选中。
  final bool checked;

  /// 锁定（选中态保持视觉；交互层由调用方处理，如 `.is-locked`）。
  final bool locked;

  /// 边长（visibility selector 16 / 子群禁言行 18）。
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: checked ? AylaColors.glow500 : Colors.transparent, // accent-color
          borderRadius: BorderRadius.circular(size * 0.25),
          border: Border.all(
            color: checked ? AylaColors.glow500 : AylaColors.textSecondary,
            width: 1.5,
          ),
        ),
        child: checked
            ? Icon(Icons.check, size: size * 0.75, color: Colors.white)
            : null,
      ),
    );
  }
}
