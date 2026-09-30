/// 量化探针（2026-09-30，第十三批 c）：**挂载帧的零观感优化点**。
///
/// 用户要求「最好不要与 web 的视觉效果有区别」⇒ 只能做**逐像素等价**的优化。
/// 本支测 `AylaGlassSurface` 的两个 `LayoutBuilder`（内高光 / 缓存面积判定）与
/// 阴影环对「挂载帧 UI 成本」的贡献，判断该先动哪一个。
///
/// 跑法：`flutter test test/tmp_mount_optimize_probe_test.dart --concurrency 1`
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
  const double w = 360;
  const double h = 300;
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

  /// 手搭等价卡（不含 `LayoutBuilder` 内高光、不含缓存层），用于差值定位。
  Widget bareGlass({bool inset = false}) {
    final BorderRadius br = BorderRadius.circular(16);
    return SizedBox(
      width: w,
      height: h,
      child: Stack(
        fit: StackFit.passthrough,
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: AylaGlassBackdrop(
              radius: br,
              repaintBoundary: false,
              filter: ui.ImageFilter.compose(
                outer: const ColorFilter.matrix(kSaturation14),
                inner: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: AylaGlassConfig.resolveBackground(strong: false, opaqueSoft: false),
              borderRadius: br,
              border: Border.all(color: AylaColors.glassBorder),
            ),
            child: inset
                ? LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints c) => DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: br,
                        gradient: AylaInset.topHighlight(c.maxHeight),
                      ),
                    ),
                  )
                : const SizedBox.expand(),
          ),
        ],
      ),
    );
  }

  Future<double> uiMsOfMount(WidgetTester tester, List<Widget> cards) async {
    await tester.pumpWidget(scene(<Widget>[]));
    await tester.pump();
    final Stopwatch sw = Stopwatch()..start();
    await tester.pumpWidget(scene(cards));
    sw.stop();
    return sw.elapsedMicroseconds / 1000.0;
  }

  testWidgets('挂载帧：内高光 LayoutBuilder 的贡献', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.reset();
      AylaGlassConfig.backdropCacheEnabled = true;
    });
    AylaGlassConfig.backdropCacheEnabled = false; // 隔离「捕获」这一项
    const int n = 20;

    final double surface =
        await uiMsOfMount(tester, <Widget>[for (int i = 0; i < n; i += 1) SizedBox(width: w, height: h, child: AylaGlassSurface(shadow: AylaShadows.glass, child: const Text('卡片')))]);
    final double bareNoInset =
        await uiMsOfMount(tester, <Widget>[for (int i = 0; i < n; i += 1) bareGlass()]);
    final double bareInset =
        await uiMsOfMount(tester, <Widget>[for (int i = 0; i < n; i += 1) bareGlass(inset: true)]);

    debugPrint('$n 卡挂载帧 UI：AylaGlassSurface（全量，无缓存）= ${surface.toStringAsFixed(1)} ms');
    debugPrint('$n 卡挂载帧 UI：手搭等价卡（无内高光 LayoutBuilder）= ${bareNoInset.toStringAsFixed(1)} ms');
    debugPrint('$n 卡挂载帧 UI：手搭等价卡（含内高光 LayoutBuilder）= ${bareInset.toStringAsFixed(1)} ms');
    debugPrint(
      '⇒ 内高光 LayoutBuilder 净增量 ≈ ${(bareInset - bareNoInset).toStringAsFixed(1)} ms / $n 卡；'
      'AylaGlassSurface 其余包装（缓存层 + 阴影 + 内高光）≈ '
      '${(surface - bareNoInset).toStringAsFixed(1)} ms',
    );
  });
}
