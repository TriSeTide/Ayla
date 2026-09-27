/// scrolling text（自 `primitives.dart` 拆出：一文件一件）。
///
/// 事实源与逐条对照见 `docs/flutter/17-组件文件头归档（整理前原文）.md` 的 `primitives.dart` 一节
/// 与各件的 `///` 头注。
///
/// ## 公开面
/// `AylaScrollingText`

library;

import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';

/// `.scroll-text` —— 长文本单行 marquee（溢出才滚，未溢出静态）。
///
/// 事实源 base.css 724–758：容器 `white-space: nowrap` + overflow hidden；
/// 溢出时内层按 `scroll-text-marquee` 来回滚动——0–20% 停开头、
/// 50–70% 停结尾、100% 回到开头，linear 匀速；时长由距离/速度得出并夹在
/// 4~16s。`prefers-reduced-motion` 关闭滚动只裁剪。
class AylaScrollingText extends StatefulWidget {
  const AylaScrollingText({
    super.key,
    required this.text,
    this.style,
    this.speed = 24,
  });

  /// 文本。
  final String text;

  /// 文字样式（默认 body）。
  final TextStyle? style;

  /// 每秒滚动像素（默认 24；越大越快）。
  final double speed;

  @override
  State<AylaScrollingText> createState() => _AylaScrollingTextState();
}

class _AylaScrollingTextState extends State<AylaScrollingText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _marquee = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 8),
  );

  /// 溢出距离（>0 才滚动）。用 TextPainter 同步测量，避免依赖"先渲染再回读"
  /// 造成的死锁：未溢出分支不带测量用的 key，就永远测不出溢出（此前实测
  /// 「长文本不滚」的根因）。
  double _overflow = 0;
  double _lastWidth = -1;

  /// marquee 时间轴（对齐 base.css keyframes 百分比）：
  /// 0–20% 停开头 → 20–50% 滚到尾 → 50–70% 停结尾 → 70–100% 滚回开头。
  double _offsetFor(double t) {
    if (t <= 0.2) return 0;
    if (t <= 0.5) return -(t - 0.2) / 0.3 * _overflow;
    if (t <= 0.7) return -_overflow;
    return -(1 - (t - 0.7) / 0.3) * _overflow;
  }

  TextStyle _resolveStyle(BuildContext context) =>
      widget.style ??
      AylaTextStyles.of(context)
          .body
          .copyWith(color: AylaColors.textPrimary);

  /// 测量文本自然宽度与容器可用宽度的差（正数=溢出）。
  void _measure(double available, TextStyle style, double scale) {
    if ((available - _lastWidth).abs() < 0.5) return; // 宽度没变不必重测
    _lastWidth = available;
    final TextPainter tp = TextPainter(
      text: TextSpan(text: widget.text, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.linear(scale),
    )..layout();
    final double overflow = tp.size.width - available;
    tp.dispose();

    final double next = overflow > 1 ? overflow : 0;
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (next > 0 && !reduceMotion) {
      // duration = clamp(distance / speed, 4, 16) 秒（web ScrollingText 同式）
      final double secs = (next / widget.speed).clamp(4.0, 16.0);
      _marquee.duration = Duration(milliseconds: (secs * 1000).round());
      if (!_marquee.isAnimating) _marquee.repeat();
    } else {
      _marquee.stop();
    }
    if ((next - _overflow).abs() > 0.5) {
      // 布局阶段更新测量结果：用 post-frame 避免 build 期间 setState
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _overflow = next);
      });
      _overflow = next; // 本帧即用新值（避免闪一帧静态）
    }
  }

  @override
  void dispose() {
    _marquee.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle style = _resolveStyle(context);
    final double scale = MediaQuery.textScalerOf(context).scale(1);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double available = constraints.maxWidth;
        if (available.isFinite && available > 0) {
          _measure(available, style, scale);
        }

        final Widget label = Text(
          widget.text,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.visible, // 溢出交给外层 ClipRect 裁
          style: style,
        );

        if (_overflow <= 0) {
          // 未溢出：静态单行（超出即省略，语义同 web 未溢出分支）
          return ClipRect(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                widget.text,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
          );
        }

        // 跑马灯是**持续循环动画**（4–16s 一圈）：包一层重绘边界，让每帧的
        // markNeedsPaint 止步于此 —— 否则它会一路上传到最近的边界（静态布局里
        // 就是整页重绘）。2026-09-25 全库审计：动画组件此前**没有一个**边界。
        return RepaintBoundary(
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _marquee,
              builder: (BuildContext context, Widget? child) {
                return Transform.translate(
                  offset: Offset(_offsetFor(_marquee.value), 0),
                  child: child,
                );
              },
              child: label,
            ),
          ),
        );
      },
    );
  }
}
