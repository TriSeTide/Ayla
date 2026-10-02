/// 未读跳转标签「点击不跳转」专项测试（2026-10-02 用户真机实报）。
///
/// ## 现象（Lead 真机复现）
/// 群聊页顶部未读跳转标签（语义树 Button "跳转到 15 条未读消息"，actions=[invoke]）
/// **点击后页面逐像素无变化**：消息列表内容 / 滚动位置 / 时间戳全部一致。
///
/// ## 事实源（web）
/// - MessageList.tsx:844–859（handleJumpTag：找不到目标 ⇒ onLoadUntilSeq ⇒ 再找 ⇒ 跳）
/// - MessageList.tsx:734–762（jumpToMessage：**目标不在当前渲染窗口时先重定心窗口**
///   setWindowAround，再由 tsx 861–894 的 layout effect 完成滚动定位）
/// - MessageList.tsx:709–721（setWindowAround：把渲染窗口移到目标附近 → 目标进入 DOM）
/// - MessageList.tsx:652–667（scrollToMessageAndHighlight：**目标节点存在**才滚动居中 + 高亮）
/// - useChat.ts:185–214（loadHistoryUntilSeq：按 seq 翻页直到目标进缓存，失败返回 false）
/// - message_list.dart 文件头「与 web 的差异 1」：Flutter 不做 DOM 窗口化，靠 ListView.builder
///   懒构建 —— 但**懒构建的项没有 RenderObject**，Scrollable.ensureVisible 拿不到 context。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/chat_message.dart';
import '../lib/core/models/conversation.dart';
import '../lib/core/models/user_public.dart';
import '../lib/core/ws/chat_ws.dart';
import '../lib/pages/chat_support.dart' show AylaConversationRuntime;
import '../lib/state/badges_state.dart';
import '../lib/state/chat_drafts.dart';
import '../lib/state/chat_state.dart';
import '../lib/state/message_state.dart';
import '../lib/state/notices_state.dart';
import '../lib/state/realtime_state.dart';
import '../lib/state/subgroup_state.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/chat/message_list.dart';

AylaChatMessage _msg({
  required String id,
  required int seq,
  String senderId = 'u1',
  String? content,
}) =>
    AylaChatMessage(
      id: id,
      conversationId: 'c1',
      senderId: senderId,
      type: AylaMessageType.text,
      status: AylaMessageStatus.sent,
      content: content ?? '第 $seq 条 ${'占位内容占位内容占位内容占位内容占位 ' * 4}',
      seq: seq,
      createdAt: DateTime(2026, 10, 2, 12, 0)
          .add(Duration(minutes: seq))
          .toUtc()
          .toIso8601String(),
    );

AylaConversationSummary _conv() => AylaConversationSummary(
      id: 'c1',
      type: AylaConversationType.group,
      title: '深夜电台群',
      avatar: '',
      members: <AylaConversationMember>[
        AylaConversationMember(
          id: 'm1',
          user: const AylaUserPublic(id: 'u1', nickname: '汐汐', username: 'xixi'),
        ),
      ],
    );

