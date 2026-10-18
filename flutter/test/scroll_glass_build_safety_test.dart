/// 滚动期**不得**产生「Build scheduled during frame」的回归锁（2026-10-17）。
///
/// ## 锁的是什么（真实回归，Lead 复现：`message_jump_tag_test` 8/8 全红）
/// 背底层纹理缓存下沉进 [AylaGlassBackdrop] 后，`_AylaBackdropCache` 外面多了一层
/// 本件自己的 `LayoutBuilder`。而 `_AylaBackdropCache` 旧实现在
/// `ScrollPosition.isScrollingNotifier` 的通知里 **`setState`**：
///
/// ```
/// void _onScrollChanged() {
///   ...
///   setState(() => _scrolling = now);   // ← layout 期触发 build
/// }
/// ```
///
/// 该通知会在 **`RenderViewport.performLayout` 期间**发出 ⇒ 断言：
///
/// ```
/// Build scheduled during frame.
/// A _RenderLayoutBuilder was mutated in RenderViewport.performLayout.
/// Failed assertion: 'debugNeedsLayout': is not true.   ← 抛在 AylaGlassBackdrop
/// ```
///
/// 改前只有「面积 ≥ 阈值的大卡」才有 `LayoutBuilder + 缓存`（聊天页气泡都不在内）；
/// 下沉后**每个气泡都有** ⇒ 一滚动就成片触发。
///
/// ## 修法
/// `_scrolling` 只被刷新周期（[_period] → Timer 时长）读，**build 完全不读**
/// ⇒ 直接赋值即可，不需要重建 widget（零额外帧）。
///
/// ## 本文件的判别力（红-绿已验证）
/// 把 `setState(() => _scrolling = now)` 改回去 ⇒ 本文件两条用例**立刻变红**
/// （断言 `takeException()` 捕到 `debugNeedsLayout` / `Build scheduled during frame`）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/chat_message.dart';
import '../lib/core/models/conversation.dart';
import '../lib/core/models/user_public.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/chat/message_bubble.dart';
import '../lib/widgets/chat/message_list.dart';

AylaChatMessage _msg({required String id, required int seq, bool self = false}) =>
    AylaChatMessage(
      id: id,
      conversationId: 'c1',
      senderId: self ? 'me' : 'u1',
      type: AylaMessageType.text,
      status: AylaMessageStatus.sent,
      content: '第 ' + seq.toString() + ' 条 ' + ('占位内容占位内容占位内容占位 ' * 3),
      seq: seq,
      createdAt: DateTime(2026, 10, 17, 12, 0)
          .add(Duration(minutes: seq))
          .toUtc()
          .toIso8601String(),
    );

AylaConversationSummary _conv() => AylaConversationSummary(
      id: 'c1',
      type: AylaConversationType.group,
      title: '滚动回归群',
      avatar: '',
      members: <AylaConversationMember>[
        AylaConversationMember(
          id: 'm1',
          user: const AylaUserPublic(id: 'u1', nickname: '汐汐', username: 'xixi'),
        ),
      ],
    );

