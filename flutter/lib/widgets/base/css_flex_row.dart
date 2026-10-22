/// CSS display:flex 主轴 flex-shrink 的 Flutter 等价件。
///
/// ## 为什么需要它（与 Flutter Flexible 的语义差异）
///
/// CSS 与 Flutter 在「主轴空间不够时怎么分配」上是**两套完全不同的算法**：
///
/// | 情况 | CSS flex-shrink: 1 | Flutter Flexible |
/// |---|---|---|
/// | 空间够 | 所有人用**自然宽**（flex-basis: auto） | 仍然按 flex 因子**分配**剩余空间 |
/// | 空间不够 | 溢出量按 shrink × flex-basis 加权**收缩** | 同样按 flex 因子分配 |
/// | 下界 | min-width（默认 auto = min-content；overflow:hidden 时 = 0） | 0（fit: loose）/ 由 Expanded 强行撑满 |
///
/// 因此 **Flexible 不是 flex-shrink 的等价物** —— 它在空间充足时也会改变宽度。
/// 本项目实测过这条：把消息行的操作栏改成 Flexible 后，900 档气泡从 633 腰斩到 395
/// （见 widgets/chat/message_bubble.dart 文件头）。
///
/// 本件按 CSS Flexible Box Layout Module Level 1 §9.7 Resolving Flexible Lengths
/// 的**收缩分支**逐条实现，并且**只在真正溢出时才收缩**。
///
/// ## 算法（逐条对应规范）
///
/// 1. **flex base size**（规范 §9.2）：每个子项按自身自然宽（flex-basis: auto
///    = max-content，再被自身 max-width 夹住）—— 本件用「无界主轴测量一遍」拿到；
/// 2. **主轴自由空间** = 容器可用宽 − Σbase − gap×(n−1)；
/// 3. **不溢出 ⇒ 全部用 base**（这是与 Flexible 的根本区别）；
/// 4. **溢出 ⇒ 收缩**：可收缩项的缩放因子 = flex-shrink × base，溢出量按缩放因子
///    占比分摊；若某项触到自己的 min-width（[AylaCssFlexItem.minWidth]）则**冻结**
///    在该下界，把剩余溢出量在其余可收缩项之间**重新分摊**（规范 §9.7 的循环）；
/// 5. 用最终宽**重新布局**被改宽的项（文字因此重新折行，与浏览器一致）。
///
/// ## 事实源
/// - Ayla/web/src/styles/app.css:1041–1046  .msg-row { display:flex;
///   align-items:flex-end; gap:var(--sp-2); padding: 0 var(--sp-1) }
/// - app.css:1069–1071  .msg-row.self { flex-direction: row-reverse }
/// - app.css:1073–1083  .msg-body { max-width:75%; min-width:0 }
/// - app.css:1290–1298  .msg-actions { display:flex; align-items:center; gap:var(--sp-1) }
/// - app.css:1324–1333  .msg-action-btn { padding: 6px 8px; font-size:12px }
///   **无 flex-shrink: 0、无 white-space: nowrap** ⇒ 默认 shrink:1 且标签可折行；
/// - auroraqua.css:142–146  :is(.btn, .msg-action-btn, …) { position:relative;
///   overflow:hidden; isolation:isolate } ⇒ 按钮 overflow: hidden
///   ⇒ 按规范 §4.5「automatic minimum size」的例外条款，其 min-width: auto
///   解析为 **0**（实测印证：375 档 .msg-action-btn 从 57.6 压到 33.6，
///   低于它自己的 min-content 44.8）。
///
/// ## 与 CSS 的已知差异（登记，不掩盖）
/// 1. **intrinsic 尺寸返回 0**：容器要量每个子项的「自然宽」，而消息体子树里有
///    LayoutBuilder（media_content.dart:509/943、share_bubble.dart:301），
///    Flutter 明确不支持对含 LayoutBuilder 的子树求 intrinsic（会抛
///    LayoutBuilder does not support returning intrinsic dimensions）。
///    ⇒ 本件不实现 intrinsic（与同目录的 [AylaCssColumns] 一致），
///    **不得**把它放进 IntrinsicWidth / IntrinsicHeight。
/// 2. **测量是「布局一遍再重排被改宽的项」**（浏览器同样分两趟）：
///    只有真正收缩的项会布局两次，未收缩时零额外开销。
/// 3. **只实现收缩分支**：flex-grow、flex-wrap、order、baseline 对齐
///    均未实现（当前用途不需要；需要时按同样的方式补）。
///
/// ## 公开面
/// [AylaCssFlexRow] · [AylaCssFlexItem]
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 浮点容差：真实像素下 Σbase 与可用宽恰好相等是常见边界
/// （例：.msg-row 的 343 = 37 + 8 + 158 + 8 + 132），必须按 <= 判「不溢出」。
const double kAylaCssFlexEpsilon = 0.001;

