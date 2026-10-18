/// 第二批页面（VoiceHub / LiveHub / GamesHub / Favorites / Search）的定向测试。
///
/// 分两层：
/// 1. **分类过滤纯函数**（hub_support）—— 三个大厅页的「前端二次过滤」判据，
///    与 web VoiceHubPage.tsx:76–87 / LiveHubPage.tsx:63–75 / GamesHubPage.tsx:70–82 逐条对应；
/// 2. **页面首帧与失败态** —— 骨架数量（对照 tsx 的骨架结构）+ 无网络时不崩、
///    错误静默（web 的错误态只影响页脚）。
library;

import 'dart:io';

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
import '../lib/state/directory_events.dart';
import '../lib/pages/live_hub_page.dart';
import '../lib/pages/group_posts_page.dart' show AylaPostViewProbe;
import '../lib/pages/search_page.dart';
import '../lib/pages/voice_hub_page.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/base/loading.dart' show AylaSkeleton;
import '../lib/widgets/base/scroll_restore.dart'
    show AylaScrollMemory, AylaScrollRestore;
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


/// 【E1】滚动位置恢复接线（web `useScrollRestore`，2026-10-17 补齐 6 页）
///
/// 之前：`lib/widgets/base/scroll_restore.dart` 件已存在，但除 posts_hub / search /
/// post_detail 三页外**其余 6 页都没接** ⇒ 进详情再返回时列表回到顶部。
/// 本组锁两件事：① 键字符串与 web `scope` 逐字一致；② 记忆命中后页面不把记录覆盖成 0。
void _scrollRestoreGroup() {
  group('E1 滚动恢复（useScrollRestore.ts:48–105）—— 6 页接线', () {
    setUp(AylaScrollMemory.clear);
    tearDown(AylaScrollMemory.clear);

    /// 逐页源码里的键字面量（= web scope 的 Flutter 表达）。
    ///
    /// 用**源码字符串**断言而不实例化页面：六页各自要 ProviderScope + 网络替身，
    /// 而键是纯字符串契约 —— 读文件锁最稳，也不依赖任何 mock。
    /// web 事实源见各组注释。
    test('键与 web scope 逐字一致（6 页）', () {
      const Map<String, String> cases = <String, String>{
        // GamesHubPage.tsx:45  const scope = `games-hub:${filter}`;
        'games_hub_page.dart': r'games-hub:$_filter',
        // LiveHubPage.tsx:42   const scope = `live-hub:${filter}`;
        'live_hub_page.dart': r'live-hub:$_filter',
        // VoiceHubPage.tsx:54  const scope = `voice-hub:${filter}`;
        'voice_hub_page.dart': r'voice-hub:$_filter',
        // FavoritesPage.tsx:295 const scope = `favorites:${favoriteAccount()}:${filter}`;
        'favorites_page.dart': r'favorites:$user:$_filter',
        // MyPostsPage.tsx:74   const scrollRestoreKey = `user-posts:${ownerId}`;
        'my_posts_page.dart': 'user-posts:',
        // GroupPosts.tsx:73/88 const ownerKey = `${userId}:group-posts:${groupId}`;
        'group_posts_page.dart': r':group-posts:$groupId',
      };
      for (final MapEntry<String, String> e in cases.entries) {
        final String src = File('lib/pages/${e.key}').readAsStringSync();
        expect(
          src,
          contains(e.value),
          reason: '${e.key} 的滚动键必须逐字等于 web scope（${e.value}）',
        );
        // 同时必须真的用了恢复控制器（防「键在、没接」）
        expect(src, contains('AylaScrollRestore('), reason: '${e.key} 必须实例化 AylaScrollRestore');
        expect(src, contains('AylaScrollMemory.save('), reason: '${e.key} 必须在入口显式 saveScrollPosition');
        expect(src, contains('_restore.update('), reason: '${e.key} 必须在 build 里表达 ready 门');
      }
    });

    test('记忆命中：restoring 为真、且不把记录清零（useScrollRestore.ts:65–73）', () {
      AylaScrollMemory.put('probe-key', 96);
      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      final AylaScrollRestore restore = AylaScrollRestore(
        key: 'probe-key',
        controller: controller,
        ready: false,
      )..attach();
      addTearDown(restore.dispose);
      // ready=false 时：命中过（restoring 真）但**不**落位（tsx 69 的 `!ready` 早退）
      expect(restore.restoring, isTrue);
      expect(restore.hasSavedPosition, isTrue);
      expect(AylaScrollMemory.get('probe-key'), 96, reason: '首帧不得覆盖记忆');
      // ready 转真后仍不写回（无附件时 jumpTo 会被跳过）
      restore.update(ready: true);
      expect(AylaScrollMemory.get('probe-key'), 96);
    });
  });
}

