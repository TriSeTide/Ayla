/// 流体极光背景（`lib/theme/aurora_background.dart` + `aurora_baked_layer.dart`
/// + `aurora_turbulence.dart`）定向测试。
///
/// 覆盖五类：
/// 1. **结构**：静态兜底层常驻；四层流层只在 `animate` 且非 reduced-motion 时建；
///    `child` 在最上；`previewTheme` 宿主静态（无限动画会让 `pumpAndSettle` 永不 settle）。
/// 2. **性能不变量**（2026-09-25 事故后的回归锁）：背景每帧路径里**不得有
///    `ImageFiltered`/`BackdropFilter`**（逐帧滤镜会爆显存 —— 用户实测闪退），
///    且五层烘焙像素总量必须落在 [AylaFluidAurora.bakePixelBudget] 内。
/// 3. **关键尺寸**：150vmax 渐变层 / inset -25% 湍流层 / 40vw·80vw·70vw 光斑，
///    逐项与 `base.css` 的 `vw`、`inset`、`left/top` 百分比对账。
/// 4. **关键帧与时长**：CSS 关键帧逐帧取值、**逐段** `ease-in-out`、负延迟折算的相位、
///    宽/窄档时长（20s/15s/10s vs 28s/21s/10s）。
/// 5. **纹理**：feTurbulence 的 LUT 语义、确定性、取值域，以及「网格属于流层」
///    （reduced-motion 下必须一起消失）、farthest-corner 半径换算。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/aurora_background.dart';
import '../lib/theme/aurora_baked_layer.dart';
import '../lib/theme/aurora_turbulence.dart';
import '../lib/theme/preview_theme.dart';

