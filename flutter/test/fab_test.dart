/// A4：右下角浮层按钮族定向测试 —— 逐条对照
/// `layout/{CornerFabStack,RefreshFab,ScrollTopFab,QuickMessageFab}.tsx`
/// 与 `styles/shell.css` 423–456 / 679–787。
///
/// 另含本批顺带修正的回归：`AylaCornerFab` 的过渡时长（180ms → 200ms，
/// 依据 `auroraqua.css:54–94` 对 `.corner-fab` 的同特异性后加载覆写）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/app_icons.dart' show AylaIcon;
import '../lib/theme/buttons.dart' show AylaCornerFab, AylaMessageFab;
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart' show AylaDurations, AylaSpacing;
import '../lib/widgets/fab.dart';
import '../lib/widgets/tab_badge.dart' show TabBadge;

void main() {
  Widget host(Widget child) => MaterialApp(home: previewScope(child));

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// 找树里是否存在平移 dx 的 `Transform`（精确像素位移断言，避免依赖祖先顺序）。
  bool hasTranslateX(WidgetTester tester, double dx) {
    return tester
        .widgetList<Transform>(find.byType(Transform))
        .any((Transform t) => (t.transform.storage[12] - dx).abs() < 0.01);
  }

  bool hasTranslateY(WidgetTester tester, double dy) {
    return tester
        .widgetList<Transform>(find.byType(Transform))
        .any((Transform t) => (t.transform.storage[13] - dy).abs() < 0.01);
  }

  /// 回顶钮自己的淡入层（收紧作用域，避免命中页面里其它 AnimatedOpacity）。
  Finder scrollTopOpacity() => find.descendant(
        of: find.byType(AylaScrollTopFab),
        matching: find.byType(AnimatedOpacity),
      );

  /// 按属性锁定唯一那层 `Positioned`（子树里还有 `AylaCornerFab` 的 `Positioned.fill`，
  /// 单用 descendant 会 "Too many elements"）。
  Positioned positionedAt(
    WidgetTester tester, {
    double? left,
    double? right,
    double? bottom,
  }) {
    return tester.widget<Positioned>(find.byWidgetPredicate(
      (Widget w) =>
          w is Positioned &&
          w.left == left &&
          w.right == right &&
          w.bottom == bottom,
    ));
  }

  /// 可滚动「页面」（内容 4000 高 → 远大于一屏）。
  Widget page(ScrollController controller) => Stack(
        children: <Widget>[
          ListView.builder(
            controller: controller,
            itemCount: 40,
            itemBuilder: (BuildContext context, int i) =>
                SizedBox(height: 100, child: Text('item $i')),
          ),
        ],
      );

  // ==================== 堆叠容器 ====================

  group('AylaCornerFabStack（CornerFabStack.tsx 1–26 + shell.css 684–694）', () {
    testWidgets('定位 = right 38 / bottom 100（fixed 等价 Positioned）', (WidgetTester tester) async {
      setViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(host(
        Stack(children: <Widget>[
          AylaCornerFabStack(refresh: true, scrollTop: true),
        ]),
      ));
      await tester.pump();

      expect(AylaCornerFabStack.stackRight, 38); // calc(32px + (56-44)/2)
      expect(AylaCornerFabStack.stackBottom, 100); // calc(32px + 56px + sp3)
      // ⚠️ 不能只用 descendant：子树里还有 `AylaCornerFab` 的 `Positioned.fill`
      // → 用属性谓词锁定「fixed 定位那一层」
      final Positioned positioned = positionedAt(tester, right: 38, bottom: 100);
      expect(positioned.right, 38);
      expect(positioned.bottom, 100);
    });

    testWidgets('垂直堆叠：回顶在上、刷新在下，gap sp3=12、align end', (WidgetTester tester) async {
      setViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(host(
        Stack(children: <Widget>[
          const AylaCornerFabStack(refresh: true, scrollTop: true),
        ]),
      ));
      await tester.pump();

      final Column column = tester.widget<Column>(
        find.descendant(
          of: find.byType(AylaCornerFabStack),
          matching: find.byType(Column),
        ),
      );
      expect(column.spacing, AylaSpacing.sp3);
      expect(column.crossAxisAlignment, CrossAxisAlignment.end);
      expect(column.mainAxisSize, MainAxisSize.min);

      final double scrollTopY =
          tester.getRect(find.byType(AylaScrollTopFab)).top;
      final double refreshY = tester.getRect(find.byType(AylaRefreshFab)).top;
      expect(scrollTopY, lessThan(refreshY), reason: 'JSX 顺序：ScrollTopFab 在上');

      final double gap = refreshY - tester.getRect(find.byType(AylaScrollTopFab)).bottom;
      expect(gap, AylaSpacing.sp3);
    });

    testWidgets('scrollTop 开关：只渲染回顶钮', (WidgetTester tester) async {
      setViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(host(
        Stack(children: <Widget>[const AylaCornerFabStack(scrollTop: true)]),
      ));
      await tester.pump();
      expect(find.byType(AylaScrollTopFab), findsOneWidget);
      expect(find.byType(AylaRefreshFab), findsNothing);
    });

    // ⚠️ 换参数必须另开一个 testWidgets：`previewScope` 的 `Overlay(initialEntries:)`
    // 只在首次创建生效，同一测试里第二次 pumpWidget 改参数**不会传播**（库内已踩过）。
    testWidgets('refresh 开关：只渲染刷新钮', (WidgetTester tester) async {
      setViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(host(
        Stack(children: <Widget>[const AylaCornerFabStack(refresh: true)]),
      ));
      await tester.pump();
      expect(find.byType(AylaRefreshFab), findsOneWidget);
      expect(find.byType(AylaScrollTopFab), findsNothing);
    });
  });

  // ==================== 刷新 ====================

  group('AylaRefreshFab（RefreshFab.tsx 1–39 + shell.css 742–758）', () {
    testWidgets('结构：AylaCornerFab + iconRetry 20 + aria-label，无 Material 图标', (
      WidgetTester tester,
    ) async {
      setViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(host(const AylaRefreshFab()));
      await tester.pump();

      final AylaCornerFab fab =
          tester.widget<AylaCornerFab>(find.byType(AylaCornerFab));
      expect((fab.icon as AylaIcon).icon.name, 'iconRetry');
      expect((fab.icon as AylaIcon).size, 20);
      expect(fab.semanticLabel, '刷新当前页');
      expect(find.byIcon(Icons.refresh), findsNothing);
    });

    testWidgets('点击 → 调 onRefresh；期间图标旋转、完成后停（800ms linear）', (
      WidgetTester tester,
    ) async {
      setViewport(tester, const Size(1440, 900));
      int calls = 0;
      final Completer<void> gate = Completer<void>();
      await tester.pumpWidget(host(AylaRefreshFab(
        onRefresh: () {
          calls++;
          return gate.future;
        },
      )));
      await tester.pump();
      expect(find.byType(RotationTransition), findsNothing);

      await tester.tap(find.byType(AylaCornerFab));
      await tester.pump();
      expect(calls, 1);
      // is-spinning → `.corner-fab-icon` 旋转（ayla-loading-spin 800ms linear infinite）
      expect(find.byType(RotationTransition), findsOneWidget);

      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(find.byType(RotationTransition), findsNothing);
    });

    testWidgets('无回调 ≠ 禁用：点击无异常、按钮保持可用外观', (WidgetTester tester) async {
      setViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(host(const AylaRefreshFab()));
      await tester.pump();

      // web `if (!fn) return;` —— 按钮不是 disabled（不出现 .55 禁用透明度）
      final AylaCornerFab fab =
          tester.widget<AylaCornerFab>(find.byType(AylaCornerFab));
      expect(fab.onPressed, isNotNull);
      await tester.tap(find.byType(AylaCornerFab));
      await tester.pump();
      expect(find.byType(RotationTransition), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('position: bottomLeft → Positioned(left 32 / bottom 32)', (WidgetTester tester) async {
      setViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(host(
        Stack(children: <Widget>[
          const AylaRefreshFab(position: AylaRefreshFabPosition.bottomLeft),
        ]),
      ));
      await tester.pump();

      final Positioned positioned = positionedAt(tester, left: 32, bottom: 32);
      expect(positioned.left, 32);
      expect(positioned.bottom, 32);
    });
  });

  // ==================== 回到顶部 ====================

  group('AylaScrollTopFab（ScrollTopFab.tsx 1–75 + shell.css 723–739 / 762–782）', () {
    testWidgets('初始隐藏：opacity 0 + 不可点 + 语义排除（aria-hidden / tabIndex=-1）', (
      WidgetTester tester,
    ) async {
      setViewport(tester, const Size(375, 812));
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(host(Stack(children: <Widget>[
        page(controller),
        AylaScrollTopFab(controller: controller),
      ])));
      await tester.pump();

      final AylaCornerFab fab =
          tester.widget<AylaCornerFab>(find.byType(AylaCornerFab));
      expect((fab.icon as AylaIcon).icon.name, 'iconArrowUp');
      expect((fab.icon as AylaIcon).size, 20);
      expect(fab.semanticLabel, '回到顶部');

      final AnimatedOpacity opacity =
          tester.widget<AnimatedOpacity>(scrollTopOpacity());
      expect(opacity.opacity, 0);
      // 不可点 = `visibility: hidden` 等价物。
      // ⚠️ `AylaCornerFab` 的阴影 ring 内部也有 `IgnorePointer` → 用「child 类型」
      // 精确锁定本组件那一层（不依赖 ancestor 的遍历顺序）。
      expect(
        tester
            .widget<IgnorePointer>(find.byWidgetPredicate(
              (Widget w) => w is IgnorePointer && w.child is ExcludeSemantics,
            ))
            .ignoring,
        isTrue,
      );
      // aria-hidden={!visible} 等价物
      expect(
        tester
            .widget<ExcludeSemantics>(find.byWidgetPredicate(
              (Widget w) => w is ExcludeSemantics && w.child is AnimatedOpacity,
            ))
            .excluding,
        isTrue,
      );
      expect(hasTranslateY(tester, 8), isTrue, reason: '隐藏态 translateY(8px)');
    });

    testWidgets('滚过一屏（>viewport 高）→ 浮入；未过一屏 → 仍隐藏', (WidgetTester tester) async {
      setViewport(tester, const Size(375, 812));
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(host(Stack(children: <Widget>[
        page(controller),
        AylaScrollTopFab(controller: controller),
      ])));
      await tester.pump();

      controller.jumpTo(400); // < 812：不到一屏
      await tester.pump();
      expect(
        tester.widget<AnimatedOpacity>(scrollTopOpacity()).opacity,
        0,
      );

      controller.jumpTo(900); // > 812：过一屏
      await tester.pump();
      expect(
        tester.widget<AnimatedOpacity>(scrollTopOpacity()).opacity,
        1,
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(hasTranslateY(tester, 0), isTrue, reason: 'is-visible → translateY(0)');
    });

    testWidgets('内嵌小滚动区（高 < 40% 视口）不算主滚动容器 → 不浮入', (WidgetTester tester) async {
      setViewport(tester, const Size(375, 812));
      final ScrollController inner = ScrollController();
      addTearDown(inner.dispose);
      await tester.pumpWidget(host(Stack(children: <Widget>[
        Column(children: <Widget>[
          SizedBox(
            height: 200, // 200 < 812 × 0.4 = 324.8
            child: ListView.builder(
              controller: inner,
              itemCount: 20,
              itemBuilder: (BuildContext context, int i) => SizedBox(height: 100, child: Text('i$i')),
            ),
          ),
        ]),
        AylaScrollTopFab(controller: inner),
      ])));
      await tester.pump();

      inner.jumpTo(1200); // 远超一屏，但容器太矮 → 不认
      await tester.pump();
      expect(
        tester.widget<AnimatedOpacity>(scrollTopOpacity()).opacity,
        0,
      );
    });

    testWidgets('点击 → 回顶（pixels 0）', (WidgetTester tester) async {
      setViewport(tester, const Size(375, 812));
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(host(Stack(children: <Widget>[
        page(controller),
        AylaScrollTopFab(controller: controller),
      ])));
      await tester.pump();
      controller.jumpTo(1600);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      await tester.tap(find.byType(AylaCornerFab));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // animateTo 300ms
      expect(controller.position.pixels, 0);
    });

    testWidgets('position: narrow → right 16 / bottom 76 + safe', (WidgetTester tester) async {
      setViewport(tester, const Size(375, 812));
      tester.view.padding = const FakeViewPadding(bottom: 34);
      await tester.pumpWidget(host(Stack(children: <Widget>[
        const AylaScrollTopFab(position: AylaScrollTopFabPosition.narrow),
      ])));
      await tester.pump();

      final Positioned p = positionedAt(tester, right: 16, bottom: 110);
      expect(p.right, 16);
      expect(p.bottom, 76 + 34); // calc(64px + safe + sp3)
    });

    testWidgets('position: narrow + stacked → right 22 / bottom 144 + safe', (
      WidgetTester tester,
    ) async {
      setViewport(tester, const Size(375, 812));
      tester.view.padding = const FakeViewPadding(bottom: 34);
      await tester.pumpWidget(host(Stack(children: <Widget>[
        const AylaScrollTopFab(
          position: AylaScrollTopFabPosition.narrow,
          stacked: true,
        ),
      ])));
      await tester.pump();

      final Positioned p = positionedAt(tester, right: 22, bottom: 178);
      expect(p.right, 22); // calc(16px + (56-44)/2)
      expect(p.bottom, 144 + 34); // 64 + safe + 12 + 56 + 12
    });
  });

  // ==================== 半贴消息钮 ====================

  group('AylaQuickMessageFab（QuickMessageFab.tsx 1–54 + shell.css 423–456）', () {
    testWidgets('结构：AylaMessageFab + iconMessage 24 + tab-badge + aria-label（有未读）', (
      WidgetTester tester,
    ) async {
      setViewport(tester, const Size(375, 812));
      await tester.pumpWidget(host(const AylaQuickMessageFab(unread: 3)));
      await tester.pump();

      final AylaMessageFab fab =
          tester.widget<AylaMessageFab>(find.byType(AylaMessageFab));
      expect((fab.icon as AylaIcon).icon.name, 'iconMessage');
      expect((fab.icon as AylaIcon).size, 24);
      expect(fab.semanticLabel, '消息，3 条未读'); // unread > 0
      expect(fab.badge, isA<TabBadge>());
      expect(find.text('3'), findsOneWidget);
    });

    // ⚠️ 换参数另开测试（Overlay(initialEntries:) 只在首次创建生效，见上）
    testWidgets('tab-badge 99+ 截断', (WidgetTester tester) async {
      setViewport(tester, const Size(375, 812));
      await tester.pumpWidget(host(const AylaQuickMessageFab(unread: 150)));
      await tester.pump();
      expect(find.text('99+'), findsOneWidget);
    });

    testWidgets('aria-label：无未读时为「消息」', (WidgetTester tester) async {
      setViewport(tester, const Size(375, 812));
      await tester.pumpWidget(host(const AylaQuickMessageFab()));
      await tester.pump();
      expect(
        tester.widget<AylaMessageFab>(find.byType(AylaMessageFab)).semanticLabel,
        '消息',
      );
    });

    testWidgets('展开 4s 无点击 → 半贴 translateX(-44px)（200ms 过渡）', (WidgetTester tester) async {
      setViewport(tester, const Size(375, 812));
      await tester.pumpWidget(host(const AylaQuickMessageFab(
        unread: 1,
        collapseDelay: Duration(milliseconds: 100), // 测试注入短延时（tsx 默认 4000）
      )));
      await tester.pump();
      expect(hasTranslateX(tester, 0), isTrue);

      await tester.pump(const Duration(milliseconds: 120)); // 计时到
      await tester.pump(const Duration(milliseconds: 200)); // 过渡走完
      expect(hasTranslateX(tester, -AylaQuickMessageFab.collapseShift), isTrue);
      expect(
        tester.widget<AylaMessageFab>(find.byType(AylaMessageFab)).semanticLabel,
        '展开消息', // 半贴态 label
      );
    });

    testWidgets('半贴点击 → 点出来（不打开）；展开点击 → onOpenQuickMessages', (
      WidgetTester tester,
    ) async {
      setViewport(tester, const Size(375, 812));
      int opened = 0;
      await tester.pumpWidget(host(AylaQuickMessageFab(
        unread: 1,
        collapseDelay: const Duration(milliseconds: 100),
        onOpenQuickMessages: () => opened++,
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350)); // 半贴完成

      await tester.tap(find.byType(AylaMessageFab));
      // ⚠️ `pump()` 不带时长 → 不推进时间：既重建了展开态，又不会让半贴计时器提前触发
      await tester.pump();
      expect(opened, 0, reason: '半贴态点击只是点出来');
      expect(
        tester.widget<AylaMessageFab>(find.byType(AylaMessageFab)).semanticLabel,
        '消息，1 条未读',
        reason: '半贴 → 展开（label 由「展开消息」变回未读态）',
      );

      await tester.tap(find.byType(AylaMessageFab));
      await tester.pump();
      expect(opened, 1, reason: '展开态点击打开快捷消息栏');
    });

    testWidgets('快捷栏已打开时不启动半贴计时（R-QM bug 修复语义）', (WidgetTester tester) async {
      setViewport(tester, const Size(375, 812));
      await tester.pumpWidget(host(const AylaQuickMessageFab(
        quickMessagesOpen: true,
        collapseDelay: Duration(milliseconds: 100),
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(hasTranslateX(tester, 0), isTrue); // 仍展开
    });
  });

  // ==================== 顺带修正回归 ====================

  group('AylaCornerFab 过渡时长（auroraqua.css 54–94 覆写 shell.css 713–714）', () {
    testWidgets('200ms --auroraqua-ease（不是 shell.css 的 180ms）', (WidgetTester tester) async {
      setViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(host(const AylaCornerFab(
        icon: SizedBox(width: 20, height: 20),
      )));
      await tester.pump();

      final AnimatedContainer animated = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byType(AylaCornerFab),
          matching: find.byType(AnimatedContainer),
        ),
      );
      expect(AylaDurations.button, const Duration(milliseconds: 200));
      expect(animated.duration, AylaDurations.button);
    });
  });
}
