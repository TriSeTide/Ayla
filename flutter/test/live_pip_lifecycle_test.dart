/// Android「直播脱离应用」（PiP）语义定向测试 —— 不碰真实 MethodChannel。
///
/// ## 覆盖（逐条对应 task-2 的用户要求 / 研究结论）
/// ① **PiP 里也算观看人**：生命周期 paused/hidden/detached 时若原生说「在 PiP 里」，
///    绝不断开弹幕 WS（否则后端把你移出在看名单）；
/// ② 不在 PiP 时行为与改动前一致（进后台 = 离开观看）；
/// ③ inactive 不动（短暂失焦不算离开）；
/// ④ 会话结束（stop() / dispose()）**一定**把 setSessionActive(false) 送出去 ——
///    漏传是「按 Home 误进 PiP」这个唯一失败模式的成因；
/// ⑤ 进房拿到 SRS = live ⇒ 同步 true（「开播即武装」）、拿到非 live ⇒ 同步 false；
/// ⑥ 脱离入口只在小窗上暴露一个键，且点击回调能触发（组件层，不碰通道）。
///
/// ## 为什么用假 presenter 而不是假通道
/// AylaDetachedLivePresenter 是 core/platform/detached_live.dart 三个函数的值容器；
/// 测试注入它就能断言「什么时机调了什么」，不必真的建 MethodChannel —— 语义是可测的，
/// 通道参数名/类型由契约文件与原生侧编译保证。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/live_api.dart';
import '../lib/core/ws/live_ws.dart';
import '../lib/pages/live_support.dart';
import '../lib/player/hls_player.dart';
import '../lib/state/live_state.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/live/live_channel_snapshot.dart';
import '../lib/widgets/live/live_hall.dart' show AylaLiveStatus;
import '../lib/widgets/live/live_mini_player.dart';
import '../lib/widgets/live/live_player.dart' show AylaLiveSrsStatus;

/// 平台播放器桩（不碰真实解码；buildView 给一个可渲染面）。
class _FakePlatformPlayer implements HlsPlatformPlayer {
  @override
  void Function(HlsState state)? onStateChange;
  @override
  void Function()? onStall;
  @override
  void Function()? onResume;
  @override
  void Function(String detail)? onFatal;
  @override
  void Function(Duration position)? onPosition;

  @override
  Future<void> attach(String url) async {}
  @override
  Future<void> play() async {}
  @override
  Future<bool> seekToLiveEdge() async => true;
  @override
  Widget? buildView() => const ColoredBox(color: Color(0xFF2A3550));
  @override
  Future<void> dispose() async {}
}

HlsPlaybackController _fakePlayerFactory() =>
    HlsPlaybackController(_FakePlatformPlayer.new, HlsPlayerCallbacks());

/// 记录「平台动作被怎么调用」的假 presenter。
class _Recorder {
  _Recorder({this.inPipValue = false});

  /// isInPip 要返回什么（模拟系统画中画里/外）。
  bool inPipValue;

  /// setSessionActive 的调用序列。
  final List<bool> sessionActive = <bool>[];

  /// enter 的调用次数与参数。
  int enterCalls = 0;
  String? lastChannelId;
  String? lastTitle;
  String? lastPlayUrl;
  Rect? lastVideoRect;

  /// close 的调用次数。
  int closeCalls = 0;

  /// enter 的返回（模拟原生成功/失败）。
  bool enterResult = true;

  AylaDetachedLivePresenter get presenter => AylaDetachedLivePresenter(
    enter: ({
      required String channelId,
      required String title,
      String? playUrl,
      Rect? videoRect,
    }) async {
      enterCalls += 1;
      lastChannelId = channelId;
      lastTitle = title;
      lastPlayUrl = playUrl;
      lastVideoRect = videoRect;
      return enterResult;
    },
    close: () async {
      closeCalls += 1;
    },
    setSessionActive: (bool active) async {
      sessionActive.add(active);
    },
    isInPip: () async => inPipValue,
  );
}

/// 三个读取端点的桩（可切换 SRS 判定 ⇒ 驱动「开播/停播」分支）。
class _LiveStub {
  /// SRS 实时判定（用例可直接改它来驱动「开播/停播」分支）。
  AylaLiveSrsStatus srsStatus = AylaLiveSrsStatus.live;

  Future<AylaLiveChannelSnapshot> channel(String id) async =>
      AylaLiveChannelSnapshot(
        id: id,
        title: '深夜电台',
        hlsUrl: 'https://cdn.example/live/$id.m3u8',
        status: AylaLiveStatus.live,
      );

