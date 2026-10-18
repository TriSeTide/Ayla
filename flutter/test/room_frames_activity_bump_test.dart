/// P1-1 定向测试：voice/live 事件 → **群卡片往前排**（web `ws/chat.ts` 三处 `bumpGroups`）。
///
/// 事实源（web）：
/// - `ws/chat.ts:102–112` `visibleGroupIds`（归属群 ∪ 白名单群，去重/滤空）；
/// - `ws/chat.ts:114–118` `bumpGroups`（逐 id `bumpGroupActivity`，单调）；
/// - `ws/chat.ts:667–678` `voice.channel.created` → 拉详情后 `bumpGroups(visibleGroupIds(channel))`；
/// - `ws/chat.ts:685–719` `voice.channel.member_count_changed` → **人数增加才 bump**
///   （`Number(d.member_count) > prevCount && prev`，离开/被踢不回退）；
/// - `ws/chat.ts:732–744` `live.channel.status.changed` → 帧 `status === "live"` 才继续，
///   且**详情确认** `channel.status === "live"` 后 bump（下播/结束不回退）；
/// - `live.channel.created` / `.updated`（`:728–731 / :751–755`）**不 bump**。
///
/// 本组用**真实回环 HTTP**（帧只带 channel_id，bump 的群 id 来自 REST 详情）；
/// ⚠️ 不要初始化 `TestWidgetsFlutterBinding`（它换掉 `HttpOverrides.global` ⇒ 请求 400）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/voice_api.dart' show AylaVoiceChannelSnapshot;
import '../lib/core/net/dio_client.dart';
import '../lib/core/ws/chat_ws.dart' show aylaVisibleGroupIds;
import '../lib/core/ws/room_frames.dart';
import '../lib/state/boardgame_store.dart';
import '../lib/state/chat_state.dart';
import '../lib/state/live_state.dart';
import '../lib/state/voice_state.dart';

/// 最小 voice/live 后端：`GET /api/v1/voice/channels/${id}/` + `/live/channels/${id}/`。
class _RoomsBackend {
  /// channelId → 响应体；缺失即 404。
  final Map<String, Map<String, dynamic>> voice = <String, Map<String, dynamic>>{};
  final Map<String, Map<String, dynamic>> live = <String, Map<String, dynamic>>{};

  /// channelId → 状态码覆盖（403/404 静默路径用）。
  final Map<String, int> status = <String, int>{};

  Future<void> handle(HttpRequest request) async {
    final RegExpMatch? v = RegExp('^/api/v1/voice/channels/([^/]+)/\$')
        .firstMatch(request.uri.path);
    final RegExpMatch? l = RegExp('^/api/v1/live/channels/([^/]+)/\$')
        .firstMatch(request.uri.path);
    if (request.method != 'GET' || (v == null && l == null)) {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    final bool isVoice = v != null;
    final RegExpMatch match = (v ?? l)!;
    final String id = match.group(1)!;
    final Map<String, Map<String, dynamic>> table = isVoice ? voice : live;
    final int code = status[id] ?? (table.containsKey(id) ? 200 : 404);
    request.response.statusCode = code;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(
      code == 200 ? table[id]! : <String, dynamic>{'detail': 'not found'},
    ));
    await request.response.close();
  }
}

/// 无令牌 token store（本组不走鉴权；`init` 只为构造 dio 的 baseUrl）。
class _NoTokens implements AuthTokenStore {
  @override
  String? get accessToken => null;

  @override
  String? get refreshToken => null;

  @override
  void setTokens(String access, String? refresh) {}

  @override
  void clear() {}
}

Map<String, dynamic> _voiceBody({
  required String id,
  String? group,
  List<String> allowedGroupIds = const <String>[],
  int memberCount = 0,
}) =>
    <String, dynamic>{
      'id': id,
      'name': '房$id',
      'room_name': 'room_$id',
      'owner_id': 'u1',
      'owner_nickname': '房主',
      'member_count': memberCount,
      'visibility': 'group',
      'group': group,
      'allowed_group_ids': allowedGroupIds,
      'created_at': '2026-10-01T00:00:00Z',
    };

Map<String, dynamic> _liveBody({
  required String id,
  String status = 'live',
  String? group,
  List<String> allowedGroupIds = const <String>[],
}) =>
    <String, dynamic>{
      'id': id,
      'title': '直播$id',
      'description': '',
      'status': status,
      'owner_id': 'u1',
      'owner_nickname': '主播',
      'visibility': 'group',
      'group': group,
      'allowed_group_ids': allowedGroupIds,
      'started_at': '2026-10-01T00:00:00Z',
      'created_at': '2026-10-01T00:00:00Z',
    };

