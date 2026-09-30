/// 量化探针（2026-09-30）：**入场快照（`SnapshotWidget`）的 raster 收益 + 解冻帧检查**。
///
/// ## 为什么用「生产路径」而不是手搭 widget
/// 本探针把 `AylaGlassSurface` 直接包在 `AylaRevealProgress(progress:, snapshot:)` 里 ——
/// 这正是 `AylaRevealItem(fadeGlass: false)` 在 `reveal.dart` 里分发给玻璃件的**同一条路径**
/// （`_buildBody` 的 `entry != null && snapshot != null` 分支 ⇒ coreBody + SnapshotWidget）。
/// 因此测出的数字就是「启用生产快照路径」的收益，无需改动生产代码。
///
/// ## 口径
/// 与 `tmp_raster_cost_probe_test.dart` 相同：软件光栅化（Skia CPU），只取**相对**量级。
///
/// 跑法：`flutter test test/tmp_snapshot_gain_probe_test.dart --concurrency 1`
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

void main() {
  const double kCardW = 360;
  const double kCardH = 300;
  final GlobalKey rootKey = GlobalKey();

  /// 一张走「玻璃档快照路径」的卡（= 生产路径）。
  Widget snapCard(SnapshotController controller) {
    return SizedBox(
      width: kCardW,
      height: kCardH,
      child: AylaRevealProgress(
        progress: const AlwaysStoppedAnimation<double>(1),
        snapshot: controller,
        child: AylaGlassSurface(
          blur: AylaGlass.blurCard,
          shadow: AylaShadows.glass,
          child: const Text('卡片'),
        ),
      ),
    );
  }

  Widget scene(List<Widget> cards) {
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
              child: Wrap(children: cards),
            ),
          ),
        ),
      ),
    );
  }

  Future<double> toImageMedian(
    WidgetTester tester, {
    int samples = 3,
  }) async {
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

  /// 数「非全透明」像素占比（判定解冻帧是否空白）。
  Future<double> opaqueRatio(WidgetTester tester) async {
    final RenderRepaintBoundary boundary =
        rootKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    return (await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
      final ByteData? data =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      if (data == null) return -1.0;
      final Uint8List bytes = data.buffer.asUint8List();
      int opaque = 0;
      int total = 0;
      for (int i = 3; i < bytes.length; i += 4) {
        total += 1;
        if (bytes[i] > 8) opaque += 1;
      }
      return opaque / total;
    }))!;
  }

  testWidgets('快照收益：实时模糊 vs 冻结纹理（生产路径）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const int n = 6;
    final List<SnapshotController> controllers = <SnapshotController>[
      for (int i = 0; i < n; i += 1) SnapshotController(),
    ];
    addTearDown(() {
      for (final SnapshotController c in controllers) {
        c.dispose();
      }
    });
    final List<Widget> cards = <Widget>[
      for (int i = 0; i < n; i += 1) snapCard(controllers[i]),
    ];

    // 第一趟：allowSnapshotting 全 false ⇒ 实时 BackdropFilter（= 改前基线）。
    await tester.pumpWidget(scene(cards));
    await tester.pump();
    final double live = await toImageMedian(tester);

    // 第二趟：开启快照并让 child 落一帧（捕获），再测「画纹理」的成本。
    for (final SnapshotController c in controllers) {
      c.allowSnapshotting = true;
    }
    await tester.pump(); // 捕获帧（_paintAndDetachToImage）
    await tester.pump();
    final double frozen = await toImageMedian(tester);

    // 第三趟：解冻（allowSnapshotting = false）→ 检查那一帧是否空白。
    final double beforeUnfreeze = await opaqueRatio(tester);
    for (final SnapshotController c in controllers) {
      c.allowSnapshotting = false;
    }
    await tester.pump();
    final double atUnfreeze = await opaqueRatio(tester);
    await tester.pump();
    final double afterUnfreeze = await opaqueRatio(tester);

    debugPrint('$n 卡 · 实时 BackdropFilter = ${live.toStringAsFixed(2)} ms/帧');
    debugPrint('$n 卡 · 快照冻结纹理   = ${frozen.toStringAsFixed(2)} ms/帧');
    debugPrint('收益 = ${(live / frozen).toStringAsFixed(1)}×');
    debugPrint(
      '解冻帧不透明像素占比：冻结时 ${beforeUnfreeze.toStringAsFixed(4)} → '
      '解冻当帧 ${atUnfreeze.toStringAsFixed(4)} → 下一帧 ${afterUnfreeze.toStringAsFixed(4)}',
    );
  });
}
