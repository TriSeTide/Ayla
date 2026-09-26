/// 1px 虚线圆角边框（CSS `border: 1px dashed`）——**共享件**。
///
/// 从 `channel_sidebar.dart` 的私有 `_DashedBorderPainter` 提升而来（2026-09-22）：
/// 直播侧栏的「新建直播间」键（`live.css 238`：`border: 1px dashed var(--ice-500)`）
/// 与频道侧栏的「更多」键（`group.css 1112`：`border: 1px dashed var(--glass-border)`）
/// 是同一个绘制需求 ⇒ 按「先复用、不重抄」的库内纪律合到一处。
///
/// 事实源（段长）：浏览器对 1px 虚线的常见画法是 **3px 实 / 3px 空**；CSS 未显式声明
/// `stroke-dasharray`（web 用的是原生 `dashed` 关键字）⇒ 取该常见值，两侧同一实现。
library;

import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

/// 虚线边框：以 [CustomPaint] 的 `foregroundPainter` 叠在子节点之上绘制（不占布局）。
///
/// ```dart
/// AylaDashedBorder(
///   radius: AylaRadii.rInput,
///   color: AylaColors.glassBorder,
///   child: SizedBox(height: 28, child: ...),
/// )
/// ```
class AylaDashedBorder extends StatelessWidget {
  const AylaDashedBorder({
    super.key,
    required this.child,
    required this.radius,
    required this.color,
    this.dash = 3,
    this.gap = 3,
  });

  /// 子节点（虚线画在它之上，尺寸取子节点的）。
  final Widget child;

  /// 圆角半径（CSS `border-radius`）。
  final double radius;

  /// 线色。
  final Color color;

  /// 实段长（px）。
  final double dash;

  /// 空段长（px）。
  final double gap;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      foregroundPainter: _DashedBorderPainter(
        radius: radius,
        color: color,
        dash: dash,
        gap: gap,
      ),
      child: child,
    );
  }
}

/// 1px 虚线圆角描边（`Canvas.drawPath` 逐段抽取）。
class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({
    required this.radius,
    required this.color,
    required this.dash,
    required this.gap,
  });

  final double radius;
  final Color color;
  final double dash;
  final double gap;

  @override
  void paint(Canvas canvas, Size size) {
    final Path outline = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
      );
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color;
    for (final PathMetric metric in outline.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final double end = math.min(distance + dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) =>
      old.radius != radius ||
      old.color != color ||
      old.dash != dash ||
      old.gap != gap;
}
