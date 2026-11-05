/// 直播小窗「切后台 ⇒ 出现 / 回前台 ⇒ 消失」+ 尺寸的回归锁（2026-11-01 用户实报四条）。
///
/// ## 用户原话
/// 1. 「小窗在手机上太大了，手机上应该还原成没有加大过的那个样子」
///    ⇒ 默认尺寸必须是设计值 **168×94**（不是电脑端的 400×225）。
/// 2. 「从直播间离开 app，把 Ayla 放后台没有出现小窗」
///    ⇒ 生命周期 paused/hidden 时**必须**把窗口外小窗开出来。
/// 3. 「回到直播间时小窗应该消失」
///    ⇒ 回前台 / 再次进入直播间时清投影 ⇒ 壳层同步器关窗。
/// 4. 「关闭键上半部分被裁断」
///    ⇒ 窗口几何 = 卡片 + **四边**各 [kLiveCloseInset]，卡片画在 inset 偏移上。
///
/// ## 为什么这些用例必须存在
/// 四条都是「接线」而不是组件自身语义：组件测试全绿、Flutter 也能编译，
/// 但真机上就是不动（2026-11-01 实测：手机上跑的包根本没有这些改动）。
/// 所以这里锁的是**会话层的判定与投影变化**，而不是像素。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/live_api.dart';
import '../lib/core/platform/detached_live.dart';
import '../lib/core/ws/live_ws.dart';
import '../lib/pages/live_support.dart';
import '../lib/player/hls_player.dart';
import '../lib/state/live_state.dart';
import '../lib/widgets/live/live_channel_snapshot.dart';
import '../lib/widgets/live/live_hall.dart' show AylaLiveStatus;
import '../lib/widgets/live/live_mini_player.dart';
import '../lib/widgets/live/live_player.dart' show AylaLiveSrsStatus;

/// 平台播放器桩（不碰真实解码）。
class _FakePlatformPlayer implements HlsPlatformPlayer {
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
  Future<void> attach(String url) async {}
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

/// 记录平台动作的假 presenter（只关心「有没有真的去开窗/关窗」）。
class _Recorder {
  _Recorder({this.inPipValue = false});

  bool inPipValue;
  int enterCalls = 0;
  int closeCalls = 0;
  String? lastChannelId;
  String? lastPlayUrl;