void main() {
  Widget host(
    Widget child, {
    Size size = const Size(400, 300),
    bool disableAnimations = false,
  }) {
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          disableAnimations: disableAnimations,
        ),
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: size.width, height: size.height, child: child),
        ),
      ),
    );
  }

  /// ⚠️ 层内是**动画 Transform**（旋转/缩放）⇒ `getRect/getTopLeft` 会返回变换后的
  /// 轴对齐包围盒（实测 1200 被量成 1009.9），不是布局几何。
  /// 几何断言必须走：尺寸 = `getSize`（局部 size，不含祖先变换）；
  /// 位置 = 该层自己的 `Positioned`（left/top/width/height 就是 CSS 语义值）。
  Size layerSize(WidgetTester tester, Key key) =>
      tester.getSize(find.byKey(key));

  Positioned layerBox(WidgetTester tester, Key key) => tester.widget<Positioned>(
    find
        .descendant(of: find.byKey(key), matching: find.byType(Positioned))
        .first,
  );

  // ------------------------------------------------------------------
  // 1. 结构
  // ------------------------------------------------------------------

  testWidgets('静态兜底常驻；animate 时四层流层齐备、child 在最上', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(const AylaAuroraBackground(child: Text('content'))),
    );
    await tester.pump();

    expect(find.byKey(AylaAuroraKeys.staticLayer), findsOneWidget);
    for (final Key key in AylaAuroraKeys.flowLayers) {
      expect(find.byKey(key), findsOneWidget, reason: key.toString());
    }
    expect(find.text('content'), findsOneWidget);
  });

  testWidgets('animate: false ⇒ 只剩静态兜底（无流层、无网格）', (WidgetTester tester) async {
    await tester.pumpWidget(host(const AylaAuroraBackground(animate: false)));
    await tester.pump();
    expect(find.byKey(AylaAuroraKeys.staticLayer), findsOneWidget);
    for (final Key key in AylaAuroraKeys.flowLayers) {
      expect(find.byKey(key), findsNothing, reason: key.toString());
    }
  });

  testWidgets('prefers-reduced-motion ⇒ 四层隐藏（等价 animate: false）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(const AylaAuroraBackground(), disableAnimations: true),
    );
    await tester.pump();
    for (final Key key in AylaAuroraKeys.flowLayers) {
      expect(find.byKey(key), findsNothing, reason: key.toString());
    }
  });

  testWidgets('previewTheme 宿主是静态背景（pumpAndSettle 可 settle）', (WidgetTester tester) async {
    await tester.pumpWidget(previewTheme(const SizedBox(width: 10, height: 10)));
    // 无限循环动画会在这里超时失败 —— 本断言就是那条回归锁。
    await tester.pumpAndSettle();
    for (final Key key in AylaAuroraKeys.flowLayers) {
      expect(find.byKey(key), findsNothing);
    }
  });

  // ------------------------------------------------------------------
  // 2. 性能不变量
  // ------------------------------------------------------------------

  testWidgets('每帧路径无逐帧滤镜：背景子树里不得出现 ImageFiltered / BackdropFilter', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(const AylaAuroraBackground()));
    await tester.pump();
    // 五层都是烘焙纹理（RawImage），滤镜在**烘焙期**一次性施加。
    expect(find.byType(RawImage), findsNWidgets(5));
    expect(
      find.descendant(
        of: find.byType(AylaAuroraBackground),
        matching: find.byType(ImageFiltered),
      ),
      findsNothing,
      reason: '逐帧 ImageFiltered 会每帧重跑大层模糊 ⇒ 爆显存（2026-09-25 实测事故）',
    );
    expect(
      find.descendant(
        of: find.byType(AylaAuroraBackground),
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
    );
  });

  test('烘焙像素预算：1080p 与 4K 视口下都不超预算（低频层降采样）', () {
    for (final Size viewport in <Size>[const Size(1920, 1080), const Size(3840, 2160)]) {
      final int pixels = aylaAuroraBakePixels(viewport, 1.25);
      expect(
        pixels,
        lessThanOrEqualTo(AylaFluidAurora.bakePixelBudget),
        reason: '视口 $viewport 的烘焙总量 $pixels 像素超预算',
      );
      // 也不能退化成"没烘焙"（每层至少要有像素）
      expect(pixels, greaterThan(100 * 1000));
    }
    // 首版事故口径（150vmax 1:1 + 1.5×视口 1:1）在 1080p 下是 1300 万像素以上；
    // 2026-09-27 cap 上调后预算放宽到 10M（1080p 实测 ≈7.8M），仍远低于事故口径。
    expect(AylaFluidAurora.bakePixelBudget, lessThanOrEqualTo(10000000));
  });

  test('每层烘焙上限常量都受控（防止有人把 cap 改回 4096 级）', () {
    for (final double cap in <double>[
      AylaFluidAurora.bakeStaticMaxSide,
      AylaFluidAurora.bakeGradientMaxSide,
      AylaFluidAurora.bakeTurbulenceMaxSide,
      AylaFluidAurora.bakeBlobMaxSide,
    ]) {
      expect(cap, lessThanOrEqualTo(kMaxAuroraBakeSide));
      expect(cap, greaterThan(0));
    }
  });

  // ------------------------------------------------------------------
  // 3. 关键尺寸
  // ------------------------------------------------------------------

  testWidgets('宽屏：150vmax 渐变层居中 · inset -25% 湍流层 · 40vw 双光斑', (WidgetTester tester) async {
    // ⚠️ 视口必须 > 768：断点是 «max-width: 768px» ⇒ 窄屏档，光斑会变成 80vw/70vw
    //    （曾经用 400 宽的宿主，宽屏用例静默落进窄屏档，断言量到 320 而非 160）。
    const double w = 769;
    const double h = 300;
    await tester.pumpWidget(host(const AylaAuroraBackground(), size: const Size(w, h)));
    await tester.pump();

    // ② 渐变层：150vmax 正方形，中心 = 视口中心（base.css 61–65）；
    // 外框另加 2×overscan（模糊扩散预留 —— 不预留会露出硬直边）。
    const double side = 1.5 * w;
    const double gOver = AylaFluidAurora.gradientOverscan;
    expect(layerSize(tester, AylaAuroraKeys.gradient), Size(side + gOver * 2, side + gOver * 2));
    expect(
      layerBox(tester, AylaAuroraKeys.gradient).left,
      closeTo((w - side) / 2 - gOver, 1e-9),
    );
    expect(
      layerBox(tester, AylaAuroraKeys.gradient).top,
      closeTo((h - side) / 2 - gOver, 1e-9),
    );

    // ③ 湍流层：inset -25%（base.css:85）+ 同款 overscan
    const double tOver = AylaFluidAurora.turbulenceOverscan;
    expect(
      layerSize(tester, AylaAuroraKeys.turbulence),
      Size(side + tOver * 2, h * 1.5 + tOver * 2),
    );
    expect(layerBox(tester, AylaAuroraKeys.turbulence).left, -w * 0.25 - tOver);
    expect(layerBox(tester, AylaAuroraKeys.turbulence).top, -h * 0.25 - tOver);

    // ④ 冰蓝光斑：40vw · top -10% · left 25%（base.css 110–118）
    expect(layerSize(tester, AylaAuroraKeys.blobIce), const Size(w * 0.4, w * 0.4));
    expect(layerBox(tester, AylaAuroraKeys.blobIce).left, w * 0.25);
    expect(layerBox(tester, AylaAuroraKeys.blobIce).top, -h * 0.1);

    // ⑤ 亮粉光斑：40vw · bottom -10% · right 25%（base.css 120–128）
    expect(layerSize(tester, AylaAuroraKeys.blobSakura), const Size(w * 0.4, w * 0.4));
    expect(
      layerBox(tester, AylaAuroraKeys.blobSakura).left,
      closeTo(w * 0.75 - w * 0.4, 1e-9),
    );
    expect(
      layerBox(tester, AylaAuroraKeys.blobSakura).top,
      closeTo(h * 1.1 - w * 0.4, 1e-9),
    );
  });

  testWidgets('窄屏 ≤768：光斑 80vw / 70vw 上下分区且水平居中', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(const AylaAuroraBackground(), size: const Size(375, 240)),
    );
    await tester.pump();

    // 冰蓝 80vw · top 25% · left 50%（base.css 212–224）
    expect(layerSize(tester, AylaAuroraKeys.blobIce), const Size(300, 300));
    expect(layerBox(tester, AylaAuroraKeys.blobIce).left, 375 * 0.5 - 150);
    expect(layerBox(tester, AylaAuroraKeys.blobIce).top, 240 * 0.25);
    // 亮粉 70vw · bottom 25% · right 50%（base.css 225–237）
    expect(layerSize(tester, AylaAuroraKeys.blobSakura), const Size(262.5, 262.5));
    expect(layerBox(tester, AylaAuroraKeys.blobSakura).left, 375 * 0.5 - 262.5 / 2);
    expect(layerBox(tester, AylaAuroraKeys.blobSakura).top, 240 * 0.75 - 262.5);
  });

  testWidgets('窄屏：渐变层仍取视口最长边（150vmax）且居中', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(const AylaAuroraBackground(), size: const Size(375, 240)),
    );
    await tester.pump();
    const double over = AylaFluidAurora.gradientOverscan;
    expect(layerSize(tester, AylaAuroraKeys.gradient), Size(562.5 + over * 2, 562.5 + over * 2));
    expect(layerBox(tester, AylaAuroraKeys.gradient).left, (375 - 562.5) / 2 - over);
    expect(layerBox(tester, AylaAuroraKeys.gradient).top, (240 - 562.5) / 2 - over);
  });

  // ------------------------------------------------------------------
  // 4. 关键帧 / 时长 / 相位
  // ------------------------------------------------------------------

  test('关键帧逐帧取值与 web @keyframes 一致（base.css 131–208 / 287–303）', () {
    expect(aylaFluidPoseAt(AylaFluidAurora.gradientFrames, 0).rotateDeg, 0);
    expect(aylaFluidPoseAt(AylaFluidAurora.gradientFrames, 0).scale, 1);
    final AylaFluidPose g25 = aylaFluidPoseAt(AylaFluidAurora.gradientFrames, 0.25);
    expect(g25.rotateDeg, 115);
    expect(g25.dx, closeTo(0.04, 1e-9));
    expect(g25.dy, closeTo(-0.03, 1e-9));
    expect(g25.scale, closeTo(1.22, 1e-9));
    final AylaFluidPose g50 = aylaFluidPoseAt(AylaFluidAurora.gradientFrames, 0.5);
    expect(g50.rotateDeg, 220);
    expect(g50.scale, closeTo(0.78, 1e-9));
    final AylaFluidPose g75 = aylaFluidPoseAt(AylaFluidAurora.gradientFrames, 0.75);
    expect(g75.rotateDeg, 315);
    expect(g75.scale, closeTo(1.12, 1e-9));
    expect(aylaFluidPoseAt(AylaFluidAurora.gradientFrames, 1).rotateDeg, 360);

    final AylaFluidPose b15 = aylaFluidPoseAt(AylaFluidAurora.blobIceFrames, 0.15);
    expect(b15.scale, closeTo(1.35, 1e-9));
    expect(b15.dx, closeTo(0.2, 1e-9));
    expect(b15.dy, closeTo(-0.15, 1e-9));
    final AylaFluidPose b50 = aylaFluidPoseAt(AylaFluidAurora.blobIceFrames, 0.5);
    expect(b50.dx, closeTo(0.8, 1e-9));
    expect(b50.dy, closeTo(0.12, 1e-9));

    final AylaFluidPose t20 = aylaFluidPoseAt(AylaFluidAurora.turbulenceFrames, 0.2);
    expect(t20.rotateDeg, 16);
    expect(t20.dx, closeTo(0.08, 1e-9));
    expect(t20.dy, closeTo(-0.05, 1e-9));
    expect(t20.scale, 1);
    expect(aylaFluidPoseAt(AylaFluidAurora.turbulenceFrames, 0.8).rotateDeg, -18);

    expect(aylaFluidPoseAt(AylaFluidAurora.gradientFramesNarrow, 0.45).rotateDeg, 180);
    expect(
      aylaFluidPoseAt(AylaFluidAurora.gradientFramesNarrow, 0.45).scale,
      closeTo(0.94, 1e-9),
    );
    expect(aylaFluidPoseAt(AylaFluidAurora.gradientFramesNarrow, 0.2).dx, 0);
  });

  test('逐段 ease-in-out（CSS 的 timing function 对每个关键帧区间生效）', () {
    final double k = const Cubic(0.42, 0, 0.58, 1).transform(0.25);
    final AylaFluidPose pose = aylaFluidPoseAt(AylaFluidAurora.gradientFrames, 0.0625);
    expect(pose.rotateDeg, closeTo(115 * k, 1e-6));
    expect(pose.scale, closeTo(1 + 0.22 * k, 1e-6));
    expect(pose.rotateDeg, isNot(closeTo(28.75, 1e-3))); // 不是线性插值
  });

  test('端点外取端点值（t < 0 / t > 1 clamp）', () {
    expect(aylaFluidPoseAt(AylaFluidAurora.gradientFrames, -1).rotateDeg, 0);
    expect(aylaFluidPoseAt(AylaFluidAurora.gradientFrames, 2).rotateDeg, 360);
  });

  test('CSS 参数：时长 / 相位 / 模糊 / 透明度 / tile（tokens.css + base.css）', () {
    expect(AylaFluidAurora.gradientPeriod, const Duration(seconds: 20));
    expect(AylaFluidAurora.gradientPhase, closeTo(8 / 20, 1e-9));
    expect(AylaFluidAurora.gradientPeriodNarrow, const Duration(seconds: 28));
    expect(AylaFluidAurora.gradientPhaseNarrow, closeTo(8 / 28, 1e-9));
    expect(AylaFluidAurora.turbulencePeriod, const Duration(seconds: 15));
    expect(AylaFluidAurora.turbulencePhase, closeTo(5 / 15, 1e-9));
    expect(AylaFluidAurora.turbulencePeriodNarrow, const Duration(seconds: 21));
    expect(AylaFluidAurora.turbulencePhaseNarrow, closeTo(5 / 21, 1e-9));
    expect(AylaFluidAurora.blobPeriod, const Duration(seconds: 10));
    expect(AylaFluidAurora.blobBlur, 40);
    expect(AylaFluidAurora.turbulenceBlur, 60);
    expect(AylaFluidAurora.turbulenceOpacity, 0.08);
    expect(AylaFluidAurora.turbulenceTile, 480);
    expect(AylaFluidAurora.gradientBlur, 40);
    expect(AylaFluidAurora.gradientVmax, 150);
    expect(AylaFluidAurora.narrowBreakpoint, 768);
    expect(AylaFluidAurora.staticLayers.length, 9);
  });

  testWidgets('动画确实在跑：pump 1s 后渐变层变换矩阵改变', (WidgetTester tester) async {
    await tester.pumpWidget(host(const AylaAuroraBackground()));
    await tester.pump();
    final Finder gradientTransform = find.descendant(
      of: find.byKey(AylaAuroraKeys.gradient),
      matching: find.byType(Transform),
    );
    final Matrix4 before = tester.widget<Transform>(gradientTransform.first).transform;
    await tester.pump(const Duration(seconds: 1));
    final Matrix4 after = tester.widget<Transform>(gradientTransform.first).transform;
    expect(after, isNot(equals(before)));
  });

  test('三条时间轴的初始相位（CSS 负延迟）', () {
    // 相位 0.4 落在 25%→50% 段内的 60% 处（raw=0.6 ⇒ easeInOut≈0.671）
    // ⇒ 115 + (220 − 105… ) —— 精确值 185.04（**不是**线性换算的 144）
    final AylaFluidPose gradient = aylaFluidPoseAt(
      AylaFluidAurora.gradientFrames,
      AylaFluidAurora.gradientPhase,
    );
    expect(gradient.rotateDeg, closeTo(185.04, 0.01));
    final AylaFluidPose turbulence = aylaFluidPoseAt(
      AylaFluidAurora.turbulenceFrames,
      AylaFluidAurora.turbulencePhase,
    );
    expect(
      turbulence.rotateDeg,
      closeTo(aylaFluidPoseAt(AylaFluidAurora.turbulenceFrames, 1 / 3).rotateDeg, 1e-9),
    );
    expect(aylaFluidPoseAt(AylaFluidAurora.blobIceFrames, 0).scale, 1);
    expect(aylaFluidPoseAt(AylaFluidAurora.blobSakuraFrames, 0).scale, 1);
  });

  // ------------------------------------------------------------------
  // 5. 纹理与半径
  // ------------------------------------------------------------------

  test('烘焙模糊 σ 必须按 ratio 缩放（否则降采样会让视觉模糊翻倍）', () {
    // ImageFilter 作用在光栅化后的像素空间、不受 canvas 变换影响；烘焙图按 ratio 缩过，
    // 显示时又放回逻辑尺寸 ⇒ σ 不乘 ratio 就会被等比例放大。
    // 2026-09-27 实测：流层 ratio≈0.50 ⇒ 视觉 σ 80（web 是 40）⇒ 颜色摊平变白。
    expect(aylaBakedBlurSigma(40, 1.0), 40);
    expect(aylaBakedBlurSigma(40, 0.5), 20);
    expect(aylaBakedBlurSigma(60, 0.25), 15);
    expect(aylaBakedBlurSigma(0, 0.5), 0);
  });

  test('兜底底色是白（base.css：body/#root 都 transparent ⇒ 浏览器默认白底）', () {
    // 曾经的错：写成 --ice-100（冷灰）⇒ 整片偏灰偏暗。像素对账才暴露（见 13 号 §八）。
    expect(AylaFluidAurora.backdrop, const Color(0xFFFFFFFF));
    expect(AylaFluidAurora.backdrop.a, 1.0);
  });

  test('九层绘制顺序：CSS background 列表第一项在最上 ⇒ canvas 必须倒序画', () {
    final List<AylaAuroraRadialSpec> order = AylaFluidAurora.paintOrder;
    expect(order.length, 9);
    // 第一笔 = 列表最后一项（中心暖白光晕，最底层）；正序画会让它盖住四角四色 ⇒ 整片发白
    expect(order.first, same(AylaFluidAurora.staticLayers.last));
    expect(order.last, same(AylaFluidAurora.staticLayers.first));
  });

  test('模糊扩散预留：overscan = 3σ（内容居中、外框大一圈）', () {
    // 不预留 ⇒ saveLayer 把模糊扩散裁在 bounds 内 ⇒ 层边缘是**硬直边**
    //（2026-09-25 用户实报「背景总是出现裁切边旋转露出来」）。
    expect(AylaFluidAurora.gradientOverscan, AylaFluidAurora.gradientBlur * 3);
    expect(AylaFluidAurora.turbulenceOverscan, AylaFluidAurora.turbulenceBlur * 3);
    expect(AylaFluidAurora.gradientOverscan, greaterThan(0));
    expect(AylaFluidAurora.turbulenceOverscan, greaterThan(0));
    // 光斑层内容边缘本就透明（radial 70% 截止）⇒ 不需要预留，避免白花像素预算
  });

  test('farthest-corner 半径：正方形四角 √2 / 中心 √2÷2 / 非正方形按短边归一', () {
    const Size square = Size(300, 300);
    expect(
      aylaFarthestCornerRadius(square, Alignment.topLeft),
      closeTo(math.sqrt2, 1e-9),
    );
    expect(
      aylaFarthestCornerRadius(square, Alignment.center),
      closeTo(math.sqrt2 / 2, 1e-9),
    );
    const Size wide = Size(400, 200);
    expect(
      aylaFarthestCornerRadius(wide, Alignment.center),
      closeTo(math.sqrt(200 * 200 + 100 * 100) / 200, 1e-9),
    );
  });

  test('feComponentTransfer table → 256 项 LUT（Blink 语义：量化 + 折线 + 截断）', () {
    final Int32List lut = AylaTurbulenceSpec.lut(AylaTurbulenceSpec.aTable);
    expect(lut.length, 256);
    // v=0 → 首项 0.35；v=1 → 末项 0.35；v=0.5 → 中间项 0（V 形）
    expect(lut[0], (255 * 0.35).floor());
    expect(lut[255], (255 * 0.35).floor());
    expect(lut[128], 0);
    // 折线（不是阶梯）：邻近索引必须单调下降
    expect(lut[64], greaterThan(lut[128]));
    final Int32List lutR = AylaTurbulenceSpec.lut(AylaTurbulenceSpec.rTable);
    expect(lutR[0], (255 * 0.741).floor());
    expect(lutR[255], (255 * 0.976).floor());
  });

  test('feTurbulence 纹理：480×480 RGBA、确定性、Chrome 实测口径的统计量', () {
    final Uint8List pixels = AylaTurbulenceTile.pixels();
    expect(pixels.length, 480 * 480 * 4);
    expect(identical(pixels, AylaTurbulenceTile.pixels()), isTrue);

    // 确定性：同 seed 必得同一张表 / 同一噪声值（全图复算太慢，取表 + 采样点）。
    final AylaTurbulenceTables t1 = AylaTurbulenceTables(AylaTurbulenceSpec.seed);
    final AylaTurbulenceTables t2 = AylaTurbulenceTables(AylaTurbulenceSpec.seed);
    expect(listEquals(t1.lattice, t2.lattice), isTrue);
    expect(t1.noise2(0, 1.234, 5.678), t2.noise2(0, 1.234, 5.678));
    expect(t1.noise2(3, 40.5, 12.25).isFinite, isTrue);

    int minA = 255;
    int maxA = 0;
    int sumA = 0;
    int count = 0;
    int nonZeroRgbAtZeroAlpha = 0;
    for (int i = 0; i < pixels.length; i += 4) {
      final int a = pixels[i + 3];
      minA = a < minA ? a : minA;
      maxA = a > maxA ? a : maxA;
      sumA += a;
      count++;
      if (a == 0 && (pixels[i] != 0 || pixels[i + 1] != 0 || pixels[i + 2] != 0)) {
        nonZeroRgbAtZeroAlpha++;
      }
    }
    final double meanA = sumA / count;
    debugPrint('feTurbulence 统计：mean=$meanA max=$maxA min=$minA');

    // LUT 上界 0.35（89/255）；Chrome 实测 max ≈ 73、mean ≈ 17.07
    expect(maxA, lessThanOrEqualTo((0.35 * 255).round()));
    expect(maxA, greaterThan(40));
    expect(meanA, closeTo(17.07, 3));
    expect(minA, 0);
    // alpha=0 的像素不残留 RGB（预乘存储语义）
    expect(nonZeroRgbAtZeroAlpha, 0);
  });
}
