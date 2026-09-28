/// 主页（HomePage）首帧与状态定向测试 —— 对照 web `pages/HomePage.tsx`。
///
/// 与第二批同类页同一口径（hub_pages_test）：**无网络**下不崩、错误静默，
/// 只断言页面「骨架 / 空态 / 宽屏分支」三档与布局开关的行为，
/// 数据正确性由同批的纯函数测试 `home_activity_test.dart` 覆盖。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/pages/home_page.dart';
import '../lib/state/home_prefs.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/layout_switch.dart' show AylaLayoutSwitch;
import '../lib/widgets/base/loading.dart' show AylaSkeleton;
import '../lib/widgets/group/group_card.dart'
    show AylaGroupCard, AylaGroupListItem;

Widget _host(Widget child, {Size viewport = const Size(420, 900)}) {
  return ProviderScope(
    child: MaterialApp(
      home: Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: viewport),
          child: previewScope(child),
        ),
      ),
    ),
  );
}

Future<void> _pump(WidgetTester tester, {Size viewport = const Size(420, 900)}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  // ⚠️ 只 pump 首帧：无网络时请求在**下一个** microtask 就失败，
  // 多 pump 一次就会把首屏骨架推过去（对照 hub_pages_test 同口径）。
  await tester.pumpWidget(_host(const HomePage(), viewport: viewport));
}

