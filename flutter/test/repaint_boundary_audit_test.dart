/// 卡片级 `RepaintBoundary` 的**量化**审计（2026-09-27；13 号 §8.19）。
///
/// 问题：玻璃卡（`BackdropFilter`）会不会被「邻居动画」反复重录？
///
/// 做法：把 [RenderProxyBox] 探针插在玻璃卡外层，统计若干帧里它被 `paint` 的次数 ——
/// 被 paint 就意味着这一帧**重新录制了 `BackdropFilterLayer`**（重新采样 + 高斯模糊
/// 背后内容）；没被 paint 则 layer 被复用，这一帧零模糊成本。
///
/// 三个场景（同一探针、同一帧数）：
/// 1. **无边界**：邻居是持续循环动画 ⇒ 它的 `markNeedsPaint` 冒泡到最近的 repaint
///    boundary（这里是页面根）⇒ 整棵子树（含玻璃卡）逐帧重绘；
/// 2. **玻璃卡自身加 `RepaintBoundary`**：邻居只重绘自己，玻璃卡的 layer 被复用；
/// 3. **真实宿主 `ListView.builder`**：每个 item 自带 `RepaintBoundary`
///    （`addRepaintBoundaries` 默认 true）⇒ 列表内的玻璃卡本来就已被保护。
///
/// 结论写在 13 号 §8.19：**量出的收益只出现在「玻璃卡与持续动画共享同一 repaint
/// boundary」的布局里**，而真实 app 的玻璃卡宿主是列表（自带边界）或已加边界的动画；
/// 因此不新增卡片级边界（见文档里的结构审计）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/aurora_background.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';

/// 玻璃卡子树的 `paint` 计数探针。
class _PaintProbe extends RenderProxyBox {
  _PaintProbe(this.onPaint);

  void Function() onPaint;

  @override
  void paint(PaintingContext context, Offset offset) {
    onPaint();
    super.paint(context, offset);
  }
}

class _PaintProbeWidget extends SingleChildRenderObjectWidget {
  const _PaintProbeWidget({required this.onPaint, super.child});

  final void Function() onPaint;

  @override
  RenderObject createRenderObject(BuildContext context) => _PaintProbe(onPaint);

  @override
  void updateRenderObject(BuildContext context, _PaintProbe renderObject) {
    renderObject.onPaint = onPaint;
  }
}

/// 每帧变化的邻居（持续循环动画）—— 模拟「卡片旁边有个一直在动的东西」。
class _NeighbourTicker extends StatefulWidget {
  const _NeighbourTicker();

  @override
  State<_NeighbourTicker> createState() => _NeighbourTickerState();
}

class _NeighbourTickerState extends State<_NeighbourTicker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        return SizedBox(
          width: 24,
          height: 24,
          child: ColoredBox(
            color: Color.lerp(
              const Color(0xFF9DBFE6),
              const Color(0xFFF17EB3),
              _controller.value,
            )!,
          ),
        );
      },
    );
  }
}

