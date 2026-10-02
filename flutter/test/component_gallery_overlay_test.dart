/// 组件画布「打开即刷异常」的回归锁（2026-10-02 用户实报）。
///
/// ## 实锤现场
/// 用户 \`flutter run\` 打开组件库，控制台 2728 行日志里
/// \`No Overlay widget found\` **数百条**（主导），
/// \`Another exception was thrown\` 合计 1051 条。
///
/// ## 根因 A（装配位形，不是件本身）
/// 画布由 \`main.dart:200–204\` 挂在 \`MaterialApp.builder\` 返回的 \`Stack\` 里，
/// 与 \`child\`（= Navigator）**同级**：
/// - 应用侧一切正常 —— Navigator 自带 \`Overlay\`，所有页面都在它之下；
/// - 画布是 Navigator 的**兄弟** ⇒ 祖先链里有 Scaffold / Material / Localizations，
///   唯独**没有任何 Overlay**。
///
/// 首发栈（框架 \`widgets/debug.dart:525–553\` 的 \`debugCheckHasOverlay\`）：
/// \`\`\`
/// RawTooltipState.build (widgets/raw_tooltip.dart:865)
///   ↑ lib/widgets/base/tooltip.dart:91   ← AylaTooltip 的 Material Tooltip
/// \`\`\`
/// \`AylaTooltip\` 是 2026-09-25 引入的新件（画布 \`component_gallery.dart:650/662/674\` 三处样张），
/// 且其分区属**默认分类**（\`kGalleryCategories[0]\` 的 base 组，前缀 \`AylaTooltip\`）
/// ⇒ **一打开画布即命中**；每个 Tooltip 在 build 期都抛一次 ⇒ 一次打开上百条。
/// 同日 \`cce223b\` 给 Tooltip 套 \`Semantics(container: true)\` 只修了**语义树**断言，
/// 与 Overlay 无关。
///
/// > 画布历史上能用，正因为当时的样张里没有引入 Overlay 依赖的件
/// > （\`Overlay.of\` / Material \`Tooltip\` / \`OverlayPortal\` 都会要求祖先）。
///
/// ## 修复
/// 画布根补一层 \`Overlay\`（\`component_gallery.dart\` 的 \`_GalleryHost\`）：
/// 画布是自成一体的预览宿主，不应依赖兄弟 Navigator 的 Overlay；
/// 补在画布**内部**同时让画布内件插入的浮层跟随画布裁剪，不外溢到应用界面。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/preview/component_gallery.dart';
import '../lib/widgets/base/tooltip.dart' show AylaTooltip;

/// 复刻 \`main.dart\` 的真实位形：画布与 Navigator（\`child\`）是 Stack 的兄弟。
///
/// 关键点：\`Overlay\` 只由 Navigator 创建，而 Navigator 在 \`child\` 里 ——
/// 画布拿不到它。这正是 \`No Overlay widget found\` 的位形。
Widget appLikeHost(Widget gallery) {
  return MaterialApp(
    // 与 main.dart 一致：Scaffold 在 builder 里（画布落在 Scaffold body 内）
    builder: (BuildContext context, Widget? child) => Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[child ?? const SizedBox.shrink(), gallery],
      ),
    ),
    home: const SizedBox.shrink(),
  );
}