/// 让在途请求（无网络 ⇒ 立即失败）走完，页面进入「空态」。
Future<void> _settleFailure(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('窄屏首帧（tsx 157–166）', () {
    testWidgets('页头 .home-toolbar：群聊 28/600 + 布局开关', (WidgetTester tester) async {
      await _pump(tester);

      final Text title = tester.widget<Text>(find.text('群聊'));
      expect(title.style?.fontSize, 28);
      expect(title.style?.fontWeight, FontWeight.w600);
      expect(find.byType(AylaLayoutSwitch), findsOneWidget);
      // .home-toolbar padding sp3 sp4
      expect(
        find.ancestor(
          of: find.text('群聊'),
          matching: find.byWidgetPredicate(
            (Widget w) =>
                w is Padding &&
                w.padding ==
                    const EdgeInsets.symmetric(
                      horizontal: AylaSpacing.sp4,
                      vertical: AylaSpacing.sp3,
                    ),
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('加载中 → SkeletonCards：6 张骨架群卡（tsx 35–47）', (WidgetTester tester) async {
      await _pump(tester);
      // 6 张卡 × 2 根骨架 = 12
      expect(find.byType(AylaSkeleton), findsNWidgets(12));
      expect(find.byType(AylaGroupCard), findsNothing);
      await tester.pump(const Duration(milliseconds: 50));
    });

    testWidgets('列表 / 卡片双形态由 AylaLayoutSwitch 驱动（默认卡片档）', (WidgetTester tester) async {
      await _pump(tester);
      final AylaLayoutSwitch before =
          tester.widget<AylaLayoutSwitch>(find.byType(AylaLayoutSwitch));
      expect(before.isCard, isTrue, reason: 'web stores/home.ts:20 默认 card');

      // 两个键的可访问名 = web 的 aria-label（"卡片布局" / "列表布局"）
      for (final String label in <String>['卡片布局', '列表布局']) {
        expect(
          find.byWidgetPredicate(
            (Widget w) => w is Semantics && w.properties.label == label,
          ),
          findsWidgets,
          reason: label,
        );
      }

      // 本用例的范围是**页面接线**：onChanged(false) → prefs.setLayout(list)
      // → 开关回落到列表档（开关自身的按钮行为由它自己的测试覆盖）。
      final AylaLayoutSwitch sw =
          tester.widget<AylaLayoutSwitch>(find.byType(AylaLayoutSwitch));
      sw.onChanged(false);
      await tester.pump();
      final AylaLayoutSwitch after =
          tester.widget<AylaLayoutSwitch>(find.byType(AylaLayoutSwitch));
      expect(after.isCard, isFalse);
      await tester.pump(const Duration(milliseconds: 50));
    });
  });

  group('窄屏空态（tsx 170–180）', () {
    testWidgets('两行文案 + 两键（创建群聊 / 搜索发现群）', (WidgetTester tester) async {
      await _pump(tester);
      await _settleFailure(tester);

      expect(find.text('创建你的第一个群'), findsOneWidget);
      expect(find.text('和朋友们聚在一起，从这里开始'), findsOneWidget);
      expect(find.text('创建群聊'), findsOneWidget);
      expect(find.text('搜索发现群'), findsOneWidget);
      // .home-state padding：sp12 sp6（home.css 622–629）
      expect(
        find.ancestor(
          of: find.text('创建你的第一个群'),
          matching: find.byWidgetPredicate(
            (Widget w) =>
                w is Padding &&
                w.padding ==
                    const EdgeInsets.symmetric(
                      horizontal: AylaSpacing.sp6,
                      vertical: AylaSpacing.sp12,
                    ),
          ),
        ),
        findsOneWidget,
      );
      // 请求失败后不再显示骨架，也不伪造群卡
      expect(find.byType(AylaSkeleton), findsNothing);
      expect(find.byType(AylaGroupCard), findsNothing);
      expect(find.byType(AylaGroupListItem), findsNothing);
    });
  });

  group('宽屏（tsx 124–151）', () {
    testWidgets('无群 → .home-wide-empty（还没有加入群聊 + 创建你的第一个群）', (
      WidgetTester tester,
    ) async {
      await _pump(tester, viewport: const Size(1440, 900));
      await _settleFailure(tester);

      expect(find.text('还没有加入群聊'), findsOneWidget);
      expect(find.text('创建或加入一个群聊，这里是你的「家」'), findsOneWidget);
      expect(find.text('创建你的第一个群'), findsOneWidget);
      // 宽屏不出现窄屏页头与布局开关
      expect(find.text('群聊'), findsNothing);
      expect(find.byType(AylaLayoutSwitch), findsNothing);
    });
  });

  group('AylaHomePrefsController（web stores/home.ts）', () {
    test('layout 只认 list，其余（null/未知/空）回落 card', () {
      expect(AylaHomeLayout.parse('list'), AylaHomeLayout.list);
      expect(AylaHomeLayout.parse('card'), AylaHomeLayout.card);
      expect(AylaHomeLayout.parse(null), AylaHomeLayout.card);
      expect(AylaHomeLayout.parse('nope'), AylaHomeLayout.card);
    });

    test('读盘：缺键回落默认；存储异常静默回落默认', () async {
      final AylaHomePrefsController c1 = AylaHomePrefsController(
        reader: () async => <String, Object?>{
          'ayla.home.layout': 'list',
          'ayla.home.recent_group': 'g9',
        },
      );
      await c1.load();
      expect(c1.layout, AylaHomeLayout.list);
      expect(c1.recentGroupId, 'g9');

      final AylaHomePrefsController c2 = AylaHomePrefsController(
        reader: () async => throw StateError('存储不可用'),
      );
      await c2.load();
      expect(c2.layout, AylaHomeLayout.card);
      expect(c2.recentGroupId, isNull);
    });

    test('写盘：setLayout/setRecentGroup 落盘键名与 web 一致；null 清除最近群', () async {
      Map<String, Object?>? written;
      final AylaHomePrefsController c = AylaHomePrefsController(
        reader: () async => <String, Object?>{},
        writer: (Map<String, Object?> prefs) async => written = prefs,
      );
      await c.load();
      c.setLayout(AylaHomeLayout.list);
      expect(written?['ayla.home.layout'], 'list');
      c.setRecentGroup('g1');
      expect(written?['ayla.home.recent_group'], 'g1');
      c.setRecentGroup(null);
      expect(written?.containsKey('ayla.home.recent_group'), isFalse);
    });
  });
}
