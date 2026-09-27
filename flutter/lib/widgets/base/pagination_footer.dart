/// pagination footer（自 `directory_controls.dart` 拆出：一文件一件）。
///
/// 事实源与逐条对照见 `docs/flutter/17-组件文件头归档（整理前原文）.md` 的 `directory_controls.dart` 一节
/// 与各件的 `///` 头注。
///
/// ## 公开面
/// `AylaStablePaginationFooter` · `AylaPaginationLoadingDots`

library;

import 'package:flutter/material.dart';
import '../../theme/tokens.dart';

/// 稳定分页页脚（`AylaStablePaginationFooter.tsx` + home.css 639–656）。
///
/// ## 事实源
/// ```
/// .stable-pagination-footer { display:flex; flex:none; width:100%;
///   min-height:80px; padding: var(--sp-3); flex-direction:column;
///   align-items:center; justify-content:center; gap: var(--sp-2);
///   overflow-anchor:none; }
/// ```
/// **核心语义**：记住**测到过的最大高度**，并在列表仍挂载期间把它写回
/// `min-height` —— 这样「重试/进度/已到底」三态切换时**页脚盒子不塌缩**，
/// 下方内容不跳动（tsx 用 `useLayoutEffect` 首测 + `ResizeObserver` 增量测）。
///
/// Flutter 等价：`LayoutBuilder` 首测 + 内容变化后重测，用 `Container.minHeight`
/// 锁定历史最大值（`overflowAnchor:none` 对应 Flutter 无隐含锚定行为，无需处理）。
class AylaStablePaginationFooter extends StatefulWidget {
  const AylaStablePaginationFooter({
    super.key,
    required this.child,
    this.minHeight = 80,
    this.padding = const EdgeInsets.all(AylaSpacing.sp3),
  });

  /// 页脚内容（三态之一）。
  final Widget child;

  /// 初始最小高度（`.stable-pagination-footer { min-height: 80px }`）。
  final double minHeight;

  /// 内距（基样式 `padding: var(--sp-3)`；**搜索分组内**覆写为 `sp2 0 0`，见 search.css 75–78）。
  final EdgeInsetsGeometry padding;

  @override
  State<AylaStablePaginationFooter> createState() => _StablePaginationFooterState();
}

class _StablePaginationFooterState extends State<AylaStablePaginationFooter> {
  final GlobalKey _contentKey = GlobalKey();

  /// 历史最大高度（tsx `tallest` ref）。
  double _tallest = 0;

  @override
  Widget build(BuildContext context) {
    // 内容变化后测真实高度并抬高 minHeight（tsx：useLayoutEffect 首测 +
    // ResizeObserver 增量测）。用 post-frame 测量避免布局期内 setState。
    WidgetsBinding.instance.addPostFrameCallback((_) => _retainHeight());
    return Container(
      width: double.infinity, // width: 100%
      constraints: BoxConstraints(
        minHeight: _tallest > widget.minHeight ? _tallest : widget.minHeight,
      ),
      padding: widget.padding, // padding: var(--sp-3)（搜索分组内覆写为 sp2 0 0）
      child: UnconstrainedBox(
        // 让内容按自然高度布局（不被 minHeight 拉伸，才能测准）
        constrainedAxis: Axis.horizontal,
        child: KeyedSubtree(key: _contentKey, child: widget.child),
      ),
    );
  }

  /// 记住测到过的最大高度（`.stable-pagination-footer` 的核心语义：
  /// 三态切换时页脚盒子不塌缩、下方内容不跳动）。
  void _retainHeight() {
    if (!mounted) return;
    final RenderBox? box =
        _contentKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final double h = box.size.height;
    if (h > _tallest && mounted) {
      setState(() => _tallest = h);
    }
  }
}

// ======================= 加载点 =======================

/// `.pagination-loading-dots` —— 三个 6px 冰蓝圆点（home.css 659–671）。
class AylaPaginationLoadingDots extends StatelessWidget {
  const AylaPaginationLoadingDots({super.key, this.semanticLabel});

  /// 无障碍标签（如「正在加载历史」）。
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final Widget dots = SizedBox(
      // min-height: 40px
      height: 40,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6, // gap: 6px
        children: <Widget>[
          for (int i = 0; i < 3; i++)
            Container(
              width: 6, // width: 6px
              height: 6, // height: 6px
              decoration: const BoxDecoration(
                color: AylaColors.ice500, // background: var(--ice-500)
                shape: BoxShape.circle, // border-radius: pill
              ),
            ),
        ],
      ),
    );
    return semanticLabel == null
        ? dots
        : Semantics(label: semanticLabel, child: dots);
  }
}

// ======================= DirectoryLoadMore =======================
