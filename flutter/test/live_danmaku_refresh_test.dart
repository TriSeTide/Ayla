/// 直播弹幕「第二轮实报」回归锁 —— 用户 2026-10-26 复报：
/// 「发送出去还是没有正常刷出来，还是要退出重进才刷；
///  消息不刷出来但会出现『有新弹幕』的标签和『返回最新消息』，
///  此时点击『有新弹幕』也无法跳转出未刷出的弹幕；
///  头像的在线光环也不是正常显示在线的。」
///
/// ## 第一轮修错了什么（必须记住）
/// 第一轮只补了「谁去滚列表」（pumpScroll/handleDanmakuScroll/scrollDanmakuToBottom），
/// 但**没人让页面重绘**：`AylaCursorHistory` 是 `ChangeNotifier`，
/// 而三个直播页面只 `addListener` 了 `_session` / `_directory` / `_viewerSheet`，
/// **从未监听 history**。于是：
/// 1. 新弹幕 append 后 `items` 变了、`hasNewer` 也亮了 —— 但**页面不重建**
///    ⇒ 列表与提示条都停在上一次构建的快照；
/// 2. 点「返回最新消息」`returnLatest()` 其实**成功**了（数据换成最新、hasNewer 清掉），
///    可页面照样不重建 ⇒ 用户看到「点了没反应」。
/// 这解释了「提示条能出现、但点它毫无作用」这对看似矛盾的现象。
///
/// ## 本文件锁什么
/// ① **转发**：会话把 history 的 notify 转发给自身监听者（一行 `addListener` 都不许漏）；
/// ② **重绘**：history 变更后页面真的重建（`setState` 触发，用 build 计数验证）；
/// ③ **点提示真能跳**：`scrollDanmakuToBottom()` 后列表含新弹幕且贴底；
/// ④ **头像在线实时**：三个页面都传 `senderOnlineOf`（不是旧的默认 false）；
/// ⑤ **发图照样刷**：图片弹幕（大图/动图描述符）到达后列表条目增加。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/live_api.dart';
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

/// WS 客户端（测试直接投喂帧；token=null 不会建真实连接）。
AylaLiveWsClient _ws = AylaLiveWsClient(accessToken: () => null);

AylaLiveRoomSession _session(AylaLiveState live) => AylaLiveRoomSession(
      channelId: 'c1',
      liveState: live,
      liveWs: _ws,
      playerFactory: _playerFactory,
      channelFetcher: (String id) async =>
          AylaLiveChannelSnapshot(id: id, title: 't', status: AylaLiveStatus.live),
      statusFetcher: (String id) async =>
          const AylaLiveStatusResult(status: AylaLiveSrsStatus.live),
      viewersFetcher: (String id) async =>
          const AylaLiveViewersResult(channelId: 'c1', count: 0),
    );

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
        'thumbnail': '/api/v1/media/m-big/thumbnail',
      },
      'created_at': '2026-10-26T10:00:09Z',
    };

String _read(String relative) => File(relative).readAsStringSync();

List<AylaDanmakuEntry> _many() => <AylaDanmakuEntry>[
      for (int i = 0; i < 14; i++)
        AylaDanmakuEntry(
          id: 'e' + i.toString(),
          senderNickname: 'a',
          content: 'c' + i.toString(),
        ),
    ];

Widget _host(AylaLiveRoomSession s, List<AylaDanmakuEntry> items) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 180,
          child: AylaDanmakuList(
            items: items,
            controller: s.danmakuScroll,
            onUserScroll: s.handleDanmakuScroll,
            onScrollToBottom: () {},
          ),
        ),
      ),
    );

