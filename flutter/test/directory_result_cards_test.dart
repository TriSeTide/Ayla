/// B6-2：目录结果卡定向测试 —— 逐条对照 DirectoryResultCards.tsx 119 行 +
/// typed-result-cards.css。
///
/// 覆盖：群卡结构（Avatar 44 / 标题 / 「N 人 / 公开群聊」/ 入口文案 / 点卡回调）·
/// meta 缺省不渲染 · 申请制文案 · 收藏卡四种分派（game / voice / live / message）·
/// 投影缺失 → 「内容不可用」· 消息卡正文三态（blockquote 原文 / 已撤回 / 戳一戳）·
/// heading 昵称与缺省「消息」· action 槽位透传（群卡 + 收藏卡）。
///
/// ⚠️ post 分派未断言：AylaPost 的构造依赖帖子完整投影（本件只验证「分派到既有 post 卡」
/// 这一跳，页面层接线时再补）；其余四种已覆盖。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/chat_message.dart';
import '../lib/core/models/game_room.dart';
import '../lib/core/models/subgroup.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/avatar_halo.dart';
import '../lib/widgets/directory_result_cards.dart';
import '../lib/widgets/game_room_card.dart';
import '../lib/widgets/live_hall.dart';
import '../lib/widgets/voice_channels.dart';

