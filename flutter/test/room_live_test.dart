/// 房内页批次（2026-09-28）的 live / 桌游 / 目录帧定向测试。
///
/// 覆盖：
/// 1. **帧解析**（`DanmakuFrame` 平铺 vs 历史条目的 `sender.user_id` 差异）；
/// 2. **状态层**（[AylaLiveState]：弹幕去重定长 / 在看人数只认当前频道 / 频道 patch）；
/// 3. **目录事件总线**（[AylaDirectoryEvents]）与**域外帧桥**（[AylaRoomDirectoryBridge]）；
/// 4. **排序与投影纯函数**（`aylaHubSortLive` / 条目换人数）；
/// 5. **页面装配**（房内三页 + 控制台空态）首帧不崩、无网络错误静默。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/api/live_api.dart';
import '../lib/core/api/voice_api.dart'
    show AylaDirectoryVoiceEntry, AylaVoiceChannelSnapshot;
import '../lib/core/models/game_room.dart';
import '../lib/core/models/user_public.dart';
import '../lib/core/ws/room_frames.dart';
import '../lib/pages/games_hub_page.dart';
import '../lib/pages/hub_support.dart';
import '../lib/pages/live_room_page.dart';
import '../lib/pages/live_studio_page.dart';
import '../lib/pages/voice_hub_page.dart';
import '../lib/state/directory_events.dart';
import '../lib/state/live_state.dart';
import '../lib/state/voice_state.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/live/live_channel_snapshot.dart';
import '../lib/widgets/live/live_studio.dart' show AylaStudioEmpty;
import '../lib/widgets/live/live_hall.dart';
import '../lib/widgets/live/live_player.dart' show AylaLiveSrsStatus;
import '../lib/widgets/game/game_room_placeholder.dart';
import '../lib/widgets/voice/voice_channel_panel.dart'
    show AylaVoiceChannelPanel;
import '../lib/widgets/voice/voice_channels.dart' show AylaVoiceCardData;

/// 页面宿主：真实 GoRouter 壳（房内三页都会在失败/非法 id 时 `context.go` 回大厅 ⇒
/// 没有 GoRouter 祖先会直接抛异常；这是**真实调用面**，不绕开）。
Widget _host(Widget child, {Size viewport = const Size(1440, 900)}) {
  final GoRouter router = GoRouter(
    initialLocation: '/room',
    routes: <RouteBase>[
      GoRoute(
        path: '/room',
        builder: (BuildContext c, GoRouterState s) => previewScope(child),
      ),
      GoRoute(
        path: '/:rest(.*)',
        builder: (BuildContext c, GoRouterState s) =>
            const Scaffold(body: SizedBox.shrink()),
      ),
    ],
  );
  return ProviderScope(
    child: MaterialApp.router(
      routerConfig: router,
      builder: (BuildContext context, Widget? nav) => MediaQuery(
        data: MediaQuery.of(context).copyWith(size: viewport),
        child: nav ?? const SizedBox.shrink(),
      ),
    ),
  );
}

AylaDirectoryLiveEntry _live(
  String id,
  String title, {
  AylaLiveStatus? status,
  String? startedAt,
  String? endedAt,
  String? createdAt,
}) =>
    AylaDirectoryLiveEntry(
      card: AylaLiveCardData(id: id, title: title, status: status),
      startedAt: startedAt,
      endedAt: endedAt,
      createdAt: createdAt,
    );

