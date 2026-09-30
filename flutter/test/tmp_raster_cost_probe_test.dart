/// 量化探针（2026-09-30）：**raster 成本代理测量**（软件光栅化）。
///
/// ## 口径与边界（必须写在前面，避免误读）
/// `flutter test` 的 UI 线程不做光栅化 ⇒ `pump()` 测不到 backdrop 模糊的成本
/// （见 `tmp_frame_cost_probe_test.dart`：12 张玻璃卡静止时 UI 每帧 0.03ms）。
/// 本探针改用 **`RenderRepaintBoundary.toImage()`** —— 它会用软件光栅器（Skia CPU）
/// **真实执行** saveLayer / backdrop 捕获 / 高斯模糊 / 阴影环布尔运算，
/// 因此能得到 raster 成本的**相对量级**（绝对值≠GPU，只用于 A/B 对照）。
///
/// 回答两个问题：
/// ① 玻璃卡（BackdropFilter）的 raster 成本随张数如何增长；
/// ② `SnapshotWidget` 冻结后（画纹理代替实时模糊）能省多少。
///
/// 跑法：`flutter test test/tmp_raster_cost_probe_test.dart --concurrency 1`
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
  const double kCardW = 360;
  const double kCardH = 300;
  final GlobalKey rootKey = GlobalKey();

  Widget card({double blur = AylaGlass.blurCard}) {
    return SizedBox(
      width: kCardW,
      height: kCardH,
      child: AylaGlassSurface(
        blur: blur,
        shadow: AylaShadows.glass,
        child: const Text('卡片'),
      ),
    );
  }

  Widget scene({required int cards, double blur = AylaGlass.blurCard}) {
    return RepaintBoundary(
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
                  for (int i = 0; i < cards; i += 1) card(blur: blur),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 中位数光栅化耗时（ms）：软件光栅化一次整帧。
  Future<double> toImageMedian(
    WidgetTester tester,
    Widget widget, {
    int samples = 3,
  }) async {
    await tester.pumpWidget(widget);
    await tester.pump();
    final RenderRepaintBoundary boundary =
        rootKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    expect(boundary.debugNeedsPaint, isFalse, reason: '边界未绘制完，无法取样');
    final List<double> ms = <double>[];
    for (int i = 0; i < samples; i += 1) {
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

  testWidgets('raster 成本代理：背景 / 玻璃卡张数 / 模糊开关', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final StringBuffer out = StringBuffer('构型 | 光栅化中位数(ms)');
    final Map<String, double> result = <String, double>{};
    Future<void> measure(String label, Widget w, {int samples = 3}) async {
      final double v = await toImageMedian(tester, w, samples: samples);
      result[label] = v;
      out.writeln('$label | ${v.toStringAsFixed(2)}');
    }

    await measure('背景 · 0 卡', scene(cards: 0));
    await measure('背景 · 1 卡 blur24', scene(cards: 1));
    await measure('背景 · 3 卡 blur24', scene(cards: 3));
    await measure('背景 · 3 卡 blur0', scene(cards: 3, blur: 0));
    await measure('背景 · 6 卡 blur24', scene(cards: 6), samples: 2);
    debugPrint(out.toString());
  });
}
