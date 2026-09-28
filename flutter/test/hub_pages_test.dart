/// 第二批页面（VoiceHub / LiveHub / GamesHub / Favorites / Search）的定向测试。
///
/// 分两层：
/// 1. **分类过滤纯函数**（hub_support）—— 三个大厅页的「前端二次过滤」判据，
///    与 web VoiceHubPage.tsx:76–87 / LiveHubPage.tsx:63–75 / GamesHubPage.tsx:70–82 逐条对应；
/// 2. **页面首帧与失败态** —— 骨架数量（对照 tsx 的骨架结构）+ 无网络时不崩、
///    错误静默（web 的错误态只影响页脚）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/boardgame_api.dart';
import '../lib/core/api/live_api.dart';
import '../lib/core/api/voice_api.dart';
import '../lib/core/models/game_room.dart';
import '../lib/core/models/user_public.dart';
import '../lib/core/models/visibility.dart';
import '../lib/pages/favorites_page.dart';
import '../lib/pages/games_hub_page.dart';
import '../lib/pages/hub_support.dart';
import '../lib/pages/live_hub_page.dart';
import '../lib/pages/search_page.dart';
import '../lib/pages/voice_hub_page.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/base/loading.dart' show AylaSkeleton;
import '../lib/widgets/game/games_grid.dart';
import '../lib/widgets/live/live_hall.dart';
import '../lib/widgets/profile/favorites_skeleton.dart';
import '../lib/widgets/voice/voice_channels.dart';

AylaDirectoryVoiceEntry _voice(
  String id, {
  AylaPostVisibility? visibility,
  int? memberCount,
  String ownerId = '',
}) =>
    AylaDirectoryVoiceEntry(
      card: AylaVoiceCardData(
        id: id,
        name: id,
        memberCount: memberCount,
        visibility: visibility,
      ),
      ownerId: ownerId,
    );

AylaDirectoryLiveEntry _live(
  String id, {
  AylaLiveStatus? status,
  AylaPostVisibility? visibility,
  String ownerId = '',
  bool isOwner = false,
}) =>
    AylaDirectoryLiveEntry(
      card: AylaLiveCardData(
        id: id,
        title: id,
        status: status,
        visibility: visibility,
      ),
      ownerId: ownerId,
      isOwner: isOwner,
    );

AylaDirectoryGameEntry _game(
  String id, {
  AylaGameRoomStatus? status,
  AylaPostVisibility? visibility,
  String ownerId = '',
  bool isOwner = false,
}) =>
    AylaDirectoryGameEntry(
      card: AylaGameCardData(
        id: id,
        name: id,
        status: status,
        visibility: visibility,
      ),
      room: AylaGameRoom(
        id: int.tryParse(id) ?? 0,
        name: id,
        owner: const AylaUserPublic(id: ''),
        ownerId: '',
        status: status,
      ),
      ownerId: ownerId,
      isOwner: isOwner,
    );