/// 单个子项在主轴上的 flex 参数（等价 CSS 里该 item 的 flex-shrink / min-width）。
///
/// 必须是 [AylaCssFlexRow] 的**直接子级**。
class AylaCssFlexItem extends ParentDataWidget<AylaCssFlexItemParentData> {
  const AylaCssFlexItem({
    super.key,
    this.flexShrink = 1.0,
    this.minWidth = 0,
    this.minContentWidth,
    required super.child,
  });

  /// 等价 flex-shrink（CSS 默认 1；0 = 不参与收缩）。
  final double flexShrink;

  /// 收缩的硬下界（等价 CSS 显式写的 min-width）。
  ///
  /// 调用方按**实际解析结果**显式传入：
  /// - .favorite-toggle.is-compact 的 min-width: 32px ⇒ 32；
  /// - .msg-body 显式写了 min-width: 0 ⇒ 0（默认值）。
  final double minWidth;

  /// 等价 CSS 的 **min-content 主轴尺寸**（规范 §4.5 automatic minimum size）。
  ///
  /// 传 null ⇒ 无内容下界（只受 [minWidth] 约束）。
  /// 子项自己就是个 flex 容器时（工具栏），这里传它自己的 min-content
  /// 之和（= 每个按钮的 min-content + gap），与 CSS 逐层递推的方式一致。
  final double? minContentWidth;

  @override
  void applyParentData(RenderObject renderObject) {
    assert(renderObject.parentData is AylaCssFlexItemParentData);
    final AylaCssFlexItemParentData data =
        renderObject.parentData! as AylaCssFlexItemParentData;
    bool needsLayout = false;
    if (data.flexShrink != flexShrink) {
      data.flexShrink = flexShrink;
      needsLayout = true;
    }
    if (data.minWidth != minWidth) {
      data.minWidth = minWidth;
      needsLayout = true;
    }
    if (data.minContentWidth != minContentWidth) {
      data.minContentWidth = minContentWidth;
      needsLayout = true;
    }
    if (needsLayout) {
      final RenderObject? target = renderObject.parent;
      if (target != null) target.markNeedsLayout();
    }
  }

  @override
  Type get debugTypicalAncestorWidgetClass => AylaCssFlexRow;
}

/// [AylaCssFlexItem] 写入子项的布局参数。
class AylaCssFlexItemParentData extends ContainerBoxParentData<RenderBox> {
  /// 等价 CSS flex-shrink。
  double flexShrink = 1.0;

  /// 等价 CSS min-width（收缩下界）。
  double minWidth = 0;

  /// 等价 CSS 的 min-content 主轴尺寸；null = 无内容下界。
  double? minContentWidth;
}

/// CSS display:flex（单行、主轴横向、只收缩不增长）的等价容器。
///
/// 用法（消息行，与 app.css:1041–1071 同构）：
/// ```dart
/// AylaCssFlexRow(
///   gap: AylaSpacing.sp2,                          // gap: var(--sp-2)
///   crossAxisAlignment: CrossAxisAlignment.end,    // align-items: flex-end
///   mainAxisAlignment: isSelf ? MainAxisAlignment.end : MainAxisAlignment.start,
///   children: <Widget>[
///     AylaCssFlexItem(flexShrink: 0, child: halo),  // .msg-sender-halo 有 flex-shrink:0
///     AylaCssFlexItem(child: body),                 // .msg-body（max-width 由自身约束给出）
///     AylaCssFlexItem(child: actions),              // .msg-actions（默认 shrink 1）
///   ],
/// )
/// ```
class AylaCssFlexRow extends MultiChildRenderObjectWidget {
  const AylaCssFlexRow({
    super.key,
    this.gap = 0,
    this.mainAxisAlignment = MainAxisAlignment.start,
    this.crossAxisAlignment = CrossAxisAlignment.end,
    this.mainAxisSize = MainAxisSize.max,
    required super.children,
  });