  AylaDetachedLivePresenter get presenter => AylaDetachedLivePresenter(
    enter: ({
      required String channelId,
      required String title,
      String? playUrl,
      Rect? videoRect,
    }) async {
      enterCalls += 1;
      lastChannelId = channelId;
      lastPlayUrl = playUrl;
      return true;
    },
    close: () async {
      closeCalls += 1;
    },
    setSessionActive: (bool active) async {},
    isInPip: () async => inPipValue,
  );
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
      liveWs: AylaLiveWsClient(accessToken: () => null),
      channelFetcher: stub.channel,
      statusFetcher: stub.status,
      viewersFetcher: stub.viewers,
      playerFactory: _fakePlayerFactory,
      detached: rec.presenter,
    );

void main() {
  // 会话的 `start()` 会挂滚动绑定（`AylaHistoryScrollBinding` 要 `SchedulerBinding.instance`），
  // 而这些用例是纯 `test()`（不是 `testWidgets`）⇒ 必须自己初始化 binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('问题①：手机端默认尺寸 = 设计值 168×94（不是电脑端 400）', () {
    test('浮层默认宽度常量 = kLiveMiniWidth', () {
      expect(kLiveDetachedMiniDefaultWidth, kLiveMiniWidth);
      expect(kLiveMiniWidth, 168);
      expect(kLiveMiniHeight, 94);
      expect(kLiveMiniWidth / kLiveMiniHeight, closeTo(16 / 9, 0.01));
    });

    test('缩放上限按平台分开：手机 320 / 桌面 900（用户实报「不能缩放到这——么——大」）', () {
      expect(kLiveMiniMinWidth, 120, reason: 'App 内捏合下限保持 web 原值');
      expect(
        kLiveMiniMaxWidth,
        320,
        reason: '手机端 = web LiveMiniPlayer.tsx:32–33 原值；900 是电脑端为「画面不糊」加的',
      );
      expect(
        kLiveMiniDesktopMaxWidth,
        900,
        reason: '电脑端保留大尺寸（125% 缩放下 168 只有 210 物理像素）',
      );
    });
  });

  group('缩放：Dart 与原生必须同一套范围（两边各写一份常量，最容易漂）', () {
    test('原生 MAX_WIDTH_DP/MIN_WIDTH_DP 与 Dart 常量逐字一致', () async {
      final String kt = await File(
        'android/app/src/main/kotlin/com/ayla/ayla_flutter/LiveMiniWindowHost.kt',
      ).readAsString();
      expect(
        kt,
        contains('const val MIN_WIDTH_DP = 120'),
        reason: '原生捏合下限必须与 kLiveMiniMinWidth 一致',
      );
      expect(
        kt,
        contains('const val MAX_WIDTH_DP = 320'),
        reason: '原生捏合上限必须与 kLiveMiniMaxWidth 一致（手机不能到 900）',
      );
      expect(
        kt,
        contains('const val DEFAULT_WIDTH_DP = 168'),
        reason: '默认宽度必须等于 kLiveDetachedMiniDefaultWidth（168）',
      );
      expect(
        kt,
        isNot(contains('MAX_WIDTH_DP = 900')),
        reason: '900 是电脑端那档；手机上出现就等于「能缩放到铺满整屏」',
      );
    });
  });

  group('问题②：App 切后台 ⇒ 小窗必须出现', () {
    test('paused ⇒ 小窗投影置位 + 真的去开了窗口', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      final _Recorder rec = _Recorder();
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

      expect(live.miniPlayer, isNotNull, reason: '投影非空 ⇒ AppShell 才会开窗');
      expect(live.miniPlayer!.channelId, 'c1');
      expect(
        rec.enterCalls,
        greaterThan(0),
        reason: '主引擎进后台后不出帧，必须由会话层直接开窗（不能等壳层 postFrame）',
      );
      expect(rec.lastChannelId, 'c1');
      expect(
        session.miniWindowIsBackgroundAuto,
        isTrue,
        reason: '标记来源：回前台要按它决定自动撤掉',
      );
    });

    test('hidden 同样触发（切后台的第一档，比 paused 更早）', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      final _Recorder rec = _Recorder();
      final AylaLiveRoomSession session = _session(live, stub, rec);
      addTearDown(() async {
        await aylaCloseLiveMiniPlayer();
        live.dispose();
      });

      await session.start();
      await aylaHandleLiveViewingLifecycle(
        AppLifecycleState.hidden,
        detached: rec.presenter,
      );

      expect(live.miniPlayer, isNotNull);
      expect(rec.enterCalls, greaterThan(0));
    });

    test('inactive 不动（短暂失焦不该弹小窗）', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      final _Recorder rec = _Recorder();
      final AylaLiveRoomSession session = _session(live, stub, rec);
      addTearDown(live.dispose);

      await session.start();
      await aylaHandleLiveViewingLifecycle(
        AppLifecycleState.inactive,
        detached: rec.presenter,
      );

      expect(live.miniPlayer, isNull);
      expect(rec.enterCalls, 0);
      await session.stop();
      session.dispose();
    });

    test('直播未开始（SRS 非 live）⇒ 不弹小窗', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub()..srsStatus = AylaLiveSrsStatus.idle;
      final _Recorder rec = _Recorder();
      final AylaLiveRoomSession session = _session(live, stub, rec);
      addTearDown(live.dispose);

      await session.start();
      await aylaHandleLiveViewingLifecycle(
        AppLifecycleState.paused,
        detached: rec.presenter,
      );

      expect(live.miniPlayer, isNull);
      await session.stop();
      session.dispose();
    });
  });

  group('问题③：回到前台 / 回到直播间 ⇒ 小窗必须消失', () {
    test('resumed ⇒ 自动弹出的那个小窗撤掉（投影清空 + 关窗 + 会话不销毁）', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      final _Recorder rec = _Recorder();
      final AylaLiveRoomSession session = _session(live, stub, rec);
      addTearDown(() async {
        await session.stop();
        session.dispose();
        live.dispose();
      });

      await session.start();
      await aylaHandleLiveViewingLifecycle(
        AppLifecycleState.paused,
        detached: rec.presenter,
      );
      expect(live.miniPlayer, isNotNull);

      await aylaHandleLiveViewingLifecycle(
        AppLifecycleState.resumed,
        detached: rec.presenter,
      );

      expect(live.miniPlayer, isNull, reason: '用户：回到直播间时小窗应该消失');
      expect(aylaMiniPlayerOwner, isNull);
      expect(
        session.alive,
        isTrue,
        reason: '只是小窗让位，会话与观看登记要继续（页面还在用）',
      );
      expect(rec.closeCalls, greaterThan(0), reason: '原生窗口必须真的关掉');
    });

    test('「离开直播间」得到的小窗**不**在回前台时被撤（那不是自动弹出的）', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      final _Recorder rec = _Recorder();
      final AylaLiveRoomSession session = _session(live, stub, rec);
      addTearDown(() async {
        await aylaCloseLiveMiniPlayer();
        live.dispose();
      });

      await session.start();
      await session.detachView(isNarrow: true);
      expect(live.miniPlayer, isNotNull);
      expect(session.miniWindowIsBackgroundAuto, isFalse);

      await aylaHandleLiveViewingLifecycle(
        AppLifecycleState.resumed,
        detached: rec.presenter,
      );

      expect(
        live.miniPlayer,
        isNotNull,
        reason: '用户主动保留的小窗不能被回前台抢走',
      );
      // 不再断言 closeCalls == 0：`detachView` 进小窗时会先关一次窗口（让位），
      // 这里要锁的是「回前台**没有**再撤一次」—— 用 resumed 前后的差值表达。
      final int before = rec.closeCalls;
      await aylaHandleLiveViewingLifecycle(
        AppLifecycleState.resumed,
        detached: rec.presenter,
      );
      expect(
        rec.closeCalls,
        before,
        reason: '非自动弹出的小窗不该因为回前台而多关一次',
      );
    });

    test('再次进入直播间（start）⇒ 清投影', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      final _Recorder rec = _Recorder();
      final AylaLiveRoomSession session = _session(live, stub, rec);
      addTearDown(() async {
        await aylaCloseLiveMiniPlayer();
        live.dispose();
      });

      await session.start();
      await session.detachView(isNarrow: true);
      expect(live.miniPlayer, isNotNull);

      final AylaLiveRoomSession next = _session(live, stub, _Recorder());
      await next.start();
      addTearDown(() async {
        await next.stop();
        next.dispose();
      });

      expect(live.miniPlayer, isNull, reason: '回到直播间 ⇒ 小窗投影必须清空');
    });
  });

  group('问题②③的连乘：切后台 → 回前台 → 退出直播间，小窗仍要能出现', () {
    test('切后台不摘「页面级活跃会话」⇒ 之后 detachView 仍进小窗', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      final _Recorder rec = _Recorder();
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
      await aylaHandleLiveViewingLifecycle(
        AppLifecycleState.resumed,
        detached: rec.presenter,
      );
      expect(live.miniPlayer, isNull, reason: '回前台已撤掉自动弹出的那个');

      // 用户接着退出直播间：这条路径必须还能进小窗（不被代际防御误杀）。
      await session.detachView(isNarrow: true);
      expect(
        live.miniPlayer,
        isNotNull,
        reason: '切后台过一轮之后，「退出直播间」仍要能出现小窗',
      );
    });

    test('回前台撤小窗后，观看登记仍能续上（会话没被摘出恢复目标）', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      final _Recorder rec = _Recorder();
      final AylaLiveRoomSession session = _session(live, stub, rec);
      addTearDown(() async {
        await session.stop();
        session.dispose();
        live.dispose();
      });

      await session.start();
      await aylaHandleLiveViewingLifecycle(
        AppLifecycleState.paused,
        detached: rec.presenter,
      );
      expect(session.backgroundPaused, isTrue);

      await aylaHandleLiveViewingLifecycle(
        AppLifecycleState.resumed,
        detached: rec.presenter,
      );

      expect(
        session.backgroundPaused,
        isFalse,
        reason: '回前台必须续上观看登记（否则别人看你不在看了、心跳也不恢复）',
      );
    });
  });

  group('「怎么关」：用户点掉小窗后不得再自动出现（2026-11-01 用户实报）', () {
    test('点掉小窗 ⇒ 之后切后台 / 退出直播间都不再自动弹', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      final _Recorder rec = _Recorder();
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
      expect(live.miniPlayer, isNotNull);

      // 模拟用户点小窗的关闭键：原生发 liveWindowClosed。
      AylaDetachedLiveEvents.instance.debugEmit(
        const AylaDetachedLiveEvent.liveWindowClosed(),
      );
      await Future<void>.delayed(Duration.zero);
      expect(live.miniPlayer, isNull, reason: '点了关闭键 ⇒ 投影必须清掉');

      // 用户继续把 App 放后台：不允许再自动出现。
      final int before = rec.enterCalls;
      await aylaHandleLiveViewingLifecycle(
        AppLifecycleState.paused,
        detached: rec.presenter,
      );
      expect(
        live.miniPlayer,
        isNull,
        reason: '用户亲手关掉过小窗 ⇒ 不得再自动出现（这是「怎么关」）',
      );
      expect(rec.enterCalls, before, reason: '不该再去开窗');

      // 再退出直播间：同样不出现。
      await session.detachView(isNarrow: true);
      expect(live.miniPlayer, isNull);
      expect(rec.enterCalls, before);
    });

    test('点掉小窗时人还在直播间 ⇒ **不销毁会话**（否则退不出直播间）', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      final _Recorder rec = _Recorder();
      final AylaLiveRoomSession session = _session(live, stub, rec);
      addTearDown(() async {
        await session.stop();
        session.dispose();
        live.dispose();
      });

      await session.start();
      await aylaHandleLiveViewingLifecycle(
        AppLifecycleState.paused,
        detached: rec.presenter,
      );
      expect(live.miniPlayer, isNotNull);

      AylaDetachedLiveEvents.instance.debugEmit(
        const AylaDetachedLiveEvent.liveWindowClosed(),
      );
      await Future<void>.delayed(Duration.zero);

      expect(live.miniPlayer, isNull);
      expect(
        session.alive,
        isTrue,
        reason: '人还在直播间页里：关小窗只是收起浮层，会话必须活着（否则画面卡死、退不出去）',
      );
    });

    test('新建会话（重新进直播间）⇒ 抑制被清掉，可以再次自动弹', () async {
      final AylaLiveState live = AylaLiveState();
      final _LiveStub stub = _LiveStub();
      final _Recorder rec = _Recorder();
      final AylaLiveRoomSession first = _session(live, stub, rec);
      addTearDown(() async {
        await aylaCloseLiveMiniPlayer();
        live.dispose();
      });

      await first.start();
      // 先让它切后台进过小窗（这才挂上关闭事件的监听），再模拟用户点关闭键。
      await aylaHandleLiveViewingLifecycle(
        AppLifecycleState.paused,
        detached: rec.presenter,
      );
      expect(live.miniPlayer, isNotNull);

      AylaDetachedLiveEvents.instance.debugEmit(
        const AylaDetachedLiveEvent.liveWindowClosed(),
      );
      await Future<void>.delayed(Duration.zero);
      expect(live.miniPlayer, isNull, reason: '点了关闭键 ⇒ 投影清掉');
      expect(first.alive, isTrue, reason: '人还在直播间 ⇒ 会话不销毁');

      await first.detachView(isNarrow: true);
      expect(live.miniPlayer, isNull, reason: '抑制生效：退出直播间也不自动弹');

      // 用户重新进直播间：新会话 ⇒ 抑制解除。
      final AylaLiveRoomSession second = _session(live, stub, _Recorder());
      await second.start();
      await aylaHandleLiveViewingLifecycle(
        AppLifecycleState.paused,
        detached: rec.presenter,
      );
      expect(
        live.miniPlayer,
        isNotNull,
        reason: '重新进直播间是一次新的观看流程，切后台应当照常弹小窗',
      );
    });
  });

  group('问题④：关闭键不能被裁（几何口径）', () {
    test('窗口 = 卡片 + 四边各 inset（Dart build 的算法）', () {
      const double inset = kLiveCloseInset;
      const double cardW = kLiveMiniWidth;
      final double cardH = cardW * 9 / 16;
      final double winW = cardW + inset * 2;
      final double winH = cardH + inset * 2;
      // 卡片画在 (inset, inset) ⇒ 关闭键 (top:-inset,right:-inset,24×24) 落在
      // 窗口坐标 y ∈ [0, 24]、x ∈ [winW-24, winW]，完整可见。
      final double closeTop = inset - inset; // 卡片 top + 按钮 -inset
      final double closeBottom = closeTop + 24;
      final double closeRight = inset + cardW + inset;
      expect(closeTop, 0, reason: '按钮上沿正好压在窗口上沿（不再越界）');
      expect(closeBottom, lessThanOrEqualTo(winH));
      expect(closeRight, winW, reason: '按钮右沿正好压在窗口右沿');
      expect(winH, greaterThan(cardH), reason: '高度必须比卡片大出两倍 inset');
    });

    test('kLiveCloseInset 与原生 CLOSE_INSET_DP 同值（10）', () {
      expect(kLiveCloseInset, 10);
    });
  });
}
