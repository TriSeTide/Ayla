/// B5 后台恢复回归锁（开发文档 §3 B5；需求 §3.1 B5 / §5.1 S5、G3）。
///
/// ## 缺陷（两半，两端各一半）
/// 1. **Windows**：media_kit_video 的 `Video` 默认值是
///    `pauseUponEnteringBackgroundMode = true`、`resumeUponEnteringForegroundMode = false`
///    （`third_party/media_kit_video/lib/src/video/video_texture.dart:132–133`）。
///    Ayla 此前两个参数都没传 ⇒ **进后台暂停、回前台不播** ⇒ 回到前台是黑屏。
/// 2. **移动端**：`video_player` 的 `VideoPlayer` widget **没有**这对参数，
///    进后台后播放器被系统停下 ⇒ 回前台同样黑屏。补在会话层（[B5] 的一半）：
///    生命周期 resumed ⇒ `resumeViewerPresence()` ⇒ `HlsPlaybackController.resumePlayback()`。
///
/// ## 本测试锁住什么
/// 1. Windows 参数**必须显式成对传**（源码级断言：漏掉 resume 就等于没修）；
/// 2. 会话层回前台会**真的**让播放器继续播（移动端那一半）；
/// 3. 已经 playing 时 resumePlayback 是 no-op（不打断正在播的画面）；
/// 4. 页面不持有画面（B6 槽位）时**不得**替别人 play（避免抢流）。
library;

import 'dart:io';

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

/// 平台桩：记录 play() 调用（= 「有没有真的去让它继续播」）。
class _FakePlatformPlayer implements HlsPlatformPlayer {
  _FakePlatformPlayer() {
    last = this;
  }

  /// 最近创建的实例（用例用它推状态，模拟平台上报 playing）。
  static _FakePlatformPlayer? last;

  static int playCalls = 0;

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
  Future<void> play() async {
    playCalls += 1;
  }

  @override
  Future<bool> seekToLiveEdge() async => true;

  @override
  Widget? buildView() => const ColoredBox(color: Color(0xFF2A3550));

  @override
  Future<void> dispose() async {}
}

HlsPlaybackController _fakePlayerFactory() =>
    HlsPlaybackController(_FakePlatformPlayer.new, HlsPlayerCallbacks());

class _Recorder {
  AylaDetachedLivePresenter get presenter => AylaDetachedLivePresenter(
    enter: ({
      required String channelId,
      required String title,
      String? playUrl,
      Rect? videoRect,
      String? lastFramePath,
    }) async => true,
    close: () async {},
    setSessionActive: (bool active) async {},
    isInPip: () async => false,
  );
}

class _LiveStub {
  Future<AylaLiveChannelSnapshot> channel(String id) async =>
      AylaLiveChannelSnapshot(
        id: id,
        title: '深夜电台',
        hlsUrl: 'https://cdn.example/live/$id.m3u8',
        status: AylaLiveStatus.live,
      );

  Future<AylaLiveStatusResult> status(String id) async =>
      const AylaLiveStatusResult(status: AylaLiveSrsStatus.live);

  Future<AylaLiveViewersResult> viewers(String id) async =>
      AylaLiveViewersResult(channelId: id, count: 1);
}

AylaLiveRoomSession _session(AylaLiveState live, _LiveStub stub) =>
    AylaLiveRoomSession(
      channelId: 'c1',
      liveState: live,
      liveWs: AylaLiveWsClient(accessToken: () => null),
      playerFactory: _fakePlayerFactory,
      channelFetcher: stub.channel,
      statusFetcher: stub.status,
      viewersFetcher: stub.viewers,
      detached: _Recorder().presenter,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => _FakePlatformPlayer.playCalls = 0);

  group('Windows：media_kit Video 的 B5 参数必须显式成对传', () {
    test('buildView 传 pause=true / resume=true（源码级断言，漏一个就等于没修）', () {
      final String source = File(
        'lib/player/platforms/media_kit_impl.dart',
      ).readAsStringSync();
      expect(
        source.contains('pauseUponEnteringBackgroundMode: true'),
        isTrue,
        reason: '后台继续解码纯耗电，直播场景应保持暂停（开发文档 §3 B5）',
      );
      expect(
        source.contains('resumeUponEnteringForegroundMode: true'),
        isTrue,
        reason: '这一条是缺陷本体：默认 false ⇒ 进后台暂停后再也不恢复（黑屏）',
      );
    });
  });

  group('移动端：回前台由会话层补「继续播」', () {
    test('resumeViewerPresence ⇒ 页面持有画面时真的 play 一次', () async {
      final AylaLiveState live = AylaLiveState();
      final AylaLiveRoomSession session = _session(live, _LiveStub());
      addTearDown(() async {
        await session.stop();
        session.dispose();
        live.dispose();
      });

      await session.start();
      expect(session.pictureSlot, AylaPictureSlot.inline);

      // 模拟 App 进后台（断 WS + 暂停观看登记）
      session.pauseViewerPresence();
      expect(session.backgroundPaused, isTrue);
      final int before = _FakePlatformPlayer.playCalls;

      // 回前台
      session.resumeViewerPresence();
      await pumpEventQueue();

      expect(
        _FakePlatformPlayer.playCalls,
        greaterThan(before),
        reason: '移动端 video_player 没有 resume 参数 ⇒ 必须在会话层补这一次 play',
      );
    });

    test('页面不持有画面（脱离态）⇒ 回前台不替别人 play（不抢流）', () async {
      final AylaLiveState live = AylaLiveState();
      final AylaLiveRoomSession session = _session(live, _LiveStub());
      addTearDown(() async {
        await session.stop();
        session.dispose();
        live.dispose();
      });

      await session.start();
      await session.enterDetachedPresentation();
      await pumpEventQueue();
      expect(session.pictureSlot, AylaPictureSlot.desktopMini);

      session.pauseViewerPresence();
      final int before = _FakePlatformPlayer.playCalls;
      session.resumeViewerPresence();
      await pumpEventQueue();

      expect(
        _FakePlatformPlayer.playCalls,
        before,
        reason: 'B6 槽位守卫：小窗/脱离态持有画面时，页面不得再拉一路出来',
      );
    });
  });

  group('HlsPlaybackController.resumePlayback 的语义', () {
    test('已经 playing ⇒ no-op（不打断正在播的画面）', () async {
      final List<String> logs = <String>[];
      final HlsPlaybackController c = HlsPlaybackController(
        _FakePlatformPlayer.new,
        HlsPlayerCallbacks()..onLog = logs.add,
      );
      await c.attach('https://x/live/a.m3u8');
      // 让控制器进入 playing（平台上报，等价 mpv 的 playing 事件）
      _FakePlatformPlayer.last?.onStateChange?.call(HlsState.playing);
      expect(c.state, HlsState.playing);
      final int afterAttach = _FakePlatformPlayer.playCalls;
      await c.resumePlayback();
      expect(
        _FakePlatformPlayer.playCalls,
        afterAttach,
        reason: '正在播时再 play 一次没有意义，还可能触发一次 seek/重缓冲',
      );
      await c.destroy();
    });

    test('没有平台实例 ⇒ 静默返回（不抛）', () async {
      final HlsPlaybackController c = HlsPlaybackController(
        _FakePlatformPlayer.new,
        HlsPlayerCallbacks(),
      );
      await c.resumePlayback(); // 未 attach
    });
  });
}