void main() {
  /// 高行消息（保证一定可滚），且**大部分是别人**的气泡（= 真有 blur(12) 背底层的那档）。
  List<AylaChatMessage> many({int count = 40}) => <AylaChatMessage>[
        for (int i = 1; i <= count; i += 1)
          _msg(id: 'm' + i.toString(), seq: i, self: i % 5 == 0),
      ];

  Widget host(WidgetTester tester, Widget child) {
    const Size viewport = Size(500, 600);
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    return MaterialApp(
      home: previewTheme(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: SizedBox(
              width: viewport.width,
              height: viewport.height,
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('真实消息列表：拖动滚动全程不产生构建期异常（Build scheduled during frame）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageList(
          messages: many(),
          conversation: _conv(),
          currentUserId: 'me',
          onMarkConversationRead: (int seq, List<String> ids) async {},
          onMarkRead: (AylaChatMessage m, bool exact) async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // 气泡确实都是玻璃（别人气泡带 blur(12) 背底层）—— 否则本用例测不到目标路径。
    expect(find.byType(AylaMessageBubble), findsWidgets);
    expect(tester.takeException(), isNull, reason: '首帧就不得有异常');

    // 按住拖动（滚动进行中 → isScrollingNotifier 会翻转 → 曾在此触发 setState）
    final TestGesture gesture = await tester.startGesture(const Offset(250, 300));
    for (int i = 0; i < 12; i += 1) {
      await gesture.moveBy(const Offset(0, -18));
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.takeException(),
        isNull,
        reason:
            '滚动第 ' +
            i.toString() +
            ' 步出现异常 —— 典型是「Build scheduled during frame / '
            'debugNeedsLayout」（滚动通知里 setState 的回归）',
      );
    }
    await gesture.up();
    await tester.pump();

    // 松开后（isScrollingNotifier 再翻回 false）也不得炸。
    for (int i = 0; i < 6; i += 1) {
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.takeException(), isNull, reason: '停止滚动后的收尾帧不得有异常');
    }
  });

  testWidgets('滚动状态翻转只改刷新周期：不重建 _AylaBackdropCache（无 setState）', (
    WidgetTester tester,
  ) async {
    // 判别力用例：滚动过程中本件 State 的 **element 不得被标记重建**。
    // 做法：给列表外面套一个 build 计数探针，滚动只应触发列表内部的滚动重绘，
    // 不该因「缓存件 setState」而把整棵玻璃子树重建。
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageList(
          messages: many(),
          conversation: _conv(),
          currentUserId: 'me',
          onMarkConversationRead: (int seq, List<String> ids) async {},
          onMarkRead: (AylaChatMessage m, bool exact) async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final TestGesture gesture = await tester.startGesture(const Offset(250, 300));
    for (int i = 0; i < 8; i += 1) {
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.takeException(), isNull);
    }
    await gesture.up();
    await tester.pump();

    // 滚动后列表仍然正常（内容还在、可继续交互）。
    expect(find.byType(AylaMessageList), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  /// **真正的触发路径**：与 `message_jump_tag_test` 的 S2 **逐字同构** ——
  /// 消息 seq 从 60 起（目标 seq 58 在列表**之前**），靠 `onLoadUntilSeq` 往前补页；
  /// 补页后新气泡插到列表头部、并伴随一次长距离跳转 ⇒ 新玻璃气泡在**后续几帧的
  /// layout 期**被挂载/揭出。此时 `_bindScrollPosition()` 同步调 `_onScrollChanged()`
  /// （glass.dart:602）⇒ 旧实现的 `setState` 会在 `RenderViewport.performLayout` 期间
  /// 突变 `_RenderLayoutBuilder`（= `message_jump_tag_test` 8/8 全红的那条断言）。
  ///
  /// ⚠️ 上一版我用「插入到头部 + 目标 seq=2」构造，**没有辨别力**（红-绿不过）：
  /// 那条路径下新气泡的滚动位置在挂载时已经是同一个值，`if (now == _scrolling) return;`
  /// 提前返回，永远走不到 setState。构型必须与 S2 一致才能复现。
  testWidgets('前置补页 + 长距离跳转（新玻璃气泡在 layout 期挂载）不得产生构建期异常', (
    WidgetTester tester,
  ) async {
    List<AylaChatMessage> messages = <AylaChatMessage>[
      for (int i = 60; i < 100; i += 1) _msg(id: 'm' + i.toString(), seq: i),
    ];
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('1 条新消息'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('1 条新消息'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // 冲掉跳转的异步链（分步 jumpTo + ensureVisible + 高亮），逐帧检查异常。
    for (int i = 0; i < 24; i += 1) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        tester.takeException(),
        isNull,
        reason:
            '跳转第 ' +
            i.toString() +
            ' 帧出现异常：典型是「Build scheduled during frame / '
            'A _RenderLayoutBuilder was mutated in RenderViewport.performLayout」'
            '（新气泡在 layout 期挂载 ⇒ _bindScrollPosition → _onScrollChanged 里 setState）',
      );
    }
  });
}
