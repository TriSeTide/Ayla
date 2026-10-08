/// 目录列表 **WS 热更新** 回归锁 —— 用户 2026-10-08 实报：
/// 「语音房列表页、直播列表页、桌游列表页、帖子列表页、群内第 2 列侧栏的直播、
///   群内第 2 列侧栏的语音（语音还给修坏了）全都没有 ws 热更新」。
///
/// ## 事实源（web `stores/directory.ts`）
/// web 的机制是「**帧 → 域 store → 目录缓存**」，页面**不订阅 WS**：
/// - `:148–196` `updateCachedItems`：把域 store 的新旧快照 diff 进全部同 kind 的 record；
/// - `:205–219` `ensureDirectoryTracking` 的 **store 订阅通路**（本仓 =
///   `state/directory_tracking.dart`）；
/// - `:220–259` `chatWS.onFrame` 的**帧直连通路**（`createdIds` / 删除摘除；
///   本仓 = `core/ws/room_frames.dart` + `AylaDirectoryStore.noteCreated/noteDeleted`）。
///
/// ## 本文件锁什么
/// 1. **store 级**：`updateCachedItems` 的四档语义（updated / removed / added /
///    membershipChanged / invalidated / mutationRevision / total / totalMemberCount）；
/// 2. **帧级**：`noteCreated` / `noteDeleted` 的 60 秒提示与删除摘除；
/// 3. **通路级**：`AylaDirectoryTracking` 订阅三个域 store 后，帧到达**不做任何页面动作**
///    就能让 record 变新（这是「架构修好了」的判据）。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/boardgame_api.dart' show AylaDirectoryGameEntry;
import '../lib/core/api/directory_page.dart';
import '../lib/core/api/live_api.dart';
import '../lib/core/api/voice_api.dart';
import '../lib/core/models/game_room.dart';
import '../lib/core/models/user_public.dart';
import '../lib/core/models/visibility.dart' show AylaPostVisibility;
import '../lib/state/boardgame_store.dart';
import '../lib/state/directory_events.dart' show AylaDirectoryKind;
import '../lib/state/directory_store.dart';
import '../lib/state/directory_tracking.dart';
import '../lib/state/live_state.dart';
import '../lib/state/voice_state.dart';
import '../lib/widgets/live/live_channel_snapshot.dart';
import '../lib/widgets/live/live_hall.dart' show AylaLiveCardData, AylaLiveStatus;
import '../lib/widgets/voice/voice_channels.dart' show AylaVoiceCardData;

/// 目录条目（record.items 的形态；`directory_tracking.dart` 的投影产物）。
AylaDirectoryVoiceEntry _entry(
  String id, {
  int? memberCount,
  String? lastOccupiedAt,
  String? lastVacantAt,
  String? createdAt,
  List<String> allowedGroupIds = const <String>['g1'],
}) =>
    AylaDirectoryVoiceEntry(
      card: AylaVoiceCardData(id: id, name: id, memberCount: memberCount),
      createdAt: createdAt,
      lastOccupiedAt: lastOccupiedAt,
      lastVacantAt: lastVacantAt,
      allowedGroupIds: allowedGroupIds,
    );

/// 语音快照（域 store 的条目形态）。
AylaVoiceChannelSnapshot _voiceSnapshot(
  String id, {
  int memberCount = 0,
  String? lastOccupiedAt,
  String? lastVacantAt,
  String? createdAt,
}) =>
    AylaVoiceChannelSnapshot(
      id: id,
      name: id,
      memberCount: memberCount,
      lastOccupiedAt: lastOccupiedAt,
      lastVacantAt: lastVacantAt,
      createdAt: createdAt,
      allowedGroupIds: const <String>['g1'],
    );

AylaLiveChannelSnapshot _liveSnapshot(
  String id, {
  AylaLiveStatus? status = AylaLiveStatus.live,
  int? viewerCount,
  String? startedAt,
  String? endedAt,
  String? createdAt,
}) =>
    AylaLiveChannelSnapshot(
      id: id,
      title: id,
      status: status,
      viewerCount: viewerCount,
      startedAt: startedAt,
      endedAt: endedAt,
      createdAt: createdAt,
    );

AylaGameRoom _room(int id, {String? createdAt}) => AylaGameRoom(
      id: id,
      name: 'room$id',
      owner: const AylaUserPublic(id: 'u1'),
      ownerId: 'u1',
      status: AylaGameRoomStatus.waiting,
      createdAt: createdAt,
    );

