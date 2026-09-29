/// 群场景数据层与页面层定向测试 —— 事实源：`Ayla/web/src/stores/subgroup.ts`（220 行）、
/// `stores/subgroupRead.ts`、`stores/group.ts`、`pages/GroupPage.tsx`（539 行）、
/// `hooks/useSwipeCommit.ts`、`hooks/useChat.ts:69–78`。
///
/// 口径：只锁**可指到 web 行号**的语义 —— 子群未读的精确消除、活跃度单调、
/// 松手判定三分支、路由场景优先级、子群视图过滤。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/chat_message.dart';
import '../lib/core/models/conversation.dart';
import '../lib/core/models/subgroup.dart';
import '../lib/pages/group_chat_page.dart' show aylaMessageInSubgroup;
import '../lib/pages/group_page.dart'
    show aylaGroupSceneDirection, aylaGroupSceneOrderIndex, aylaResolveSwipeCommit;
import '../lib/pages/group_support.dart';
import '../lib/state/chat_state.dart';
import '../lib/state/group_providers.dart';
import '../lib/state/group_state.dart';
import '../lib/state/message_state.dart';
import '../lib/state/subgroup_state.dart';
import '../lib/widgets/base/avatar_status_badges.dart' show AylaAvatarStatus;
import '../lib/widgets/shell/channel_sidebar.dart' show AylaGroupScene;

AylaChatMessage _msg({
  required String id,
  required int seq,
  String? subgroupId,
}) =>
    AylaChatMessage(
      id: id,
      conversationId: 'g1',
      senderId: 'u1',
      type: AylaMessageType.text,
      content: 'x',
      status: AylaMessageStatus.sent,
      seq: seq,
      createdAt: '2026-09-29T00:00:00Z',
      subgroupId: subgroupId,
    );

AylaSubGroup _sg(
  String id, {
  bool isDefault = false,
  int unreadCount = 0,
  List<int> unreadSeqs = const <int>[],
  bool hasUnreadSeqs = false,
  bool? muted,
  int? lastSeq,
}) =>
    AylaSubGroup(
      id: id,
      conversationId: 'g1',
      name: '组$id',
      isDefault: isDefault,
      muted: muted,
      unreadCount: unreadCount,
      unreadSeqs: unreadSeqs,
      hasUnreadSeqs: hasUnreadSeqs,
      lastMessageSeq: lastSeq,
    );

