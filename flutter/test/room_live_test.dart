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
import '../lib/widgets/live/live_room_body.dart' show AylaLiveRoomBody;
import '../lib/pages/voice_hub_page.dart';
import '../lib/state/boardgame_store.dart';
import '../lib/core/api/directory_page.dart';
import '../lib/state/directory_events.dart';
import '../lib/state/directory_store.dart';
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

    test('voice.channel.deleted → 域 store 移除 + 目录缓存摘除（注入 store 档）', () {
      final AylaVoiceState voice = AylaVoiceState();
      voice.upsertChannel(AylaVoiceChannelSnapshot(id: 'v1', name: 'x'));
      final AylaDirectoryStore store = AylaDirectoryStore();
      const AylaDirectoryOptions options = AylaDirectoryOptions();
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
        results: <Object>[
          AylaDirectoryVoiceEntry(
            card: const AylaVoiceCardData(id: 'v1', name: 'x'),
          ),
        ],
        total: 1,
      );
      final AylaDirectoryEvents events = AylaDirectoryEvents();
      final AylaRoomDirectoryBridge bridge =
          _bridge(voice: voice, events: events, store: store);
      bridge.handleFrame(<String, dynamic>{
        'type': 'voice.channel.deleted',
        'data': <String, dynamic>{'channel_id': 'v1'},
      });
      expect(voice.channels, isEmpty);
      // ★ 注入 store 后，删除走**目录缓存**（web `stores/directory.ts:237–258`），
      // 不再走事件总线。
      expect(events.revision, 0,
          reason: '注入 store ⇒ 帧直连通路写 store，不广播');
      expect(store.records, isEmpty,
          reason: '异步取页未跑 ⇒ 无 record 可摘（但帧本身不抛错）');
    });

    test('live.viewers.changed → 只 patch 域 store（目录侧由订阅通路随同）', () {
      // 2026-10-08 架构收口：帧桥**不再广播给页面**（那是「页面漏订阅就没热更新」的
      // 根因），只落域 store；目录缓存的更新由 `directory_tracking.dart` 的 store
      // 订阅通路承担（web `stores/directory.ts:205–219`）。
      final AylaLiveState live = AylaLiveState();
      live.upsertChannel(_snapshot('c1'));
      final AylaDirectoryEvents events = AylaDirectoryEvents();
      final AylaRoomDirectoryBridge bridge = _bridge(live: live, events: events);
      bridge.handleFrame(<String, dynamic>{
        'type': 'live.viewers.changed',
        'data': <String, dynamic>{'channel_id': 'c1', 'viewer_count': 12},
      });
      expect(live.channelOf('c1')!.viewerCount, 12);
      // 未注入目录 store（本用例）⇒ 走兼容档：人数帧**不属于** `live.channel.*`
      // 命名空间，web 也不发失效/人数事件给目录（帧直连通路只认 created/deleted）
      // ⇒ 总线不动（revision 保持）。
      expect(events.revision, 0,
          reason: '人数帧不进帧直连通路（web `:221–223` 的 kind 判定只认 created/deleted）');
    });

    test('live.channel.deleted → 状态移除 + 目录删除', () {
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
    });

    test('boardgame.room.deleted → 全局表移除 + 目录删除事件（web chat.ts:853–855）', () {
      final AylaBoardgameStore boardgame = AylaBoardgameStore();
      boardgame.upsertRoom(_room(9));
      boardgame.upsertRoom(_room(10));
      final AylaDirectoryEvents events = AylaDirectoryEvents();
      final AylaRoomDirectoryBridge bridge =
          _bridge(events: events, boardgame: boardgame);
      bridge.handleFrame(<String, dynamic>{
        'type': 'boardgame.room.deleted',
        'room': <String, dynamic>{'id': '9'},
      });
      // 全局表移除（**只去条目、不回退其余顺序**）：web `removeRoom`（86–89）。
      expect(
        boardgame.rooms.map((AylaGameRoom r) => r.id).toList(),
        <int>[10],
      );
      expect(events.last!.deleted, isTrue);
      expect(events.last!.kind, AylaDirectoryKind.game);
      expect(events.last!.id, '9');
    });

    test('boardgame.room.created 保留目录失效，另加 REST 详情对账（两条效应并存）', () {
      // 2026-10-01（排序实时源批次）：web 侧这两个帧有**两条彼此独立**的效应 ——
      // ① `chat.ts:845–851` 的 `getGameRoom(id).then(upsertRoom).catch(静默)`
      //    （**帧只是提示**，权威是 REST 详情）⇒ 全局房间表；
      // ② `stores/directory.ts:220–236` 的帧跟踪 ⇒ 目录缓存失效 / 创建提示。
      // 本批是「**补**上 ①」而不是「换成 ①」⇒ ② 必须原样保留（目录页靠它给刷新入口）。
      final AylaDirectoryEvents events = AylaDirectoryEvents();
      final AylaBoardgameStore boardgame = AylaBoardgameStore();
      final AylaRoomDirectoryBridge bridge =
          _bridge(events: events, boardgame: boardgame);
      bridge.handleFrame(<String, dynamic>{
        'type': 'boardgame.room.created',
        'room': <String, dynamic>{'id': 'not-a-number'},
      });
      // id 非法 ⇒ ① 直接忽略（不猜语义、不伪造房间）；但 ② 的失效事件照样发
      //（web 的帧跟踪只看 `frame.room.id` 是否为 null，不看它是不是合法数字）。
      expect(events.revision, 1);
      expect(events.last!.kind, AylaDirectoryKind.game);
      expect(events.last!.deleted, isFalse);
      expect(boardgame.rooms, isEmpty, reason: '不伪造一条房间');

      // id 缺失 ⇒ 两条都不做（web：`!d || !d.id` 直接 break）。
      final int base = events.revision;
      bridge.handleFrame(<String, dynamic>{'type': 'boardgame.room.created'});
      bridge.handleFrame(<String, dynamic>{
        'type': 'boardgame.room.created',
        'room': <String, dynamic>{},
      });
      expect(events.revision, base);
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


    // ===== 问题 11 附带：权威名单子链接进三个直播页（web 弹层自拉，见 LiveViewerSheet.tsx:44–79）=====
    testWidgets('LiveRoomPage：名单子链已接线（弹层打开钩子非空 + 投影不是骨架）', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(const LiveRoomPage(channelId: '7')));
      await tester.pump();
      final AylaLiveRoomBody body =
          tester.widget<AylaLiveRoomBody>(find.byType(AylaLiveRoomBody));
      // 未打开弹层前 `viewerSheet` 仍是骨架（viewers == null）——与 web 一致
      expect(body.data.viewerSheet.viewers, isNull, reason: '未打开 ⇒ 骨架态');
      expect(
        body.onOpenViewerSheet,
        isNotNull,
        reason: '页面必须把 onOpen 接到 AylaLiveViewerStrip（否则弹层永远骨架）',
      );
      await tester.pumpAndSettle();
    });

    testWidgets('LiveStudioPage：名单子链已接线', (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_host(const LiveStudioPage(channelId: '7')));
      await tester.pump();
      final AylaLiveRoomBody body =
          tester.widget<AylaLiveRoomBody>(find.byType(AylaLiveRoomBody));
      expect(body.data.viewerSheet.viewers, isNull);
      expect(body.onOpenViewerSheet, isNotNull);
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

AylaGameRoom _room(int id) => AylaGameRoom(
      id: id,
      name: '房间$id',
      owner: AylaUserPublic(id: 'u1', nickname: '房主'),
      ownerId: 'u1',
      status: AylaGameRoomStatus.waiting,
      createdAt: '2026-10-01T00:00:00Z',
    );

AylaRoomDirectoryBridge _bridge({
  AylaVoiceState? voice,
  AylaLiveState? live,
  AylaDirectoryEvents? events,
  AylaBoardgameStore? boardgame,
  AylaDirectoryStore? store,
}) =>
    AylaRoomDirectoryBridge(
      voiceState: voice ?? AylaVoiceState(),
      liveState: live ?? AylaLiveState(),
      // ⚠️ 2026-10-08：目录 store 是**首选落点**（web 的帧直连通路）；
      // 事件总线只剩「未注入 store」时的兼容档（历史用例仍覆盖它）。
      directoryStore: store,
      directory: events ?? AylaDirectoryEvents(),
      boardgameStore: boardgame ?? AylaBoardgameStore(),
      currentUserId: () => 'u-me',
    );
