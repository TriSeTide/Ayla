/// 房内页批次（2026-09-28）的 voice 域定向测试。
///
/// 覆盖四层，全部**不发真网络**：
/// 1. **帧解析与枚举**（`voice.state` 的 state 枚举：未知值 → null，不 fallback）；
/// 2. **状态层**（[AylaVoiceState]：`applyVoiceState` 的四种 state 合并 / 对账保本地偏好 /
///    远端音量全量快照 / 频道 patch 与移除）；
/// 3. **WS 客户端**（[AylaVoiceWsClient]：订阅帧形状、重连重发整个集合、域外帧透传）；
/// 4. **两个分页/窗口设施**（[AylaCursorHistory] / [AylaMediaPagedList]）与
///    [AylaVoiceSessionRuntime] 的代际与串行语义；
/// 5. **API 投影**（`AylaVoiceChannelSnapshot` / `AylaVoiceMemberDescriptor` /
///    `AylaVoiceChatMessage` 的解析与缺席语义）。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/api/media_page.dart';
import '../lib/core/api/voice_api.dart';
import '../lib/core/ws/voice_ws.dart';
import '../lib/state/cursor_history.dart';
import '../lib/state/media_paged_list.dart';
import '../lib/state/realtime_state.dart';
import '../lib/state/voice_state.dart';
import '../lib/pages/voice_support.dart';

/// 历史窗口的测试条目（id / created_at 双投影）。
class _Row {
  const _Row(this.id, this.at);

  final String id;
  final String at;
}

