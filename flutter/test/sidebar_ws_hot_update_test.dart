/// **侧栏级**目录 WS 热更新回归锁 —— 用户实报的「群内第 2 列侧栏的直播 / 语音」两条。
///
/// ## 事实源
/// web `layout/ChannelSidebar.tsx:124–125`：
/// ```tsx
/// const voiceDirectory = useDirectoryPage("voice", { groupId: currentGroupId }, enabled);
/// const liveDirectory  = useDirectoryPage("live",  { groupId: currentGroupId }, enabled);
/// ```
/// ⇒ 侧栏两列**就是目录缓存的查询投影**，与三个大厅页读同一份 record；
/// 帧只落域 store，缓存由 `ensureDirectoryTracking`（`stores/directory.ts:205–219`）patch
/// ⇒ **侧栏零订阅、自动热更新**。
///
/// ## 本文件锁什么
/// 1. 侧栏读的 record **按 groupId 分桶**（`directoryKey` 含 groupId ⇒ 切群换 key）；
/// 2. 帧到达后 `voiceRooms` / `liveRooms` 的**投影**（页面 `_buildWide` 的槽位逻辑）
///    自动变新 —— 人数 / 新建 / 删除 / 开播 四档；
/// 3. 群内两列的 `AylaChannelDirectory` 三态（total / loading / invalidated）来自 store。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/directory_page.dart';
import '../lib/core/api/live_api.dart' show AylaDirectoryLiveEntry;
import '../lib/core/api/voice_api.dart'
    show AylaDirectoryVoiceEntry, AylaVoiceChannelSnapshot;
import '../lib/state/boardgame_store.dart' show AylaBoardgameStore;
import '../lib/state/directory_events.dart' show AylaDirectoryKind;
import '../lib/state/directory_store.dart';
import '../lib/state/directory_tracking.dart';
import '../lib/state/live_state.dart';
import '../lib/state/voice_state.dart';
import '../lib/widgets/live/live_channel_snapshot.dart';
import '../lib/widgets/live/live_hall.dart' show AylaLiveCardData, AylaLiveStatus;
import '../lib/pages/hub_support.dart' show aylaHubSortVoice;
import '../lib/widgets/voice/voice_channels.dart' show AylaVoiceCardData;

AylaVoiceChannelSnapshot _voiceSnapshot(
  String id, {
  int memberCount = 0,
  String? lastOccupiedAt,
  String? lastVacantAt,
  String? createdAt,
  List<String> allowedGroupIds = const <String>['g1'],
}) =>
    AylaVoiceChannelSnapshot(
      id: id,
      name: id,
      memberCount: memberCount,
      lastOccupiedAt: lastOccupiedAt,
      lastVacantAt: lastVacantAt,
      createdAt: createdAt,
      allowedGroupIds: allowedGroupIds,
    );

AylaLiveChannelSnapshot _liveSnapshot(
  String id, {
  AylaLiveStatus? status = AylaLiveStatus.idle,
  String? startedAt,
  String? endedAt,
  String? createdAt,
  List<String> allowedGroupIds = const <String>['g1'],
}) =>
    AylaLiveChannelSnapshot(
      id: id,
      title: id,
      status: status,
      startedAt: startedAt,
      endedAt: endedAt,
      createdAt: createdAt,
      allowedGroupIds: allowedGroupIds,
    );