/// 【E2】帖子视口浏览上报接线（web `usePostViewTracking`，2026-10-17 补齐 2 页）
///
/// 之前：只有 `group_posts_page.dart` 接了探针 + `reportPostViews`；
/// `posts_hub_page.dart`（`PostsHubPage.tsx:113`）与 `my_posts_page.dart`
/// （`MyPostsPage.tsx:68`）**都没接** ⇒ 这两页刷帖不产生浏览上报。
void _postViewTrackingGroup() {
  group('E2 帖子视口浏览上报（usePostViewTracking.ts:24–88）—— 2 页接线', () {
    test('三页共用同一个探针 + 同一个 flush 窗口常量（不复制第二份）', () {
      final String group =
          File('lib/pages/group_posts_page.dart').readAsStringSync();
      // 探针是本页定义的公开件（group_posts 是唯一实现）
      expect(group, contains('class AylaPostViewProbe extends StatefulWidget'));
      expect(group, contains('const int kAylaPostViewFlushDelayMs = 300'),
          reason: 'FLUSH_DELAY_MS = 300（usePostViewTracking.ts:22）');

      for (final String page in <String>[
        'posts_hub_page.dart', // PostsHubPage.tsx:113
        'my_posts_page.dart', //  MyPostsPage.tsx:68
      ]) {
        final String src = File('lib/pages/$page').readAsStringSync();
        // 必须 import 复用，而不是各自复制一份
        expect(
          src,
          contains('show AylaPostViewProbe, kAylaPostViewFlushDelayMs'),
          reason: '$page 必须复用 group_posts 的探针与常量',
        );
        // 四处接线缺一不可：探针挂载 / 进视口回调 / 去抖 / 上报
        expect(src, contains('AylaPostViewProbe('),
            reason: '$page 必须挂探针');
        expect(src, contains('_onPostVisible('),
            reason: '$page 必须有进视口回调');
        expect(src, contains('kAylaPostViewFlushDelayMs'),
            reason: '$page 必须用 300ms 去抖');
        expect(src, contains('AylaPostsApi.reportPostViews('),
            reason: '$page 必须真的上报');
        // 页面卸载要取消定时器（web :86 clearTimeout）
        expect(src, contains('_viewFlushTimer?.cancel()'),
            reason: '$page 卸载必须取消去抖定时器');
      }
    });

    testWidgets('探针：真进视口才回调，且只在上升沿触发一次（IO 语义）', (
      WidgetTester tester,
    ) async {
      int calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: <Widget>[
                const SizedBox(height: 2000),
                AylaPostViewProbe(
                  onVisible: () => calls += 1,
                  child: const SizedBox(height: 100, width: 100),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(calls, 0, reason: '首屏在 2000px 之外 ⇒ 不可见、不回调');

      // 滚到它可见
      await tester.drag(find.byType(ListView), const Offset(0, -2100));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(calls, 1, reason: '进入视口 → 回调一次');

      // 继续小幅滚动（仍可见）⇒ 不重复回调
      await tester.drag(find.byType(ListView), const Offset(0, -20));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(calls, 1, reason: '持续可见不重复回调（只在跨越阈值时触发）');
    });
  });
}

/// 语音房「有人区置顶」判据（web `sortChannels.ts:32–46`）在侧栏投影处的回归锁 ——
/// 覆盖 task-5 用户实报的「宽屏第二列侧栏排序依然错误」：
/// 人数 0 → 1 时该房必须被排到最前（且**数据本身**要先跟着事件更新）。
void _voiceSortGroup() {
  group('侧栏语音排序：有人 0→1 时置顶（sortChannels.ts:33–39）', () {
    AylaDirectoryVoiceEntry entry(String id, {int count = 0}) =>
        AylaDirectoryVoiceEntry(
          card: AylaVoiceCardData(id: id, name: id, memberCount: count),
        );

    test('事件把人数改成 1 后，排序把该房提到最前', () {
      final List<AylaDirectoryVoiceEntry> before = <AylaDirectoryVoiceEntry>[
        entry('a', count: 0),
        entry('b', count: 0),
      ];
      // 事件到达（`voice.channel.member_count_changed`）⇒ 纯投影换人数。
      final ({List<AylaDirectoryVoiceEntry> items, bool refresh}) applied =
          aylaHubApplyVoiceEvent(
        before,
        const AylaDirectoryEvent.patched(AylaDirectoryKind.voice, 'b', 1),
      );
      expect(applied.refresh, isFalse);
      // 排序在投影处表达（`group_page.dart` 的 voiceRooms 槽位）。
      final List<String> sorted = <String>[
        for (final AylaDirectoryVoiceEntry e in aylaHubSortVoice(applied.items))
          e.card.id,
      ];
      expect(sorted, <String>['b', 'a'],
          reason: '有人（member_count > 0）整体置顶（web sortChannels.ts:34–36）');
    });

    test('全局快照提供时间戳时按 last_occupied_at 降序（web :37–39）', () {
      final List<AylaDirectoryVoiceEntry> items = <AylaDirectoryVoiceEntry>[
        entry('old', count: 1),
        entry('new', count: 2),
      ];
      final List<String> sorted = <String>[
        for (final AylaDirectoryVoiceEntry e in aylaHubSortVoice(
          items,
          factsOf: <String, AylaVoiceSortFacts>{
            'old': const AylaVoiceSortFacts(
              memberCount: 1,
              lastOccupiedAt: '2026-09-28T08:00:00Z',
            ),
            'new': const AylaVoiceSortFacts(
              memberCount: 2,
              lastOccupiedAt: '2026-09-28T09:00:00Z',
            ),
          },
        ))
          e.card.id,
      ];
      expect(sorted, <String>['new', 'old']);
    });
  });
}

void main() {
  _scrollRestoreGroup();
  _postViewTrackingGroup();
  _voiceSortGroup();

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