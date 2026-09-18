/// CSS linear-gradient 角度 → Flutter [LinearGradient] 的精确换算。
///
/// CSS 角度语义（`linear-gradient(135deg, …)`）：0deg = 指向正上，
/// 顺时针增大；渐变**终点**（最后一个颜色）指向该角，起点（第一个颜色）
/// 在反方向。换算基准见 tokens.css `--fluid-gradient-angle` 等用法。
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// 按 CSS 角度生成 [LinearGradient]。
///
/// [begin]/[end] 由角度换算，向量不强制归一化（LinearGradient 按盒子
/// 尺寸缩放，比例正确即可）。
LinearGradient cssLinearGradient({
  required double angleDeg,
  required List<Color> colors,
  List<double>? stops,
}) {
  final double rad = angleDeg * math.pi / 180;
  // 终点方向：x = sin(θ)（右为正），y = -cos(θ)（上为正 → Alignment 下为正）
  final double dx = math.sin(rad);
  final double dy = -math.cos(rad);
  return LinearGradient(
    begin: Alignment(-dx, -dy),
    end: Alignment(dx, dy),
    colors: colors,
    stops: stops,
  );
}
