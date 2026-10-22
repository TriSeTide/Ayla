/// CSS `width: fit-content` 的 Flutter 等价（2026-10-22 二轮）。
///
/// ## 为什么需要它（真机实报「语音气泡撑满整行」的根因）
///
/// 消息气泡的宽度链在 CSS 里分**两趟**算：
///
/// 1. **intrinsic 趟（自下而上）**：先算每层盒子的 max-content；
/// 2. **布局趟（自上而下）**：把 max-content 用祖先的 `max-width` 夹住。
///
/// 关键：第 1 趟里 `.voice-wave{flex:1}` 贡献的是**它自己的 max-content**
/// （= 144），**不是** `.msg-body` 的 75% 上限；到第 2 趟才可能被夹小。
///
/// Flutter 只有一趟：`Align(widthFactor:1)` 之类的 shrink-to-fit 是「用**已有约束**
/// 布局一次，再用子级尺寸定自身」——子级拿到的 `maxWidth` 已经是被 75% 夹过的值，
/// 于是内部 `Expanded` / `Row` 直接把那个上限当成内容宽 ⇒ 卡片被拉成整行。
///
/// 本件补上**第 1 趟**：先用**无界主轴**布局一次拿 max-content，再用可用宽夹住
/// 并把子级按最终宽重排（与浏览器一致，两趟）。
///
/// ## 与 `IntrinsicWidth` 的区别（为什么不用现成的）
///
/// Flutter 的 `IntrinsicWidth` 走 `computeMaxIntrinsicWidth`，而**媒体子树里含
/// `LayoutBuilder`**（`_ImageMedia` / `_MixedMedia`）—— Flutter 明确不支持对含
/// `LayoutBuilder` 的子树求 intrinsic，会抛
/// `LayoutBuilder does not support returning intrinsic dimensions`。
/// 本件改用「真布局一遍」求 max-content，因此对这类子树同样有效。
///
/// ⚠️ 前提：子树在**无界主轴**下必须能完成布局。若子树内部用 `Expanded`（flex:1），
/// 无界时 `RenderFlex` 会断言 ⇒ 必须先用 [AylaFillOrNatural] 表达
/// 「有界占满 / 无界取内容宽」两档语义。
library;

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// CSS `width: fit-content`（主轴 = 横向）。
///
/// 宽 = clamp(**max-content**, [minWidth], min([maxWidth], 可用宽))。
class AylaFitContent extends SingleChildRenderObjectWidget {
  const AylaFitContent({
    super.key,
    this.minWidth = 0,
    this.maxWidth = double.infinity,
    required super.child,
  });

  /// 等价 CSS `min-width`（订阅自身盒子）。
  final double minWidth;

  /// 等价 CSS `max-width`（订阅自身盒子）。
  final double maxWidth;

  @override
  AylaFitContentRenderObject createRenderObject(BuildContext context) =>
      AylaFitContentRenderObject(minWidth: minWidth, maxWidth: maxWidth);

  @override
  void updateRenderObject(
    BuildContext context,
    AylaFitContentRenderObject renderObject,
  ) {
    renderObject
      ..minWidth = minWidth
      ..maxWidth = maxWidth;
  }
}

/// 公开（而非 _ 私有）：[AylaFitContent.createRenderObject] 的返回类型出现在
/// 公开 API 上，用私有类型会触发 library_private_types_in_public_api。
class AylaFitContentRenderObject extends RenderProxyBox {
  AylaFitContentRenderObject({
    double minWidth = 0,
    double maxWidth = double.infinity,
  })  : _minWidth = minWidth,
        _maxWidth = maxWidth;

  double _minWidth;
  double get minWidth => _minWidth;
  set minWidth(double v) {
    if (_minWidth == v) return;
    _minWidth = v;
    markNeedsLayout();
  }

