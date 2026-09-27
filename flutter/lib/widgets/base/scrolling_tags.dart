/// scrolling tags（自 `primitives.dart` 拆出：一文件一件）。
///
/// 事实源与逐条对照见 `docs/flutter/17-组件文件头归档（整理前原文）.md` 的 `primitives.dart` 一节
/// 与各件的 `///` 头注。
///
/// ## 公开面
/// `AylaScrollingTags`

library;

import 'package:flutter/material.dart';
import '../../theme/tokens.dart';
import 'tooltip.dart';

/// `.scroll-tags` —— 标签横向 marquee（溢出时滚 + **左右 14px 渐隐**）。
///
/// 事实源 `base.css` 760–806：
/// - `.scroll-tags`：`display:block`、`min-width:0`、overflow hidden、nowrap；
/// - `.scroll-tags-inner`：inline-flex、`gap: var(--sp-1)`、nowrap；
/// - 溢出时 `.scroll-tags-inner` 复用 `scroll-text-marquee` 关键帧（与
///   ScrollingText 同一时序：0–20% 停开头 / 50–70% 停结尾 / 100% 回开头，
///   linear，时长由组件测量夹 4~16s）；
/// - **溢出时左右边缘渐隐**（`mask-image: linear-gradient(to right,
///   transparent 0, #000 14px, #000 calc(100% - 14px), transparent 100%)`）
///   ——替代硬裁剪的生硬截断；未溢出时不加 mask。
/// - `prefers-reduced-motion`：停止滚动（仅裁剪）。
class AylaScrollingTags extends StatefulWidget {
  const AylaScrollingTags({
    super.key,
    required this.children,
    this.title,
    this.speed = 24,
    this.fadeWidth = 14, // mask 渐隐 14px（base.css）
  });

  /// 悬停提示（web prop «title»，ScrollingTags.tsx:54 ⇒ 原生 title 属性）。
  ///
  /// 调用方按 web 传法给值：直播来源标签传 «visibilityLabels.join("、")»
  /// （LiveRoomBody.tsx:257 / 325）。null/空 ⇒ 不提示（等价 title={undefined}）。
  final String? title;

  /// 标签（横向排列，间距 sp1）。
  final List<Widget> children;

  /// 每秒滚动像素（默认 24）。
  final double speed;

  /// 左右渐隐宽度（px，web 为 14px）。
  final double fadeWidth;

  @override
  State<AylaScrollingTags> createState() => _AylaScrollingTagsState();
}