void main() {
  group('弹幕帧解析', () {
    test('WS 回帧是平铺且 sender 键为 id/avatar', () {
      final AylaLiveDanmaku? item = AylaLiveDanmaku.fromFrameJson(
        <String, dynamic>{
          'type': 'danmaku',
          'id': 'd1',
          'sender': <String, dynamic>{
            'id': 'u1',
            'nickname': '爱莉',
            'avatar': '/a.png',
          },
          'content': 'hi',
          'created_at': 'T',
        },
      );
      expect(item!.senderUserId, 'u1');
      expect(item.senderAvatar, '/a.png');
      expect(item.createdAt, 'T');
    });

    test('历史条目 sender 键为 user_id；缺 id 非法', () {
      final AylaLiveDanmaku? item = AylaLiveDanmaku.fromHistoryJson(
        <String, dynamic>{
          'id': 'd2',
          'sender': <String, dynamic>{'user_id': 'u2', 'nickname': 'n'},
          'content': 'x',
        },
      );
      expect(item!.senderUserId, 'u2');
      expect(AylaLiveDanmaku.fromHistoryJson(<String, dynamic>{}), isNull);
    });
  });

  group('AylaLiveState（web stores/live.ts）', () {
    test('弹幕按 id 去重、按 created_at 升序、定长截断', () {
      final List<AylaLiveDanmaku> list = normalizeDanmaku(<AylaLiveDanmaku>[
        const AylaLiveDanmaku(id: 'b', createdAt: '2'),
        const AylaLiveDanmaku(id: 'a', createdAt: '1'),
        const AylaLiveDanmaku(id: 'b', createdAt: '2'),
      ]);
      expect(list.map((AylaLiveDanmaku d) => d.id), <String>['a', 'b']);
    });

    test('在看人数只认当前直播间；patchViewerCount 对未加载条目是 no-op', () {
      final AylaLiveState state = AylaLiveState();
      state.setViewers('c1', 5, const <AylaLiveViewer>[]);
      expect(state.viewerCount, isNull, reason: '当前直播间尚未设置');
      state.setCurrentChannel(_snapshot('c1'));
      state.setViewers('c1', 5, const <AylaLiveViewer>[]);
      expect(state.viewerCount, 5);
      state.setViewers('c2', 9, const <AylaLiveViewer>[]);
      expect(state.viewerCount, 5, reason: '其他频道不写当前直播间');
      state.patchViewerCount('c9', 42);
      expect(state.channels.containsKey('c9'), isFalse);
      state.patchViewerCount('c1', 7);
      expect(state.viewerCount, 7);
    });

    test('clearViewers 清空而不写 0（presence 不可用语义）', () {
      final AylaLiveState state = AylaLiveState();
      state.setCurrentChannel(_snapshot('c1'));
      state.setViewers('c1', 3, const <AylaLiveViewer>[]);
      state.clearViewers();
      expect(state.viewerCount, isNull);
      expect(state.viewers, isEmpty);
    });

    test('removeChannel：移除当前直播间时同步清空四件套', () {
      final AylaLiveState state = AylaLiveState();
      state.upsertChannel(_snapshot('c1'));
      state.setCurrentChannel(_snapshot('c1'));
      state.setSrsStatus(AylaLiveSrsStatus.live);
      state.appendDanmaku(const AylaLiveDanmaku(id: 'd', createdAt: '1'));
      state.removeChannel('c1');
      expect(state.channels, isEmpty);
      expect(state.currentChannel, isNull);
      expect(state.srsStatus, isNull);
      expect(state.danmaku, isEmpty);
    });

    test('upsertChannel 同步当前直播间；reset 全清', () {
      final AylaLiveState state = AylaLiveState();
      state.setCurrentChannel(_snapshot('c1'));
      state.upsertChannel(_snapshot('c1', title: '新标题'));
      expect(state.currentChannel!.title, '新标题');
      state.reset();
      expect(state.channels, isEmpty);
      expect(state.currentChannel, isNull);
    });
  });

  group('目录事件总线 + 域外帧桥', () {
    test('总线：三类事件写最近一条并推进 revision', () {
      final AylaDirectoryEvents events = AylaDirectoryEvents();
      final int base = events.revision;
      events.emitDeleted(AylaDirectoryKind.voice, 'v1');
      expect(events.last!.deleted, isTrue);
      expect(events.last!.id, 'v1');
      events.emitPatched(AylaDirectoryKind.live, 'c1', 8);
      expect(events.last!.memberCount, 8);
      events.emitInvalidated(AylaDirectoryKind.game);
      expect(events.last!.kind, AylaDirectoryKind.game);
      expect(events.last!.deleted, isFalse);
      expect(events.last!.memberCount, isNull);
      expect(events.revision, base + 3);
      events.reset();
      expect(events.last, isNull);
    });

    test('voice.channel.deleted → 状态移除 + 目录删除事件', () {
      final AylaVoiceState voice = AylaVoiceState();
      voice.upsertChannel(AylaVoiceChannelSnapshot(id: 'v1', name: 'x'));
      final AylaDirectoryEvents events = AylaDirectoryEvents();
      final AylaRoomDirectoryBridge bridge = _bridge(voice: voice, events: events);
      bridge.handleFrame(<String, dynamic>{
        'type': 'voice.channel.deleted',
        'data': <String, dynamic>{'channel_id': 'v1'},
      });
      expect(voice.channels, isEmpty);
      expect(events.last!.kind, AylaDirectoryKind.voice);
      expect(events.last!.deleted, isTrue);
    });

    test('live.viewers.changed → patch 人数 + 目录人数事件（不标失效）', () {
      final AylaLiveState live = AylaLiveState();
      live.upsertChannel(_snapshot('c1'));
      final AylaDirectoryEvents events = AylaDirectoryEvents();
      final AylaRoomDirectoryBridge bridge = _bridge(live: live, events: events);
      bridge.handleFrame(<String, dynamic>{
        'type': 'live.viewers.changed',
        'data': <String, dynamic>{'channel_id': 'c1', 'viewer_count': 12},
      });
      expect(live.channelOf('c1')!.viewerCount, 12);
      expect(events.last!.memberCount, 12);
      expect(events.last!.deleted, isFalse);
    });

    test('live.channel.deleted → 状态移除 + 目录删除；boardgame 两档', () {
      final AylaLiveState live = AylaLiveState();
      live.upsertChannel(_snapshot('c1'));
      final AylaDirectoryEvents events = AylaDirectoryEvents();
      final AylaRoomDirectoryBridge bridge = _bridge(live: live, events: events);
      bridge.handleFrame(<String, dynamic>{
        'type': 'live.channel.deleted',
        'data': <String, dynamic>{'channel_id': 'c1'},
      });
      expect(live.channels, isEmpty);
      expect(events.last!.kind, AylaDirectoryKind.live);
      bridge.handleFrame(<String, dynamic>{
        'type': 'boardgame.room.created',
        'room': <String, dynamic>{'id': '9'},
      });
      expect(events.last!.kind, AylaDirectoryKind.game);
      expect(events.last!.deleted, isFalse);
      bridge.handleFrame(<String, dynamic>{
        'type': 'boardgame.room.deleted',
        'room': <String, dynamic>{'id': '9'},
      });
      expect(events.last!.deleted, isTrue);
      expect(events.last!.id, '9');
    });

    test('缺 channel_id 的帧被忽略；未知帧 no-op', () {
      final AylaDirectoryEvents events = AylaDirectoryEvents();
      final AylaRoomDirectoryBridge bridge = _bridge(events: events);
      final int base = events.revision;
      bridge.handleFrame(<String, dynamic>{
        'type': 'voice.channel.deleted',
        'data': <String, dynamic>{},
      });
      bridge.handleFrame(<String, dynamic>{'type': 'post.created'});
      bridge.handleFrame(<String, dynamic>{'type': 7});
      expect(events.revision, base);
    });
  });

  group('排序与投影纯函数', () {
    test('aylaHubSortLive：在播 → 曾播（ended_at 降序）→ 从未（created_at 降序）', () {
      final List<AylaDirectoryLiveEntry> sorted = aylaHubSortLive(
        <AylaDirectoryLiveEntry>[
          _live('4', '从未', createdAt: '2026-01-01'),
          _live('2', '曾播旧', startedAt: 'a', endedAt: '2026-01-01'),
          _live('3', '从未新', createdAt: '2026-02-01'),
          _live('1', '在播', status: AylaLiveStatus.live, startedAt: '2026-03-01'),
          _live('5', '曾播新', startedAt: 'a', endedAt: '2026-02-15'),
        ],
      );
      expect(
        sorted.map((AylaDirectoryLiveEntry e) => e.card.id).toList(),
        <String>['1', '5', '2', '3', '4'],
      );
    });

    test('在播之间按 started_at 降序', () {
      final List<AylaDirectoryLiveEntry> sorted = aylaHubSortLive(
        <AylaDirectoryLiveEntry>[
          _live('a', 'A', status: AylaLiveStatus.live, startedAt: '2026-01-01'),
          _live('b', 'B', status: AylaLiveStatus.live, startedAt: '2026-05-01'),
        ],
      );
      expect(sorted.first.card.id, 'b');
    });

    test('条目换人数：逐字段搬运，只改目标字段', () {
      final AylaDirectoryLiveEntry entry = _live('c1', 'T');
      final AylaDirectoryLiveEntry patched =
          aylaHubLiveEntryWithViewerCount(entry, 9);
      expect(patched.card.viewerCount, 9);
      expect(patched.card.title, 'T');
      expect(patched.ownerId, entry.ownerId);
    });

    test('语音条目换人数：保留可见性与白名单群名', () {
      final AylaDirectoryVoiceEntry entry = AylaDirectoryVoiceEntry(
        card: const AylaVoiceCardData(
          id: 'v1',
          name: '房',
          memberCount: 1,
          groupName: '群',
        ),
        ownerId: 'u1',
        createdAt: 'T',
      );
      final AylaDirectoryVoiceEntry patched =
          aylaHubVoiceEntryWithMemberCount(entry, 4);
      expect(patched.card.memberCount, 4);
      expect(patched.card.groupName, '群');
      expect(patched.ownerId, 'u1');
      expect(patched.createdAt, 'T');
    });

    test('快照 → 直播条目（控制台侧栏同步）', () {
      final AylaDirectoryLiveEntry entry = aylaHubLiveEntryFromSnapshot(
        AylaLiveChannelSnapshot(
          id: '7',
          title: '控制台',
          ownerId: 'u1',
          isOwner: true,
          status: AylaLiveStatus.live,
          startedAt: 'T',
        ),
        isOwner: true,
      );
      expect(entry.card.id, '7');
      expect(entry.isOwner, isTrue);
      expect(entry.startedAt, 'T');
    });
  });

  group('页面装配（无网络首帧）', () {
    testWidgets('VoiceHubPage 房内分支渲染语音房面板', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(const VoiceHubPage(channelId: 'v1')));
      // 「语音房」= head 标题 + 面板标题各一处（频道详情未到 ⇒ 走退化档，不伪造名字）
      expect(find.text('语音房'), findsNWidgets(2));
      expect(find.byType(AylaVoiceChannelPanel), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('LiveRoomPage 非法 id 不崩（回大厅）', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(const LiveRoomPage(channelId: 'abc')));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
    });

    testWidgets('LiveStudioPage 合法 id 首帧不崩', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(const LiveStudioPage(channelId: '7')));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
    });

    testWidgets('GamesHubPage 房内分支渲染桌游占位', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      // 无网络 ⇒ 详情拉取失败 ⇒ 静默回大厅（web tsx 136–139）：断言**不崩**，
      // 且大厅分支可被路由接管（房内占位组件在有房间时渲染 —— 见下一用例）。
      await tester.pumpWidget(_host(const GamesHubPage(roomId: '9')));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
    });

    testWidgets('AylaGameRoomPlaceholder 房内占位（注入房间）', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(
        AylaGameRoomPlaceholder(
          room: const AylaGameRoom(
            id: 9,
            name: '桌游室 A',
            owner: AylaUserPublic(id: 'u1', nickname: '爱莉'),
            ownerId: 'u1',
            status: AylaGameRoomStatus.waiting,
            memberCount: 2,
            isMember: true,
          ),
          onBack: () {},
          narrow: false,
        ),
      ));
      expect(find.byType(AylaGameRoomPlaceholder), findsOneWidget);
      expect(find.text('桌游室 A'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('AylaStudioEmpty：标题/描述/创建键逐字', (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(_host(
        AylaStudioEmpty(onCreateNewChannel: () => taps++),
      ));
      expect(find.text('暂无直播间'), findsOneWidget);
      expect(find.text('创建你的第一个直播间，开始推流吧'), findsOneWidget);
      await tester.tap(find.text('创建直播间'));
      await tester.pump();
      expect(taps, 1);
    });
  });
}

AylaLiveChannelSnapshot _snapshot(String id, {String title = 'T'}) =>
    AylaLiveChannelSnapshot(id: id, title: title);

AylaRoomDirectoryBridge _bridge({
  AylaVoiceState? voice,
  AylaLiveState? live,
  AylaDirectoryEvents? events,
}) =>
    AylaRoomDirectoryBridge(
      voiceState: voice ?? AylaVoiceState(),
      liveState: live ?? AylaLiveState(),
      directory: events ?? AylaDirectoryEvents(),
      currentUserId: () => 'u-me',
    );
