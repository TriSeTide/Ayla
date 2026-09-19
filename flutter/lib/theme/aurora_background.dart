/// 全局极光背景 —— `tokens.css --bg-aurora` 的九层 radial 同构版。
///
/// 事实源：`web/src/styles/tokens.css` 第 28–36 行（逐层对应）：
/// 四角四色螺旋（左上冰蓝 / 右上冰蓝深 / 右下亮樱粉 / 左下淡樱粉，各 50%
/// 半径弥散）+ 四边中点白色光斑（45% 隔离蓝粉，避免混合成紫）+ 中心
/// 35% 暖白光晕（33%→.5 / 52%→.15 / 63%→0 三层 stop）。
/// 外加 `--bg-aurora-grid`：极淡 96px 周期网格纹理（0.015/0.008 透明度，
/// 肉眼几乎不可见，仅保留微妙层次感）。
///
/// 纪律：背景是 z 最低层，内容在其上滚动；光斑在玻璃卡片之下，被
/// backdrop-filter 模糊后透出（d:§7.2 层级）。fluid 动画（旋转/漂移/呼吸）
/// 由后续 M 阶段按 d:§7.2 参数接入，本层为静态同构底。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// CSS radial-gradient(circle at X% Y%, c0 0%, c1 50%) 的一层。
///
/// Flutter [RadialGradient.radius] 的 1.0 ≈ 最长轴一半；四角层用 1.05
/// 保证对角覆盖（CSS 的 farthest-corner 语义），中心层按 stops 缩放。
class _RadialLayer extends StatelessWidget {
  const _RadialLayer({
    required this.alignment,
    required this.colors,
    required this.stops,
    this.radius = 1.05,
  });

  final Alignment alignment;
  final List<Color> colors;
  final List<double> stops;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: alignment,
              radius: radius,
              colors: colors,
              stops: stops,
            ),
          ),
        ),
      ),
    );
  }
}

/// 极光背景（全屏，静态九层同构底 + 极淡网格）。
///
/// 用法：作为页面根 Scaffold 的底层（`Stack` 最下层）或 `body` 背景。
class AuroraBackground extends StatelessWidget {
  const AuroraBackground({super.key, this.child});

  const AuroraBackground.fill({super.key}) : child = null;

  /// 可选内容（置于背景之上）。
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: const BoxDecoration(color: AylaColors.ice100),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // 1–4：四角四色螺旋（tokens.css 28–31 行）
            const _RadialLayer(
              alignment: Alignment(-1, -1),
              colors: <Color>[AylaColors.ice300, Color(0x00BDD4E9)],
              stops: <double>[0, 0.5],
            ),
            const _RadialLayer(
              alignment: Alignment(1, -1),
              colors: <Color>[AylaColors.ice500, Color(0x009DBFE6)],
              stops: <double>[0, 0.5],
            ),
            const _RadialLayer(
              alignment: Alignment(1, 1),
              colors: <Color>[Color(0xA6F17EB3), Color(0x00F17EB3)],
              stops: <double>[0, 0.5],
            ),
            const _RadialLayer(
              alignment: Alignment(-1, 1),
              colors: <Color>[AylaColors.sakura100, Color(0x00FCD8FF)],
              stops: <double>[0, 0.5],
            ),
            // 5–8：四边中点白色光斑隔离蓝粉（tokens.css 32–35 行，45%）
            const _RadialLayer(
              alignment: Alignment(0, -1),
              colors: <Color>[AylaColors.surface, Color(0x00FFFAFB)],
              stops: <double>[0, 0.45],
            ),
            const _RadialLayer(
              alignment: Alignment(1, 0),
              colors: <Color>[AylaColors.surface, Color(0x00FFFAFB)],
              stops: <double>[0, 0.45],
            ),
            const _RadialLayer(
              alignment: Alignment(0, 1),
              colors: <Color>[AylaColors.surface, Color(0x00FFFAFB)],
              stops: <double>[0, 0.45],
            ),
            const _RadialLayer(
              alignment: Alignment(-1, 0),
              colors: <Color>[AylaColors.surface, Color(0x00FFFAFB)],
              stops: <double>[0, 0.45],
            ),
            // 9：中心暖白光晕。CSS（tokens.css 36）是 **4 个 stop**：
            //   `#fffafb 0%, rgba(255,250,251,.5) 33%, rgba(255,250,251,.15) 52%,
            //    rgba(255,250,251,0) 63%`
            // = 完全不透明 → 33% 降到 .5 → 52% 降到 .15 → 63% 归零。
            // 此前漏了 33% 这一档（只写 0/.52/.63）→ 中心过曝、扩散偏硬。
            const _RadialLayer(
              alignment: Alignment(0, 0),
              radius: 0.85,
              colors: <Color>[
                Color(0xFFFFFAFB), // 0%  rgba(255,250,251,1)
                Color(0x80FFFAFB), // 33% .5
                Color(0x26FFFAFB), // 52% .15
                Color(0x00FFFAFB), // 63% 0
              ],
              stops: <double>[0, 0.33, 0.52, 0.63],
            ),
            // 极淡网格纹理（tokens.css --bg-aurora-grid，96px 周期）：
            // repeating-linear-gradient 两个方向各一组，透明度极低。
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(painter: _AuroraGridPainter()),
              ),
            ),
            if (child != null) child!,
          ],
        ),
      ),
    );
  }
}

/// 极淡 96px 周期网格（--bg-aurora-grid：0.015 → 0.008 渐隐线）。
class _AuroraGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // `--bg-aurora-grid`（tokens.css 39–40）是两层 repeating-linear-gradient：
    //   repeating-linear-gradient(0deg,                  // 横线
    //     rgba(157,191,230,.015) 0 1px,                  //  0–1px  全亮
    //     rgba(157,191,230,.008) 3px,                    //  1→3px 渐隐到半亮
    //     transparent 4px 96px)                          //  4–96px 透明（周期 96）
    //   … 另一层为 90deg 竖线，参数相同。
    // **不是 1px 实线**：0→1px 全亮、1→3px 线性衰减到 .008、3→4px 再衰减到 0，
    // 4px 之后到底透明（每 96px 重复）。1px 实线会让网格偏硬、出现摩尔纹。
    const double period = 96;
    const double fadeEnd = 3; // 半亮位置（1→3px 线性衰减到 .008）
    const double zeroEnd = 4; // 完全透明位置（3→4px 衰减到 0）

    // stop 比例：0 → .015；1/4 → .008；3/4 → 0（4px 内完成整段渐隐）
    const List<double> stops = <double>[0, 1 / zeroEnd, fadeEnd / zeroEnd];
    final List<Color> ramp = <Color>[
      AylaColors.ice500.withValues(alpha: 0.015),
      AylaColors.ice500.withValues(alpha: 0.008),
      AylaColors.ice500.withValues(alpha: 0.0),
    ];

    for (double y = 0; y <= size.height; y += period) {
      // 横线（0deg）：从 y 向下 4px 渐隐
      canvas.drawRect(
        Rect.fromLTWH(0, y, size.width, zeroEnd),
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(0, y),
            Offset(0, y + zeroEnd),
            ramp,
            stops,
          ),
      );
    }
    for (double x = 0; x <= size.width; x += period) {
      // 竖线（90deg）：从 x 向右 4px 渐隐
      canvas.drawRect(
        Rect.fromLTWH(x, 0, zeroEnd, size.height),
        Paint()
          ..shader = ui.Gradient.linear(
            Offset(x, 0),
            Offset(x + zeroEnd, 0),
            ramp,
            stops,
          ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
