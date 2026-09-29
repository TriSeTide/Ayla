/// 选项卡面板**进场**（web `hooks/useTabPanelMotion.ts`）回归 —— 消息域三处复用点。
///
/// 用户 2026-09-29 实报：「窄屏私信界面的顶部选项卡，私信切入切出没有动画」。
///
/// 事实源（逐条）：
/// - `useTabPanelMotion.ts:23–46`：`selection` 变化且非 reduced 时，对**新面板**播
///   `[{opacity:0, x:+20}, {opacity:1, x:0}]`，`duration = 300ms`、
///   `easing = cubic-bezier(.42,0,.58,1)`（= `AURORAQUA_MOTION.easeInOut`）；
///   **没有退出动画** —— 旧面板由条件渲染直接卸载（web 无 `AnimatePresence`）；
///   `prefers-reduced-motion` ⇒ 直接 return（同文件 31 行）；
/// - 三处调用点：`MessagesPage.tsx:63`（窄屏页，selection = `tab`）·
///   `WideMessagesSidebar.tsx:77`（宽屏侧栏，selection = `tab`）·
///   `QuickMessagesSheet.tsx:55`（快捷栏，selection = **`activeChatId ?? tab`**）。
/// - CSS 侧无 animation（`messages.css:70–81` 只有盒模型）⇒ 动画**只来自 JS**。
///
/// 测试纪律（实测踩过）：位移探针必须落在 `Transform` **之下**（[AylaPanelTransition] 的
/// element renderObject 是 `RenderOpacity`，量它恒 0）⇒ 这里量面板内的真实内容。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/conversation.dart';
import '../lib/core/models/user_public.dart';
import '../lib/pages/messages_page.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/sample_media.dart';
import '../lib/widgets/chat/conversation_list.dart' show AylaConversationList;
import '../lib/widgets/chat/messages_layout.dart' show AylaMessagesGroup;
import '../lib/widgets/chat/quick_messages_sheet.dart';
import '../lib/widgets/chat/wide_messages_sidebar.dart';
import '../lib/widgets/motion/gestures.dart';

AylaConversationSummary _conv(String id, String name) => AylaConversationSummary(
      id: id,
      type: AylaConversationType.private,
      title: '',
      avatar: '',
      peer: AylaUserPublic(id: 'u-$id', nickname: name, username: 'user_$id'),
    );

