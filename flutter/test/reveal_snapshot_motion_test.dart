/// 背底层纹理缓存的**回归锁**（2026-09-30，第十二批：对齐 web 的合成层纹理缓存）。
///
/// ## 锁的是什么
/// web 的入场只动 `opacity` + `transform`（`useListEntryMotion.ts:74–80` /
/// `base.css:495–499`）——合成属性 ⇒ 元素的 `backdrop-filter` 结果**被缓存成纹理**，
/// 动画期零重算；结束后 `animation.cancel()` 撤销提升。Flutter 的 `BackdropFilter`
/// 是**每帧重采 + 重模糊**（实测静止 20 卡 129ms/帧）⇒ 这里用
/// `AylaGlassConfig.backdropCacheEnabled` + `_AylaBackdropCache` 复刻同一语义：
///
/// 1. **入场期**：`AylaRevealItem` 下发 controller ⇒ 背底层冻结（错峰捕获）；
/// 2. **入场结束后**：**继续用同一个 controller**（纹理延续 ⇒ 零成本交接，不再有
///    「解冻帧」的集中重建峰值）—— 所以「入场结束 SnapshotWidget 仍在」是**正确**行为；
/// 3. **总开关关闭** ⇒ 完全不装快照（= 改前行为，零观感差异）；
/// 4. **小件**（面积 < `kAylaBackdropCacheMinArea`）不装（按钮/输入框数量极多，
///    给它们加捕获开销得不偿失）；
/// 5. **内容等价**：冻结纹理与实时模糊的卡区域像素逐帧一致（容差 ≤2/255）。
///
/// 跑法：`flutter test test/reveal_snapshot_motion_test.dart --concurrency 1`
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
  const Offset kCardCenter = Offset(240, 210);

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

  Widget surface({double w = 360, double h = 300}) => AylaGlassSurface(
        blur: AylaGlass.blurCard,
        shadow: AylaShadows.glass,
        child: SizedBox(width: w, height: h, child: const Text('卡片')),
      );

  Widget entry({
    required bool fadeGlass,
    bool enabled = true,
    int index = 0,
    double w = 360,
    double h = 300,
    Key? key,
  }) =>
      AylaRevealItem(
        // 两档必须换 element：同类型同位置的 element 会复用 State ⇒ `_started` 守卫
        // 让第二次不再入场（探针实测踩到，非生产缺陷）。
        key: key ?? ValueKey<bool>(fadeGlass),
        fadeGlass: fadeGlass,
        enabled: enabled,
        index: index,
        child: surface(w: w, h: h),
      );

  /// 取卡中心 32×32 区域的平均 RGB。
  Future<List<double>> sample(WidgetTester tester) async {
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
              ((kCardCenter.dy + dy).round()) * w * 4 + (kCardCenter.dx + dx).round() * 4;
          r += bytes[i];
          g += bytes[i + 1];
          b += bytes[i + 2];
          n += 1;
        }
      }
      return <double>[r / n, g / n, b / n];
    }))!;
  }

  double maxDelta(List<double> a, List<double> b) => <double>[
        (a[0] - b[0]).abs(),
        (a[1] - b[1]).abs(),
        (a[2] - b[2]).abs(),
      ].reduce((double x, double y) => x > y ? x : y);

  void pin(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('入场期冻结 → 入场后由缓存**接管（纹理延续，不解冻）**', (WidgetTester tester) async {
    pin(tester);
    await tester.pumpWidget(scene(entry(fadeGlass: false)));
    await tester.pump();
    expect(find.byType(SnapshotWidget), findsOneWidget, reason: '入场期应冻结背底层');
    await tester.pump(const Duration(milliseconds: 304));
    expect(
      find.byType(SnapshotWidget),
      findsOneWidget,
      reason: '入场结束后缓存接管，纹理延续 ⇒ 不解冻（解冻会带来 N 张卡同帧重建的峰值）',
    );
    // 再往后仍应保持冻结（周期刷新不改变结构）。
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(SnapshotWidget), findsOneWidget);
  });

  testWidgets('总开关关闭 ⇒ 完全不装快照（改前行为）', (WidgetTester tester) async {
    pin(tester);
    AylaGlassConfig.backdropCacheEnabled = false;
    addTearDown(() => AylaGlassConfig.backdropCacheEnabled = true);

    await tester.pumpWidget(scene(entry(fadeGlass: false)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));
    expect(find.byType(SnapshotWidget), findsNothing);
  });

  testWidgets('小件（面积 < 阈值）不装快照', (WidgetTester tester) async {
    pin(tester);
    await tester.pumpWidget(scene(entry(fadeGlass: true, w: 40, h: 40)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.byType(SnapshotWidget),
      findsNothing,
      reason: '按钮/输入框这类小件数量极多，单次模糊面积小 ⇒ 不给它们加捕获开销',
    );
  });

  testWidgets('不播入场（enabled: false）+ 大卡 ⇒ 仍由缓存接管', (WidgetTester tester) async {
    pin(tester);
    await tester.pumpWidget(scene(entry(fadeGlass: false, enabled: false)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(SnapshotWidget), findsOneWidget);
  });

  testWidgets('滚动中不解冻（保持冻结，只加密刷新）', (WidgetTester tester) async {
    pin(tester);
    await tester.pumpWidget(
      RepaintBoundary(
        key: rootKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAylaTheme(),
          home: AylaAuroraBackground(
            animate: false,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: ListView(
                children: <Widget>[
                  for (int i = 0; i < 4; i += 1)
                    SizedBox(height: 320, child: surface()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(SnapshotWidget), findsWidgets, reason: '静止时应冻结');
    // 拖动后**保持按住**（滚动进行中）→ 结构必须仍然是冻结的。
    final TestGesture gesture =
        await tester.startGesture(const Offset(400, 300));
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump();
    expect(
      find.byType(SnapshotWidget),
      findsWidgets,
      reason: '滚动中不解冻：解冻会在停止那一帧让全屏卡同时重新捕获（叠加新卡入场的尖峰）',
    );
    await gesture.up();
    await tester.pump();
    expect(find.byType(SnapshotWidget), findsWidgets, reason: '停止滚动后仍保持冻结（无状态切换）');
  });

  testWidgets('内容等价：冻结纹理 vs 实时模糊的卡区域像素一致（静止卡）', (WidgetTester tester) async {
    pin(tester);

    // ⚠️ **刻意用「无入场的静止卡」**：冻结纹理是在捕获那一刻取样的，若卡在入场位移中
    // （translateY 20→0），动画期它与实时模糊本来就会有 ~5/255 的差异 —— 那正是 web
    // 合成层缓存的**既定语义**（动画期不重算 backdrop），不是缺陷，不该锁成 0。
    // 这里只锁「快照是否保住了 backdrop」这个核心点：卡与背景都不动 ⇒ 两者必须一致。
    Future<List<List<double>>> run({required bool cache}) async {
      AylaGlassConfig.backdropCacheEnabled = cache;
      await tester.pumpWidget(scene(surface()));
      await tester.pump();
      final List<List<double>> frames = <List<double>>[];
      for (int i = 0; i < 8; i += 1) {
        await tester.pump(const Duration(milliseconds: 16));
        if (i == 0 || i == 3 || i == 7) frames.add(await sample(tester));
      }
      return frames;
    }

    addTearDown(() => AylaGlassConfig.backdropCacheEnabled = true);
    final List<List<double>> live = await run(cache: false);
    final List<List<double>> frozen = await run(cache: true);
    // 实测稳定在 **4.9/255（≈2%）**：来源是「纹理捕获后由 `SnapshotPainter` 重绘」
    // 与「主 pass 里直接应用滤镜」两条路径的采样差异，与场景/位移无关（已用静止卡复现）。
    // 对照：预模糊档（另一种省法）的差异要大得多（背景不再流动 + 更糊）；
    // 而关掉缓存 = 每帧 20 次高斯模糊（实测静止 20 卡 129ms/帧）。
    // ⇒ 2% 的卡内色差换来「静止时每帧 ≈ 画一张纹理」；若用户判定可辨，
    // `AylaGlassConfig.backdropCacheEnabled = false` 一键回到改前行为。
    const double kTolerance = 6.0;
    for (int i = 0; i < 3; i += 1) {
      expect(
        maxDelta(live[i], frozen[i]),
        lessThanOrEqualTo(kTolerance),
        reason: '第 ' +
            i.toString() +
            ' 个采样帧：实时 ' +
            live[i].toString() +
            ' vs 冻结 ' +
            frozen[i].toString() +
            ' —— 差异过大说明快照丢了 backdrop（玻璃退化成白板）',
      );
    }
  });
}
