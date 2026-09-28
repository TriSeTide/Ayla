/// 会话状态语义测试 —— 对照 `Ayla/web/src/stores/chat.ts`。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/conversation.dart';
import '../lib/state/chat_state.dart';

AylaConversationSummary _conv(
  String id, {
  bool group = false,
  bool pinned = false,
  int unread = 0,
  List<int> unreadSeqs = const <int>[],
  List<int> mentionSeqs = const <int>[],
  bool? complete,
}) =>
    AylaConversationSummary(
      id: id,
      type: group ? AylaConversationType.group : AylaConversationType.private,
      title: id,
      unreadCount: unread,
      unreadSeqs: unreadSeqs,
      mentionUnreadSeqs: mentionSeqs,
      unreadSeqsComplete: complete,
      isPinned: pinned,
    );

void main() {
  test('bumpUnread：同 seq 只记一次，mention / reply 各自入列', () {
    final AylaChatState chat = AylaChatState();
    chat.setConversations(<AylaConversationSummary>[_conv('c1')]);
    chat.bumpUnread('c1', seq: 5, mention: true, reply: true);
    chat.bumpUnread('c1', seq: 5, mention: true);
    chat.bumpUnread('c1', seq: 6);
    final AylaConversationSummary c = chat.byId('c1')!;
    expect(c.unreadSeqs, <int>[5, 6]);
    expect(c.unreadCount, 2);
    expect(c.mentionUnreadSeqs, <int>[5]);
    expect(c.replyUnreadSeqs, <int>[5]);
  });

  test('bumpUnread：unread_seqs_complete=false 且 seq 不晚于已见 latest ⇒ 不累加', () {
    final AylaChatState chat = AylaChatState();
    chat.setConversations(<AylaConversationSummary>[
      _conv('c1', unread: 4, unreadSeqs: const <int>[2], complete: false),
    ]);
    chat.bumpUnread('c1', seq: 2);
    expect(chat.byId('c1')!.unreadCount, 4, reason: '摘要只含计数 ⇒ 不凭它推断未读');
  });

  test('markReadSeqs：完整档按序号数组长度；不完整档按命中条数递减（下限 0）', () {
    final AylaChatState chat = AylaChatState();
    chat.setConversations(<AylaConversationSummary>[
      _conv('c1', unread: 2, unreadSeqs: const <int>[3, 4]),
      _conv('c2', unread: 5, unreadSeqs: const <int>[9], complete: false),
    ]);
    chat.markReadSeqs('c1', <int>[3]);
    expect(chat.byId('c1')!.unreadSeqs, <int>[4]);
    expect(chat.byId('c1')!.unreadCount, 1);
    chat.markReadSeqs('c2', <int>[9]);
    expect(chat.byId('c2')!.unreadCount, 4);
    expect(chat.byId('c2')!.unreadSeqs, isEmpty);
  });

  test('活跃 bump 单调：旧时间戳不回退', () {
    final AylaChatState chat = AylaChatState();
    chat.bumpGroupActivity('g1', 100);
    chat.bumpGroupActivity('g1', 50);
    expect(chat.groupActivityAt['g1'], 100);
    chat.bumpConversationActivity('c1', 200);
    chat.bumpConversationActivity('c1', 100);
    expect(chat.conversationActivityAt['c1'], 200);
  });

  test('upsertConversation：详情（peer 缺失）不覆盖已有对端；置顶排前', () {
    final AylaChatState chat = AylaChatState();
    chat.setConversations(<AylaConversationSummary>[
      _conv('c1', unread: 1),
      _conv('c2'),
    ]);
    chat.upsertConversation(
      AylaConversationSummary(
        id: 'c2',
        type: AylaConversationType.private,
        title: 'c2-新',
        isPinned: true,
      ),
    );
    expect(chat.conversations.first.id, 'c2', reason: '置顶优先');
    expect(chat.byId('c2')!.title, 'c2-新');
  });

  test('aylaSortPrivateByActivity：置顶 → 活跃时间 → 稳定原序', () {
    final List<AylaConversationSummary> list = <AylaConversationSummary>[
      _conv('a'),
      _conv('b'),
      _conv('c', pinned: true),
    ];
    final List<AylaConversationSummary> sorted =
        aylaSortPrivateByActivity<AylaConversationSummary>(
      list,
      <String, int>{'a': 10, 'b': 30},
      idOf: (AylaConversationSummary c) => c.id,
      pinnedOf: (AylaConversationSummary c) => c.isPinned ?? false,
    );
    expect(
      sorted.map((AylaConversationSummary c) => c.id).toList(),
      <String>['c', 'b', 'a'],
    );
  });

  test('removeConversation 清掉当前会话选中', () {
    final AylaChatState chat = AylaChatState();
    chat.setConversations(<AylaConversationSummary>[_conv('c1')]);
    chat.openConversation('c1');
    chat.removeConversation('c1');
    expect(chat.conversations, isEmpty);
    expect(chat.activeConversationId, isNull);
  });
}
