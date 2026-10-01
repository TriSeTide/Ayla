/// GroupPage 目录事件接线回归锁 —— 用户实报「宽屏第二列侧栏排序依然错误」的第二根因。
///
/// ## 事实源
/// WS 帧桥（`core/ws/room_frames.dart`）确实在广播目录事件：
/// - `emitPatched(voice, channelId, count)`（`:195`，来自 `voice.channel.member_count_changed`）
/// - `emitPatched(live, channelId, count)`（`:229`，来自 `live.viewers.changed`）
/// - `emitInvalidated(voice)`（`:165`）/ `emitInvalidated(live)`（`:211`）
/// - `emitDeleted(voice/live/game)`（`:113/124/149`）
///
/// 而 web 侧这些帧对**目录列表**的效应由 `stores/directory.ts:205–219` 的
/// `ensureDirectoryTracking` 承担（订阅三个域 store ⇒ `updateCachedItems` 重排 record）。
///
/// ## 本文件锁什么
/// 1. `AylaDirectoryEvents` 的三档语义 + revision 递增（事件不丢、可判重）；
/// 2. 「voice/live 事件 → 已加载条目」的纯投影（`hub_support` 的两个纯函数）在
///    **分页列表层**的净效果：删除后不再在列表里、人数变化后就地换值且**重排**；
/// 3. `live.channel.*` 的失效档 ⇒ 走 refresh（页面照 `voice_hub_page.dart:153` 的口径）。
///
/// ⚠️ 这里不启动真实 GroupPage（它需要真实路由 + WS）：覆盖的是**页面消费事件时调用的那两层**
/// （事件总线 + 纯投影 + `AylaPagedList`），与 `group_page.dart` 的
/// `_applyVoiceDirectoryEvent` / `_applyLiveDirectoryEvent` 逐行同源。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/directory_page.dart';
import '../lib/core/api/live_api.dart';
import '../lib/core/api/voice_api.dart';
import '../lib/pages/hub_support.dart';
import '../lib/state/directory_events.dart';
import '../lib/state/paged_list.dart';
import '../lib/widgets/live/live_hall.dart' show AylaLiveCardData, AylaLiveStatus;
import '../lib/widgets/voice/voice_channels.dart' show AylaVoiceCardData;

AylaDirectoryVoiceEntry _voice(String id, {int count = 0}) =>
    AylaDirectoryVoiceEntry(
      card: AylaVoiceCardData(id: id, name: id, memberCount: count),
    );

AylaDirectoryLiveEntry _live(
  String id, {
  AylaLiveStatus? status = AylaLiveStatus.live,
  String title = '',
}) =>
    AylaDirectoryLiveEntry(
      card: AylaLiveCardData(
        id: id,
        title: title.isEmpty ? id : title,
        status: status,
      ),
    );

