/// 空分组间距回归锁（2026-10-15 用户实报「内容区顶部留空都多了」）。
///
/// ## 根因
/// web 的 `ResultGroup` 在 `count === 0` 时 **`return null`**（SearchPage.tsx:503）
/// ⇒ 空分组**不产生 DOM 节点**，不占 flex `gap` / multicol `margin`。
/// Flutter 的 `Column(spacing:)` 与 `AylaCssColumns(itemGap:)` 会给**零高 child 照样插间距**
/// ⇒ 若把空分组也放进 children，首张卡被推下「空分组个数 × spacing」。
///
/// 搜索七档顺序 = 用户→群聊→帖子→桌游室→语音房→直播间 ⇒ 单类档偏移逐档递增：
/// 群聊 +16 · 帖子 +32 · 桌游室 +48 · 语音房 +64 · 直播间 +80（与用户截图吻合）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/app_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/css_columns.dart';

void main() {
  group('间距机制（Flutter 语义，非本库 bug——是必须绕开的平台差异）', () {
    testWidgets('Column.spacing 会给零高 child 插间距：前导空 child 逐个数累积', (
      WidgetTester tester,
    ) async {
      for (final int n in <int>[0, 1, 2, 3, 4, 5]) {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                spacing: AylaSpacing.sp4,
                children: <Widget>[
                  for (int i = 0; i < n; i++) const SizedBox.shrink(),
                  const SizedBox(
                    key: ValueKey<String>('target'),
                    height: 50,
                  ),
                ],
              ),
            ),
          ),
        ));
        final Rect t = tester.getRect(find.byKey(const ValueKey<String>('target')));
        final Rect c = tester.getRect(find.byType(Column));
        expect(t.top - c.top, n * AylaSpacing.sp4,
            reason: '前导空 child 数=' + n.toString() + ' 时顶部留空应为 n × sp4');
      }
    });

    testWidgets('AylaCssColumns：零高单元也参与分配与摆放（不是「不存在」）', (
      WidgetTester tester,
    ) async {
      // 与 `Column(spacing:)` 的**区别**（如实记录，避免下次误判）：
      // 多列件把单元**分配**到各列后再列内摆放，零高单元在列内只推进 itemGap（不产生可见高度），
      // 且可能被分到第 2 列 ⇒ 「首个可见单元」的顶部留空不一定是 N × itemGap。
      // ⇒ 结论不变：**空分组必须在进 children 之前就被过滤掉**（与 web 的 return null 对齐），
      //    否则无论间距怎么算，都会多出一个「占位的空单元」。
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        theme: buildAylaTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 1000,
              child: AylaCssColumns(
                columnCount: 2,
                columnGap: AylaSpacing.sp6,
                itemGap: AylaSpacing.sp4,
                children: <Widget>[
                  const SizedBox.shrink(), // 空分组
                  const SizedBox.shrink(),
                  const SizedBox(key: ValueKey<String>('target'), height: 50),
                ],
              ),
            ),
          ),
        ),
      ));
      // 零高单元不占可见高度 ⇒ 容器高由唯一有高的单元决定（50）
      final Size host = tester.getSize(find.byType(AylaCssColumns));
      debugPrint('多列容器高 = ' + host.height.toString());
      expect(host.height, lessThan(AylaSpacing.sp4 + 50 + AylaSpacing.sp4 + 1),
          reason: '零高单元不得把容器撑高（它们只是分配项，不是可见间距来源）');
      // 唯一有高的单元必须被渲染且可见
      final Rect target = tester.getRect(find.byKey(const ValueKey<String>('target')));
      expect(target.height, 50);
    });
  });
  group('页面层契约：空分组必须在进 children 前被过滤（源扫，web `return null` 等价物）', () {
    test('search_page.dart 的两处分组列表都必须走 _nonEmptyGroups', () {
      // 用**源扫**而不是渲染断言：
      // · `SearchPage` 直接调静态 `AylaSearchApi`，测试无法注入 fake 响应；
      // · 而「空分组有没有被过滤」是**纯源码事实**（与 web 用源扫验 backdrop-filter 同一理由）。
      // 若将来有人把 `_nonEmptyGroups(...)` 换回裸列表，本断言立刻转红。
      final File f = File('lib/pages/search_page.dart');
      expect(f.existsSync(), isTrue, reason: '源文件必须存在（cwd = Ayla/flutter）');
      final String src = f.readAsStringSync();
      // 两处调用点（Column 档 / AylaCssColumns 档）
      final int calls = '_nonEmptyGroups(results, single, revealIndex, wide)'.allMatches(src).length;
      expect(calls, 2,
          reason: '两个分支都必须用 _nonEmptyGroups（实际找到 ' + calls.toString() + ' 处）');
      // 不得再有裸的分组调用直接进 children
      expect(src.contains('children: <Widget>[\n                _usersGroup('), isFalse,
          reason: '不得把空分组可能出现在其中的裸列表直接交给 Column/AylaCssColumns');
      // helper 必须存在且以 total != 0 为判据（与 AylaSearchResultGroup 的 count==0 早退同源）
      expect(src.contains('List<Widget> _nonEmptyGroups('), isTrue);
      final int guards = '?? 0) != 0)'.allMatches(src).length;
      expect(guards, greaterThanOrEqualTo(6),
          reason: '六个分组各需一条非空判据（实际找到 ' + guards.toString() + ' 条）');
    });
  });
}