void main() {
  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget host(WidgetTester tester, Widget child,
      {Size viewport = const Size(500, 600)}) {
    setViewport(tester, viewport);
    return MaterialApp(
      home: previewTheme(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: SizedBox(
                width: viewport.width, height: viewport.height, child: child),
          ),
        ),
      ),
    );
  }

  double offsetOf(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels;

  double maxOffsetOf(WidgetTester tester) => tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position
      .maxScrollExtent;

  /// 冲掉跳转的异步链：`_revealTarget` 的分步 `jumpTo`（每步等一帧）+
  /// `ensureVisible` 的 300ms 动画 + 高亮。帧数给足，避免「动画中途取景」
  /// 让懒构建的行被回收导致误判。
  Future<void> settleJump(WidgetTester tester) async {
    for (int i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Rect? rectOfText(WidgetTester tester, String text) {
    final Finder f = find.text(text);
    if (f.evaluate().isEmpty) return null;
    return tester.getRect(f.first);
  }

  // 40 条高行消息：首屏只构建视口附近的项（懒构建）
  List<AylaChatMessage> many({int count = 40, int start = 1}) =>
      <AylaChatMessage>[
        for (int i = start; i < start + count; i++) _msg(id: 'm$i', seq: i),
      ];

  testWidgets('S1 目标在缓存但未被懒构建 ⇒ 点击未读标签必须滚动到目标（实报根因）',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageList(
          messages: many(),
          conversation: _conv(),
          currentUserId: 'me',
          unreadSeqs: const <int>[1],
          // 与生产接线同形（group_chat_page.dart:626–627）：目标「已在缓存」时
          // AylaConversationRuntime.loadUntilSeq 在 chat_support.dart:279 立刻返回 true。
          onLoadUntilSeq: (int seq) async => true,
          onMarkConversationRead: (int seq, List<String> ids) async {},
          onMarkRead: (AylaChatMessage m, bool exact) async {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final double before = offsetOf(tester);
    expect(before, 0, reason: '初始贴底');

    await tester.tap(find.text('1 条新消息'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await settleJump(tester);

    final double after = offsetOf(tester);
    // ignore: avoid_print
    print('S1 before=$before after=$after max=${maxOffsetOf(tester)} '
        'targetRect=${rectOfText(tester, _msg(id: 'm1', seq: 1).content)}');
    expect(after, greaterThan(before + 100),
        reason: '点击未读标签必须真的滚动（当前实现：目标未构建 ⇒ ensureVisible 被跳过 ⇒ 零位移）');
    final Rect? rect = rectOfText(tester, _msg(id: 'm1', seq: 1).content);
    expect(rect, isNotNull, reason: '跳转后目标行必须被构建并可见');
    expect(rect!.bottom, lessThanOrEqualTo(601));
  });

  testWidgets('S2 目标不在缓存、由 onLoadUntilSeq 补进缓存 ⇒ 点击必须滚动到目标',
      (WidgetTester tester) async {
    List<AylaChatMessage> messages = many(count: 40, start: 60);
    bool loaded = false;
    late StateSetter setLocal;
    await tester.pumpWidget(
      host(
        tester,
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setter) {
            setLocal = setter;
            return AylaMessageList(
              messages: messages,
              conversation: _conv(),
              currentUserId: 'me',
              hasMore: true,
              unreadSeqs: const <int>[58],
              onLoadUntilSeq: (int seq) async {
                if (loaded) return true;
                loaded = true;
                setLocal(() {
                  messages = <AylaChatMessage>[
                    _msg(id: 'm58', seq: 58),
                    _msg(id: 'm59', seq: 59),
                    ...messages,
                  ];
                });
                return true;
              },
              onLoadMore: () async {},
              onMarkConversationRead: (int seq, List<String> ids) async {},
              onMarkRead: (AylaChatMessage m, bool exact) async {},
            );
          },
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('1 条新消息'), findsOneWidget);

    await tester.tap(find.text('1 条新消息'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await settleJump(tester);

    final Rect? rect = rectOfText(tester, _msg(id: 'm58', seq: 58).content);
    // ignore: avoid_print
    print('S2 offset=${offsetOf(tester)} max=${maxOffsetOf(tester)} targetRect=$rect');
    expect(rect, isNotNull, reason: '补页后目标必须被构建并可见（web：窗口重定心 → 滚动居中）');
    expect(offsetOf(tester), greaterThan(50), reason: '补页后必须离开底部');
  });

  testWidgets('S3 onLoadUntilSeq 返回 false ⇒ 不崩、不伪造跳转、留下可诊断日志',
      (WidgetTester tester) async {
    final List<String> logs = <String>[];
    // debugPrint 是 foundation 调试变量：必须在**测试体结束前**原样还原，
    // 否则 binding 的 `debugAssertAllFoundationVarsUnset` 会在收尾断言失败。
    final void Function(String? message, {int? wrapWidth}) original = debugPrint;
    int loadCalls = 0;
    try {
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      await tester.pumpWidget(
        host(
          tester,
          AylaMessageList(
            messages: many(),
            conversation: _conv(),
            currentUserId: 'me',
            unreadSeqs: const <int>[777],
            onLoadUntilSeq: (int seq) async {
              loadCalls++;
              return false;
            },
            onMarkConversationRead: (int seq, List<String> ids) async {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('1 条新消息'), findsOneWidget);
      await tester.tap(find.text('1 条新消息'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    } finally {
      debugPrint = original;
    }

    expect(loadCalls, 1, reason: '确实尝试了补页');
    expect(offsetOf(tester), 0, reason: '目标确实不可达：不得伪造跳转');
    expect(tester.takeException(), isNull);
    // ignore: avoid_print
    print('S3 logs=$logs');
    expect(logs.where((String s) => s.contains('777')).isNotEmpty, isTrue,
        reason: '加载失败必须留下可诊断日志（web 静默 ⇒ Flutter 至少 debugPrint 留痕）');
  });

  testWidgets('S4 目标已在 messages 且已构建 ⇒ 跳转后仍可见（回归）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageList(
          messages: many(count: 4, start: 1),
          conversation: _conv(),
          currentUserId: 'me',
          unreadSeqs: const <int>[2],
          onLoadUntilSeq: (int seq) async => true,
          onMarkConversationRead: (int seq, List<String> ids) async {},
          onMarkRead: (AylaChatMessage m, bool exact) async {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('1 条新消息'), findsOneWidget);
    await tester.tap(find.text('1 条新消息'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(rectOfText(tester, _msg(id: 'm2', seq: 2).content), isNotNull,
        reason: '可见目标：跳转后仍可见');
  });

  testWidgets('S5 真实 AylaConversationRuntime.loadUntilSeq：补页落空 ⇒ 不崩、不伪造跳转、有日志',
      (WidgetTester tester) async {
    // ★ 端到端锁：用**生产实现**（不是复刻早退条件）。
    //
    // 链路：`chat_support.dart:276–289` 的循环第一轮就命中「目标在桶里 ⇒ return true」；
    // 而 S1 覆盖「目标在桶里但 `widget.messages` 是另一个已加载窗口」的同形场景。
    // 真正致命的是 `minSeq <= targetSeq` 那一支：目标 seq **比最小已加载 seq 更大**、
    // 又不在桶里（空洞 / props 未刷新）时 web 与 Flutter 都返回 false —— 那是
    // 「不需要补页」的正常态；修复前 `jumpToMessage` 把它当「补页失败」直接 return，
    // 于是 `Scrollable.ensureVisible` 完全没执行 ⇒ 用户实报的零位移。
    final AylaChatState chat = AylaChatState();
    final AylaMessageState message = AylaMessageState();
    final AylaSubGroupState subgroups = AylaSubGroupState();
    final AylaChatWsClient ws = AylaChatWsClient(
      chatState: chat,
      messageState: message,
      notices: AylaNoticesController(),
      badges: AylaBadgesController(),
      realtime: AylaRealtimeState(),
      subgroupState: subgroups,
      currentUserId: () => 'me',
      autoReconcile: false,
    );
    final AylaConversationRuntime runtime = AylaConversationRuntime(
      conversationId: 'c1',
      chatState: chat,
      messageState: message,
      drafts: AylaChatDraftsController(),
      badges: AylaBadgesController(),
      ws: ws,
      currentUserId: () => 'me',
    );
    addTearDown(() {
      runtime.dispose();
      ws.disconnect();
      chat.dispose();
      message.dispose();
      subgroups.dispose();
    });

    // 桶里只有 seq 30..69；未读标签指向 seq 10（更早、桶里没有）⇒ 需要补页。
    message.openBucket('c1');
    message.prependHistory(
      'c1',
      <AylaChatMessage>[for (int i = 30; i < 70; i++) _msg(id: 'm$i', seq: i)],
      hasMore: true,
    );
    // ★ 真实的早退：minSeq(30) <= targetSeq(10) 为假 ⇒ 会走 loadMore()（网络失败静默）
    //   ⇒ 循环 200 轮后返回 false。这正是实报里「点了没反应」的那条分支。
    // `maxPages: 1` 把「翻页 ⇒ 无网络失败」的尝试收敛到一次，避免测试期做 200 次连接。
    expect(await runtime.loadUntilSeq(10, maxPages: 1), isFalse,
        reason: '前置：真实实现确实返回 false（无网络 ⇒ loadMore 失败 ⇒ 有界循环落空）');
    final List<AylaChatMessage> uiMessages =
        <AylaChatMessage>[for (int i = 30; i < 70; i++) _msg(id: 'm$i', seq: i)];
    // 记录点击期间产生的日志（下面断言「失败有诊断」）。
    // ⚠️ debugPrint 是 foundation 调试变量，必须在测试体结束前还原（见 S3 注释）。
    final List<String> logs = <String>[];
    final void Function(String? message, {int? wrapWidth}) original = debugPrint;
    try {
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      await tester.pumpWidget(
        host(
          tester,
          AylaMessageList(
            messages: uiMessages,
            conversation: _conv(),
            currentUserId: 'me',
            unreadSeqs: const <int>[10],
            onLoadUntilSeq: (int seq) => runtime.loadUntilSeq(seq, maxPages: 1),
            onMarkConversationRead: (int seq, List<String> ids) async {},
            onMarkRead: (AylaChatMessage m, bool exact) async {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('1 条新消息'), findsOneWidget);
      expect(offsetOf(tester), 0, reason: '初始贴底');

      await tester.tap(find.text('1 条新消息'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await settleJump(tester);
    } finally {
      debugPrint = original;
    }

    // 目标 seq=10 不在消息面里 ⇒ 真不可达，不得伪造跳转；但**必须**有可诊断日志，
    // 且不得因为 loadUntilSeq 返回 false 就静默吞掉整条路径（见 S7 的同源断言）。
    expect(offsetOf(tester), 0, reason: '目标不在消息面：确实无法定位，不伪造');
    expect(tester.takeException(), isNull);
    expect(logs.where((String s) => s.contains('seq=10')).isNotEmpty, isTrue,
        reason: '真实 loadUntilSeq 落空时必须留下可诊断日志（实报里用户毫无反馈）');
  });

  testWidgets('S6 首猜偏移故意打歪 ⇒ 二分收敛后仍能定位（不依赖估算精度）',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageList(
          messages: many(),
          conversation: _conv(),
          currentUserId: 'me',
          unreadSeqs: const <int>[1],
          // 首猜锚到「最底部」——离目标最远的位置
          scrollOffsetGuess: (int index, ScrollPosition pos) => 0,
          onLoadUntilSeq: (int seq) async => true,
          onMarkConversationRead: (int seq, List<String> ids) async {},
          onMarkRead: (AylaChatMessage m, bool exact) async {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('1 条新消息'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await settleJump(tester);

    final Rect? rect = rectOfText(tester, _msg(id: 'm1', seq: 1).content);
    // ignore: avoid_print
    print('S6 offset=${offsetOf(tester)} targetRect=$rect');
    expect(rect, isNotNull, reason: '首猜打歪也必须靠二分收敛把目标带进构建范围');
  });

  testWidgets('S7 未注入 onLoadUntilSeq 且目标不在 messages ⇒ 不崩 + 可诊断日志',
      (WidgetTester tester) async {
    final List<String> logs = <String>[];
    final void Function(String? message, {int? wrapWidth}) original = debugPrint;
    try {
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      await tester.pumpWidget(
        host(
          tester,
          AylaMessageList(
            messages: many(),
            conversation: _conv(),
            currentUserId: 'me',
            unreadSeqs: const <int>[9999],
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('1 条新消息'), findsOneWidget);
      await tester.tap(find.text('1 条新消息'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    } finally {
      debugPrint = original;
    }
    expect(offsetOf(tester), 0, reason: '确实不可达：不得伪造跳转');
    expect(tester.takeException(), isNull);
    expect(logs.where((String s) => s.contains('9999')).isNotEmpty, isTrue,
        reason: '未注入回调时必须留下可诊断日志（旧实现整段静默 return）');
  });

  testWidgets('S8 超长会话（500 条）+ 首猜锚到最底 ⇒ 仍有界收敛到目标', (WidgetTester tester) async {
    // 覆盖「行高在长链上分布不均、纯二分预算不够」的场景：割线插值必须把命中次数压住。
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageList(
          messages: many(count: 500, start: 1),
          conversation: _conv(),
          currentUserId: 'me',
          unreadSeqs: const <int>[3],
          scrollOffsetGuess: (int index, ScrollPosition pos) => 0,
          onLoadUntilSeq: (int seq) async => true,
          onMarkConversationRead: (int seq, List<String> ids) async {},
          onMarkRead: (AylaChatMessage m, bool exact) async {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('1 条新消息'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await settleJump(tester);

    final Rect? rect = rectOfText(tester, _msg(id: 'm3', seq: 3).content);
    // ignore: avoid_print
    print('S8 offset=${offsetOf(tester)} max=${maxOffsetOf(tester)} targetRect=$rect');
    expect(rect, isNotNull, reason: '500 条会话也必须把目标带进构建范围（有界收敛）');
  });

  testWidgets('S9 端到端（真实 runtime + 目标在桶里但未构建）⇒ 必须跳转', (WidgetTester tester) async {
    // ★ 与真机主路径最贴近的一条：`unreadSeqs` 指向的 seq **确实在消息桶里**
    //（群聊首屏拉最新 20 条，未读就在其中），但用户上翻过历史 ⇒ 目标行被
    // `ListView.builder` 回收、没有 RenderObject。
    //
    // 修复前的两个断点在这条路径上同时成立：
    //   ① `jumpToMessage` 用 `key.currentContext == null` 当作「需要补页」的判据；
    //   ② `runtime.loadUntilSeq` 命中缓存返回 true，但 `Future.delayed(Duration.zero)`
    //      等不到重建，`key.currentContext` 仍是 null ⇒ `ensureVisible` 整段跳过。
    final AylaChatState chat = AylaChatState();
    final AylaMessageState message = AylaMessageState();
    final AylaSubGroupState subgroups = AylaSubGroupState();
    final AylaChatWsClient ws = AylaChatWsClient(
      chatState: chat,
      messageState: message,
      notices: AylaNoticesController(),
      badges: AylaBadgesController(),
      realtime: AylaRealtimeState(),
      subgroupState: subgroups,
      currentUserId: () => 'me',
      autoReconcile: false,
    );
    final AylaConversationRuntime runtime = AylaConversationRuntime(
      conversationId: 'c1',
      chatState: chat,
      messageState: message,
      drafts: AylaChatDraftsController(),
      badges: AylaBadgesController(),
      ws: ws,
      currentUserId: () => 'me',
    );
    addTearDown(() {
      runtime.dispose();
      ws.disconnect();
      chat.dispose();
      message.dispose();
      subgroups.dispose();
    });

    // 真实桶：seq 1..40（相当于「首屏 20 + 上翻一页」），目标 seq=2 在桶里。
    message.openBucket('c1');
    message.prependHistory(
      'c1',
      <AylaChatMessage>[for (int i = 1; i <= 40; i++) _msg(id: 'm$i', seq: i)],
      hasMore: true,
    );
    expect(await runtime.loadUntilSeq(2), isTrue,
        reason: '前置：真实 loadUntilSeq 对「已在桶里」的目标返回 true（chat_support.dart:279）');

    await tester.pumpWidget(
      host(
        tester,
        AylaMessageList(
          messages: runtime.messages,
          conversation: _conv(),
          currentUserId: 'me',
          unreadSeqs: const <int>[2],
          onLoadUntilSeq: runtime.loadUntilSeq,
          onMarkConversationRead: (int seq, List<String> ids) async {},
          onMarkRead: (AylaChatMessage m, bool exact) async {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final double before = offsetOf(tester);
    expect(before, 0, reason: '初始贴底：目标行未被构建');
    expect(find.text('1 条新消息'), findsOneWidget);

    await tester.tap(find.text('1 条新消息'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await settleJump(tester);

    final Rect? rect = rectOfText(tester, _msg(id: 'm2', seq: 2).content);
    // ignore: avoid_print
    print('S9 before=$before after=${offsetOf(tester)} targetRect=$rect');
    expect(offsetOf(tester), greaterThan(before + 100),
        reason: '真实链路：目标在桶里但未被构建 ⇒ 必须滚动定位（实报的零位移根因）');
    expect(rect, isNotNull, reason: '跳转后目标行必须被构建并可见');
  });
}
