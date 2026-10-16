/// **群内语音「进不去房间」+ 侧栏语音列表被 WS 清空** 回归锁。
///
/// ## 症状（用户实报）
/// 1. 群内点语音房 ⇒ 永远停在「正在加载语音房…」，**进不去**；
/// 2. 群列表（ServerRail）不为「新建语音房 / 有人进语音」往前排；
/// 3. 语音帧到达后，群内第 2 列侧栏的语音房行**整批消失**。
///
/// ## 根因（同一处：目录取页落地钩子丢字段）
/// web 的目录条目**就是**域 store 的描述符本身（同一对象），字段不存在搬运损失：
/// - \`stores/directory.ts:143–146\` \`cachedItems\` 直接返回 \`useVoiceStore.channels\`；
/// - \`stores/directory.ts:310–320\` 取页结果逐条 \`upsertChannel(item)\`（**原对象**）；
/// - 目录条目类型 = 完整 \`VoiceChannelDescriptor\`（\`api/types.ts:863–885\`，含 \`allowed_group_ids\`）。
///
/// Flutter 侧目录条目（\`AylaDirectoryVoiceEntry\`）与域快照
/// （\`AylaVoiceChannelSnapshot\`）是**两个类型** ⇒ 中间必须有一次逐字段搬运，
/// 落点是 \`state/room_providers.dart\` 的 \`_onVoiceDirectoryItem\`。
/// 该搬运**漏了 \`allowedGroupIds\`**（对照同文件的 \`_onLiveDirectoryItem\`，那边有传）。
///
/// ## 三条受损链路（都由同一个字段缺口引发）
/// 1. \`GroupVoice.tsx:123–129\` 的房内命中判据 = \`allowed_group_ids\` 含本群
///    ⇒ Flutter \`group_voice_page.dart\` 的 \`_roomChannel()\` 恒失败 ⇒ 骨架常驻；
/// 2. \`groupActivity.ts:70–76\` 的 \`visibleInGroup\` = 白名单含本群
///    ⇒ 群活跃度/存在性判据恒假 ⇒ \`sortGroupsByActivity\`（tsx 205–209）不往前排；
/// 3. \`stores/directory.ts:110–113\` 的 \`matchesQuery\`（\`groupId\` 档）读白名单
///    ⇒ 投影回目录缓存后，群桶记录的行被 \`_matchesQueryOf\` 判为**不属于本群** ⇒ 整批移出。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/directory_page.dart';
import '../lib/core/api/voice_api.dart'
    show AylaDirectoryVoiceEntry, AylaVoiceChannelSnapshot;
import '../lib/state/directory_events.dart' show AylaDirectoryKind;
import '../lib/state/directory_store.dart';
import '../lib/state/room_providers.dart'
    show aylaStartRoomFrames, aylaStopDirectoryTracking, voiceStateProvider;
import '../lib/widgets/voice/voice_channels.dart' show AylaVoiceCardData;

