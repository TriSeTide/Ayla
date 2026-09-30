/// 量化探针（2026-09-30，第十一批）：**静止期冻结快照的视觉可辨性**。
///
/// 动机：实测「6 张玻璃卡静止（卡与背景都不动）连续 6 帧 = 34–37 ms」（软件光栅化）
/// ⇒ **每帧都在全额重算 backdrop 模糊**（Flutter 没有 web 的合成层纹理缓存）。
/// 一屏 20 张卡的页面就是每帧 20 次高斯模糊 ⇒ 实机余量被吃光。唯一能省的手段是
/// **把静止的卡冻成纹理**，代价是卡内模糊背景不再逐帧更新。
/// 本探针量化这个代价：`AylaAuroraBackground(animate: true)` 下卡区域颜色的
/// 时间漂移 —— **若 500ms 漂移 ≲1/255，则「每 500ms 重新捕获一次」与逐帧更新肉眼无差**。
///
/// 跑法：`flutter test test/tmp_aurora_drift_probe_test.dart --concurrency 1`
library;

import 'dart:typed_data';
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

  Widget scene({required bool animate}) => RepaintBoundary(
        key: rootKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAylaTheme(),
          home: AylaAuroraBackground(
            animate: animate,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: kCardW,
                  height: kCardH,
                  child: AylaGlassSurface(
                    shadow: AylaShadows.glass,
                    child: const Text('卡片'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  Future<List<double>> sample(WidgetTester tester, Offset center) async {
    final RenderRepaintBoundary boundary =
        rootKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    return (await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
      final ByteData? data =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      if (data == null) return <double>[-1, -1, -1];
      final Uint8List bytes = data.buffer.asUint8List();
      final int w = image.width;
      double r = 0, g = 0, b = 0;
      int n = 0;
      for (double dy = -24; dy < 24; dy += 2) {
        for (double dx = -24; dx < 24; dx += 2) {
          final int i =
              ((center.dy + dy).round()) * w * 4 + (center.dx + dx).round() * 4;
          r += bytes[i];
          g += bytes[i + 1];
          b += bytes[i + 2];
          n += 1;
        }
      }
      return <double>[r / n, g / n, b / n];
    }))!;
  }

  testWidgets('背景动画下卡区域颜色的时间漂移（判定冻结刷新的可辨性）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const Offset cardPoint = Offset(120, 80);
    const Offset bgPoint = Offset(600, 480);

    final StringBuffer out = StringBuffer();
    for (final bool animate in <bool>[false, true]) {
      await tester.pumpWidget(scene(animate: animate));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final List<double> base = await sample(tester, cardPoint);
      final List<double> baseBg = await sample(tester, bgPoint);
      out.writeln(
        'animate=$animate 基准 卡=${base.map((double v) => v.toStringAsFixed(0)).join(",")} '
        '背景=${baseBg.map((double v) => v.toStringAsFixed(0)).join(",")}',
      );
      for (final int ms in <int>[250, 500, 1000, 2000]) {
        await tester.pump(Duration(milliseconds: ms));
        final List<double> now = await sample(tester, cardPoint);
        final List<double> nowBg = await sample(tester, bgPoint);
        double maxDelta = 0;
        for (int i = 0; i < 3; i += 1) {
          final double d = (now[i] - base[i]).abs();
          if (d > maxDelta) maxDelta = d;
        }
        double maxDeltaBg = 0;
        for (int i = 0; i < 3; i += 1) {
          final double d = (nowBg[i] - baseBg[i]).abs();
          if (d > maxDeltaBg) maxDeltaBg = d;
        }
        out.writeln(
          '  +${ms}ms 卡=${now.map((double v) => v.toStringAsFixed(0)).join(",")} '
          '|Δ|=${maxDelta.toStringAsFixed(1)}  背景 |Δ|=${maxDeltaBg.toStringAsFixed(1)}',
        );
      }
    }
    debugPrint(out.toString());
  });
}
