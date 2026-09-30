/// 量化探针（2026-09-30）：**入场快照的端到端时序与内容等价**（走真实 `AylaRevealItem`）。
///
/// 对照两档：
/// - **参考档** `AylaRevealItem(fadeGlass: true)` —— 不装快照，整层 `Opacity`（改前行为）；
/// - **快照档** `AylaRevealItem(fadeGlass: false)` —— 背底层冻成纹理（新路径）。
/// 两档除这一处外完全相同 ⇒ 逐帧卡区域像素应当一致（快照内容等价），
/// 且冻结/解冻的时机可用 `find.byType(SnapshotWidget)` 计数直接观察。
///
/// ⚠️ `flutter test` 是软件光栅化 ⇒ 「解冻帧空白」若只存在于 GPU/Impeller 时序，
/// 本探针**测不到**（那正是它必须在结构上被消除的理由：解冻 = 整棵快照子树被替换）。
///
/// 跑法：`flutter test test/tmp_unfreeze_probe_test.dart --concurrency 1`
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
import '../lib/widgets/base/reveal.dart' show AylaRevealItem;

void main() {
  final GlobalKey rootKey = GlobalKey();
  const Offset cardCenter = Offset(240, 210);

  Widget scene(Widget card) => RepaintBoundary(
        key: rootKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAylaTheme(),
          home: AylaAuroraBackground(
            animate: false,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: Stack(
                children: <Widget>[Positioned(left: 60, top: 60, child: card)],
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
      for (double dy = -16; dy < 16; dy += 1) {
        for (double dx = -16; dx < 16; dx += 1) {
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

  Future<List<String>> run(WidgetTester tester,
      {required bool fadeGlass, int frames = 24}) async {
    await tester.pumpWidget(scene(
      AylaRevealItem(
        // 两轮必须换 element：同类型同位置的 element 会复用 State ⇒ `_started` 守卫
        // 让第二轮不再入场（探针实测踩到，非生产缺陷）。
        key: ValueKey<bool>(fadeGlass),
        fadeGlass: fadeGlass,
        duration: const Duration(milliseconds: 300),
        child: AylaGlassSurface(
          blur: AylaGlass.blurCard,
          shadow: AylaShadows.glass,
          child: const SizedBox(width: 360, height: 300, child: Text('卡片')),
        ),
      ),
    ));
    await tester.pump();
    final List<String> rows = <String>[];
    for (int i = 0; i < frames; i += 1) {
      await tester.pump(const Duration(milliseconds: 16));
      final List<double> c = await sample(tester, cardCenter);
      rows.add('f$i 快照件=${find.byType(SnapshotWidget).evaluate().length} '
          '卡=(${c[0].toStringAsFixed(0)},${c[1].toStringAsFixed(0)},${c[2].toStringAsFixed(0)})');
    }
    return rows;
  }

  testWidgets('入场快照：端到端时序 + 与参考档逐帧对照', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final List<String> ref = await run(tester, fadeGlass: true);
    final List<String> snap = await run(tester, fadeGlass: false);
    debugPrint('=== 参考档（fadeGlass: true，无快照）===');
    for (final String r in ref) {
      debugPrint(r);
    }
    debugPrint('=== 快照档（fadeGlass: false）===');
    for (final String r in snap) {
      debugPrint(r);
    }
    // 逐帧差异汇总（只报数值差，便于判断等价性）。
    final StringBuffer diff = StringBuffer('逐帧 |Δ|（参考 vs 快照）：');
    for (int i = 0; i < ref.length && i < snap.length; i += 1) {
      final RegExp re = RegExp(r'卡=\((\d+),(\d+),(\d+)\)');
      final Match? a = re.firstMatch(ref[i]);
      final Match? b = re.firstMatch(snap[i]);
      if (a == null || b == null) continue;
      final int d = <int>[
        (int.parse(a.group(1)!) - int.parse(b.group(1)!)).abs(),
        (int.parse(a.group(2)!) - int.parse(b.group(2)!)).abs(),
        (int.parse(a.group(3)!) - int.parse(b.group(3)!)).abs(),
      ].reduce((int x, int y) => x > y ? x : y);
      diff.write('f$i:$d ');
    }
    debugPrint(diff.toString());
  });
}
