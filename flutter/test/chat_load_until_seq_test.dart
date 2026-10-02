/// `AylaConversationRuntime.loadUntilSeq` 的**契约边界**测试。
///
/// ## 为什么单独测它
/// 用户实报的「未读跳转标签点击不跳转」根因链里，这一环是**被误用的一方**：
/// `loadUntilSeq` 回答的是「历史是否已加载到目标」，而不是「跳转是否成功」。
/// 它的早退条件（`minSeq <= targetSeq` / `!hasMore`）在目标已落在已加载区间内或已到
/// 历史尽头时**合理地**返回 false —— 调用方（`AylaMessageList`）曾经把这个 false 当成
/// 「补页失败」直接 return，于是用户点击后页面零位移。
///
/// 本文件把这条语义钉死，并与 web `useChat.ts:185–214` 的 `loadHistoryUntilSeq`
/// 逐条对齐（同一循环形、同一三个早退条件）。
///
/// ⚠️ 覆盖范围：**不需要网络**的分支（早退、命中缓存、页数预算用尽）；
/// 真正落库翻页的路径由 widget 层用例 `message_jump_tag_test.dart` 的 S2 覆盖
///（那里注入 `onLoadUntilSeq` 并验证补页后确实跳转）。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/chat_message.dart';
import '../lib/core/ws/chat_ws.dart';
import '../lib/pages/chat_support.dart';
import '../lib/state/badges_state.dart';
import '../lib/state/chat_drafts.dart';
import '../lib/state/chat_state.dart';
import '../lib/state/message_state.dart';
import '../lib/state/notices_state.dart';
import '../lib/state/realtime_state.dart';
import '../lib/state/subgroup_state.dart';

AylaChatMessage _msg(int seq, {bool pending = false}) => AylaChatMessage(
      id: 'm$seq',
      conversationId: 'c1',
      senderId: 'u1',
      type: AylaMessageType.text,
      status: AylaMessageStatus.sent,
      content: '第 $seq 条',
      seq: seq,
      pending: pending,
      createdAt: DateTime(2026, 10, 2, 12, 0)
          .add(Duration(minutes: seq))
          .toUtc()
          .toIso8601String(),
    );

void main() {
  late AylaChatState chat;
  late AylaMessageState message;
  late AylaSubGroupState subgroups;
  late AylaChatWsClient ws;
  late AylaConversationRuntime runtime;

  setUp(() {
    chat = AylaChatState();
    message = AylaMessageState();
    subgroups = AylaSubGroupState();
    ws = AylaChatWsClient(
      chatState: chat,
      messageState: message,
      notices: AylaNoticesController(),
      badges: AylaBadgesController(),
      realtime: AylaRealtimeState(),
      subgroupState: subgroups,
      currentUserId: () => 'me',
      autoReconcile: false,
    );
    runtime = AylaConversationRuntime(
      conversationId: 'c1',
      chatState: chat,
      messageState: message,
      drafts: AylaChatDraftsController(),
      badges: AylaBadgesController(),
      ws: ws,
      currentUserId: () => 'me',
    );
  });

  tearDown(() {
    runtime.dispose();
    ws.disconnect();
    chat.dispose();
    message.dispose();
    subgroups.dispose();
  });

  group('loadUntilSeq 契约（对照 web useChat.ts:185–214）', () {
    test('桶未打开 ⇒ false（web :196 `if (!bucket) return false`）', () async {
      expect(await runtime.loadUntilSeq(5), isFalse);
    });

    test('非法目标 seq（<= 0）⇒ false，不发起请求（web :192）', () async {
      message.openBucket('c1');
      expect(await runtime.loadUntilSeq(0), isFalse);
      expect(await runtime.loadUntilSeq(-3), isFalse);
    });

    test('目标已在桶里 ⇒ true（web :197 `some(seq === targetSeq)`）', () async {
      message.openBucket('c1');
      message.prependHistory(
        'c1',
        <AylaChatMessage>[_msg(60), _msg(61), _msg(62)],
        hasMore: true,
      );
      expect(await runtime.loadUntilSeq(61), isTrue);
    });

    test('目标比最小已加载 seq 更大但不在桶里（空洞）⇒ false —— 「不需要补页」的正常态'
        '（web :203 `minSeq <= targetSeq`）', () async {
      // before_seq 游标只能向前翻页，比最早一条更新的空洞补不出来 ⇒ web 同样早退 false。
      message.openBucket('c1');
      message.prependHistory(
        'c1',
        <AylaChatMessage>[_msg(60), _msg(61), _msg(62)],
        hasMore: true,
      );
      expect(await runtime.loadUntilSeq(62), isTrue, reason: '在桶里 ⇒ 命中');
      expect(await runtime.loadUntilSeq(63), isFalse,
          reason: '63 不在桶里，而 minSeq(60) <= 63 ⇒ 早退 false（不需补页）');
    });

    test('已到历史尽头（hasMore == false）且目标不在桶里 ⇒ false（web :203 `!bucket.hasMore`）',
        () async {
      message.openBucket('c1');
      message.prependHistory(
        'c1',
        <AylaChatMessage>[_msg(60), _msg(61)],
        hasMore: false,
      );
      expect(await runtime.loadUntilSeq(1), isFalse,
          reason: '没有更早历史可翻 ⇒ 不得伪造成功');
    });

    test('页数预算用尽 ⇒ false（maxPages 边界，web :194 的 for 上界）', () async {
      message.openBucket('c1');
      message.prependHistory(
        'c1',
        <AylaChatMessage>[_msg(60), _msg(61)],
        hasMore: true,
      );
      expect(await runtime.loadUntilSeq(1, maxPages: 0), isFalse,
          reason: '一页都不允许 ⇒ 直接落空，不得伪造定位成功');
    });

    test('pending 本地消息（seq=0）不参与最小 seq 判定（web :199–200 过滤 pending）',
        () async {
      message.openBucket('c1');
      message.addPendingMessage('c1', _msg(0, pending: true));
      // 只有 pending ⇒ 滤掉后没有已确认消息 ⇒ minSeq == null ⇒ false（不炸、不误判）
      expect(await runtime.loadUntilSeq(5), isFalse);
    });

    test('命中缓存不依赖网络；maxPages 为 0 时连命中检查都不执行（与 web 逐字一致）',
        () async {
      // ⚠️ web useChat.ts:194–197 把「命中缓存」的检查**放在页循环体内** ⇒
      // `maxPages = 0` 时循环体一次都不跑，即使目标已在缓存也返回 false。
      // 本件（chat_support.dart:276–281）同形，故此处按同一口径断言 —— 这是
      // 「调用方必须给正预算」的契约，不是缺陷。
      message.openBucket('c1');
      message.prependHistory(
        'c1',
        <AylaChatMessage>[_msg(7)],
        hasMore: true,
      );
      expect(await runtime.loadUntilSeq(7), isTrue,
          reason: '默认 200 页预算 ⇒ 第一轮循环即命中');
      expect(await runtime.loadUntilSeq(7, maxPages: 0), isFalse,
          reason: '零预算 ⇒ 循环体不执行（与 web useChat.ts:194 同形）');
    });
  });
}
