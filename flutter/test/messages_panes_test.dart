/// B3 chat 第四批（下）：宽屏消息左列 + 快捷消息栏定向测试。
///
/// 对照：`WideMessagesSidebar.tsx` / `QuickMessagesSheet.tsx` + messages.css 243–425。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/conversation.dart';
import '../lib/core/models/user_public.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/sample_media.dart';
import '../lib/widgets/messages_tabs.dart';
import '../lib/widgets/dialogs.dart'
    show AylaModalCard, AylaModalOverlay, AylaSheetHead;
import '../lib/widgets/messages_tabs.dart' show AylaMessagesTabs;
import '../lib/widgets/quick_messages_sheet.dart';
import '../lib/widgets/wide_messages_sidebar.dart';

AylaConversationSummary _conv(String id, String name, {int unread = 0}) =>
    AylaConversationSummary(
      id: id,
      type: AylaConversationType.private,
      title: '',
      avatar: '',
      unreadCount: unread,
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

  Widget host(
    WidgetTester tester,
    Widget child, {
    Size viewport = const Size(420, 640),
  }) {
    setViewport(tester, viewport);
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

  // ======================= 宽屏消息左列 =======================

  testWidgets('左列：332 玻璃侧栏卡 + 不自身滚动（`scrollable: false`）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaWideMessagesSidebar(
          activeId: 'c2',
          onSelect: (_) {},
          conversations: <AylaConversationSummary>[_conv('c1', '小樱'), _conv('c2', '阿澈')],
        ),
        viewport: const Size(500, 640),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // 宽度权威（量卡片本体：外层会被紧宿主 clamp）
    expect(
      tester.getSize(find.byType(GlassSurface).first).width,
      AylaWideMessagesSidebar.sidebarWidth,
    );
    // 侧栏自身不自滚动 ⇒ 只有各 tab 内容区的滚动视图
    expect(
      find.byType(SingleChildScrollView),
      findsOneWidget,
      reason: 'tabs 固定 + 内容区独立滚动（web `.wide-messages-sidebar` 无 overflow）',
    );
  });

  testWidgets('左列：会话列表渲染 + 选中态（会话列表组件复用）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaWideMessagesSidebar(
          activeId: 'c1',
          onSelect: (_) {},
          conversations: <AylaConversationSummary>[
            _conv('c1', '小樱', unread: 2),
            _conv('c2', '阿澈'),
          ],
        ),
        viewport: const Size(500, 640),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('小樱'), findsOneWidget);
    expect(find.text('阿澈'), findsOneWidget);
    expect(find.text('2'), findsOneWidget, reason: '未读徽标');
  });

  testWidgets('左列：好友 tab（好友行 + 「解除中…」档 + 空态）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaWideMessagesSidebar(
          activeId: null,
          initialTab: 'friends',
          onSelect: (_) {},
          friendList: const <AylaUserPublic>[
            AylaUserPublic(id: 'u1', nickname: '小樱', username: 'sakura'),
            AylaUserPublic(id: 'u2', nickname: '阿澈', username: 'ache'),
          ],
          removingFriendId: 'u2',
          onOpenUserChat: (_) {},
          onRemoveFriend: (_) {},
        ),
        viewport: const Size(500, 640),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('小樱'), findsOneWidget);
    expect(find.text('解除中…'), findsOneWidget, reason: 'removingFriendId 档');
  });

  testWidgets('左列：认证 tab 渲染传入的面板 + 徽标', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaWideMessagesSidebar(
          activeId: null,
          initialTab: 'requests',
          requestBadge: 4,
          onSelect: (_) {},
          requestsPanel: const Padding(
            padding: EdgeInsets.all(8),
            child: Text('认证面板占位'),
          ),
        ),
        viewport: const Size(500, 640),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('认证面板占位'), findsOneWidget);
    expect(find.text('4'), findsOneWidget, reason: '认证徽标');
  });

  testWidgets('左列：切 tab 触发 onTabChanged 并切换内容', (WidgetTester tester) async {
    final List<String> changes = <String>[];
    await tester.pumpWidget(
      host(
        tester,
        AylaWideMessagesSidebar(
          activeId: null,
          onSelect: (_) {},
          onTabChanged: changes.add,
          conversations: <AylaConversationSummary>[_conv('c1', '小樱')],
          requestsPanel: const Padding(
            padding: EdgeInsets.all(8),
            child: Text('认证面板占位'),
          ),
        ),
        viewport: const Size(500, 640),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('认证消息'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(changes, <String>['requests']);
    expect(find.text('认证面板占位'), findsOneWidget);
  });

  // ======================= 快捷消息栏 =======================

  testWidgets('快捷栏：上 30% 遮罩 + 下 70% 面板 + radius 24 上圆角', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaQuickMessagesSheet(
          onClose: () {},
          privatePanel: const Padding(
            padding: EdgeInsets.all(8),
            child: Text('私信列表占位'),
          ),
        ),
        viewport: const Size(420, 600),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('私信列表占位'), findsOneWidget);
    // ⚠️ 2026-09-24 改：本栏**复用通用弹层配方**（`AylaModalOverlay` + `AylaModalCard`，
    // 与 `AylaCreateSheet` 同源），不再自己拼「30% 遮罩带 + 70% 面板 + ClipRRect」——
    // 那种写法下遮罩只到面板顶边，面板 24px 上圆角切掉的两角会露出未压暗的页面（web 既有 bug）。
    // 复用库内**现成的弹层容器**（与名单弹层同一套）：`AylaModalOverlay` + `AylaModalCard`
    final Finder sheet = find.byType(AylaModalOverlay);
    expect(sheet, findsOneWidget);
    final AylaModalCard modal = tester.widget<AylaModalCard>(
      find.byType(AylaModalCard),
    );
    expect(modal.narrowHeightFactor, AylaQuickMessagesSheet.panelFraction, // 70%
        reason: '`.quick-messages-panel { height: 70% }`');
    expect(modal.narrowRadius, AylaQuickMessagesSheet.panelRadius, // 24
        reason: '`.quick-messages-panel { border-radius: 24px 24px 0 0 }`');
    // 下方弹出的半屏弹层：贴底 + 高 70%
    final Rect card = tester.getRect(find.byType(AylaModalCard));
    expect(card.height, moreOrLessEquals(600 * AylaQuickMessagesSheet.panelFraction, epsilon: 1.5));
    expect(card.bottom, moreOrLessEquals(600, epsilon: 0.5));
    // 遮罩**铺满**（修的就是「遮罩只到面板顶边 ⇒ 上圆角切角露出未压暗页面」）
    final Rect scrim = tester.getRect(
      find.descendant(
        of: find.byType(AylaModalOverlay),
        matching: find.byType(ColoredBox),
      ).first,
    );
    expect(scrim.height, moreOrLessEquals(600, epsilon: 0.5));
    // head 是本件自己的（web 原样）：选项卡 + `.icon-btn-40` 关闭键，**没有标题**
    expect(find.byType(AylaMessagesTabs), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('quick-messages-close')), findsOneWidget);
    expect(find.byType(AylaSheetHead), findsNothing);
  });

  testWidgets('快捷栏：遮罩点击关闭 + 关闭键关闭', (WidgetTester tester) async {
    int closed = 0;
    await tester.pumpWidget(
      host(
        tester,
        AylaQuickMessagesSheet(onClose: () => closed++),
        viewport: const Size(420, 600),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 遮罩在上 30%（点 y = 60，面板从 y=180 起）
    await tester.tapAt(const Offset(200, 60));
    await tester.pump();
    expect(closed, 1, reason: '遮罩点击关闭');

    await tester.tap(find.byKey(const ValueKey<String>('quick-messages-close')));
    await tester.pump();
    expect(closed, 2, reason: '关闭键');
  });

  testWidgets('快捷栏：ESC 关闭（全局键盘监听，web 监听 document）', (WidgetTester tester) async {
    int closed = 0;
    await tester.pumpWidget(
      host(
        tester,
        AylaQuickMessagesSheet(onClose: () => closed++),
        viewport: const Size(420, 600),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closed, 1);
  });

  testWidgets('快捷栏：两档选项卡（tabs padding 0）+ 认证徽标', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaQuickMessagesSheet(onClose: () {}, requestBadge: 7),
        viewport: const Size(420, 600),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('私信'), findsOneWidget);
    expect(find.text('认证消息'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    final AylaMessagesTabs tabs = tester.widget<AylaMessagesTabs>(
      find.byType(AylaMessagesTabs),
    );
    expect(tabs.padding, EdgeInsets.zero, reason: '`.quick-messages-tabs { padding: 0 }`');
  });

  testWidgets('快捷栏：activeChatId 非空 ⇒ 内联私聊面板（不渲染列表）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaQuickMessagesSheet(
          onClose: () {},
          activeChatId: 'c1',
          privateChatPane: const Padding(
            padding: EdgeInsets.all(8),
            child: Text('内联私聊占位'),
          ),
          privatePanel: const Padding(
            padding: EdgeInsets.all(8),
            child: Text('私信列表占位'),
          ),
        ),
        viewport: const Size(420, 600),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('内联私聊占位'), findsOneWidget);
    expect(find.text('私信列表占位'), findsNothing, reason: '内联态替换列表态');
  });
}
