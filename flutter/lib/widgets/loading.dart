/// 加载族：LoadingSpinner / Skeleton / FullScreenLoader（base.css 515–574 行 / d:§7.3/7.4）。
///
/// 事实源：
/// - `.loading-spinner`：18px 圆、2px 环、`--ice-300` 轨道 +
///   `--indigo-700` 顶、800ms linear 整圈旋转；`--sm` 14px（消息发送
///   轨道用 rgba(70,91,146,.25)，由调用方传 trackColor）
/// - `.skeleton`：radius 8、`--glass-bg` + 1px `--glass-border`、
///   `frost-pulse` opacity .55↔.9 1600ms ease-in-out
/// - `.fullscreen-loader`：fixed 全屏 z 最高、垂直居中；品牌 40px Fredoka
///   600 渐变字（120deg indigo→grape，`line-height ≥1.25` 防 background-clip
///   裁字）+ spinner-md，无卡片容器、不放文案行
/// - reduced-motion：循环转圈与骨架脉冲停止，保留静态标识与预留尺寸
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../theme/aurora_background.dart';
import '../theme/css_gradient.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';

/// 加载转圈（base.css .loading-spinner / --sm）。
class LoadingSpinner extends StatelessWidget {
  const LoadingSpinner({
    super.key,
    this.size = 18,
    this.track = AylaColors.ice300,
    this.top = AylaColors.indigo700,
  });

  /// 直径（默认 18；sm 14）。
  final double size;

  /// 轨道色（--ice-300；消息发送用 rgba(70,91,146,.25)）。
  final Color track;

  /// 顶部推进色（--indigo-700）。
  final Color top;

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final double stroke = size >= 18 ? 2 : 2;
    return SizedBox(
      width: size,
      height: size,
      child: reduceMotion
          // reduced-motion：静态加载标识，不旋转
          ? DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: track, width: stroke),
              ),
            )
          : TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: AylaDurations.spin,
              curve: Curves.linear,
              builder: (BuildContext context, double t, Widget? child) {
                return CustomPaint(
                  painter: _SpinnerPainter(
                    progress: t,
                    track: track,
                    top: top,
                    stroke: stroke,
                  ),
                );
              },
            ),
    );
  }
}

class _SpinnerPainter extends CustomPainter {
  const _SpinnerPainter({
    required this.progress,
    required this.track,
    required this.top,
    required this.stroke,
  });

  final double progress;
  final Color track;
  final Color top;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = size.center(Offset.zero);
    final double radius = (size.shortestSide - stroke) / 2;
    final Paint trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawCircle(center, radius, trackPaint);

    // 顶部高亮弧：web 用 `border-top-color: --indigo-700` 实现，其余三边为
    // 轨道色（base.css 520–521）。CSS 圆角边框的四段是**梯形拼接**，接缝落在
    // 对角线方向 ⇒ top 段恰好覆盖 **90°**（π/2）。此前写 1.2 rad(≈69°) 是错的。
    final Paint topPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt // border 无圆头
      ..color = top;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2 + progress * 2 * math.pi, // 从 12 点方向起转
      math.pi / 2, // 90°：border-top 的可见段
      false,
      topPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _SpinnerPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

/// 骨架块（base.css .skeleton + frost-pulse）。
class AylaSkeleton extends StatefulWidget {
  const AylaSkeleton({
    super.key,
    this.width,
    this.height,
    this.radius = AylaRadii.rSm,
    this.shape = BoxShape.rectangle,
  });

  /// 宽（null = 撑满父约束）。
  final double? width;

  /// 高（null = 撑满父约束）。
  final double? height;

  /// 圆角（胶囊等特殊形态传 999）。
  final double radius;

  /// 形状（圆形头像骨架等）。
  final BoxShape shape;

