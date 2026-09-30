/// 量化探针（2026-09-30）：**快照是否保留 backdrop** + **模糊强度×t 的入场语义**。
///
/// ## 问题一（决定快照路线生死）
/// `_RenderSnapshotWidget._paintAndDetachToImage` 用**独立离屏 OffsetLayer** 捕获子树
/// （`snapshot_widget.dart:297–321`）⇒ 子树里的 `BackdropFilter` 在那个离屏 pass 里
/// **看不到外层已绘制内容**，模糊结果应是空的。低频极光背景掩盖了这一点
/// （模糊前后都接近），故本探针在卡后面放**黑白棋盘**（高频）做判别：
///   参考档（实时模糊）⇒ 卡区域应是**均匀灰**；快照档若丢 backdrop ⇒ 卡区域是纯面层色。
///
/// ## 问题二（「变色」的可能正解）
/// 外层 `Opacity` 对 `BackdropFilter` 无效（Impeller 拒绝继承不透明度）⇒ 入场期
/// 「模糊满强度 + 只有面层在淡」= 实机「变色」。若把 **sigma 随进度 t 变化**
/// （t=0 ⇒ sigma 0 ⇒ 卡区域 = 原背景，无空洞；t=1 ⇒ 满态），则首帧等同背景、
/// 末帧等同满态，中间态为「模糊渐显」，且 sigma 小的时候 raster 更便宜。
/// 本探针验证两端点是否严格等于「背景 / 满态」。
///
/// 跑法：`flutter test test/tmp_motion_color_probe_test.dart --concurrency 1`
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
import '../lib/widgets/base/reveal.dart' show AylaRevealProgress;

