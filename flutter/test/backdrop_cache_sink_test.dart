/// 背底层纹理缓存**下沉到 `AylaGlassBackdrop`** 的回归锁（2026-10-17，性能 P0）。
///
/// ## 锁的是什么
/// 改前：缓存 `_AylaBackdropCache` 只接在 `AylaGlassSurface` 内部 ⇒ **直接调用
/// `AylaGlassBackdrop` 的 15 处玻璃件全部落空**。最贵的是「别人的消息气泡」
/// （`lib/widgets/chat/message_bubble.dart:908`，`blur(12)`）：面积 425×43 ≈ 18275，
/// 恰好低于旧阈值 20000 ⇒ **每条别人的消息都是一个每帧实时高斯模糊**。
/// 实测（`test/backdrop_cache_sink_test.dart` 的口径见 `probe_real_bubbles_test.dart`）：
/// 20 条消息列表 = 8 个在屏「活」backdrop，改后 = **0 活 / 8 冻**，raster 45.8→21.1 ms（−54%）。
///
/// 改后：缓存由 [AylaGlassBackdrop] 自身按**本件实际面积**决定，与谁调用无关。
/// 本文件锁 6 件事（正常 / 失败 / 未注入 三条路径都覆盖）：
/// 1. **正常路径**：大件（≥ [kAylaBackdropCacheMinArea]）冻结；小件不冻结；
/// 2. **失败/降级路径**：总开关关闭 ⇒ 完全不装快照（= 改前行为，零观感差异）；
/// 3. **未注入路径**：无 `entryController`（不在入场中）⇒ 缓存自建 controller 照常冻结，
///    不得抛异常、不得退化成不冻结；
/// 4. **不得双层**：`AylaGlassSurface` 内部恰好 **1** 个 `SnapshotWidget`
///    （双层 `SnapshotWidget` 会互相打架，这是下沉时最容易引入的回归）；
/// 5. **入会 controller 透传**：入场期下发的 controller 必须被缓存用上；
/// 6. **默认视觉不变**：冻结纹理与实时模糊的卡内色差在既有容差内（≤6/255）。
///
/// 跑法：`flutter test test/backdrop_cache_sink_test.dart --concurrency 1`
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/app_theme.dart';
import '../lib/theme/aurora_background.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/reveal.dart' show AylaRevealItem;

