/// 群 presence 对账定向测试 —— 对照 web `ws/chat.ts:335–378`。
///
/// 覆盖（任务书要求的五档）：
/// 1. **250ms 合并**：窗口内的多条帧只发一次请求（web `:336–343`）；
/// 2. **分批 100**：>100 个群 ⇒ 多次请求，每批 ≤100（web `:354`）；
/// 3. **null ⇒ 移除会话 + 退订**（web `:362–364`）—— Flutter 侧用「请求过但响应里没有」表达；
/// 4. **非 null ⇒ upsert 带 group_presence**（web `:365–366`）；
/// 5. **错误保留原状不误删**（web `:371–373` 只写 realtime 失败档）。
///
/// 另加四条边界：未登录不发请求、私聊不参与、`live.viewers.changed` 不触发、
/// 对账途中账号切换丢弃结果、detach 清窗口。
///
/// 帧注入走真实 `debugHandleFrame`（`AylaChatWsClient` → `onFrame` → 帧桥），
/// 只把 `fetch` 换成内存假后端 —— 被测算的是「合并窗口 + 分批 + 落地」这条真链。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/conversation.dart';
import '../lib/core/ws/chat_ws.dart';
import '../lib/core/ws/group_presence.dart';
import '../lib/core/ws/room_frames.dart';
import '../lib/state/badges_state.dart';
import '../lib/state/boardgame_store.dart';
import '../lib/state/chat_state.dart';
import '../lib/state/live_state.dart';
import '../lib/state/message_state.dart';
import '../lib/state/notices_state.dart';
import '../lib/state/realtime_state.dart';
import '../lib/state/subgroup_state.dart';
import '../lib/state/voice_state.dart';

/// 群会话摘要（对账只用到 id + type）。
AylaConversationSummary _group(String id) => AylaConversationSummary(
      id: id,
      type: AylaConversationType.group,
      title: '群 `id',
    );

/// 私聊会话摘要。
AylaConversationSummary _dm(String id) => AylaConversationSummary(
      id: id,
      type: AylaConversationType.private,
      title: '私聊 `id',
    );

/// 假 presence 后端：记录每次请求的 id 批次，按 `members` 决定谁还「在群里」。
///
/// **缺席即 null**：后端 `GroupPresenceBatchView` 是 `result = dict.fromkeys(ids)`
/// ⇒ 非成员的 id 在响应里是 null；Flutter 的 `getGroupPresence` 会把它过滤掉，
/// 于是「请求过但响应里没有」⇔ web 的 `presence === null`。
class _FakePresence {
  /// 已收到的请求批次。
  final List<List<String>> batches = <List<String>>[];

  /// 仍在群里的会话 id（不在此集合 ⇒ 响应里缺席 = 后端 null）。
  Set<String> members = <String>{};

  /// 各群返回的 presence（缺省 = 三个 flag 全 false）。
  final Map<String, AylaGroupPresence> presenceOf = <String, AylaGroupPresence>{};

  /// 抛错开关（「错误保留原状」用例）。
  bool fail = false;

  /// 请求闸门（null = 立刻返回）；「往返途中」用。
  Completer<void>? gate;

  Future<Map<String, AylaGroupPresence>> call(List<String> ids) async {
    batches.add(List<String>.of(ids));
    final Completer<void>? g = gate;
    if (g != null) await g.future;
    if (fail) throw StateError('网络失败');
    return <String, AylaGroupPresence>{
      for (final String id in ids)
        if (members.contains(id))
          id: presenceOf[id] ?? const AylaGroupPresence(),
    };
  }
}

/// 一套内存状态 + **真实** chat WS 客户端 + **真实**帧桥（只 fetch 是假的）。
class _Harness {
  _Harness({this.me = 'u-me'}) {
    client = AylaChatWsClient(
      chatState: chat,
      messageState: message,
      notices: notices,
      badges: badges,
      realtime: realtime,
      subgroupState: subgroup,
      currentUserId: () => me,
      autoReconcile: false,
    );
    reconciler = AylaGroupPresenceReconciler(
      chatState: chat,
      currentUserId: () => me,
      realtime: realtime,
      unsubscribe: unsubscribed.add,
      fetch: backend.call,
    );
    bridge = AylaRoomDirectoryBridge(
      voiceState: AylaVoiceState(),
      liveState: AylaLiveState(),
      boardgameStore: AylaBoardgameStore(),
      chatState: chat,
      realtime: realtime,
      groupPresence: reconciler,
      currentUserId: () => me,
    );
    bridge.attach(client);
  }

