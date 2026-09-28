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

  test('viewerAtBottom 默认 true（web `?? true`）', () {
    final AylaMessageState m = AylaMessageState();
    expect(m.viewerAtBottom('c1'), isTrue);
    m.setViewerAtBottom('c1', false);
    expect(m.viewerAtBottom('c1'), isFalse);
  });
}
