import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/widgets/avatar_status_badges.dart';
import '../lib/widgets/group_card.dart';
import '../lib/theme/preview_theme.dart';

void main() {
  testWidgets('B3 卡片族渲染无异常', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(375, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(previewTheme(
      AylaGroupGrid(children: <Widget>[
        AylaGroupCard(
          groupId: 'g1',
          title: '测试群',
          slides: <GroupCarouselSlide>[
            const GroupCarouselSlide.messageVoice(
                newMessageCount: 3, voiceRooms: <GroupSlideVoiceRoom>[]),
          ],
          unread: 5,
          onOpen: () {},
        ),
      ]),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('测试群'), findsWidgets);
  });

  testWidgets('列表项渲染无异常', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(375, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(previewTheme(
      AylaGroupList(children: <Widget>[
        AylaGroupListItem(
          groupId: 'g1',
          title: '列表群',
          status: const AvatarStatus(unread: 7, live: true),
          preview: '小樱：你好',
          onOpen: () {},
        ),
      ]),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('列表群'), findsOneWidget);
  });
}
