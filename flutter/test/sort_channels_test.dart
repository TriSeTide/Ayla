/// 语音/直播排序定向测试 —— 事实源 Ayla/web/src/utils/sortChannels.ts（62 行）。
///
/// 口径：逐条对照 web 的行号断言。
/// | web | 行 | 断言 |
/// |---|---|---|
/// | toMs | 26–30 | null / 空串 / 非法 → 0；合法 ISO → 毫秒 |
/// | sortVoiceChannels | 33–36 | 有人区（member_count > 0）整体置顶 |
/// | 同上 | 37–39 | 有人区内部按 last_occupied_at 新→旧 |
/// | 同上 | 40–42 | 无人但有历史（last_occupied_at / last_vacant_at 任一非空）压住从未有人 |
/// | 同上 | 43 | 无人有历史档按 last_vacant_at 新→旧（变空不回初始位） |
/// | 同上 | 44 | 从未有人按 created_at 降序 |
/// | sortLiveChannels | 48–61 | 在播 → 曾播 → 从未；各档内部按对应时间降序 |
///
/// **稳定序**是本轮的重点：Dart 的 `List.sort` 不稳定（web `Array.sort` 自 ES2019 起稳定）
/// ⇒ 并列项必须保持**传入顺序**（实现里用原索引做末位比较键）。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/live_api.dart';
import '../lib/core/api/voice_api.dart';
import '../lib/pages/hub_support.dart';
import '../lib/state/directory_events.dart';
import '../lib/widgets/live/live_hall.dart' show AylaLiveCardData, AylaLiveStatus;
import '../lib/widgets/voice/voice_channels.dart' show AylaVoiceCardData;

AylaDirectoryVoiceEntry _voice(
  String id, {
  int memberCount = 0,
  String? createdAt,
  String? lastOccupiedAt,
  String? lastVacantAt,
  String name = '',
}) =>
    AylaDirectoryVoiceEntry(
      card: AylaVoiceCardData(
        id: id,
        name: name.isEmpty ? id : name,
        memberCount: memberCount,
      ),
      createdAt: createdAt,
    );

AylaDirectoryLiveEntry _live(
  String id, {
  AylaLiveStatus? status,
  String? startedAt,
  String? endedAt,
  String? createdAt,
  String title = '',
}) =>
    AylaDirectoryLiveEntry(
      card: AylaLiveCardData(
        id: id,
        title: title.isEmpty ? id : title,
        status: status,
      ),
      startedAt: startedAt,
      endedAt: endedAt,
      createdAt: createdAt,
    );

/// 从排序结果取 id 序列（断言用）。
List<String> _ids(List<AylaDirectoryVoiceEntry> list) =>
    <String>[for (final AylaDirectoryVoiceEntry e in list) e.card.id];

List<String> _liveIds(List<AylaDirectoryLiveEntry> list) =>
    <String>[for (final AylaDirectoryLiveEntry e in list) e.card.id];

/// 构造「排序投影」表（web 的排序读 VoiceChannelDescriptor 的四个字段）。
Map<String, AylaVoiceSortFacts> _facts(Map<String, AylaVoiceSortFacts> map) => map;

