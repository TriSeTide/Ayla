/// 迷你 SVG path 解析 + 绘制（库内公共件）—— 服务**组件级内联 glyph**。
///
/// ## 事实源 / 分工
/// web 的图标分两种：
/// 1. **`components/icons.tsx` 全量 47 个**（24 viewBox、元素级 fill/stroke）⇒ 走 `appIconsData` + `AylaIcon`；
/// 2. **内联 `<svg>` glyph**（不在 icons.tsx 里，组件/页面自带）⇒ 走本文件：
///    - `layout/ChannelSidebar.tsx:621` — pencil（`M17 3a2.85 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z`，24 viewBox / stroke 2）
///    - `pages/group/GroupInfo.tsx:1012` — 同一个 pencil（页面未实现，届时直接用本件）
///    - `components/motion/PullToRefresh.tsx:266–272` — check（`M3 8.5l3.2 3.2L13 5`，**16 viewBox** / stroke 2）
///      与 arrow（`M3.5 6l4.5 4.5L12.5 6`，**16 viewBox** / stroke 2）
///    - `components/chat/ConversationMoreMenu.tsx:188` — trash（**实心**，24 viewBox）
///
/// ⚠️ **禁止用 Material Icons 顶替**：本项目已把「图标先用 Material 占位」列为偷懒案例；
/// 2026-09-25 审计发现 `AylaRefreshDot` 的 check / arrow 曾用 `Icons.check` / `Icons.keyboard_arrow_down` 顶替
/// （web 是 16 viewBox 自绘）⇒ 已改为本件。
///
/// ## 覆盖范围
/// 命令 `M/m L/l H/h V/v A/a Z/z`；`A/a` 只取半径与终点（**不解析 large-arc / sweep 标志**）——
/// 库内既有取舍，够用即可，新增 glyph 若用到其它命令需在此扩展。
library;

import 'package:flutter/material.dart';

/// 解析迷你 SVG path。
///
/// ⚠️ 分词必须用「命令字母 | 数字」正则，**不能按空白切分**：SVG path 里数字可以紧凑书写
/// （`m9 6 6 6-6 6` 的 `6-6`），按空白切会得到 `'6-6'` → `double.parse` 抛 `FormatException`（实测踩过）。
Path aylaParseSvgPath(String d) {
  final Path path = Path();
  final RegExp tokenRe = RegExp(r'[MLHVAZmlhvaz]|-?\d*\.?\d+(?:[eE][-+]?\d+)?');
  final List<String> tokens = tokenRe
      .allMatches(d)
      .map((RegExpMatch m) => m[0]!)
      .toList();
  double x = 0;
  double y = 0;
  double sx = 0;
  double sy = 0;
  int i = 0;
  String cmd = '';
  double next() => double.parse(tokens[i++]);
  bool isCmd(String t) => t.length == 1 && 'MLHVAZmlhvaz'.contains(t);

  while (i < tokens.length) {
    if (isCmd(tokens[i])) {
      cmd = tokens[i];
      i++;
      if (cmd == 'Z' || cmd == 'z') {
        path.close();
        x = sx;
        y = sy;
      }
      continue;
    }
    switch (cmd) {
      case 'M':
        x = next();
        y = next();
        sx = x;
        sy = y;
        path.moveTo(x, y);
        cmd = 'L';
      case 'm':
        x += next();
        y += next();
        sx = x;
        sy = y;
        path.moveTo(x, y);
        cmd = 'l';
      case 'L':
        x = next();
        y = next();
        path.lineTo(x, y);
      case 'l':
        x += next();
        y += next();
        path.lineTo(x, y);
      case 'H':
        x = next();
        path.lineTo(x, y);
      case 'h':
        x += next();
        path.lineTo(x, y);
      case 'V':
        y = next();
        path.lineTo(x, y);
      case 'v':
        y += next();
        path.lineTo(x, y);
      case 'A':
        final double rx = next();
        final double ry = next();
        next(); // x-axis-rotation
        next(); // large-arc-flag
        next(); // sweep-flag
        x = next();
        y = next();
        path.arcToPoint(Offset(x, y), radius: Radius.elliptical(rx, ry));
      case 'a':
        final double rx = next();
        final double ry = next();
        next();
        next();
        next();
        x += next();
        y += next();
        path.arcToPoint(Offset(x, y), radius: Radius.elliptical(rx, ry));
      default:
        i++;
    }
  }
  return path;
}

/// 内联 glyph：按 [viewBox] 把 [d] 缩放到 [size] 绘制（描边默认 / [filled] 实心）。
class AylaSvgGlyph extends StatelessWidget {
  const AylaSvgGlyph({
    super.key,
    required this.d,
    required this.size,
    this.color,
    this.viewBox = 24,
    this.strokeWidth = 2,
    this.filled = false,
  });

  /// path 数据（web 内联 `<svg><path d="…"/></svg>` 原文，逐字照抄）。
  final String d;

  /// 绘制边长（= web 的 `width/height`）。
  final double size;

  /// 颜色（null ⇒ 由祖先决定时传具体色，库内惯例是显式传 `AylaColors.*`）。
  final Color? color;

  /// 原 SVG 的 viewBox 边长（web 有 24 与 16 两种，勿混）。
  final double viewBox;

  /// `stroke-width`（web 内联 glyph 一律 2）。
  final double strokeWidth;

  /// `fill="currentColor" stroke="none"` 的实心 glyph（如菜单垃圾桶）。
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _AylaSvgGlyphPainter(
        d: d,
        color: color ?? IconTheme.of(context).color ?? const Color(0xFF465B92),
        viewBox: viewBox,
        strokeWidth: strokeWidth,
        filled: filled,
      ),
    );
  }
}

class _AylaSvgGlyphPainter extends CustomPainter {
  const _AylaSvgGlyphPainter({
    required this.d,
    required this.color,
    required this.viewBox,
    required this.strokeWidth,
    required this.filled,
  });

  final String d;
  final Color color;
  final double viewBox;
  final double strokeWidth;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    if (d.isEmpty) return;
    canvas.save();
    canvas.scale(size.width / viewBox, size.height / viewBox);
    canvas.drawPath(
      aylaParseSvgPath(d),
      filled
          ? (Paint()
              ..style = PaintingStyle.fill
              ..color = color)
          : (Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = strokeWidth // stroke-width: 2
              ..strokeCap = StrokeCap.round // stroke-linecap: round
              ..strokeJoin = StrokeJoin.round // stroke-linejoin: round
              ..color = color),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AylaSvgGlyphPainter old) =>
      old.d != d ||
      old.color != color ||
      old.viewBox != viewBox ||
      old.strokeWidth != strokeWidth ||
      old.filled != filled;
}