void main() {
  const int frames = 10;

  Widget host(Widget child) => MaterialApp(home: previewScope(child));

  Widget glassCard() => const AylaGlassSurface(
    child: SizedBox(width: 120, height: 60),
  );

  setUp(() {
    AylaGlassConfig.quality = AylaGlassQuality.realBackdrop;
  });

  testWidgets('量化①：邻居动画下，无 repaint 边界的玻璃卡每帧被重绘（= 每帧重录 BackdropFilter）', (
    WidgetTester tester,
  ) async {
    int paints = 0;
    await tester.pumpWidget(
      host(
        Column(
          children: <Widget>[
            _PaintProbeWidget(onPaint: () => paints++, child: glassCard()),
            const _NeighbourTicker(),
          ],
        ),
      ),
    );
    await tester.pump();
    paints = 0; // 首帧不计
    for (int i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    debugPrint('【RepaintBoundary 量化】无边界：$frames 帧里玻璃卡被 paint $paints 次');
    expect(
      paints,
      greaterThanOrEqualTo(frames - 1),
      reason: '邻居动画的 markNeedsPaint 会冒泡到最近的 repaint boundary（页面根）',
    );
    await tester.pumpWidget(host(const SizedBox.shrink()));
  });

  testWidgets('量化②：玻璃卡自身加 RepaintBoundary 后，邻居动画不再重绘它', (
    WidgetTester tester,
  ) async {
    int paints = 0;
    await tester.pumpWidget(
      host(
        Column(
          children: <Widget>[
            RepaintBoundary(
              child: _PaintProbeWidget(onPaint: () => paints++, child: glassCard()),
            ),
            const _NeighbourTicker(),
          ],
        ),
      ),
    );
    await tester.pump();
    paints = 0;
    for (int i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    debugPrint('【RepaintBoundary 量化】有边界：$frames 帧里玻璃卡被 paint $paints 次');
    expect(paints, lessThanOrEqualTo(1));
    await tester.pumpWidget(host(const SizedBox.shrink()));
  });

  testWidgets('量化③：真实宿主 ListView 的 item 自带 RepaintBoundary（列表内玻璃卡已被保护）', (
    WidgetTester tester,
  ) async {
    int paints = 0;
    await tester.pumpWidget(
      host(
        Column(
          children: <Widget>[
            SizedBox(
              height: 200,
              child: ListView.builder(
                itemCount: 3,
                itemBuilder: (BuildContext context, int index) {
                  return _PaintProbeWidget(
                    onPaint: () {
                      if (index == 0) paints++;
                    },
                    child: const AylaGlassSurface(
                      child: SizedBox(width: 120, height: 60),
                    ),
                  );
                },
              ),
            ),
            const _NeighbourTicker(),
          ],
        ),
      ),
    );
    await tester.pump();
    paints = 0;
    for (int i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    debugPrint('【RepaintBoundary 量化】ListView item 内玻璃卡：$frames 帧被 paint $paints 次');
    expect(
      paints,
      0,
      reason: 'SliverChildBuilderDelegate.addRepaintBoundaries 默认 true',
    );
    await tester.pumpWidget(host(const SizedBox.shrink()));
  });

  testWidgets('量化④：真实极光背景下，玻璃卡子树不被背景动画牵连（2026-09-30 修复后）', (
    WidgetTester tester,
  ) async {
    int paints = 0;
    await tester.pumpWidget(
      host(
        AylaAuroraBackground(
          child: Align(
            alignment: Alignment.topLeft,
            child: _PaintProbeWidget(
              onPaint: () => paints++,
              child: glassCard(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    paints = 0;
    for (int i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    debugPrint('【RepaintBoundary 量化】极光背景 + 玻璃卡：$frames 帧里玻璃卡被 paint $paints 次');
    // **2026-09-30 已修复**：`aurora_background.dart` 的边界下移到「只包背景层」，
    // 并给内容 `child` 也加了独立边界 —— **两侧都要加**：仅加背景侧时实测内容层
    // 10 帧仍被 paint 11 次（背景重绘经父级牵连兄弟）。修复后本用例从
    // 「基线坏（10/10 帧）」变为 **≤1 次**。
    expect(
      paints,
      lessThanOrEqualTo(1),
      reason: '背景层与内容层各有独立 RepaintBoundary（2026-09-30 修复）',
    );
    await tester.pumpWidget(host(const SizedBox.shrink()));
    AylaBackdropSnapshot.clear();
  });

  testWidgets('量化⑤：卡片级边界生效 —— 背景动画不再重录玻璃滤镜层', (
    WidgetTester tester,
  ) async {
    int paints = 0;
    await tester.pumpWidget(
      host(
        AylaAuroraBackground(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 160,
              height: 80,
              child: AylaGlassBackdrop(
                radius: BorderRadius.circular(AylaRadii.rCard),
                filter: AylaGlassConfig.backdropFilter(
                  sigma: AylaGlass.blurCard,
                ),
                // 探针放在**滤镜层内部**（边界之下）—— 若边界生效，
                // 祖先重绘时它不会被 paint。
                child: _PaintProbeWidget(
                  onPaint: () => paints++,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    paints = 0;
    for (int i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    debugPrint('【RepaintBoundary 量化】背景 + 滤镜层（自带卡片级边界）：$frames 帧被 paint $paints 次');
    expect(
      paints,
      0,
      reason: 'AylaGlassBackdrop 的 realBackdrop 分支自带 RepaintBoundary',
    );
    await tester.pumpWidget(host(const SizedBox.shrink()));
    AylaBackdropSnapshot.clear();
  });
}
