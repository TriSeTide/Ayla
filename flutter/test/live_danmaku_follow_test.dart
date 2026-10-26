/// 直播弹幕「贴底跟随 / 有新弹幕 / 群内实时同步」回归锁 —— 用户 2026-10-26 实报
/// 「直播弹幕发送图片过大（测试用的是动图）后，发送后会导致刷新不出来，需要重新进入
/// 直播间才看到新弹幕」。
///
/// ## 根因（三条叠加，全部是**接线缺口**，不是数据层问题）
/// 会话级探针实测：WS 帧 → store → 历史窗口三段都是通的（图片帧与文字帧都进得去）。
/// 断的是 web 由 `useCursorHistory` 自带、而 Flutter 侧**没人消费**的三件：
/// 1. **贴底跟随**：web 在 `useLayoutEffect` 里写 `list.scrollTop = list.scrollHeight`
///    （`useCursorHistory.ts:66–79`）；Flutter 的
///    `AylaCursorHistory.pendingScrollToBottom` **只置位、全仓零消费方**
///    ⇒ 新弹幕进了窗口但列表**原地不动**。图片弹幕行（96×64 缩略图 + 昵称）比
///    一行纯文字高得多，连续几条就把可见区顶满 ⇒ 视觉上「卡住」；
///    退出重进会重建列表并贴底 ⇒ 表现为「重进才刷新」。
/// 2. **有新弹幕 ↓**：`AylaDanmakuList.onScrollToBottom` 未接线，而
///    `history.hasNewer` 是**锁存位**（`cursor_history.dart:296`）⇒ 一旦上翻过，
///    提示亮着但点了没反应，永远回不到最新。
/// 3. **群内直播**：`group_live_page` 从不调 `session.syncRealtimeToHistory()`
///    ⇒ 历史窗口没有实时帧 ⇒ 群内直播的实时弹幕**永不出现**
///    （web `GroupLive.tsx` 复用同一份 `useDanmaku` hook，天然没有该缺口）。
///
/// ## 本文件锁什么
/// ① 会话层：`pumpScroll` 真的把列表滚到底（消费置位 + 幂等）；
/// ② 会话层：`handleDanmakuScroll` 距底<40 才继续跟随（上翻即停跟随）；
/// ③ 会话层：`scrollDanmakuToBottom` 未脱挂时直接贴底并重新跟随；
/// ④ 装配层：三个直播页面都把 controller / onUserScroll / onScrollToBottom 接上；
/// ⑤ 端到端：图片弹幕帧到达后进入历史窗口（媒体描述符完整）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/live_api.dart';
import '../lib/core/api/media_page.dart';
import '../lib/core/ws/live_ws.dart';
import '../lib/pages/live_support.dart';
import '../lib/player/hls_player.dart';
import '../lib/player/platforms/hls_platform.dart';
import '../lib/state/cursor_history.dart';
import '../lib/state/live_state.dart';
import '../lib/widgets/live/danmaku.dart';
import '../lib/widgets/live/live_channel_snapshot.dart';
import '../lib/widgets/live/live_hall.dart' show AylaLiveStatus;
import '../lib/widgets/live/live_player.dart' show AylaLiveSrsStatus;
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

HlsPlaybackController _playerFactory() =>
    HlsPlaybackController(_FakePlatformPlayer.new, HlsPlayerCallbacks());

AylaLiveRoomSession _session(AylaLiveState live) => AylaLiveRoomSession(
      channelId: 'c1',
      liveState: live,
      // token 为 null ⇒ connect() 是 no-op（不建真实连接）。
      liveWs: AylaLiveWsClient(accessToken: () => null),
      playerFactory: _playerFactory,
      channelFetcher: (String id) async =>
          AylaLiveChannelSnapshot(id: id, title: 't', status: AylaLiveStatus.live),
      statusFetcher: (String id) async =>
          const AylaLiveStatusResult(status: AylaLiveSrsStatus.live),
      viewersFetcher: (String id) async =>
          const AylaLiveViewersResult(channelId: 'c1', count: 0),
    );

/// 图片弹幕帧（后端 `_danmaku_event` 的真实形状：平铺 + sender.id + media descriptor）。
Map<String, dynamic> _imageFrame(String id) => <String, dynamic>{
      'type': 'danmaku',
      'id': id,
      'channel_id': 'c1',
      'sender': <String, dynamic>{'id': 'u1', 'nickname': '樱', 'avatar': ''},
      'content': '图片',
      'media_id': 'm-big',
      'media': <String, dynamic>{
        'media_id': 'm-big',
        'kind': 'image',
        'mime_type': 'image/gif',
        'size': 6 * 1024 * 1024,
        'status': 'ready',
        'width': 3200,
        'height': 2400,
        'duration': null,
        'thumbnail': '/api/v1/media/m-big/thumbnail',
        'waveform': null,
        'created_at': '2026-10-26T10:00:00Z',
      },
      'created_at': '2026-10-26T10:00:00Z',
    };

