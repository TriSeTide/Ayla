/// 桌游全局 store 定向测试 —— 事实源：`Ayla/web/src/stores/boardgame.ts`（99 行）。
///
/// 口径：只锁**可指到 web 行号**的语义 —— 降序排序（51）、upsert 的原位替换 vs
/// 插头部（74–84）、removeRoom（86–89，不回退排序）、reset（91）、isStale（95–98）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/boardgame_api.dart' show AylaDirectoryGameEntry;
import '../lib/core/api/directory_page.dart' show AylaDirectoryPage;
import '../lib/core/models/game_room.dart';
import '../lib/core/models/user_public.dart';
import '../lib/state/boardgame_store.dart';
import '../lib/core/net/dio_client.dart';
import '../lib/core/ws/room_frames.dart';
import '../lib/state/directory_events.dart'
    show AylaDirectoryEvents, AylaDirectoryKind;
import '../lib/state/directory_store.dart'
    show AylaDirectoryOptions, AylaDirectoryStore;
import '../lib/state/live_state.dart';
import '../lib/state/voice_state.dart';

/// 构造一个房间（`created_at` 参与排序，故可注入）。
AylaGameRoom _room(int id, {String? createdAt, String name = 'R'}) =>
    AylaGameRoom(
      id: id,
      name: name,
      owner: const AylaUserPublic(id: 'u1', nickname: '房主'),
      ownerId: 'u1',
      status: AylaGameRoomStatus.waiting,
      createdAt: createdAt,
    );

/// 目录取页 → 全局 store 的落地钩子（web `stores/directory.ts:310–320`）。
///
/// web 在 `loadDirectory` 的取页成功回调里把 `results` 逐条
/// `useBoardgameStore.getState().upsertRoom(item)`；Flutter 侧的等价物是
/// `AylaDirectoryStore.itemUpsertHooks`（通用件只给承接口，**由 state 层注入**）。
/// 本组证明「目录页拉到的房间真的会进全局表」—— 这是群活跃度/存在性角标
/// 在「没打开过桌游页」时也有数据的**唯一**来源。
void _directoryHookTests() {
  test('目录取页落地 ⇒ game store 收到逐条 upsert（web stores/directory.ts:310–320）', () async {
    final AylaBoardgameStore store = AylaBoardgameStore();
    final AylaDirectoryStore directory = AylaDirectoryStore();
    directory.itemUpsertHooks[AylaDirectoryKind.game] = (Object item) {
      if (item is! AylaDirectoryGameEntry) return;
      store.upsertRoom(item.room);
    };
    directory.requestOverride = (kind, options, cursor) async =>
        AylaDirectoryPage<Object>(
          results: <Object>[
            AylaDirectoryGameEntry.fromJson(<String, dynamic>{
              'id': 1,
              'name': '甲',
              'created_at': '2026-01-01T00:00:00Z',
              'status': 'waiting',
            })!,
            AylaDirectoryGameEntry.fromJson(<String, dynamic>{
              'id': 2,
              'name': '乙',
              'created_at': '2026-01-02T00:00:00Z',
              'status': 'waiting',
            })!,
          ],
          nextCursor: null,
          hasMore: false,
          total: 2,
        );

    await directory.load(
      AylaDirectoryKind.game,
      const AylaDirectoryOptions(filter: 'all'),
    );
    expect(
      store.rooms.map((AylaGameRoom r) => r.id).toList(),
      <int>[2, 1],
      reason: 'upsert 不存在即插头部（web 74–84）⇒ 逐条循环后顺序与取页顺序相反，web 同',
    );
  });

  test('未注册钩子 ⇒ 不落地（缺失即不落，不伪造）', () async {
    final AylaBoardgameStore store = AylaBoardgameStore();
    final AylaDirectoryStore directory = AylaDirectoryStore();
    directory.requestOverride = (kind, options, cursor) async =>
        AylaDirectoryPage<Object>(
          results: <Object>[
            AylaDirectoryGameEntry.fromJson(<String, dynamic>{
              'id': 3,
              'name': '丙',
              'created_at': '2026-01-03T00:00:00Z',
              'status': 'waiting',
            })!,
          ],
          nextCursor: null,
          hasMore: false,
          total: 1,
        );
    await directory.load(
      AylaDirectoryKind.game,
      const AylaDirectoryOptions(filter: 'all'),
    );
    expect(store.rooms, isEmpty);
  });
}

