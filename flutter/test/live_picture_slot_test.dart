/// B6 画面槽位守卫回归锁（开发文档 §3 B6；需求 §3.1 B6 / §5.1 S6）。
///
/// ## 用户实报与根因
/// 小窗 / 脱离态开着的时候，`refreshSrsStatus` 只要读到 SRS = live 就 `_attachPlayer()`，
/// **没有「当前画面归谁」的守卫** ⇒ 页面那一路播放器被重新拉起来，
/// 与窗口外小窗的第二引擎播放器抢同一个 HLS 流（表现为主窗口黑屏）。
/// 需求 §5.1 S6 的口径是「任何时刻只能有一个画面槽位持有播放器」。
///
/// ## 本测试锁住什么
/// 1. 进房 ⇒ 槽位 = inline（页面持画面）；
/// 2. 进脱离态 / 小窗 ⇒ 槽位让出，此后 `refreshSrsStatus()` 读到 live **不得**再 attach
///    （判据：`session.videoView` 保持 null、平台播放器不再新建）；
/// 3. 关闭脱离态 / 回前台 ⇒ 槽位恢复 inline，画面重新交给页面；
/// 4. 会话结束 ⇒ 槽位归 none。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/live_api.dart';
import '../lib/core/ws/live_ws.dart';
import '../lib/pages/live_support.dart';
import '../lib/player/hls_player.dart';
import '../lib/state/live_state.dart';
import '../lib/widgets/live/live_channel_snapshot.dart';
import '../lib/widgets/live/live_hall.dart' show AylaLiveStatus;
import '../lib/widgets/live/live_player.dart' show AylaLiveSrsStatus;

/// 平台播放器桩：记录 attach 次数（= 「页面这一路是否被拉起来」的判据）。
class _FakePlatformPlayer implements HlsPlatformPlayer {
  static int attachCalls = 0;

  @override
  void Function(HlsState state)? onStateChange;
  @override
  void Function()? onStall;
  @override
  void Function()? onResume;
  @override
  void Function(String detail)? onFatal;

  /// P1-4 新增接口成员（非 fatal 的分片级故障上报）。替身不模拟它，留空即可。
  @override
  void Function(String detail)? onFragmentError;

  @override
  void Function(Duration position)? onPosition;

  @override
  Future<void> attach(String url) async {
    attachCalls += 1;
  }

  @override
  Future<void> play() async {}

  @override
  Future<bool> seekToLiveEdge() async => true;

  @override
  Widget? buildView() => const ColoredBox(color: Color(0xFF2A3550));

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  Future<void> dispose() async {}
}

HlsPlaybackController _fakePlayerFactory() =>
    HlsPlaybackController(_FakePlatformPlayer.new, HlsPlayerCallbacks());

/// 会记录 enter/close 的假 presenter（不碰 MethodChannel）。
class _Recorder {
  final List<String> calls = <String>[];

  AylaDetachedLivePresenter get presenter => AylaDetachedLivePresenter(
    enter: ({
      required String channelId,
      required String title,
      String? playUrl,
      Rect? videoRect,
    }) async {
      calls.add('enter');
      return true;
    },
    close: () async {
      calls.add('close');
    },
    setSessionActive: (bool active) async {},
    isInPip: () async => false,
  );
}

class _LiveStub {
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
  _LiveStub stub, {
  AylaDetachedLivePresenter? detached,
}) => AylaLiveRoomSession(
  channelId: 'c1',
  liveState: live,
  // token 为 null ⇒ connect() 是 no-op，不建真实 WS 连接。
  liveWs: AylaLiveWsClient(accessToken: () => null),
  playerFactory: _fakePlayerFactory,
  channelFetcher: stub.channel,
  statusFetcher: stub.status,
  viewersFetcher: stub.viewers,
  detached: detached ?? const AylaDetachedLivePresenter(),
);

void main() {
  // 会话的默认 present 走原生通道（aylaSetLivePipSessionActive 等）⇒ 测试必须先建
  // binding 才能调 MethodChannel；所有用例仍注入假 presenter，binding 只是兜底。
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => _FakePlatformPlayer.attachCalls = 0);

  test('① 进房 ⇒ 槽位 = inline（画面归页面）', () async {
    final AylaLiveState live = AylaLiveState();
    final _Recorder rec = _Recorder();
    final AylaLiveRoomSession session = _session(
      live,
      _LiveStub(),
      detached: rec.presenter,
    );
    addTearDown(() async {
      await session.stop();
      session.dispose();
      live.dispose();
    });

    await session.start();
    expect(session.pictureSlot, AylaPictureSlot.inline);
    expect(_FakePlatformPlayer.attachCalls, 1, reason: '进房读到 live ⇒ 页面挂播放器');
  });

  test('② 进脱离态 ⇒ 槽位让出；此后 refreshSrsStatus 读到 live 也不许再 attach', () async {
    final AylaLiveState live = AylaLiveState();
    final _LiveStub stub = _LiveStub();
    final _Recorder rec = _Recorder();
    final AylaLiveRoomSession session = _session(
      live,
      stub,
      detached: rec.presenter,
    );
    addTearDown(() async {
      await session.stop();
      session.dispose();
      live.dispose();
    });

    await session.start();
    final int before = _FakePlatformPlayer.attachCalls;
    expect(await session.enterDetachedPresentation(), isTrue);
    await pumpEventQueue();
    expect(session.pictureSlot, AylaPictureSlot.desktopMini);

    // 脱离态期间来一次 SRS 状态刷新（用户实报的触发条件）
    stub.srsStatus = AylaLiveSrsStatus.live;
    await session.refreshSrsStatus();

    expect(
      _FakePlatformPlayer.attachCalls,
      before,
      reason: '小窗 / 脱离态持有画面时，页面这一路不得被重新拉起来（会抢流）',
    );
    expect(session.pictureSlot, AylaPictureSlot.desktopMini);
  });

  test('③ 关闭脱离态 ⇒ 槽位恢复 inline，画面交回页面', () async {
    final AylaLiveState live = AylaLiveState();
    final _LiveStub stub = _LiveStub();
    final _Recorder rec = _Recorder();
    final AylaLiveRoomSession session = _session(
      live,
      stub,
      detached: rec.presenter,
    );
    addTearDown(() async {
      await session.stop();
      session.dispose();
      live.dispose();
    });

    await session.start();
    await session.enterDetachedPresentation();
    await pumpEventQueue();
    expect(session.pictureSlot, AylaPictureSlot.desktopMini);

    await session.closeDetachedPresentation();
    await pumpEventQueue();
    expect(
      session.pictureSlot,
      AylaPictureSlot.inline,
      reason: '回页面后槽位必须恢复，否则后面的 attach 会被自己的守卫挡住（永久黑屏）',
    );
  });

  test('④ 会话结束 ⇒ 槽位归 none', () async {
    final AylaLiveState live = AylaLiveState();
    final _Recorder rec = _Recorder();
    final AylaLiveRoomSession session = _session(
      live,
      _LiveStub(),
      detached: rec.presenter,
    );
    addTearDown(() {
      session.dispose();
      live.dispose();
    });

    await session.start();
    expect(session.pictureSlot, AylaPictureSlot.inline);
    await session.stop();
    expect(session.pictureSlot, AylaPictureSlot.none);
  });
}
