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
/// ## 2026-10-26 第二轮（用户复报「还是不自动滚底」）
/// 根因升级为**消费时机**问题：
/// - 旧 `pumpScroll()` **先** `consumeScrollToBottom()` **再**判 `danmakuScroll.hasClients`
///   ⇒ 进房时列表尚未挂载（loading / 播放器占位）就把贴底请求吃掉，之后无人再触发
///   ⇒ 「永远不自动滚底，退出重进才好」；
/// - 且消费挂在**三个页面各自的 build post-frame** 上 ⇒ 页面不重建就没有下一次；
/// - `scrollDanmakuToBottom()` 的脱挂分支在 `returnLatest()` 后立刻 `jumpTo(max)`，
///   但此刻本帧布局还是旧高度 ⇒ 跳旧 max（「点了返回最新没反应」）。
/// ⇒ 现在统一交给 `AylaHistoryScrollBinding`（`widgets/base/history_scroll_binding.dart`）：
/// 列表未挂载时**保留** pending、贴底后连跟几帧覆盖「旧高度」窗口。
///
/// ## 本文件锁什么
/// ① 会话层：新弹幕 append 后列表真的滚到底（web listRef 语义）；
/// ② 会话层：距底<40 继续跟随、上翻即停（web `handleScroll`）；
/// ③ 会话层：`scrollDanmakuToBottom` 未脱挂时直接贴底并重新跟随；
/// ④ 装配层：三个直播页面接线正确，且**不得**再有已废弃的 `pumpScroll` / `onDanmakuScroll`；
/// ⑤ 端到端：图片弹幕帧到达后进入历史窗口（媒体描述符完整）；
/// ⑥ **列表尚未挂载时收到 append，挂载后必须自动贴底**（本轮核心回归锁）。
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
            onUserScroll: null,
            onScrollToBottom: () {},
          ),
        ),
      ),
    );
void main() {
  group('① 会话层：新弹幕 append 后绑定把列表滚到底', () {
    testWidgets('新弹幕 append 后列表真的贴底（web listRef 语义）',
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
      // binding 在 history.notify 时已排 postFrame 消费 => pump 一次就贴底
      await tester.pump();

      expect(
        position.pixels,
        moreOrLessEquals(position.maxScrollExtent, epsilon: 0.5),
        reason: '新弹幕 append 后必须贴底（web useCursorHistory 的 anchor=bottom）',
      );

      // 幂等：置位已消费，再 pump 不应再改滚动位置
      final double before = position.pixels;
      await tester.pump();
      expect(position.pixels, moreOrLessEquals(before, epsilon: 0.5));
    });

    testWidgets('没有新弹幕时不会无端改滚动位置',
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
      await tester.pump();
      await tester.pump();
      expect(session.danmakuScroll.position.pixels,
          moreOrLessEquals(before, epsilon: 0.5));
    });
  });

  group('② 会话层：following 的跟随判定（距底 < 40，web handleScroll）', () {
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
      expect(session.history!.following, isTrue, reason: '贴底 ⇒ 跟随');

      session.danmakuScroll.jumpTo(0);
      await tester.pump();
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
      // 确定性前提：先明确落到底（初值常数 0 时 jumpTo(0) 是 no-op、不会发滚动通知，
      // 那样本条就会「因为没通知」而假绿）。
      session.danmakuScroll.jumpTo(position.maxScrollExtent);
      await tester.pump();
      session.danmakuScroll.jumpTo(0);
      await tester.pump();
      expect(session.history!.following, isFalse, reason: '上翻 ⇒ 停跟随');

      await session.scrollDanmakuToBottom();
      await tester.pump();
      await tester.pump();
      expect(position.pixels,
          moreOrLessEquals(position.maxScrollExtent, epsilon: 0.5),
          reason: '未脱挂 ⇒ 直接贴底（web useDanmaku scrollToBottom 的第二档）');
      expect(session.history!.following, isTrue, reason: '贴底后恢复跟随');
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

    String readText(String path) => _read(path);

    test('live_room_page / live_studio_page / group_live_page 三页全接', () {
      const List<String> pages = <String>[
        'lib/pages/live_room_page.dart',
        'lib/pages/live_studio_page.dart',
        'lib/pages/group_live_page.dart',
      ];
      for (final String page in pages) {
        final String text = readText(page);
        expectWired(page, <String>[
          'danmakuController: session.danmakuScroll',
          'onScrollToBottom: () => unawaited(session.scrollDanmakuToBottom())',
        ]);
        // ⚠️ 反向断言：页面**不得**再自己排帧消费贴底（唯一 owner = 会话内的
        // `AylaHistoryScrollBinding`）。旧的 `addPostFrameCallback(pumpScroll)`
        // 有两个真错：① 页面不重建就没有下一次；② `pumpScroll` 先消费后判
        // `hasClients` ⇒ 列表未挂载时请求被吞（「永不滚底」的直接根因）。
        for (final String banned in <String>[
          'session.pumpScroll()',
          'onDanmakuScroll:',
        ]) {
          expect(text.contains(banned), isFalse,
              reason: page + ' 仍留有已废弃接线：' + banned);
        }
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

  // ======================= ⑥ 本轮核心回归锁 =======================

  group('⑥ 列表尚未挂载时收到 append ⇒ 挂载后必须自动贴底（「永不滚底」根因）', () {
    testWidgets('session.start() 后列表还没挂载：append 的贴底请求不被吞，挂载即贴底',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final AylaLiveState live = AylaLiveState();
      final AylaLiveRoomSession session = _session(live);
      addTearDown(session.dispose);
      // start() 里 await Future.delayed(Duration.zero)：fake clock 下必须 runAsync
      await tester.runAsync(() => session.start());
      await tester.pump();

      final AylaCursorHistory<AylaLiveDanmaku>? history = session.history;
      expect(history, isNotNull);

      // ---- 关键：此刻**列表还没挂载**（没有 AylaDanmakuList 在树上）----
      expect(session.danmakuScroll.hasClients, isFalse,
          reason: '前提：列表尚未挂载（否则本用例复现不了旧根因）');
      history!.setFollowing(true);
      history.append(const AylaLiveDanmaku(
        id: 'boot1',
        createdAt: '2026-10-26T10:00:01Z',
        content: '进房首屏',
      ));
      await tester.pump();
      await tester.pump();
      // ⚠️ 旧实现（`pumpScroll`）在这一步已经把 pending 消费掉了（先消费后判
      // `hasClients`）⇒ 下面挂载后永远贴不上底。本断言锁住「不许吞」。
      expect(history.pendingScrollToBottom, isTrue,
          reason: '列表未挂载时不得消费 pendingScrollToBottom（这是「永不滚底」的根因）');

      // ---- 列表挂载（足够多的条目撑出可滚高度）----
      await tester.pumpWidget(_host(session, _many()));
      await tester.pumpAndSettle();

      final ScrollPosition position = session.danmakuScroll.position;
      expect(position.maxScrollExtent, greaterThan(0.0),
          reason: '列表必须可滚（否则本用例无意义）');
      expect(position.pixels,
          moreOrLessEquals(position.maxScrollExtent, epsilon: 0.5),
          reason: '挂载后必须消费掉进房期间的贴底请求并滚到底');
      expect(history.pendingScrollToBottom, isFalse,
          reason: '消费后必须清位（避免每帧重复跳）');
    });
  });
}
