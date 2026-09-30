/// 量化探针（2026-09-30，第九/十批性能整改）：**每帧 UI 线程成本分解**。
///
/// ## 为什么要有它（回答用户「什么都掉帧」的定位问题）
/// 官方性能文档把掉帧分成两半：**UI 线程**（build/layout/paint/Scene 构建）与
/// **Raster 线程**（光栅化，含 backdrop 捕获 + 高斯模糊）。
/// `flutter test` 只跑 UI 线程（`TestWindow.render` 不做光栅化）⇒
/// **本探针的绝对值只能回答「UI 侧是否已经吃掉一帧预算」**：
/// - UI 中位数 > 16ms ⇒ 是 UI 瓶颈，可直接在这里定位并优化；
/// - UI 中位数 ≪ 16ms ⇒ 掉帧在 raster（玻璃卡的每帧捕获 + 模糊），
///   需真机 `flutter drive --profile` 的 `timeline_summary.json` 佐证。
///
/// 同时输出**确定性结构计数**（BackdropFilter 数量 + 玻璃层总面积），
/// 这是 raster 成本的一阶代理（每帧每张卡都要重采样 + 高斯模糊）。
///
/// 跑法：`flutter test test/tmp_frame_cost_probe_test.dart --concurrency 1`
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/app_theme.dart';
import '../lib/theme/aurora_background.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/reveal.dart' show AylaRevealItem;

void main() {
  const double kCardW = 360;
  const double kCardH = 300;

  Widget card({double blur = AylaGlass.blurCard, bool shadow = true}) {
    return SizedBox(
      width: kCardW,
      height: kCardH,
      child: AylaGlassSurface(
        blur: blur,
        shadow: shadow ? AylaShadows.glass : const <BoxShadow>[],
        child: const Text('卡片'),
      ),
    );
  }

  Widget scene({
    required int cards,
    required bool flow,
    double blur = AylaGlass.blurCard,
    bool shadow = true,
    bool entry = false,
  }) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAylaTheme(),
      home: AylaAuroraBackground(
        animate: flow,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SingleChildScrollView(
            child: Wrap(
              children: <Widget>[
                for (int i = 0; i < cards; i += 1)
                  entry
                      ? AylaRevealItem(
                          fadeGlass: false,
                          delay: Duration(milliseconds: i * 50),
                          duration: const Duration(milliseconds: 300),
                          child: card(blur: blur, shadow: shadow),
                        )
                      : card(blur: blur, shadow: shadow),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 结构计数：离屏合成的层数 + 玻璃层总面积（raster 成本代理）。
  String structReport(WidgetTester tester) {
    int backdrop = 0;
    int opacity = 0;
    int clip = 0;
    int boundary = 0;
    double glassArea = 0;
    void visit(RenderObject ro) {
      if (ro is RenderBackdropFilter) {
        backdrop += 1;
        final Size s = ro.size;
        glassArea += s.width * s.height;
      } else if (ro is RenderOpacity && ro.opacity > 0 && ro.opacity < 1) {
        opacity += 1;
      } else if (ro is RenderClipRRect) {
        clip += 1;
      } else if (ro is RenderRepaintBoundary) {
        boundary += 1;
      }
      ro.visitChildren(visit);
    }

    visit(tester.binding.renderView);
    return 'backdrop=$backdrop 玻璃面积=${glassArea.toStringAsFixed(0)}px² '
        'opacity(0<a<1)=$opacity clipRRect=$clip repaintBoundary=$boundary';
  }

  /// 中位数每帧墙钟耗时（ms）——比均值抗 GC/JIT 尖峰（13 号记过 2.9–11.7ms 跳动）。
  Future<double> medianFrameMs(
    WidgetTester tester,
    Widget widget, {
    int frames = 24,
    int stepsPerFrame = 8,
  }) async {
    await tester.pumpWidget(widget);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final List<double> samples = <double>[];
    for (int i = 0; i < frames; i += 1) {
      final Stopwatch sw = Stopwatch()..start();
      for (int s = 0; s < stepsPerFrame; s += 1) {
        await tester.pump(const Duration(milliseconds: 2));
      }
      sw.stop();
      samples.add(sw.elapsedMicroseconds / stepsPerFrame / 1000.0);
    }
    samples.sort();
    return samples[samples.length ~/ 2];
  }

  testWidgets('每帧 UI 成本分解 + 结构计数', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // 预热：首轮含 JIT / 首次布局，丢弃。
    await medianFrameMs(tester, scene(cards: 4, flow: true), frames: 6);

    final Map<String, Widget> cases = <String, Widget>{
      'A 背景静止 · 0 卡': scene(cards: 0, flow: false),
      'B 背景动画 · 0 卡': scene(cards: 0, flow: true),
      'C 背景静止 · 12 卡': scene(cards: 12, flow: false),
      'D 背景动画 · 12 卡': scene(cards: 12, flow: true),
      'E 背景动画 · 12 卡 blur=0': scene(cards: 12, flow: true, blur: 0),
      'F 背景动画 · 12 卡 无阴影': scene(cards: 12, flow: true, shadow: false),
      'G 背景动画 · 12 卡 + 入场': scene(cards: 12, flow: true, entry: true),
      'H 背景动画 · 1 卡': scene(cards: 1, flow: true),
    };

    final StringBuffer out = StringBuffer();
    out.writeln('构型 | 每帧 UI 中位数(ms) | 结构');
    final Map<String, double> ms = <String, double>{};
    for (final MapEntry<String, Widget> e in cases.entries) {
      final double v = await medianFrameMs(tester, e.value);
      ms[e.key] = v;
      out.writeln('${e.key} | ${v.toStringAsFixed(3)} | ${structReport(tester)}');
    }
    // 第二轮反向复测（消除「后测的构型占便宜」这类系统性偏差）。
    out.writeln('--- 反向复测 ---');
    for (final MapEntry<String, Widget> e in cases.entries.toList().reversed) {
      final double v = await medianFrameMs(tester, e.value);
      out.writeln('${e.key} | ${v.toStringAsFixed(3)}（正向 ${ms[e.key]!.toStringAsFixed(3)}）');
    }
    debugPrint(out.toString());
  });
}