void main() {
  group('aylaVisibleGroupIds（web ws/chat.ts:102–112）', () {
    test('归属群 ∪ 白名单，去重、滤空值', () {
      expect(
        aylaVisibleGroupIds(
          group: 'g1',
          allowedGroupIds: <String>['g1', 'g2', '', 'g3'],
        ),
        <String>['g1', 'g2', 'g3'],
      );
    });

    test('group 为 null/空串时不进集合（web `if (descriptor.group)`）', () {
      expect(
        aylaVisibleGroupIds(group: null, allowedGroupIds: <String>['g2']),
        <String>['g2'],
      );
      expect(
        aylaVisibleGroupIds(group: '', allowedGroupIds: <String>['g2']),
        <String>['g2'],
      );
    });

    test('两者都空 ⇒ 空集合（不 bump 任何群）', () {
      expect(aylaVisibleGroupIds(), isEmpty);
    });
  });

  HttpOverrides.global = null;
  late _RoomsBackend backend;
  late HttpServer server;

  setUpAll(() async {
    backend = _RoomsBackend();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // ignore: unawaited_futures
    server.listen(backend.handle);
    DioClient.instance.debugBaseUrlOverride = 'http://127.0.0.1:${server.port}';
    DioClient.instance.init(tokenStore: _NoTokens(), onSessionExpired: () {});
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  setUp(() {
    backend.voice.clear();
    backend.live.clear();
    backend.status.clear();
  });

  AylaRoomDirectoryBridge bridgeWith({
    required AylaChatState chat,
    AylaVoiceState? voice,
    AylaLiveState? live,
  }) =>
      AylaRoomDirectoryBridge(
        voiceState: voice ?? AylaVoiceState(),
        liveState: live ?? AylaLiveState(),
        boardgameStore: AylaBoardgameStore(),
        currentUserId: () => 'me',
        chatState: chat,
      );

  group('voice.channel.created ⇒ bumpGroups（web chat.ts:667–678 / :674）', () {
    test('建语音房 ⇒ 归属群 + 白名单群都被 bump', () async {
      final AylaChatState chat = AylaChatState();
      backend.voice['v1'] = _voiceBody(
        id: 'v1',
        group: 'g1',
        allowedGroupIds: <String>['g2'],
      );
      final AylaRoomDirectoryBridge bridge = bridgeWith(chat: chat);
      bridge.handleFrame(<String, dynamic>{
        'type': 'voice.channel.created',
        'data': <String, dynamic>{'channel_id': 'v1'},
      });
      await pumpEventQueue();
      expect(chat.groupActivityAt.containsKey('g1'), isTrue,
          reason: 'web :674 bumpGroups(visibleGroupIds(channel)) 含归属群');
      expect(chat.groupActivityAt.containsKey('g2'), isTrue,
          reason: '白名单群同样被 bump');
    });

    test('REST 403 ⇒ 不 bump（web 权限过滤：不可见频道不推进排序）', () async {
      final AylaChatState chat = AylaChatState();
      backend.status['v1'] = 403;
      final AylaRoomDirectoryBridge bridge = bridgeWith(chat: chat);
      bridge.handleFrame(<String, dynamic>{
        'type': 'voice.channel.created',
        'data': <String, dynamic>{'channel_id': 'v1'},
      });
      await pumpEventQueue();
      expect(chat.groupActivityAt, isEmpty);
    });

    test('未注入 chatState ⇒ 不崩、域 store 照常落地', () async {
      final AylaVoiceState voice = AylaVoiceState();
      backend.voice['v1'] = _voiceBody(id: 'v1', group: 'g1');
      final AylaRoomDirectoryBridge bridge = AylaRoomDirectoryBridge(
        voiceState: voice,
        liveState: AylaLiveState(),
        boardgameStore: AylaBoardgameStore(),
        currentUserId: () => 'me',
      );
      bridge.handleFrame(<String, dynamic>{
        'type': 'voice.channel.created',
        'data': <String, dynamic>{'channel_id': 'v1'},
      });
      await pumpEventQueue();
      expect(voice.channelOf('v1'), isNotNull);
    });

    test('voice.channel.updated ⇒ 只 reconcile、不 bump（web :720–727 无 bump）',
        () async {
      final AylaChatState chat = AylaChatState();
      backend.voice['v1'] = _voiceBody(id: 'v1', group: 'g1');
      final AylaVoiceState voice = AylaVoiceState();
      final AylaRoomDirectoryBridge bridge =
          bridgeWith(chat: chat, voice: voice);
      bridge.handleFrame(<String, dynamic>{
        'type': 'voice.channel.updated',
        'data': <String, dynamic>{'channel_id': 'v1'},
      });
      await pumpEventQueue();
      expect(voice.channelOf('v1'), isNotNull, reason: 'REST 对账照常');
      expect(chat.groupActivityAt, isEmpty, reason: 'updated 不 bump');
    });
  });

  group('voice.channel.member_count_changed（web chat.ts:685–719）', () {
    test('人数增加 ⇒ bump 该房可见群（:714–717）', () async {
      final AylaChatState chat = AylaChatState();
      final AylaVoiceState voice = AylaVoiceState();
      // 帧到达前本地已有该房（web :691–694 的 prev 来源）。
      voice.upsertChannel(_snapshotOf(_voiceBody(
        id: 'v1',
        group: 'g1',
        allowedGroupIds: <String>['g2'],
        memberCount: 0,
      )));
      final AylaRoomDirectoryBridge bridge =
          bridgeWith(chat: chat, voice: voice);
      bridge.handleFrame(<String, dynamic>{
        'type': 'voice.channel.member_count_changed',
        'data': <String, dynamic>{'channel_id': 'v1', 'member_count': 1},
      });
      await pumpEventQueue();
      expect(chat.groupActivityAt.containsKey('g1'), isTrue);
      expect(chat.groupActivityAt.containsKey('g2'), isTrue);
    });

    test('人数减少 ⇒ 不 bump（离开/被踢不回退，web 原话）', () async {
      final AylaChatState chat = AylaChatState();
      final AylaVoiceState voice = AylaVoiceState();
      voice.upsertChannel(_snapshotOf(_voiceBody(
        id: 'v1',
        group: 'g1',
        memberCount: 3,
      )));
      final AylaRoomDirectoryBridge bridge =
          bridgeWith(chat: chat, voice: voice);
      bridge.handleFrame(<String, dynamic>{
        'type': 'voice.channel.member_count_changed',
        'data': <String, dynamic>{'channel_id': 'v1', 'member_count': 2},
      });
      await pumpEventQueue();
      expect(chat.groupActivityAt, isEmpty);
    });

    test('人数不变 ⇒ 不 bump（web > prevCount 严格大于）', () async {
      final AylaChatState chat = AylaChatState();
      final AylaVoiceState voice = AylaVoiceState();
      voice.upsertChannel(_snapshotOf(_voiceBody(
        id: 'v1',
        group: 'g1',
        memberCount: 2,
      )));
      final AylaRoomDirectoryBridge bridge =
          bridgeWith(chat: chat, voice: voice);
      bridge.handleFrame(<String, dynamic>{
        'type': 'voice.channel.member_count_changed',
        'data': <String, dynamic>{'channel_id': 'v1', 'member_count': 2},
      });
      await pumpEventQueue();
      expect(chat.groupActivityAt, isEmpty);
    });

    test('本地无该房（prev == null）⇒ 即便帧人数 > 0 也不 bump（web && prev）',
        () async {
      final AylaChatState chat = AylaChatState();
      final AylaVoiceState voice = AylaVoiceState();
      backend.voice['v1'] = _voiceBody(id: 'v1', group: 'g1', memberCount: 0);
      final AylaRoomDirectoryBridge bridge =
          bridgeWith(chat: chat, voice: voice);
      bridge.handleFrame(<String, dynamic>{
        'type': 'voice.channel.member_count_changed',
        'data': <String, dynamic>{'channel_id': 'v1', 'member_count': 5},
      });
      await pumpEventQueue();
      expect(voice.channelOf('v1'), isNotNull, reason: '帧缺排序投影 ⇒ REST 对账照常');
      expect(chat.groupActivityAt, isEmpty);
    });

    test('member_count 缺字段 / 非数字 ⇒ 直接忽略、不 bump', () async {
      final AylaChatState chat = AylaChatState();
      final AylaRoomDirectoryBridge bridge = bridgeWith(chat: chat);
      bridge.handleFrame(<String, dynamic>{
        'type': 'voice.channel.member_count_changed',
        'data': <String, dynamic>{'channel_id': 'v1'},
      });
      await pumpEventQueue();
      expect(chat.groupActivityAt, isEmpty);
    });
  });

  group('live.channel.status.changed（web chat.ts:732–744）', () {
    test('帧 live + 详情 live ⇒ bump 可见群（:737–741）', () async {
      final AylaChatState chat = AylaChatState();
      backend.live['l1'] = _liveBody(
        id: 'l1',
        status: 'live',
        group: 'g1',
        allowedGroupIds: <String>['g2'],
      );
      final AylaRoomDirectoryBridge bridge = bridgeWith(chat: chat);
      bridge.handleFrame(<String, dynamic>{
        'type': 'live.channel.status.changed',
        'data': <String, dynamic>{'channel_id': 'l1', 'status': 'live'},
      });
      await pumpEventQueue();
      expect(chat.groupActivityAt.containsKey('g1'), isTrue);
      expect(chat.groupActivityAt.containsKey('g2'), isTrue);
    });

    test('帧 status != live（下播）⇒ 不 bump（不回退）', () async {
      final AylaChatState chat = AylaChatState();
      backend.live['l1'] = _liveBody(id: 'l1', status: 'ended', group: 'g1');
      final AylaRoomDirectoryBridge bridge = bridgeWith(chat: chat);
      bridge.handleFrame(<String, dynamic>{
        'type': 'live.channel.status.changed',
        'data': <String, dynamic>{'channel_id': 'l1', 'status': 'ended'},
      });
      await pumpEventQueue();
      expect(chat.groupActivityAt, isEmpty);
    });

    test('帧 live 但详情已非 live ⇒ 不 bump（以详情为权威，web :737–741）', () async {
      final AylaChatState chat = AylaChatState();
      backend.live['l1'] = _liveBody(id: 'l1', status: 'ended', group: 'g1');
      final AylaRoomDirectoryBridge bridge = bridgeWith(chat: chat);
      bridge.handleFrame(<String, dynamic>{
        'type': 'live.channel.status.changed',
        'data': <String, dynamic>{'channel_id': 'l1', 'status': 'live'},
      });
      await pumpEventQueue();
      expect(chat.groupActivityAt, isEmpty);
    });

    test('live.channel.created ⇒ 只 reconcile、不 bump（web :728–731）', () async {
      final AylaChatState chat = AylaChatState();
      backend.live['l1'] = _liveBody(id: 'l1', status: 'live', group: 'g1');
      final AylaLiveState live = AylaLiveState();
      final AylaRoomDirectoryBridge bridge =
          bridgeWith(chat: chat, live: live);
      bridge.handleFrame(<String, dynamic>{
        'type': 'live.channel.created',
        'data': <String, dynamic>{'channel_id': 'l1'},
      });
      await pumpEventQueue();
      expect(live.channelOf('l1'), isNotNull);
      expect(chat.groupActivityAt, isEmpty, reason: 'created 不 bump');
    });

    test('live.channel.updated ⇒ 只 reconcile、不 bump（web :751–755）', () async {
      final AylaChatState chat = AylaChatState();
      backend.live['l1'] = _liveBody(id: 'l1', status: 'live', group: 'g1');
      final AylaLiveState live = AylaLiveState();
      final AylaRoomDirectoryBridge bridge =
          bridgeWith(chat: chat, live: live);
      bridge.handleFrame(<String, dynamic>{
        'type': 'live.channel.updated',
        'data': <String, dynamic>{'channel_id': 'l1'},
      });
      await pumpEventQueue();
      expect(live.channelOf('l1'), isNotNull);
      expect(chat.groupActivityAt, isEmpty);
    });
  });

  group('bump 单调性（web stores/chat.ts:85–91）', () {
    test('同一个群连续两条帧 ⇒ 时间戳只前进不乱序', () async {
      final AylaChatState chat = AylaChatState();
      backend.voice['v1'] = _voiceBody(id: 'v1', group: 'g1');
      backend.voice['v2'] = _voiceBody(id: 'v2', group: 'g1');
      final AylaRoomDirectoryBridge bridge = bridgeWith(chat: chat);
      bridge.handleFrame(<String, dynamic>{
        'type': 'voice.channel.created',
        'data': <String, dynamic>{'channel_id': 'v1'},
      });
      await pumpEventQueue();
      final int first = chat.groupActivityAt['g1']!;
      bridge.handleFrame(<String, dynamic>{
        'type': 'voice.channel.created',
        'data': <String, dynamic>{'channel_id': 'v2'},
      });
      await pumpEventQueue();
      expect(chat.groupActivityAt['g1']! >= first, isTrue);
    });
  });
}

/// 目录条目 → 域快照（成员数用；与生产 room_providers 的搬运同口径的最小子集）。
AylaVoiceChannelSnapshot _snapshotOf(Map<String, dynamic> body) =>
    AylaVoiceChannelSnapshot(
      id: body['id'] as String,
      name: body['name'] as String,
      roomName: body['room_name'] as String? ?? '',
      ownerId: body['owner_id'] as String? ?? '',
      ownerNickname: body['owner_nickname'] as String?,
      memberCount: body['member_count'] as int?,
      group: body['group'] as String?,
      allowedGroupIds: <String>[
        for (final Object? id
            in (body['allowed_group_ids'] as List<Object?>? ?? const <Object?>[]))
          if (id is String) id,
      ],
      createdAt: body['created_at'] as String?,
    );