  /// 主轴项间距（等价 CSS gap）。**不可收缩**，只在相邻两项之间出现。
  final double gap;

  /// 容器自身宽度取法。
  ///
  /// - [MainAxisSize.max]（默认）= CSS `display:flex` 的**块级**容器：占满可用宽
  ///   （消息行 `.msg-row` 就是这个形态）；
  /// - [MainAxisSize.min] = 作为**内层 flex item** 时按内容收缩
  ///   （`.msg-actions` 是内层 flex 容器，宽度 = 子键之和）。
  ///
  /// 注意这两者**都不是** Flutter `Row` 的「分配剩余空间」语义：收缩/放置
  /// 全部按 flex-shrink 规则算完之后，容器只是决定「我自己的宽是多少」。
  final MainAxisSize mainAxisSize;

  final MainAxisAlignment mainAxisAlignment;

  /// 交叉轴对齐。CSS 侧消息行是 align-items: flex-end（底部对齐）。
  final CrossAxisAlignment crossAxisAlignment;

  @override
  AylaCssFlexRowRenderObject createRenderObject(BuildContext context) =>
      AylaCssFlexRowRenderObject(
        gap: gap,
        mainAxisAlignment: mainAxisAlignment,
        crossAxisAlignment: crossAxisAlignment,
        mainAxisSize: mainAxisSize,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    AylaCssFlexRowRenderObject renderObject,
  ) {
    renderObject
      ..gap = gap
      ..mainAxisAlignment = mainAxisAlignment
      ..crossAxisAlignment = crossAxisAlignment
      ..mainAxisSize = mainAxisSize;
  }
}

/// 公开（而非 _ 私有）：[AylaCssFlexRow.createRenderObject] 的返回类型出现在公开
/// API 上，用私有类型会触发 library_private_types_in_public_api（项目基线零告警）。
class AylaCssFlexRowRenderObject extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, AylaCssFlexItemParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, AylaCssFlexItemParentData> {
  AylaCssFlexRowRenderObject({
    required double gap,
    required MainAxisAlignment mainAxisAlignment,
    required CrossAxisAlignment crossAxisAlignment,
    required MainAxisSize mainAxisSize,
  })  : _gap = gap,
        _mainAxisAlignment = mainAxisAlignment,
        _crossAxisAlignment = crossAxisAlignment,
        _mainAxisSize = mainAxisSize;

  double _gap;
  MainAxisAlignment _mainAxisAlignment;
  CrossAxisAlignment _crossAxisAlignment;
  MainAxisSize _mainAxisSize;

  MainAxisSize get mainAxisSize => _mainAxisSize;
  set mainAxisSize(MainAxisSize value) {
    if (_mainAxisSize == value) return;
    _mainAxisSize = value;
    markNeedsLayout();
  }

  double get gap => _gap;
  set gap(double value) {
    if (_gap == value) return;
    _gap = value;
    markNeedsLayout();
  }

  MainAxisAlignment get mainAxisAlignment => _mainAxisAlignment;
  set mainAxisAlignment(MainAxisAlignment value) {
    if (_mainAxisAlignment == value) return;
    _mainAxisAlignment = value;
    markNeedsLayout();
  }