/// 黑白棋盘（高频 backdrop 判别器）。
class _Checker extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const double cell = 12;
    final Paint dark = Paint()..color = const Color(0xFF101820);
    final Paint light = Paint()..color = const Color(0xFFF0F4F8);
    for (int y = 0; y * cell < size.height; y += 1) {
      for (int x = 0; x * cell < size.width; x += 1) {
        canvas.drawRect(
          Rect.fromLTWH(x * cell, y * cell, cell, cell),
          (x + y).isEven ? dark : light,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _Checker oldDelegate) => false;
}

void main() {
  final GlobalKey rootKey = GlobalKey();
  const Offset cardCenter = Offset(240, 210);

  /// [highFreq]：卡后面是否放棋盘（高频 backdrop）。
  /// [sigmaFactor]：模糊强度乘数（null = 固定 24，即现状）。
  /// [useSnapshot]：是否走快照路径。
  Widget page({
    required double opacity,
    bool highFreq = false,
    double? sigmaFactor,
    SnapshotController? snapshot,
  }) {
    final double sigma = 24 * (sigmaFactor ?? 1.0);
    final Widget backdrop = sigma <= 0.01
        ? const SizedBox.expand()
        : AylaGlassBackdrop(
            radius: BorderRadius.circular(16),
            repaintBoundary: false,
            filter: ui.ImageFilter.compose(
              outer: const ColorFilter.matrix(kSaturation14),
              inner: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            ),
          );
    final Widget face = DecoratedBox(
      decoration: BoxDecoration(
        color: AylaGlassConfig.resolveBackground(strong: false, opaqueSoft: false),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AylaColors.glassBorder),
      ),
      child: const SizedBox(width: 360, height: 300, child: Text('卡片')),
    );
    final Widget card = Stack(
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned.fill(child: backdrop),
        face,
      ],
    );
    final Widget tracked = snapshot == null
        ? card
        : AylaRevealProgress(
            progress: const AlwaysStoppedAnimation<double>(1),
            snapshot: snapshot,
            child: card,
          );
    return RepaintBoundary(
      key: rootKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAylaTheme(),
        home: AylaAuroraBackground(
          animate: false,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Stack(
              children: <Widget>[
                if (highFreq)
                  Positioned(
                    left: 60,
                    top: 60,
                    child: CustomPaint(
                      size: const Size(360, 300),
                      painter: _Checker(),
                    ),
                  ),
                Positioned(
                  left: 60,
                  top: 60,
                  child: Opacity(opacity: opacity, child: tracked),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<List<double>> sample(WidgetTester tester, Offset center) async {
    final RenderRepaintBoundary boundary =
        rootKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    return (await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
      final ByteData? data =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      if (data == null) return <double>[-1, -1, -1, -1];
      final Uint8List bytes = data.buffer.asUint8List();
      final int w = image.width;
      double r = 0, g = 0, b = 0;
      int n = 0;
      for (double dy = -16; dy < 16; dy += 1) {
        for (double dx = -16; dx < 16; dx += 1) {
          final int i = ((center.dy + dy).round()) * w * 4 + (center.dx + dx).round() * 4;
          r += bytes[i];
          g += bytes[i + 1];
          b += bytes[i + 2];
          n += 1;
        }
      }
      return <double>[r / n, g / n, b / n, 1.0];
    }))!;
  }

  String fmt(List<double> c) =>
      '(${c[0].toStringAsFixed(0)},${c[1].toStringAsFixed(0)},${c[2].toStringAsFixed(0)})';

  testWidgets('问题一：快照是否保留 backdrop（高频棋盘判别）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final StringBuffer out = StringBuffer();
    // 棋盘中心（卡外，无遮挡）作为对照。
    const Offset checkerPoint = Offset(560, 480);
    // 先测「无卡」时棋盘的样子。
    await tester.pumpWidget(page(opacity: 0, highFreq: true));
    await tester.pump();
    out.writeln('棋盘（无卡遮挡）= ${fmt(await sample(tester, cardCenter))} · 棋盘点 = ${fmt(await sample(tester, checkerPoint))}');

    // 参考档：满态实时模糊。
    await tester.pumpWidget(page(opacity: 1, highFreq: true));
    await tester.pump();
    final List<double> refFull = await sample(tester, cardCenter);
    out.writeln('参考 · 满态实时模糊（卡区域）= ${fmt(refFull)}');

    // 快照档：开启快照后测量。
    final SnapshotController sc = SnapshotController(allowSnapshotting: true);
    addTearDown(sc.dispose);
    await tester.pumpWidget(page(opacity: 1, highFreq: true, snapshot: sc));
    await tester.pump();
    await tester.pump();
    final List<double> snapFull = await sample(tester, cardCenter);
    out.writeln('快照 · 满态冻结纹理（卡区域）= ${fmt(snapFull)}  snap=${sc.allowSnapshotting}');
    out.writeln('⇒ 差异 = R${(snapFull[0] - refFull[0]).toStringAsFixed(0)} '
        'G${(snapFull[1] - refFull[1]).toStringAsFixed(0)} '
        'B${(snapFull[2] - refFull[2]).toStringAsFixed(0)}'
        '（小≈保留 backdrop；大≈模糊丢失）');

    // 低透明度档：t=0.3 时两档对比（用户「变色」现场）。
    await tester.pumpWidget(page(opacity: 0.3, highFreq: true));
    await tester.pump();
    out.writeln('参考 · t=0.3（模糊满强度 + 面层淡）= ${fmt(await sample(tester, cardCenter))}');
    debugPrint(out.toString());
  });

  testWidgets('问题二：模糊强度×t 的两端是否等于「背景 / 满态」', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final StringBuffer out = StringBuffer();
    // 背景基准：不画卡（opacity 0 的卡不渲染）。取同一位置。
    await tester.pumpWidget(page(opacity: 0, highFreq: true));
    await tester.pump();
    final List<double> bg = await sample(tester, cardCenter);
    out.writeln('背景（该位置无卡）= ${fmt(bg)}');

    // t=0 且 sigma×t = 0。
    await tester.pumpWidget(page(opacity: 0, highFreq: true, sigmaFactor: 0));
    await tester.pump();
    out.writeln('sigma×t=0 · opacity=0 = ${fmt(await sample(tester, cardCenter))}');

    // t=1 且 sigma 满。
    await tester.pumpWidget(page(opacity: 1, highFreq: true, sigmaFactor: 1));
    await tester.pump();
    out.writeln('sigma 满 · opacity=1 = ${fmt(await sample(tester, cardCenter))}');

    // t=0.5 档（sigma 半 + opacity 0.5）——观察中间态是否「从背景浮现」。
    await tester.pumpWidget(page(opacity: 0.5, highFreq: true, sigmaFactor: 0.5));
    await tester.pump();
    out.writeln('sigma×0.5 · opacity=0.5 = ${fmt(await sample(tester, cardCenter))}');
    debugPrint(out.toString());
  });
}