void main() {
  group('路由场景解析（GroupPage.tsx:216–224）', () {
    test('优先级：postId > voiceChannelId > liveChannelId > scene > chat', () {
      expect(
        aylaGroupSceneFromRoute(
          scene: 'games',
          postId: '12',
          voiceChannelId: 'v1',
          liveChannelId: '3',
        ),
        AylaGroupScene.posts,
      );
      expect(
        aylaGroupSceneFromRoute(scene: 'games', voiceChannelId: 'v1', liveChannelId: '3'),
        AylaGroupScene.voice,
      );
      expect(
        aylaGroupSceneFromRoute(scene: 'games', liveChannelId: '3'),
        AylaGroupScene.live,
      );
      expect(aylaGroupSceneFromRoute(scene: 'games'), AylaGroupScene.games);
      expect(aylaGroupSceneFromRoute(), AylaGroupScene.chat);
    });

    test('未知 scene 回退 chat（VALID_SCENES 过滤）', () {
      expect(aylaGroupSceneFromRoute(scene: 'nope'), AylaGroupScene.chat);
      expect(aylaGroupSceneFromRoute(scene: 'info'), AylaGroupScene.info);
    });

    test('场景索引：info 按 chat 处理（useSceneSwipeDirection.ts:17–19）', () {
      expect(
        aylaGroupSceneOrderIndex(AylaGroupScene.info),
        aylaGroupSceneOrderIndex(AylaGroupScene.chat),
      );
      expect(aylaGroupSceneDirection(AylaGroupScene.chat, AylaGroupScene.info), 0);
      expect(aylaGroupSceneDirection(AylaGroupScene.voice, AylaGroupScene.live), 1);
    });
  });

  group('松手判定（useSwipeCommit.ts:67–90）', () {
    test('净位移过 1/3 宽 → 切（左滑 = 下一个）', () {
      expect(
        aylaResolveSwipeCommit(net: -130, cross: 0, velocity: 0, size: 375),
        1,
      );
      expect(
        aylaResolveSwipeCommit(net: 130, cross: 0, velocity: 0, size: 375),
        -1,
      );
    });

    test('同向甩动（≥300px/s 且净位移 ≥40）也算切', () {
      expect(
        aylaResolveSwipeCommit(net: -60, cross: 0, velocity: -400, size: 375),
        1,
      );
      // 反向甩动不算（velocity 与 net 异号）。
      expect(
        aylaResolveSwipeCommit(net: -60, cross: 0, velocity: 400, size: 375),
        0,
      );
      // 高速微动不算（净位移 < 40）。
      expect(
        aylaResolveSwipeCommit(net: -20, cross: 0, velocity: -900, size: 375),
        0,
      );
    });

    test('交叉轴占优 → 让位（不切页）', () {
      expect(
        aylaResolveSwipeCommit(net: -100, cross: 120, velocity: -500, size: 375),
        0,
      );
    });
  });

  group('子群状态机（stores/subgroup.ts）', () {
    test('setSubgroups 落库：默认组在前、未读快照合并', () {
      final AylaSubGroupState state = AylaSubGroupState();
      state.bumpSubgroupUnread('g1', '2', 11);
      state.setSubgroups('g1', <AylaSubGroup>[
        _sg('1', isDefault: true, hasUnreadSeqs: true),
        _sg('2', hasUnreadSeqs: true),
      ]);
      expect(state.subgroupsOf('g1').length, 2);
      expect(state.unreadOf('g1', '2'), 1);
      expect(state.unreadSeqsOf('g1', '2'), <int>[11]);
    });

    test('markSubgroupReadSeqs 只按确认序号消除，返回实际移除数（幂等）', () {
      final AylaSubGroupState state = AylaSubGroupState();
      state.bumpSubgroupUnread('g1', '2', 11);
      state.bumpSubgroupUnread('g1', '2', 12);
      expect(state.markSubgroupReadSeqs('g1', '2', <int>[11]), 1);
      expect(state.unreadOf('g1', '2'), 1);
      expect(state.unreadSeqsOf('g1', '2'), <int>[12]);
      // 重复确认幂等（第二次没有可移除的）。
      expect(state.markSubgroupReadSeqs('g1', '2', <int>[11]), 0);
      expect(state.isSubgroupMessageConfirmedRead('g1', 11), isTrue);
    });

    test('recordMessageActivity 单调：旧序号不回退', () {
      final AylaSubGroupState state = AylaSubGroupState();
      state.setSubgroups('g1', <AylaSubGroup>[_sg('2', lastSeq: 5)]);
      state.recordMessageActivity('g1', '2', 9);
      state.recordMessageActivity('g1', '2', 3);
      expect(state.subgroupsOf('g1').first.lastMessageSeq, 9);
    });

    test('removeSubgroup 清四张投影 + 当前选中回落默认组', () {
      final AylaSubGroupState state = AylaSubGroupState();
      state.setSubgroups('g1', <AylaSubGroup>[
        _sg('1', isDefault: true),
        _sg('2'),
      ]);
      state.setActiveSubgroup('g1', '2');
      state.bumpSubgroupUnread('g1', '2', 7);
      state.removeSubgroup('g1', '2');
      expect(state.subgroupsOf('g1').length, 1);
      expect(state.unreadOf('g1', '2'), 0);
      expect(state.isSubgroupMessageConfirmedRead('g1', 7), isFalse);
      state.setActiveSubgroup('g1', null);
      expect(state.activeSubgroupOf('g1'), isNull);
    });

    test('sortSubgroupsByActivity：默认组固定第一，其余按最近消息降序', () {
      final List<AylaSubGroup> sorted = aylaSortSubgroupsByActivity(<AylaSubGroup>[
        _sg('2', lastSeq: 3),
        _sg('3', lastSeq: 9),
        _sg('1', isDefault: true, lastSeq: 1),
      ]);
      expect(sorted.map((AylaSubGroup s) => s.id).toList(), <String>['1', '3', '2']);
    });
  });

  group('群已读回执（stores/subgroupRead.ts）', () {
    test('按序号消除 + 会话未读同步 + 消息已读态', () {
      final AylaSubGroupState subgroup = AylaSubGroupState();
      final AylaChatState chat = AylaChatState();
      final AylaMessageState message = AylaMessageState();
      chat.setConversations(<AylaConversationSummary>[
        AylaConversationSummary(
          id: 'g1',
          type: AylaConversationType.group,
          title: '群',
          unreadSeqs: <int>[11, 12],
        ),
      ]);
      message.openBucket('g1');
      message.upsertMessage('g1', _msg(id: 'm11', seq: 11, subgroupId: '2'));
      subgroup.bumpSubgroupUnread('g1', '2', 11);
      subgroup.bumpSubgroupUnread('g1', '2', 12);
      aylaApplySubgroupReadReceipt(
        subgroupState: subgroup,
        chatState: chat,
        messageState: message,
        convId: 'g1',
        subgroupId: '2',
        markedSeqs: <int>[11],
      );
      expect(subgroup.unreadSeqsOf('g1', '2'), <int>[12]);
      expect(chat.byId('g1')!.unreadSeqs, <int>[12]);
      expect(message.messagesOf('g1').first.readByMe, isTrue);
    });

    test('空序号数组是 no-op（不整组清零）', () {
      final AylaSubGroupState subgroup = AylaSubGroupState();
      final AylaChatState chat = AylaChatState();
      final AylaMessageState message = AylaMessageState();
      subgroup.bumpSubgroupUnread('g1', '2', 11);
      aylaApplySubgroupReadReceipt(
        subgroupState: subgroup,
        chatState: chat,
        messageState: message,
        convId: 'g1',
        subgroupId: '2',
        markedSeqs: const <int>[],
      );
      expect(subgroup.unreadOf('g1', '2'), 1);
    });
  });

  group('子群视图过滤（useChat.ts:69–78）', () {
    test('默认组视图含 subgroup_id 为 null 的旧消息', () {
      expect(
        aylaMessageInSubgroup(_msg(id: 'a', seq: 1), '1', isDefault: true),
        isTrue,
      );
      expect(
        aylaMessageInSubgroup(_msg(id: 'b', seq: 2, subgroupId: '1'), '1', isDefault: true),
        isTrue,
      );
      expect(
        aylaMessageInSubgroup(_msg(id: 'c', seq: 3, subgroupId: '2'), '1', isDefault: true),
        isFalse,
      );
    });

    test('非默认子群只含自己（null 旧消息不进）', () {
      expect(
        aylaMessageInSubgroup(_msg(id: 'a', seq: 1), '2'),
        isFalse,
      );
      expect(
        aylaMessageInSubgroup(_msg(id: 'b', seq: 2, subgroupId: '2'), '2'),
        isTrue,
      );
    });

    test('subgroupId 为 null ⇒ 全量视图', () {
      expect(aylaMessageInSubgroup(_msg(id: 'a', seq: 1), null), isTrue);
    });
  });

  group('群导航状态（stores/group.ts）', () {
    test('setActiveScene / setCurrentGroup / reset', () {
      final AylaGroupState state = AylaGroupState();
      state.setActiveScene(AylaGroupScene.games);
      state.setCurrentGroup('g1');
      expect(state.activeScene, AylaGroupScene.games);
      expect(state.currentGroupId, 'g1');
      state.reset();
      expect(state.activeScene, AylaGroupScene.chat);
      expect(state.currentGroupId, isNull);
    });

    test('parseScene 未知返回 null（不 fallback）', () {
      expect(AylaGroupState.parseScene('info'), AylaGroupScene.info);
      expect(AylaGroupState.parseScene('nope'), isNull);
      expect(AylaGroupState.parseScene(null), isNull);
    });

    test('场景顺序常量 = web GROUP_SCENE_ORDER', () {
      expect(kAylaGroupSceneOrder.map((AylaGroupScene s) => s.name).toList(),
          <String>['voice', 'live', 'chat', 'posts', 'games']);
    });
  });

  group('群活跃度（groupActivity.ts:93–226）', () {
    test('窗口内消息生成事件；窗口外不算', () {
      final int now = DateTime.now().millisecondsSinceEpoch;
      final AylaLastMessagePreview recent = AylaLastMessagePreview(
        seq: 3,
        type: AylaMessageType.text,
        content: 'hi',
        senderName: '小樱',
        createdAt: DateTime.fromMillisecondsSinceEpoch(now - 60000)
            .toUtc()
            .toIso8601String(),
      );
      final AylaGroupActivity activity = aylaGroupActivityOf(
        groupId: 'g1',
        lastMessage: recent,
        liveChannels: const [],
        voiceChannels: const [],
        groupActivityAt: const <String, int>{},
        nowMs: now,
      );
      expect(activity.hasActivity, isTrue);
      expect(activity.lastEvent!.kind, 'message');
      expect(activity.lastEvent!.text, '小樱：hi');

      final AylaLastMessagePreview stale = AylaLastMessagePreview(
        seq: 3,
        type: AylaMessageType.text,
        content: 'hi',
        senderName: '小樱',
        createdAt: DateTime.fromMillisecondsSinceEpoch(
                now - kAylaNewContentWindowMs - 1000)
            .toUtc()
            .toIso8601String(),
      );
      expect(
        aylaGroupActivityOf(
          groupId: 'g1',
          lastMessage: stale,
          liveChannels: const [],
          voiceChannels: const [],
          groupActivityAt: const <String, int>{},
          nowMs: now,
        ).hasActivity,
        isFalse,
      );
    });

    test('无事件但有单调 bump ⇒ 只保留时间戳（描述暂缺）', () {
      final AylaGroupActivity activity = aylaGroupActivityOf(
        groupId: 'g1',
        lastMessage: null,
        liveChannels: const [],
        voiceChannels: const [],
        groupActivityAt: const <String, int>{'g1': 123},
      );
      expect(activity.lastNewAt, 123);
      expect(activity.lastEvent, isNull);
    });

    test('poke 预览不加发送者前缀（groupActivity.ts:106–109）', () {
      final int now = DateTime.now().millisecondsSinceEpoch;
      final AylaLastMessagePreview poke = AylaLastMessagePreview(
        seq: 4,
        type: AylaMessageType.poke,
        content: 'u2',
        senderName: '小樱',
        preview: '小樱戳了戳你',
        createdAt: DateTime.fromMillisecondsSinceEpoch(now - 1000)
            .toUtc()
            .toIso8601String(),
      );
      final AylaGroupActivity activity = aylaGroupActivityOf(
        groupId: 'g1',
        lastMessage: poke,
        liveChannels: const [],
        voiceChannels: const [],
        groupActivityAt: const <String, int>{},
        nowMs: now,
      );
      expect(activity.lastEvent!.text, '小樱戳了戳你');
    });

    test('排序：置顶优先 → 新内容时间降序 → 原顺序稳定', () {
      List<AylaConversationSummary> groups = <AylaConversationSummary>[
        AylaConversationSummary(id: 'a', type: AylaConversationType.group, title: 'A'),
        AylaConversationSummary(
          id: 'b',
          type: AylaConversationType.group,
          title: 'B',
          isPinned: true,
        ),
        AylaConversationSummary(id: 'c', type: AylaConversationType.group, title: 'C'),
      ];
      final List<AylaConversationSummary> sorted = aylaSortGroupsByActivity(
        groups,
        (AylaConversationSummary c) => AylaGroupActivity(
          lastNewAt: c.id == 'c' ? 100 : 0,
        ),
      );
      expect(
        sorted.map((AylaConversationSummary c) => c.id).toList(),
        <String>['b', 'c', 'a'],
      );
    });
  });

  group('存在性角标（groupActivity.ts:116–152）', () {
    test('优先用会话聚合字段', () {
      final AylaAvatarStatus status = aylaGroupPresenceOf(
        groupId: 'g1',
        aggregate: AylaGroupPresence(live: true, voice: false, game: true),
        liveChannels: const [],
        voiceChannels: const [],
      );
      expect(status.live, isTrue);
      expect(status.voice, isFalse);
      expect(status.game, isTrue);
    });

    test('无聚合时：桌游源未接 ⇒ 保持 false（不伪造）', () {
      final AylaAvatarStatus status = aylaGroupPresenceOf(
        groupId: 'g1',
        aggregate: null,
        liveChannels: const [],
        voiceChannels: const [],
      );
      expect(status.live, isFalse);
      expect(status.voice, isFalse);
      expect(status.game, isFalse);
    });
  });
}