void main() {
  final GlobalKey rootKey = GlobalKey();

  Widget host(Widget child) => MaterialApp(home: previewScope(child));

  /// 真实宿主形态：极光背景 + 定位一块玻璃（与生产一致）。
  Widget scene(Widget child, {Size size = const Size(800, 600)}) => RepaintBoundary(
        key: rootKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAylaTheme(),
          home: AylaAuroraBackground(
            animate: false,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: SizedBox(
                width: size.width,
                height: size.height,
                child: Stack(
                  children: <Widget>[Positioned(left: 40, top: 40, child: child)],
                ),
              ),
            ),
          ),
        ),
      );

  /// 像素采样专用宿主：**全幅**铺背景色 + 卡（不做 Positioned 包一层，
  /// 否则 ColoredBox 拿不到 tight 约束、采样区域会落在空白处）。
  Widget pixelScene(Widget child) => RepaintBoundary(
        key: rootKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAylaTheme(),
          home: AylaAuroraBackground(
            animate: false,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: child,
            ),
          ),
        ),
      );

  /// **直接**使用 [AylaGlassBackdrop]（模拟 message_bubble / buttons / dialogs 的调用方式）。
  Widget bareBackdrop({double w = 425, double h = 43, double sigma = 12}) => SizedBox(
        width: w,
        height: h,
        child: AylaGlassBackdrop(
          radius: BorderRadius.circular(18),
          filter: AylaGlassConfig.blurOnly(sigma: sigma),
        ),
      );

  Widget surface({double w = 360, double h = 300}) => AylaGlassSurface(
        child: SizedBox(width: w, height: h, child: const Text('卡片')),
      );

  void pin(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  setUp(() => AylaGlassConfig.backdropCacheEnabled = true);
  tearDown(() {
    AylaGlassConfig.backdropCacheEnabled = true;
    AylaBackdropSnapshot.clear();
  });

  group('① 正常路径：按本件面积决定是否冻结', () {
    testWidgets('直接调用的 AylaGlassBackdrop（425×43 气泡尺寸）⇒ 冻结', (
      WidgetTester tester,
    ) async {
      pin(tester);
      await tester.pumpWidget(scene(bareBackdrop()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byType(SnapshotWidget),
        findsOneWidget,
        reason: '气泡 425×43 ≈ 18275 > 阈值 4000 ⇒ 必须冻结（改前这里一个都没有）',
      );
    });

    testWidgets('小件（36×36 = 1296 < 4000）⇒ 不冻结', (WidgetTester tester) async {
      pin(tester);
      await tester.pumpWidget(scene(bareBackdrop(w: 36, h: 36, sigma: 8)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byType(SnapshotWidget),
        findsNothing,
        reason: '按钮类小件数量极多（一屏 8–15 个），每次捕获都是同步离屏渲染 ⇒ 不加',
      );
    });

    testWidgets('阈值边界：略大于阈值冻结、略小于不冻', (WidgetTester tester) async {
      pin(tester);
      // 64×64 = 4096 ≥ 4000
      await tester.pumpWidget(scene(bareBackdrop(w: 64, h: 64)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(SnapshotWidget), findsOneWidget, reason: '64×64=4096 ≥ 4000');

      // 60×60 = 3600 < 4000
      await tester.pumpWidget(scene(bareBackdrop(w: 60, h: 60)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(SnapshotWidget), findsNothing, reason: '60×60=3600 < 4000');
    });

    test('阈值必须是 4000（性能 P0 的显式裁决，改它要先改本锁与文档）', () {
      expect(kAylaBackdropCacheMinArea, 4000);
    });
  });

  group('② 失败/降级路径：总开关关闭 = 改前行为', () {
    testWidgets('backdropCacheEnabled=false ⇒ 直接调用的大件也不冻结', (
      WidgetTester tester,
    ) async {
      pin(tester);
      AylaGlassConfig.backdropCacheEnabled = false;
      addTearDown(() => AylaGlassConfig.backdropCacheEnabled = true);

      await tester.pumpWidget(scene(bareBackdrop()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byType(SnapshotWidget),
        findsNothing,
        reason: '总开关关闭必须完全回到「每帧实时模糊」的改前行为（一键止血）',
      );
      // 但滤镜本身必须还在（不能连玻璃一起丢掉）。
      expect(find.byType(BackdropFilter), findsWidgets);
    });
  });

  group('③ 未注入路径：无 entryController（不在入场中）', () {
    testWidgets('无入场上下文 ⇒ 自建 controller 照常冻结、不抛异常', (
      WidgetTester tester,
    ) async {
      pin(tester);
      await tester.pumpWidget(scene(bareBackdrop()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(
        find.byType(SnapshotWidget),
        findsOneWidget,
        reason: '不依赖 AylaRevealItem：绝大多数调用点（气泡/按钮/输入框）本来就没有入场上下文',
      );
    });

    testWidgets('挂了 entryController 的大件 ⇒ 冻结且 controller 被用上（不是自建）', (
      WidgetTester tester,
    ) async {
      pin(tester);
      await tester.pumpWidget(
        host(
          Center(
            child: AylaRevealItem(
              fadeGlass: false,
              delay: Duration.zero,
              child: surface(),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byType(SnapshotWidget),
        findsOneWidget,
        reason: '入场期由 AylaRevealItem 下发 controller（错峰捕获在那边），必须被缓存用上',
      );
      await tester.pump(const Duration(milliseconds: 320));
      // 入场结束后**继续用同一个 controller**（纹理延续 ⇒ 无解冻帧峰值）。
      expect(
        find.byType(SnapshotWidget),
        findsOneWidget,
        reason: '零成本交接：入场结束后不得解冻',
      );
    });
  });

  group('④ 不得双层：AylaGlassSurface 内部恰好 1 个 SnapshotWidget', () {
    testWidgets('大卡 ⇒ 1 个（改前是 1 个，下沉后不得变成 2 个）', (
      WidgetTester tester,
    ) async {
      pin(tester);
      await tester.pumpWidget(scene(surface()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byType(SnapshotWidget),
        findsOneWidget,
        reason: '缓存已下沉进 AylaGlassBackdrop；AylaGlassSurface 若仍自己包一层就是双层捕获',
      );
      // 镜头层结构锁：真玻璃档仍恰好一个 BackdropFilter（缓存不新增滤镜层）。
      expect(
        find.descendant(
          of: find.byType(AylaGlassSurface),
          matching: find.byType(BackdropFilter),
        ),
        findsOneWidget,
      );
    });

    testWidgets('小卡（< 阈值）⇒ 0 个 SnapshotWidget（回归：不得因下沉而误判）', (
      WidgetTester tester,
    ) async {
      pin(tester);
      await tester.pumpWidget(scene(surface(w: 100, h: 30)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(SnapshotWidget), findsNothing);
    });
  });

  group('⑤ 默认视觉不变：冻结 vs 实时的卡内色差', () {
    Future<Uint8List> shot(WidgetTester tester, Widget child) async {
      await tester.pumpWidget(pixelScene(child));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      final RenderRepaintBoundary boundary =
          rootKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      return (await tester.runAsync(() async {
        final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
        final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        image.dispose();
        return data!.buffer.asUint8List();
      }))!;
    }

    /// 卡中心 40×40 区域平均 RGB（卡在 40,40，425×43 ⇒ 中心约 252,61）。
    List<double> center(Uint8List bytes, {int w = 800, int cx = 252, int cy = 61}) {
      double r = 0, g = 0, b = 0;
      int n = 0;
      for (int dy = -18; dy < 18; dy += 1) {
        for (int dx = -18; dx < 18; dx += 1) {
          final int i = (cy + dy) * w * 4 + (cx + dx) * 4;
          r += bytes[i];
          g += bytes[i + 1];
          b += bytes[i + 2];
          n += 1;
        }
      }
      return <double>[r / n, g / n, b / n];
    }

    double maxDelta(List<double> a, List<double> b) => <double>[
          (a[0] - b[0]).abs(),
          (a[1] - b[1]).abs(),
          (a[2] - b[2]).abs(),
        ].reduce((double x, double y) => x > y ? x : y);

    testWidgets('冻结纹理保留 backdrop（红/蓝背景判别 + 色差容差）', (WidgetTester tester) async {
      pin(tester);

      Future<List<double>> at(Color bg, {required bool cache}) async {
        AylaGlassConfig.backdropCacheEnabled = cache;
        final Uint8List bytes = await shot(
          tester,
          Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Positioned.fill(child: ColoredBox(color: bg)),
              Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 40, top: 40),
                  child: bareBackdrop(),
                ),
              ),
            ],
          ),
        );
        return center(bytes);
      }

      addTearDown(() => AylaGlassConfig.backdropCacheEnabled = true);

      // 判别力：红底 vs 蓝底必须显著不同 —— 否则说明 backdrop 退化成白板。
      final List<double> liveRed = await at(const Color(0xFFFF0000), cache: false);
      final List<double> liveBlue = await at(const Color(0xFF0000FF), cache: false);
      final List<double> frozenRed = await at(const Color(0xFFFF0000), cache: true);
      final List<double> frozenBlue = await at(const Color(0xFF0000FF), cache: true);

      expect(
        maxDelta(liveRed, liveBlue),
        greaterThan(40),
        reason: '实时档必须真的采样了背景（红蓝差应很大）—— 这是判别力的前提',
      );
      expect(
        maxDelta(frozenRed, frozenBlue),
        greaterThan(40),
        reason: '冻结档同样必须保留 backdrop（diff ≤40 就说明冻结成了白板）',
      );
      // 同一背景下 冻结 vs 实时：色差在既有容差内（reveal_snapshot_motion_test 用 6.0）。
      expect(
        maxDelta(liveRed, frozenRed),
        lessThanOrEqualTo(6.0),
        reason: '冻结纹理与实时模糊的卡内色差必须 ≤6/255（默认视觉不变）',
      );
    });
  });
}