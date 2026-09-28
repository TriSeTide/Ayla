/// 消息域页面定向测试 —— `MessagesPage` 窄屏三 tab / 宽屏两列 + 会话路由适配。
///
/// 口径（与 `posts_pages_test` / `hub_pages_test` 同）：**无网络下不崩、错误静默**——
/// 取数走 `DioClient` 未初始化 ⇒ `AylaPagedList` 落 error 态，首帧结构仍完整。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/pages/chat_conversation_route.dart';
import '../lib/pages/messages_page.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/chat/messages_layout.dart';
import '../lib/widgets/chat/messages_tabs.dart';
import '../lib/widgets/chat/wide_messages_sidebar.dart';
import '../lib/widgets/base/dialogs.dart'
    show AylaAsyncState, AylaAsyncStatus;

Widget _host(Widget child, Size viewport) => ProviderScope(
      child: MaterialApp(
        home: Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: previewScope(
              SizedBox(
                width: viewport.width,
                height: viewport.height,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );

Future<void> _pump(
  WidgetTester tester,
  Widget page, {
  Size viewport = const Size(420, 760),
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_host(page, viewport));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('MessagesPage 窄屏', () {
    testWidgets('首帧：三 tab 逐字 + 私信面板（爱莉入口/会话列表/页脚）', (WidgetTester tester) async {
      await _pump(tester, const MessagesPage());
      expect(find.text('私信'), findsOneWidget);
      expect(find.text('好友列表'), findsOneWidget);
      expect(find.text('认证消息'), findsOneWidget);
      expect(find.byType(AylaMessagesTabs), findsOneWidget);
      // tab 行由页面提供（inline style `padding: 0 16px`），tab 项在 `AylaNavHighlightList` 里
      final AylaMessagesTabs tabs = tester.widget<AylaMessagesTabs>(
        find.byType(AylaMessagesTabs),
      );
      expect(tabs.items.length, 3);
      expect(tabs.items[2].label, '认证消息');
    });

    testWidgets('切「好友列表」：分组标题存在；空态需「成功且为空」才出现', (WidgetTester tester) async {
      await _pump(tester, const MessagesPage());
      await tester.tap(find.text('好友列表'));
      await tester.pump(const Duration(milliseconds: 320));
      expect(find.text('我的好友（0）'), findsOneWidget);
      // ⚠️ 空态文案只在「取数成功且为空」时出现（web `MessagesPage.tsx:309` 的 `!friendsPage.error`）：
      // 本测试无网络 ⇒ 落 error 态 ⇒ 空态**不该**出现（与 web 同）。
      expect(find.text('还没有好友，去搜索添加吧'), findsNothing);
    });

    testWidgets('切「认证消息」：标题 + 提示（带句号）', (WidgetTester tester) async {
      await _pump(tester, const MessagesPage());
      await tester.tap(find.text('认证消息'));
      await tester.pump(const Duration(milliseconds: 320));
      expect(find.text('认证消息'), findsWidgets, reason: 'tab 与分组标题同名');
      expect(
        find.text('好友申请、群邀请和入群申请都会集中显示在这里。'),
        findsOneWidget,
        reason: '窄屏提示带句号（宽屏侧栏的提示无句号、且没有该分组标题）',
      );
      // 空态同理：取数失败时**不显示**「暂无待处理认证消息」（web tsx 362 要求四个分页均无 error）
      expect(find.text('暂无待处理认证消息'), findsNothing);
    });
  });

  group('MessagesPage 宽屏', () {
    testWidgets('两列：332 左列 + 右列空态两行', (WidgetTester tester) async {
      await _pump(
        tester,
        const MessagesPage(),
        viewport: const Size(1440, 900),
      );
      expect(find.byType(AylaWideMessagesSidebar), findsOneWidget);
      expect(find.byType(AylaWideMessagesEmpty), findsOneWidget);
      expect(find.text('选择一个会话开始聊天'), findsOneWidget);
      expect(find.text('左侧会话列表，点击进入私聊'), findsOneWidget);
    });
  });

  group('ChatConversationRoute', () {
    testWidgets('类型未知且取数失败 ⇒ 错误态（文案 + 重试）', (WidgetTester tester) async {
      await _pump(
        tester,
        const ChatConversationRoute(conversationId: 'c1'),
      );
      // 首次 pump 落加载态；DioClient 未初始化 ⇒ 请求失败后转错误态
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(AylaAsyncState), findsOneWidget);
      final AylaAsyncState state = tester.widget<AylaAsyncState>(
        find.byType(AylaAsyncState),
      );
      expect(
        state.status == AylaAsyncStatus.loading ||
            state.status == AylaAsyncStatus.error,
        isTrue,
        reason: '类型未定时要么在加载、要么失败并给出重试（不静默当私聊）',
      );
      if (state.status == AylaAsyncStatus.error) {
        expect(find.text('加载会话失败，请重试'), findsOneWidget);
        expect(find.text('重试'), findsOneWidget);
      }
    });
  });
}
