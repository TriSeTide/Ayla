/// 毛玻璃质量档的**结构锁**（性能不变量，2026-09-27 §8.17）。
///
/// [AylaGlassConfig.quality] 是全站玻璃件「背后内容层」的总闸，三档必须都锁住：
///
/// - 默认 [AylaGlassQuality.realBackdrop] —— **与改造前逐像素一致**：
///   每张玻璃卡一个 `BackdropFilter`，widget 结构与直接写
///   `ClipRRect(child: BackdropFilter(...))` 相同；
/// - [AylaGlassQuality.preblurred] —— 用背景低频快照（[AylaBackdropSnapshot]）
///   采样替代滤镜 ⇒ 玻璃子树里 **0 个 `BackdropFilter`**；
/// - [AylaGlassQuality.opaque] —— 连采样都不做，面层换 .92 实底。
///
/// 这些断言同时是回归锁：谁把某个玻璃件从 [AylaGlassBackdrop] 改回裸
/// `BackdropFilter`（或漏接质量档），预模糊档的 0 计数就会失败。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
    home: previewScope(
      Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: const Size(400, 300)),
          child: Center(child: child),
        ),
      ),
    ),
  );

  /// 面层（外层 DecoratedBox）的底色。
  Color faceColor(WidgetTester tester, Finder root) {
    final DecoratedBox face = tester.widget<DecoratedBox>(
      find.descendant(of: root, matching: find.byType(DecoratedBox)).first,
    );
    return (face.decoration as BoxDecoration).color!;
  }

  Widget card() => const AylaGlassSurface(
    child: SizedBox(width: 120, height: 40),
  );

  setUp(() {
    AylaGlassConfig.quality = AylaGlassQuality.realBackdrop;
  });

  tearDown(() {
    AylaGlassConfig.quality = AylaGlassQuality.realBackdrop;
    AylaBackdropSnapshot.clear();
  });

  testWidgets('默认档 = 真玻璃：玻璃卡装一个 BackdropFilter（与改造前一致）', (
    WidgetTester tester,
  ) async {
    expect(AylaGlassConfig.quality, AylaGlassQuality.realBackdrop);
    expect(AylaGlassConfig.backdropEnabled, isTrue);
    await tester.pumpWidget(host(card()));
    await tester.pump();
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.byType(AylaBackdropSampler), findsNothing);
  });

  testWidgets('预模糊档：玻璃卡 0 个 BackdropFilter、改用采样层', (WidgetTester tester) async {
    AylaGlassConfig.quality = AylaGlassQuality.preblurred;
    await tester.pumpWidget(host(card()));
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(AylaBackdropSampler), findsOneWidget);
  });

  testWidgets('预模糊档不改面层材质（颜色与真玻璃档逐点相同）', (WidgetTester tester) async {
    await tester.pumpWidget(host(card()));
    await tester.pump();
    final Color real = faceColor(tester, find.byType(AylaGlassSurface));
    AylaGlassConfig.quality = AylaGlassQuality.preblurred;
    await tester.pumpWidget(host(card()));
    await tester.pump();
    final Color pre = faceColor(tester, find.byType(AylaGlassSurface));
    expect(pre, real, reason: '质量档只换「背后内容层」，材质层必须原样');
    expect(pre.a, closeTo(AylaColors.glassBg.a, 0.001));
  });

  testWidgets('实底档：0 滤镜、0 采样，面层换成 .92 实底', (WidgetTester tester) async {
    AylaGlassConfig.quality = AylaGlassQuality.opaque;
    await tester.pumpWidget(host(card()));
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(AylaBackdropSampler), findsNothing);
    expect(
      faceColor(tester, find.byType(AylaGlassSurface)),
      AylaColors.glassOpaqueFallback,
    );
  });

  testWidgets('预模糊档：玻璃按钮同样 0 个 BackdropFilter', (WidgetTester tester) async {
    AylaGlassConfig.quality = AylaGlassQuality.preblurred;
    await tester.pumpWidget(
      host(AylaGlassButton(label: '开播', onPressed: () {})),
    );
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('预模糊档但快照未就绪：采样层不画白板、组件照常渲染', (WidgetTester tester) async {
    AylaGlassConfig.quality = AylaGlassQuality.preblurred;
    AylaBackdropSnapshot.clear();
    expect(AylaBackdropSnapshot.image, isNull);
    await tester.pumpWidget(host(const AylaGlassSurface(child: Text('内容'))));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('内容'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  test('useOpaqueFallback 与 quality 双向映射（旧调用点不改也正确）', () {
    AylaGlassConfig.useOpaqueFallback = true;
    expect(AylaGlassConfig.quality, AylaGlassQuality.opaque);
    expect(AylaGlassConfig.backdropEnabled, isFalse);
    expect(AylaGlassConfig.preblurEnabled, isFalse);
    expect(AylaGlassConfig.backdropLayerEnabled, isFalse);
    AylaGlassConfig.useOpaqueFallback = false;
    expect(AylaGlassConfig.quality, AylaGlassQuality.realBackdrop);
    expect(AylaGlassConfig.backdropEnabled, isTrue);
    expect(AylaGlassConfig.backdropLayerEnabled, isTrue);
  });

  testWidgets('AylaBackdropSnapshot：register 提升 revision、clear 归零', (WidgetTester tester) async {
    final int before = AylaBackdropSnapshot.revision;
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, 4, 4));
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 4, 4),
      Paint()..color = const Color(0xFF00FF00),
    );
    final ui.Image image = await recorder.endRecording().toImage(4, 4);
    AylaBackdropSnapshot.register(
      image: image,
      viewport: const Size(100, 50),
      origin: const Offset(7, 9),
    );
    expect(AylaBackdropSnapshot.revision, before + 1);
    expect(AylaBackdropSnapshot.viewport, const Size(100, 50));
    expect(AylaBackdropSnapshot.origin, const Offset(7, 9));
    expect(AylaBackdropSnapshot.image, isNotNull);
    AylaBackdropSnapshot.clear();
    expect(AylaBackdropSnapshot.revision, before + 2);
    expect(AylaBackdropSnapshot.image, isNull);
    expect(AylaBackdropSnapshot.viewport, Size.zero);
  });
}
