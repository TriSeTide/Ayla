/// **页面级**目录 WS 热更新回归锁 —— 用户实报的判据：
/// 「语音房列表页、直播列表页、桌游列表页、群内第 2 列侧栏的直播、群内第 2 列侧栏的语音
///   全都没有 ws 热更新」。
///
/// ## 判据（Lead 指定）
/// 页面在**不订阅任何事件**的前提下，帧到达后列表**自动**反映：
/// - 投一帧 `voice.channel.created` → **不等 60 秒、不点刷新** → 列表已含新条目；
/// - 投一帧 `boardgame.room.deleted` → 列表已移除该条；
/// - 人数/状态帧 → 行上的数字/LIVE 立即变。
///
/// ## 事实源
/// web `stores/directory.ts:143–146 / 205–219`：页面读的是**目录缓存的查询投影**，
/// 帧只落域 store，缓存由 `ensureDirectoryTracking` 的订阅通路 patch ⇒ 页面零订阅。
/// 三个大厅页（`LiveHubPage.tsx` / `VoiceHubPage.tsx` / `GamesHubPage.tsx`）
/// 都只用 `useDirectoryPage` 取数，**没有任何 `chatWS.onFrame`**。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/boardgame_api.dart' show AylaDirectoryGameEntry;
import '../lib/core/api/directory_page.dart';
import '../lib/core/api/live_api.dart' show AylaDirectoryLiveEntry;
import '../lib/core/api/voice_api.dart'
    show AylaDirectoryVoiceEntry, AylaVoiceChannelSnapshot;
import '../lib/core/models/game_room.dart'
    show AylaGameCardData, AylaGameRoom, AylaGameRoomStatus;
import '../lib/core/models/user_public.dart' show AylaUserPublic;
import '../lib/pages/games_hub_page.dart';
import '../lib/pages/live_hub_page.dart';
import '../lib/pages/voice_hub_page.dart';
import '../lib/state/boardgame_store.dart' show aylaBoardgameStore;
import '../lib/state/directory_events.dart' show AylaDirectoryKind;
import '../lib/state/directory_store.dart';
import '../lib/state/directory_tracking.dart';
import '../lib/state/live_state.dart';
import '../lib/state/voice_state.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/live/live_channel_snapshot.dart';
import '../lib/widgets/live/live_hall.dart' show AylaLiveCardData, AylaLiveStatus;
import '../lib/widgets/voice/voice_channels.dart' show AylaVoiceCardData;

Widget _host(Widget child, {Size viewport = const Size(1440, 900)}) =>
    ProviderScope(
      child: MaterialApp(
        home: Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: previewScope(child),
          ),
        ),
      ),
    );

AylaVoiceChannelSnapshot _voiceSnapshot(
  String id, {
  int memberCount = 0,
  String? createdAt,
}) =>
    AylaVoiceChannelSnapshot(
      id: id,
      name: id,
      memberCount: memberCount,
      createdAt: createdAt,
    );

AylaLiveChannelSnapshot _liveSnapshot(
  String id, {
  AylaLiveStatus? status = AylaLiveStatus.idle,
  int? viewerCount,
  String? startedAt,
}) =>
    AylaLiveChannelSnapshot(
      id: id,
      title: id,
      status: status,
      viewerCount: viewerCount,
      startedAt: startedAt,
    );