void main() {
  group('aylaSortToMs（web toMs，sortChannels.ts:26–30）', () {
    test('null / 空串 / 非法 → 0（不猜时间）', () {
      expect(aylaSortToMs(null), 0);
      expect(aylaSortToMs(''), 0);
      expect(aylaSortToMs('不是时间'), 0);
    });

    test('合法 ISO → 毫秒（与时区偏移无关的绝对时刻）', () {
      expect(
        aylaSortToMs('2026-09-28T12:00:00Z'),
        DateTime.utc(2026, 9, 28, 12).millisecondsSinceEpoch,
      );
    });
  });

  group('aylaHubSortVoice：三档判据（web sortVoiceChannels 33–44）', () {
    test('有人区整体置顶，内部按 last_occupied_at 新→旧', () {
      final List<AylaDirectoryVoiceEntry> items = <AylaDirectoryVoiceEntry>[
        _voice('empty'),
        _voice('occ_old'),
        _voice('occ_new'),
      ];
      final List<String> sorted = _ids(
        aylaHubSortVoice(
          items,
          factsOf: _facts(<String, AylaVoiceSortFacts>{
            'empty': const AylaVoiceSortFacts(memberCount: 0),
            'occ_old': const AylaVoiceSortFacts(
              memberCount: 2,
              lastOccupiedAt: '2026-09-28T10:00:00Z',
            ),
            'occ_new': const AylaVoiceSortFacts(
              memberCount: 1,
              lastOccupiedAt: '2026-09-28T11:00:00Z',
            ),
          }),
        ),
      );
      expect(sorted, <String>['occ_new', 'occ_old', 'empty'],
          reason: '有人区（占 2 席与 1 席都算）压住无人房；内部按最近有人进入降序');
    });

    test('无人有历史（last_vacant_at）压住从未有人；按 last_vacant_at 降序', () {
      final List<String> sorted = _ids(
        aylaHubSortVoice(
          <AylaDirectoryVoiceEntry>[_voice('never'), _voice('vacant_old'), _voice('vacant_new')],
          factsOf: _facts(<String, AylaVoiceSortFacts>{
            'never': const AylaVoiceSortFacts(memberCount: 0, createdAt: '2026-09-28T12:00:00Z'),
            'vacant_old': const AylaVoiceSortFacts(
              memberCount: 0,
              lastOccupiedAt: '2026-09-28T08:00:00Z',
              lastVacantAt: '2026-09-28T09:00:00Z',
            ),
            'vacant_new': const AylaVoiceSortFacts(
              memberCount: 0,
              lastOccupiedAt: '2026-09-28T08:00:00Z',
              lastVacantAt: '2026-09-28T10:00:00Z',
            ),
          }),
        ),
      );
      expect(sorted, <String>['vacant_new', 'vacant_old', 'never'],
          reason: '「变空不回初始位」—— 即使 never 的 created_at 更新，也排在有人历史之后');
    });

    test('「曾进入」两字段兜底：只有 last_occupied_at 也算有历史（web 40 行）', () {
      final List<String> sorted = _ids(
        aylaHubSortVoice(
          <AylaDirectoryVoiceEntry>[_voice('never'), _voice('legacy')],
          factsOf: _facts(<String, AylaVoiceSortFacts>{
            'never': const AylaVoiceSortFacts(memberCount: 0),
            'legacy': const AylaVoiceSortFacts(
              memberCount: 0,
              lastOccupiedAt: '2026-09-28T08:00:00Z',
              // last_vacant_at 缺失（部署前的老房间）
            ),
          }),
        ),
      );
      expect(sorted, <String>['legacy', 'never']);
    });

    test('从未有人档按 created_at 降序（web 44 行）', () {
      final List<String> sorted = _ids(
        aylaHubSortVoice(
          <AylaDirectoryVoiceEntry>[_voice('old'), _voice('new'), _voice('mid')],
          factsOf: _facts(<String, AylaVoiceSortFacts>{
            'old': const AylaVoiceSortFacts(memberCount: 0, createdAt: '2026-09-01T00:00:00Z'),
            'new': const AylaVoiceSortFacts(memberCount: 0, createdAt: '2026-09-28T00:00:00Z'),
            'mid': const AylaVoiceSortFacts(memberCount: 0, createdAt: '2026-09-15T00:00:00Z'),
          }),
        ),
      );
      expect(sorted, <String>['new', 'mid', 'old']);
    });

    test('稳定序：同档并列保持传入顺序（Dart List.sort 不稳定 ⇒ 必须显式二级键）', () {
      // 五个房间完全同档同值 —— web Array.sort 稳定 ⇒ 输出顺序 = 输入顺序。
      final List<AylaDirectoryVoiceEntry> items = <AylaDirectoryVoiceEntry>[
        _voice('a'),
        _voice('b'),
        _voice('c'),
        _voice('d'),
        _voice('e'),
      ];
      final Map<String, AylaVoiceSortFacts> facts = <String, AylaVoiceSortFacts>{
        for (final AylaDirectoryVoiceEntry e in items)
          e.card.id: const AylaVoiceSortFacts(
            memberCount: 0,
            createdAt: '2026-09-28T00:00:00Z',
          ),
      };
      expect(_ids(aylaHubSortVoice(items, factsOf: facts)),
          <String>['a', 'b', 'c', 'd', 'e']);
    });

    test('缺席 factsOf 的条目按条目自带字段（人数 + created_at）参与，不伪造时间戳', () {
      final List<AylaDirectoryVoiceEntry> items = <AylaDirectoryVoiceEntry>[
        _voice('idle', createdAt: '2026-09-01T00:00:00Z'),
        _voice('busy', memberCount: 3),
      ];
      // factsOf 为空 ⇒ 全部走 ofEntry：busy 有人在 ⇒ 置顶。
      expect(_ids(aylaHubSortVoice(items)), <String>['busy', 'idle']);
    });

    test('输入列表不被就地修改（web 的 [...list].sort）', () {
      final List<AylaDirectoryVoiceEntry> items = <AylaDirectoryVoiceEntry>[
        _voice('x'),
        _voice('y', memberCount: 1),
      ];
      final List<AylaDirectoryVoiceEntry> sorted = aylaHubSortVoice(items);
      expect(_ids(items), <String>['x', 'y'], reason: '原列表顺序不变');
      expect(_ids(sorted), <String>['y', 'x']);
    });
  });

  group('aylaHubSortLive（web sortLiveChannels 48–61，既有件回归锁）', () {
    test('在播 → 曾播 → 从未；内部各按 started_at / ended_at / created_at 降序', () {
      final List<String> sorted = _liveIds(
        aylaHubSortLive(<AylaDirectoryLiveEntry>[
          _live('never', createdAt: '2026-09-28T12:00:00Z'),
          _live('live_old', status: AylaLiveStatus.live, startedAt: '2026-09-28T08:00:00Z'),
          _live('ended_new',
              status: AylaLiveStatus.ended,
              startedAt: '2026-09-27T00:00:00Z',
              endedAt: '2026-09-28T10:00:00Z'),
          _live('live_new', status: AylaLiveStatus.live, startedAt: '2026-09-28T09:00:00Z'),
          _live('ended_old',
              status: AylaLiveStatus.ended,
              startedAt: '2026-09-26T00:00:00Z',
              endedAt: '2026-09-27T00:00:00Z'),
        ]),
      );
      expect(sorted, <String>[
        'live_new',
        'live_old',
        'ended_new',
        'ended_old',
        'never',
      ]);
    });
  });

  group('目录事件 → 已加载条目的纯投影（web chat.ts 的 voice./live. 分支）', () {
    test('voice deleted ⇒ 去掉该条，不触发重取', () {
      final ({List<AylaDirectoryVoiceEntry> items, bool refresh}) r =
          aylaHubApplyVoiceEvent(
        <AylaDirectoryVoiceEntry>[_voice('a'), _voice('b')],
        const AylaDirectoryEvent.deleted(AylaDirectoryKind.voice, 'a'),
      );
      expect(_ids(r.items), <String>['b']);
      expect(r.refresh, isFalse);
    });

    test('voice memberCount ⇒ 只换该条人数（web voice.ts patchChannel）', () {
      final ({List<AylaDirectoryVoiceEntry> items, bool refresh}) r =
          aylaHubApplyVoiceEvent(
        <AylaDirectoryVoiceEntry>[_voice('a', memberCount: 0), _voice('b')],
        const AylaDirectoryEvent.patched(AylaDirectoryKind.voice, 'a', 5),
      );
      expect(r.refresh, isFalse);
      expect(r.items.first.card.memberCount, 5);
      expect(r.items.first.card.id, 'a', reason: '就地替换，位置不动');
      expect(r.items[1].card.memberCount, 0, reason: '其他条目不动（默认 0，未被事件改写）');
    });

    test('voice invalidated ⇒ 原列表 + refresh（web 置 invalidated 由页面重取）', () {
      final ({List<AylaDirectoryVoiceEntry> items, bool refresh}) r =
          aylaHubApplyVoiceEvent(
        <AylaDirectoryVoiceEntry>[_voice('a')],
        const AylaDirectoryEvent.invalidated(AylaDirectoryKind.voice),
      );
      expect(r.refresh, isTrue);
      expect(_ids(r.items), <String>['a']);
    });

    test('live viewers.changed ⇒ 只换在看人数（web live.ts patchViewerCount：不改排序）', () {
      final ({List<AylaDirectoryLiveEntry> items, bool refresh}) r =
          aylaHubApplyLiveEvent(
        <AylaDirectoryLiveEntry>[_live('1'), _live('2')],
        const AylaDirectoryEvent.patched(AylaDirectoryKind.live, '1', 42),
      );
      expect(r.refresh, isFalse);
      expect(r.items.first.card.viewerCount, 42);
      expect(r.items[1].card.viewerCount, isNull);
    });

    test('live deleted / status.changed ⇒ 删条 / 重取', () {
      expect(
        aylaHubApplyLiveEvent(
          <AylaDirectoryLiveEntry>[_live('1'), _live('2')],
          const AylaDirectoryEvent.deleted(AylaDirectoryKind.live, '2'),
        ).items.length,
        1,
      );
      expect(
        aylaHubApplyLiveEvent(
          <AylaDirectoryLiveEntry>[_live('1')],
          const AylaDirectoryEvent.invalidated(AylaDirectoryKind.live),
        ).refresh,
        isTrue,
      );
    });
  });
}
