/// 量化探针（2026-09-30，第十三批 b）：**挂载帧成本的构成**（build/layout vs 快照捕获）。
///
/// 上一支（`tmp_mount_frame_probe_test.dart`）测得：一帧挂载 20 张玻璃卡 = **UI 278ms**。
/// 本支拆开它：同构型下比较「缓存开（挂载帧做 20 次离屏捕获）」与「缓存关（挂载帧做
/// 20 次实时模糊）」，以及与「纯 SizedBox 卡片」的差 ⇒ 判断该往哪优化。
///
/// 跑法：`flutter test test/tmp_mount_breakdown_probe_test.dart --concurrency 1`
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/app_theme.dart';
import '../lib/theme/aurora_background.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/tokens.dart';

void main() {
  final GlobalKey rootKey = GlobalKey();

  Widget scene(List<Widget> cards) => RepaintBoundary(
        key: rootKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAylaTheme(),
          home: AylaAuroraBackground(
            animate: false,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: Align(
                alignment: Alignment.topLeft,
                child: Wrap(children: cards),
              ),
            ),
          ),
        ),
      );

  Widget glassCard() => SizedBox(
        width: 360,
        height: 300,
        child: AylaGlassSurface(
          shadow: AylaShadows.glass,
          child: const Text('卡片'),
        ),
      );

  Widget plainCard() => const SizedBox(
        width: 360,
        height: 300,
        child: DecoratedBox(
          decoration: BoxDecoration(color: Color(0x88FFFFFF)),
          child: Text('卡片'),
        ),
      );

  Future<double> rasterMs(WidgetTester tester) async {
    final RenderRepaintBoundary boundary =
        rootKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final int us = (await tester.runAsync(() async {
      final Stopwatch sw = Stopwatch()..start();
      final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
      sw.stop();
      image.dispose();
      return sw.elapsedMicroseconds;
    }))!;
    return us / 1000.0;
  }

  Future<double> uiMsOfMount(WidgetTester tester, List<Widget> cards) async {
    await tester.pumpWidget(scene(<Widget>[]));
    await tester.pump();
    await rasterMs(tester); // 预热
    final Stopwatch sw = Stopwatch()..start();
    await tester.pumpWidget(scene(cards));
    sw.stop();
    return sw.elapsedMicroseconds / 1000.0;
  }

  testWidgets('挂载帧构成：纯色卡 / 玻璃卡（缓存开 vs 关）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.reset();
      AylaGlassConfig.backdropCacheEnabled = true;
    });

    const int n = 20;
    final double plain =
        await uiMsOfMount(tester, <Widget>[for (int i = 0; i < n; i += 1) plainCard()]);
    AylaGlassConfig.backdropCacheEnabled = false;
    final double glassNoCache =
        await uiMsOfMount(tester, <Widget>[for (int i = 0; i < n; i += 1) glassCard()]);
    AylaGlassConfig.backdropCacheEnabled = true;
    final double glassCache =
        await uiMsOfMount(tester, <Widget>[for (int i = 0; i < n; i += 1) glassCard()]);
    final double glassCacheRaster = await rasterMs(tester);

    debugPrint('挂载帧 UI：纯色 $n 卡 = ${plain.toStringAsFixed(1)} ms');
    debugPrint('挂载帧 UI：玻璃 $n 卡（无缓存）= ${glassNoCache.toStringAsFixed(1)} ms');
    debugPrint(
      '挂载帧 UI：玻璃 $n 卡（缓存开）= ${glassCache.toStringAsFixed(1)} ms '
      '（该帧 raster = ${glassCacheRaster.toStringAsFixed(1)} ms）',
    );
    debugPrint(
      '⇒ 玻璃件自身（build/layout/paint 记录）≈ '
      '${(glassNoCache - plain).toStringAsFixed(1)} ms；'
      '快照捕获净增量 ≈ ${(glassCache - glassNoCache).toStringAsFixed(1)} ms',
    );
  });
}
