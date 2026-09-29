/// P0 回归锁：`AylaPullToRefresh` 放进**高度无界**的滚动容器必须能正常布局。
///
/// ## 事实源（web，禁自由发挥）
/// `Ayla/web/src/components/motion/PullToRefresh.tsx`（渲染 JSX 253–279）+
/// `Ayla/web/src/styles/app.css:4008–4071`：
/// - `.pull-to-refresh { position: relative; min-height: 0 }`（4010–4013）—— 容器在流内；
/// - `.pull-refresh-content { position: relative }`（4015–4017）—— **内容在流内**，
///   容器高度由它决定（JSX 里 content 是 indicator 之后的普通流内子级）；
/// - `.pull-refresh-indicator { position: absolute; top: 0; left: 0; right: 0; height: 52px }`
///   （4022–4035）—— 覆盖层，不参与尺寸；
/// - 容器**没有任何 overflow 声明**（4020–4021 注释：「可见性由状态类 + opacity 控制，
///   **不依赖滚动容器 overflow 裁剪**」）⇒ 不裁剪。
///
/// ## 事故（2026-09-29 P0，本文件的由来）
/// Flutter 侧此前把内容也写成 `Positioned.fill` ⇒ Stack 的两个直接子级**全是
/// Positioned** ⇒ `RenderStack` 取 `constraints.biggest`；六个目录页都把本件放进
/// `SingleChildScrollView`（滚动视口给子级 `widthConstraints()`：宽度 tight、主轴高度
/// 0..∞）⇒ `'size.isFinite'` 断言（`rendering/stack.dart`）⇒ 该子树布局中断 ⇒
/// 帖子 / 直播 / 语音 / 桌游四厅 + 收藏 + 搜索的内容区**全空**（render tree 大片
/// `NEEDS-LAYOUT`，语义树上也没有卡片节点）。
///
/// ⚠️ 断言方式：渲染库的 assert 经 `FlutterError` 进入 flutter_test 的 pending
/// exception ⇒ 用 `tester.takeException()` 显式取走并断言为 null（取不走则测试失败）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/preview_theme.dart';
import '../lib/widgets/base/directory_page.dart';
import '../lib/widgets/base/media_interaction.dart';
import '../lib/widgets/base/profile_and_filters.dart';

