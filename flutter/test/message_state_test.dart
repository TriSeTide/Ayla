/// 消息桶语义测试 —— 对照 `Ayla/web/src/stores/message.ts`。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/chat_message.dart';
import '../lib/state/message_state.dart';

AylaChatMessage _msg(
  String id, {
  int seq = 1,
  bool pending = false,
  String? key,
  String sender = 'u1',
}) =>
    AylaChatMessage(
      id: id,
      conversationId: 'c1',
      senderId: sender,
      type: AylaMessageType.text,
      content: id,
      status: AylaMessageStatus.sent,
      seq: seq,
      createdAt: 't',
      pending: pending,
      idempotencyKey: key,
    );

void main() {
  test('upsertMessage：同 seq 去重、lastSeq 单调', () {
    final AylaMessageState m = AylaMessageState();
    m.openBucket('c1');
    m.upsertMessage('c1', _msg('a', seq: 1));
    m.upsertMessage('c1', _msg('a-dup', seq: 1, sender: 'u2'));
    m.upsertMessage('c1', _msg('b', seq: 2));
    expect(m.messagesOf('c1').length, 2);
    expect(m.bucketOf('c1')!.lastSeq, 2);
  });

  test('pending 恒置底；同幂等键的 pending 只留一条', () {
    final AylaMessageState m = AylaMessageState();
    m.openBucket('c1');
    m.upsertMessage('c1', _msg('a', seq: 5));
    m.addPendingMessage('c1', _msg('local-1', seq: 0, pending: true, key: 'k1'));
    m.addPendingMessage('c1', _msg('local-1b', seq: 0, pending: true, key: 'k1'));
    final List<AylaChatMessage> list = m.messagesOf('c1');
    expect(list.length, 2);
    expect(list.last.pending, isTrue, reason: 'pending 置底');
  });

  test('resolvePendingMessage：本地 pending 与服务端消息只留一条', () {
    final AylaMessageState m = AylaMessageState();
    m.openBucket('c1');
    m.addPendingMessage('c1', _msg('local-1', seq: 0, pending: true, key: 'k1'));
    m.resolvePendingMessage('c1', 'local-1', 'k1', _msg('srv-1', seq: 3));
    final List<AylaChatMessage> list = m.messagesOf('c1');
    expect(list.length, 1);
    expect(list.single.id, 'srv-1');
    expect(list.single.pending, isFalse);
  });

  test('resolvePendingByKey：WS 先到时用服务端消息替换 pending', () {
    final AylaMessageState m = AylaMessageState();
    m.openBucket('c1');
    m.addPendingMessage('c1', _msg('local-1', seq: 0, pending: true, key: 'k1'));
    m.resolvePendingByKey('c1', 'k1', _msg('srv-9', seq: 9));
    expect(m.messagesOf('c1').single.id, 'srv-9');
  });

  test('失败/进度/撤回/删除四类元事件', () {
    final AylaMessageState m = AylaMessageState();
    m.openBucket('c1');
    m.addPendingMessage('c1', _msg('local-1', seq: 0, pending: true, key: 'k1'));
    m.setMessageUploadProgress('c1', 'local-1', 42);
    expect(m.messagesOf('c1').single.uploadProgress, 42);
    m.setMessageUploadProgress('c1', 'local-1', null);
    expect(m.messagesOf('c1').single.uploadProgress, isNull,
        reason: 'null = 上传完成（web setMessageUploadProgress(..., null)）');
    m.markMessageFailed('c1', 'local-1');
    expect(m.messagesOf('c1').single.sendFailed, isTrue);
    m.upsertMessage('c1', _msg('srv-1', seq: 4));
    m.setRecalled('c1', 'srv-1');
    final AylaChatMessage recalled = m
        .messagesOf('c1')
        .firstWhere((AylaChatMessage x) => x.id == 'srv-1');
    expect(recalled.status, AylaMessageStatus.recalled);
    m.removeMessage('c1', 'srv-1');
    expect(m.messagesOf('c1').length, 1);
  });

  test('prependHistory：前插 + hasMore + lastSeq', () {
    final AylaMessageState m = AylaMessageState();
    m.openBucket('c1');
    m.prependHistory('c1', <AylaChatMessage>[_msg('b', seq: 8)], hasMore: true);
    m.prependHistory('c1', <AylaChatMessage>[_msg('a', seq: 7)], hasMore: false);
    final AylaMessageBucket bucket = m.bucketOf('c1')!;
    expect(
      bucket.messages.map((AylaChatMessage x) => x.id).toList(),
      <String>['a', 'b'],
    );
    expect(bucket.hasMore, isFalse);
    expect(bucket.lastSeq, 8);
  });

  // ======================= withConfirmedRead（web message.ts:85–88） =======================

  test('isConfirmedRead 投影：四处入库路径都逐条置 readByMe（web 96/135/176/324）', () {
    final AylaMessageState m = AylaMessageState();
    m.openBucket('c1');
    // 只把 seq 2 视为「服务端已确认已读」（模拟子群已读回执投影）。
    // 四条路径各用不同 seq（同 seq 会被 insertBySeq 去重，测不到入库）。
    m.isConfirmedRead = (String convId, int seq) =>
        convId == 'c1' && <int>{2, 3, 4, 5}.contains(seq);

    m.upsertMessage('c1', _msg('srv-2', seq: 2)); // web message.ts:96
    expect(m.messagesOf('c1').first.readByMe, isTrue,
        reason: 'upsertMessage 入库即投影');

    m.resolvePendingByKey('c1', 'k3', _msg('srv-3', seq: 3)); // web message.ts:176
    expect(
      m.messagesOf('c1').firstWhere((AylaChatMessage x) => x.id == 'srv-3').readByMe,
      isTrue,
      reason: 'resolvePendingByKey 入库即投影',
    );

    m.addPendingMessage('c1', _msg('local-1', seq: 0, pending: true, key: 'k1'));
    m.resolvePendingMessage('c1', 'local-1', 'k1', _msg('srv-4', seq: 4)); // web :135
    expect(
      m.messagesOf('c1').firstWhere((AylaChatMessage x) => x.id == 'srv-4').readByMe,
      isTrue,
      reason: 'resolvePendingMessage 入库即投影',
    );

    m.prependHistory('c1', <AylaChatMessage>[_msg('hist-5', seq: 5)], hasMore: false); // :324
    expect(
      m.messagesOf('c1').firstWhere((AylaChatMessage x) => x.id == 'hist-5').readByMe,
      isTrue,
      reason: 'prependHistory 前插即投影（用户实报的路径）',
    );
  });

  test('isConfirmedRead：未确认的不伪造已读；未接钩子时是空操作', () {
    final AylaMessageState m = AylaMessageState();
    m.openBucket('c1');
    m.isConfirmedRead = (String convId, int seq) => seq == 5;
    // seq 3 未确认 ⇒ 保持 null（**不伪造已读**）
    m.upsertMessage('c1', _msg('x', seq: 3));
    expect(m.messagesOf('c1').single.readByMe, isNull);
    // seq 5 已确认 ⇒ 前插即置已读
    m.prependHistory('c1', <AylaChatMessage>[_msg('y', seq: 5)], hasMore: false);
    final AylaChatMessage y =
        m.messagesOf('c1').firstWhere((AylaChatMessage x) => x.id == 'y');
    expect(y.readByMe, isTrue);

    final AylaMessageState plain = AylaMessageState();
    plain.openBucket('c1');
    plain.upsertMessage('c1', _msg('z', seq: 5));
    expect(plain.messagesOf('c1').single.readByMe, isNull,
        reason: '未接钩子 ⇒ 空操作（纯 state 行为不变）');
  });

  test('viewerAtBottom 默认 true（web `?? true`）', () {
    final AylaMessageState m = AylaMessageState();
    expect(m.viewerAtBottom('c1'), isTrue);
    m.setViewerAtBottom('c1', false);
    expect(m.viewerAtBottom('c1'), isFalse);
  });
}