  double _maxWidth;
  double get maxWidth => _maxWidth;
  set maxWidth(double v) {
    if (_maxWidth == v) return;
    _maxWidth = v;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    final BoxConstraints c = constraints;
    if (child == null) {
      size = c.constrain(Size(c.minWidth, 0));
      return;
    }

    // ---- 第 1 趟：无界主轴测 max-content（等价 CSS 的 intrinsic 趟）----
    // 高度方向沿用父级约束：本件只解宽度，垂直方向不该被无界化
    // （否则 SingleChildScrollView 之类会算错）。
    child.layout(
      BoxConstraints(
        minWidth: 0,
        maxWidth: double.infinity,
        minHeight: c.minHeight,
        maxHeight: c.maxHeight,
      ),
      parentUsesSize: true,
    );
    final double maxContent = child.size.width;

    // ---- 第 2 趟：clamp(max-content, 自身 min/max-width)，再夹可用宽 ----
    // min-width **压过**可用宽（CSS 规范：min-width 优先，允许溢出父级、
    // 由祖先 overflow 裁剪）。实测证据：375 档 .voice-card 宽 240，而气泡内容盒
    // 只有 204.31 ⇒ 波形确实被裁掉一截，浏览器行为如此。
    double w = math.max(maxContent, _minWidth);
    if (_maxWidth.isFinite) w = math.min(w, _maxWidth);
    if (c.maxWidth.isFinite) w = math.min(w, math.max(c.maxWidth, _minWidth));
    w = math.max(0, w);

    // ---- 按最终宽重排（波形重新分配，等价浏览器的第二次布局）----
    child.layout(
      BoxConstraints.tightFor(width: w).copyWith(
        minHeight: c.minHeight,
        maxHeight: c.maxHeight,
      ),
      parentUsesSize: true,
    );

    size = c.constrain(Size(w, child.size.height));
  }
}

/// `flex: 1` 的「有界占满 / 无界取内容宽」等价件（主轴 = 横向）。
///
/// CSS 的 `flex:1` 项在**两趟**里语义不同：
/// - 布局趟（父级有界）⇒ 占满剩余空间；
/// - intrinsic 趟（父级主轴无界，求 max-content）⇒ 贡献**自身内容宽**。
///
/// Flutter 的 `Expanded` 只有前者，无界时会断言
/// （`RenderFlex children have non-zero flex but incoming width constraints are unbounded`）。
///
/// 语义：
/// - 父级主轴**有界** ⇒ 宽 = 父级给的 `maxWidth`（与 `Expanded` 逐像素一致）；
/// - 父级主轴**无界** ⇒ 宽 = [minWidth]（= 该项自己算出的 max-content）。
///
/// [minWidth] 必须从事实源推导（不得估计）；调用点见 `media_content.dart`
/// 的语音卡（`.voice-wave { flex:1 }` / `.voice-seek { flex:1 }`）。
class AylaInlineSize extends StatelessWidget {
  const AylaInlineSize({
    super.key,
    required this.minWidth,
    required this.child,
  });

  /// 无界主轴时的宽度（= CSS 该项的 max-content）。
  final double minWidth;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // 有界 ⇒ 占满（等价 flex:1）；无界 ⇒ 取 max-content。
        // 只决定**主轴**尺寸：高度由 child 自己给（.voice-wave 的 height:36 由调用方设）。
        final double width = c.maxWidth.isFinite ? c.maxWidth : minWidth;
        return SizedBox(width: width, child: child);
      },
    );
  }
}

/// 同上，但「无界主轴」时的宽度由**子级自然宽**决定（不传固定值）。
///
/// 适用于 `flex:1` 项的内容宽是**动态**的场景（文件名、标题…）。
/// 有界 ⇒ 占满父级给的 `maxWidth`；无界 ⇒ 用无界主轴布局子级、取其自然宽
/// （= CSS 该项的 max-content）。
class AylaInlineNaturalSize extends SingleChildRenderObjectWidget {
  const AylaInlineNaturalSize({super.key, required super.child});

  @override
  AylaInlineNaturalSizeRenderObject createRenderObject(BuildContext context) =>
      AylaInlineNaturalSizeRenderObject();
}

/// 公开（而非 _ 私有）：[AylaInlineNaturalSize.createRenderObject] 的返回类型
/// 出现在公开 API 上，用私有类型会触发 library_private_types_in_public_api。
class AylaInlineNaturalSizeRenderObject extends RenderProxyBox {
  @override
  void performLayout() {
    final RenderBox? child = this.child;
    final BoxConstraints c = constraints;
    if (child == null) {
      size = c.constrain(Size(c.minWidth, 0));
      return;
    }
    if (c.maxWidth.isFinite) {
      // 有界 ⇒ 占满（等价 flex:1）。
      child.layout(
        BoxConstraints.tightFor(width: c.maxWidth).copyWith(
          minHeight: c.minHeight,
          maxHeight: c.maxHeight,
        ),
        parentUsesSize: true,
      );
      size = c.constrain(Size(c.maxWidth, child.size.height));
      return;
    }
    // 无界 ⇒ 子级的自然宽（等价 CSS intrinsic 趟里 flex:1 项贡献自身 max-content）。
    child.layout(
      BoxConstraints(
        minWidth: 0,
        maxWidth: double.infinity,
        minHeight: c.minHeight,
        maxHeight: c.maxHeight,
      ),
      parentUsesSize: true,
    );
    size = c.constrain(Size(child.size.width, child.size.height));
  }
}
