/// 量化探针（2026-09-30，第十三批）：**「一帧突然出现太多卡」的挂载帧成本**。
///
/// 用户判断：「最后一帧突然出现太多卡了」，并要求「别人 app 怎么做优化的，flutter 文档怎么教的」。
/// 官方口径（docs.flutter.dev/perf/best-practices「Implement grids and lists thoughtfully → Be lazy」）
/// 是**懒构建**（`ListView.builder`：只构建屏幕上可见的部分）—— 但本场景 20 张卡**都在可见区**，
/// 懒构建无能为力 ⇒ 需要量化「同一帧挂载 N 张卡」到底贵在哪一栏（build/layout vs raster）。
///
/// 对照两条路径：
/// · `burst`    —— 一帧内挂载 20 张（= 用户说的「最后一帧突然出现太多卡」）；
/// · `chunked`  —— 分 5 帧、每帧 4 张（时间切片；卡在 stagger delay 期内完成挂载 ⇒ 视觉无差）。
///
/// 跑法：`flutter test test/tmp_mount_frame_probe_test.dart --concurrency 1`
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

  Widget scene(int cards) => RepaintBoundary(
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
                child: Wrap(
                  children: <Widget>[
                    for (int i = 0; i < cards; i += 1)
                      SizedBox(
                        width: 360,
                        height: 300,
                        child: AylaGlassSurface(
                          shadow: AylaShadows.glass,
                          child: const Text('卡片'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
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

  testWidgets('一帧挂载 20 张 vs 分 5 帧挂载', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // ---------- burst：一帧 20 张 ----------
    await tester.pumpWidget(scene(0));
    await tester.pump();
    await rasterMs(tester); // 预热
    final Stopwatch burstSw = Stopwatch()..start();
    await tester.pumpWidget(scene(20));
    burstSw.stop();
    final double burstUi = burstSw.elapsedMicroseconds / 1000.0;
    final double burstRaster = await rasterMs(tester);
    final List<double> burstTail = <double>[];
    for (int i = 0; i < 4; i += 1) {
      await tester.pump(const Duration(milliseconds: 16));
      burstTail.add(await rasterMs(tester));
    }

    // ---------- chunked：每帧 4 张 ----------
    await tester.pumpWidget(scene(0));
    await tester.pump();
    final List<double> chunkUi = <double>[];
    final List<double> chunkRaster = <double>[];
    for (int k = 1; k <= 5; k += 1) {
      final Stopwatch sw = Stopwatch()..start();
      await tester.pumpWidget(scene(k * 4));
      sw.stop();
      chunkUi.add(sw.elapsedMicroseconds / 1000.0);
      chunkRaster.add(await rasterMs(tester));
    }
    for (int i = 0; i < 4; i += 1) {
      await tester.pump(const Duration(milliseconds: 16));
      await rasterMs(tester);
    }

    debugPrint(
      'burst  ：挂载帧 UI = ${burstUi.toStringAsFixed(1)} ms · 该帧 raster = '
      '${burstRaster.toStringAsFixed(1)} ms · 随后 4 帧 raster = '
      '${burstTail.map((double v) => v.toStringAsFixed(0)).join("/")}',
    );
    debugPrint(
      'chunked：各帧 UI = ${chunkUi.map((double v) => v.toStringAsFixed(1)).join("/")} ms '
      '· 各帧 raster = ${chunkRaster.map((double v) => v.toStringAsFixed(0)).join("/")}',
    );
    debugPrint(
      '⇒ burst 单帧最大 = ${(burstUi > burstRaster ? burstUi : burstRaster).toStringAsFixed(1)} ms；'
      'chunked 单帧最大 = '
      '${(chunkUi.reduce((double a, double b) => a > b ? a : b)) > (chunkRaster.reduce((double a, double b) => a > b ? a : b)) ? chunkUi.reduce((double a, double b) => a > b ? a : b).toStringAsFixed(1) : chunkRaster.reduce((double a, double b) => a > b ? a : b).toStringAsFixed(1)} ms',
    );
  });
}
