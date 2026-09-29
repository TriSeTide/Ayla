/// 宽屏私信：左右卡片的 12px 外边距 + 私聊三区进出场编排（用户 2026-09-29 实报）。
///
/// 事实源（逐条）：
/// - `messages.css:255`：`.wide-messages-sidebar { margin: var(--sidebar-gutter) }`（= 12，
///   `tokens.css:132`）—— 此前只登记未表达（19 号 §7.5 待裁决偏离），本轮按 web 收口；
/// - `auroraqua.css:402–409`（**@media ≥769 内**）：`:is(.chat-header, .private-chat-head, …)`
///   `margin: var(--sidebar-gutter)`；同块 `361–368`：`.wide-messages-pane .private-chat-head`
///   与 `.wide-messages-pane .composer` 各把 **margin-left 归零**；
/// - `auroraqua.css:347–359`（同 @media）：`.composer` 的 `margin: var(--sidebar-gutter)`；
/// - `PrivateChatPane.tsx:165–253`：三区 `motion.header` / `.chat-messages-motion` /
///   `.chat-composer-motion` 各带 `panelVariants`（top / right→left / bottom），
///   `inherit={panelMotion}` + `useIsPresent()`；
/// - `auroraquaMotion.ts:37–51`：`enter = 该边 ±20 + opacity 0` → `center 0/1` →
///   `exit = exitEdge ±20 + opacity 0`，300ms `easeInOut`；reduced ⇒ 位移 0 / 时长 0。
///
/// 测试纪律（实测踩过）：
/// 1. **位移探针必须落在 `Transform` 之下** —— `AylaPanelTransition` 的 element renderObject
///    是 `RenderOpacity`（`Transform` 的**祖先**）⇒ `tester.getTopLeft` 读它拿不到偏移（恒 0）。
///    故几何一律量 panel 内的**内容**（昵称 / 消息列表 / 输入框）。
/// 2. `MaterialApp` 自带多个 `FadeTransition`（页面转场）⇒ 数 FadeTransition 必须限定
///    `of: AylaConversationTransition`。
/// 3. `previewTheme` 的 `Overlay(initialEntries:)` 只在**首次创建**生效 ⇒ 同用例内换档无效，
///    一档一用例。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/chat_message.dart';
import '../lib/core/models/conversation.dart';
import '../lib/core/models/user_public.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/sample_media.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/chat/message_input.dart';
import '../lib/widgets/chat/message_list.dart';
import '../lib/widgets/chat/private_chat_pane.dart';
import '../lib/widgets/motion/gestures.dart';

AylaUserPublic _u(String id, String name) => AylaUserPublic(
      id: id,
      nickname: name,
      username: 'user_$id',
      online: true,
    );

AylaConversationSummary _conv() => AylaConversationSummary(
      id: 'c1',
      type: AylaConversationType.private,
      title: '',
      avatar: '',
      peer: _u('u2', '小樱'),
    );

