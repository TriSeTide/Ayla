/// chat 通道客户端定向测试 —— 对照 `Ayla/web/src/ws/chat.ts`（41 个接收 case）。
///
/// 口径：本批实装 18 条（消息域 + 认证通知 + 会话新增），其余 23 条显式登记在
/// [kAylaChatWsOutOfBatchFrames]；本文件对两类都做断言（已实装行为 + 域外帧 no-op）。
///
/// 帧注入走 `debugHandleFrame`、发送出口走 `debugSend`（均 `@visibleForTesting`）：
/// 被测对象是**真实的分发/补发逻辑**，只绕开 socket 传输层（`WsChannel` 属 M0 已交付件）。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/chat_message.dart';
import '../lib/core/models/conversation.dart';
import '../lib/core/ws/chat_ws.dart';
import '../lib/core/ws/room_frames.dart' show kAylaRoomFramesTurnedOn;
import '../lib/state/badges_state.dart';
import '../lib/state/chat_state.dart';
import '../lib/state/message_state.dart';
import '../lib/state/notices_state.dart';
import '../lib/state/realtime_state.dart';

/// 测试脚手架：一套内存状态 + 关闭自动对账（避免真网络请求）。
class _Harness {
  _Harness({this.me = 'u-me'}) {
    client = AylaChatWsClient(
      chatState: chat,
      messageState: message,
      notices: notices,
      badges: badges,
      realtime: realtime,
      currentUserId: () => me,
      autoReconcile: false,
    );
    client.debugSend = sent.add;
  }

  final String? me;
  final AylaChatState chat = AylaChatState();
  final AylaMessageState message = AylaMessageState();
  final AylaNoticesController notices = AylaNoticesController();
  final AylaBadgesController badges = AylaBadgesController();
  final AylaRealtimeState realtime = AylaRealtimeState();
  late final AylaChatWsClient client;
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  void seedPrivate(String id) {
    chat.setConversations(<AylaConversationSummary>[
      AylaConversationSummary(
        id: id,
        type: AylaConversationType.private,
        title: '',
      ),
    ]);
  }

  AylaChatMessage textMsg({
    required String id,
    required String senderId,
    required int seq,
    String content = 'x',
  }) =>
      AylaChatMessage(
        id: id,
        conversationId: 'c1',
        senderId: senderId,
        type: AylaMessageType.text,
        content: content,
        status: AylaMessageStatus.sent,
        seq: seq,
        createdAt: '2026-09-28T12:00:00Z',
      );
}