/// `boardgame.room.created/updated` ⇒ 拉 REST 详情 ⇒ `upsertRoom`
/// （web `ws/chat.ts:845–851 / 857–865`）。
///
/// 与 `posts_frames_test.dart` 同一套纪律：**真实回环 HTTP**（帧只带 `id`，
/// upsert 落地的是 `GET /boardgame/rooms/<id>/` 的响应）—— 纯 mock store 会把这个
/// 环节整个跳过。⚠️ 不要初始化 `TestWidgetsFlutterBinding`（它把
/// `HttpOverrides.global` 换成 mock ⇒ 任何请求返回 400）。
void _reconcileFromFrames() {
  HttpOverrides.global = null;
  late _BoardgameBackend backend;
  late HttpServer server;

  setUpAll(() async {
    backend = _BoardgameBackend();
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
    backend.rooms.clear();
    backend.status.clear();
  });

  test('boardgame.room.created ⇒ REST 详情 upsert 进全局表', () async {
    final AylaBoardgameStore store = AylaBoardgameStore();
    backend.rooms[6] = <String, dynamic>{
      'id': 6,
      'name': '狼人杀',
      'owner': <String, dynamic>{'id': 'u1', 'nickname': '阿蓝'},
      'owner_id': 'u1',
      'status': 'waiting',
      'allowed_group_ids': <String>['g1'],
      'created_at': '2026-10-01T00:00:00Z',
    };
    final AylaRoomDirectoryBridge bridge = AylaRoomDirectoryBridge(
      voiceState: AylaVoiceState(),
      liveState: AylaLiveState(),
      directory: AylaDirectoryEvents(),
      boardgameStore: store,
      currentUserId: () => 'me',
    );
    bridge.handleFrame(<String, dynamic>{
      'type': 'boardgame.room.created',
      'room': <String, dynamic>{'id': '6'},
    });
    await pumpEventQueue();
    expect(store.rooms.single.id, 6);
    expect(store.rooms.single.name, '狼人杀');
    expect(store.rooms.single.owner.displayName, '阿蓝');
    expect(store.rooms.single.allowedGroupIds, <String>['g1']);
  });

  test('403/404 静默：不 upsert、不抛错（web catch 原话）', () async {
    final AylaBoardgameStore store = AylaBoardgameStore();
    backend.status[6] = 403;
    final AylaRoomDirectoryBridge bridge = AylaRoomDirectoryBridge(
      voiceState: AylaVoiceState(),
      liveState: AylaLiveState(),
      directory: AylaDirectoryEvents(),
      boardgameStore: store,
      currentUserId: () => 'me',
    );
    bridge.handleFrame(<String, dynamic>{
      'type': 'boardgame.room.updated',
      'room': <String, dynamic>{'id': '6'},
    });
    await pumpEventQueue();
    expect(store.rooms, isEmpty);
  });
}

/// 最小桌游后端（只实现 `GET /boardgame/rooms/<id>/`）。
class _BoardgameBackend {
  /// roomId → 响应体；缺失即 404。
  final Map<int, Map<String, dynamic>> rooms = <int, Map<String, dynamic>>{};

  /// roomId → 状态码覆盖（403/404 静默路径用）。
  final Map<int, int> status = <int, int>{};

  Future<void> handle(HttpRequest request) async {
    final RegExpMatch? match = RegExp(r'^/api/v1/boardgame/rooms/(\d+)/$')
        .firstMatch(request.uri.path);
    if (request.method == 'GET' && match != null) {
      final int id = int.parse(match.group(1)!);
      final int code = status[id] ?? (rooms.containsKey(id) ? 200 : 404);
      request.response.statusCode = code;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(
        code == 200 ? rooms[id]! : <String, dynamic>{'detail': 'not found'},
      ));
      await request.response.close();
      return;
    }
    request.response.statusCode = 404;
    await request.response.close();
  }
}

/// 无令牌 token store（本组不打鉴权路径；`init` 只为构造 dio 的 baseUrl）。
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