void main() {
  late AylaDirectoryStore store;
  late AylaVoiceState voice;
  late AylaLiveState live;
  late AylaDirectoryTracking tracking;
  const AylaDirectoryOptions voiceOptions = AylaDirectoryOptions(groupId: 'g1');
  const AylaDirectoryOptions liveOptions = AylaDirectoryOptions(groupId: 'g1');

  setUp(() {
    store = AylaDirectoryStore();
    store.userId = 'u1';
    voice = AylaVoiceState();
    live = AylaLiveState();
    tracking = AylaDirectoryTracking();
    tracking.start(
      voiceState: voice,
      liveState: live,
      boardgameStore: AylaBoardgameStore(),
      currentUserId: () => 'u1',
      store: store,
    );
  });

  tearDown(() {
    tracking.stop();
    store.reset();
    store.userId = null;
  });

  group('侧栏语音列（ChannelSidebar.tsx:124）：零订阅、帧到达即变', () {
    test('member_count_changed ⇒ 行上人数与排序都变（「人数/排序不动」的修复判据）',
        () async {
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
        results: <Object>[
          AylaDirectoryVoiceEntry(
            card: const AylaVoiceCardData(id: 'a', name: 'a', memberCount: 0),
            createdAt: '2026-01-02',
            allowedGroupIds: const <String>['g1'],
          ),
          AylaDirectoryVoiceEntry(
            card: const AylaVoiceCardData(id: 'b', name: 'b', memberCount: 0),
            createdAt: '2026-01-01',
            allowedGroupIds: const <String>['g1'],
          ),
        ],
        total: 2,
      );
      await store.load(AylaDirectoryKind.voice, voiceOptions);
      expect(
        store
            .itemsAs<AylaDirectoryVoiceEntry>(AylaDirectoryKind.voice, voiceOptions)
            .map((AylaDirectoryVoiceEntry e) => e.card.id)
            .toList(),
        <String>['a', 'b'],
      );

      // ⚠️ 真实顺序：两条房先由「目录取页的落地」进域 store（`mergingPage` 档），
      // 之后的 `member_count_changed` 才是**帧**（`patchChannel`）。
      // 若跳过第一步，域 store 的新旧快照里就没有旧值可比 ⇒ `changed` 判据不成立
      // （web `stores/directory.ts:156–160` 的 `old != null && current != null`）。
      voice.upsertChannel(_voiceSnapshot('a', memberCount: 0, createdAt: '2026-01-02'));
      voice.upsertChannel(_voiceSnapshot('b', memberCount: 0, createdAt: '2026-01-01'));
      // ★ 帧：b 有人进（域 store patch → 订阅通路 diff）。
      voice.patchChannel('b',
          memberCount: 2, lastOccupiedAt: '2026-01-05');

      final List<AylaDirectoryVoiceEntry> items = store
          .itemsAs<AylaDirectoryVoiceEntry>(AylaDirectoryKind.voice, voiceOptions);
      expect(items.first.card.id, 'b',
          reason: '有人区置顶（web sortVoiceChannels:34–36）⇒ 侧栏排序立即变');
      expect(items.first.card.memberCount, 2,
          reason: '行上人数立即变（`channel-voice-room-count`）');
    });

    test('voice.channel.created ⇒ 侧栏立即多一行', () async {
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(results: <Object>[], total: 0);
      await store.load(AylaDirectoryKind.voice, voiceOptions);
      store.noteCreated(AylaDirectoryKind.voice, 'v-new');
      voice.upsertChannel(_voiceSnapshot('v-new', createdAt: '2026-01-02'));
      expect(
        store
            .itemsAs<AylaDirectoryVoiceEntry>(AylaDirectoryKind.voice, voiceOptions)
            .map((AylaDirectoryVoiceEntry e) => e.card.id)
            .toList(),
        <String>['v-new'],
      );
    });

    test('voice.channel.deleted ⇒ 侧栏立即少一行', () async {
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
        results: <Object>[
          AylaDirectoryVoiceEntry(
            card: const AylaVoiceCardData(id: 'v1', name: 'v1'),
            allowedGroupIds: const <String>['g1'],
          ),
        ],
        total: 1,
      );
      await store.load(AylaDirectoryKind.voice, voiceOptions);
      voice.removeChannel('v1');
      store.noteDeleted(AylaDirectoryKind.voice, 'v1');
      expect(
        store.itemsAs<AylaDirectoryVoiceEntry>(AylaDirectoryKind.voice, voiceOptions),
        isEmpty,
      );
    });

    test('群内两列的「排序事实」来自目录条目本身（不是全局 voiceState）',
        () async {
      // 「曾有人、现在没人」的房（有 last_vacant_at）必须压住「从未有人」，
      // 而这些时间戳**只写在目录条目里**（域 store 未覆盖该房）⇒ 若排序只读
      // `voiceState.channels`，该房会被误判成「从未有人」而沉底（用户实报的
      // 「语音还给修坏了」）。
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
        results: <Object>[
          AylaDirectoryVoiceEntry(
            card: const AylaVoiceCardData(id: 'never', name: 'never'),
            createdAt: '2026-01-05',
            allowedGroupIds: const <String>['g1'],
          ),
          AylaDirectoryVoiceEntry(
            card: const AylaVoiceCardData(id: 'vacant', name: 'vacant'),
            createdAt: '2026-01-01',
            lastOccupiedAt: '2026-01-02',
            lastVacantAt: '2026-01-03',
            allowedGroupIds: const <String>['g1'],
          ),
        ],
        total: 2,
      );
      await store.load(AylaDirectoryKind.voice, voiceOptions);
      // 域 store **没有**这两个房的条目（用户没进过、也没收到过它们的帧）。
      expect(voice.channels, isEmpty);
      final List<AylaDirectoryVoiceEntry> items = store
          .itemsAs<AylaDirectoryVoiceEntry>(AylaDirectoryKind.voice, voiceOptions);
      expect(
        aylaHubSortVoiceIds(items),
        <String>['vacant', 'never'],
        reason: '「变空不回初始位」—— 排序必须读**条目自带**的 last_vacant_at',
      );
    });
  });

  group('侧栏直播列（ChannelSidebar.tsx:125）：零订阅、帧到达即变', () {
    test('live.channel.status.changed（开播）⇒ 侧栏 LIVE 与排序都变', () async {
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
        results: <Object>[
          AylaDirectoryLiveEntry(
            card: const AylaLiveCardData(
              id: '1',
              title: '1',
              status: AylaLiveStatus.idle,
            ),
            createdAt: '2026-01-02',
            allowedGroupIds: const <String>['g1'],
          ),
          AylaDirectoryLiveEntry(
            card: const AylaLiveCardData(
              id: '2',
              title: '2',
              status: AylaLiveStatus.idle,
            ),
            createdAt: '2026-01-01',
            allowedGroupIds: const <String>['g1'],
          ),
        ],
        total: 2,
      );
      await store.load(AylaDirectoryKind.live, liveOptions);
      expect(
        store
            .itemsAs<AylaDirectoryLiveEntry>(AylaDirectoryKind.live, liveOptions)
            .first
            .card
            .id,
        '1',
      );

      // 同 voice：先由「目录取页落地 / 详情对账」把两条房放进域 store，
      // 再由 `live.channel.status.changed` 的详情对账改变描述符。
      live.upsertChannel(_liveSnapshot('1', createdAt: '2026-01-02'));
      live.upsertChannel(_liveSnapshot('2', createdAt: '2026-01-01'));
      live.upsertChannel(_liveSnapshot('2', status: AylaLiveStatus.live,
          startedAt: '2026-01-05', createdAt: '2026-01-01'));
      final List<AylaDirectoryLiveEntry> items =
          store.itemsAs<AylaDirectoryLiveEntry>(AylaDirectoryKind.live, liveOptions);
      expect(items.first.card.id, '2',
          reason: '在播置顶（web sortLiveChannels:52–54）⇒ 侧栏排序立即变');
      expect(items.first.card.status, AylaLiveStatus.live,
          reason: 'LIVE 标记立即出现（`isLive` 由 status 推出）');
    });

    test('live.channel.deleted ⇒ 侧栏立即少一行', () async {
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
        results: <Object>[
          AylaDirectoryLiveEntry(
            card: const AylaLiveCardData(id: '1', title: '1'),
            allowedGroupIds: const <String>['g1'],
          ),
        ],
        total: 1,
      );
      await store.load(AylaDirectoryKind.live, liveOptions);
      live.removeChannel('1');
      store.noteDeleted(AylaDirectoryKind.live, '1');
      expect(
        store.itemsAs<AylaDirectoryLiveEntry>(AylaDirectoryKind.live, liveOptions),
        isEmpty,
      );
    });
  });

  group('侧栏两列的 record 按 groupId 分桶（directoryKey 含 groupId）', () {
    test('别的群的 record 不受本群帧影响；本群键独立', () async {
      const AylaDirectoryOptions other = AylaDirectoryOptions(groupId: 'g2');
      store.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
        results: <Object>[
          AylaDirectoryVoiceEntry(
            card: const AylaVoiceCardData(id: 'g1-room', name: 'g1-room'),
            allowedGroupIds: const <String>['g1'],
          ),
        ],
        total: 1,
      );
      await store.load(AylaDirectoryKind.voice, voiceOptions);
      // g2 的查询：同一个房因白名单不含 g2 ⇒ 不进 items（web `matchesQuery`）。
      await store.load(AylaDirectoryKind.voice, other);
      expect(
        store.itemsAs<AylaDirectoryVoiceEntry>(AylaDirectoryKind.voice, other),
        isEmpty,
      );
      expect(
        store
            .itemsAs<AylaDirectoryVoiceEntry>(AylaDirectoryKind.voice, voiceOptions)
            .length,
        1,
      );
    });
  });
}

/// 侧栏语音列的投影序（页面 `_buildWide` 的 `voiceRooms` 槽位同源）。
List<String> aylaHubSortVoiceIds(List<AylaDirectoryVoiceEntry> items) => <String>[
      for (final AylaDirectoryVoiceEntry e in aylaHubSortVoice(items)) e.card.id,
    ];