/// 生产目录条目（后端 \`VoiceChannelSerializer\` 形状：白名单含本群 g1）。
AylaDirectoryVoiceEntry _entry(String id, {int memberCount = 0}) =>
    AylaDirectoryVoiceEntry(
      card: AylaVoiceCardData(id: id, name: '房间 $id', memberCount: memberCount),
      ownerId: 'u1',
      createdAt: '2026-10-01T00:00:00Z',
      roomName: 'room_$id',
      allowedGroupIds: const <String>['g1'],
      group: 'g1',
      lastOccupiedAt: '2026-10-02T00:00:00Z',
    );

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
    // ★ 生产装配：注册三条落地钩子 + 目录 store 订阅通路（web \`ensureDirectoryTracking\`）。
    aylaStartRoomFrames(container);
  });

  tearDown(() {
    aylaStopDirectoryTracking();
    aylaDirectoryStore.reset();
    aylaDirectoryStore.userId = null;
    container.dispose();
  });

  const AylaDirectoryOptions groupOptions = AylaDirectoryOptions(groupId: 'g1');

  /// 目录取页的**真实落地路径**：\`store.load\` → \`itemUpsertHooks[voice]\`
  /// （web \`stores/directory.ts:311–320\` 的逐条 \`upsertChannel\`）。
  Future<void> loadGroupPage(List<AylaDirectoryVoiceEntry> items) async {
    aylaDirectoryStore.userId = 'u1';
    aylaDirectoryStore.requestOverride = (kind, options, cursor) async =>
        AylaDirectoryPage<Object>(
          results: List<Object>.of(items),
          total: items.length,
          totalMemberCount: items.fold<int>(
            0,
            (int sum, AylaDirectoryVoiceEntry e) => sum + (e.card.memberCount ?? 0),
          ),
        );
    await aylaDirectoryStore.load(AylaDirectoryKind.voice, groupOptions);
  }

  group('群内语音房「进不去」根因（web stores/directory.ts:310–320 的字段原子性）', () {
    test('目录取页落地 ⇒ 域快照必须带 allowed_group_ids（对照 _onLiveDirectoryItem 有传）',
        () async {
      await loadGroupPage(<AylaDirectoryVoiceEntry>[_entry('v1', memberCount: 2)]);

      final AylaVoiceChannelSnapshot? snapshot =
          container.read(voiceStateProvider).channelOf('v1');
      expect(snapshot, isNotNull,
          reason: '取页结果必须逐条落进域 store（web stores/directory.ts:315）');
      expect(
        snapshot!.allowedGroupIds,
        <String>['g1'],
        reason: '★ GroupVoice.tsx:123–129 的房内命中判据读它；'
            '丢了它 ⇒ _roomChannel() 恒 null ⇒ 「正在加载语音房…」常驻 = 用户实报的进不去',
      );
    });

    test('★ 侧栏（群桶）在语音帧到达后**不得**把已加载的行整批移出', () async {
      await loadGroupPage(<AylaDirectoryVoiceEntry>[
        _entry('v1', memberCount: 1),
        _entry('v2', memberCount: 0),
      ]);
      expect(
        aylaDirectoryStore
            .itemsAs<AylaDirectoryVoiceEntry>(AylaDirectoryKind.voice, groupOptions)
            .map((AylaDirectoryVoiceEntry e) => e.card.id)
            .toList(),
        <String>['v1', 'v2'],
      );

      // 帧：v1 又有人进（\`voice.channel.member_count_changed\` → \`patchChannel\`）。
      // 域 store 变化 → 订阅通路 \`updateCachedItems\` → \`matchesQuery\` 复查每一行。
      // web 侧白名单在描述符上（\`stores/directory.ts:110–113\`）⇒ 复查通过、行保留。
      await loadGroupPage(<AylaDirectoryVoiceEntry>[
        _entry('v1', memberCount: 1),
        _entry('v2', memberCount: 0),
      ]);
      container.read(voiceStateProvider).patchChannel('v1', memberCount: 5);

      expect(
        aylaDirectoryStore
            .itemsAs<AylaDirectoryVoiceEntry>(AylaDirectoryKind.voice, groupOptions)
            .map((AylaDirectoryVoiceEntry e) => e.card.id)
            .toList(),
        <String>['v1', 'v2'],
        reason: '★ 用户的「侧栏语音房整批消失」：投影回缓存的行丢了白名单 ⇒ '
            'matchesQuery 判它不属于本群 ⇒ 被移出列表',
      );
    });

    test('群归属 group 随条目落地（web 分享载荷 extra.group_id 的事实源）', () async {
      await loadGroupPage(<AylaDirectoryVoiceEntry>[_entry('v1')]);
      expect(
        container.read(voiceStateProvider).channelOf('v1')!.group,
        'g1',
        reason: 'web VoiceRoomBody.tsx:281–287 的 voiceSharePayload({group_id: channel.group})',
      );
    });
  });

  group('侧栏语音人数 = 目录 total_member_count（web ChannelSidebar.tsx:127）', () {
    test('不是「已加载页的人数之和」——后端返回的是完整可见目录的成员数', () async {
      // 后端 `voice/views.py:141–144`：`total_member_count` 统计**完整可见目录**，
      // 与当页 `results` 的 `member_count` 之和可以不等（分页只给前 20 条）。
      aylaDirectoryStore.userId = 'u1';
      aylaDirectoryStore.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
            results: <Object>[_entry('v1', memberCount: 2)],
            total: 40,
            totalMemberCount: 137,
          );
      await aylaDirectoryStore.load(AylaDirectoryKind.voice, groupOptions);

      expect(
        aylaDirectoryStore
            .recordOf(AylaDirectoryKind.voice, groupOptions)!
            .totalMemberCount,
        137,
        reason: '侧栏裸文本读它（tsx 127 `voiceDirectory.totalMemberCount ?? 0`）；'
            '用当页人数之和会显示成 2 而不是 137',
      );
    });
  });
}
