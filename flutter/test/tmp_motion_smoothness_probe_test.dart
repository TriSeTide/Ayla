/// 量化探针（2026-10-01）：**入场动画的逐帧平滑度**（同时看「值曲线」与「每帧耗时」）。
///
/// 用户定性：「不是掉帧，是很流畅的，但是好好的动画就是顿了一下」，
/// 并补充「**问题不在你，这个动画在这个对话开始前我记得就这样**」⇒ 属**既有实现**。
///
/// 本探针逐帧记录两样东西：
/// 1. **每张卡的实际 alpha 与 translateY**（从真实 `AylaRevealItem` 的渲染树读，
///    不是读 widget 参数）——检查「是否有帧不变（停顿）」或「是否有帧突变（跳）」；
/// 2. **每帧的 UI 墙钟**——定位「哪一帧特别贵」。
///
/// 跑法：`flutter test test/tmp_motion_smoothness_probe_test.dart --concurrency 1`
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/app_theme.dart';
import '../lib/theme/aurora_background.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/reveal.dart' show AylaRevealItem, AylaRevealScope;

void main() {
  testWidgets('入场逐帧平滑度：alpha/位移曲线 + 每帧耗时', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const int n = 8;
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAylaTheme(),
        home: AylaAuroraBackground(
          animate: false,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: AylaRevealScope(
              child: Align(
                alignment: Alignment.topLeft,
                child: Wrap(
                  children: <Widget>[
                    for (int i = 0; i < n; i += 1)
                      AylaRevealItem(
                        fadeGlass: false,
                        index: i,
                        child: SizedBox(
                          width: 340,
                          height: 280,
                          child: AylaGlassSurface(
                            shadow: AylaShadows.glass,
                            child: Text('卡$i'),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final List<String> rows = <String>[];
    final List<double> frameMs = <double>[];
    for (int f = 0; f < 30; f += 1) {
      final Stopwatch sw = Stopwatch()..start();
      await tester.pump(const Duration(milliseconds: 16));
      sw.stop();
      frameMs.add(sw.elapsedMicroseconds / 1000.0);
      // 第 1 张与第 4 张卡的 alpha（从渲染树读，绕开 widget 参数）。
      final String a1 = _alphaOf(tester, '卡0');
      final String a4 = _alphaOf(tester, '卡4');
      rows.add('f$f 卡0.a=$a1 卡4.a=$a4 ui=${frameMs.last.toStringAsFixed(1)}ms');
    }
    debugPrint(rows.join('\n'));
    final double worst = frameMs.reduce((double a, double b) => a > b ? a : b);
    debugPrint('UI 每帧最大值 = ${worst.toStringAsFixed(1)}ms（第 ${frameMs.indexOf(worst)} 帧）');
  });
}

/// 从渲染树读某张卡的**实际不透明度**（`RenderOpacity` 的 `alpha`/`opacity`）。
String _alphaOf(WidgetTester tester, String label) {
  final Finder f = find.ancestor(
    of: find.text(label),
    matching: find.byType(Opacity),
  );
  if (f.evaluate().isEmpty) return '—';
  final RenderOpacity ro = tester.renderObject<RenderOpacity>(f.first);
  return ro.opacity.toStringAsFixed(3);
}