void main() {
  group('① 转发：会话必须把 history 的通知转发给页面监听者', () {
    test('append 后会话的监听者收到通知（= 页面能重建）', () async {
      final AylaLiveState live = AylaLiveState();
      final AylaLiveRoomSession session = _session(live);
      addTearDown(session.dispose);
      await session.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      int notifications = 0;
      session.addListener(() => notifications += 1);

      // 走真实路径：WS 帧 -> store -> syncRealtimeToHistory -> history.append
      _ws.debugHandleFrame(_imageFrame('777'));
      session.syncRealtimeToHistory();
      await Future<void>.delayed(Duration.zero);

      expect(notifications, greaterThan(0),
          reason: 'history 的通知必须转发到会话（否则页面永不重绘 —— 第二轮实报根因）');
    });
  });

  group('② 重绘：history 变更后页面真的重建', () {
    testWidgets('监听会话并 setState（与三个直播页同构）⇒ 新弹幕出现在列表', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(400, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final AylaLiveState live = AylaLiveState();
      final AylaLiveRoomSession session = _session(live);
      addTearDown(session.dispose);
      await tester.runAsync(() => session.start());
      await tester.pump();

      // 与 live_room_page 完全同构：_session.addListener(_onChanged) + setState。
      int builds = 0;
      late StateSetter setHostState;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            setHostState = setState;
            builds += 1;
            return _host(session, session.danmakuEntries());
          },
        ),
      );
      await tester.pumpAndSettle();
      session.addListener(() => setHostState(() {}));
      final int before = builds;

      session.history!.append(const AylaLiveDanmaku(
        id: 'new1',
        createdAt: '2026-10-26T10:00:19Z',
        content: 'NEW-DANMAKU',
      ));
      await tester.pumpAndSettle();

      expect(builds, greaterThan(before),
          reason: 'history append 后页面必须重建（否则新弹幕永远不出现）');
      expect(find.text('NEW-DANMAKU'), findsOneWidget,
          reason: '新弹幕必须真的渲染出来（第二轮实报的核心症状）');
    });
  });

  group('③ 点「有新弹幕」真的能跳到底', () {
    testWidgets('未脱挂时 scrollDanmakuToBottom 直接贴底并恢复跟随', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(400, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final AylaLiveState live = AylaLiveState();
      final AylaLiveRoomSession session = _session(live);
      addTearDown(session.dispose);
      await tester.runAsync(() => session.start());
      await tester.pump();

      await tester.pumpWidget(_host(session, _many()));
      await tester.pumpAndSettle();

      final ScrollPosition position = session.danmakuScroll.position;
      expect(position.maxScrollExtent, greaterThan(0.0));

      session.danmakuScroll.jumpTo(0);
      await tester.pump();
      session.handleDanmakuScroll();
      expect(session.history!.following, isFalse, reason: '上翻后应停跟随');

      // 点「有新弹幕」/「返回最新」的实际落点（页面接的就是这个方法）。
      // 注：hasNewer == true 时它会先 returnLatest() 重新读最新一页 —— 本用例
      // 没有网络桩，走的是「未脱挂」这一档，验证的是贴底 + 恢复跟随。
      await tester.runAsync(() => session.scrollDanmakuToBottom());
      await tester.pump();

      expect(position.pixels,
          moreOrLessEquals(position.maxScrollExtent, epsilon: 0.5),
          reason: '点「返回最新」后必须贴底（实报：点了无法跳转出未刷出的弹幕）');
      expect(session.history!.following, isTrue);
    });

    test('hasNewer 时优先 returnLatest（窗口脱挂先重读最新，再贴底）', () async {
      final AylaLiveState live = AylaLiveState();
      final AylaLiveRoomSession session = _session(live);
      addTearDown(session.dispose);
      await session.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      session.history!.setFollowing(false);
      session.history!.append(const AylaLiveDanmaku(
        id: 'h1',
        createdAt: '2026-10-26T10:00:29Z',
        content: 'h1',
      ));
      expect(session.history!.hasNewer, isTrue);

      // 无网络桩 ⇒ returnLatest 失败返回 false，且**不得**把窗口改坏
      // （web 语义："成功读取后再替换窗口，失败保留原页"）。
      final int before = session.history!.items.length;
      await session.scrollDanmakuToBottom();
      expect(session.history!.items.length, before,
          reason: 'returnLatest 失败时必须保留原窗口，不得清空');
      expect(session.history!.hasNewer, isTrue,
          reason: '没读到最新就不能假装已回到最新');
    });
  });

  group('④ 头像在线实时：三个直播页都传 senderOnlineOf', () {
    test('三个页面都接线（静态审计，防再次漏）', () {
      const List<String> pages = <String>[
        'lib/pages/live_room_page.dart',
        'lib/pages/live_studio_page.dart',
        'lib/pages/group_live_page.dart',
      ];
      for (final String page in pages) {
        final String text = _read(page);
        expect(text.contains('senderOnlineOf'), isTrue,
            reason: page + ' 未传 senderOnlineOf（弹幕头像会恒灰环）');
        expect(text.contains('presenceStateProvider'), isTrue,
            reason: page + ' 未订阅 presence（在线态不会实时更新）');
      }
    });

    test('danmakuEntries 按 userId 逐条求值（不再是单一 bool）', () async {
      final AylaLiveState live = AylaLiveState();
      final AylaLiveRoomSession session = _session(live);
      addTearDown(session.dispose);
      await session.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      session.history!.append(const AylaLiveDanmaku(
        id: 'x',
        createdAt: '2026-10-26T10:00:39Z',
        senderUserId: 'u-online',
        content: 'x',
      ));
      final List<AylaDanmakuEntry> entries = session.danmakuEntries(
        senderOnlineOf: (String id) => id == 'u-online',
      );
      expect(entries.single.senderOnline, isTrue,
          reason: '在线发送者应显示在线光环');
    });
  });

  group('⑤ 发图照样刷：图片弹幕帧到达后条目增加', () {
    test('大图/动图描述符完整进入列表', () async {
      final AylaLiveState live = AylaLiveState();
      final AylaLiveRoomSession session = _session(live);
      addTearDown(session.dispose);
      await session.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final int before = session.danmakuEntries().length;
      _ws.debugHandleFrame(_imageFrame('888'));
      session.syncRealtimeToHistory();
      await Future<void>.delayed(Duration.zero);

      final List<AylaDanmakuEntry> after = session.danmakuEntries();
      expect(after.length, greaterThan(before));
      final AylaDanmakuEntry img =
          after.firstWhere((AylaDanmakuEntry e) => e.id == '888');
      expect(img.mediaId, 'm-big');
      expect(img.media?.mimeType, 'image/gif');
    });
  });
}