  String? me;
  final AylaChatState chat = AylaChatState();
  final AylaMessageState message = AylaMessageState();
  final AylaNoticesController notices = AylaNoticesController();
  final AylaBadgesController badges = AylaBadgesController();
  final AylaRealtimeState realtime = AylaRealtimeState();
  final AylaSubGroupState subgroup = AylaSubGroupState();
  final _FakePresence backend = _FakePresence();
  final List<String> unsubscribed = <String>[];
  late final AylaChatWsClient client;
  late final AylaGroupPresenceReconciler reconciler;
  late final AylaRoomDirectoryBridge bridge;

  void seed(List<AylaConversationSummary> convs) => chat.setConversations(convs);
}

/// 推一个房间帧（真实线路：client → onFrame → 帧桥）。
void _roomFrame(_Harness h, String type, {String id = 'v1'}) {
  h.client.debugHandleFrame(<String, dynamic>{
    'type': type,
    'data': <String, dynamic>{
      'channel_id': id,
      'room_id': id,
      'member_count': 1,
    },
  });
}

/// 等一轮对账「跑完」—— **轮询而不是固定等待**。
///
/// ⚠️ 全量测试是并发跑的（每文件一个 isolate、互抢 CPU），固定的
/// `250ms + 120ms` 在大负载下会不够 ⇒ 偶发超时（实测全量跑时「分批 100」那条会挂）。
/// 这里用「条件轮询 + 上限」：条件满足即返回，最坏等 [timeout]。
Future<void> _waitFor(
  bool Function() done, {
  Duration timeout = const Duration(seconds: 5),
  String? reason,
}) async {
  final Stopwatch sw = Stopwatch()..start();
  while (!done()) {
    if (sw.elapsed > timeout) {
      fail('等待超时（${reason ?? '未指定'}）：${sw.elapsed.inMilliseconds}ms');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// 等合并窗口 + 对账轮跑完（条件 = 至少发过一次请求且已不再 pending）。
Future<void> _settle(_Harness h) => _waitFor(
      () => h.backend.batches.isNotEmpty && !h.reconciler.isPending,
      reason: 'presence 对账未完成',
    );

void main() {
  group('群 presence 对账（web ws/chat.ts:335–378）', () {
    test('250ms 合并：窗口内多条帧只发一次请求（web :336–343）', () async {
      final _Harness h = _Harness();
      h.seed(<AylaConversationSummary>[_group('g1')]);
      h.backend.members = <String>{'g1'};

      _roomFrame(h, 'voice.channel.created');
      _roomFrame(h, 'live.channel.status.changed');
      _roomFrame(h, 'boardgame.room.updated');
      expect(h.backend.batches, isEmpty, reason: '250ms 窗口未到 ⇒ 还不发');

      await _settle(h);
      expect(h.backend.batches.length, 1, reason: '三条帧合并成一次请求');
      expect(h.backend.batches.single, <String>['g1']);
      expect(h.reconciler.debugRefreshCount, 1);
      expect(h.reconciler.isPending, isFalse);
    });

    test('分批 100：>100 个群 ⇒ 每批 ≤100（web :354）', () async {
      final _Harness h = _Harness();
      h.seed(<AylaConversationSummary>[
        for (int i = 1; i <= 250; i += 1) _group('g`i'),
      ]);
      h.backend.members = <String>{for (int i = 1; i <= 250; i += 1) 'g`i'};

      _roomFrame(h, 'voice.channel.created');
      await _settle(h);

      expect(h.backend.batches.length, 3, reason: '250 个群 = 100 + 100 + 50');
      expect(h.backend.batches[0].length, 100);
      expect(h.backend.batches[1].length, 100);
      expect(h.backend.batches[2].length, 50);
      expect(h.chat.conversations.length, 250, reason: '全部在群里 ⇒ 一条都不删');
    });

    test('null（响应里缺席）⇒ 移除会话 + 退订（web :362–364）', () async {
      final _Harness h = _Harness();
      h.seed(<AylaConversationSummary>[_group('g1'), _group('g2')]);
      // g1 还在群里；g2 已被移出 ⇒ 响应里没有 g2（= 后端的 null）。
      h.backend.members = <String>{'g1'};

      _roomFrame(h, 'voice.channel.deleted');
      await _settle(h);

      expect(
        h.chat.conversations.map((AylaConversationSummary c) => c.id).toList(),
        <String>['g1'],
      );
      expect(h.unsubscribed, <String>['g2'], reason: '被移出 ⇒ 退订该会话');
      expect(h.chat.byId('g2'), isNull);
    });

    test('非 null ⇒ upsert 带上 group_presence（web :365–366）', () async {
      final _Harness h = _Harness();
      h.seed(<AylaConversationSummary>[_group('g1')]);
      h.backend.members = <String>{'g1'};
      h.backend.presenceOf['g1'] = const AylaGroupPresence(live: true, voice: true);
      expect(h.chat.byId('g1')!.groupPresence, isNull,
          reason: '前置：摘要里还没有 presence');

      _roomFrame(h, 'live.channel.status.changed');
      await _settle(h);

      final AylaGroupPresence? p = h.chat.byId('g1')!.groupPresence;
      expect(p, isNotNull);
      expect(p!.live, isTrue);
      expect(p.voice, isTrue);
      expect(p.game, isFalse);
      expect(h.chat.conversations.length, 1);
      expect(h.unsubscribed, isEmpty);
    });

    test('错误保留原状：不删会话、不误判 presence，只写 realtime failed 文案（web :371–373）',
        () async {
      final _Harness h = _Harness();
      h.seed(<AylaConversationSummary>[_group('g1'), _group('g2')]);
      h.backend.fail = true;

      _roomFrame(h, 'voice.channel.created');
      await _settle(h);

      expect(h.chat.conversations.length, 2, reason: '网络失败不得当成「都不在群里」');
      expect(h.unsubscribed, isEmpty);
      final AylaRealtimeStatus status =
          h.realtime.statusOf(AylaRealtimeChannel.chat);
      expect(status.connection, AylaRealtimeConnection.failed);
      expect(status.lastError, kAylaGroupPresenceFailedText);
      expect(h.reconciler.isPending, isFalse, reason: 'finally 收起 pending');
    });

    test('私聊不参与对账（web :352 只取 type === "group"）', () async {
      final _Harness h = _Harness();
      h.seed(<AylaConversationSummary>[_group('g1'), _dm('c1')]);
      h.backend.members = <String>{'g1'};

      _roomFrame(h, 'voice.channel.created');
      await _settle(h);

      expect(h.backend.batches.single, <String>['g1'], reason: '私聊 id 不得进请求');
      expect(h.chat.byId('c1'), isNotNull);
    });

    test('live.viewers.changed 不触发对账（不是 live.channel.* 命名空间，web :946）', () async {
      final _Harness h = _Harness();
      h.seed(<AylaConversationSummary>[_group('g1')]);

      h.client.debugHandleFrame(<String, dynamic>{
        'type': 'live.viewers.changed',
        'data': <String, dynamic>{'channel_id': 'l1', 'viewer_count': 3},
      });
      // 这条要确认「**没有**发生请求」⇒ 只能实打实等过窗口 + 余量（不能用 _settle，
      // 它的条件就是「已发过请求」，永远等不到）。
      await Future<void>.delayed(
        kAylaGroupPresenceWindow + const Duration(milliseconds: 200),
      );

      expect(h.backend.batches, isEmpty);
      expect(h.reconciler.isDirty, isFalse, reason: '队列都不该被登记');
    });

    test('未登录（currentUserId == null）⇒ 不发请求（web :347–348）', () async {
      final _Harness h = _Harness(me: null);
      h.seed(<AylaConversationSummary>[_group('g1')]);

      await h.reconciler.refreshGroupPresence();
      expect(h.backend.batches, isEmpty);
      expect(h.reconciler.debugRefreshCount, 0);
    });

    test('对账途中账号切换 ⇒ 丢弃整批结果（web :349–352 的 actor 守卫）', () async {
      final _Harness h = _Harness();
      h.seed(<AylaConversationSummary>[_group('g1'), _group('g2')]);
      h.backend.members = <String>{'g2'}; // g1 本应被移除
      h.backend.gate = Completer<void>();

      final Future<void> flight = h.reconciler.refreshGroupPresence();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      h.me = 'u-other'; // 往返途中账号变了
      h.backend.gate!.complete();
      await flight;

      expect(h.chat.byId('g1'), isNotNull, reason: '账号已变 ⇒ 旧账号结果不落地');
      expect(h.unsubscribed, isEmpty);
    });

    test('detach 清掉合并窗口与在飞标记（web :968–976）', () async {
      final _Harness h = _Harness();
      h.seed(<AylaConversationSummary>[_group('g1')]);
      h.backend.members = <String>{'g1'};

      _roomFrame(h, 'voice.channel.created'); // 起 timer
      expect(h.reconciler.isDirty, isTrue);
      h.bridge.detach();
      expect(h.reconciler.isDirty, isFalse);

      // 这里要**确认「什么都没发生」**，只能实打实等过窗口 + 余量。
      await Future<void>.delayed(
        kAylaGroupPresenceWindow + const Duration(milliseconds: 200),
      );
      expect(h.backend.batches, isEmpty, reason: 'timer 已取消 ⇒ 不再发请求');
    });
  });
}