void main() {
  Widget host(Widget child, {Size viewport = const Size(460, 700)}) {
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: SizedBox.fromSize(
              size: viewport,
              child: SingleChildScrollView(child: child),
            ),
          ),
        ),
      ),
    );
  }

  AylaChatMessage message({
    AylaMessageType type = AylaMessageType.text,
    AylaMessageStatus status = AylaMessageStatus.sent,
    String content = '正文',
  }) {
    return AylaChatMessage(
      id: 'm1',
      conversationId: 'c1',
      senderId: 'u1',
      type: type,
      content: content,
      status: status,
      seq: 1,
      createdAt: '',
    );
  }

  testWidgets('群卡结构：Avatar 44 / 标题 / N 人 + 公开群聊 / 入口文案 / 点击回调', (
    WidgetTester tester,
  ) async {
    int opened = 0;
    await tester.pumpWidget(host(AylaGroupResultCard(
      group: const AylaGroupResultData(
        id: 'g1',
        title: '冰樱研究社',
        memberCount: 42,
        joinPolicy: AylaGroupJoinPolicy.public,
      ),
      entryLabel: '进入',
      onOpen: () => opened++,
    )));
    await tester.pump();

    expect(find.text('冰樱研究社'), findsWidgets);
    expect(find.text('42 人'), findsOneWidget); // tsx 29
    expect(find.text('公开群聊'), findsOneWidget); // tsx 30
    expect(find.text('进入'), findsOneWidget); // .search-row-action
    expect(tester.widget<AvatarHalo>(find.byType(AvatarHalo)).size, 44); // tsx 26

    await tester.tap(find.text('冰樱研究社').last);
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('群卡 meta 缺省：只有标题时不渲染人数与策略', (WidgetTester tester) async {
    await tester.pumpWidget(host(AylaGroupResultCard(
      group: const AylaGroupResultData(id: 'g2', title: '只有名字的群'),
      onOpen: () {},
    )));
    await tester.pump();
    expect(find.text('只有名字的群'), findsWidgets);
    expect(find.textContaining(' 人'), findsNothing);
    expect(find.text('公开群聊'), findsNothing);
    expect(find.text('申请制群聊'), findsNothing);
  });

  testWidgets('群卡：申请制文案（tsx 30）', (WidgetTester tester) async {
    await tester.pumpWidget(host(AylaGroupResultCard(
      group: const AylaGroupResultData(
        id: 'g3',
        title: '申请制群',
        joinPolicy: AylaGroupJoinPolicy.application,
      ),
      onOpen: () {},
    )));
    await tester.pump();
    expect(find.text('申请制群聊'), findsOneWidget);
  });

  testWidgets('group action 槽位：替换件渲染在卡内', (WidgetTester tester) async {
    await tester.pumpWidget(host(AylaGroupResultCard(
      group: const AylaGroupResultData(id: 'g4', title: '群'),
      onOpen: () {},
      action: const Icon(Icons.close, key: ValueKey<String>('slot')),
    )));
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('slot')), findsOneWidget);
  });

  testWidgets('收藏分派：game → AylaGameRoomCard（tsx 59–60）', (WidgetTester tester) async {
    await tester.pumpWidget(host(AylaFavoriteResultCard(
      favorite: const AylaFavoriteResultData(
        id: 1,
        targetType: AylaFavoriteTargetType.game,
        game: AylaGameCardData(id: '1', name: '桌游房'),
      ),
      onOpen: () {},
    )));
    await tester.pump();
    expect(find.byType(AylaGameRoomCard), findsOneWidget);
  });

  testWidgets('收藏分派：voice → AylaVoiceChannelCard（tsx 57–58）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(AylaFavoriteResultCard(
      favorite: const AylaFavoriteResultData(
        id: 2,
        targetType: AylaFavoriteTargetType.voice,
        voice: AylaVoiceCardData(id: 'v1', name: '语音房'),
      ),
      onOpen: () {},
    )));
    await tester.pump();
    expect(find.byType(AylaVoiceChannelCard), findsOneWidget);
  });

  testWidgets('收藏分派：live → AylaLiveChannelCard（tsx 55–56）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(AylaFavoriteResultCard(
      favorite: const AylaFavoriteResultData(
        id: 3,
        targetType: AylaFavoriteTargetType.live,
        live: AylaLiveCardData(id: 'l1', title: '直播间'),
      ),
      onOpen: () {},
    )));
    await tester.pump();
    expect(find.byType(AylaLiveChannelCard), findsOneWidget);
  });

  testWidgets('收藏卡：投影缺失 → 「内容不可用」（tsx 46–48）', (WidgetTester tester) async {
    await tester.pumpWidget(host(AylaFavoriteResultCard(
      favorite: const AylaFavoriteResultData(
        id: 4,
        targetType: AylaFavoriteTargetType.post,
      ),
      onOpen: () {},
    )));
    await tester.pump();
    expect(find.text('内容不可用'), findsOneWidget);
  });

  testWidgets('消息卡：blockquote 原文 + heading 昵称（tsx 96–105）', (WidgetTester tester) async {
    int opened = 0;
    await tester.pumpWidget(host(AylaFavoriteResultCard(
      favorite: AylaFavoriteResultData(
        id: 5,
        targetType: AylaFavoriteTargetType.message,
        message: message(content: '被收藏的正文'),
      ),
      senderLabel: '爱莉',
      onOpen: () => opened++,
    )));
    await tester.pump();

    expect(find.text('爱莉'), findsOneWidget); // tsx 97
    expect(find.text('被收藏的正文'), findsOneWidget); // blockquote
    expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);

    // 整卡/主按钮可点（canOpen = conversationId 非空）
    await tester.tap(find.text('被收藏的正文'));
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('消息卡：已撤回文案 + 缺昵称时 heading 兜底「消息」（tsx 99–101）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(AylaFavoriteResultCard(
      favorite: AylaFavoriteResultData(
        id: 6,
        targetType: AylaFavoriteTargetType.message,
        message: message(status: AylaMessageStatus.recalled, content: ''),
      ),
      onOpen: () {},
    )));
    await tester.pump();
    expect(find.text('该消息已撤回'), findsOneWidget);
    expect(find.text('消息'), findsOneWidget); // 缺昵称时的 heading 兜底
  });

  testWidgets('消息卡：戳一戳文案（tsx 102）', (WidgetTester tester) async {
    await tester.pumpWidget(host(AylaFavoriteResultCard(
      favorite: AylaFavoriteResultData(
        id: 7,
        targetType: AylaFavoriteTargetType.message,
        message: message(type: AylaMessageType.poke, content: ''),
      ),
      onOpen: () {},
    )));
    await tester.pump();
    expect(find.text('戳一戳消息'), findsOneWidget);
  });

  testWidgets('收藏卡 action 槽位透传（web 的取消收藏直删键）', (WidgetTester tester) async {
    await tester.pumpWidget(host(AylaFavoriteResultCard(
      favorite: const AylaFavoriteResultData(
        id: 8,
        targetType: AylaFavoriteTargetType.game,
        game: AylaGameCardData(id: '1', name: '桌游房'),
      ),
      onOpen: () {},
      action: const Icon(Icons.close, key: ValueKey<String>('del')),
    )));
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('del')), findsOneWidget);
  });
}