Widget _host(Widget child, {Size viewport = const Size(1440, 900)}) {
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

void main() {
  group('aylaHubFilterOf / aylaHubFilterLabel', () {
    test('已知分类取原值；未知/缺省 → all', () {
      expect(aylaHubFilterOf(VoiceHubPage.filters, 'occupied'), 'occupied');
      expect(aylaHubFilterOf(VoiceHubPage.filters, null), 'all');
      expect(aylaHubFilterOf(VoiceHubPage.filters, 'nope'), 'all');
      expect(aylaHubFilterLabel(VoiceHubPage.filters, 'mine'), '我的');
    });
  });

  group('语音大厅分类过滤（VoiceHubPage.tsx:76–87）', () {
    final Set<String> friends = <String>{'u9'};
    test('public 按 visibility', () {
      expect(
        aylaHubMatchVoice(
          _voice('a', visibility: AylaPostVisibility.public),
          'public',
        ),
        isTrue,
      );
      expect(
        aylaHubMatchVoice(
          _voice('b', visibility: AylaPostVisibility.friends),
          'public',
        ),
        isFalse,
      );
      expect(aylaHubMatchVoice(_voice('c'), 'public'), isFalse);
    });

    test('friends 用好友集合判 owner_id', () {
      expect(
        aylaHubMatchVoice(_voice('a', ownerId: 'u9'), 'friends',
            friendIds: friends),
        isTrue,
      );
      expect(
        aylaHubMatchVoice(_voice('b', ownerId: 'u8'), 'friends',
            friendIds: friends),
        isFalse,
      );
      expect(aylaHubMatchVoice(_voice('c'), 'friends'), isFalse);
    });

    test('occupied = member_count > 0（缺省不算有人）', () {
      expect(
        aylaHubMatchVoice(_voice('a', memberCount: 3), 'occupied'),
        isTrue,
      );
      expect(aylaHubMatchVoice(_voice('b', memberCount: 0), 'occupied'), isFalse);
      expect(aylaHubMatchVoice(_voice('c'), 'occupied'), isFalse);
    });

    test('mine = owner_id === 当前用户；未登录恒假', () {
      expect(
        aylaHubMatchVoice(_voice('a', ownerId: 'me'), 'mine',
            currentUserId: 'me'),
        isTrue,
      );
      expect(
        aylaHubMatchVoice(_voice('b', ownerId: 'me'), 'mine',
            currentUserId: 'other'),
        isFalse,
      );
      expect(aylaHubMatchVoice(_voice('c', ownerId: 'me'), 'mine'), isFalse);
    });

    test('未知分类不丢弃条目（default true）', () {
      expect(aylaHubMatchVoice(_voice('a'), 'unexpected'), isTrue);
    });
  });

  group('直播大厅分类过滤（LiveHubPage.tsx:63–75）', () {
    test('live / offline 按 status', () {
      expect(
        aylaHubMatchLive(_live('a', status: AylaLiveStatus.live), 'live'),
        isTrue,
      );
      expect(
        aylaHubMatchLive(_live('b', status: AylaLiveStatus.idle), 'live'),
        isFalse,
      );
      expect(
        aylaHubMatchLive(_live('c', status: AylaLiveStatus.idle), 'offline'),
        isTrue,
      );
      // status 缺失（未知）⇒ 归入停播（web 是 !== "live"）
      expect(aylaHubMatchLive(_live('d'), 'offline'), isTrue);
    });

    test('public / friends / mine', () {
      expect(
        aylaHubMatchLive(
          _live('a', visibility: AylaPostVisibility.public),
          'public',
        ),
        isTrue,
      );
      expect(
        aylaHubMatchLive(_live('b', ownerId: 'u9'), 'friends',
            friendIds: <String>{'u9'}),
        isTrue,
      );
      expect(aylaHubMatchLive(_live('c', isOwner: true), 'mine'), isTrue);
      expect(aylaHubMatchLive(_live('d'), 'mine'), isFalse);
    });
  });

  group('桌游大厅分类过滤（GamesHubPage.tsx:70–82）', () {
    test('waiting / playing 按 status', () {
      expect(
        aylaHubMatchGame(
          _game('1', status: AylaGameRoomStatus.waiting),
          'waiting',
        ),
        isTrue,
      );
      expect(
        aylaHubMatchGame(
          _game('2', status: AylaGameRoomStatus.playing),
          'waiting',
        ),
        isFalse,
      );
      expect(
        aylaHubMatchGame(
          _game('3', status: AylaGameRoomStatus.playing),
          'playing',
        ),
        isTrue,
      );
      // ended 不属于任何 tab（web 只在 waiting/playing 两 tab 出现）
      expect(
        aylaHubMatchGame(_game('4', status: AylaGameRoomStatus.ended), 'playing'),
        isFalse,
      );
    });

    test('public / friends / mine', () {
      expect(
        aylaHubMatchGame(
          _game('1', visibility: AylaPostVisibility.friends),
          'public',
        ),
        isFalse,
      );
      expect(
        aylaHubMatchGame(_game('2', ownerId: 'u9'), 'friends',
            friendIds: <String>{'u9'}),
        isTrue,
      );
      expect(aylaHubMatchGame(_game('3', isOwner: true), 'mine'), isTrue);
    });
  });

  group('页面首帧与失败态', () {
    testWidgets('VoiceHubPage：首帧两根 64 高骨架（tsx 288–292）', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(const VoiceHubPage()));
      expect(find.byType(AylaSkeleton), findsNWidgets(2));
      expect(find.text('语音房间'), findsOneWidget); // 侧栏标题
      await tester.pumpAndSettle();
    });

    testWidgets('LiveHubPage：首帧两根 96 高骨架（tsx 143–147）', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(const LiveHubPage()));
      expect(find.byType(AylaSkeleton), findsNWidgets(2));
      expect(find.text('直播间'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('GamesHubPage：首帧桌游骨架（tsx 184–193）', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(const GamesHubPage()));
      expect(find.byType(AylaGamesGridSkeleton), findsOneWidget);
      expect(find.text('桌游室'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('FavoritesPage：首帧收藏骨架（tsx 268–271）', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(const FavoritesPage()));
      expect(find.byType(AylaFavoritesSkeleton), findsOneWidget);
      expect(find.text('我的收藏'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('SearchPage：带 q 时先显示「搜索中…」（tsx 375）', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(const SearchPage(initialQuery: '爱莉')));
      expect(find.text('搜索中…'), findsOneWidget);
      expect(find.text('全局搜索'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('SearchPage：无 q 且历史为空 ⇒ 内容区为空（tsx 362）', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(const SearchPage()));
      await tester.pumpAndSettle();
      expect(find.text('搜索中…'), findsNothing);
      expect(find.text('未找到「」相关结果'), findsNothing);
    });

    testWidgets('窄屏：五个目录页均按窄屏档渲染（不溢出、不抛异常）', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(375, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _host(const GamesHubPage(), viewport: const Size(375, 720)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        _host(const FavoritesPage(), viewport: const Size(375, 720)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