void main() {
  setUp(aylaEnableSampleMedia);
  tearDown(aylaDisableSampleMedia);

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget host(
    WidgetTester tester,
    Widget child, {
    Size viewport = const Size(900, 700),
    bool reduced = false,
  }) {
    setViewport(tester, viewport);
    return MaterialApp(
      home: previewTheme(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: viewport,
              disableAnimations: reduced,
            ),
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

  /// 私聊面板（宽屏档 + 可选三区编排）。
  Widget pane({bool panelMotion = false, bool blocked = false}) =>
      AylaPrivateChatPane(
        conversation: _conv(),
        messages: const <AylaChatMessage>[],
        currentUserId: 'me',
        peerOnline: true,
        peerStatus: '在线',
        panelMotion: panelMotion,
        blocked: blocked,
        composer: AylaMessageInput(onSubmit: (_) {}, draftKey: 'k'),
      );

  Finder panelOf(AylaPanelEdge edge) => find.byWidgetPredicate(
        (Widget w) => w is AylaPanelTransition && w.edge == edge,
      );

  /// 三区各自的几何探针（必须落在 `Transform` 之下，见文件头纪律 1）。
  Finder headProbe() => find.text('小樱');
  Finder messagesProbe() => find.byType(AylaMessageList);
  Finder composerProbe() => find.byType(AylaMessageInput);

  // ======================= ① 12px 外边距 =======================

  testWidgets('宽屏私聊头部：`margin: var(--sidebar-gutter)` = 上 12 / 右 12，左归零', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(tester, pane()));
    await tester.pump(const Duration(milliseconds: 50));

    final Rect card = tester.getRect(
      find
          .descendant(
            of: find.byType(AylaPrivateChatPane),
            matching: find.byType(AylaGlassSurface),
          )
          .first,
    );
    expect(
      card.left,
      moreOrLessEquals(0, epsilon: 0.01),
      reason:
          'auroraqua.css:361–368 —— `.wide-messages-pane .private-chat-head { margin-left: 0 }`',
    );
    expect(
      card.top,
      moreOrLessEquals(AylaSpacing.sidebarGutter, epsilon: 0.01),
      reason: 'auroraqua.css:402–409 —— 上边距 12',
    );
    expect(
      card.right,
      moreOrLessEquals(900 - AylaSpacing.sidebarGutter, epsilon: 0.01),
      reason: '右边距 12（同一 margin 的右向）',
    );
    // 头部内容高 56（`.private-chat-head { height: 56px }`，既有 chat_panes_test 同口径）
    expect(
      tester
          .getSize(
            find
                .ancestor(
                  of: find.text('小樱'),
                  matching: find.byType(SizedBox),
                )
                .first,
          )
          .height,
      AylaPrivateChatPane.headHeight,
    );
  });

  testWidgets('宽屏输入框：gutter = 左 0 / 右 12 / 下 12（`auroraqua.css:347–368`）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageInput(
          onSubmit: (_) {},
          draftKey: 'k',
          gutter: const EdgeInsets.fromLTRB(
            0,
            AylaSpacing.sidebarGutter,
            AylaSpacing.sidebarGutter,
            AylaSpacing.sidebarGutter,
          ),
        ),
        viewport: const Size(400, 700),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final Rect card = tester.getRect(
      find
          .descendant(
            of: find.byType(AylaMessageInput),
            matching: find.byType(AylaGlassSurface),
          )
          .first,
    );
    expect(card.left, moreOrLessEquals(0, epsilon: 0.01),
        reason: '`.wide-messages-pane .composer { margin-left: 0 }`');
    expect(card.right, moreOrLessEquals(400 - AylaSpacing.sidebarGutter, epsilon: 0.01));
    expect(card.bottom, moreOrLessEquals(700 - AylaSpacing.sidebarGutter, epsilon: 0.01));
  });

  testWidgets('宽屏输入框：不传 gutter ⇒ 默认档不表达外边距（群聊档由调用方决定）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageInput(onSubmit: (_) {}, draftKey: 'k'),
        viewport: const Size(400, 700),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final Rect card = tester.getRect(
      find
          .descendant(
            of: find.byType(AylaMessageInput),
            matching: find.byType(AylaGlassSurface),
          )
          .first,
    );
    expect(card.right, moreOrLessEquals(400, epsilon: 0.01));
    expect(card.bottom, moreOrLessEquals(700, epsilon: 0.01));
  });

  testWidgets('窄屏档：gutter 被忽略（窄屏 `.composer` 是通栏条）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessageInput(
          onSubmit: (_) {},
          draftKey: 'k',
          narrow: true,
          gutter: const EdgeInsets.all(AylaSpacing.sidebarGutter),
        ),
        viewport: const Size(400, 700),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final Rect card = tester.getRect(
      find
          .descendant(
            of: find.byType(AylaMessageInput),
            matching: find.byType(AylaGlassSurface),
          )
          .first,
    );
    expect(card.left, moreOrLessEquals(0, epsilon: 0.01));
    expect(card.right, moreOrLessEquals(400, epsilon: 0.01));
  });

  // ======================= ② 三区编排 =======================

  testWidgets('三区：head=top / 消息区=right→left / 输入区=bottom（tsx:177–242）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(tester, pane(panelMotion: true)));
    await tester.pump(const Duration(milliseconds: 50));

    final List<AylaPanelTransition> panels = tester
        .widgetList<AylaPanelTransition>(find.byType(AylaPanelTransition))
        .toList();
    expect(panels.length, 3, reason: '三区各持有自己的 motion 分区');
    expect(
      panels.map((AylaPanelTransition p) => p.edge).toSet(),
      <AylaPanelEdge>{
        AylaPanelEdge.top,
        AylaPanelEdge.right,
        AylaPanelEdge.bottom,
      },
    );
    expect(
      panels
          .firstWhere((AylaPanelTransition p) => p.edge == AylaPanelEdge.top)
          .exitEdge,
      AylaPanelEdge.top,
      reason: 'panelVariants(reduced, "top")',
    );
    expect(
      panels
          .firstWhere((AylaPanelTransition p) => p.edge == AylaPanelEdge.right)
          .exitEdge,
      AylaPanelEdge.left,
      reason: 'panelVariants(reduced, "right", "left")',
    );
    expect(
      panels
          .firstWhere((AylaPanelTransition p) => p.edge == AylaPanelEdge.bottom)
          .exitEdge,
      AylaPanelEdge.bottom,
      reason: 'panelVariants(reduced, "bottom")',
    );
  });

  testWidgets('panelMotion 默认 false ⇒ 零行为变化（无面板转场节点）', (WidgetTester tester) async {
    await tester.pumpWidget(host(tester, pane()));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(AylaPanelTransition), findsNothing);
  });

  testWidgets('进场：head 自 top −20 归零 / 输入区自 bottom +20 归零 / 消息区自 right +20 归零', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(tester, pane(panelMotion: true)));

    // 挂载首帧 v = 0 ⇒ 已在起始位移上（探针在 Transform 之下）
    final double headTop0 = tester.getTopLeft(headProbe()).dy;
    final double composerTop0 = tester.getTopLeft(composerProbe()).dy;
    final double messagesLeft0 = tester.getTopLeft(messagesProbe()).dx;

    await tester.pump(); // 起 tick（首帧只记 _startTime）
    await tester.pump(const Duration(milliseconds: 400)); // 300ms 走完

    final double headTop1 = tester.getTopLeft(headProbe()).dy;
    final double composerTop1 = tester.getTopLeft(composerProbe()).dy;
    final double messagesLeft1 = tester.getTopLeft(messagesProbe()).dx;

    expect(headTop1 - headTop0, moreOrLessEquals(20, epsilon: 1),
        reason: 'top 边：enter = y −20 → center 0（auroraquaMotion.ts:39–48）');
    expect(composerTop1 - composerTop0, moreOrLessEquals(-20, epsilon: 1),
        reason: 'bottom 边：enter = y +20 → 0');
    expect(messagesLeft1 - messagesLeft0, moreOrLessEquals(-20, epsilon: 1),
        reason: 'right 边：enter = x +20 → 0');
  });

  testWidgets('退场：在场信号转 false ⇒ head 向 top、消息区向 left 各 +20', (
    WidgetTester tester,
  ) async {
    bool present = true;
    late StateSetter setOuter;
    await tester.pumpWidget(
      host(
        tester,
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            setOuter = setState;
            return AylaConversationPresence(
              present: present,
              child: pane(panelMotion: true),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final double headTop0 = tester.getTopLeft(headProbe()).dy;
    final double messagesLeft0 = tester.getTopLeft(messagesProbe()).dx;

    setOuter(() => present = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final double headTop1 = tester.getTopLeft(headProbe()).dy;
    final double messagesLeft1 = tester.getTopLeft(messagesProbe()).dx;

    expect(headTop0 - headTop1, moreOrLessEquals(20, epsilon: 1),
        reason: 'exit = center → exitEdge ±20（head 的 exitEdge = top ⇒ y −20）');
    expect(messagesLeft0 - messagesLeft1, moreOrLessEquals(20, epsilon: 1),
        reason: '消息区 exitEdge = **left**（x −20），与进场边 right 不同');
  });

  testWidgets('reduced-motion：位移 0 / 时长 0（挂载即终态）', (WidgetTester tester) async {
    await tester.pumpWidget(host(tester, pane(panelMotion: true), reduced: true));
    final double headTop0 = tester.getTopLeft(headProbe()).dy;
    final double messagesLeft0 = tester.getTopLeft(messagesProbe()).dx;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.getTopLeft(headProbe()).dy,
        moreOrLessEquals(headTop0, epsilon: 0.01));
    expect(tester.getTopLeft(messagesProbe()).dx,
        moreOrLessEquals(messagesLeft0, epsilon: 0.01));
  });

  testWidgets('禁发档：`.private-chat-blocked` 也在输入区 motion 分区内（tsx:243–246）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(tester, pane(panelMotion: true, blocked: true)));
    await tester.pumpAndSettle();
    final Finder notice = find.text('对方已不是你的好友，无法发送消息');
    expect(notice, findsOneWidget);
    expect(
      find.descendant(of: panelOf(AylaPanelEdge.bottom), matching: notice),
      findsOneWidget,
      reason: '禁发提示与输入区同属 `.chat-composer-motion`',
    );
  });

  // ======================= ③ 宿主：childOwnsPanels =======================

  testWidgets('childOwnsPanels: true ⇒ 旧件不整体淡出，子件读到 present=false', (
    WidgetTester tester,
  ) async {
    String identity = 'a';
    late StateSetter setOuter;
    await tester.pumpWidget(
      host(
        tester,
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            setOuter = setState;
            return AylaConversationTransition(
              identity: identity,
              childOwnsPanels: true,
              builder: (BuildContext context, String id) => Text(
                'pane-$id-${AylaConversationPresence.of(context)}',
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('pane-a-true'), findsOneWidget);

    setOuter(() => identity = 'b');
    await tester.pump();
    expect(find.text('pane-a-false'), findsOneWidget,
        reason: '退出中的旧件读到 present=false（web useIsPresent()）');
    expect(
      find.descendant(
        of: find.byType(AylaConversationTransition),
        matching: find.byType(FadeTransition),
      ),
      findsNothing,
      reason: 'childOwnsPanels ⇒ 宿主不整体淡出（web 透明编排；MaterialApp 自带的淡入不计）',
    );

    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('pane-b-true'), findsOneWidget,
        reason: '旧件退完才挂新件（mode="wait"）');
  });

  testWidgets('childOwnsPanels 默认 false ⇒ 旧件整体淡出兜底（未接面板动效的子件）', (
    WidgetTester tester,
  ) async {
    String identity = 'a';
    late StateSetter setOuter;
    await tester.pumpWidget(
      host(
        tester,
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            setOuter = setState;
            return AylaConversationTransition(
              identity: identity,
              builder: (BuildContext context, String id) => Text('pane-$id'),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    setOuter(() => identity = 'b');
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(AylaConversationTransition),
        matching: find.byType(FadeTransition),
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('pane-b'), findsOneWidget);
  });
}
