/// 群内场景**不应重复让出状态栏**的回归锁（2026-10-19 用户实拍「群内不需要这个」）。
///
/// 背景：群页自己渲染 `AylaGroupTopTabs`，状态栏已由群顶栏**覆盖着色**。
/// 群内的直播/语音/帖子/桌游复用与一级页**相同**的房间组件，那些组件默认会自己让出
/// 状态栏（因为一级路由是沉浸式、壳层不出顶栏）⇒ 群内必须显式关闭，否则群顶栏与
/// 场景头部之间会多出一条**空白色带**（用户截图红框里那条）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/preview_theme.dart';
import '../lib/widgets/base/safe_area.dart';

void main() {
  group('AylaTopInsetGap 只产出「有状态栏时的高度」', () {
    testWidgets('viewPadding.top 为 0 时不产出任何尺寸（桌面/宽屏零开销）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        previewScope(
          const MediaQuery(
            data: MediaQueryData(padding: EdgeInsets.zero, viewPadding: EdgeInsets.zero),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: AylaTopInsetGap(),
            ),
          ),
        ),
      );
      expect(tester.getSize(find.byType(AylaTopInsetGap)).height, 0);
    });

    testWidgets('有状态栏时高度 = viewPadding.top', (WidgetTester tester) async {
      await tester.pumpWidget(
        previewScope(
          const MediaQuery(
            data: MediaQueryData(
              padding: EdgeInsets.only(top: 24),
              viewPadding: EdgeInsets.only(top: 24),
            ),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: AylaTopInsetGap(),
            ),
          ),
        ),
      );
      expect(tester.getSize(find.byType(AylaTopInsetGap)).height, 24);
    });

    testWidgets('键盘弹出（viewInsets）不影响占位高度 —— 必须用 viewPadding 而非 padding', (
      WidgetTester tester,
    ) async {
      // 键盘弹出时 `MediaQuery.padding` 会随 `viewInsets` 联动变化，
      // 但 `viewPadding` 保持稳定。顶栏不该因弹键盘而跳动。
      await tester.pumpWidget(
        previewScope(
          const MediaQuery(
            data: MediaQueryData(
              viewPadding: EdgeInsets.only(top: 24),
              viewInsets: EdgeInsets.only(bottom: 300),
              padding: EdgeInsets.only(top: 24, bottom: 0),
            ),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: AylaTopInsetGap(),
            ),
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(AylaTopInsetGap)).height,
        24,
        reason: '键盘弹出不应改变顶栏占位（用 viewPadding）',
      );
    });
  });
}