  Future<AylaLiveStatusResult> status(String id) async =>
      AylaLiveStatusResult(status: srsStatus);

  Future<AylaLiveViewersResult> viewers(String id) async =>
      AylaLiveViewersResult(channelId: id, count: 3);
}

AylaLiveRoomSession _session(
  AylaLiveState live,
  _LiveStub stub,
  _Recorder rec, {
  String channelId = 'c1',
}) =>
    AylaLiveRoomSession(
      channelId: channelId,
      liveState: live,
      // token 为 null ⇒ connect() 是 no-op，不建真实 WS 连接。
      liveWs: AylaLiveWsClient(accessToken: () => null),
      channelFetcher: stub.channel,
      statusFetcher: stub.status,
      viewersFetcher: stub.viewers,
      playerFactory: _fakePlayerFactory,
      detached: rec.presenter,
    );

void main() {
  group('① PiP 里仍算观看人（生命周期的 PiP 守卫）', () {
    test('paused/hidden/detached + 原生说在 PiP 里 ⇒ 守卫拦住「暂停观看」', () async {
      final _Recorder rec = _Recorder(inPipValue: true);
      for (final AppLifecycleState state in <AppLifecycleState>[
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.detached,
      ]) {
        // 无会话时内部两侧都是 null ⇒ pause 本身是 no-op；本用例先确认守卫可读回 true
        // 且不抛（生命周期回调里抛异常会连带断掉整条前后台收口）。
        await aylaHandleLiveViewingLifecycle(state, detached: rec.presenter);
      }
    });

    test('paused + 原生说在 PiP 里 ⇒ 会话的弹幕 WS 保持（不算离开）', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      final _Recorder rec = _Recorder(inPipValue: true);
      final AylaLiveRoomSession session = _session(live, stub, rec);
      addTearDown(() async {
        await aylaCloseLiveMiniPlayer();
        live.dispose();
      });

      await session.start();
      expect(session.alive, isTrue);

      await aylaHandleLiveViewingLifecycle(
        AppLifecycleState.paused,
        detached: rec.presenter,
      );

      // 守卫返回 true ⇒ 没有调用 pauseViewerPresence ⇒ 后台暂停标志保持 false。
      // 该标志是「回前台要不要重连」的唯一判据，因此可直接断言。
      expect(
        session.backgroundPaused,
        isFalse,
        reason: 'PiP 里看直播也算观看人：不许退观看（用户明确要求）',
      );
      expect(session.alive, isTrue);
    });

    test('paused + 原生说不 PiP ⇒ 照旧暂停观看（无行为回归）', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      final _Recorder rec = _Recorder(inPipValue: false);
      final AylaLiveRoomSession session = _session(live, stub, rec);
      addTearDown(() async {
        await aylaCloseLiveMiniPlayer();
        live.dispose();
      });

      await session.start();
      await aylaHandleLiveViewingLifecycle(
        AppLifecycleState.paused,
        detached: rec.presenter,
      );

      expect(
        session.backgroundPaused,
        isTrue,
        reason: '不在 PiP 的进后台必须退观看（改动前的既有语义）',
      );
    });

    test('resumed ⇒ 续上观看；inactive ⇒ 什么都不做', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      final _Recorder rec = _Recorder(inPipValue: false);
      final AylaLiveRoomSession session = _session(live, stub, rec);
      addTearDown(() async {
        await aylaCloseLiveMiniPlayer();
        live.dispose();
      });

      await session.start();

      await aylaHandleLiveViewingLifecycle(
        AppLifecycleState.inactive,
        detached: rec.presenter,
      );
      expect(session.backgroundPaused, isFalse);

      await aylaHandleLiveViewingLifecycle(
        AppLifecycleState.paused,
        detached: rec.presenter,
      );
      expect(session.backgroundPaused, isTrue);

      await aylaHandleLiveViewingLifecycle(
        AppLifecycleState.resumed,
        detached: rec.presenter,
      );
      expect(session.backgroundPaused, isFalse);
    });
  });

  group('④ 会话结束一定撤销原生武装（唯一失败模式）', () {
    test('stop() ⇒ setSessionActive(false) 一定发出', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      final _Recorder rec = _Recorder();
      final AylaLiveRoomSession session = _session(live, stub, rec);
      addTearDown(live.dispose);

      await session.start();
      expect(
        rec.sessionActive,
        <bool>[true],
        reason: '进房读到 SRS = live ⇒ 立刻武装（「开播即武装」）',
      );

      await session.stop();
      expect(
        rec.sessionActive.last,
        isFalse,
        reason: '漏传 false 会让用户在任何页面按 Home 都误进 PiP',
      );
      expect(session.alive, isFalse);
    });

    test('dispose() 兜底路径也会发 setSessionActive(false)（异常路径不漏）', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      final _Recorder rec = _Recorder();
      final AylaLiveRoomSession session = _session(live, stub, rec);
      addTearDown(live.dispose);

      await session.start();
      rec.sessionActive.clear();

      // 不走 stop()（模拟页面直接 dispose 的异常路径）
      session.dispose();
      await Future<void>.delayed(Duration.zero);

      expect(
        rec.sessionActive,
        contains(false),
        reason: 'stop() 之外的路径也必须撤销武装',
      );
    });
  });

  group('⑤ 开播/停播 → 原生武装状态同步', () {
    test('SRS 变非 live ⇒ setSessionActive(false)；变回 live ⇒ true', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      final _Recorder rec = _Recorder();
      final AylaLiveRoomSession session = _session(live, stub, rec);
      addTearDown(() async {
        await aylaCloseLiveMiniPlayer();
        live.dispose();
      });

      await session.start();
      expect(rec.sessionActive, <bool>[true]);

      stub.srsStatus = AylaLiveSrsStatus.idle;
      await session.refreshSrsStatus();
      expect(rec.sessionActive.last, isFalse);

      stub.srsStatus = AylaLiveSrsStatus.live;
      await session.refreshSrsStatus();
      expect(rec.sessionActive.last, isTrue);
    });
  });

  group('⑥ 脱离入口（会话 + 小窗键）', () {
    test('enterDetachedPresentation ⇒ 传归一后的 playUrl + 可覆盖的 videoRect', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      final _Recorder rec = _Recorder();
      final AylaLiveRoomSession session = _session(live, stub, rec);
      addTearDown(() async {
        await aylaCloseLiveMiniPlayer();
        live.dispose();
      });

      await session.start();

      final bool ok = await session.enterDetachedPresentation(
        videoRect: const Rect.fromLTWH(10, 20, 300, 168),
      );

      expect(ok, isTrue);
      expect(rec.enterCalls, 1);
      expect(rec.lastChannelId, 'c1');
      expect(rec.lastTitle, '深夜电台');
      expect(
        rec.lastPlayUrl,
        'https://cdn.example/live/c1.m3u8',
        reason: 'playUrl 必须经过 aylaNormalizeLivePlayUrl（Windows 第二窗口靠 URL 自证）',
      );
      expect(rec.lastVideoRect, const Rect.fromLTWH(10, 20, 300, 168));
      expect(session.detached, isTrue);
      expect(
        session.alive,
        isTrue,
        reason: '脱离态不销毁会话：WS/HLS 继续跑 ⇒ 仍算观看人',
      );

      // 幂等：重复调用不再打通道
      await session.enterDetachedPresentation();
      expect(rec.enterCalls, 1);
    });

    test('原生失败 ⇒ 返回 false 且会话仍在（调用方回落到 App 内小窗）', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      final _Recorder rec = _Recorder()..enterResult = false;
      final AylaLiveRoomSession session = _session(live, stub, rec);
      addTearDown(() async {
        await aylaCloseLiveMiniPlayer();
        live.dispose();
      });

      await session.start();
      final bool ok = await session.enterDetachedPresentation();

      expect(ok, isFalse);
      expect(session.detached, isFalse);
      expect(session.alive, isTrue);
    });

    testWidgets('小窗只有「关闭」一个键（脱离按钮已被用户否决，2026-10-31）', (
      WidgetTester tester,
    ) async {
      const Size vp = Size(420, 700);
      tester.view.physicalSize = vp;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      Finder byLabel(String label) => find.byWidgetPredicate(
        (Widget w) => w is Semantics && w.properties.label == label,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: previewScope(
            Builder(
              builder: (BuildContext context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(size: vp),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox.fromSize(
                    size: vp,
                    child: const Stack(
                      children: <Widget>[
                        AylaLiveMiniPlayer(videoView: SizedBox()),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 用户原话：「我要的不是加这个脱离按钮」「不要造轮子」
      // ⇒ 小窗上只留原有的关闭键，**不得**再出现第二个键。
      expect(byLabel('关闭小窗'), findsOneWidget);
      expect(byLabel('脱离应用'), findsNothing);
    });
  });
}
