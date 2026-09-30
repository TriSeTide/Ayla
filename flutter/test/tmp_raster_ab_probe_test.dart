/// 量化探针（2026-09-30）：**玻璃卡 raster 成本分解**（saturate / ClipRRect / 阴影 / sigma）。
///
/// 目的：在「UI 线程 <2ms、raster 是瓶颈」已确认的前提下，找出每张玻璃卡
/// 7–8ms（软件光栅化）里各成分的占比，作为**零观感软件层优化**的靶点。
/// 口径同 `tmp_raster_cost_probe_test.dart`：只取相对量级，绝对值≠GPU。
///
/// 跑法：`flutter test test/tmp_raster_ab_probe_test.dart --concurrency 1`
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

  /// 与 `AylaGlassSurface` 同结构的可参数化玻璃卡（只保留 raster 相关层）。
  Widget glass({
    double blur = 24,
    bool saturate = true,
    bool clip = true,
    bool shadow = true,
    int cards = 1,
  }) {
    final BorderRadius br = BorderRadius.circular(16);
    final ui.ImageFilter filter = saturate
        ? ui.ImageFilter.compose(
            outer: const ColorFilter.matrix(kSaturation14),
            inner: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          )
        : ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur);
    final Widget face = DecoratedBox(
      decoration: BoxDecoration(
        color: AylaGlassConfig.resolveBackground(strong: false, opaqueSoft: false),
        borderRadius: br,
        border: Border.all(color: AylaColors.glassBorder),
      ),
      child: SizedBox(
        width: kCardW,
        height: kCardH,
        child: const Text('卡片'),
      ),
    );
    final Widget card = Stack(
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: <Widget>[
        if (blur > 0)
          Positioned.fill(
            child: AylaGlassBackdrop(
              radius: clip ? br : null,
              filter: filter,
            ),
          ),
        if (shadow)
          Positioned.fill(
            child: IgnorePointer(
              child: AylaGlassShadow.ring(radius: br, shadows: AylaShadows.glass),
            ),
          ),
        face,
      ],
    );
    return SizedBox(
      width: kCardW,
      height: kCardH,
      child: cards == 1
          ? card
          : Wrap(
              children: <Widget>[for (int i = 0; i < cards; i += 1) card],
            ),
    );
  }

  Widget scene(Widget child) {
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
              child: SizedBox(width: 1200, height: 900, child: child),
            ),
          ),
        ),
      ),
    );
  }

  Future<double> toImageMedian(WidgetTester tester, Widget widget,
      {int samples = 3}) async {
    await tester.pumpWidget(scene(widget));
    await tester.pump();
    final RenderRepaintBoundary boundary =
        rootKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
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

  testWidgets('玻璃卡 raster 成本分解（3 卡规模）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final StringBuffer out = StringBuffer('变体 | 光栅化中位数(ms)');
    Future<void> m(String label, Widget w) async {
      final double v = await toImageMedian(tester, w);
      out.writeln('$label | ${v.toStringAsFixed(2)}');
    }

    await m('0 卡（纯背景）', glass(cards: 0));
    await m('3 卡 全量（blur24+saturate+clip+阴影）', glass(cards: 3));
    await m('3 卡 去 saturate', glass(cards: 3, saturate: false));
    await m('3 卡 去 ClipRRect', glass(cards: 3, clip: false));
    await m('3 卡 去阴影', glass(cards: 3, shadow: false));
    await m('3 卡 去 saturate+clip+阴影', glass(cards: 3, saturate: false, clip: false, shadow: false));
    await m('3 卡 blur=0（无滤镜层）', glass(cards: 3, blur: 0));
    debugPrint(out.toString());
  });
}