void main() {
  group('AylaBoardgameStore（web stores/boardgame.ts）', () {
    test('setRooms：created_at 降序 + lastFetched 落地 + 清 error', () {
      final AylaBoardgameStore store = AylaBoardgameStore();
      store.setError('旧错误');
      store.setRooms(<AylaGameRoom>[
        _room(1, createdAt: '2026-01-01T00:00:00Z'),
        _room(3, createdAt: '2026-03-01T00:00:00Z'),
        _room(2, createdAt: '2026-02-01T00:00:00Z'),
      ]);
      // web 51：`b.created_at.localeCompare(a.created_at)`（降序）。
      expect(
        store.rooms.map((AylaGameRoom r) => r.id).toList(),
        <int>[3, 2, 1],
      );
      expect(store.roomsLoading, isFalse);
      expect(store.error, isNull);
      expect(store.lastFetched, isNotNull);
      expect(store.loaded, isTrue);
    });

    test('setRooms：created_at 缺席排最后（不造时间戳）', () {
      final AylaBoardgameStore store = AylaBoardgameStore();
      store.setRooms(<AylaGameRoom>[
        _room(1),
        _room(2, createdAt: '2026-01-01T00:00:00Z'),
      ]);
      expect(
        store.rooms.map((AylaGameRoom r) => r.id).toList(),
        <int>[2, 1],
      );
    });

    test('setRooms：同 created_at 保持原索引顺序（Dart sort 不稳定 ⇒ 显式稳定化）', () {
      final AylaBoardgameStore store = AylaBoardgameStore();
      const String t = '2026-01-01T00:00:00Z';
      store.setRooms(<AylaGameRoom>[
        _room(11, createdAt: t),
        _room(12, createdAt: t),
        _room(13, createdAt: t),
        _room(14, createdAt: t),
      ]);
      expect(
        store.rooms.map((AylaGameRoom r) => r.id).toList(),
        <int>[11, 12, 13, 14],
      );
    });

    test('upsertRoom：不存在插到头部；已存在原位替换（web 74–84）', () {
      final AylaBoardgameStore store = AylaBoardgameStore();
      store.setRooms(<AylaGameRoom>[
        _room(1, createdAt: '2026-01-01T00:00:00Z'),
        _room(2, createdAt: '2026-01-02T00:00:00Z'),
      ]);
      // 不存在 ⇒ 插到头部（即使它的 created_at 很旧 —— upsert **不重排**）。
      store.upsertRoom(_room(9, createdAt: '2000-01-01T00:00:00Z', name: '新'));
      expect(
        store.rooms.map((AylaGameRoom r) => r.id).toList(),
        <int>[9, 2, 1],
      );
      // 已存在 ⇒ **原位替换**（位置不变）。
      store.upsertRoom(_room(2, createdAt: '2026-01-02T00:00:00Z', name: '改名'));
      expect(
        store.rooms.map((AylaGameRoom r) => r.id).toList(),
        <int>[9, 2, 1],
      );
      expect(store.rooms[1].name, '改名');
      expect(store.rooms.length, 3);
    });

    test('removeRoom：移除命中项、其余顺序不动（不回退排序，web 86–89）', () {
      final AylaBoardgameStore store = AylaBoardgameStore();
      store.setRooms(<AylaGameRoom>[
        _room(1, createdAt: '2026-01-03T00:00:00Z'),
        _room(2, createdAt: '2026-01-02T00:00:00Z'),
        _room(3, createdAt: '2026-01-01T00:00:00Z'),
      ]);
      store.removeRoom(2);
      expect(
        store.rooms.map((AylaGameRoom r) => r.id).toList(),
        <int>[1, 3],
      );
      // 未命中 ⇒ 不通知（避免无意义重建）。
      int notifications = 0;
      store.addListener(() => notifications += 1);
      store.removeRoom(999);
      expect(notifications, 0);
    });

    test('reconcileRooms：整表替换 + 降序（web 59–70）', () {
      final AylaBoardgameStore store = AylaBoardgameStore();
      store.upsertRoom(_room(99));
      store.reconcileRooms(<AylaGameRoom>[
        _room(1, createdAt: '2026-01-01T00:00:00Z'),
        _room(2, createdAt: '2026-01-05T00:00:00Z'),
      ]);
      expect(
        store.rooms.map((AylaGameRoom r) => r.id).toList(),
        <int>[2, 1],
      );
      expect(store.lastFetched, isNotNull);
    });

    test('setRoomsLoading / setError（web 57 / 72）', () {
      final AylaBoardgameStore store = AylaBoardgameStore();
      int notifications = 0;
      store.addListener(() => notifications += 1);
      store.setRoomsLoading(true);
      store.setRoomsLoading(true); // 同值 ⇒ 不重复通知
      expect(store.roomsLoading, isTrue);
      expect(notifications, 1);
      store.setError('拉取失败');
      expect(store.error, '拉取失败');
      expect(notifications, 2);
    });

    test('reset：四字段回初始态（web 91 的 set({ ...INITIAL })）', () {
      final AylaBoardgameStore store = AylaBoardgameStore();
      store.setRooms(<AylaGameRoom>[_room(1, createdAt: '2026-01-01T00:00:00Z')]);
      store.setRoomsLoading(true);
      store.setError('x');
      store.reset();
      expect(store.rooms, isEmpty);
      expect(store.roomsLoading, isFalse);
      expect(store.error, isNull);
      expect(store.lastFetched, isNull);
      expect(store.loaded, isFalse);
    });

    test('isStale：从未取到 ⇒ true；窗口内 ⇒ false；超窗 ⇒ true（web 95–98）', () {
      final AylaBoardgameStore store = AylaBoardgameStore();
      // web：`if (!lastFetched) return true` —— 未知不当「新鲜」。
      expect(store.isStale(), isTrue);
      store.setRooms(<AylaGameRoom>[]);
      expect(store.isStale(maxAgeMs: kAylaBoardgameFreshWindowMs), isFalse);
      // 负窗口 ⇒ 任何已落地数据都算过期。
      expect(store.isStale(maxAgeMs: -1), isTrue);
    });
  });

  group('目录取页落地钩子（web stores/directory.ts:310–320）', _directoryHookTests);

  group('boardgame 帧 → 全局表（web ws/chat.ts:845–865）', _reconcileFromFrames);
}