class _AylaScrollingTagsState extends State<AylaScrollingTags>
    with SingleTickerProviderStateMixin {
  late final AnimationController _marquee = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 8),
  );

  /// 内部标签容器**右侧收窄量**（实测校准；0 = 与 web 同宽）。
  static const double _innerRightInset = 1;

  final GlobalKey _innerKey = GlobalKey();
  double _overflow = 0;

  double _offsetFor(double t) {
    if (t <= 0.2) return 0;
    if (t <= 0.5) return -(t - 0.2) / 0.3 * _overflow;
    if (t <= 0.7) return -_overflow;
    return -(1 - (t - 0.7) / 0.3) * _overflow;
  }

  void _measure(double available) {
    final RenderBox? inner =
        _innerKey.currentContext?.findRenderObject() as RenderBox?;
    if (inner == null || !available.isFinite || available <= 0) return;
    final double d = inner.size.width - available;
    final double next = d > 1 ? d : 0;
    if ((next - _overflow).abs() < 0.5) return;
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    setState(() => _overflow = next);
    if (next > 0 && !reduceMotion) {
      final double secs = (next / widget.speed).clamp(4.0, 16.0);
      _marquee.duration = Duration(milliseconds: (secs * 1000).round());
      if (!_marquee.isAnimating) _marquee.repeat();
    } else {
      _marquee.stop();
    }
  }

  @override
  void dispose() {
    _marquee.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool overflowing = _overflow > 0;

    // web «title»（ScrollingTags.tsx:54）：原生提示的平台等价物 ⇒ AylaTooltip。
    return AylaTooltip(
      message: widget.title,
      child: LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _measure(c.maxWidth);
        });

        // ⚠️ 标签**收窄**方案（按可用宽均分）已于 2026-09-22 按用户要求**回退**：
        // 收窄后内容不再溢出 ⇒ 滚动/marquee 与渐隐一起失效。
        // 内层 Row 保持内容自然宽度，溢出由容器裁剪 + 渐隐（对齐 web `.scroll-tags`）。
        final int count = widget.children.length;
        Widget content = Row(
          key: _innerKey,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int i = 0; i < count; i++) ...<Widget>[
              if (i > 0) const SizedBox(width: AylaSpacing.sp1), // gap: sp1
              widget.children[i],
            ],
          ],
        );

        if (overflowing) {
          content = AnimatedBuilder(
            animation: _marquee,
            builder: (BuildContext context, Widget? child) => Transform.translate(
              offset: Offset(_offsetFor(_marquee.value), 0),
              child: child,
            ),
            child: content,
          );
          // 持续循环动画：隔离重绘范围（见 scrolling_text.dart 同处说明）。
          content = RepaintBoundary(child: content);
        }

        // 内层 Row 按内容自然宽度排布，溢出由容器裁剪（对齐 web 的
        // `.scroll-tags { display:block; min-width:0; overflow:hidden; white-space:nowrap }`）。
        //
        // ⚠️ **高度必须等于内容**——2026-09-22 用户实测报「渐隐右边/下面有一条接缝线」
        // （语音卡、直播卡、帖子卡都中）。此前这里用 `SizedBox(height: 40)` +
        // `OverflowBox(min/maxHeight: 40)` 顶高度：本组件高度恒为 40（无界祖先）或父级可用高
        // （有界祖先），而真标签只有 ~23 ⇒ 父级一矮（卡片 meta 行 22.6 / head 行 32）
        // 就把居中的标签**上下裁掉几像素**，圆角被切断 ⇒ 看起来是一条接缝。
        // ⚠️ 也不能只用 `OverflowBox(maxWidth: infinity)`：它不设高时自身取父级最大高。
        // 正解 = 横向 `SingleChildScrollView`（禁手势）：子级拿**无界宽**（可超出、无 overflow 报错）、
        // 自身高度 = 内容高、自带裁剪 ⇒ mask / 裁剪 / 标签三者同高。
        // ⚠️ 必须关掉滚动条：桌面端 `Scrollable` 会自动挂 `Scrollbar`，其拇指会被画成
        // 一条**灰色竖线**（实测像素 `d7cbdb` vs 背景 `eeeeee`）——报的
        // 「渐隐右边有一条接缝线」就是它（每个标签条都有一条，看起来像容器的边）。
        // 库内 server_rail 同款处理（web 全局隐藏原生滚动条）。
        // ⚠️ **内部标签容器右侧收窄 1px**（校准，原话：
        // 「内部标签容器宽度收窄右侧一点点，渐隐遮罩完全不动」）。
        // 收窄只作用于**内层容器**（滚动视口 = 标签容器），**渐隐遮罩的几何一行未动**
        //（`ShaderMask` 仍以 LayoutBuilder 的尺寸为基准）——需要再调就改这里的数值。
        Widget clipped = Padding(
          padding: const EdgeInsets.only(right: _innerRightInset),
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(), // web `overflow: hidden`：不可拖
              clipBehavior: Clip.hardEdge,
              child: content,
            ),
          ),
        );

        // 溢出时套 mask 渐隐（未溢出不加，对齐 web）
        if (overflowing) {
          clipped = ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (Rect bounds) {
              // ⚠️ 渐隐几何 = 容器自身（web `.scroll-tags.is-overflow` 的 mask-image 同构）：
              // `linear-gradient(to right, transparent 0, #000 14px, #000 calc(100% - 14px),
              // transparent 100%)`（base.css 787–802）。
              // 2026-09-22 用户实测期间试过两种偏离（整体平移 1px / 右缘加宽 1px），**均已回退**——
              // 那两处改动对「边缘接缝」无效，改回与 web 同构的几何。
              final double w = bounds.width == 0 ? 1 : bounds.width;
              return LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: const <Color>[Color(0x00000000), Color(0xFF000000),
                    Color(0xFF000000), Color(0x00000000)],
                stops: <double>[
                  0,
                  widget.fadeWidth / w,
                  1 - widget.fadeWidth / w,
                  1,
                ],
              ).createShader(bounds);
            },
            child: clipped,
          );
        }

        return clipped;
        },
      ),
    );
  }
}

// ======================= 样张 =======================
