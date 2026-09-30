/// 量化探针（2026-09-30，第十一批）：**预模糊档（`AylaGlassQuality.preblurred`）的 raster 收益**。
///
/// 用途：给「静止期每帧 N 次高斯模糊」这个引擎语义成本提供**可裁决的杠杆**。
/// 预模糊档是库内**既有**的质量档（`AylaGlassConfig.quality` 一行切换全站）：
/// 玻璃件改为采样一张**烘焙的低频背景快照**（`AylaBackdropSnapshot`，长边 256），
/// 不再做逐帧 `BackdropFilter`。**代价是观感**：卡内背景不再随极光流动、也更"平"，
/// 所以它只能作为**用户裁决项**，不是默认值。
///
/// 跑法：`flutter test test/tmp_quality_gain_probe_test.dart --concurrency 1`
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

  Future<double> medianFrameMs(WidgetTester tester, {int frames = 4}) async {
    final RenderRepaintBoundary boundary =
        rootKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final List<double> ms = <double>[];
    for (int i = 0; i < frames; i += 1) {
      final int us = (await tester.runAsync(() async {
        final Stopwatch sw = Stopwatch()..start();
        final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
        sw.stop();
        image.dispose();
        return sw.elapsedMicroseconds;
      }))!;
      ms.add(us / 1000.0);
    }
    ms.sort();
    return ms[ms.length ~/ 2];
  }

  testWidgets('预模糊档 vs 真玻璃档：静止每帧成本', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.reset();
      AylaGlassConfig.quality = AylaGlassQuality.realBackdrop;
      AylaBackdropSnapshot.clear();
    });

    // 手动登记一张「已烘焙的背景快照」（预模糊档的采样源；生产由 aurora 背景烘焙）。
    final bool baked = (await tester.runAsync(() async {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, 256, 160));
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 256, 160),
        Paint()..color = AylaFluidAurora.backdrop,
      );
      final ui.Picture picture = recorder.endRecording();
      final ui.Image image = await picture.toImage(256, 160);
      picture.dispose();
      AylaBackdropSnapshot.register(
        image: image,
        viewport: const Size(1600, 1000),
        origin: Offset.zero,
      );
      return true;
    }))!;
    debugPrint('背景快照已登记 = $baked');

    final StringBuffer out = StringBuffer('档位 | 卡数 | 静止每帧中位数(ms)');
    for (final AylaGlassQuality q in <AylaGlassQuality>[
      AylaGlassQuality.realBackdrop,
      AylaGlassQuality.preblurred,
    ]) {
      AylaGlassConfig.quality = q;
      for (final int cards in <int>[6, 12, 20]) {
        await tester.pumpWidget(scene(cards));
        await tester.pump();
        await tester.pump();
        out.writeln(
          '${q.name} | $cards | ${(await medianFrameMs(tester)).toStringAsFixed(1)}',
        );
      }
    }
    debugPrint(out.toString());
  });
}