  @override
  State<AylaSkeleton> createState() => _AylaSkeletonState();
}

class _AylaSkeletonState extends State<AylaSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: AylaDurations.pulse,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery 依赖只能在 didChangeDependencies 之后读取（initState 里
    // 读取会触发 framework 断言）。
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion) {
      _pulse.stop();
      _pulse.value = 0;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true); // ease-in-out 往返 = opacity .55↔.9
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final double opacity =
        reduceMotion ? 0.55 : (0.55 + 0.35 * _pulse.value);

    final Widget block = Opacity(
      opacity: opacity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: widget.shape,
          color: AylaColors.glassBg,
          border: Border.all(color: AylaColors.glassBorder),
          borderRadius: widget.shape == BoxShape.circle
              ? null
              : BorderRadius.circular(widget.radius),
        ),
      ),
    );

    if (widget.width == null && widget.height == null) return block;
    return SizedBox(width: widget.width, height: widget.height, child: block);
  }
}

/// 全屏加载界面（base.css .fullscreen-loader / d:§7.4）。
///
/// 场景：进入网页/刷新/登录（注册）成功后，核心数据预加载完成前覆盖全屏。
/// 品牌 40px Fredoka 600 渐变字 + spinner-md 直接浮于极光背景之上，
/// 无卡片容器、不放文案行。
class FullScreenLoader extends StatelessWidget {
  const FullScreenLoader({super.key, this.brand = 'Ayla'});

  /// 品牌文字（默认与 web .fullscreen-loader-brand 一致：Ayla）。
  final String brand;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const Positioned.fill(child: AuroraBackground()),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                brand,
                style: TextStyle(
                  fontFamily: AylaFonts.display,
                  fontFamilyFallback: AylaFonts.cjkFallback,
                  fontSize: 40,
                  fontWeight: FontWeight.w600,
                  height: 1.25, // ≥1.25：防渐变字裁剪字形（同 auth-brand 断言）
                  foreground: Paint()
                    ..shader = cssLinearGradient(
                      angleDeg: 120, // linear-gradient(120deg, indigo, grape)
                      colors: AylaGradients.brand,
                    ).createShader(const Rect.fromLTWH(0, 0, 200, 60)),
                ),
              ),
              const SizedBox(height: AylaSpacing.sp4), // gap: var(--sp-4)
              const LoadingSpinner(size: 18),
            ],
          ),
        ),
      ],
    );
  }
}

// ======================= 预览 =======================

/// 加载转圈（md 18px / sm 14px / 消息发送轨道色）。
@Preview(
  group: 'Widgets',
  name: 'LoadingSpinner md/sm/消息轨道',
  size: Size(360, 140),
  wrapper: previewTheme,
)
Widget loadingSpinnerPreview() {
  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp6),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: const <Widget>[
        LoadingSpinner(),
        SizedBox(width: AylaSpacing.sp6),
        LoadingSpinner(size: 14),
        SizedBox(width: AylaSpacing.sp6),
        LoadingSpinner(track: Color(0x40465B92)),
      ],
    ),
  );
}

/// 骨架块（头像圆 / 文本行 / 胶囊）。
@Preview(
  group: 'Widgets',
  name: 'AylaSkeleton 圆/行/胶囊',
  size: Size(420, 220),
  wrapper: previewTheme,
)
Widget skeletonPreview() {
  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Row(
          children: <Widget>[
            AylaSkeleton(
              width: 44,
              height: 44,
              radius: AylaRadii.rPill,
              shape: BoxShape.circle,
            ),
            SizedBox(width: AylaSpacing.sp3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  AylaSkeleton(width: 120, height: 14),
                  SizedBox(height: AylaSpacing.sp2),
                  AylaSkeleton(width: 200, height: 12),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AylaSpacing.sp4),
        const AylaSkeleton(width: 96, height: 24, radius: AylaRadii.rPill),
      ],
    ),
  );
}

/// 全屏加载界面。
@Preview(
  group: 'Widgets',
  name: 'FullScreenLoader',
  size: Size(420, 300),
  wrapper: previewTheme,
)
Widget fullScreenLoaderPreview() => const FullScreenLoader();
