/// 画布性能审计 —— **逐分类统计「每帧要离屏合成」的层数量**，并输出清单。
///
/// ## 为什么要有这个工具（2026-09-25）
/// 用户实测「组件库有些动画掉帧」。定位性能问题不该靠猜：Flutter 里每帧真正的
/// 大头是**离屏合成**——`BackdropFilter`（玻璃卡，要采样 + 模糊背后内容）、
/// `ImageFiltered`（模糊层）、`Opacity`（半透明层）、`ShaderMask`（蒙版层）。
/// 它们各自都是一次 `saveLayer`：层数越多、面积越大，光栅线程越慢。
///
/// 本测试逐分类点选后统计**可见**（跳过 Offstage 保活分类）的层数，把清单打到
/// 测试输出里 —— 后续「哪个域最贵、该优化谁」以这份数字为准，不靠感觉。
///
/// 同时它也是回归锁：单个分类的离屏层数超过预算即失败（防止有人加了一屏玻璃卡）。
///
/// 跑法（Windows 侧）：
///   E:\flutter-3.47.4\bin\flutter.bat test test/perf_audit_test.dart
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';


import '../lib/preview/component_gallery.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';

/// 单个分类里允许出现的离屏层数上限（超了先看是不是新加了一屏玻璃卡）。
///
/// 2026-09-27 §8.17 实测基线（画布一次铺开该域全部样张，属**极端**场景而非真实单页）：
///
/// | 分类 | backdrop | imageFiltered | opacity | shaderMask | 合计 |
/// |---|---|---|---|---|---|
/// | 基元 · 材质 · 排版 | 14 | 0 | 10 | 1 | 25 |
/// | Shell · 导航壳与浮层 | 41 | 0 | 19 | 3 | 63 |
/// | chat · 气泡/列表/输入/面板 | 140 | 0 | 143 | 0 | **283** |
/// | live · 直播域 | 87 | 0 | 50 | 1 | 138 |
/// | voice · 语音域 | 57 | 0 | 41 | 2 | 100 |
/// | posts · 帖子/评论 | 26 | 0 | 21 | 0 | 47 |
/// | group · 群与目录 | 73 | 0 | 25 | 0 | 98 |
/// | boardgame · 桌游域 | 31 | 0 | 19 | 0 | 50 |
/// | profile · 个人主页域 | 20 | 0 | 7 | 0 | 27 |
/// | search · 搜索域 | 9 | 0 | 1 | 0 | 10 |
/// | motion · 转场与手势 | 9 | 0 | 8 | 0 | 17 |
/// | 通用件 · 分享/分页/弹层/资源 | 27 | 0 | 23 | 0 | 50 |
///
/// **本轮（§8.17）把 opacity 从 622 → 367（−255 层 / −41%）**；除「基元」外 backdrop
/// 逐分类**一个都没变**（默认档逐像素不变的直接证据）——「基元 +5 backdrop / +1 opacity」
/// 是本节新增的 `AylaGlassQuality` 三档切换样张自带的。做法是把「静态半透明」与
/// 「扫光带的 .5」从 `Opacity` widget 换成颜色/渐变的 alpha（无重叠 ⇒ 等价）。
///
/// 两类大头仍是 **backdrop（玻璃卡）与 opacity（半透明层）**：每个都是一次
/// «saveLayer»。imageFiltered 全 0 ⇒ 背景已经不是逐帧滤镜（烘焙管线生效）。
const int kMaxLayersPerCategory = 300;

/// 单个分类里允许出现的 `BackdropFilter` 数上限。
///
/// 玻璃卡是**每帧成本最高**的一类（要采样 + 高斯模糊背后内容，背景还在逐帧
/// 流动）⇒ 单独给它一条更紧的锁：谁在样张里塞一屏玻璃卡，这条先红。
/// 当前最贵 = chat 140。
const int kMaxBackdropPerCategory = 150;