void pinCanvas(WidgetTester tester) {
  tester.view.physicalSize = const Size(1800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 计数守卫：在 [body] 执行期间收集 FlutterError 的异常首行，返回各种类的条数。
///
/// 用于「修复前后条数」的量化（用户现场：\`No Overlay widget found\` 数百条）。
Future<Map<String, int>> countErrors(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  final List<String> messages = <String>[];
  final FlutterExceptionHandler? prev = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    messages.add(details.exceptionAsString());
  };
  try {
    await body();
  } finally {
    FlutterError.onError = prev;
  }
  tester.takeException(); // 清掉测试框架自己攒的那一份
  final Map<String, int> counts = <String, int>{};
  for (final String m in messages) {
    final String kind = m.split('\n').first;
    counts[kind] = (counts[kind] ?? 0) + 1;
  }
  return counts;
}

void main() {
  testWidgets('画布真实位形（Navigator 兄弟）：打开不抛 No Overlay widget found', (
    WidgetTester tester,
  ) async {
    pinCanvas(tester);
    await tester.pumpWidget(appLikeHost(const ComponentGallery()));
    await tester.pump();

    // 画布确实建出来了（不是被异常吞掉）
    expect(find.text(kGalleryCategories.first.label), findsOneWidget);

    // 修复前：AylaTooltip 分区里 3 个 Tooltip 各抛一次
    // "No Overlay widget found. RawTooltip-[LabeledGlobalKey<RawTooltipState>] ..."
    expect(
      tester.takeException(),
      isNull,
      reason: '画布必须自带 Overlay 祖先（Tooltip / OverlayPortal / Overlay.of 全部依赖它）',
    );
  });

  testWidgets('画布根必须提供 Overlay 祖先（不依赖兄弟 Navigator）', (
    WidgetTester tester,
  ) async {
    pinCanvas(tester);
    await tester.pumpWidget(appLikeHost(const ComponentGallery()));
    await tester.pump();

    // 画布样张里的 AylaTooltip 是真实存在的（分区：AylaTooltip（web `title=` 28 处…））
    expect(find.byType(AylaTooltip), findsWidgets);

    // 从画布里任一 Tooltip 的 context 向上找 Overlay 必须**找得到**
    final BuildContext context = tester.element(find.byType(AylaTooltip).first);
    expect(
      Overlay.maybeOf(context),
      isNotNull,
      reason: '画布自身必须提供 Overlay（Navigator 是它的兄弟，够不到）',
    );
  });

  testWidgets('画布逐分类遍历：每一类渲染都不抛异常', (WidgetTester tester) async {
    pinCanvas(tester);
    await tester.pumpWidget(appLikeHost(const ComponentGallery()));
    await tester.pump();

    for (final AylaGalleryCategory category in kGalleryCategories) {
      await tester.tap(find.text(category.label));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 320)); // 共享胶囊迁移 300ms
      expect(
        tester.takeException(),
        isNull,
        reason: '分类「${category.label}」渲染必须零异常',
      );
    }

    // 兜底类（映射遗漏）
    await tester.tap(find.text('未分类（映射遗漏）'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));
    expect(tester.takeException(), isNull);
  });

  testWidgets('画布内件真的能用 Overlay：AylaServerRail 悬停面板在建出来的画布里可见', (
    WidgetTester tester,
  ) async {
    pinCanvas(tester);
    await tester.pumpWidget(appLikeHost(const ComponentGallery()));
    await tester.pump();
    tester.takeException();

    // 切到 Shell 分类（ServerRail 样张在「Shell · 导航壳与浮层」）
    await tester.tap(find.text('Shell · 导航壳与浮层'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320)); // 共享胶囊迁移 300ms
    await tester.pump(const Duration(milliseconds: 320));

    // AylaServerRail 的悬停置顶面板走 `Overlay.of(context).insert`（server_rail.dart:834–837），
    // 画布的 Shell 分区第二个 rail 用 `hovered: 'g3'` 静态注入 ⇒ 一挂载就插 entry。
    // 「g3 = 爱莉的客厅」未置顶 ⇒ 面板文案是「置顶」。
    expect(
      find.text('置顶'),
      findsWidgets,
      reason: '画布自带 Overlay ⇒ rail 的 pop entry 真的插得进、画得出（修复前这条也红）',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('量化：No Overlay widget found 条数 = 0（修复前每条样张 4 条）', (
    WidgetTester tester,
  ) async {
    pinCanvas(tester);

    // ⚠️ 必须在 pumpWidget **之内**开始计数：异常发生在首帧 build。
    final Map<String, int> counts = <String, int>{};
    final List<String> messages = <String>[];
    final FlutterExceptionHandler? prev = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      messages.add(details.exceptionAsString());
    };
    await tester.pumpWidget(appLikeHost(const ComponentGallery()));
    await tester.pump();
    FlutterError.onError = prev;
    tester.takeException();
    for (final String m in messages) {
      final String kind = m.split('\n').first;
      counts[kind] = (counts[kind] ?? 0) + 1;
    }

    // 修复前实测：4 条 `No Overlay widget found.`（画布默认分类 base 组的 4 个 Tooltip：
    // 3 个样张 + 分区里其它件各一处），叠加 `Another exception was thrown` 转述。
    // 现场 2728 行日志里它是**主导**异常（用户原话「组件库打开会这样子报错」）。
    expect(
      counts['No Overlay widget found.'] ?? 0,
      0,
      reason: '画布自带 Overlay ⇒ 不应再有任何一条（修复前 4）',
    );
    expect(
      counts.keys.where((String k) => k.contains('Overlay')).toList(),
      isEmpty,
      reason: '任何形态的 Overlay 缺失（含 within LookupBoundary 变体）都必须是 0',
    );
  });
}
