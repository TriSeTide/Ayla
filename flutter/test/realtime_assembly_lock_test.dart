/// 2026-10-20 热更新审计发现的**装配层与数据源层**缺陷回归锁。
///
/// 本次审计（三路只读审计 + 真实后端实测）确认：WS 协议层、帧解包、41 条 case 分发、
/// subscribe/resume 基线、未读/已读算法**都与 web 等价**（既有单测全绿、后端实测帧
/// 也正常下发）。真正的缺陷在**装配生命周期**与**页面数据源**两层 —— 这正是
/// 「单测绿但真机不热更新」的根因形态。本文件锁住这几条旧测试覆盖不到的缺陷。
///
/// 逐条对应（详见 `docs/flutter/23-ws热更新审计-A.md` / `24-…-B.md` / `25-…-C.md`）：
/// | # | 缺陷 | 本文件的锁 |
/// |---|---|---|
/// | **R1** | 目录订阅通路只在启动期装配一次，登出/401 后被拆、**永不重装** | ① stop() 后 isTracking=false；start() 后恢复 |
/// | **R3** | `boardgame.room.deleted` 是**顶层** `room_id`，`_roomId` 读不到 ⇒ 整帧丢弃 | ② 真实帧形状（无 room / 无 data）必须能删掉条目 |
/// | **D2** | `WsChannel.connect()` 无幂等 ⇒ 登录链开两条 socket | ③ 第二次 connect() 不得再调 connectFactory |
///
/// ## 纪律
/// 这些锁只断言**契约**（谁读谁、什么变了必须可见），不锁实现细节；
/// 未来若再改架构，只要契约仍成立这些测试就该继续绿。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/boardgame_api.dart' show AylaDirectoryGameEntry;
import '../lib/core/api/directory_page.dart' show AylaDirectoryPage;
import '../lib/core/api/voice_api.dart'
    show AylaDirectoryVoiceEntry, AylaVoiceChannelSnapshot;
import '../lib/widgets/voice/voice_channels.dart' show AylaVoiceCardData;
import '../lib/core/net/dio_client.dart' show AuthTokenStore;
import '../lib/core/ws/room_frames.dart';
import '../lib/core/ws/ws_manager.dart';
import '../lib/state/boardgame_store.dart';
import '../lib/state/chat_state.dart';
import '../lib/state/directory_events.dart' show AylaDirectoryKind;
import '../lib/state/directory_store.dart';
import '../lib/state/directory_tracking.dart';
import '../lib/state/live_state.dart';
import '../lib/state/realtime_state.dart';
import '../lib/state/voice_state.dart';
import '../lib/core/models/chat_message.dart' show AylaMessageType;
import '../lib/core/models/conversation.dart'
    show
        AylaConversationSummary,
        AylaConversationType,
        AylaLastMessagePreview;
import '../lib/core/models/game_room.dart' show AylaGameCardData, AylaGameRoom;
import '../lib/core/models/post.dart' show AylaPost;
import '../lib/core/ws/posts_frames.dart' show AylaPostsFramesBridge;
import '../lib/state/paged_list.dart' show AylaPagedList;
import '../lib/state/posts_store.dart'
    show AylaPostTabCache, AylaPostsStore;
import '../lib/core/models/user_public.dart' show AylaUserPublic;
import '../lib/state/social_store.dart'
    show
        AylaSocialController,
        AylaSocialKind,
        AylaSocialOptions,
        AylaSocialStore,
        AylaSocialTracking;
import '../lib/state/subgroup_state.dart' show AylaSubGroupState;

/// 快照 → 目录条目（与 production 的 `directory_tracking.dart` 投影同口径）。
AylaDirectoryVoiceEntry _voiceEntryOf(AylaVoiceChannelSnapshot c) =>
    AylaDirectoryVoiceEntry(
      card: AylaVoiceCardData(
        id: c.id,
        name: c.name,
        memberCount: c.memberCount,
      ),
      ownerId: c.ownerId,
      isOwner: c.mine,
      allowedGroupIds: c.allowedGroupIds,
      createdAt: c.createdAt,
      lastOccupiedAt: c.lastOccupiedAt,
      lastVacantAt: c.lastVacantAt,
    );

AylaGameRoom _room(int id, {String name = 'room'}) => AylaGameRoom(
      id: id,
      name: name,
      owner: const AylaUserPublic(id: 'u1'),
      ownerId: 'u1',
      status: null,
      allowedGroupIds: const <String>['g1'],
      createdAt: '2026-10-01T00:00:00Z',
    );

