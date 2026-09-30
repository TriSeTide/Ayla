/// 量化探针（2026-09-30，第十一批）：**入场逐帧 raster 成本曲线**（三种档）。
///
/// 用户实机：「出现全部卡片时掉帧」「就位前一帧有一部分卡片偏白」。
/// 那一批卡（第 7 张起）的 stagger 被 cap 到 300ms ⇒ **同时开始渲染** ⇒ 峰值帧。
/// 本探针逐帧光栅化计时，比较三条入场实现：
///   · `fixed`    —— 背底层 sigma 恒 24（= 关闭快照后的现状）；
///   · `sigmaT`   —— sigma = 24×t（拟议：t=0 时卡区域**完全等同背景**，模糊渐显）；
///   · `snapshot` —— 背底层冻成纹理（当前已启用的路径：捕获帧 + 解冻帧是峰值）。
/// 测量用 `RepaintBoundary.toImage()`（软件光栅化，真实执行 backdrop 捕获 / 高斯模糊 / saveLayer）。
///
/// 跑法：`flutter test test/tmp_entry_cost_probe_test.dart --concurrency 1`
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/app_theme.dart';
import '../lib/theme/aurora_background.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/tokens.dart';

enum _Mode { fixed, sigmaT, snapshot }

void main() {
  const double kCardW = 360;
  const double kCardH = 300;
  const int kCards = 6;
  final GlobalKey rootKey = GlobalKey();

  Widget scene(Widget child) => RepaintBoundary(
        key: rootKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAylaTheme(),
          home: AylaAuroraBackground(
            animate: false,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: Align(alignment: Alignment.topLeft, child: child),
            ),
          ),
        ),
      );

  Future<double> timeToImage(WidgetTester tester) async {
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

  testWidgets('入场逐帧 raster 成本：fixed vs sigma×t vs snapshot', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    for (final _Mode mode in _Mode.values) {
      final GlobalKey<_EntryDriverState> driver = GlobalKey<_EntryDriverState>();
      final List<double> ms = <double>[];
      await tester.pumpWidget(scene(_EntryDriver(key: driver, mode: mode, cards: kCards)));
      await tester.pump();
      for (int i = 0; i <= 20; i += 1) {
        driver.currentState!.setProgress(i / 20);
        await tester.pump();
        ms.add(await timeToImage(tester));
      }
      final double total = ms.reduce((double a, double b) => a + b);
      final double peak = ms.reduce((double a, double b) => a > b ? a : b);
      final int peakAt = ms.indexOf(peak);
      debugPrint(
        '${mode.name.padRight(9)} 21 帧合计 = ${total.toStringAsFixed(0)} ms · '
        '单帧峰值 = ${peak.toStringAsFixed(0)} ms（第 $peakAt 帧）· '
        '前 5 帧 = ${ms.take(5).map((double v) => v.toStringAsFixed(0)).join("/")} · '
        '末 3 帧 = ${ms.skip(18).map((double v) => v.toStringAsFixed(0)).join("/")}',
      );
    }
  });

  testWidgets('静止时每帧成本（卡与背景都不动）—— 验证模糊是否每帧重算', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    for (final int cards in <int>[0, 3, 6]) {
      final GlobalKey<_EntryDriverState> driver = GlobalKey<_EntryDriverState>();
      await tester.pumpWidget(
        scene(_EntryDriver(key: driver, mode: _Mode.fixed, cards: cards, frozenProgress: true)),
      );
      await tester.pump();
      final List<double> ms = <double>[];
      for (int i = 0; i < 6; i += 1) {
        await tester.pump();
        ms.add(await timeToImage(tester));
      }
      debugPrint(
        '$cards 卡静止（t=1，卡与背景皆不动）· 连续 6 帧 = '
        '${ms.map((double v) => v.toStringAsFixed(0)).join("/")} ms',
      );
    }
  });
}

/// 自持进度 `t` 的驱动器：**保持同一棵 element 树**（否则 `SnapshotWidget` 每次都会重新捕获，
/// 测不出「捕获一次 + 复用纹理」的真实成本）。
class _EntryDriver extends StatefulWidget {
  const _EntryDriver({
    super.key,
    required this.mode,
    required this.cards,
    this.frozenProgress = false,
  });

  final _Mode mode;
  final int cards;
  final bool frozenProgress;

  @override
  State<_EntryDriver> createState() => _EntryDriverState();
}

class _EntryDriverState extends State<_EntryDriver> {
  double _t = 0;
  SnapshotController? _snapshot;

  @override
  void initState() {
    super.initState();
    if (widget.mode == _Mode.snapshot) {
      _snapshot = SnapshotController(allowSnapshotting: true);
    }
    if (widget.frozenProgress) _t = 1;
  }

  @override
  void dispose() {
    _snapshot?.dispose();
    super.dispose();
  }

  void setProgress(double v) => setState(() => _t = v);

  @override
  Widget build(BuildContext context) {
    final BorderRadius br = BorderRadius.circular(16);
    return Wrap(
      children: <Widget>[
        for (int i = 0; i < widget.cards; i += 1)
          Opacity(
            opacity: _t,
            child: Transform.translate(
              offset: Offset(0, 20 * (1 - _t)),
              child: SizedBox(
                width: 360,
                height: 300,
                child: Stack(
                  fit: StackFit.passthrough,
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    Positioned.fill(child: _backdrop(br, br)),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: AylaGlassConfig.resolveBackground(
                          strong: false,
                          opaqueSoft: false,
                        ),
                        borderRadius: br,
                        border: Border.all(color: AylaColors.glassBorder),
                      ),
                      child: const Text('卡片'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _backdrop(BorderRadius br, BorderRadius unused) {
    switch (widget.mode) {
      case _Mode.fixed:
        return _glass(br, 24);
      case _Mode.sigmaT:
        final double sigma = 24 * _t;
        return sigma <= 0.5 ? const SizedBox.expand() : _glass(br, sigma);
      case _Mode.snapshot:
        return AylaRevealProgressProbe(
          controller: _snapshot!,
          child: _glass(br, 24),
        );
    }
  }

  Widget _glass(BorderRadius br, double sigma) => AylaGlassBackdrop(
        radius: br,
        repaintBoundary: false,
        filter: ui.ImageFilter.compose(
          outer: const ColorFilter.matrix(kSaturation14),
          inner: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        ),
      );
}

/// 只做「把 SnapshotWidget 塞进子树」的最小包装（探针内用，不引生产件的私有面）。
class AylaRevealProgressProbe extends StatelessWidget {
  const AylaRevealProgressProbe({super.key, required this.controller, required this.child});

  final SnapshotController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SnapshotWidget(
      mode: SnapshotMode.permissive,
      controller: controller,
      child: child,
    );
  }
}
