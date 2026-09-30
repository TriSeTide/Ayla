/// 量化：极光背景的四层流层动画，是否还会牵连**内容层**逐帧重绘。
///
/// 手法与 `repaint_boundary_audit_test` 同源：探针插在内容层外层，统计若干帧内
/// 它被 `paint` 的次数。背景层若与内容共享同一个 `RepaintBoundary`，背景每帧变化
/// 会把内容一起拖进重绘（次数 ≈ 帧数）；边界下移到背景层后应为 **0**。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/aurora_background.dart';
import '../lib/theme/preview_theme.dart';

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

void main() {
  testWidgets('背景动画期间内容层不被牵连重绘', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1024, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    int paints = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: previewScope(
          AylaAuroraBackground(
            child: _PaintProbeWidget(
              onPaint: () => paints += 1,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    awaits:
    for (int i = 0; i < 10; i += 1) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    debugPrint('内容层在 10 帧内被 paint 次数 = ' + paints.toString());
    expect(paints, lessThanOrEqualTo(1));
  });
}