void main() {
  /// 内容：自然高度确定的流内列表（等价 web 的 `.posts-feed` / `.live-hall-grid` 等）。
  ///
  /// 高度 300 < 测试表面 600 ⇒ `SingleChildScrollView` 无可滚动空间，
  /// `Scrollable` 不会赢走手势 ⇒ 跟手位移断言不受滚动干扰（但滚动视口给子级的
  /// **主轴约束仍是 0..∞**，P0 的触发条件不变）。
  Widget content({double height = 300}) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < 3; i++)
            SizedBox(height: height / 3, child: Text('卡片 $i')),
        ],
      );

  /// 无界高度宿主：等价目录页内容区 —— `SingleChildScrollView` 给子级的约束是
  /// `widthConstraints()`（宽度 tight、高度 0..∞），即崩溃现场的
  /// `BoxConstraints(w=…, 0.0<=h<=Infinity)`。
  Widget unboundedHost(Widget child, {double width = 800}) => previewTheme(
        SizedBox(width: width, child: SingleChildScrollView(child: child)),
      );

  /// 指示器的 `AnimatedOpacity`（idle → 0；pulling / refreshing / done → 1）。
  Finder indicatorOpacity() => find.ancestor(
        of: find.byType(AylaRefreshDot),
        matching: find.byType(AnimatedOpacity),
      );

  double indicatorValue(WidgetTester tester) =>
      tester.widget<AnimatedOpacity>(indicatorOpacity()).opacity;

  group('AylaPullToRefresh 无界高度（P0 回归：目录页内容区全空）', () {
    testWidgets('放进高度无界的 SingleChildScrollView：不抛异常，卡片真的渲染出来',
        (WidgetTester tester) async {
      final GlobalKey key = GlobalKey();
      await tester.pumpWidget(
        unboundedHost(
          AylaPullToRefresh(
            key: key,
            isAtTop: () => true,
            onRefresh: () async {},
            child: content(),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull,
          reason: "不允许再出现 Stack 的 'size.isFinite' 断言（此前整片内容区空白）");
      expect(find.text('卡片 0'), findsOneWidget, reason: '卡片必须真的在树上（症状是 0 张卡）');
      expect(find.text('卡片 2'), findsOneWidget);

      final Size size = tester.getSize(find.byKey(key));
      expect(size.width, 800,
          reason: '宽度撑满父宽（web .pull-refresh-content 在流内、块级宽度随父）');
      expect(size.height, 300,
          reason: '容器高度由流内内容决定（web 容器无固定高度、min-height:0）');
    });

    testWidgets('结构锁：内容必须是 Stack 的非 Positioned 子级（唯一尺寸来源）',
        (WidgetTester tester) async {
      final GlobalKey key = GlobalKey();
      await tester.pumpWidget(
        unboundedHost(
          AylaPullToRefresh(
            key: key,
            isAtTop: () => true,
            onRefresh: () async {},
            child: content(),
          ),
        ),
      );
      await tester.pump();

      // 最外层 Stack（AylaRefreshDot 内部也有 Stack ⇒ 只取首个）
      final Stack stack = tester.widget<Stack>(
        find
            .descendant(of: find.byKey(key), matching: find.byType(Stack))
            .first,
      );
      expect(stack.children.whereType<Positioned>().length, 1,
          reason: '只有指示器是 Positioned（web .pull-refresh-indicator 是 absolute）');
      expect(stack.children.where((Widget c) => c is! Positioned).length, 1,
          reason: '内容必须在流内 —— 两个子级全 Positioned 时 Stack 失去尺寸来源（P0 根因）');
      expect(stack.fit, StackFit.loose, reason: 'Stack 只做尺寸容器（尺寸交给块级内容子级）');
      expect(stack.clipBehavior, Clip.none,
          reason: 'web .pull-to-refresh 无 overflow 声明 ⇒ 不裁剪');

      // 流内子级 = 块级内容（web `.pull-refresh-content { position: relative }`）：
      // 宽度撑满父可用宽、高度由内容决定、左对齐。
      final Align block = stack.children.first as Align;
      expect(block.widthFactor, isNull, reason: '宽度撑满（块级）；无界宽时会自动退化为内容宽');
      expect(block.heightFactor, 1.0, reason: '高度取内容自然高（绝不取 constraints.biggest）');
      expect(block.alignment, Alignment.topLeft, reason: '块级左对齐');

      // 命中面 = 整个盒子（web 的 div `pointer-events` 默认 auto ⇒ 透明处也命中）
      final Listener listener = tester.widget<Listener>(
        find
            .descendant(of: find.byKey(key), matching: find.byType(Listener))
            .first,
      );
      expect(listener.behavior, HitTestBehavior.opaque);
    });

    testWidgets('块级宽度 + 整盒命中：内容塌陷时仍撑满父宽、空白处也能下拉',
        (WidgetTester tester) async {
      final GlobalKey key = GlobalKey();
      int refreshes = 0;
      await tester.pumpWidget(
        previewTheme(
          SizedBox(
            height: 400,
            child: AylaPullToRefresh(
              key: key,
              isAtTop: () => true,
              onRefresh: () async {
                refreshes++;
              },
              child: const SizedBox(height: 1000, child: Text('列表内容')),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byKey(key)).width, 800,
          reason: '块级：宽度撑满父可用宽（内容自身宽度塌陷也不缩）');

      // 内容只占左上角一小块；在远离内容的空白处下拉（x=600）仍须触发 ——
      // web 的 `.pull-to-refresh` 是 div，onTouchStart 挂在盒子上，命中整个矩形。
      final Rect box = tester.getRect(find.byKey(key));
      final TestGesture gesture =
          await tester.startGesture(Offset(600, box.top + 40));
      await tester.pump();
      await gesture.moveTo(Offset(600, box.top + 140)); // dy = 100 > threshold 64
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(refreshes, 1, reason: '空白处下拉同样有效（命中面 = 整个盒子）');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('下拉：内容跟手位移（translateY）+ 指示器出现（opacity 0 → 1）',
        (WidgetTester tester) async {
      final GlobalKey key = GlobalKey();
      int refreshes = 0;
      await tester.pumpWidget(
        unboundedHost(
          AylaPullToRefresh(
            key: key,
            isAtTop: () => true,
            onRefresh: () async {
              refreshes++;
            },
            child: content(),
          ),
        ),
      );
      await tester.pump();

      expect(indicatorValue(tester), 0.0, reason: 'idle 态指示器隐藏（web opacity:0）');
      final double topBefore = tester.getTopLeft(find.text('卡片 0')).dy;
      // 起点按组件真实位置算（宿主把内容居中，硬编码坐标会打空）
      final Offset start =
          tester.getTopLeft(find.byKey(key)) + const Offset(400, 20);

      final TestGesture gesture = await tester.startGesture(start);
      await tester.pump();
      await gesture.moveTo(start + const Offset(0, 100)); // dy = 100 > threshold 64
      await tester.pump();

      expect(indicatorValue(tester), 1.0,
          reason: 'pulling 态指示器出现（web .is-pulling → opacity:1）');
      expect(tester.getTopLeft(find.text('卡片 0')).dy - topBefore,
          closeTo(dampPull(100), 0.5),
          reason: '内容跟手位移 = dampPull(dy)（web: content translateY(y)）');

      await gesture.up();
      await tester.pump(); // → refreshing
      expect(refreshes, 1, reason: '过阈值松手必须触发刷新（无界场景同款路径）');
      // 刷新完成 → done 停留 300ms → 收起动画 200ms
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
    });

    testWidgets('真实结构：AylaDirectoryContent（目录页内容区）内嵌本件不崩',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        unboundedHost(
          AylaDirectoryContent(
            child: AylaPullToRefresh(
              isAtTop: () => true,
              onRefresh: () async {},
              child: content(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // 让入场动画走完（300ms）

      expect(tester.takeException(), isNull);
      expect(find.text('卡片 0'), findsOneWidget);
      expect(find.text('卡片 2'), findsOneWidget);
    });

    testWidgets('有界高度（SizedBox 380 + ListView）保持原行为（画布样张用法）',
        (WidgetTester tester) async {
      final GlobalKey key = GlobalKey();
      await tester.pumpWidget(
        previewTheme(
          SizedBox(
            width: 375,
            height: 380,
            child: AylaPullToRefresh(
              key: key,
              isAtTop: () => true,
              onRefresh: () async {},
              child: ListView(
                physics: const NeverScrollableScrollPhysics(),
                children: const <Widget>[
                  SizedBox(height: 900, child: Text('卡片 0')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      final Size size = tester.getSize(find.byKey(key));
      expect(size.width, 375);
      expect(size.height, 380,
          reason: '有界高度下容器仍占满父高（与修复前的 Positioned.fill 行为一致）');
    });

    testWidgets('目录页真实装配（AylaDirectoryPage → 内容区 → 本件）：内容区不再空白',
        (WidgetTester tester) async {
      // 有界视口（等价 AppShell 的固定高度内容区）+ 1280 宽 ⇒ 宽屏两列档，
      // 内容区走 _DirectoryContentBleed（≥769 的 12px 绘制带外扩），与实机一致。
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        previewTheme(
          AylaDirectoryPage(
            filters: AylaDirectoryFilters(
              label: '帖子分类',
              options: const <({String key, String label})>[
                (key: 'all', label: '全部'),
                (key: 'post', label: '帖子'),
              ],
              value: 'all',
              onChange: (String _) {},
            ),
            content: AylaDirectoryContent(
              child: AylaPullToRefresh(
                isAtTop: () => true,
                onRefresh: () async {},
                child: content(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // 侧栏/内容入场动画走完

      expect(tester.takeException(), isNull,
          reason: '实机症状：目录页内容区整片空白（Stack 的 size.isFinite 断言中断布局）');
      expect(find.text('卡片 0'), findsOneWidget);
      expect(find.text('卡片 2'), findsOneWidget);
    });
  });
}
