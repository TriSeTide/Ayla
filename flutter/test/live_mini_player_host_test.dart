/// 窄屏浮动小窗宿主（`AppShell.tsx:131–132`）+ 小窗运行时语义（`liveSessionRuntime.ts:299–317 / 533–537`）。
///
/// ## 覆盖（6 条，逐条对齐 web）
/// ① 窄屏 + `miniPlayer` 非空 ⇒ 渲染 `AylaLiveMiniPlayer`；**宽屏同状态不渲染**
///    （web 只在 `AppShell.tsx:132` 的 `isNarrow` 分支渲染）；
/// ② `miniPlayer == null` ⇒ 不渲染；
/// ③ 窄屏离开直播间页（直播中）⇒ 置位（web `detachView` 的窄屏判定）；
/// ④ 小窗模式下直播结束 ⇒ 清位 + 完整销毁（web `:533–537`）；
/// ⑤ 关闭小窗 ⇒ 清位且**幂等**（web `LiveMiniPlayer.tsx:93–96`）；
/// ⑥ 同一时刻至多一个 owner（第二个会话接管前先销毁旧小窗会话）。
///
/// 壳层宿主自建最小 GoRouter（不 import 整张路由表，同 `app_shell_fabs_test.dart`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/api/live_api.dart';
import '../lib/core/ws/live_ws.dart';
import '../lib/layout/app_shell.dart';
import '../lib/pages/live_support.dart';
import '../lib/player/hls_player.dart';
import '../lib/state/live_state.dart';
import '../lib/state/room_providers.dart';
import '../lib/theme/app_theme.dart';
import '../lib/widgets/live/live_channel_snapshot.dart';
import '../lib/widgets/live/live_hall.dart' show AylaLiveStatus;
import '../lib/widgets/live/live_mini_player.dart';
import '../lib/widgets/live/live_player.dart' show AylaLiveSrsStatus;

/// 平台播放器桩（不碰真实解码；`buildView` 给一个可渲染面）。
class _FakePlatformPlayer implements HlsPlatformPlayer {
  bool disposed = false;

  @override
  void Function(HlsState state)? onStateChange;
  @override
  void Function()? onStall;
  @override
  void Function()? onResume;
  @override
  void Function(String detail)? onFatal;

  @override
  Future<void> attach(String url) async {}
  @override
  Future<void> play() async {}
  @override
  Future<bool> seekToLiveEdge() async => true;
  @override
  Widget? buildView() => const ColoredBox(color: Color(0xFF2A3550));
  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

HlsPlaybackController _fakePlayerFactory() =>
    HlsPlaybackController(_FakePlatformPlayer.new, HlsPlayerCallbacks());

/// 三个读取端点的桩（可切换 SRS 判定 ⇒ 驱动「直播结束」分支）。
class _LiveStub {
  AylaLiveSrsStatus srsStatus = AylaLiveSrsStatus.live;

  Future<AylaLiveChannelSnapshot> channel(String id) async =>
      AylaLiveChannelSnapshot(
        id: id,
        title: '深夜电台',
        hlsUrl: 'https://cdn.example/$id.m3u8',
        status: AylaLiveStatus.live,
      );

  Future<AylaLiveStatusResult> status(String id) async =>
      AylaLiveStatusResult(status: srsStatus);

