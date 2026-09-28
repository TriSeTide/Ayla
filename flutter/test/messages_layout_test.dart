/// 消息域页面骨架与宽屏右列定向测试 —— 对照 `messages.css`（页面级声明块）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/user_public.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/avatar_halo.dart';
import '../lib/widgets/chat/messages_layout.dart';
import '../lib/widgets/chat/request_rows.dart';

void main() {
  Widget host(Widget child, {EdgeInsets viewPadding = EdgeInsets.zero}) =>
      MaterialApp(
        home: previewTheme(
          MediaQuery(
            data: MediaQueryData(viewPadding: viewPadding),
            child: SizedBox(width: 900, height: 600, child: child),
          ),
        ),
      );

  testWidgets('AylaMessagesPage 窄屏：column + 底部 68 + 安全区（避让 FAB）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        AylaMessagesPage(
          children: <Widget>[
            const SizedBox(height: 40),
            const Expanded(child: SizedBox.expand()),
          ],
        ),
        viewPadding: const EdgeInsets.only(bottom: 34),
      ),
    );
    final Padding padding = tester.widget<Padding>(
      find.ancestor(
        of: find.byType(Column),
        matching: find.byType(Padding),
      ).first,
    );
    expect(
      padding.padding,
      const EdgeInsets.only(
        bottom: AylaMessagesPage.fabClearance + 34,
      ),
      reason: '`.messages-page { padding-bottom: 68px }` + 安全区（与 HomePage 同口径）',
    );
    expect(AylaMessagesPage.fabClearance, 68);
  });

  testWidgets('AylaMessagesPage 宽屏：row + 无底部 padding（侧栏/输入框铺满）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        AylaMessagesPage(
          wide: true,
          children: <Widget>[
            const SizedBox(width: 332),
            const AylaWideMessagesPane(),
          ],
        ),
        viewPadding: const EdgeInsets.only(bottom: 34),
      ),
    );
    expect(find.byType(Row), findsWidgets);
    final Finder pageRow = find
        .descendant(of: find.byType(AylaMessagesPage), matching: find.byType(Row))
        .first;
    final Row row = tester.widget<Row>(pageRow);
    expect(row.crossAxisAlignment, CrossAxisAlignment.stretch);
    // 宽屏档没有底部 padding ⇒ 不出现 68+34 的 Padding
    final Iterable<Padding> paddings = tester.widgetList<Padding>(find.byType(Padding));
    for (final Padding p in paddings) {
      expect((p.padding as EdgeInsets).bottom, isNot(AylaMessagesPage.fabClearance + 34));
    }
  });

  testWidgets('AylaWideMessages：`/chat/:id` 外壳（row + 裁剪）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        AylaWideMessages(
          children: <Widget>[
            const SizedBox(width: 332),
            const Expanded(child: SizedBox.expand()),
          ],
        ),
      ),
    );
    expect(find.byType(ClipRect), findsWidgets);
  });

  testWidgets('AylaWideMessagesPane 空态：两行文案逐字 + 居中', (WidgetTester tester) async {
    // 本件返回 `Expanded`（= web 的 `flex: 1`）⇒ 必须作为 Row 的直接子项。
    await tester.pumpWidget(
      host(
        const Row(children: <Widget>[AylaWideMessagesPane()]),
      ),
    );
    expect(find.text('选择一个会话开始聊天'), findsOneWidget);
    expect(find.text('左侧会话列表，点击进入私聊'), findsOneWidget);
    final Rect empty = tester.getRect(find.byType(AylaWideMessagesEmpty));
    final Rect title = tester.getRect(find.text('选择一个会话开始聊天'));
    expect(title.center.dx, moreOrLessEquals(empty.center.dx, epsilon: 1),
        reason: '`.wide-messages-empty` 水平居中');
  });

  testWidgets('AylaWideMessagesPane 有内容：子件铺满（`> .private-chat { flex: 1 }`）', (WidgetTester tester) async {
    // ⚠️ flutter_test 默认表面 800×600 会夹住 `SizedBox(900)`（库内既有测试纪律）
    await tester.binding.setSurfaceSize(const Size(900, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      host(
        Row(
          children: <Widget>[
            AylaWideMessagesPane(
              child: Container(
                key: const ValueKey<String>('pane-child'),
                color: Colors.red,
              ),
            ),
          ],
        ),
      ),
    );
    expect(find.byType(AylaWideMessagesEmpty), findsNothing);
    final Rect child = tester.getRect(find.byKey(const ValueKey<String>('pane-child')));
    expect(child.width, moreOrLessEquals(900, epsilon: 0.5));
    expect(child.height, moreOrLessEquals(600, epsilon: 0.5));
  });

  testWidgets('分组件：标题 15/700 + 组内 gap sp2 + 说明 13 且上移 8', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        const Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AylaMessagesSectionHint('好友申请、群邀请和入群申请都会集中显示在这里。'),
            AylaMessagesGroup(
              title: '我的好友（2）',
              children: <Widget>[AylaMessagesEmpty('还没有好友，去搜索添加吧')],
            ),
          ],
        ),
      ),
    );
    final Text title = tester.widget<Text>(find.text('我的好友（2）'));
    expect(title.style!.fontSize, 15);
    expect(title.style!.fontWeight, FontWeight.w700);
    final Text hint = tester
        .widget<Text>(find.text('好友申请、群邀请和入群申请都会集中显示在这里。'));
    expect(hint.style!.fontSize, 13);
    final Transform moved = tester.widget<Transform>(
      find.ancestor(of: find.text(hint.data!), matching: find.byType(Transform)).first,
    );
    expect(moved.transform.storage[13], -AylaSpacing.sp2,
        reason: '`.messages-section-hint { margin: calc(var(--sp-2) * -1) 0 0 }`');
    final Text empty = tester.widget<Text>(find.text('还没有好友，去搜索添加吧'));
    expect(empty.style!.fontSize, 13);
  });

  testWidgets('好友行头像尺寸档：默认 36（宽屏侧栏）/ 40（窄屏页）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        Column(
          children: <Widget>[
            AylaFriendRow(
              user: const AylaUserPublic(id: 'u1', nickname: '小樱', username: 's'),
              onOpenChat: () {},
            ),
            AylaFriendRow(
              user: const AylaUserPublic(id: 'u2', nickname: '阿澈', username: 'a'),
              onOpenChat: () {},
              avatarSize: 40,
            ),
          ],
        ),
      ),
    );
    final List<AylaAvatarHalo> halos =
        tester.widgetList<AylaAvatarHalo>(find.byType(AylaAvatarHalo)).toList();
    expect(halos.length, 2);
    expect(halos[0].size, 36, reason: 'WideMessagesSidebar.tsx:241');
    expect(halos[1].size, 40, reason: 'MessagesPage.tsx:288（窄屏好友行）');
  });
}