void main() {
  group('目录事件总线语义（state/directory_events.dart）', () {
    test('三档 emit 都推进 revision 并 notify（页面按 revision 判重）', () {
      final AylaDirectoryEvents events = AylaDirectoryEvents();
      int notified = 0;
      events.addListener(() => notified += 1);
      expect(events.revision, 0);

      events.emitPatched(AylaDirectoryKind.voice, 'v1', 3);
      expect(events.revision, 1);
      expect(events.last?.kind, AylaDirectoryKind.voice);
      expect(events.last?.id, 'v1');
      expect(events.last?.memberCount, 3);
      expect(events.last?.deleted, isFalse);

      events.emitDeleted(AylaDirectoryKind.live, 'l1');
      expect(events.revision, 2);
      expect(events.last?.deleted, isTrue);

      events.emitInvalidated(AylaDirectoryKind.voice);
      expect(events.revision, 3);
      expect(events.last?.memberCount, isNull);
      expect(events.last?.deleted, isFalse);

      expect(notified, 3);
    });
  });

  group('voice.channel.* → 分页列表（web directory.ts:205–219 + voice.ts:156–165）', () {
    test('member_count_changed ⇒ 行内人数就地更新，且重排后该房置顶', () async {
      final AylaPagedList<AylaDirectoryVoiceEntry> list =
          AylaPagedList<AylaDirectoryVoiceEntry>(
        request: (String? cursor) async => AylaDirectoryPage<AylaDirectoryVoiceEntry>(
          results: <AylaDirectoryVoiceEntry>[_voice('a'), _voice('b')],
        ),
        keyOf: (AylaDirectoryVoiceEntry e) => e.card.id,
      );
      addTearDown(list.dispose);
      await list.load();
      expect(
        <String>[for (final AylaDirectoryVoiceEntry e in list.items) e.card.id],
        <String>['a', 'b'],
      );

      // 事件到达 ⇒ 页面做「纯投影 + setItems」，槽位处再套排序。
      final ({List<AylaDirectoryVoiceEntry> items, bool refresh}) applied =
          aylaHubApplyVoiceEvent(
        list.items,
        const AylaDirectoryEvent.patched(AylaDirectoryKind.voice, 'b', 1),
      );
      expect(applied.refresh, isFalse);
      list.setItems(applied.items);

      expect(list.items[1].card.memberCount, 1, reason: '行内人数就地更新（web patchChannel）');
      expect(
        <String>[
          for (final AylaDirectoryVoiceEntry e in aylaHubSortVoice(list.items))
            e.card.id,
        ],
        <String>['b', 'a'],
        reason: '排序在投影处表达 ⇒ 有人区置顶（web sortChannels.ts:34–36）',
      );
    });

    test('voice.channel.deleted ⇒ 该条从列表移除（web items.filter）', () async {
      final AylaPagedList<AylaDirectoryVoiceEntry> list =
          AylaPagedList<AylaDirectoryVoiceEntry>(
        request: (String? cursor) async => AylaDirectoryPage<AylaDirectoryVoiceEntry>(
          results: <AylaDirectoryVoiceEntry>[_voice('a'), _voice('b')],
        ),
        keyOf: (AylaDirectoryVoiceEntry e) => e.card.id,
      );
      addTearDown(list.dispose);
      await list.load();

      final ({List<AylaDirectoryVoiceEntry> items, bool refresh}) applied =
          aylaHubApplyVoiceEvent(
        list.items,
        const AylaDirectoryEvent.deleted(AylaDirectoryKind.voice, 'a'),
      );
      list.setItems(applied.items);
      expect(
        <String>[for (final AylaDirectoryVoiceEntry e in list.items) e.card.id],
        <String>['b'],
      );
    });

    test('voice.channel.created/updated（invalidated）⇒ 原列表不动 + 触发重取', () async {
      int calls = 0;
      final AylaPagedList<AylaDirectoryVoiceEntry> list =
          AylaPagedList<AylaDirectoryVoiceEntry>(
        request: (String? cursor) async {
          calls += 1;
          return AylaDirectoryPage<AylaDirectoryVoiceEntry>(
            results: <AylaDirectoryVoiceEntry>[_voice('a')],
          );
        },
        keyOf: (AylaDirectoryVoiceEntry e) => e.card.id,
      );
      addTearDown(list.dispose);
      await list.load();
      expect(calls, 1);

      final ({List<AylaDirectoryVoiceEntry> items, bool refresh}) applied =
          aylaHubApplyVoiceEvent(
        list.items,
        const AylaDirectoryEvent.invalidated(AylaDirectoryKind.voice),
      );
      expect(applied.refresh, isTrue);
      if (applied.refresh) await list.refresh();
      expect(calls, 2, reason: '失效档 ⇒ 页面重取首页（voice_hub_page.dart:153 的同一口径）');
    });
  });

  group('live.channel.* / live.viewers.changed → 分页列表', () {
    test('viewers.changed ⇒ 只换在看人数、不重取（web live.ts:218–224）', () async {
      int calls = 0;
      final AylaPagedList<AylaDirectoryLiveEntry> list =
          AylaPagedList<AylaDirectoryLiveEntry>(
        request: (String? cursor) async {
          calls += 1;
          return AylaDirectoryPage<AylaDirectoryLiveEntry>(
            results: <AylaDirectoryLiveEntry>[_live('1'), _live('2')],
          );
        },
        keyOf: (AylaDirectoryLiveEntry e) => e.card.id,
      );
      addTearDown(list.dispose);
      await list.load();

      final ({List<AylaDirectoryLiveEntry> items, bool refresh}) applied =
          aylaHubApplyLiveEvent(
        list.items,
        const AylaDirectoryEvent.patched(AylaDirectoryKind.live, '1', 7),
      );
      expect(applied.refresh, isFalse);
      list.setItems(applied.items);
      expect(list.items.first.card.viewerCount, 7);
      expect(calls, 1, reason: '人数是瞬态投影 ⇒ 不拉 REST、不标失效');
    });

    test('status.changed（invalidated）⇒ 重取（LIVE 标记随之更新）', () async {
      int calls = 0;
      AylaLiveStatus status = AylaLiveStatus.idle;
      final AylaPagedList<AylaDirectoryLiveEntry> list =
          AylaPagedList<AylaDirectoryLiveEntry>(
        request: (String? cursor) async {
          calls += 1;
          return AylaDirectoryPage<AylaDirectoryLiveEntry>(
            results: <AylaDirectoryLiveEntry>[_live('1', status: status)],
          );
        },
        keyOf: (AylaDirectoryLiveEntry e) => e.card.id,
      );
      addTearDown(list.dispose);
      await list.load();
      expect(list.items.first.card.status, AylaLiveStatus.idle);

      status = AylaLiveStatus.live;
      final ({List<AylaDirectoryLiveEntry> items, bool refresh}) applied =
          aylaHubApplyLiveEvent(
        list.items,
        const AylaDirectoryEvent.invalidated(AylaDirectoryKind.live),
      );
      expect(applied.refresh, isTrue);
      await list.refresh();
      expect(calls, 2);
      expect(list.items.first.card.status, AylaLiveStatus.live);
    });

    test('live.channel.deleted ⇒ 移除该条', () async {
      final AylaPagedList<AylaDirectoryLiveEntry> list =
          AylaPagedList<AylaDirectoryLiveEntry>(
        request: (String? cursor) async => AylaDirectoryPage<AylaDirectoryLiveEntry>(
          results: <AylaDirectoryLiveEntry>[_live('1'), _live('2')],
        ),
        keyOf: (AylaDirectoryLiveEntry e) => e.card.id,
      );
      addTearDown(list.dispose);
      await list.load();
      final ({List<AylaDirectoryLiveEntry> items, bool refresh}) applied =
          aylaHubApplyLiveEvent(
        list.items,
        const AylaDirectoryEvent.deleted(AylaDirectoryKind.live, '2'),
      );
      list.setItems(applied.items);
      expect(list.items.length, 1);
      expect(list.items.first.card.id, '1');
    });
  });
}
