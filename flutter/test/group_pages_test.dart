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
import '../lib/core/models/game_room.dart';
import '../lib/core/models/post.dart';
import '../lib/core/models/subgroup.dart';
import '../lib/core/models/chat_message.dart' show AylaLastMessagePreview;
import '../lib/core/ws/chat_ws.dart' show AylaChatWsClient;
import '../lib/state/chat_providers.dart'
    show aylaStartSocialTracking, chatStateProvider, chatWsProvider;
import '../lib/state/social_store.dart' show AylaSocialKind, AylaSocialOptions, aylaSocialStore;
import '../lib/widgets/shell/server_rail.dart'
    show AylaServerRail, AylaServerRailGroup;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../lib/core/models/user_public.dart' show AylaUserPublic;
import '../lib/pages/group_chat_page.dart' show aylaMessageInSubgroup;
import '../lib/core/api/directory_page.dart' show AylaDirectoryPage;
import '../lib/pages/group_page.dart'
    show
        GroupPage,
        aylaGroupPageSubgroupsLoader,
        aylaGroupSceneDirection,
        aylaGroupSceneOrderIndex,
        aylaResolveSwipeCommit;
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
        gameRooms: const <AylaGameRoom>[],
        posts: const <AylaPost>[],
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
          gameRooms: const <AylaGameRoom>[],
          posts: const <AylaPost>[],
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
        gameRooms: const <AylaGameRoom>[],
        posts: const <AylaPost>[],
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
        gameRooms: const <AylaGameRoom>[],
        posts: const <AylaPost>[],
        groupActivityAt: const <String, int>{},
        nowMs: now,
      );
      expect(activity.lastEvent!.text, '小樱戳了戳你');
    });

    test('新桌游房 ⇒ game 事件；窗口外不算（web groupActivity.ts:196–205）', () {
      final int now = DateTime.now().millisecondsSinceEpoch;
      String iso(int ms) =>
          DateTime.fromMillisecondsSinceEpoch(ms).toUtc().toIso8601String();

      final AylaGameRoom fresh = _room(
        id: 7,
        name: '狼人杀',
        allowedGroupIds: const <String>['g1'],
        createdAt: iso(now - 60000),
        ownerNickname: '阿蓝',
      );
      final AylaGroupActivity hit = aylaGroupActivityOf(
        groupId: 'g1',
        lastMessage: null,
        liveChannels: const [],
        voiceChannels: const [],
        gameRooms: <AylaGameRoom>[fresh],
        posts: const <AylaPost>[],
        groupActivityAt: const <String, int>{},
        nowMs: now,
      );
      expect(hit.lastEvent!.kind, 'game');
      // 文案逐字来自 web 202：`${owner} 创建了桌游房 ${r.name}`，
      // owner 显示名 = displayName(nickname, username)（web 79–81）。
      expect(hit.lastEvent!.text, '阿蓝 创建了桌游房 狼人杀');

      // 窗口外（> 24h）：不算（isRecent，web 65–68）。
      final AylaGroupActivity miss = aylaGroupActivityOf(
        groupId: 'g1',
        lastMessage: null,
        liveChannels: const [],
        voiceChannels: const [],
        gameRooms: <AylaGameRoom>[
          _room(
            id: 8,
            name: '狼人杀',
            allowedGroupIds: const <String>['g1'],
            createdAt: iso(now - kAylaNewContentWindowMs - 1000),
          ),
        ],
        posts: const <AylaPost>[],
        groupActivityAt: const <String, int>{},
        nowMs: now,
      );
      expect(miss.hasActivity, isFalse);

      // 白名单不含本群：不算（visibleInGroup，web 70–76）。
      final AylaGroupActivity other = aylaGroupActivityOf(
        groupId: 'g1',
        lastMessage: null,
        liveChannels: const [],
        voiceChannels: const [],
        gameRooms: <AylaGameRoom>[
          _room(
            id: 9,
            name: '狼人杀',
            allowedGroupIds: const <String>['g2'],
            createdAt: iso(now - 1000),
          ),
        ],
        posts: const <AylaPost>[],
        groupActivityAt: const <String, int>{},
        nowMs: now,
      );
      expect(other.hasActivity, isFalse);
    });

    test('新帖子 ⇒ post 事件；窗口外不算（web groupActivity.ts:206–215）', () {
      final int now = DateTime.now().millisecondsSinceEpoch;
      String iso(int ms) =>
          DateTime.fromMillisecondsSinceEpoch(ms).toUtc().toIso8601String();

      final AylaPost fresh = _post(
        id: 3,
        title: '今晚吃啥',
        allowedGroupIds: const <String>['g1'],
        createdAt: iso(now - 120000),
        authorNickname: '小樱',
      );
      final AylaGroupActivity hit = aylaGroupActivityOf(
        groupId: 'g1',
        lastMessage: null,
        liveChannels: const [],
        voiceChannels: const [],
        gameRooms: const <AylaGameRoom>[],
        posts: <AylaPost>[fresh],
        groupActivityAt: const <String, int>{},
        nowMs: now,
      );
      expect(hit.lastEvent!.kind, 'post');
      // 文案逐字来自 web 212：`${author} 发了新帖 ${p.title}`。
      expect(hit.lastEvent!.text, '小樱 发了新帖 今晚吃啥');

      final AylaGroupActivity miss = aylaGroupActivityOf(
        groupId: 'g1',
        lastMessage: null,
        liveChannels: const [],
        voiceChannels: const [],
        gameRooms: const <AylaGameRoom>[],
        posts: <AylaPost>[
          _post(
            id: 4,
            title: '昨晚吃啥',
            allowedGroupIds: const <String>['g1'],
            createdAt: iso(now - kAylaNewContentWindowMs - 1000),
          ),
        ],
        groupActivityAt: const <String, int>{},
        nowMs: now,
      );
      expect(miss.hasActivity, isFalse);
    });

    test('五源取 at 最大者（web 178–183 的 `!best || at > best.at`）', () {
      final int now = DateTime.now().millisecondsSinceEpoch;
      String iso(int ms) =>
          DateTime.fromMillisecondsSinceEpoch(ms).toUtc().toIso8601String();

      // 消息 at = now-10s；帖子 at = now-1s ⇒ 帖子最新，应胜出。
      final AylaLastMessagePreview message = AylaLastMessagePreview(
        seq: 5,
        type: AylaMessageType.text,
        content: 'hi',
        senderName: '小樱',
        createdAt: iso(now - 10000),
      );
      final AylaGroupActivity activity = aylaGroupActivityOf(
        groupId: 'g1',
        lastMessage: message,
        liveChannels: const [],
        voiceChannels: const [],
        gameRooms: const <AylaGameRoom>[],
        posts: <AylaPost>[
          _post(
            id: 5,
            title: '最新帖',
            allowedGroupIds: const <String>['g1'],
            createdAt: iso(now - 1000),
          ),
        ],
        groupActivityAt: const <String, int>{},
        nowMs: now,
      );
      expect(activity.lastEvent!.kind, 'post');
      expect(activity.lastNewAt, now - 1000);
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
        gameRooms: const <AylaGameRoom>[],
      );
      expect(status.live, isTrue);
      expect(status.voice, isFalse);
      expect(status.game, isTrue);
    });

    test('无聚合时：三源皆空 ⇒ 全 false（不伪造）', () {
      final AylaAvatarStatus status = aylaGroupPresenceOf(
        groupId: 'g1',
        aggregate: null,
        liveChannels: const [],
        voiceChannels: const [],
        gameRooms: const <AylaGameRoom>[],
      );
      expect(status.live, isFalse);
      expect(status.voice, isFalse);
      expect(status.game, isFalse);
    });

    test('无聚合时：桌游白名单含本群 ⇒ game=true（web groupActivity.ts:144–149）', () {
      // 判据只看 `allowed_group_ids`，**不看 status**（与 live 的 status=live 不同）。
      final AylaAvatarStatus status = aylaGroupPresenceOf(
        groupId: 'g1',
        aggregate: null,
        liveChannels: const [],
        voiceChannels: const [],
        gameRooms: <AylaGameRoom>[
          _room(id: 1, name: '房A', allowedGroupIds: const <String>['g1']),
        ],
      );
      expect(status.game, isTrue);

      final AylaAvatarStatus other = aylaGroupPresenceOf(
        groupId: 'g1',
        aggregate: null,
        liveChannels: const [],
        voiceChannels: const [],
        gameRooms: <AylaGameRoom>[
          _room(id: 2, name: '房B', allowedGroupIds: const <String>['g2']),
        ],
      );
      expect(other.game, isFalse, reason: '白名单不含本群 ⇒ 不伪造');
    });
  });

  // ==========================================================================
  // 端到端回归锁：真实 GroupPage 灌数据 → 子群落库（default 并入 + 排序 + 首个 active）
  // ==========================================================================
  //
  // ⚠️ 与前一条 @sortSubgroupsByActivity@ 纯函数用例的区别：那条只证明**排序函数对**，
  // 这条证明**页面真的把它接上了** —— 用户实报「宽屏第二列侧栏排序依然错误」与
  // 「子群接线接到主群」都属于「函数对但没接线」类问题，纯函数锁抓不到。
  //
  // 走真实装配：GroupPage.initState → _bindGroupLists → _createSubgroups
  // （loader 返回**带 default** 的响应，与后端 views.py:238-247 同形）
  // → _syncSubgroupsFor → subgroupStateProvider。
  group('端到端：真实 GroupPage 的子群落库（default 并入 + 排序，GroupPage.tsx:265-283）', () {
    // ⚠️ 必须包 Scaffold：群聊输入区是 Material 的 TextField，
    // 没有 Material 祖先会抛 「No Material widget found」（与本组断言无关的宿主问题）。
    Widget host(ProviderContainer container) => UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (BuildContext context) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    size: const Size(1440, 900),
                  ),
                  child: const GroupPage(groupId: 'g1'),
                ),
              ),
            ),
          ),
        );

    setUp(() {
      aylaGroupPageSubgroupsLoader = null;
      aylaSocialStore.reset();
      aylaSocialStore.userId = 'u1';
      // 群头像列（AylaGroupDirectory）读 social ⇒ 注入空页，避免真网络。
      aylaSocialStore.requestOverride =
          (kind, options, cursor) async => const AylaDirectoryPage<Object>();
    });

    tearDown(() {
      aylaGroupPageSubgroupsLoader = null;
      aylaSocialStore.requestOverride = null;
      aylaSocialStore.reset();
      aylaSocialStore.userId = null;
    });

    testWidgets(
        '响应里的 default 不在 results 内 ⇒ 仍被并入且排第一，并确立首个 active',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // 后端真实形状：rows 按 SUBGROUP_ORDER 分页，default 在响应外层另给。
      aylaGroupPageSubgroupsLoader = (String groupId, String? cursor) async =>
          AylaSubgroupPage(
            results: <AylaSubGroup>[
              _sg('b', lastSeq: 30),
              _sg('c', lastSeq: 10),
            ],
            total: 3,
            defaultSubgroup: _sg('a', isDefault: true, lastSeq: 0),
          );

      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(host(container));
      await tester.pump(const Duration(milliseconds: 200));

      final AylaSubGroupState state = container.read(subgroupStateProvider);
      expect(
        state.subgroupsOf('g1').map((AylaSubGroup s) => s.id).toList(),
        <String>['a', 'b', 'c'],
        reason: '★ default 必须并入且默认组第一（web social.ts:174-178 + subgroup.ts:19-23）',
      );
      expect(state.activeSubgroupOf('g1'), 'a',
          reason: '★ 首个 active = 服务端默认组（web GroupPage.tsx:267-269）—— '
              '它就是发送时 subgroup_id 的来源');

      await tester.pumpAndSettle();
    });

    testWidgets('默认组已在 results 内 ⇒ 不重复并入（按 id 去重）',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      aylaGroupPageSubgroupsLoader = (String groupId, String? cursor) async =>
          AylaSubgroupPage(
            results: <AylaSubGroup>[
              _sg('a', isDefault: true, lastSeq: 5),
              _sg('b', lastSeq: 30),
            ],
            total: 2,
            defaultSubgroup: _sg('a', isDefault: true, lastSeq: 5),
          );

      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(host(container));
      await tester.pump(const Duration(milliseconds: 200));

      final AylaSubGroupState state = container.read(subgroupStateProvider);
      expect(
        state.subgroupsOf('g1').map((AylaSubGroup s) => s.id).toList(),
        <String>['a', 'b'],
        reason: '不得出现重复的默认组条目',
      );
      await tester.pumpAndSettle();
    });
  });

  // ==========================================================================
  // ★ 决定性端到端锁：rail 顺序**真的变了**（Lead 实测口径）
  // ==========================================================================
  //
  // Lead 用真实后端 + 真实 app 实测：「我在后端把群 43 顶到第一，然后截图 —— rail 顺序
  // **一个字都没变**」⇒ 证明「即使后端数据是对的、即使帧在路上」，Flutter 侧也**没有
  // 任何路径**把变化传导到 rail。
  //
  // 因此本组**不走纯函数**，而是读**真实渲染出来的 AylaServerRail.groups**
  // （即用户眼睛看到的那个列表），按生产装配顺序灌数据：
  //   ① aylaSocialStore.load()（= appInit 预取，根因 A 的回流在这里落地）
  //   ② 真实 WS 帧 message.new 经 AylaChatWsClient.debugHandleFrame
  //   ③ 断言 rail 的 group 顺序发生了变化，且**集合与后端一致**（不混入私聊）
  group('端到端：rail（宽屏左侧群头像列）顺序随 WS 帧真的变化', () {
    const AylaSocialOptions groupOptions = AylaSocialOptions(type: 'group');

    AylaConversationSummary conv(
      String id, {
      AylaConversationType type = AylaConversationType.group,
      int? lastSeq,
    }) =>
        AylaConversationSummary(
          id: id,
          type: type,
          title: '群$id',
          isPinned: false,
          lastMessage: lastSeq == null
              ? null
              : AylaLastMessagePreview(
                  seq: lastSeq,
                  type: AylaMessageType.text,
                  content: 'x',
                  senderId: 'u2',
                  senderName: '别人',
                  status: 'sent',
                  createdAt: '2026-10-01T00:00:00Z',
                  preview: 'x',
                ),
        );

    List<String> railGroupIds(WidgetTester tester) => tester
        .widget<AylaServerRail>(find.byType(AylaServerRail))
        .groups
        .map((AylaServerRailGroup g) => g.id)
        .toList();

    Widget railHost(ProviderContainer container) => UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (BuildContext context) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    size: const Size(1440, 900),
                  ),
                  child: const GroupPage(groupId: 'g1'),
                ),
              ),
            ),
          ),
        );

    setUp(() {
      aylaGroupPageSubgroupsLoader = null;
      aylaSocialStore.reset();
      aylaSocialStore.userId = 'u1';
    });

    tearDown(() {
      aylaGroupPageSubgroupsLoader = null;
      aylaSocialStore.requestOverride = null;
      aylaSocialStore.reset();
      aylaSocialStore.userId = null;
    });

    testWidgets(
        'social.load 回流 → message.new → rail 顺序变化（不是只验 chatState）',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // ⚠️ **生产装配顺序**：容器先建、再 aylaStartSocialTracking
      // （= main.dart:121），**然后**才 load()。
      // 顺序反了就不算端到端 —— 回流的回调是**启动期注入**的；
      // 先 load 再装配等于「生产上不存在的路径」（本轮首次实测就踩到：
      // 先 load 时 chatState.byId('g1') 恒 null，正是因为回调还没接上）。
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      aylaStartSocialTracking(container);

      // ① 后端目录（只给群；私聊由 type=group 过滤，集合一致性见下一条）。
      aylaSocialStore.requestOverride = (kind, options, cursor) async =>
          AylaDirectoryPage<Object>(
            results: <Object>[conv('g1'), conv('g2')],
            total: 2,
          );
      await aylaSocialStore.load(AylaSocialKind.conversations, groupOptions);
      aylaGroupPageSubgroupsLoader = (String groupId, String? cursor) async =>
          AylaSubgroupPage(total: 0);

      await tester.pumpWidget(railHost(container));
      await tester.pump(const Duration(milliseconds: 200));

      // ★ 根因 A 的直接锁：load 之后 chatState 必须有这些群。
      expect(container.read(chatStateProvider).byId('g1'), isNotNull,
          reason: '★ web social.ts:172 的回流 —— 没有它后面所有门控都失效');

      // g2 先有活动 ⇒ rail 基线上 g2 排前。
      container.read(chatStateProvider).bumpGroupActivity('g2', 1000);
      await tester.pump(const Duration(milliseconds: 50));
      expect(railGroupIds(tester), <String>['g2', 'g1'],
          reason: '基线：g2 有活动 ⇒ 排在 g1 前');

      // ② 真实 WS 帧：在 g1 里来一条消息（message.new）。
      final AylaChatWsClient ws = container.read(chatWsProvider);
      ws.debugHandleFrame(<String, dynamic>{
        'type': 'message.new',
        'data': <String, dynamic>{
          'conversation_id': 'g1',
          'message_id': 'm1',
          'sender_id': 'u2',
          'content': '新消息',
          'type': 'text',
          'media': null,
          'reply_to': null,
          'seq': 900,
          'ts': '2026-10-01T00:00:01Z',
        },
      });
      await tester.pump(const Duration(milliseconds: 50));

      // ③ ★★ 用户验收口径：rail **顺序真的变了**。
      expect(railGroupIds(tester), <String>['g1', 'g2'],
          reason: '★★ 发消息后 g1 必须排到 rail 最前 —— '
              '这正是 Lead 实机截图里「一个字都没变」的那条链路');

      await tester.pumpAndSettle();
    });

    testWidgets('rail 集合 = 后端返回的群（不混入私聊）',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // ⚠️ 同前：生产装配顺序（容器 → tracking → load）。
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      aylaStartSocialTracking(container);

      // 后端 type=group 只返回群；这里故意在**同一 store 的另一条 record** 里
      // 放私聊（模拟「全部会话」那条 record），验证 rail 读的是群档、不是全部。
      aylaSocialStore.requestOverride = (kind, options, cursor) async {
        if (options.type == 'private') {
          return AylaDirectoryPage<Object>(
            results: <Object>[
              conv('p1', type: AylaConversationType.private),
              conv('p2', type: AylaConversationType.private),
            ],
            total: 2,
          );
        }
        return AylaDirectoryPage<Object>(
          results: <Object>[conv('g1'), conv('g2'), conv('g3')],
          total: 3,
        );
      };
      await aylaSocialStore.load(AylaSocialKind.conversations, groupOptions);
      await aylaSocialStore.load(AylaSocialKind.conversations,
          const AylaSocialOptions(type: 'private'));
      aylaGroupPageSubgroupsLoader = (String groupId, String? cursor) async =>
          AylaSubgroupPage(total: 0);

      await tester.pumpWidget(railHost(container));
      await tester.pump(const Duration(milliseconds: 200));

      final List<String> ids = railGroupIds(tester);
      expect(ids, hasLength(3),
          reason: '★ rail 只显示**群**（后端 type=group 返回 3 个）');
      expect(ids.toSet(), <String>{'g1', 'g2', 'g3'},
          reason: '★ 集合必须与后端一致 —— 不得混入私聊 p1/p2');
      expect(ids.contains('p1'), isFalse, reason: '私聊不得出现在群头像列');
      await tester.pumpAndSettle();
    });
  });
}

/// 桌游房构造（测试用；字段对齐 web `GameRoom`，`created_at` 参与窗口判定）。
AylaGameRoom _room({
  required int id,
  required String name,
  List<String> allowedGroupIds = const <String>[],
  String? createdAt,
  String ownerNickname = '房主',
  String? ownerUsername,
}) =>
    AylaGameRoom(
      id: id,
      name: name,
      owner: AylaUserPublic(
        id: 'u1',
        nickname: ownerNickname,
        username: ownerUsername,
      ),
      ownerId: 'u1',
      status: AylaGameRoomStatus.waiting,
      allowedGroupIds: allowedGroupIds,
      createdAt: createdAt,
    );

/// 帖子构造（测试用；`author` 的展示名判据 = displayName，web groupActivity.ts:79–81）。
AylaPost _post({
  required int id,
  required String title,
  List<String> allowedGroupIds = const <String>[],
  String? createdAt,
  String authorNickname = '作者',
  String? authorUsername,
}) =>
    AylaPost(
      id: id,
      author: AylaPostAuthor(
        id: 'u2',
        nickname: authorNickname,
        username: authorUsername,
      ),
      authorId: 'u2',
      title: title,
      allowedGroupIds: allowedGroupIds,
      createdAt: createdAt,
    );