void main() {
  group('voice.state 帧枚举', () {
    test('五个合法值逐个解析', () {
      expect(AylaVoiceMemberEventState.parse('joined'),
          AylaVoiceMemberEventState.joined);
      expect(AylaVoiceMemberEventState.parse('left'),
          AylaVoiceMemberEventState.left);
      expect(AylaVoiceMemberEventState.parse('heartbeat'),
          AylaVoiceMemberEventState.heartbeat);
      expect(AylaVoiceMemberEventState.parse('muted'),
          AylaVoiceMemberEventState.muted);
      expect(AylaVoiceMemberEventState.parse('unmuted'),
          AylaVoiceMemberEventState.unmuted);
    });

    test('未知值 → null（不 fallback 成 joined/heartbeat）', () {
      expect(AylaVoiceMemberEventState.parse('kicked'), isNull);
      expect(AylaVoiceMemberEventState.parse(null), isNull);
      expect(AylaVoiceMemberEventState.parse(7), isNull);
    });
  });

  group('AylaVoiceState（web stores/voice.ts）', () {
    test('enterChannel 铺底 + applyVoiceState 合并（仅当前频道）', () {
      final AylaVoiceState state = AylaVoiceState();
      state.enterChannel('v1', <AylaVoiceMemberState>[
        const AylaVoiceMemberState(userId: 'u1', joinedAt: 't0'),
      ]);
      // 其他频道的帧被忽略
      state.applyVoiceState('v2', 'u9', AylaVoiceMemberEventState.joined, 't1');
      expect(state.members.containsKey('u9'), isFalse);
      // joined 新增
      state.applyVoiceState('v1', 'u2', AylaVoiceMemberEventState.joined, 't1');
      expect(state.members['u2']!.joinedAt, 't1');
      // heartbeat 只更新时间
      state.applyVoiceState('v1', 'u2', AylaVoiceMemberEventState.heartbeat, 't2');
      expect(state.members['u2']!.lastSeenAt, 't2');
      // muted 只改静音位
      state.applyVoiceState('v1', 'u2', AylaVoiceMemberEventState.muted, 't3');
      expect(state.members['u2']!.muted, isTrue);
      expect(state.members['u2']!.lastSeenAt, 't3');
      // unmuted 复位
      state.applyVoiceState('v1', 'u2', AylaVoiceMemberEventState.unmuted, 't4');
      expect(state.members['u2']!.muted, isFalse);
      // left 移除
      state.applyVoiceState('v1', 'u1', AylaVoiceMemberEventState.left, 't5');
      expect(state.members.containsKey('u1'), isFalse);
    });

    test('muted 帧对不在表里的成员是 no-op（不凭空插入）', () {
      final AylaVoiceState state = AylaVoiceState();
      state.enterChannel('v1', const <AylaVoiceMemberState>[]);
      state.applyVoiceState('v1', 'ghost', AylaVoiceMemberEventState.muted, 't');
      expect(state.members, isEmpty);
    });

    test('reconcileMembers 以服务端为权威，但保留本地音量偏好', () {
      final AylaVoiceState state = AylaVoiceState();
      state.enterChannel('v1', <AylaVoiceMemberState>[
        const AylaVoiceMemberState(
          userId: 'u1',
          volume: 40,
          locallyMuted: true,
          audioLevel: 0.5,
        ),
      ]);
      state.reconcileMembers(<AylaVoiceMemberDescriptor>[
        const AylaVoiceMemberDescriptor(
          id: 1,
          userId: 'u1',
          joinedAt: 'j',
          lastSeenAt: 's',
        ),
        const AylaVoiceMemberDescriptor(id: 2, userId: 'u2'),
      ]);
      expect(state.members.length, 2);
      expect(state.members['u1']!.volume, 40);
      expect(state.members['u1']!.locallyMuted, isTrue);
      expect(state.members['u1']!.audioLevel, 0.5);
      expect(state.members['u1']!.joinedAt, 'j');
      expect(state.members['u2']!.volume, 100);
    });

    test('setRemoteAudioLevels 是全量快照（缺席归 0）', () {
      final AylaVoiceState state = AylaVoiceState();
      state.enterChannel('v1', <AylaVoiceMemberState>[
        const AylaVoiceMemberState(userId: 'u1', audioLevel: 0.9),
        const AylaVoiceMemberState(userId: 'u2'),
      ]);
      state.setRemoteAudioLevels(<String, double>{'u1': 0.3});
      expect(state.members['u1']!.audioLevel, 0.3);
      expect(state.members['u2']!.audioLevel, 0);
    });

    test('本地音量 0~100 取整夹取；成员音量只在表内生效', () {
      final AylaVoiceState state = AylaVoiceState();
      state.enterChannel('v1', <AylaVoiceMemberState>[
        const AylaVoiceMemberState(userId: 'u1'),
      ]);
      state.setLocalVolume(120);
      expect(state.localVolume, 100);
      state.setLocalVolume(-5);
      expect(state.localVolume, 0);
      state.setLocalVolume(66.6);
      expect(state.localVolume, 67);
      state.setMemberVolume('ghost', 30);
      expect(state.members.containsKey('ghost'), isFalse);
      state.setMemberVolume('u1', 30);
      expect(state.members['u1']!.volume, 30);
    });

    test('频道表：upsert / patch（只改人数与 mine）/ remove', () {
      final AylaVoiceState state = AylaVoiceState();
      state.upsertChannel(AylaVoiceChannelSnapshot(
        id: 'v1',
        name: '房',
        memberCount: 2,
        mine: false,
      ));
      state.patchChannel('v1', memberCount: 3, mine: true);
      expect(state.channelOf('v1')!.memberCount, 3);
      expect(state.channelOf('v1')!.mine, isTrue);
      // 不存在的频道 patch 是 no-op
      state.patchChannel('v9', memberCount: 1);
      expect(state.channels.length, 1);
      state.removeChannel('v1');
      expect(state.channels, isEmpty);
    });

    test('leaveChannelLocal 复位媒体与本地偏好（幂等）', () {
      final AylaVoiceState state = AylaVoiceState();
      state.enterChannel('v1', <AylaVoiceMemberState>[
        const AylaVoiceMemberState(userId: 'u1'),
      ]);
      state.setMedia(AylaVoiceMediaConnection.connected);
      state.setMicEnabled(true);
      state.setLocalVolume(70);
      state.leaveChannelLocal();
      expect(state.currentChannelId, isNull);
      expect(state.members, isEmpty);
      expect(state.media, AylaVoiceMediaConnection.idle);
      expect(state.micEnabled, isFalse);
      expect(state.localVolume, 100);
      state.leaveChannelLocal();
      expect(state.currentChannelId, isNull);
    });
  });

  group('AylaVoiceWsClient（web ws/voice.ts）', () {
    test('subscribe 幂等且帧形状 = {type, channel_ids}', () {
      final AylaVoiceState state = AylaVoiceState();
      final AylaVoiceWsClient client = AylaVoiceWsClient(
        voiceState: state,
        realtime: AylaRealtimeState(),
      );
      final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
      client.debugSend = sent.add;
      client.subscribe(<String>['v1', 'v2']);
      client.subscribe(<String>['v2', 'v3']);
      expect(sent.length, 2);
      expect(sent.first['type'], 'subscribe');
      expect(sent.first['channel_ids'], <String>['v1', 'v2']);
      expect(sent.last['channel_ids'], <String>['v3']);
      expect(client.isSubscribed('v1'), isTrue);
      client.unsubscribe('v1');
      expect(client.isSubscribed('v1'), isFalse);
      expect(sent.length, 2, reason: '退订不发帧（服务端无退订帧）');
    });

    test('首连不补发；重连重发整个集合并触发对账回调', () {
      final AylaVoiceState state = AylaVoiceState();
      final AylaVoiceWsClient client = AylaVoiceWsClient(
        voiceState: state,
        realtime: AylaRealtimeState(),
      );
      final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
      client.debugSend = sent.add;
      client.subscribe(<String>['v1']);
      sent.clear();
      client.debugHandleOpen(); // 首连
      expect(sent, isEmpty);
      int reconciled = 0;
      client.onReconnected(() => reconciled++);
      client.debugHandleOpen(); // 重连
      expect(sent.single['channel_ids'], <String>['v1']);
      expect(reconciled, 1);
    });

    test('voice.state 写入状态；未知 state 不猜测语义；其余帧只透传', () {
      final AylaVoiceState state = AylaVoiceState();
      state.enterChannel('v1', const <AylaVoiceMemberState>[]);
      final AylaVoiceWsClient client = AylaVoiceWsClient(
        voiceState: state,
        realtime: AylaRealtimeState(),
      );
      final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
      client.onFrame(frames.add);
      client.debugHandleFrame(<String, dynamic>{
        'type': 'voice.state',
        'data': <String, dynamic>{
          'channel_id': 'v1',
          'user_id': 'u1',
          'state': 'joined',
          'ts': 't1',
        },
      });
      expect(state.members.containsKey('u1'), isTrue);
      client.debugHandleFrame(<String, dynamic>{
        'type': 'voice.state',
        'data': <String, dynamic>{
          'channel_id': 'v1',
          'user_id': 'u2',
          'state': 'kicked',
        },
      });
      expect(state.members.containsKey('u2'), isFalse, reason: '未知枚举不猜测');
      client.debugHandleFrame(<String, dynamic>{
        'type': 'voice.chat.message',
        'data': <String, dynamic>{'id': 'm1', 'channel_id': 'v1'},
      });
      expect(frames.map((Map<String, dynamic> f) => f['type']).toList(),
          <String>['voice.state', 'voice.state', 'voice.chat.message']);
    });
  });

  group('AylaCursorHistory（web useCursorHistory.ts）', () {
    test('按 (created_at, 数字 id) 升序合并去重', () {
      final List<String> merged = mergeHistoryBy<_Row>(
        <_Row>[const _Row('2', 'b'), const _Row('1', 'a')],
        <_Row>[const _Row('10', 'b'), const _Row('3', 'a')],
        idOf: (_Row r) => r.id,
        createdAtOf: (_Row r) => r.at,
      ).map((_Row r) => r.id).toList();
      expect(merged, <String>['1', '3', '2', '10'], reason: '同刻按 id 数字序');
    });

    test('append 幂等；窗口超限截断并置 hasMore', () async {
      final AylaCursorHistory<_Row> history = AylaCursorHistory<_Row>(
        owner: 'h',
        fetchPage: (String? cursor, String? beforeId) async =>
            const AylaMediaCursorPage<_Row>(results: <_Row>[]),
        idOf: (_Row r) => r.id,
        createdAtOf: (_Row r) => r.at,
        enabled: false,
      );
      // 未启用只影响**拉取**；append 是纯窗口操作（web 同：enabled 只挡 load）。
      expect(history.append(const _Row('1', 'a')), isTrue);
      await history.reset(autoLoad: false);
      expect(history.items, isEmpty, reason: 'reset 清窗口（autoLoad=false 不拉取）');
      expect(history.append(const _Row('1', 'a')), isTrue);
      expect(history.append(const _Row('1', 'a')), isFalse, reason: '同 id 幂等');
      expect(history.items.length, 1);
      expect(history.pendingScrollToBottom, isTrue);
      expect(history.consumeScrollToBottom(), isTrue);
      expect(history.consumeScrollToBottom(), isFalse);
    });

    test('分页契约缺继续位置 ⇒ 显式失败（不静默吞掉）', () async {
      final AylaCursorHistory<_Row> history = AylaCursorHistory<_Row>(
        owner: 'h',
        fetchPage: (String? cursor, String? beforeId) async =>
            const AylaMediaCursorPage<_Row>(
          results: <_Row>[_Row('1', 'a')],
          hasMore: true,
          nextCursor: null,
        ),
        idOf: (_Row r) => r.id,
        createdAtOf: (_Row r) => r.at,
      );
      await history.reset();
      expect(history.error, '历史分页响应缺少有效的继续位置，请重试');
      expect(history.items, isEmpty);
    });

    test('invalidate ⇒ hasNewer；上翻期间新条目挂起（不改窗口）', () async {
      final AylaCursorHistory<_Row> history = AylaCursorHistory<_Row>(
        owner: 'h',
        fetchPage: (String? cursor, String? beforeId) async =>
            AylaMediaCursorPage<_Row>(
          results: <_Row>[const _Row('1', 'a')],
          hasMore: cursor == null,
          nextCursor: cursor == null ? 'c1' : null,
        ),
        idOf: (_Row r) => r.id,
        createdAtOf: (_Row r) => r.at,
      );
      await history.reset();
      expect(history.items.length, 1);
      history.invalidate();
      expect(history.hasNewer, isTrue);
      history.append(const _Row('2', 'b'));
      expect(history.items.length, 1, reason: 'hasNewer 期间不顶进已读窗口');
    });
  });

  group('AylaMediaPagedList（web usePagedMediaList.ts）', () {
    AylaMediaPagedList<_Row> build(
      Future<AylaMediaCursorPage<_Row>?> Function(String? cursor) request,
    ) =>
        AylaMediaPagedList<_Row>(
          scope: 's',
          request: request,
          idOf: (_Row r) => r.id,
        );

    test('首页 + 续读合并去重、total 覆盖', () async {
      final AylaMediaPagedList<_Row> list = build((String? cursor) async =>
          cursor == null
              ? const AylaMediaCursorPage<_Row>(
                  results: <_Row>[_Row('1', 'a'), _Row('2', 'b')],
                  hasMore: true,
                  nextCursor: 'c1',
                  total: 3,
                )
              : const AylaMediaCursorPage<_Row>(
                  results: <_Row>[_Row('2', 'b'), _Row('3', 'c')],
                  total: 3,
                ));
      await list.refresh();
      expect(list.items.map((_Row r) => r.id), <String>['1', '2']);
      expect(list.total, 3);
      expect(list.hasMore, isTrue);
      await list.loadMore();
      expect(list.items.map((_Row r) => r.id), <String>['1', '2', '3']);
      expect(list.hasMore, isFalse);
    });

    test('游标未推进 ⇒ 静默降级（loading 复位、不报错、保留上一页）', () async {
      final AylaMediaPagedList<_Row> list = build((String? cursor) async =>
          const AylaMediaCursorPage<_Row>(
            results: <_Row>[_Row('1', 'a')],
            hasMore: true,
            nextCursor: null,
          ));
      await list.refresh();
      expect(list.error, isNull);
      expect(list.loading, isFalse);
      expect(list.items, isEmpty);
    });

    test('updateItems 就地改写（left 帧剔除用）', () async {
      final AylaMediaPagedList<_Row> list = build((String? cursor) async =>
          const AylaMediaCursorPage<_Row>(
              results: <_Row>[_Row('1', 'a'), _Row('2', 'b')]));
      await list.refresh();
      list.updateItems((List<_Row> items) => <_Row>[
            for (final _Row r in items)
              if (r.id != '1') r,
          ]);
      expect(list.items.map((_Row r) => r.id), <String>['2']);
    });
  });

  group('AylaVoiceSessionRuntime（web runtime/voiceSessionRuntime.ts）', () {
    test('selectChannel 幂等：同 owner 同频道不推进代际', () {
      final AylaVoiceSessionRuntime runtime = AylaVoiceSessionRuntime();
      final Object owner = Object();
      runtime.selectChannel(owner, 'v1');
      final int first = runtime.currentRevision();
      runtime.selectChannel(owner, 'v1');
      expect(runtime.currentRevision(), first);
      runtime.selectChannel(owner, 'v2');
      expect(runtime.currentRevision(), first + 1);
      expect(runtime.isRevisionCurrent(first), isFalse);
      expect(runtime.selectedChannelId(), 'v2');
      runtime.cancelSelection();
      expect(runtime.selectedChannelId(), isNull);
      runtime.debugReset();
    });

    test('runJoin 合并同一代际的重复请求（只跑一次）', () async {
      final AylaVoiceSessionRuntime runtime = AylaVoiceSessionRuntime();
      final Object owner = Object();
      int runs = 0;
      Future<void> op(bool Function() isCurrent) async {
        runs++;
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      final Future<void> a = runtime.runJoin(owner, 'v1', op);
      final Future<void> b = runtime.runJoin(owner, 'v1', op);
      expect(identical(a, b), isTrue);
      await a;
      expect(runs, 1);
      runtime.debugReset();
    });

    test('runExclusive 串行（不并发进入）', () async {
      final AylaVoiceSessionRuntime runtime = AylaVoiceSessionRuntime();
      final List<String> order = <String>[];
      Future<void> task(String tag) async {
        order.add('start-$tag');
        await Future<void>.delayed(const Duration(milliseconds: 2));
        order.add('end-$tag');
      }

      await Future.wait<void>(<Future<void>>[
        runtime.runExclusive(() => task('a')),
        runtime.runExclusive(() => task('b')),
      ]);
      expect(order, <String>['start-a', 'end-a', 'start-b', 'end-b']);
      runtime.debugReset();
    });

    test('媒体归属：setMediaChannel / ownsMedia', () {
      final AylaVoiceSessionRuntime runtime = AylaVoiceSessionRuntime();
      expect(runtime.ownsMedia('v1'), isFalse);
      runtime.setMediaChannel('v1');
      expect(runtime.mediaChannel(), 'v1');
      expect(runtime.ownsMedia('v1'), isTrue);
      expect(runtime.ownsMedia('v2'), isFalse);
      runtime.setMediaChannel(null);
      expect(runtime.ownsMedia('v1'), isFalse);
      runtime.debugReset();
    });
  });

  group('voice API 投影', () {
    test('AylaVoiceChannelSnapshot：缺席即缺席 + 卡投影 + 可见性标签', () {
      final AylaVoiceChannelSnapshot? channel =
          AylaVoiceChannelSnapshot.fromJson(<String, dynamic>{
        'id': 7,
        'name': '深夜电台',
        'owner_id': 'u1',
        'owner_nickname': '爱莉',
        'member_count': 3,
        'visibility': 'public',
        'mine': true,
        'created_at': '2026-09-28T00:00:00Z',
      });
      expect(channel, isNotNull);
      expect(channel!.id, '7');
      expect(channel.card.memberCount, 3);
      expect(channel.card.mine, isTrue);
      expect(channel.card.ownerNickname, '爱莉');
      expect(channel.visibilityLabels, <String>['公开']);
      expect(channel.group, isNull, reason: '缺 group 即 null');
    });

    test('未知 visibility → null（标签整体为空，不 fallback）', () {
      final AylaVoiceChannelSnapshot? channel =
          AylaVoiceChannelSnapshot.fromJson(<String, dynamic>{
        'id': 'v1',
        'name': 'x',
        'visibility': 'secret',
      });
      expect(channel!.visibility, isNull);
      expect(channel.visibilityLabels, isEmpty);
    });

    test('member_count 缺失 → null（不写 0）', () {
      final AylaVoiceChannelSnapshot? channel =
          AylaVoiceChannelSnapshot.fromJson(<String, dynamic>{
        'id': 'v1',
        'name': 'x',
      });
      expect(channel!.memberCount, isNull);
      expect(channel.card.memberCount, isNull);
    });

    test('AylaVoiceMemberDescriptor：缺 user_id 非法', () {
      expect(
        AylaVoiceMemberDescriptor.fromJson(<String, dynamic>{'id': 1}),
        isNull,
      );
      final AylaVoiceMemberDescriptor? member =
          AylaVoiceMemberDescriptor.fromJson(<String, dynamic>{
        'id': 2,
        'user_id': 42,
        'joined_at': 'j',
      });
      expect(member!.userId, '42');
      expect(member.lastSeenAt, isNull);
    });

    test('AylaVoiceChatMessage：sender/media 投影', () {
      final AylaVoiceChatMessage? message =
          AylaVoiceChatMessage.fromJson(<String, dynamic>{
        'id': 'm1',
        'channel_id': 'v1',
        'sender': <String, dynamic>{
          'user_id': 'u1',
          'nickname': '爱莉',
          'avatar': '/a.png',
        },
        'content': '图片',
        'media_id': 'md1',
        'media': <String, dynamic>{'media_id': 'md1', 'thumbnail': '/t.png'},
        'created_at': 'T',
      });
      expect(message!.senderNickname, '爱莉');
      expect(message.thumbnailUrl, '/t.png');
      expect(message.createdAt, 'T');
    });

    test('AylaMediaCursorPage.parse：结构非法 → null；total 缺省 0', () {
      expect(AylaMediaCursorPage.parse<_Row>(null, (_) => null), isNull);
      expect(
        AylaMediaCursorPage.parse<_Row>(<String, dynamic>{'results': 'x'}, (_) => null),
        isNull,
      );
      final AylaMediaCursorPage<_Row>? page = AylaMediaCursorPage.parse<_Row>(
        <String, dynamic>{
          'results': <Object?>[
            <String, dynamic>{'id': '1'},
          ],
          'has_more': true,
        },
        (Object? raw) => _Row('1', 'a'),
      );
      expect(page!.results.length, 1);
      expect(page.total, 0);
      expect(page.nextCursor, isNull);
    });
  });
}