/// 构造一条帖子（各测试共用；字段只取断言需要的）。
AylaPost _post(
  int id, {
  String title = '帖子',
  String body = '正文',
  String authorId = 'u2',
  List<String> allowedGroupIds = const <String>[],
}) =>
    AylaPost(
      id: id,
      title: title,
      body: body,
      authorId: authorId,
      allowedGroupIds: allowedGroupIds,
      createdAt: '2026-10-01T00:00:00Z',
    );

class _Tokens implements AuthTokenStore {
  _Tokens(this._access);

  String? _access;

  @override
  String? get accessToken => _access;

  @override
  String? get refreshToken => null;

  @override
  void clear() => _access = null;

  @override
  void setTokens(String access, String? refresh) => _access = access;
}

void main() {
  group('R1 — 目录订阅通路必须可重装（登出 → 再登录）', () {
    test('stop() 后 isTracking=false；start() 重挂后恢复', () {
      final AylaVoiceState voice = AylaVoiceState();
      final AylaLiveState live = AylaLiveState();
      final AylaBoardgameStore boardgame = AylaBoardgameStore();
      final AylaDirectoryStore store = AylaDirectoryStore();
      final AylaDirectoryTracking tracking = AylaDirectoryTracking();
      addTearDown(tracking.stop);

      store.userId = 'u1';
      tracking.start(
        voiceState: voice,
        liveState: live,
        boardgameStore: boardgame,
        currentUserId: () => 'u1',
        store: store,
      );
      expect(tracking.isTracking, isTrue, reason: 'start() 后必须处于跟踪态');

      // 登出：与 aylaStopRooms* 里的 `aylaStopDirectoryTracking()` 同一条调用。
      tracking.stop();
      expect(
        tracking.isTracking,
        isFalse,
        reason: 'stop() 后必须为 false（否则拆除没生效，R1 的一半就没了）',
      );

      // 重新登录：必须能重装（本次 R1 修复让登录链显式调用它）。
      // ⚠️ 修复前 `aylaStartRoomFramesForRef` 等重装函数**全仓零调用点** ⇒
      // 登出后再登录，目录桥/帧桥至今仍是拆掉的状态，直到重启 App。
      tracking.start(
        voiceState: voice,
        liveState: live,
        boardgameStore: boardgame,
        currentUserId: () => 'u1',
        store: store,
      );
      expect(tracking.isTracking, isTrue, reason: '重装后必须恢复跟踪（R1 核心断言）');
    });
  });

  group('R3 — boardgame.room.deleted 的**真实**帧形状（顶层 room_id）', () {
    test('只有 {type, room_id}、无 room、无 data ⇒ 仍能取到 id 并删掉条目', () async {
      final AylaDirectoryStore store = AylaDirectoryStore();
      final AylaBoardgameStore boardgame = AylaBoardgameStore();
      final AylaLiveState live = AylaLiveState();
      final AylaVoiceState voice = AylaVoiceState();
      final AylaChatState chat = AylaChatState();
      final AylaRealtimeState realtime = AylaRealtimeState();
      final AylaRoomDirectoryBridge bridge = AylaRoomDirectoryBridge(
        voiceState: voice,
        liveState: live,
        boardgameStore: boardgame,
        chatState: chat,
        realtime: realtime,
        currentUserId: () => 'u1',
        directoryStore: store,
      );
      addTearDown(() => store.requestOverride = null);
      store.userId = 'u1';

      // 先让 record 里有一条（模拟列表已加载过该房间）。
      store.requestOverride = (
        AylaDirectoryKind kind,
        AylaDirectoryOptions options,
        String? cursor,
      ) async {
        if (kind != AylaDirectoryKind.game) {
          return const AylaDirectoryPage<Object>(
            results: <Object>[],
            total: 0,
          );
        }
        return AylaDirectoryPage<Object>(
          results: <Object>[
            AylaDirectoryGameEntry(
              card: AylaGameCardData(id: '42', name: 'r42'),
              room: _room(42, name: 'r42'),
              ownerId: 'u1',
            ),
          ],
          total: 1,
        );
      };
      await store.load(
        AylaDirectoryKind.game,
        const AylaDirectoryOptions(groupId: 'g1'),
      );
      expect(
        store
            .itemsAs<AylaDirectoryGameEntry>(
              AylaDirectoryKind.game,
              const AylaDirectoryOptions(groupId: 'g1'),
            )
            .length,
        1,
        reason: '前置：record 里已有该房间',
      );

      // ⚠️ **真实帧**：顶层 room_id，**没有** room、**没有** data。
      // 旧实现（只读 frame['room']['id'] 或 frame['data']['room_id']）会解析出空串，
      // 在 `if (id.isEmpty) return` 处静默丢弃 ⇒ 本断言必红。
      bridge.handleFrame(<String, dynamic>{
        'type': 'boardgame.room.deleted',
        'room_id': '42',
      });

      expect(
        store.itemsAs<AylaDirectoryGameEntry>(
          AylaDirectoryKind.game,
          const AylaDirectoryOptions(groupId: 'g1'),
        ),
        isEmpty,
        reason: '顶层 room_id 的删除帧必须真的删掉条目（R3）',
      );
    });
  });

  group('D2 — WsChannel.connect() 幂等', () {
    test('第二次 connect() 不得再调 connectFactory（登录链会连调两次）', () async {
      int opened = 0;
      final WsChannel channel = WsChannel(
        kind: WsChannelKind.chat,
        path: '/ws/chat/',
        heartbeatInterval: const Duration(seconds: 30),
        tokens: _Tokens('tok'),
        refreshTokens: () async => true,
        connectFactory: (Uri uri) {
          opened += 1;
          // 首次建连直接抛 ⇒ 通道进 connecting 态，但不会真的开 socket
          // （本用例只断言「第二次有没有再调工厂」，不关心连接本身）。
          throw StateError('本用例不建真 socket');
        },
      );
      addTearDown(channel.disconnect);

      // 模拟登录链：`wsManager.connectAll()` 后紧跟 `client.connect()`（两次）。
      // 第一次会抛（connectWithToken 的 catch 转 `_scheduleReconnect`），
      // 之后 status 停在 connecting —— 正是「已有一份连接在建立」的语义。
      channel.connect();
      await Future<void>.delayed(Duration.zero);
      expect(opened, 1, reason: '首次 connect() 必须调一次工厂');

      channel.connect();
      await Future<void>.delayed(Duration.zero);
      expect(
        opened,
        1,
        reason: '第二次 connect() 不得再调工厂（D2：否则泄漏一条活连接）',
      );
    });
  });

  group('D1 — 私信列表必须读共享 social store（WS message.new 自动可见）', () {
    test('chatState.setLastMessage ⇒ social record 的会话预览自动更新', () async {
      final AylaSocialStore social = AylaSocialStore();
      final AylaChatState chat = AylaChatState();
      final AylaSubGroupState subgroups = AylaSubGroupState();
      final AylaSocialTracking tracking =
          AylaSocialTracking(store: social)..bind(
            chatState: chat,
            subgroupState: subgroups,
          );
      addTearDown(tracking.dispose);
      social.userId = 'u1';

      // 页面加载过一次私信列表 —— 必须先 `load()` 把 record 建出来
      //（`setItems` 对不存在的 record 是 no-op，`social_store.dart` 的
      // `if (current == null) return;`）。
      addTearDown(() => social.requestOverride = null);
      social.requestOverride = (
        AylaSocialKind kind,
        AylaSocialOptions options,
        String? cursor,
      ) async =>
          const AylaDirectoryPage<Object>(
        results: <Object>[
          AylaConversationSummary(
            id: 'c1',
            type: AylaConversationType.private,
            title: '小樱',
            isPinned: false,
          ),
        ],
        total: 1,
      );
      await social.load(
        AylaSocialKind.conversations,
        const AylaSocialOptions(type: 'private'),
      );
      // 页面控制器的读投影（= 本次修复后 messages_page / chat_support 的数据源）。
      final AylaSocialController<AylaConversationSummary> page =
          AylaSocialController<AylaConversationSummary>(
        store: social,
        kind: AylaSocialKind.conversations,
        options: const AylaSocialOptions(type: 'private'),
      );
      addTearDown(page.dispose);
      expect(page.items.single.lastMessage, isNull, reason: '前置：还没有最后消息');

      // 基线：先让 chatState 里也有这条会话（tracking 首次对账时记住它）。
      chat.upsertConversation(const AylaConversationSummary(
        id: 'c1',
        type: AylaConversationType.private,
        title: '小樱',
        isPinned: false,
      ));

      // ⚠️ **这就是 message.new 的效应**（`chat_ws.dart:_onMessageNew` 末尾做的
      // `setLastMessage`）。修复前页面读的是**页面私有快照**，这一步只改 chatState
      // ⇒ 界面纹丝不动（D1）。现在页面读共享 store ⇒ 必须立刻可见。
      chat.setLastMessage(
        'c1',
        const AylaLastMessagePreview(
          seq: 5,
          type: AylaMessageType.text,
          content: '在吗',
          senderId: 'u2',
          senderName: '小樱',
          status: 'sent',
          createdAt: '2026-10-02T00:00:00Z',
          preview: '在吗',
        ),
      );

      expect(
        page.items.single.lastMessage?.content,
        '在吗',
        reason: 'D1：message.new 后列表必须自动出现新消息预览'
            '（旧实现读页面私有快照 ⇒ 恒 null）',
      );
    });
  });

  group('P1 — 一级帖子页：帧桥必须在页面之外维护 tab 快照', () {
    test('页面被导航走期间到达的 post.created 仍进入 tab 缓存，返回后立即可见', () async {
      // 用户实报：「群外发帖刷不出来、群内可以」。
      // 根因：tab 缓存只有页面级 chat.onFrame 会写；页面被导航走就解绑，
      // 期间 post.created 丢失；返回时又命中 60s 窗口不重拉。
      final AylaPostTabCache cache = AylaPostTabCache();
      // ⚠️ 只由 cache 负责释放 pager（cache.clear 会 dispose 它）——
      // 再单独 addTearDown(pager.dispose) 会双 dispose。
      addTearDown(cache.clear);
      final AylaPagedList<AylaPost> pager = AylaPagedList<AylaPost>(
        request: (String? cursor) async => const AylaDirectoryPage<AylaPost>(
          results: <AylaPost>[],
          total: 0,
        ),
        keyOf: (AylaPost p) => p.id.toString(),
      );
      const String key = 'posts:u1:all';
      cache.acquire(key, create: () => pager);
      await pager.load();
      cache.markUpdated(key);
      expect(pager.items, isEmpty, reason: '前置：该 tab 首屏为空');

      // 帧桥（页面未挂载，模拟用户停在详情页）
      final AylaPostsFramesBridge bridge = AylaPostsFramesBridge(
        postsStore: AylaPostsStore(),
        chatState: AylaChatState(),
        currentUserId: () => 'u1',
        postTabCache: cache,
      );
      bridge.mergePostIntoTabsForTest(_post(99));

      expect(
        cache.pagerOf(key)!.items.map((AylaPost p) => p.id),
        <int>[99],
        reason: 'P1：页面未挂载时帧桥也必须把新帖合进 tab 快照'
            '（修复前只有页面级监听会做 ⇒ 导航期间丢失）',
      );
    });

    test('post.deleted 在页面未挂载时也要从全部 tab 摘除', () {
      final AylaPostTabCache cache = AylaPostTabCache();
      addTearDown(cache.clear); // cache.clear 负责 dispose pager（勿再单独 dispose）
      final AylaPagedList<AylaPost> pager = AylaPagedList<AylaPost>(
        request: (String? cursor) async => const AylaDirectoryPage<AylaPost>(
          results: <AylaPost>[],
          total: 0,
        ),
        keyOf: (AylaPost p) => p.id.toString(),
      );
      cache.acquire('posts:u1:all', create: () => pager);
      pager.setItems(<AylaPost>[_post(1), _post(2)]);

      final AylaPostsFramesBridge bridge = AylaPostsFramesBridge(
        postsStore: AylaPostsStore(),
        chatState: AylaChatState(),
        currentUserId: () => 'u1',
        postTabCache: cache,
      );
      bridge.handleFrame(<String, dynamic>{
        'type': 'post.deleted',
        'post_id': 1,
      });

      expect(
        cache.pagerOf('posts:u1:all')!.items.map((AylaPost p) => p.id),
        <int>[2],
        reason: 'P1：删除帧必须同步摘除 tab 快照（避免切回旧 tab 复活已删帖）',
      );
    });
  });

  group('P2 — 语音房人数帧：本地没有该频道时必须 REST 对账', () {
    test('帧携带 last_occupied_at 且频道不在域 store ⇒ 仍必须 upsert 进列表', () async {
      // 用户实报：「进了一个语音房，语音页面的『有人』选项卡依然没有实时刷出」。
      // 旧实现：frameHasSort=true ⇒ 不 REST 对账；patchChannel 因 prev==null 直接 return
      // ⇒ 整帧丢弃，目录缓存无 diff，「有人」档永远看不到它。
      final AylaVoiceState voice = AylaVoiceState();
      final AylaDirectoryStore store = AylaDirectoryStore();
      addTearDown(() => store.requestOverride = null);
      store.userId = 'u1';

      int reconcileCalls = 0;
      final AylaRoomDirectoryBridge bridge = AylaRoomDirectoryBridge(
        voiceState: voice,
        liveState: AylaLiveState(),
        boardgameStore: AylaBoardgameStore(),
        chatState: AylaChatState(),
        realtime: AylaRealtimeState(),
        currentUserId: () => 'u1',
        directoryStore: store,
        voiceChannelLoader: (String id) async {
          reconcileCalls += 1;
          return AylaVoiceChannelSnapshot(
            id: id,
            name: 'v-' + id,
            memberCount: 1,
            lastOccupiedAt: '2026-10-20T03:10:08Z',
            allowedGroupIds: const <String>['g1'],
          );
        },
      );
      expect(voice.channelOf('85'), isNull, reason: '前置：本地没有这个频道');

      bridge.handleFrame(<String, dynamic>{
        'type': 'voice.channel.member_count_changed',
        'data': <String, dynamic>{
          'channel_id': '85',
          'member_count': 1,
          'last_occupied_at': '2026-10-20T03:10:08Z',
          'last_vacant_at': null,
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(
        reconcileCalls,
        1,
        reason: 'P2：本地无该频道时必须拉 REST 详情（旧实现因 frameHasSort=true 而不拉）',
      );
      expect(
        voice.channelOf('85'),
        isNotNull,
        reason: 'P2：对账后该频道必须进域 store（「有人」选项卡据此渲染）',
      );
    });
  });

  group('G-1 — 状态类选项卡：条件由 false 变 true 也必须并入 items', () {
    test('语音「有人」档：房从 0 人变 1 人 ⇒ 必须出现在该档列表里', () async {
      // 用户实报：「进了一个语音房，语音页面的『有人』选项卡依然没有实时刷出这个房间」。
      // 第一道断点（P2：帧被 patchChannel 早退丢弃）修完后，还有第二道：
      // updateCachedItems 的 added 只认 createdIds 或「查询维度」false→true，
      // 不含分类 filter 维度 ⇒ 「已存在的房从 0 人变 N 人」永远不会并入 occupied 档。
      // 本锁锁住修复：分类归属 false→true 也算新增。
      final AylaDirectoryStore store = AylaDirectoryStore();
      addTearDown(() => store.requestOverride = null);
      store.userId = 'u1';
      const AylaDirectoryOptions occupiedOptions =
          AylaDirectoryOptions(filter: 'occupied');

      // 该档首屏为空（0 人的房不在「有人」档里）。
      store.requestOverride = (
        AylaDirectoryKind kind,
        AylaDirectoryOptions options,
        String? cursor,
      ) async =>
          const AylaDirectoryPage<Object>(results: <Object>[], total: 0);
      await store.load(AylaDirectoryKind.voice, occupiedOptions);
      expect(
        store.itemsAs<AylaDirectoryVoiceEntry>(
          AylaDirectoryKind.voice,
          occupiedOptions,
        ),
        isEmpty,
        reason: '前置：「有人」档首屏为空',
      );

      // 域 store 里该房从 0 人 → 1 人（= member_count_changed 帧 + REST 对账后的效果）。
      final AylaVoiceChannelSnapshot empty = AylaVoiceChannelSnapshot(
        id: 'v1',
        name: 'v1',
        memberCount: 0,
      );
      store.updateCachedItems(
        AylaDirectoryKind.voice,
        <Object>[_voiceEntryOf(empty)],
        const <Object>[],
        currentUserId: 'u1',
      );
      final AylaVoiceChannelSnapshot busy = AylaVoiceChannelSnapshot(
        id: 'v1',
        name: 'v1',
        memberCount: 1,
      );
      store.updateCachedItems(
        AylaDirectoryKind.voice,
        <Object>[_voiceEntryOf(busy)],
        <Object>[_voiceEntryOf(empty)],
        currentUserId: 'u1',
      );

      expect(
        store
            .itemsAs<AylaDirectoryVoiceEntry>(
              AylaDirectoryKind.voice,
              occupiedOptions,
            )
            .map((AylaDirectoryVoiceEntry e) => e.card.id),
        <String>['v1'],
        reason: 'G-1：房从 0 人变 1 人必须并入「有人」档'
            '（修复前 added 判据不含分类维度 ⇒ 永不并入、连 invalidated 都不置）',
      );
    });
  });
}
