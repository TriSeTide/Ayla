/// 直播小窗缩放手势的方向锁（2026-10 用户实报「缩放手势好像是反了」）。
///
/// ## 修前根因（回归锁的目的）
/// 旧实现把 ScaleUpdateDetails.localFocalPoint.distance 当「双指指距」用 ——
/// 那是**双指中点相对控件左上角的距离**，与两指间距无关。于是：
/// · 双指在控件右下角捏合时该值本来就大 ⇒ 松开变大、张开变小（方向反）；
/// · 中点靠近左上角时该值趋 0 ⇒ 比例抖动/爆掉；
/// · 中点上下平移也会改该值 ⇒ 张合与拖动互相污染。
///
/// 现在用 ScaleUpdateDetails.scale（框架按 currentSpan / initialSpan 算好的
/// **相对手势起点**比例），配合起点尺寸得绝对尺寸。
///
/// 本测试走**真实双指触控派发**，与用户实际操作路径同源。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/preview_theme.dart';
import '../lib/widgets/live/live_mini_player.dart';

void main() {
  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: previewScope(
          const Stack(
            children: <Widget>[AylaLiveMiniPlayer(videoView: SizedBox())],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Size miniSize(WidgetTester tester) =>
      tester.getRect(find.byType(AylaLiveMiniPlayer)).size;

  Future<void> pinchBetween(
    WidgetTester tester,
    double fromHalf,
    double toHalf,
  ) async {
    final Rect r = tester.getRect(find.byType(AylaLiveMiniPlayer));
    final Offset c = r.center;

    final TestGesture g1 = await tester.createGesture();
    final TestGesture g2 = await tester.createGesture();
    await g1.down(c - Offset(0, fromHalf));
    await g2.down(c + Offset(0, fromHalf));
    await tester.pump(const Duration(milliseconds: 20));

    const int steps = 6;
    for (int i = 1; i <= steps; i += 1) {
      final double d = fromHalf + (toHalf - fromHalf) * i / steps;
      await g1.moveTo(c - Offset(0, d));
      await g2.moveTo(c + Offset(0, d));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g1.up();
    await g2.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> pinchOpen(WidgetTester tester) => pinchBetween(tester, 12, 44);
  Future<void> pinchClose(WidgetTester tester) => pinchBetween(tester, 44, 10);

  testWidgets('张开手指 ⇒ 小窗变大（方向锁）', (WidgetTester tester) async {
    await mount(tester);
    final Size before = miniSize(tester);
    expect(before.width, kLiveMiniWidth);
    await pinchOpen(tester);
    expect(miniSize(tester).width, greaterThan(before.width),
        reason: '张开手指必须放大。旧实现方向相反/无效');
  });

  testWidgets('收拢手指 ⇒ 小窗变小（方向锁）', (WidgetTester tester) async {
    await mount(tester);
    final Size before = miniSize(tester);
    expect(before.width, kLiveMiniWidth);
    await pinchClose(tester);
    final Size after = miniSize(tester);
    expect(after.width, lessThan(before.width),
        reason: '收拢手指必须缩小；旧实现会在这里变大');
    expect(after.width, kLiveMiniMinWidth);
  });

  testWidgets('先放大再收拢：尺寸回到下限', (WidgetTester tester) async {
    await mount(tester);
    await pinchOpen(tester);
    final Size opened = miniSize(tester);
    expect(opened.width, greaterThan(kLiveMiniWidth));
    await pinchClose(tester);
    final Size after = miniSize(tester);
    expect(after.width, lessThan(opened.width));
    expect(after.width, kLiveMiniMinWidth);
  });

  testWidgets('缩放后仍保持 16:9 且 clamp 在 120–320', (WidgetTester tester) async {
    await mount(tester);
    await pinchOpen(tester);
    final Size after = miniSize(tester);
    expect(after.width, greaterThanOrEqualTo(kLiveMiniMinWidth));
    expect(after.width, lessThanOrEqualTo(kLiveMiniMaxWidth));
    expect(after.height, closeTo(after.width * 9 / 16, 0.01));
  });

  testWidgets('单指拖动：只位移，尺寸不变', (WidgetTester tester) async {
    await mount(tester);
    final Rect before = tester.getRect(find.byType(AylaLiveMiniPlayer));
    final TestGesture g = await tester.startGesture(before.center);
    await tester.pump();
    for (int i = 0; i < 6; i += 1) {
      await g.moveBy(const Offset(-12, -12));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final Rect after = tester.getRect(find.byType(AylaLiveMiniPlayer));
    expect(after.size, before.size, reason: '单指拖动不应改变尺寸');
    expect(after.left, lessThan(before.left));
  });
}