/// ⚠️ 「滚动一屏后需要重绘的 RenderObject 数」这个指标**测不准，已废弃**（2026-09-25 实测）：
/// `debugNeedsPaint` 在 `SingleChildScrollView` 里反映的是「**未进入视口、因而没被绘制过**的
/// 节点数」（整列都会 layout、只有视口内的才 paint），与 `RepaintBoundary` 无关 ——
/// 加边界前后都是 4652。滚动隔离本身仍由 Flutter 机制保证（`RepaintBoundary` 让
/// `paintContext.paintChild` 只更新 layer offset、不重绘子树），画布每个分区都已加边界。

void main() {
  /// 真实宿主等价环境：MaterialApp 提供 Directionality/Material/Localizations。
  Widget host(Widget child) => MaterialApp(home: previewScope(child));

  void pinCanvas(WidgetTester tester) {
    tester.view.physicalSize = const Size(1800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  int countOf(Finder finder) => finder.evaluate().length;


  testWidgets('画布性能审计：逐分类统计离屏层数量（输出清单 + 预算回归锁）', (
    WidgetTester tester,
  ) async {
    pinCanvas(tester);
    await tester.pumpWidget(host(const ComponentGallery()));
    await tester.pump();

    final StringBuffer report = StringBuffer()
      ..writeln('分类 | backdrop | imageFiltered | opacity | shaderMask | 合计');
    int worst = 0;
    String worstLabel = '';

    for (final AylaGalleryCategory category in kGalleryCategories) {
      final String label = category.label;
      await tester.tap(find.text(label));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 320)); // 共享胶囊迁移 300ms

      // 默认 skipOffstage: true ⇒ 只统计**当前可见**分类，不含保活的其它分类。
      final int backdrop = countOf(find.byType(BackdropFilter));
      final int imageFiltered = countOf(find.byType(ImageFiltered));
      final int opacity = countOf(find.byType(Opacity));
      final int shaderMask = countOf(find.byType(ShaderMask));
      final int total = backdrop + imageFiltered + opacity + shaderMask;
      if (total > worst) {
        worst = total;
        worstLabel = label;
      }
      expect(
        backdrop,
        lessThanOrEqualTo(kMaxBackdropPerCategory),
        reason:
            '「$label」有 $backdrop 个 BackdropFilter（上限 $kMaxBackdropPerCategory）'
            '——玻璃卡每帧都要采样 + 模糊背后内容，先看是不是新加了一屏',
      );
      report.writeln(
        '$label | $backdrop | $imageFiltered | $opacity | $shaderMask | $total',
      );
    }
    debugPrint(report.toString());
    debugPrint('最贵的分类：$worstLabel（$worst 层）');
    expect(
      worst,
      lessThanOrEqualTo(kMaxLayersPerCategory),
      reason: '「$worstLabel」的离屏层数 $worst 超预算——先看是不是新加了一屏玻璃卡',
    );

    // 「基元 · 材质 · 排版」里有背景节：背景**必须**是 0 个逐帧滤镜
    // （烘焙纹理走 RawImage；见 aurora_background.dart 的性能口径）。
    expect(
      find.descendant(
        of: find.byType(ComponentGallery),
        matching: find.byType(ImageFiltered),
      ),
      findsNothing,
    );
  });

  testWidgets('预模糊档：画布全部分类 0 个 BackdropFilter（玻璃件全走质量档 owner）', (
    WidgetTester tester,
  ) async {
    pinCanvas(tester);
    AylaGlassConfig.quality = AylaGlassQuality.preblurred;
    addTearDown(() {
      AylaGlassConfig.quality = AylaGlassQuality.realBackdrop;
      AylaBackdropSnapshot.clear();
    });
    await tester.pumpWidget(host(const ComponentGallery()));
    await tester.pump();

    final List<String> leaks = <String>[];
    for (final AylaGalleryCategory category in kGalleryCategories) {
      await tester.tap(find.text(category.label));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 320));
      final int count = find.byType(BackdropFilter).evaluate().length;
      if (count > 0) leaks.add('${category.label} ×$count');
    }
    expect(leaks, isEmpty, reason: '预模糊档下仍装着 BackdropFilter 的分类：$leaks');
  });
}
