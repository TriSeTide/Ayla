/// 他人主页回归（`web/src/pages/UserProfilePage.tsx` 211 行）。
///
/// 可测面：加载态（骨架）与失败态（文案 + 重试 / 返回）；
/// 正常态需要网络（`GET /users/{id}/`），由后端契约测试覆盖 —— 本文件不 mock `DioClient`，
/// 未初始化时请求必然失败 ⇒ 正好用于**失败态**的断言。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/pages/user_profile_page.dart';
import '../lib/widgets/base/loading.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/profile/profile_card.dart';

void main() {
  Widget host(Widget child, {Size viewport = const Size(1440, 900)}) {
    return MaterialApp(
      home: Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: viewport),
          child: previewScope(child),
        ),
      ),
    );
  }

  testWidgets('加载态：两根骨架（高 96 + 高 12 / 宽 60%，tsx 104–107）', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      host(const UserProfilePage(userId: 'u2')),
    );
    // 首帧：请求在途 ⇒ 骨架
    expect(find.byType(AylaSkeleton), findsNWidgets(2));
    await tester.pumpAndSettle();
  });

  testWidgets('失败态：文案 + 重试 / 返回两键（tsx 108–115）', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      host(const UserProfilePage(userId: 'u2')),
    );
    await tester.pumpAndSettle();

    expect(find.text('用户不存在或暂时无法访问'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('返回'), findsOneWidget);
  });
  testWidgets('宽屏非 split（对方未开内容展示 / 无数据）：单列居中 + 卡片最大宽 640', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host(const UserProfilePage(userId: 'u2')));
    await tester.pumpAndSettle();

    final Rect card = tester.getRect(find.byType(AylaProfileCard));
    debugPrint('USERPROFILE card=' + card.toString());
    // web `.profile-page-split > .profile-column:not(:has(.profile-main))`
    // ⇒ `grid-template-columns: minmax(0, 640px)` + `justify-content: center`
    expect(card.width, closeTo(640, 1));
    expect(card.center.dx, closeTo(720, 2)); // 视口 1440 水平居中
    // ⚠️ 顶部对齐（web align-self: start）由页面内的 Alignment.topCenter 表达；
    // 本断言不量绝对 top
    // —— 测试宿主 previewScope 会把内容整体居中，量绝对值会误判。
  });

}