Map<String, dynamic> _textFrame(String id) => <String, dynamic>{
      'type': 'danmaku',
      'id': id,
      'channel_id': 'c1',
      'sender': <String, dynamic>{'id': 'u1', 'nickname': '樱', 'avatar': ''},
      'content': 'hi',
      'media_id': null,
      'media': null,
      'created_at': '2026-10-26T10:00:01Z',
    };

/// 读仓库内文件（静态接线审计用；cwd = flutter/）。
String _read(String relative) => File(relative).readAsStringSync();

/// 14 条文字弹幕（足以撑出可滚动高度）。
List<AylaDanmakuEntry> _many() => <AylaDanmakuEntry>[
      for (int i = 0; i < 14; i++)
        AylaDanmakuEntry(id: 'e' + i.toString(), senderNickname: 'a', content: 'c' + i.toString()),
    ];

/// 把列表装进固定 180 高的视口（触发滚动语义）。
Widget _host(AylaLiveRoomSession session, List<AylaDanmakuEntry> items) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 180,
          child: AylaDanmakuList(
            items: items,
            controller: session.danmakuScroll,
            onUserScroll: session.handleDanmakuScroll,
            onScrollToBottom: () {},
          ),
        ),
      ),
    );
void main() {
  group('① 会话层：pumpScroll 真的贴底', () {
    testWidgets('新弹幕 append 后 pumpScroll 把列表滚到底（web listRef 语义）',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final AylaLiveState live = AylaLiveState();
      final AylaLiveRoomSession session = _session(live);
      addTearDown(session.dispose);
      // `start()` 内部有 `await Future.delayed(Duration.zero)`（让出事件循环以避开
      // 「build 期间改 provider」）⇒ 在 testWidgets 的 fake clock 下必须用 runAsync 跑，
      // 否则该 timer 永不触发、测试直接挂死（实测踩过）。
      await tester.runAsync(() => session.start());
      await tester.pump();

      await tester.pumpWidget(_host(session, _many()));
      await tester.pumpAndSettle();

      final ScrollPosition position = session.danmakuScroll.position;
      expect(position.maxScrollExtent, greaterThan(0.0),
          reason: '14 条弹幕在 180 高视口里必须可滚动（否则本测试无意义）');

      // 模拟用户上翻到顶部
      session.danmakuScroll.jumpTo(0);
      await tester.pump();
      expect(position.pixels, 0.0);

      // 新弹幕到达：历史窗口 append ⇒ pendingScrollToBottom 置位
      final AylaCursorHistory<AylaLiveDanmaku>? history = session.history;
      expect(history, isNotNull);
      history!.append(const AylaLiveDanmaku(
        id: 'new1',
        createdAt: '2026-10-26T10:00:09Z',
        content: 'new',
      ));

      await tester.pump();
      session.pumpScroll();
      await tester.pump();

      expect(
        position.pixels,
        moreOrLessEquals(position.maxScrollExtent, epsilon: 0.5),
        reason: '新弹幕 append 后必须贴底（web useCursorHistory 的 anchor=bottom）',
      );

      // 幂等：置位已消费，再 pump 不应再改滚动位置
      final double before = position.pixels;
      session.pumpScroll();
      await tester.pump();
      expect(position.pixels, moreOrLessEquals(before, epsilon: 0.5));
    });

    testWidgets('未置位（没有新弹幕）时 pumpScroll 不动滚动位置',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final AylaLiveState live = AylaLiveState();
      final AylaLiveRoomSession session = _session(live);
      addTearDown(session.dispose);
      // `start()` 内部有 `await Future.delayed(Duration.zero)`（让出事件循环以避开
      // 「build 期间改 provider」）⇒ 在 testWidgets 的 fake clock 下必须用 runAsync 跑，
      // 否则该 timer 永不触发、测试直接挂死（实测踩过）。
      await tester.runAsync(() => session.start());
      await tester.pump();

      await tester.pumpWidget(_host(session, _many()));
      await tester.pumpAndSettle();

      session.danmakuScroll.jumpTo(30);
      await tester.pump();
      final double before = session.danmakuScroll.position.pixels;
      session.pumpScroll();
      await tester.pump();
      expect(session.danmakuScroll.position.pixels,
          moreOrLessEquals(before, epsilon: 0.5));
    });
  });

  group('② 会话层：handleDanmakuScroll 的跟随判定（距底 < 40）', () {
    testWidgets('贴底 ⇒ 继续跟随；滚远 ⇒ 停跟随', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final AylaLiveState live = AylaLiveState();
      final AylaLiveRoomSession session = _session(live);
      addTearDown(session.dispose);
      // `start()` 内部有 `await Future.delayed(Duration.zero)`（让出事件循环以避开
      // 「build 期间改 provider」）⇒ 在 testWidgets 的 fake clock 下必须用 runAsync 跑，
      // 否则该 timer 永不触发、测试直接挂死（实测踩过）。
      await tester.runAsync(() => session.start());
      await tester.pump();

      await tester.pumpWidget(_host(session, _many()));
      await tester.pumpAndSettle();

      final ScrollPosition position = session.danmakuScroll.position;
      session.danmakuScroll.jumpTo(position.maxScrollExtent);
      await tester.pump();
      session.handleDanmakuScroll();
      expect(session.history!.following, isTrue, reason: '贴底 ⇒ 跟随');

      session.danmakuScroll.jumpTo(0);
      await tester.pump();
      session.handleDanmakuScroll();
      expect(session.history!.following, isFalse, reason: '滚远（>40）⇒ 停跟随');
    });
  });

  group('③ 会话层：scrollDanmakuToBottom（web useDanmaku.scrollToBottom）', () {
    testWidgets('窗口未脱挂 ⇒ 直接贴底并重新跟随', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final AylaLiveState live = AylaLiveState();
      final AylaLiveRoomSession session = _session(live);
      addTearDown(session.dispose);
      // `start()` 内部有 `await Future.delayed(Duration.zero)`（让出事件循环以避开
      // 「build 期间改 provider」）⇒ 在 testWidgets 的 fake clock 下必须用 runAsync 跑，
      // 否则该 timer 永不触发、测试直接挂死（实测踩过）。
      await tester.runAsync(() => session.start());
      await tester.pump();

      await tester.pumpWidget(_host(session, _many()));
      await tester.pumpAndSettle();

      final ScrollPosition position = session.danmakuScroll.position;
      session.danmakuScroll.jumpTo(0);
      await tester.pump();
      session.handleDanmakuScroll();
      expect(session.history!.following, isFalse);

      await session.scrollDanmakuToBottom();
      await tester.pump();
      expect(position.pixels,
          moreOrLessEquals(position.maxScrollExtent, epsilon: 0.5));
      expect(session.history!.following, isTrue);
    });
  });

  group('④ 装配层：三个直播页面都接上了三件滚动语义', () {
    /// 静态接线锁：**参数注入型**组件必须查调用点（skill 里记过的同类缺陷第 4 次）。
    void expectWired(String path, List<String> required) {
      final String text = _read(path);
      for (final String token in required) {
        expect(text.contains(token), isTrue,
            reason: path + ' 缺少接线：' + token);
      }
    }

    test('live_room_page / live_studio_page / group_live_page 三页全接', () {
      const List<String> pages = <String>[
        'lib/pages/live_room_page.dart',
        'lib/pages/live_studio_page.dart',
        'lib/pages/group_live_page.dart',
      ];
      for (final String page in pages) {
        expectWired(page, <String>[
          'danmakuController: session.danmakuScroll',
          'onDanmakuScroll: session.handleDanmakuScroll',
          'onScrollToBottom: () => unawaited(session.scrollDanmakuToBottom())',
          'session.pumpScroll()',
        ]);
      }
    });

    test('群内直播必须同步实时帧到历史窗口（此前漏这一步 ⇒ 实时弹幕永不出现）', () {
      expectWired('lib/pages/group_live_page.dart',
          <String>['session.syncRealtimeToHistory()']);
    });

    test('房间体把三件透传给 AylaDanmakuList', () {
      expectWired('lib/widgets/live/live_room_body.dart', <String>[
        'controller: widget.data.danmakuController',
        'onUserScroll: widget.data.onDanmakuScroll',
        'onScrollToBottom: widget.data.onScrollToBottom',
      ]);
    });
  });

  group('⑤ 端到端：图片弹幕帧到达 ⇒ 进入历史窗口且描述符完整', () {
    test('WS 图片帧 + 文字帧都进入历史窗口', () async {
      final AylaLiveState live = AylaLiveState();
      final AylaLiveWsClient ws = AylaLiveWsClient(accessToken: () => null);
      final AylaLiveRoomSession session = AylaLiveRoomSession(
        channelId: 'c1',
        liveState: live,
        liveWs: ws,
        playerFactory: _playerFactory,
        channelFetcher: (String id) async => AylaLiveChannelSnapshot(
            id: id, title: 't', status: AylaLiveStatus.live),
        statusFetcher: (String id) async =>
            const AylaLiveStatusResult(status: AylaLiveSrsStatus.live),
        viewersFetcher: (String id) async =>
            const AylaLiveViewersResult(channelId: 'c1', count: 0),
      );
      addTearDown(session.dispose);
      await session.start();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      ws.debugHandleFrame(_textFrame('111'));
      await Future<void>.delayed(Duration.zero);
      session.syncRealtimeToHistory();

      ws.debugHandleFrame(_imageFrame('112'));
      await Future<void>.delayed(Duration.zero);
      session.syncRealtimeToHistory();

      final List<AylaDanmakuEntry> entries = session.danmakuEntries();
      expect(entries.length, 2,
          reason: '图片弹幕帧不得被丢弃（用户实报「发完大图后刷新不出来」）');
      final AylaDanmakuEntry image =
          entries.firstWhere((AylaDanmakuEntry e) => e.id == '112');
      expect(image.mediaId, 'm-big');
      expect(image.media?.mimeType, 'image/gif');
      expect(image.media?.thumbnail, '/api/v1/media/m-big/thumbnail');
    });
  });
}