void main() {
  group('updateCachedItems（web stores/directory.ts:148–196）', () {
    late AylaDirectoryStore store;
    const AylaDirectoryOptions options = AylaDirectoryOptions(filter: 'all');

    setUp(() {
      store = AylaDirectoryStore();
      // 与生产（`directory_tracking.dart`）同一装配：描述符 → 目录条目。
      store.descriptorAdapters[AylaDirectoryKind.voice] =
          (Object d) => d is AylaVoiceChannelSnapshot
              ? AylaDirectoryVoiceEntry(
                  card: d.card,
                  ownerId: d.ownerId,
                  createdAt: d.createdAt,
                  roomName: d.roomName,
                  allowedGroupIds: d.allowedGroupIds,
                  lastOccupiedAt: d.lastOccupiedAt,
                  lastVacantAt: d.lastVacantAt,
                  isOwner: d.mine,
                )
              : d;
      store.descriptorAdapters[AylaDirectoryKind.live] =
          (Object d) => d is AylaLiveChannelSnapshot
              ? AylaDirectoryLiveEntry.fromSnapshot(d)
              : d;
    });

    /// 铺一条「已取满首页」的 record（`fetchedAt != null && !hasMore` ⇒ `complete`）。
    Future<void> seed(
      AylaDirectoryKind kind,
      List<Object> items, {
      AylaDirectoryOptions opts = options,
      bool hasMore = false,
      int? totalMemberCount,
    }) async {
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
        results: items,
        hasMore: hasMore,
        nextCursor: hasMore ? 'c1' : null,
        total: items.length,
        totalMemberCount: totalMemberCount,
      );
      await store.load(kind, opts);
    }

    test('updated：同 id 用新描述符就地替换（人数立即生效；0→有人 触发重排）', () async {
      // ⚠️ 生产装配下 record 里存的是**目录条目**，而域 store 快照是**描述符** ——
      // diff 时经 `descriptorAdapters` 投影回条目（web 里这一步是恒等）。
      await seed(AylaDirectoryKind.voice, <Object>[
        _entry('a', createdAt: '2026-01-02'),
        _entry('b', createdAt: '2026-01-01'),
      ]);
      // 帧：b 有人在麦（域 store 快照变化 → 订阅通路 diff）。
      final List<Object> before = <Object>[
        _voiceSnapshot('a', createdAt: '2026-01-02'),
        _voiceSnapshot('b', createdAt: '2026-01-01'),
      ];
      final List<Object> after = <Object>[
        _voiceSnapshot('a', createdAt: '2026-01-02'),
        _voiceSnapshot('b', memberCount: 3, createdAt: '2026-01-01'),
      ];
      store.updateCachedItems(AylaDirectoryKind.voice, after, before);
      final AylaDirectoryRecord record =
          store.recordOf(AylaDirectoryKind.voice, options)!;
      final List<AylaDirectoryVoiceEntry> items =
          store.itemsAs<AylaDirectoryVoiceEntry>(AylaDirectoryKind.voice, options);
      expect(items.map((AylaDirectoryVoiceEntry e) => e.card.id).toList(),
          <String>['b', 'a'],
          reason: 'b 由「无人」变「有人」⇒ `sortIdentity` 翻转（web :105 的 '
              '`member_count > 0` 是排序身份的一段）⇒ 重排（web :156–160 / :178）');
      expect(items.map((AylaDirectoryVoiceEntry e) => e.card.memberCount).toList(),
          <int>[3, 0],
          reason: 'b 的人数立即变（这就是「行上人数不动」的修复判据）');
      expect(record.mutationRevision, 0,
          reason: '人数变化不改 membership ⇒ mutationRevision 不动（web :191）');
      expect(record.invalidated, isFalse);
    });

    test('changed ⇒ 重排：有人区置顶（web sortItems + sortVoiceChannels）', () async {
      final List<Object> before = <Object>[
        _entry('a', createdAt: '2026-01-02'),
        _entry('b', createdAt: '2026-01-01'),
      ];
      await seed(AylaDirectoryKind.voice, before);
      final List<Object> after = <Object>[
        _entry('a', createdAt: '2026-01-02'),
        _entry('b', memberCount: 1, lastOccupiedAt: '2026-01-03', createdAt: '2026-01-01'),
      ];
      store.updateCachedItems(AylaDirectoryKind.voice, after, before);
      expect(
        store
            .itemsAs<AylaDirectoryVoiceEntry>(AylaDirectoryKind.voice, options)
            .map((AylaDirectoryVoiceEntry e) => e.card.id)
            .toList(),
        <String>['b', 'a'],
        reason: '排序身份变了 ⇒ 重排（「侧栏排序不动」的修复判据）',
      );
    });

    test('removed（查询不再命中）：只有 matchesQuery 翻转才算移除（web :162–163）',
        () async {
      // `onlyLive` 档：直播间下播 ⇒ 不再命中查询 ⇒ 从 items 摘除并校正 total。
      const AylaDirectoryOptions onlyLive = AylaDirectoryOptions(
        filter: 'live',
        onlyLive: true,
      );
      final List<Object> before = <Object>[
        _liveSnapshot('a', status: AylaLiveStatus.live, startedAt: '2026-01-02'),
      ];
      await seed(AylaDirectoryKind.live, before, opts: onlyLive);
      expect(store.recordOf(AylaDirectoryKind.live, onlyLive)!.total, 1);
      // 下播：域 store 快照里 status 变 idle。
      store.updateCachedItems(
        AylaDirectoryKind.live,
        <Object>[_liveSnapshot('a', status: AylaLiveStatus.idle, startedAt: '2026-01-02')],
        before,
      );
      final AylaDirectoryRecord record =
          store.recordOf(AylaDirectoryKind.live, onlyLive)!;
      expect(record.items, isEmpty,
          reason: 'web :162–163 —— 过不了 matchesQuery 的条目从 items 摘除');
      expect(record.total, 0, reason: 'web :188 —— removed 计入 total');
      expect(record.mutationRevision, 1, reason: 'web :191');
    });

    test('域 store 消失但**未收到删除帧** ⇒ 条目保留（web :161 的 `?? item`）', () async {
      // 这是 web 的**真实语义**，也正是「帧直连通路」为什么必须存在：
      // `updated = record.items.map((item) => after.get(id) ?? item)` —— 域 store 里没有
      // 的条目**保留旧值**，删除只由 `chatWS.onFrame` 的 `*.deleted` 分支接手
      // （`stores/directory.ts:161` vs `:237–258`）。
      final List<Object> before = <Object>[
        _entry('a', createdAt: '2026-01-02'),
        _entry('b', createdAt: '2026-01-01'),
      ];
      await seed(AylaDirectoryKind.voice, before);
      expect(store.recordOf(AylaDirectoryKind.voice, options)!.total, 2);
      store.updateCachedItems(AylaDirectoryKind.voice,
          <Object>[_entry('a', createdAt: '2026-01-02')], before);
      final AylaDirectoryRecord record =
          store.recordOf(AylaDirectoryKind.voice, options)!;
      expect(record.items.length, 2, reason: '未收删除帧 ⇒ 条目保留（web `?? item`）');
      expect(record.mutationRevision, 0);
      // 删除帧到达（帧直连通路）⇒ 才真的摘掉。
      store.noteDeleted(AylaDirectoryKind.voice, 'b');
      final AylaDirectoryRecord after =
          store.recordOf(AylaDirectoryKind.voice, options)!;
      expect(after.items.length, 1);
      expect(after.total, 1, reason: 'web :251');
      expect(after.mutationRevision, 1);
    });

    test('added：登记了创建提示 ⇒ 新增并入 complete 的 record（web :166–174）', () async {
      final List<Object> before = <Object>[_entry('a', createdAt: '2026-01-02')];
      await seed(AylaDirectoryKind.voice, before);
      // `voice.channel.created` 帧 ⇒ 登记提示（帧直连通路）。
      store.noteCreated(AylaDirectoryKind.voice, 'new');
      final List<Object> after = <Object>[
        ...before,
        _entry('new', createdAt: '2026-01-03'),
      ];
      store.updateCachedItems(AylaDirectoryKind.voice, after, before);
      final AylaDirectoryRecord record =
          store.recordOf(AylaDirectoryKind.voice, options)!;
      expect(
        record.items
            .cast<AylaDirectoryVoiceEntry>()
            .map((AylaDirectoryVoiceEntry e) => e.card.id)
            .toList(),
        <String>['new', 'a'],
        reason: '新语音房**立即出现**在列表里（不等 60 秒、不点刷新）',
      );
      expect(record.total, 2);
      expect(record.mutationRevision, 1);
      expect(record.invalidated, isFalse, reason: 'complete（无更多页）⇒ 不需要刷新入口');
      expect(store.hasCreationHint(AylaDirectoryKind.voice, 'new'), isFalse,
          reason: 'web :195 —— 已落地的提示要清掉');
    });

    test('added：**没有**创建提示的条目不算新增（ACL 不全，web :164–171）', () async {
      final List<Object> before = <Object>[_entry('a', createdAt: '2026-01-02')];
      await seed(AylaDirectoryKind.voice, before);
      final List<Object> after = <Object>[
        ...before,
        _entry('sneaky', createdAt: '2026-01-03'),
      ];
      store.updateCachedItems(AylaDirectoryKind.voice, after, before);
      expect(
        store
            .itemsAs<AylaDirectoryVoiceEntry>(AylaDirectoryKind.voice, options)
            .map((AylaDirectoryVoiceEntry e) => e.card.id)
            .toList(),
        <String>['a'],
        reason: '无提示 ⇒ 不插入（权限不明的新增不能凭空进列表）',
      );
    });

    test('不完全的 record（hasMore）⇒ membership 变化置 invalidated 且**不**并入 items',
        () async {
      final List<Object> before = <Object>[_entry('a', createdAt: '2026-01-02')];
      await seed(AylaDirectoryKind.voice, before, hasMore: true);
      store.noteCreated(AylaDirectoryKind.voice, 'new');
      final List<Object> after = <Object>[
        ...before,
        _entry('new', createdAt: '2026-01-03'),
      ];
      store.updateCachedItems(AylaDirectoryKind.voice, after, before);
      final AylaDirectoryRecord record =
          store.recordOf(AylaDirectoryKind.voice, options)!;
      expect(record.items.length, 1, reason: 'web :173–177 —— complete 才并入');
      expect(record.invalidated, isTrue, reason: 'web :177 —— 页脚据此给「刷新」入口');
      expect(record.mutationRevision, 1);
    });

    test('totalMemberCount：语音在麦总数按 membership 增减校正（web :179–184）', () async {
      final List<Object> before = <Object>[
        _entry('a', memberCount: 2, createdAt: '2026-01-02'),
      ];
      await seed(AylaDirectoryKind.voice, before, totalMemberCount: 2);
      // a 从 2 人变 5 人（+3）。
      store.updateCachedItems(
        AylaDirectoryKind.voice,
        <Object>[_entry('a', memberCount: 5, createdAt: '2026-01-02')],
        before,
      );
      expect(
        store.recordOf(AylaDirectoryKind.voice, options)!.totalMemberCount,
        5,
        reason: '「N 人在聊」的统计也要跟着帧走',
      );
    });

    test('只 patch 同 kind 的 record（kind 不串）', () async {
      await seed(AylaDirectoryKind.voice, <Object>[_entry('a')]);
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
        results: <Object>[
          AylaDirectoryLiveEntry(
            card: const AylaLiveCardData(id: 'L', title: 'L'),
          ),
        ],
        total: 1,
      );
      await store.load(AylaDirectoryKind.live, options);
      store.updateCachedItems(AylaDirectoryKind.voice,
          <Object>[_entry('a', memberCount: 9)], <Object>[_entry('a')]);
      expect(store.itemsAs<AylaDirectoryLiveEntry>(AylaDirectoryKind.live, options).first
          .card.viewerCount, isNull,
          reason: 'voice 的 diff 不得碰到 live 的 record');
    });
  });

  group('帧直连通路 noteCreated / noteDeleted（web :220–259）', () {
    late AylaDirectoryStore store;
    const AylaDirectoryOptions options = AylaDirectoryOptions(filter: 'all');

    setUp(() {
      store = AylaDirectoryStore();
    });

    test('noteDeleted：从全部同 kind 的 record 摘除 + total -1 + invalidated（hasMore）',
        () async {
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
        results: <Object>[_entry('a'), _entry('b')],
        total: 2,
        hasMore: true,
        nextCursor: 'c1',
      );
      await store.load(AylaDirectoryKind.voice, options);
      final AylaDirectoryRecord before =
          store.recordOf(AylaDirectoryKind.voice, options)!;
      store.noteDeleted(AylaDirectoryKind.voice, 'a');
      final AylaDirectoryRecord after =
          store.recordOf(AylaDirectoryKind.voice, options)!;
      expect(after.items.length, 1,
          reason: '删除帧到达 ⇒ 条目立即消失（不等 60 秒、不点刷新）');
      expect(after.total, before.total - 1);
      expect(after.mutationRevision, before.mutationRevision + 1);
      expect(after.invalidated, isTrue, reason: 'hasMore ⇒ 页脚给刷新入口（web :247）');
    });

    test('noteDeleted：语音的 totalMemberCount 减去被删房的人数（web :252–253）', () async {
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
        results: <Object>[_entry('a', memberCount: 4)],
        total: 1,
        totalMemberCount: 4,
      );
      await store.load(AylaDirectoryKind.voice, options);
      store.noteDeleted(AylaDirectoryKind.voice, 'a');
      expect(store.recordOf(AylaDirectoryKind.voice, options)!.totalMemberCount, 0);
    });

    test('noteDeleted：**不在** record 里且无 hasMore ⇒ 不动（web :245）', () async {
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(results: <Object>[_entry('a')], total: 1);
      await store.load(AylaDirectoryKind.voice, options);
      store.noteDeleted(AylaDirectoryKind.voice, 'ghost');
      final AylaDirectoryRecord record =
          store.recordOf(AylaDirectoryKind.voice, options)!;
      expect(record.items.length, 1);
      expect(record.total, 1, reason: '没有该条目、也不再续读 ⇒ 统计不动');
    });

    test('noteCreated：登记提示；超过 TTL 后失效', () {
      int now = 1000;
      store.nowMillis = () => now;
      store.noteCreated(AylaDirectoryKind.live, 'c1');
      expect(store.hasCreationHint(AylaDirectoryKind.live, 'c1'), isTrue);
      now += AylaDirectoryStore.kAylaCreatedHintTtlMs + 1;
      // 下一次登记触发惰性清理（web `pruneCreationHints`）。
      store.noteCreated(AylaDirectoryKind.live, 'c2');
      expect(store.hasCreationHint(AylaDirectoryKind.live, 'c1'), isFalse);
      expect(store.hasCreationHint(AylaDirectoryKind.live, 'c2'), isTrue);
    });

    test('reset：清记录 + 清提示（web :86）', () {
      store.noteCreated(AylaDirectoryKind.game, '7');
      store.reset();
      expect(store.records, isEmpty);
      expect(store.hasCreationHint(AylaDirectoryKind.game, '7'), isFalse);
    });
  });

  group('AylaDirectoryTracking：域 store 变化 ⇒ 目录缓存自动 patch', () {
    late AylaDirectoryStore store;
    late AylaVoiceState voice;
    late AylaLiveState live;
    late AylaBoardgameStore boardgame;
    late AylaDirectoryTracking tracking;
    const AylaDirectoryOptions options = AylaDirectoryOptions(filter: 'all');

    setUp(() {
      store = AylaDirectoryStore();
      voice = AylaVoiceState();
      live = AylaLiveState();
      boardgame = AylaBoardgameStore();
      tracking = AylaDirectoryTracking();
      tracking.start(
        voiceState: voice,
        liveState: live,
        boardgameStore: boardgame,
        currentUserId: () => 'me',
        store: store,
      );
    });

    tearDown(() => tracking.stop());

    test('voice.channel.member_count_changed 的语义：store patch ⇒ record 立即变',
        () async {
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
        results: <Object>[
          AylaDirectoryVoiceEntry(
            card: const AylaVoiceCardData(id: 'v1', name: '房 1'),
          ),
        ],
        total: 1,
        totalMemberCount: 0,
      );
      await store.load(AylaDirectoryKind.voice, options);
      // 帧：`voice.channel.member_count_changed` → 域 store（`chat.ts:699–708`）。
      voice.upsertChannel(_voiceSnapshot('v1', memberCount: 4));
      final AylaDirectoryVoiceEntry entry = store
          .itemsAs<AylaDirectoryVoiceEntry>(AylaDirectoryKind.voice, options)
          .single;
      expect(entry.card.memberCount, 4,
          reason: '人数帧到达 ⇒ 列表条目人数立即变（无任何页面动作）');
      expect(store.recordOf(AylaDirectoryKind.voice, options)!.totalMemberCount, 4,
          reason: '「N 人在聊」也立即变');
    });

    test('voice.channel.created（带 createdIds 提示）⇒ 条目立即出现', () async {
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(results: <Object>[], total: 0);
      await store.load(AylaDirectoryKind.voice, options);
      store.noteCreated(AylaDirectoryKind.voice, 'v2'); // 帧直连通路
      voice.upsertChannel(_voiceSnapshot('v2', createdAt: '2026-01-01')); // 域 store
      expect(
        store
            .itemsAs<AylaDirectoryVoiceEntry>(AylaDirectoryKind.voice, options)
            .map((AylaDirectoryVoiceEntry e) => e.card.id)
            .toList(),
        <String>['v2'],
      );
    });

    test('live.channel.status.changed ⇒ status 立即变（LIVE 标记跟着走）', () async {
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
        results: <Object>[
          AylaDirectoryLiveEntry(
            card: const AylaLiveCardData(
              id: 'c1',
              title: '直播 1',
              status: AylaLiveStatus.idle,
            ),
          ),
        ],
        total: 1,
      );
      await store.load(AylaDirectoryKind.live, options);
      live.upsertChannel(_liveSnapshot('c1', status: AylaLiveStatus.live,
          startedAt: '2026-01-02'));
      expect(
        store
            .itemsAs<AylaDirectoryLiveEntry>(AylaDirectoryKind.live, options)
            .single
            .card
            .status,
        AylaLiveStatus.live,
      );
    });

    test('live.viewers.changed ⇒ 在看人数立即变、**不**改排序（web :756–764）', () async {
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
        results: <Object>[
          AylaDirectoryLiveEntry(
            card: const AylaLiveCardData(
              id: 'c1',
              title: '直播 1',
              status: AylaLiveStatus.live,
              viewerCount: 0,
            ),
            startedAt: '2026-01-02',
          ),
          AylaDirectoryLiveEntry(
            card: const AylaLiveCardData(
              id: 'c2',
              title: '直播 2',
              status: AylaLiveStatus.live,
              viewerCount: 3,
            ),
            startedAt: '2026-01-03',
          ),
        ],
        total: 2,
      );
      await store.load(AylaDirectoryKind.live, options);
      // ⚠️ `patchViewerCount` 只 patch **已在该频道表里**的条目（web `stores/live.ts:122–129`
      // 的 `patchChannels`：`if (!channels.some(...)) return channels`）。
      // 帧到达时该频道尚未入表 ⇒ 先由「详情对账 / 此前某次取页」入表，再 patch。
      // 这正是 web 的行为，不是本实现的偏离。
      live.upsertChannel(_liveSnapshot('c1', status: AylaLiveStatus.live,
          startedAt: '2026-01-02', viewerCount: 0));
      live.upsertChannel(_liveSnapshot('c2', status: AylaLiveStatus.live,
          startedAt: '2026-01-03', viewerCount: 3));
      live.patchViewerCount('c1', 99);
      final List<AylaDirectoryLiveEntry> items =
          store.itemsAs<AylaDirectoryLiveEntry>(AylaDirectoryKind.live, options);
      expect(items.first.card.id, 'c1',
          reason: 'c1 仍是最近开播 ⇒ 人数**不**参与排序（web :757–758 原话）');
      expect(items.first.card.viewerCount, 99);
    });

    test('boardgame.room.deleted ⇒ 桌游列表立即移除该条', () async {
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
        results: <Object>[
          AylaDirectoryGameEntry(
            card: const AylaGameCardData(id: '1', name: 'room1'),
            room: _room(1, createdAt: '2026-01-02'),
          ),
          AylaDirectoryGameEntry(
            card: const AylaGameCardData(id: '2', name: 'room2'),
            room: _room(2, createdAt: '2026-01-01'),
          ),
        ],
        total: 2,
      );
      await store.load(AylaDirectoryKind.game, options);
      // 帧：`boardgame.room.deleted` → `removeRoom` + `noteDeleted`（web :853–855 + :242–257）。
      boardgame.removeRoom(1);
      store.noteDeleted(AylaDirectoryKind.game, '1');
      expect(
        store
            .itemsAs<AylaDirectoryGameEntry>(AylaDirectoryKind.game, options)
            .map((AylaDirectoryGameEntry e) => e.room.id)
            .toList(),
        <int>[2],
      );
    });

    test('stop ⇒ 退订；之后域 store 变化不再 patch 缓存', () async {
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
        results: <Object>[
          AylaDirectoryVoiceEntry(
            card: const AylaVoiceCardData(id: 'v1', name: '房 1'),
          ),
        ],
        total: 1,
      );
      await store.load(AylaDirectoryKind.voice, options);
      tracking.stop();
      voice.upsertChannel(_voiceSnapshot('v1', memberCount: 7));
      expect(
        store
            .itemsAs<AylaDirectoryVoiceEntry>(AylaDirectoryKind.voice, options)
            .single
            .card
            .memberCount,
        isNull,
        reason: '退订后不再消费（web disposeDirectoryTracking 同）',
      );
    });
  });
}
