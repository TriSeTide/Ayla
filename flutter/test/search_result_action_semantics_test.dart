/// 搜索结果卡「内容差异」回归锁 —— `action` 三档语义 + typed 槽落点。
///
/// ## 事实源（全部为真实浏览器实测，1440×900 / dpr 1）
///
/// web `SearchPage.tsx:427–458` 给四类结果卡都传 **`action={null}`**：
///   tsx 431 `<PostCard … action={null} previewOnly />`
///   tsx 440 `<GameRoomCard … action={null} />`
///   tsx 448 `<VoiceChannelCard … action={null} browsing />`
///   tsx 455 `<LiveChannelCard … action={null} />`
/// 三域组件同一条语义（`PostCard.tsx:145` / `LiveChannelCard.tsx:51` /
/// `GameRoomCard.tsx:50` / `VoiceChannelCard.tsx:31`）：
///   `action === undefined` => 自渲收藏键；`action === null` => 什么都不渲染。
///
/// 实测 `.favorite-toggle` 计数：
///   `/search?q=1&type=post` 帖卡底排 = **0**（对照 `/posts` = 1）
///   `/search?q=1&type=voice` = **0**（对照 `/voice` = 1）
///   `/search?q=1&type=live` = **0**；`/search?q=1&type=game` = **0**
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/game_room.dart';
import '../lib/core/models/post.dart';
import '../lib/theme/app_theme.dart';
import '../lib/widgets/base/directory_controls.dart'
    show AylaFavoriteButton, AylaFavoriteState;
import '../lib/widgets/game/game_room_card.dart';
import '../lib/widgets/live/live_hall.dart';
import '../lib/widgets/posts/post_card.dart';
import '../lib/widgets/voice/voice_channels.dart';

/// 最小可用帖子（只填卡片渲染必需字段）。
AylaPost _post() => AylaPost.fromJson(<String, dynamic>{
      'id': 1,
      'body': '正文',
      'created_at': '2026-10-01T10:00:00+08:00',
    })!;

Widget _host(Widget child) => MaterialApp(
      theme: buildAylaTheme(),
      home: Scaffold(body: Center(child: SizedBox(width: 570, child: child))),
    );

/// 统计子树里的收藏键数量（`AylaFavoriteButton` 是本库唯一收藏键实现）。
int _favCount(WidgetTester tester) =>
    find.byType(AylaFavoriteButton).evaluate().length;

void main() {
  group('AylaPostCard —— action 三档（web PostCard.tsx:145）', () {
    testWidgets('action == null 且 showFavorite false => 不渲染收藏键（搜索页档）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_host(AylaPostCard(
        post: _post(),
        onOpen: () {},
        action: null,
        showFavorite: false,
      )));
      expect(_favCount(tester), 0, reason: 'web action={null} => 什么都不渲染');
      // 分享键仍在（`PostCard.tsx:146` 无条件渲染）
      expect(find.text('查看帖子'), findsOneWidget);
    });

    testWidgets('action == null 且 showFavorite true（默认）=> 渲染收藏键（信息流档）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_host(AylaPostCard(
        post: _post(),
        onOpen: () {},
      )));
      expect(_favCount(tester), 1, reason: 'web action===undefined => 默认收藏键');
    });

    testWidgets('action 非 null => 渲染该节点、不渲染默认收藏键（收藏页档）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_host(AylaPostCard(
        post: _post(),
        onOpen: () {},
        action: const Text('取消收藏'),
      )));
      expect(_favCount(tester), 0);
      expect(find.text('取消收藏'), findsOneWidget);
    });

    testWidgets('右推（Spacer）只属于默认收藏键档：搜索页档分享键不贴右缘', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      // 搜索页档：action null + showFavorite false
      await tester.pumpWidget(_host(AylaPostCard(
        post: _post(),
        onOpen: () {},
        action: null,
        showFavorite: false,
      )));
      final Rect share = tester.getRect(find.text('查看帖子'));
      // web 实测：搜索页档「查看帖子」左缘 = 尾排左内沿（不右推）
      expect(share.left, lessThan(200),
          reason: 'web 该档不右推（分享键紧随统计行，离右缘约 350px）');
    });
  });

  group('其余三类卡的 action=null 档（web SearchPage.tsx:440/448/455）', () {
    testWidgets('AylaLiveChannelCard：showActions false => 无收藏键', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_host(AylaLiveChannelCard(
        channel: const AylaLiveCardData(id: 'l1', title: '直播间'),
        onEnter: () {},
        showActions: false,
      )));
      expect(_favCount(tester), 0);
    });

    testWidgets('AylaLiveChannelCard：默认档 => 有收藏键（对照）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_host(AylaLiveChannelCard(
        channel: const AylaLiveCardData(id: 'l1', title: '直播间'),
        onEnter: () {},
      )));
      expect(_favCount(tester), 1);
    });

    testWidgets('AylaGameRoomCard：showFavorite false => 无收藏键', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_host(AylaGameRoomCard(
        room: const AylaGameCardData(id: 'g1', name: '桌游房'),
        onEnter: () {},
        showFavorite: false,
      )));
      expect(_favCount(tester), 0);
    });

    testWidgets('AylaVoiceChannelCard：action 与 favorite 皆 null => 无收藏键', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_host(AylaVoiceChannelCard(
        channel: const AylaVoiceCardData(id: 'v1', name: '语音房'),
        browsing: true,
        onEnter: () {},
      )));
      expect(_favCount(tester), 0,
          reason: 'voice_channels.dart:248–251 两槽皆 null => 不渲染');
    });

    testWidgets('AylaVoiceChannelCard：传 favorite => 渲染它（对照）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_host(AylaVoiceChannelCard(
        channel: const AylaVoiceCardData(id: 'v1', name: '语音房'),
        browsing: true,
        onEnter: () {},
        favorite: AylaFavoriteButton(
          state: AylaFavoriteState.notFavorited,
          compact: true,
        ),
      )));
      expect(_favCount(tester), 1);
    });
  });

  group('AylaLiveChannelCard —— typed 结果卡档落点 8/8', () {
    Future<Rect> run(WidgetTester tester, {required bool typed}) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        theme: buildAylaTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 560,
              child: AylaLiveChannelCard(
                channel: const AylaLiveCardData(id: 'l1', title: '直播间'),
                onEnter: () {},
                action: const SizedBox(
                  key: ValueKey<String>('slot'),
                  width: 65.6,
                  height: 27.2,
                  child: Text('取消收藏'),
                ),
                typedCardAction: typed,
              ),
            ),
          ),
        ),
      ));
      final Rect card = tester.getRect(find.byType(AylaLiveChannelCard));
      final Rect slot = tester.getRect(find.byKey(const ValueKey<String>('slot')));
      return Rect.fromLTWH(card.right - slot.right, slot.top - card.top,
          slot.width, slot.height);
    }

    testWidgets('typed 档（收藏页）=> dx/dy = 8', (WidgetTester tester) async {
      final Rect r = await run(tester, typed: true);
      expect(r.left, closeTo(8, 0.01), reason: 'typed-result-cards.css:13–16 的 sp2');
      expect(r.top, closeTo(8, 0.01));
    });

    testWidgets('默认档（直播大厅）=> 宽屏 dx/dy = 20（不改既有行为）', (
      WidgetTester tester,
    ) async {
      final Rect r = await run(tester, typed: false);
      expect(r.left, closeTo(20, 0.01), reason: 'live.css:635–640 的 calc(sp4+sp1)');
      expect(r.top, closeTo(20, 0.01));
    });
  });
}