void main() {
  group('帧分发：消息域 18 条', () {
    test('message.new（他人私聊，在底部且活跃）→ 进流 + 即时已读 + 预览', () {
      final _Harness h = _Harness();
      h.seedPrivate('c1');
      h.chat.openConversation('c1');
      h.message.openBucket('c1');
      h.message.setViewerAtBottom('c1', true);

      h.client.debugHandleFrame(<String, dynamic>{
        'type': 'message.new',
        'data': <String, dynamic>{
          'conversation_id': 'c1',
          'message_id': 'm1',
          'sender_id': 'u-peer',
          'content': '在吗',
          'type': 'text',
          'media': null,
          'reply_to': null,
          'seq': 7,
          'ts': '2026-09-28T12:00:00Z',
        },
      });

      expect(h.message.messagesOf('c1').length, 1);
      expect(h.message.messagesOf('c1').first.readByMe, isTrue,
          reason: '在底部且活跃 ⇒ 即时已读（web chat.ts:461–468）');
      expect(h.chat.byId('c1')!.unreadSeqs, isEmpty, reason: '已读 ⇒ 不进未读');
      expect(h.chat.byId('c1')!.lastMessage!.content, '在吗');
    });

    test('message.new（他人私聊，非活跃会话）→ 未读 +1 且带 seq', () {
      final _Harness h = _Harness();
      h.seedPrivate('c1');
      h.message.openBucket('c1');
      h.client.debugHandleFrame(<String, dynamic>{
        'type': 'message.new',
        'data': <String, dynamic>{
          'conversation_id': 'c1',
          'message_id': 'm1',
          'sender_id': 'u-peer',
          'content': 'hi',
          'type': 'text',
          'seq': 3,
          'ts': '2026-09-28T12:00:00Z',
        },
      });
      expect(h.chat.byId('c1')!.unreadCount, 1);
      expect(h.chat.byId('c1')!.unreadSeqs, <int>[3]);
    });

    test('message.new（自己带幂等键）→ 收敛本地 pending，无双气泡', () {
      final _Harness h = _Harness();
      h.seedPrivate('c1');
      h.message.openBucket('c1');
      h.message.addPendingMessage(
        'c1',
        AylaChatMessage(
          id: 'local-k1',
          conversationId: 'c1',
          senderId: 'u-me',
          type: AylaMessageType.text,
          content: 'hello',
          status: AylaMessageStatus.sent,
          seq: 0,
          createdAt: '2026-09-28T12:00:00Z',
          pending: true,
          idempotencyKey: 'k1',
        ),
      );
      h.client.debugHandleFrame(<String, dynamic>{
        'type': 'message.new',
        'data': <String, dynamic>{
          'conversation_id': 'c1',
          'message_id': 'm9',
          'sender_id': 'u-me',
          'content': 'hello',
          'type': 'text',
          'idempotency_key': 'k1',
          'seq': 9,
          'ts': '2026-09-28T12:00:01Z',
        },
      });
      final List<AylaChatMessage> msgs = h.message.messagesOf('c1');
      expect(msgs.length, 1, reason: 'pending 被服务端消息原地替换');
      expect(msgs.first.id, 'm9');
      expect(msgs.first.pending, isFalse);
      expect(h.chat.byId('c1')!.unreadCount, 0, reason: '自己发的消息不计未读');
    });

    test('message.read → 对端已读回执；message.recall → 状态置 recalled', () {
      final _Harness h = _Harness();
      h.message.openBucket('c1');
      h.message.upsertMessage('c1', h.textMsg(id: 'm1', senderId: 'u-peer', seq: 1));
      h.client.debugHandleFrame(<String, dynamic>{
        'type': 'message.read',
        'data': <String, dynamic>{
          'conversation_id': 'c1',
          'message_id': 'm1',
          'user_id': 'u-peer',
          'seq': 1,
        },
      });
      expect(h.message.readBy('c1', 'm1'), <String>['u-peer']);

      h.client.debugHandleFrame(<String, dynamic>{
        'type': 'message.recall',
        'data': <String, dynamic>{
          'conversation_id': 'c1',
          'message_id': 'm1',
          'seq': 1,
        },
      });
      expect(h.message.messagesOf('c1').first.status, AylaMessageStatus.recalled);
    });

    test('message.poke → 预览「A戳了戳B」+ 私信活跃 bump，不进未读', () {
      final _Harness h = _Harness();
      h.seedPrivate('c1');
      h.message.openBucket('c1');
      h.client.debugHandleFrame(<String, dynamic>{
        'type': 'message.poke',
        'data': <String, dynamic>{
          'conversation_id': 'c1',
          'message_id': 'p1',
          'sender_id': 'u-peer',
          'sender_name': '小樱',
          'target_user_id': 'u-me',
          'target_name': '我',
          'seq': 5,
          'ts': '2026-09-28T12:00:00Z',
        },
      });
      expect(h.chat.byId('c1')!.lastMessage!.preview, '小樱戳了戳我');
      expect(h.chat.conversationActivityAt['c1'], isNotNull);
      expect(h.chat.byId('c1')!.unreadCount, 0, reason: '戳一戳不进未读/红点');
      expect(h.message.messagesOf('c1').first.type, AylaMessageType.poke);
    });

    test('history.sync / chat.subscribed → 只推进 lastSeq，不新增消息', () {
      final _Harness h = _Harness();
      h.message.openBucket('c1');
      h.client.debugHandleFrame(<String, dynamic>{
        'type': 'history.sync',
        'data': <String, dynamic>{'conversation_id': 'c1', 'last_seq': 42},
      });
      expect(h.message.bucketOf('c1')!.lastSeq, 42);
      h.client.debugHandleFrame(<String, dynamic>{
        'type': 'chat.subscribed',
        'data': <String, dynamic>{'conversation_id': 'c1', 'last_seq': 50},
      });
      expect(h.client.subscriptionHeads['c1'], 50);
      expect(h.message.messagesOf('c1'), isEmpty);
    });

    test('typing → 交给 onFrame 处理器（分发层不改状态）', () {
      final _Harness h = _Harness();
      final List<String> types = <String>[];
      h.client.onFrame((Map<String, dynamic> frame) {
        types.add('${frame['type']}');
      });
      h.client.debugHandleFrame(<String, dynamic>{
        'type': 'typing',
        'data': <String, dynamic>{
          'conversation_id': 'c1',
          'user_id': 'u-peer',
          'is_typing': true,
        },
      });
      expect(types, <String>['typing']);
    });

    test('认证通知四类 → notices.push 文案逐字（含实时退群通知）', () {
      final _Harness h = _Harness();
      h.client.debugHandleFrame(<String, dynamic>{
        'type': 'friend.request.new',
        'data': <String, dynamic>{'from_user_name': '小樱'},
      });
      h.client.debugHandleFrame(<String, dynamic>{
        'type': 'group.invite.new',
        'data': <String, dynamic>{
          'inviter_name': '阿澈',
          'conversation_title': '读书会',
        },
      });
      h.client.debugHandleFrame(<String, dynamic>{
        'type': 'group.request.new',
        'data': <String, dynamic>{
          'applicant_name': '林深',
          'conversation_title': '读书会',
        },
      });
      h.client.debugHandleFrame(<String, dynamic>{
        'type': 'group.member.left',
        'data': <String, dynamic>{
          'conversation_title': '读书会',
          'member_name': '小铃',
        },
      });
      final List<String> details = <String>[
        for (final AylaRealtimeNotice n in h.notices.notices) n.detail,
      ];
      expect(details, <String>[
        '小樱 想加你为好友',
        '阿澈 邀请你加入 读书会',
        '林深 申请加入 读书会',
        '读书会：小铃 已离开',
      ]);
      expect(h.notices.ofKind(AylaRealtimeNoticeKind.groupMemberLeft).length, 1);
    });

    test('group.created → 订阅该会话并发 subscribe 帧', () {
      final _Harness h = _Harness();
      h.client.debugHandleFrame(<String, dynamic>{
        'type': 'group.created',
        'conversation': <String, dynamic>{'id': 'c9', 'type': 'group'},
      });
      expect(h.client.subscribed.contains('c9'), isTrue);
      expect(h.sent.first['type'], 'subscribe');
    });

    test('域外帧（11 条）→ chat 客户端不抛错、不改状态、仍广播给 onFrame', () {
      // 2026-09-28（房内页批次）订正：原 23 条里 **12 条已转正**（voice.channel.* 4 +
      // live.channel.* 4 + live.viewers.changed 1 + boardgame.room.* 3），由
      // `core/ws/room_frames.dart` 的 `AylaRoomDirectoryBridge` 挂 onFrame 承接 ⇒
      // 本文件只对**仍域外**的 11 条断言（chat 客户端对它们仍是 no-op + 透传）。
      final _Harness h = _Harness();
      final List<String> seen = <String>[];
      h.client.onFrame((Map<String, dynamic> f) => seen.add('${f['type']}'));
      expect(kAylaChatWsOutOfBatchFrames.length, 11);
      for (final String type in kAylaChatWsOutOfBatchFrames) {
        h.client.debugHandleFrame(<String, dynamic>{
          'type': type,
          'data': <String, dynamic>{},
        });
      }
      expect(seen.length, 11);
      expect(h.message.buckets, isEmpty);
      expect(h.notices.notices, isEmpty);
    });

    test('转正 12 条：chat 客户端不改状态，但**照样广播给 onFrame**（桥的入口）', () {
      final _Harness h = _Harness();
      final List<String> seen = <String>[];
      h.client.onFrame((Map<String, dynamic> f) => seen.add('${f['type']}'));
      for (final String type in kAylaRoomFramesTurnedOn) {
        h.client.debugHandleFrame(<String, dynamic>{
          'type': type,
          'data': <String, dynamic>{'channel_id': 'v1'},
        });
      }
      expect(kAylaRoomFramesTurnedOn.length, 12);
      expect(seen.length, 12, reason: '桥靠 onFrame 接帧 ⇒ 必须仍然透传');
      expect(h.message.buckets, isEmpty);
      expect(h.notices.notices, isEmpty);
    });

    test('缺 type 的帧静默忽略', () {
      final _Harness h = _Harness();
      h.client.debugHandleFrame(<String, dynamic>{'data': <String, dynamic>{}});
      expect(h.message.buckets, isEmpty);
    });
  });

  group('发送帧：subscribe / resume', () {
    test('subscribe 每 100 个一组', () {
      final _Harness h = _Harness();
      h.client.subscribe(<String>[
        for (int i = 0; i < 150; i++) 'c$i',
      ]);
      expect(h.sent.length, 2);
      expect(h.sent[0]['type'], 'subscribe');
      expect((h.sent[0]['conversation_ids']! as List<dynamic>).length, 100);
      expect((h.sent[1]['conversation_ids']! as List<dynamic>).length, 50);
    });

    test('resume 无基线时降级为 subscribe（不制造「补发全部历史」）', () {
      final _Harness h = _Harness();
      h.client.resume('c1');
      expect(h.sent.single['type'], 'subscribe');
      expect(h.sent.single['conversation_ids'], <String>['c1']);
    });

    test('resume 有基线时带 last_message_seq（head 与 bucket 取较大值）', () {
      final _Harness h = _Harness();
      h.message.openBucket('c1');
      h.message.setLastSeq('c1', 12);
      h.client.debugHandleFrame(<String, dynamic>{
        'type': 'chat.subscribed',
        'data': <String, dynamic>{'conversation_id': 'c1', 'last_seq': 20},
      });
      h.sent.clear();
      h.client.resume('c1');
      expect(h.sent.single['type'], 'resume');
      expect(h.sent.single['last_message_seq'], 20);
    });
  });

  group('摘要拼装', () {
    test('混排段摘要按 web segmentPreview 拼（文本 + [图片] + @名）', () {
      final String? preview = aylaSegmentPreviewOf(<AylaMediaSegment>[
        const AylaMediaSegment(type: AylaSegmentType.text, text: '看这个'),
        const AylaMediaSegment(type: AylaSegmentType.image, mediaId: 'x'),
        const AylaMediaSegment(
          type: AylaSegmentType.mention,
          userId: 'u1',
          userNickname: '小樱',
        ),
      ]);
      expect(preview, '看这个[图片]@小樱');
    });

    test('空段 → null（不回退成空串预览）', () {
      expect(aylaSegmentPreviewOf(const <AylaMediaSegment>[]), isNull);
    });
  });
}