  CrossAxisAlignment get crossAxisAlignment => _crossAxisAlignment;
  set crossAxisAlignment(CrossAxisAlignment value) {
    if (_crossAxisAlignment == value) return;
    _crossAxisAlignment = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! AylaCssFlexItemParentData) {
      // CSS 默认 flex-shrink: 1（未写 AylaCssFlexItem 时按默认值处理）。
      child.parentData = AylaCssFlexItemParentData();
    }
  }

  AylaCssFlexItemParentData _dataOf(RenderBox child) =>
      child.parentData! as AylaCssFlexItemParentData;

  /// 收缩量分摊（规范 §9.7 的收缩分支）。返回每项的最终主轴尺寸。
  ///
  /// [floorAt] 决定每次迭代用哪个下界判「冻结」：
  /// - 第 1 趟用 **min-content**（规范 §9.7 step 3 的 `min-size` 语义：
  ///   浏览器的初始布局也不会把 flex item 压到 min-content 以下）；
  /// - 第 2 趟用 **硬 min-width**（规范 §9.7 step 5 的 clamp）。
  ///
  /// 为什么要分两趟：若直接 clamp 到硬下界，会**跳过** min-content 这一段
  /// 「按钮继续压窄、文字逐字折行」的过程（实测：直接 clamp 到 0 时 375 档气泡
  /// 被压到 132，而浏览器只压到 183）。分两趟后与浏览器一致 —— 先压到 min-content
  /// （文字折行），只有还溢出才破 min-content 直到硬 min-width。
  List<double> _resolveShrink({
    required List<double> base,
    required List<double> shrink,
    required List<double> minWidths,
    required List<double> minContents,
    required double available,
    required bool floorAt,
  }) {
    final int n = base.length;
    final List<double> floors = <double>[
      for (int i = 0; i < n; i++)
        floorAt ? math.max(minWidths[i], minContents[i]) : minWidths[i],
    ];
    final List<double> result = List<double>.of(base);
    final List<bool> frozen = List<bool>.filled(n, false);
    for (int i = 0; i < n; i++) {
      if (shrink[i] <= 0 || base[i] <= floors[i] + kAylaCssFlexEpsilon) {
        frozen[i] = true;
      }
    }

    // 规范 §9.7 的循环：冻结项不参与分摊，每次冻结后剩余量重新分摊。
    for (int guard = 0; guard <= n; guard++) {
      double frozenSum = 0;
      double shrinkableSum = 0;
      double scaledSum = 0;
      for (int i = 0; i < n; i++) {
        if (frozen[i]) {
          frozenSum += result[i];
        } else {
          shrinkableSum += result[i];
          scaledSum += shrink[i] * base[i];
        }
      }
      if (scaledSum <= 0) return result;
      final double target = available - frozenSum;
      if (target >= shrinkableSum - kAylaCssFlexEpsilon) return result;
      final double deficit = shrinkableSum - target;

      bool froze = false;
      for (int i = 0; i < n; i++) {
        if (frozen[i]) continue;
        final double share = deficit * (shrink[i] * base[i]) / scaledSum;
        final double candidate = result[i] - share;
        if (candidate <= floors[i] + kAylaCssFlexEpsilon) {
          result[i] = math.max(floors[i], candidate);
          frozen[i] = true;
          froze = true;
        } else {
          result[i] = candidate;
        }
      }
      if (!froze) return result;
    }
    return result;
  }

  @override
  void performLayout() {
    final BoxConstraints c = constraints;
    final bool bounded = c.maxWidth.isFinite;
    final double maxWidth = bounded ? c.maxWidth : double.infinity;

    final List<RenderBox> children = <RenderBox>[];
    for (RenderBox? child = firstChild;
        child != null;
        child = _dataOf(child).nextSibling) {
      children.add(child);
    }
    final int n = children.length;
    if (n == 0) {
      size = c.constrain(Size(bounded ? maxWidth : 0, 0));
      return;
    }

    final double totalGap = _gap * (n - 1);

    // ---- 1) flex base size：**主轴无界**测量一遍（等价 CSS 的 max-content）----
    //
    // ⚠️ 必须无界，不能传 `BoxConstraints(maxWidth: maxWidth)`：
    // 本库里大量按钮/卡片是 `Container(alignment: ...)`（内部 `Align`）——
    // `Align` 在**有限**的宽松约束下会**撑满** maxWidth，于是「自然宽」被量成整行宽，
    // 收缩分支就永远测不到真实内容宽（实测：工具栏按钮从 46 变成 715）。
    // 这正是 Flutter `Row` 给子项主轴**无界**约束的原因，也与 CSS 的
    // `flex-basis: auto` = max-content 一致。
    // 子项自己的上限（`.msg-body { max-width:75% }` 等）由子项自身的
    // `ConstrainedBox` 施加，不依赖本件传入。
    final List<double> base = List<double>.filled(n, 0);
    const BoxConstraints probe = BoxConstraints();
    double baseSum = totalGap;
    for (int i = 0; i < n; i++) {
      children[i].layout(probe, parentUsesSize: true);
      base[i] = children[i].size.width;
      baseSum += base[i];
    }

    // ---- 2/3/4/5) 自由空间判定 + 收缩 + 重排 ----
    List<double> finals = base;
    if (bounded && baseSum > maxWidth + kAylaCssFlexEpsilon) {
      final List<double> shrink = <double>[
        for (final RenderBox ch in children) _dataOf(ch).flexShrink,
      ];
      final List<double> minWidths = <double>[
        for (final RenderBox ch in children) _dataOf(ch).minWidth,
      ];
      final List<double> minContents = <double>[
        for (final RenderBox ch in children) _dataOf(ch).minContentWidth ?? 0,
      ];
      final double available = maxWidth - totalGap;

      // 第 1 趟：压到各自 min-content（文字折行 —— 与浏览器第一次布局一致）。
      finals = _resolveShrink(
        base: base,
        shrink: shrink,
        minWidths: minWidths,
        minContents: minContents,
        available: available,
        floorAt: true,
      );
      // 第 2 趟：仍溢出 ⇒ 破 min-content，压到硬 min-width（规范 §9.7 的 clamp）。
      double sum = totalGap;
      for (final double w in finals) {
        sum += w;
      }
      if (sum > maxWidth + kAylaCssFlexEpsilon) {
        finals = _resolveShrink(
          base: finals,
          shrink: shrink,
          minWidths: minWidths,
          minContents: minContents,
          available: available,
          floorAt: false,
        );
      }

      // ---- 5) 被改宽的项按最终宽重排（文字重新折行，等价浏览器）----
      for (int i = 0; i < n; i++) {
        if ((finals[i] - base[i]).abs() <= kAylaCssFlexEpsilon) continue;
        children[i].layout(
          BoxConstraints.tightFor(width: finals[i]),
          parentUsesSize: true,
        );
      }
    }

    // ---- 6) 摆放 ----
    double finalsSum = totalGap;
    double maxHeight = 0;
    for (int i = 0; i < n; i++) {
      finalsSum += finals[i];
      maxHeight = math.max(maxHeight, children[i].size.height);
    }
    // 容器自身宽度 = **shrink-to-fit**（等价 CSS 里 flex 容器作为 flex item 时
    // 取自己的 max-content 宽）。父级给紧宽（minWidth == maxWidth，如消息行是整行宽）
    // 时就是整行；父级给松宽时按内容收缩 —— 否则内层工具栏会把整行宽当自己的宽。
    final double width = !bounded
        ? finalsSum
        : (_mainAxisSize == MainAxisSize.max
            ? maxWidth
            : math.max(c.minWidth, math.min(finalsSum, maxWidth)));

    final double leading = switch (_mainAxisAlignment) {
      MainAxisAlignment.start => 0,
      MainAxisAlignment.end => math.max(0, width - finalsSum),
      MainAxisAlignment.center => math.max(0, (width - finalsSum) / 2),
      MainAxisAlignment.spaceBetween ||
      MainAxisAlignment.spaceAround ||
      MainAxisAlignment.spaceEvenly =>
        0,
    };

    double x = leading;
    for (int i = 0; i < n; i++) {
      final RenderBox child = children[i];
      final double dy = switch (_crossAxisAlignment) {
        CrossAxisAlignment.start => 0,
        CrossAxisAlignment.end => math.max(0, maxHeight - child.size.height),
        CrossAxisAlignment.center =>
          math.max(0, (maxHeight - child.size.height) / 2),
        CrossAxisAlignment.stretch || CrossAxisAlignment.baseline => 0,
      };
      _dataOf(child).offset = Offset(x, dy);
      x += finals[i] + _gap;
    }

    size = c.constrain(Size(width, maxHeight));
  }

  // 见文件头「与 CSS 的已知差异」1：子树含 LayoutBuilder ⇒ 不实现 intrinsic。
  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) => 0;

  @override
  double computeMinIntrinsicHeight(double width) => 0;

  @override
  double computeMaxIntrinsicHeight(double width) => 0;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) {
    defaultPaint(context, offset);
  }
}