/// 量化探针（2026-09-30，第十二批）：**「最后一批卡」入场的逐帧 raster 形状**。
///
/// 用户实机：「动画最后一个阶段就是会顿一下，不连贯，很割裂」。
/// 事实源（web）：`useListEntryMotion.ts:74–80` 用 WAAPI 只动 `opacity` + `transform`
/// （合成属性 ⇒ 元素被提升为**合成层**、结果缓存成纹理 ⇒ **动画期间零 backdrop 重算**），
/// 结束后 `animation.cancel()` 撤销提升；`.reveal-item`（`base.css:495–499`）同理。
/// Flutter 侧的等价物 = 入场期间把背底层冻成纹理（`SnapshotWidget`，已落地），
/// 但**解冻**是结构切换 ⇒ 那一帧必须重建 `BackdropFilterLayer` 并做一次完整模糊。
/// 本探针模拟「delay 被 cap 到 300ms」的一批卡（= 用户说的最后一批），逐帧测 raster，
/// 看峰值落在**可见帧（~300ms）**还是**解冻帧（~600ms）**，从而确定还该削哪个峰。
///
/// 跑法：`flutter test test/tmp_last_batch_probe_test.dart --concurrency 1`
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/app_theme.dart';
import '../lib/theme/aurora_background.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/reveal.dart' show AylaRevealItem;

void main() {
  const int kCards = 8;
  final GlobalKey rootKey = GlobalKey();

  Widget scene() => RepaintBoundary(
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
                    for (int i = 0; i < kCards; i += 1)
                      AylaRevealItem(
                        fadeGlass: false,
                        index: i,
                        // 「最后一批」：stagger 已被 cap（web `staggerDelay` = min(i*50, 300)）。
                        delay: const Duration(milliseconds: 300),
                        duration: const Duration(milliseconds: 300),
                        child: SizedBox(
                          width: 360,
                          height: 300,
                          child: AylaGlassSurface(
                            shadow: AylaShadows.glass,
                            child: const Text('卡片'),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
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

  testWidgets('最后一批卡：逐帧 raster 形状（定位峰值帧）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(scene());
    await tester.pump();
    final List<double> ms = <double>[];
    final List<int> atMs = <int>[];
    int elapsed = 0;
    final int frames = 48; // 48 × 16ms ≈ 768ms（覆盖 300ms 可见 + 600ms 解冻）
    for (int i = 0; i < frames; i += 1) {
      await tester.pump(const Duration(milliseconds: 16));
      elapsed += 16;
      atMs.add(elapsed);
      ms.add(await timeToImage(tester));
    }
    double peak = 0;
    int peakIdx = 0;
    for (int i = 0; i < ms.length; i += 1) {
      if (ms[i] > peak) {
        peak = ms[i];
        peakIdx = i;
      }
    }
    final double total = ms.reduce((double a, double b) => a + b);
    debugPrint(
      '合计 ${total.toStringAsFixed(0)} ms / $frames 帧 · 峰值 ${peak.toStringAsFixed(1)} ms '
      '（第 $peakIdx 帧 ≈ ${atMs[peakIdx]}ms）',
    );
    // 分窗统计：delay 期（0–300）· 动画期（300–600）· 解冻期（600+）。
    for (final List<int> win in <List<int>>[
      <int>[0, 300],
      <int>[300, 600],
      <int>[600, 800],
    ]) {
      final List<double> inWin = <double>[
        for (int i = 0; i < ms.length; i += 1)
          if (atMs[i] > win[0] && atMs[i] <= win[1]) ms[i],
      ];
      if (inWin.isEmpty) continue;
      inWin.sort();
      debugPrint(
        '窗口 ${win[0]}–${win[1]}ms · n=${inWin.length} · '
        '中位 ${inWin[inWin.length ~/ 2].toStringAsFixed(1)} · 最大 ${inWin.last.toStringAsFixed(1)}',
      );
    }
    debugPrint('逐帧：${ms.map((double v) => v.toStringAsFixed(0)).join(" ")}');
  });
}