  Future<AylaLiveViewersResult> viewers(String id) async =>
      AylaLiveViewersResult(channelId: id, count: 0);
}

AylaLiveRoomSession _session(
  AylaLiveState live,
  _LiveStub stub, {
  String channelId = 'c1',
}) =>
    AylaLiveRoomSession(
      channelId: channelId,
      liveState: live,
      // token 为 null ⇒ `connect()` 是 no-op（`live_ws.dart:90–92`），不建真实连接。
      liveWs: AylaLiveWsClient(accessToken: () => null),
      channelFetcher: stub.channel,
      statusFetcher: stub.status,
      viewersFetcher: stub.viewers,
      playerFactory: _fakePlayerFactory,
    );

const AylaLiveMiniPlayerState _mini = AylaLiveMiniPlayerState(
  channelId: 'c1',
  sourceRoute: '/live/c1',
  channel: AylaLiveChannelSnapshot(id: 'c1', title: '深夜电台'),
);

/// 窄屏/宽屏壳层宿主（`AppShell` 读 `GoRouterState.of(context)` ⇒ 必须给路由环境）。
Future<void> _pumpShell(
  WidgetTester tester, {
  required Size viewport,
  required AylaLiveMiniPlayerState? mini,
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final ProviderContainer container = ProviderContainer();
  addTearDown(container.dispose);
  if (mini != null) {
    container.read(liveStateProvider).setMiniPlayer(mini);
  }
  final GoRouter router = GoRouter(
    initialLocation: '/group',
    routes: <RouteBase>[
      ShellRoute(
        builder: (BuildContext c, GoRouterState s, Widget child) =>
            AppShell(child: child),
        routes: <RouteBase>[
          GoRoute(
            path: '/group',
            builder: (BuildContext c, GoRouterState s) =>
                const SizedBox.shrink(),
          ),
          GoRoute(
            path: '/live/:channelId',
            builder: (BuildContext c, GoRouterState s) =>
                const SizedBox.shrink(),
          ),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        theme: buildAylaTheme(),
        builder: (BuildContext context, Widget? child) => Scaffold(
          backgroundColor: Colors.transparent,
          body: child,
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  group('窄屏浮动小窗宿主（AppShell.tsx:46 / 131–132）', () {
    testWidgets('① 窄屏 + miniPlayer 非空 ⇒ 渲染小窗', (WidgetTester tester) async {
      await _pumpShell(tester, viewport: const Size(375, 812), mini: _mini);

      expect(find.byType(AylaLiveMiniPlayer), findsOneWidget);
      expect(
        tester
            .widget<AylaLiveMiniPlayer>(find.byType(AylaLiveMiniPlayer))
            .channelTitle,
        '深夜电台',
        reason: 'LiveMiniPlayer.tsx:195 —— title = mini.channel?.title ?? "直播间"',
      );
    });

    testWidgets('① 宽屏同状态 ⇒ **不**渲染小窗（web 只在 isNarrow 渲染）', (
      WidgetTester tester,
    ) async {
      await _pumpShell(tester, viewport: const Size(1440, 900), mini: _mini);

      expect(find.byType(AylaLiveMiniPlayer), findsNothing);
    });

    testWidgets('② miniPlayer == null ⇒ 不渲染小窗', (WidgetTester tester) async {
      await _pumpShell(tester, viewport: const Size(375, 812), mini: null);

      expect(find.byType(AylaLiveMiniPlayer), findsNothing);
    });
  });

  group('小窗运行时语义（liveSessionRuntime.ts:299–317 / 533–537）', () {
    test('③ 窄屏 + 直播中 detachView ⇒ 置位，且会话**不销毁**', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      final AylaLiveRoomSession session = _session(live, stub);
      addTearDown(() async {
        await aylaCloseLiveMiniPlayer();
        live.dispose();
      });

      await session.start();
      expect(live.srsStatus, AylaLiveSrsStatus.live);

      await session.detachView(isNarrow: true);

      expect(live.miniPlayer, isNotNull);
      expect(live.miniPlayer!.channelId, 'c1');
      expect(live.miniPlayer!.sourceRoute, '/live/c1');
      expect(live.miniPlayer!.title, '深夜电台');
      expect(
        identical(aylaMiniPlayerOwner, session),
        isTrue,
        reason: '会话所有权移交给小窗宿主（唯一 owner）',
      );
      expect(session.alive, isTrue, reason: '进小窗不销毁会话（web 不 leave）');
    });

    test('③ 宽屏 detachView ⇒ 不置位且完整销毁', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      final AylaLiveRoomSession session = _session(live, stub);
      addTearDown(() async {
        await aylaCloseLiveMiniPlayer();
        live.dispose();
      });

      await session.start();
      await session.detachView(isNarrow: false);

      expect(live.miniPlayer, isNull);
      expect(aylaMiniPlayerOwner, isNull);
      expect(session.alive, isFalse, reason: '宽屏不开小窗 ⇒ leave 语义');
    });

    test('③ 窄屏但主播控制台（isOwnerConsole）⇒ 不置位', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      final AylaLiveRoomSession session = _session(live, stub);
      addTearDown(() async {
        await aylaCloseLiveMiniPlayer();
        live.dispose();
      });

      await session.start();
      await session.detachView(isNarrow: true, isOwnerConsole: true);

      expect(live.miniPlayer, isNull, reason: 'web isOwnerConsole 档不触发小窗');
      expect(session.alive, isFalse);
    });

    test('④ 小窗模式下直播结束 ⇒ 清位并完整销毁（current 复位 ⇒ srsStatus 归 null）', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      final AylaLiveRoomSession session = _session(live, stub);
      addTearDown(() async {
        await aylaCloseLiveMiniPlayer();
        live.dispose();
      });

      await session.start();
      await session.detachView(isNarrow: true);
      expect(live.miniPlayer, isNotNull);

      // 直播结束：SRS 实时判定转为 idle（`refreshSrsStatus` 的补拉结果）
      stub.srsStatus = AylaLiveSrsStatus.idle;
      await session.refreshSrsStatus();

      expect(live.miniPlayer, isNull, reason: 'web liveSessionRuntime.ts:533–537');
      expect(aylaMiniPlayerOwner, isNull);
      expect(session.alive, isFalse);
      // ⚠️ 终态断言必须是**复位后**的值：销毁路径 = web `leave()` → `clearCurrent()`，
      // 而 `clearCurrent` 把 `current` 整体复位为 `initialRoom`（`stores/live.ts:99–105 /
      // 250–258`，`initialRoom.srsStatus = null`）⇒ 刚写入的 idle 判定随会话被清回 null。
      expect(live.srsStatus, isNull, reason: 'web leave() 的 clearCurrent 复位 current');
      expect(live.currentChannel, isNull, reason: '同一条 clearCurrent 的产物');
    });

    test('④′ 非小窗直播结束 ⇒ `srsStatus` 保持 idle（只卸播放器，不复位 current）', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      final AylaLiveRoomSession session = _session(live, stub);
      addTearDown(() async {
        await session.stop();
        session.dispose();
        live.dispose();
      });

      await session.start();
      expect(live.srsStatus, AylaLiveSrsStatus.live);

      stub.srsStatus = AylaLiveSrsStatus.idle;
      await session.refreshSrsStatus();

      expect(
        live.srsStatus,
        AylaLiveSrsStatus.idle,
        reason: '判定写入 store；非小窗不做 leave ⇒ current 不被复位（对照 ④）',
      );
      expect(live.currentChannel, isNotNull);
      expect(
        session.alive,
        isTrue,
        reason: '非小窗结束只卸播放器（web 不 leave），会话仍归页面持有',
      );
      expect(live.miniPlayer, isNull);
      expect(aylaMiniPlayerOwner, isNull);
    });

    test('⑤ 关闭小窗 ⇒ 清位 + 完整销毁；重入幂等', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      final AylaLiveRoomSession session = _session(live, stub);
      addTearDown(live.dispose);

      await session.start();
      await session.detachView(isNarrow: true);
      expect(live.miniPlayer, isNotNull);

      await aylaCloseLiveMiniPlayer();

      expect(live.miniPlayer, isNull);
      expect(aylaMiniPlayerOwner, isNull);
      expect(session.alive, isFalse);

      // 幂等：再关一次不抛错、状态不变（web 的 leave 无会话时静默返回）
      await aylaCloseLiveMiniPlayer();
      expect(live.miniPlayer, isNull);
      expect(aylaMiniPlayerOwner, isNull);
    });

    test('⑥ 同一时刻至多一个 owner（第二个会话接管前先销毁旧小窗会话）', () async {
      final AylaLiveState live = AylaLiveState();
      addTearDown(() async {
        await aylaCloseLiveMiniPlayer();
        live.dispose();
      });

      final AylaLiveRoomSession first = _session(live, _LiveStub());
      await first.start();
      await first.detachView(isNarrow: true);
      expect(identical(aylaMiniPlayerOwner, first), isTrue);

      // 「点回直播间」= 新页面级会话接管：先让小窗让位（完整销毁旧会话）
      final AylaLiveRoomSession second = _session(live, _LiveStub());
      await second.start();

      expect(first.alive, isFalse, reason: '小窗让位：旧会话必须被销毁');
      expect(aylaMiniPlayerOwner, isNull, reason: '旧 owner 摘牌后新会话尚未进小窗');

      await second.detachView(isNarrow: true);
      expect(identical(aylaMiniPlayerOwner, second), isTrue);
      expect(live.miniPlayer!.channelId, 'c1');
    });

    test('⑦ 切台/新旧页并存：被更晚的会话接管后，迟到的 detachView 不置位小窗', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      addTearDown(() async {
        await aylaCloseLiveMiniPlayer();
        live.dispose();
      });

      final AylaLiveRoomSession previous = _session(live, stub);
      await previous.start();

      // 路由替换到另一个直播间：新页面先 start（旧页面尚未跑 detachView）
      final AylaLiveRoomSession next = _session(live, stub, channelId: 'c2');
      await next.start();

      // 迟到的视图分离：旧会话已被接管 ⇒ 完整销毁，不进小窗
      await previous.detachView(isNarrow: true);

      expect(live.miniPlayer, isNull, reason: '不得把已被接管的旧会话挂成小窗');
      expect(aylaMiniPlayerOwner, isNull);
      expect(previous.alive, isFalse);
      expect(next.alive, isTrue);

      await next.detachView(isNarrow: false); // 收尾：宽屏 ⇒ 完整销毁
    });
  });
}
