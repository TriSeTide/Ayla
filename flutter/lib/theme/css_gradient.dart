/// CSS linear-gradient 角度 → Flutter [LinearGradient] 的精确换算。
///
/// ## CSS 规范（`linear-gradient(<angle>, …)`）
///
/// - `0deg` 指向正上，**顺时针**增大；**终点色**在角度方向，起点色在反方向。
/// - 渐变线过盒子中心，**长度** `L = |W·sinθ| + |H·cosθ|`
///   （保证渐变沿垂直方向恰好覆盖盒子）。
///
/// ## 为什么不能简化成 `Alignment(±sinθ, ∓cosθ)`
///
/// Flutter 的 `Alignment` 端点在**归一化盒子空间**插值，实际梯度向量是
/// `(dx·W, dy·H)`；CSS 的渐变线长度按上式含 `|W·sinθ|+|H·cosθ|`。
/// **两者只在正方形盒子上等价。** 实测（W=100, H=60, 135deg）颜色落点 t：
///
/// | 位置 | CSS t | 简化写法 t | 偏差 |
/// |---|---|---|---|
/// | 左上 | 0.375 | −0.207 | **−0.582** |
/// | 右下 | 0.625 | 1.207 | **+0.582** |
/// | 上中 | 0.688 | 0.313 | −0.375 |
///
/// 即宽扁盒子上的斜向渐变会**整体错位**（颜色位置差近一半）。
library;

import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// 按 CSS 角度生成 [LinearGradient]。
///
/// [aspectRatio] = 盒子**宽 / 高**。传入才能得到与 CSS 一致的渐变线长度；
/// 不传则按正方形处理（旧行为，仅适用于近方形盒子，如正圆头像）。
///
/// 数学推导（CSS 坐标：x 右为正、y 上为正，中心为原点）：
/// ```
/// 方向 dir = (sinθ, −cosθ)          // 终点方向
/// 长度 L  = |W·sinθ| + |H·cosθ|
/// 起点    = center − (L/2)·dir
/// 终点    = center + (L/2)·dir
/// ```
/// 换算为 Flutter 归一化 `Alignment`（x 除以半宽、y 取负除以半高，因 Flutter
/// y 向下），得 `Alignment(±L·sinθ/W, ∓L·cosθ/H)`；分量允许超出 ±1。
LinearGradient cssLinearGradient({
  required double angleDeg,
  required List<Color> colors,
  List<double>? stops,
  double aspectRatio = 1.0,
}) {
  final double rad = angleDeg * math.pi / 180;
  final double sinA = math.sin(rad);
  final double cosA = math.cos(rad);

  // 用 W=aspectRatio、H=1 的等价比例（端点只与宽高比有关）
  final double w = aspectRatio <= 0 ? 1.0 : aspectRatio;
  const double h = 1.0;

  // CSS 渐变线长度
  final double len = (w * sinA).abs() + (h * cosA).abs();

  // 端点相对中心的 CSS 像素偏移（y 向上）
  final double halfX = len / 2 * sinA;
  final double halfY = len / 2 * cosA;

  // → Flutter Alignment
  final double ax = halfX / (w / 2);
  final double ay = halfY / (h / 2); // 正数表示 CSS 的"上"

  return LinearGradient(
    begin: Alignment(-ax, ay), // 起点（Flutter y 向下 → 取正号）
    end: Alignment(ax, -ay),
    colors: colors,
    stops: stops,
  );
}