void main() {
  late AylaDirectoryStore store;
  late AylaVoiceState voice;
  late AylaLiveState live;
  late AylaDirectoryTracking tracking;

  setUp(() {
    store = aylaDirectoryStore;
    store.reset();
    store.userId = 'u1';
    voice = AylaVoiceState();
    live = AylaLiveState();
    aylaBoardgameStore.reset();
    tracking = AylaDirectoryTracking();
    tracking.start(
      voiceState: voice,
      liveState: live,
      boardgameStore: aylaBoardgameStore,
      currentUserId: () => 'u1',
      store: store,
    );
  });

  tearDown(() {
    tracking.stop();
    store.reset();
    store.userId = null;
    store.descriptorAdapters.clear();
  });

  group('VoiceHubPage：不订阅任何事件，帧到达后列表自动反映', () {
    testWidgets('voice.channel.created ⇒ 新条目立即出现（不等 60 秒、不点刷新）',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      // 页面只走「取页」：首次为空列表。
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(results: <Object>[], total: 0);

      await tester.pumpWidget(_host(const VoiceHubPage()));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('新语音房'), findsNothing, reason: '起始为空');

      // ★ 帧到达 —— 只做两件事：登记创建提示（帧直连）+ 落域 store（web 的两条通路）。
      store.noteCreated(AylaDirectoryKind.voice, 'v-new');
      voice.upsertChannel(_voiceSnapshot('v-new', createdAt: '2026-01-02'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('v-new'), findsOneWidget,
          reason: '帧到达 ⇒ 列表**立即**含新条目（这是「架构修好了」的判据）');
      await tester.pumpAndSettle();
    });

    testWidgets('voice.channel.member_count_changed ⇒ 行上人数立即变',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
        results: <Object>[
          AylaDirectoryVoiceEntry(
            card: const AylaVoiceCardData(id: 'v1', name: 'v1', memberCount: 0),
          ),
        ],
        total: 1,
        totalMemberCount: 0,
      );

      await tester.pumpWidget(_host(const VoiceHubPage()));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('0 人'), findsOneWidget);

      voice.upsertChannel(_voiceSnapshot('v1', memberCount: 4));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('4 人'), findsOneWidget, reason: '人数帧 ⇒ 卡上人数立即变');
      await tester.pumpAndSettle();
    });

    testWidgets('voice.channel.deleted ⇒ 条目立即消失', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
        results: <Object>[
          AylaDirectoryVoiceEntry(
            card: const AylaVoiceCardData(id: 'v1', name: 'v1'),
          ),
        ],
        total: 1,
      );

      await tester.pumpWidget(_host(const VoiceHubPage()));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('v1'), findsOneWidget);

      // 帧：域 store 移除 + 删除摘除（web `chat.ts:682` + `directory.ts:242–257`）。
      voice.removeChannel('v1');
      store.noteDeleted(AylaDirectoryKind.voice, 'v1');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('v1'), findsNothing, reason: '删除帧 ⇒ 条目立即消失');
      await tester.pumpAndSettle();
    });
  });

  group('LiveHubPage：不订阅任何事件，帧到达后列表自动反映', () {
    testWidgets('live.channel.created ⇒ 新条目立即出现', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(results: <Object>[], total: 0);

      await tester.pumpWidget(_host(const LiveHubPage()));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('l-new'), findsNothing);

      store.noteCreated(AylaDirectoryKind.live, 'l-new');
      live.upsertChannel(_liveSnapshot('l-new', status: AylaLiveStatus.idle));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('l-new'), findsOneWidget,
          reason: '直播列表页此前**完全没有订阅** ⇒ 这就是用户实报的修复点');
      await tester.pumpAndSettle();
    });

    testWidgets('live.channel.status.changed ⇒ LIVE 标记立即出现',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
        results: <Object>[
          AylaDirectoryLiveEntry(
            card: const AylaLiveCardData(
              id: 'l1',
              title: 'l1',
              status: AylaLiveStatus.idle,
            ),
          ),
        ],
        total: 1,
      );

      await tester.pumpWidget(_host(const LiveHubPage()));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('直播中'), findsNothing, reason: '起始未开播');

      live.upsertChannel(_liveSnapshot('l1', status: AylaLiveStatus.live,
          startedAt: '2026-01-02'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('直播中'), findsOneWidget,
          reason: '开播帧 ⇒ LIVE 徽章立即出现（无需刷新）');
      await tester.pumpAndSettle();
    });
  });

  group('GamesHubPage：不订阅任何事件，帧到达后列表自动反映', () {
    testWidgets('boardgame.room.deleted ⇒ 列表立即移除该条', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
        results: <Object>[
          AylaDirectoryGameEntry(
            card: const AylaGameCardData(id: '1', name: 'room1'),
            room: _room(1, '2026-01-02'),
          ),
          AylaDirectoryGameEntry(
            card: const AylaGameCardData(id: '2', name: 'room2'),
            room: _room(2, '2026-01-01'),
          ),
        ],
        total: 2,
      );

      await tester.pumpWidget(_host(const GamesHubPage()));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('room2'), findsOneWidget);

      aylaBoardgameStore.removeRoom(2);
      store.noteDeleted(AylaDirectoryKind.game, '2');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('room2'), findsNothing,
          reason: '`boardgame.room.deleted` ⇒ 列表立即移除（Lead 指定判据）');
      await tester.pumpAndSettle();
    });

    testWidgets('boardgame.room.created ⇒ 新房间立即出现', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(results: <Object>[], total: 0);

      await tester.pumpWidget(_host(const GamesHubPage()));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('room9'), findsNothing);

      store.noteCreated(AylaDirectoryKind.game, '9');
      aylaBoardgameStore.upsertRoom(_room(9, '2026-01-03'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('room9'), findsOneWidget);
      await tester.pumpAndSettle();
    });
  });
}

AylaGameRoom _room(int id, String createdAt) => AylaGameRoom(
      id: id,
      name: 'room$id',
      owner: const AylaUserPublic(id: 'u1'),
      ownerId: 'u1',
      status: AylaGameRoomStatus.waiting,
      createdAt: createdAt,
    );