void main() {
  setUp(aylaEnableSampleMedia);
  tearDown(aylaDisableSampleMedia);

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// 宿主：`MediaQuery` 注入尺寸与 `disableAnimations`（reduced 档）。
  Widget host(
    Widget child,
    Size viewport, {
    bool reduced = false,
    bool scope = false,
  }) {
    final Widget inner = Builder(
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
    );
    return MaterialApp(
      home: scope ? previewScope(inner) : previewTheme(inner),
    );
  }

  Future<void> pump(
    WidgetTester tester,
    Widget child,
    Size viewport, {
    bool reduced = false,
    bool scope = false,
  }) async {
    setViewport(tester, viewport);
    await tester.pumpWidget(
      host(child, viewport, reduced: reduced, scope: scope),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  // ======================= ① 窄屏 /messages（用户实报现场） =======================

  testWidgets('窄屏页：三档 tab 各有一个「自右进场」的面板转场节点（edge=right / show）', (
    WidgetTester tester,
  ) async {
    await pump(tester, const MessagesPage(), const Size(420, 760), scope: true);

    AylaPanelTransition panel() => tester.widget<AylaPanelTransition>(
          find.byType(AylaPanelTransition),
        );
    expect(find.byType(AylaPanelTransition), findsOneWidget);
    expect(panel().edge, AylaPanelEdge.right, reason: 'x:+20 ⇒ 自右进场');
    expect(panel().show, isTrue);

    await tester.tap(find.text('好友列表'));
    await tester.pump();
    expect(find.byType(AylaPanelTransition), findsOneWidget);
    expect(panel().edge, AylaPanelEdge.right);

    await tester.tap(find.text('认证消息'));
    await tester.pump();
    expect(find.byType(AylaPanelTransition), findsOneWidget);
    expect(panel().edge, AylaPanelEdge.right);
  });

  testWidgets('窄屏页：切到「好友列表」⇒ 新面板自 x+20 归零（300ms easeInOut）', (
    WidgetTester tester,
  ) async {
    await pump(tester, const MessagesPage(), const Size(420, 760), scope: true);
    expect(find.byType(AylaMessagesGroup), findsNothing, reason: '首帧在私信 tab');

    await tester.tap(find.text('好友列表'));
    await tester.pump(); // 重建帧：新面板 v = 0

    final Finder probe = find.byType(AylaMessagesGroup);
    expect(probe, findsOneWidget);
    final double x0 = tester.getTopLeft(probe).dx;

    await tester.pump(); // 起 tick
    await tester.pump(const Duration(milliseconds: 400)); // 300ms 走完
    final double x1 = tester.getTopLeft(probe).dx;
    expect(
      x1 - x0,
      moreOrLessEquals(-20, epsilon: 1),
      reason: 'useTabPanelMotion：{x:+20} → {x:0}（探针在 Transform 之下）',
    );
  });

  testWidgets('窄屏页：reduced-motion ⇒ 不播进场（位置恒定）', (WidgetTester tester) async {
    await pump(
      tester,
      const MessagesPage(),
      const Size(420, 760),
      scope: true,
      reduced: true,
    );
    await tester.tap(find.text('好友列表'));
    await tester.pump();
    final Finder probe = find.byType(AylaMessagesGroup);
    final double x0 = tester.getTopLeft(probe).dx;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.getTopLeft(probe).dx,
      moreOrLessEquals(x0, epsilon: 0.01),
      reason: 'hook 31 行：`if (!changed || reduced) return`',
    );
  });

  // ======================= ② 宽屏消息侧栏 =======================

  testWidgets('宽屏侧栏：切 tab ⇒ 同款自右进场（WideMessagesSidebar.tsx:77）', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      AylaWideMessagesSidebar(
        activeId: 'c1',
        onSelect: (_) {},
        conversations: <AylaConversationSummary>[_conv('c1', '小樱')],
      ),
      const Size(500, 640),
    );
    final Finder panel = find.byType(AylaPanelTransition);
    expect(panel, findsOneWidget);
    expect(
      tester.widget<AylaPanelTransition>(panel).edge,
      AylaPanelEdge.right,
    );

    // ⚠️ 先等侧栏卡自己的入场（`AylaRevealItem` 左入 −20 / 500ms）走完，
    //    否则探针会量到「卡片 reveal 剩余 + 面板进场」的叠加位移（实测 −3.55 而非 −20）。
    await tester.pumpAndSettle();
    await tester.tap(find.text('好友'));
    await tester.pump();
    // 探针用侧栏好友档的稳定文案（空列表 ⇒ 「暂无好友」，`wide_messages_sidebar.dart:253`）
    final Finder probe = find.text('暂无好友');
    expect(probe, findsOneWidget);
    final double x0 = tester.getTopLeft(probe).dx;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.getTopLeft(probe).dx - x0, moreOrLessEquals(-20, epsilon: 1));
  });

  // ======================= ③ 快捷消息栏 =======================

  testWidgets('快捷栏：面板自右进场 + selection = tab（列表态）', (WidgetTester tester) async {
    await pump(
      tester,
      AylaQuickMessagesSheet(
        onClose: () {},
        privatePanel: const Padding(
          padding: EdgeInsets.all(8),
          child: Text('私信列表占位'),
        ),
      ),
      const Size(420, 600),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AylaPanelTransition), findsOneWidget);
    expect(
      tester.widget<AylaPanelTransition>(find.byType(AylaPanelTransition)).edge,
      AylaPanelEdge.right,
    );
    expect(find.text('私信列表占位'), findsOneWidget);
  });

  testWidgets('快捷栏：入内联私聊（activeChatId 非空）⇒ 也是同一个进场节点', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      AylaQuickMessagesSheet(
        onClose: () {},
        activeChatId: 'c1',
        privateChatPane: const Padding(
          padding: EdgeInsets.all(8),
          child: Text('内联私聊占位'),
        ),
      ),
      const Size(420, 600),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AylaPanelTransition), findsOneWidget,
        reason: 'web selection = `activeChatId ?? tab` ⇒ 进私聊同样播进场');
    expect(find.text('内联私聊占位'), findsOneWidget);
  });
}
