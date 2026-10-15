/// 搜索域三件定向测试 —— 逐条对照 `SearchPage.tsx`（362–372 / 494–521 / 391–408）+ `search.css` 11–176。
///
/// 覆盖：历史块的两条隐藏条件（有查询词 / 历史为空）· chip 文案顺序与回调 · 清空回调 ·
/// 结果分组的「空组不渲染」· 标题隐显 · 页脚三态（查看更多 / 加载中…/ 重试）+ 紧凑化参数 + 回调 ·
/// 用户行的显示名回退 / 副行条件渲染 / 头像尺寸与语义 / 两个点击回调 / 尾部槽位。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/buttons.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/avatar_halo.dart';
import '../lib/widgets/base/pagination_footer.dart';
import '../lib/widgets/search/search_history_chips.dart';
import '../lib/widgets/search/search_result_group.dart';
import '../lib/widgets/search/search_user_row.dart';

void main() {
  Widget host(Widget child, {double width = 420}) => MaterialApp(
    home: previewScope(
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, child: child),
      ),
    ),
  );

  group('AylaSearchHistoryChips（SearchPage.tsx 362–372 / search.css 11–30）', () {
    testWidgets('历史为空 ⇒ 整块不渲染', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaSearchHistoryChips(history: <String>[]),
        ),
      );
      expect(find.text('清空'), findsNothing);
    });

    testWidgets('有查询词 ⇒ 整块不渲染（web `!q &&`）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaSearchHistoryChips(
            history: <String>['爱莉'],
            query: '爱',
          ),
        ),
      );
      expect(find.text('爱莉'), findsNothing);
    });

    testWidgets('chip 文案顺序 + 回调 + 清空回调', (WidgetTester tester) async {
      final List<String> log = <String>[];
      await tester.pumpWidget(
        host(
          AylaSearchHistoryChips(
            history: const <String>['爱莉', '语音房'],
            onSelect: (String w) => log.add('select:$w'),
            onClear: () => log.add('clear'),
          ),
        ),
      );
      expect(find.text('爱莉'), findsOneWidget);
      expect(find.text('语音房'), findsOneWidget);
      expect(find.text('清空'), findsOneWidget);

      await tester.tap(find.text('语音房'));
      await tester.pump();
      await tester.tap(find.text('清空'));
      await tester.pump();
      expect(log, <String>['select:语音房', 'clear']);
    });

    testWidgets('chip 关键尺寸与质感：pill + ice-100 底 + padding 4×12；清空为纯文字', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AylaSearchHistoryChips(history: <String>['爱莉']),
        ),
      );
      final Container chip = tester.widget<Container>(
        find.ancestor(of: find.text('爱莉'), matching: find.byType(Container)).first,
      );
      expect(chip.padding, AylaSearchHistoryChips.chipPadding);
      final BoxDecoration deco = chip.decoration! as BoxDecoration;
      expect(deco.color, const Color(0xFFECF0F2)); // --ice-100
      expect(deco.borderRadius, AylaRadii.pill);
      // 两个可点项都走库内按压件（chip 在 auroraqua 按钮组内；清空不在组内 ⇒ 关掉缩放）
      final List<AylaPressScale> press = tester
          .widgetList<AylaPressScale>(find.byType(AylaPressScale))
          .toList();
      expect(press.length, 2);
      expect(press.first.hoverScale, isTrue);
      expect(press.last.hoverScale, isFalse);
      expect(press.last.pressScale, isFalse);
    });
  });

  group('AylaSearchResultGroup（ResultGroup 494–521 / search.css 68–105）', () {
    testWidgets('count == 0 ⇒ 整组不渲染（不是空态）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaSearchResultGroup(
            title: '用户',
            count: 0,
            children: <Widget>[Text('不该出现')],
          ),
        ),
      );
      expect(find.text('用户'), findsNothing);
      expect(find.text('不该出现'), findsNothing);
    });

    testWidgets('标题大写 + 单类视图可隐藏；无更多且无错误 ⇒ 无页脚', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaSearchResultGroup(
            title: '用户',
            count: 1,
            children: <Widget>[Text('行')],
          ),
        ),
      );
      expect(find.text('用户'), findsOneWidget); // toUpperCase（中文不变）
      expect(find.byType(AylaStablePaginationFooter), findsNothing);

      await tester.pumpWidget(
        host(
          const AylaSearchResultGroup(
            title: '群聊',
            count: 1,
            showTitle: false,
            children: <Widget>[Text('行')],
          ),
        ),
      );
      expect(find.text('群聊'), findsNothing);
    });

    // ⚠️ 三态各写一个用例：同一 `testWidgets` 里二次 `pumpWidget` 换 props **不生效**（库内既有结论）
    testWidgets('页脚：有更多 ⇒「查看更多」+ 紧凑化参数 + 回调', (WidgetTester tester) async {
      final List<String> log = <String>[];
      await tester.pumpWidget(
        host(
          AylaSearchResultGroup(
            title: '用户',
            count: 1,
            hasMore: true,
            onMore: () => log.add('more'),
            children: const <Widget>[Text('行')],
          ),
        ),
      );
      expect(find.text('查看更多'), findsOneWidget);
      // 紧凑化：`min-height: 0; padding: sp2 0 0`
      final AylaStablePaginationFooter footer = tester
          .widget<AylaStablePaginationFooter>(
            find.byType(AylaStablePaginationFooter),
          );
      expect(footer.minHeight, 0);
      expect(footer.padding, const EdgeInsets.only(top: 8));
      expect(
        tester.widget<AylaGlassButton>(find.byType(AylaGlassButton)).onPressed,
        isNotNull,
      );
      await tester.tap(find.text('查看更多'));
      await tester.pump();
      expect(log, <String>['more']);
    });

    testWidgets('页脚：加载中 ⇒「加载中…」且按钮禁用', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaSearchResultGroup(
            title: '用户',
            count: 1,
            hasMore: true,
            loading: true,
            onMore: () {},
            children: const <Widget>[Text('行')],
          ),
        ),
      );
      expect(find.text('加载中…'), findsOneWidget);
      expect(
        tester.widget<AylaGlassButton>(find.byType(AylaGlassButton)).onPressed,
        isNull,
      );
    });

    testWidgets('页脚：失败 ⇒ error 文案 +「重试」键触发 onMore', (WidgetTester tester) async {
      final List<String> log = <String>[];
      await tester.pumpWidget(
        host(
          AylaSearchResultGroup(
            title: '用户',
            count: 1,
            error: '加载失败，请重试',
            onMore: () => log.add('more'),
            children: const <Widget>[Text('行')],
          ),
        ),
      );
      expect(find.text('加载失败，请重试'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(log, <String>['more']);
    });
  });

  group('AylaSearchUserRow（search.css 107–176 / SearchPage.tsx 391–408）', () {
    // ⚠️ 两个状态拆两个用例（同用例二次 pumpWidget 换 props 不生效）
    testWidgets('昵称空 ⇒ 回退用户名；无签名 ⇒ 无副行', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaSearchUserRow(nickname: '', username: 'sakura'),
        ),
      );
      expect(find.text('sakura'), findsOneWidget);
      // ⚠️ 头像首字（`AylaAvatarHalo` 的 's'）也是 `Text`（库内既有坑）⇒ 只断言「除它之外没有第二行」
      expect(
        find.descendant(
          of: find.byType(AylaSearchUserRow),
          matching: find.byType(Text),
        ),
        findsNWidgets(2), // 头像首字 + 标题（无副行）
      );
    });

    testWidgets('昵称优先；有签名 ⇒ 渲染副行', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaSearchUserRow(
            nickname: '爱莉',
            username: 'elysia',
            signature: '今天也想见你',
          ),
        ),
      );
      expect(find.text('爱莉'), findsOneWidget);
      expect(find.text('elysia'), findsNothing); // 昵称优先
      expect(find.text('今天也想见你'), findsOneWidget);
    });

    testWidgets('头像 36 + 语义标签 + 两个点击回调（头像 / 正文）', (WidgetTester tester) async {
      final List<String> log = <String>[];
      await tester.pumpWidget(
        host(
          AylaSearchUserRow(
            nickname: '爱莉',
            username: 'elysia',
            onOpenProfile: () => log.add('profile'),
            onTap: () => log.add('open'),
          ),
        ),
      );
      final AylaAvatarHalo avatar = tester.widget<AylaAvatarHalo>(
        find.byType(AylaAvatarHalo),
      );
      expect(avatar.size, 36);
      expect(avatar.semanticLabel, '查看 爱莉 的个人主页');

      await tester.tap(find.byType(AylaAvatarHalo));
      await tester.pump();
      await tester.tap(find.text('爱莉'));
      await tester.pump();
      expect(log, <String>['profile', 'open']);
    });

    testWidgets('尾部槽位（.search-row-action）可注入', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaSearchUserRow(
            nickname: '星海观测站',
            username: 'g',
            trailing: Text('进入'),
          ),
        ),
      );
      expect(find.text('进入'), findsOneWidget);
    });
  });

  // ================= 多列接线（Lead 本轮补：宽屏搜索页 CSS columns 等价物） =================
  //
  // web 事实链（实测 1440 / 400）：
  //   · 全部档 `search.css:501–506`：`.search-results { display:block; columns:2; column-gap: sp6 }`
  //     单元 = 整个 `.search-group`，`margin-bottom: sp4`（search.css:522）⇒ 单元间距 16
  //   · 单类档 `search.css:508–517`：`.search-group-body { columns:2; column-gap: sp6 }`
  //     `> * { margin-bottom: sp3 }` + `typed-result-cards.css:134` 的 `gap: sp3`
  //     ⇒ 单元间距 = 12 + 12 = 24（实测相邻项 y 差 90.6 = 66.6 + 24）
  //   · gap 恒 12（`typed-result-cards.css:134` 覆写 `search.css:101` 的 sp2，全断点）
  group('AylaSearchResultGroup —— 多列（search.css:501–517）', () {
    Widget grouped({required int columnCount, required double itemGap, double width = 1164}) =>
        MaterialApp(
          home: previewScope(
            Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: AylaSearchResultGroup(
                  title: '用户',
                  count: 4,
                  columnCount: columnCount,
                  itemGap: itemGap,
                  children: <Widget>[
                    for (int i = 0; i < 4; i++)
                      SizedBox(
                        key: ValueKey<int>(i),
                        height: 100,
                        child: ColoredBox(
                          color: i.isEven ? Colors.red : Colors.blue,
                          child: Text('行$i'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );

    testWidgets('单列档（窄屏 / 全部档组内）：全部纵向排列、间距 = itemGap', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(grouped(columnCount: 1, itemGap: 12));
      final Rect r0 = tester.getRect(find.byKey(const ValueKey<int>(0)));
      final Rect r1 = tester.getRect(find.byKey(const ValueKey<int>(1)));
      expect(r1.left, closeTo(r0.left, 0.01), reason: '单列不换列');
      expect(r1.top - r0.top, closeTo(112, 0.01), reason: '100 + gap 12');
    });

    testWidgets('两列档（单类宽屏）：按 CSS columns 切分，列距 24、单元距 24', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1300, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(grouped(columnCount: 2, itemGap: 24));
      final List<Rect> r = <Rect>[
        for (int i = 0; i < 4; i++) tester.getRect(find.byKey(ValueKey<int>(i))),
      ];
      // 4 × 100 / gap24 ⇒ Chrome 实测 2 / 2（见 css_columns_test 的受控实验）
      expect(r[0].left, closeTo(r[1].left, 0.01));
      expect(r[2].left, closeTo(r[0].left + (r[0].width + 24), 0.01),
          reason: '第 2 列起点 = 列宽 + column-gap 24');
      expect(r[1].top - r[0].top, closeTo(124, 0.01), reason: '100 + itemGap 24');
      expect(r[2].top, closeTo(r[0].top, 0.01), reason: '两列首项齐平');
    });

    testWidgets('页脚不参与多列：横跨整组宽度、排在多列体之下', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1300, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: previewScope(
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 1164,
              child: AylaSearchResultGroup(
                title: '群聊',
                count: 4,
                columnCount: 2,
                itemGap: 24,
                hasMore: true,
                onMore: () {},
                children: <Widget>[
                  for (int i = 0; i < 4; i++)
                    SizedBox(key: ValueKey<int>(i), height: 100),
                ],
              ),
            ),
          ),
        ),
      ));
      final Rect group = tester.getRect(find.byType(AylaSearchResultGroup));
      final Rect more = tester.getRect(find.text('查看更多'));
      // 按钮横向居中于整组（若被塞进某一列，中心会明显偏左）
      expect(more.center.dx, closeTo(group.center.dx, 1.0),
          reason: '页脚在 .search-group-body 之外（tsx 507）⇒ 横跨整组');
      // 且在所有内容项之下
      final Rect last = tester.getRect(find.byKey(const ValueKey<int>(3)));
      expect(more.top, greaterThanOrEqualTo(last.bottom));
    });
  });}
