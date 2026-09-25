/// B3 chat 第四批：消息中心选项卡 + 认证消息面板 + 私聊面板定向测试。
///
/// 对照：`messages.css` 17–205 / `auroraqua.css` 273–285、402–410 / `private.css` 8–64、
/// `WideMessagesSidebar.tsx`、`QuickMessagesSheet.tsx`、`PrivateChatPane.tsx`。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/chat_message.dart';
import '../lib/core/models/conversation.dart';
import '../lib/core/models/social_requests.dart';
import '../lib/core/models/user_public.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/sample_media.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/message_input.dart';
import '../lib/widgets/messages_tabs.dart';
import '../lib/widgets/primitives.dart' show AylaNavHighlight;
import '../lib/widgets/private_chat_pane.dart';
import '../lib/widgets/request_rows.dart';
import '../lib/widgets/tab_badge.dart';

AylaUserPublic _u(String id, String name, {bool online = false}) =>
    AylaUserPublic(id: id, nickname: name, username: 'user_$id', online: online);

AylaChatMessage _msg(String id, int seq, String sender, String text) =>
    AylaChatMessage(
      id: id,
      conversationId: 'c1',
      senderId: sender,
      type: AylaMessageType.text,
      content: text,
      status: AylaMessageStatus.sent,
      seq: seq,
      createdAt: DateTime(2026, 9, 24, 21, 30).toUtc().toIso8601String(),
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
    Size viewport = const Size(420, 700),
  }) {
    setViewport(tester, viewport);
    return MaterialApp(
      home: previewTheme(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: viewport.width, child: child),
            ),
          ),
        ),
      ),
    );
  }

  // ======================= 模型（api/types.ts） =======================

  group('社交认证模型（types.ts:117–1400）', () {
    test('FriendRequest.fromJson：字段逐条对应；未知 status 保持 null', () {
      final AylaFriendRequest r = AylaFriendRequest.fromJson(<String, dynamic>{
        'id': 7,
        'from_user': <String, dynamic>{'id': 'u1', 'nickname': '小樱', 'username': 'sakura'},
        'to_user': <String, dynamic>{'id': 'me', 'nickname': '我'},
        'message': '加个好友吧',
        'status': 'pending',
        'created_at': '2026-09-24T13:30:00Z',
      });
      expect(r.id, '7');
      expect(r.fromUser.displayName, '小樱');
      expect(r.toUser?.id, 'me');
      expect(r.message, '加个好友吧');
      expect(r.status, 'pending');

      final AylaFriendRequest odd = AylaFriendRequest.fromJson(<String, dynamic>{
        'id': 8,
        'from_user': <String, dynamic>{'id': 'u2'},
        'status': 'weird',
      });
      expect(odd.status, 'weird', reason: '原样保留，不猜、不归一化');
      expect(odd.toUser, isNull);
    });

    test('GroupInvite / GroupJoinRequest / LeaveNotice.fromJson', () {
      final AylaGroupInvite invite = AylaGroupInvite.fromJson(<String, dynamic>{
        'id': 1,
        'conversation_title': '桌游小组',
        'inviter': <String, dynamic>{'id': 'u2', 'nickname': '阿澈'},
      });
      expect(invite.conversationTitle, '桌游小组');
      expect(invite.inviter.displayName, '阿澈');

      final AylaGroupJoinRequest join = AylaGroupJoinRequest.fromJson(<String, dynamic>{
        'id': 2,
        'conversation_title': '摄影交流',
        'applicant': <String, dynamic>{'id': 'u3', 'nickname': '林深'},
        'message': '想进来学习',
      });
      expect(join.applicant.displayName, '林深');
      expect(join.message, '想进来学习');

      final AylaGroupMemberLeaveNotice notice =
          AylaGroupMemberLeaveNotice.fromJson(<String, dynamic>{
        'id': 3,
        'conversation_title': '深夜电台群',
        'member_name': '小林',
      });
      expect(notice.conversationTitle, '深夜电台群');
      expect(notice.memberName, '小林');
    });

    test('AylaSocialPage：空态与「是否渲染」判定口径', () {
      const AylaSocialPage<int> empty = AylaSocialPage<int>();
      expect(empty.isEmptyState, isTrue);
      expect(empty.shouldRender, isFalse);

      const AylaSocialPage<int> loading = AylaSocialPage<int>(loading: true);
      expect(loading.isEmptyState, isFalse, reason: 'loading 中不算空态');
      expect(loading.shouldRender, isTrue);

      const AylaSocialPage<int> errored = AylaSocialPage<int>(error: '失败');
      expect(errored.shouldRender, isTrue);

      const AylaSocialPage<int> more = AylaSocialPage<int>(hasMore: true);
      expect(more.shouldRender, isTrue, reason: 'hasMore 时也要渲染分组（含加载键）');
    });
  });

  // ======================= 选项卡 =======================

  testWidgets('选项卡：容器只有 1px 边 + radius 16（无外阴影/无底色）+ margin sp2 / padding sp1', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessagesTabs(
          value: 'chat',
          onChange: (_) {},
          items: const <AylaMessagesTabItem>[
            AylaMessagesTabItem(key: 'chat', label: '私信'),
            AylaMessagesTabItem(key: 'friends', label: '好友'),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    final Finder box = find
        .ancestor(
          of: find.text('私信'),
          matching: find.byWidgetPredicate(
            (Widget w) =>
                w is Container &&
                w.decoration is BoxDecoration &&
                (w.decoration! as BoxDecoration).border != null,
          ),
        )
        .first;
    final Container container = tester.widget<Container>(box);
    final BoxDecoration deco = container.decoration! as BoxDecoration;
    expect(
      (deco.border! as Border).top.color,
      AylaColors.glassBorder,
      reason: '1px `--glass-border`',
    );
    expect(deco.borderRadius, BorderRadius.circular(AylaRadii.rCard));
    expect(deco.boxShadow, isNull, reason: 'web 未声明 box-shadow ⇒ 无外阴影（只有 --glass-inset 内高光）');
    expect(deco.color, isNull, reason: 'web 未声明 background ⇒ 容器透明，底归胶囊');
    expect(
      container.margin,
      const EdgeInsets.all(AylaSpacing.sp2),
      reason: 'auroraqua 278 `margin: sp2`',
    );
    expect(container.padding, const EdgeInsets.all(AylaSpacing.sp1));
  });

  testWidgets('选项卡：等宽（flex: 1 等价）+ 胶囊 = 选中项；切换后胶囊迁移', (WidgetTester tester) async {
    String value = 'chat';
    late StateSetter setLocal;
    await tester.pumpWidget(
      host(
        tester,
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setter) {
            setLocal = setter;
            return AylaMessagesTabs(
              value: value,
              onChange: (String v) => setLocal(() => value = v),
              items: const <AylaMessagesTabItem>[
                AylaMessagesTabItem(key: 'chat', label: '私信'),
                AylaMessagesTabItem(key: 'friends', label: '好友'),
                AylaMessagesTabItem(key: 'requests', label: '认证消息'),
              ],
            );
          },
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    final Rect first = tester.getRect(find.byType(AylaNavHighlight));
    final Rect tab1 = tester.getRect(find.text('私信'));
    final Rect tab2 = tester.getRect(find.text('好友'));
    // 三档等宽：相邻 tab 文本中心间隔应一致（容 1px）
    final Rect tab3 = tester.getRect(find.text('认证消息'));
    expect(
      (tab2.center.dx - tab1.center.dx),
      moreOrLessEquals(tab3.center.dx - tab2.center.dx, epsilon: 1.5),
      reason: '`flex: 1` ⇒ 等宽',
    );
    expect(first.top, lessThan(tab1.top), reason: '胶囊铺满槽位（含内边距）');

    setLocal(() => value = 'requests');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final Rect third = tester.getRect(find.byType(AylaNavHighlight));
    expect(third.left, greaterThan(first.left), reason: '切换到第三档');
  });

  testWidgets('选项卡：徽标用 TabBadgeMetrics.messages（min 18 / utility 11）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaMessagesTabs(
          value: 'requests',
          onChange: (_) {},
          items: const <AylaMessagesTabItem>[
            AylaMessagesTabItem(key: 'chat', label: '私信'),
            AylaMessagesTabItem(key: 'requests', label: '认证消息', badge: 5),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('5'), findsOneWidget);
    final TabBadge badge = tester.widget<TabBadge>(find.byType(TabBadge));
    expect(badge.metrics, TabBadgeMetrics.messages);
    expect(tester.getSize(find.byType(TabBadge)).height, 18);
  });

  // ⚠️ 2026-09-25：「选项卡窄屏档（竖排 + 宽 260）」用例**已删** —— 该档本来就不存在
  // （用户实报「消息中心选项卡根本没有这样的窄屏档」）：它对应的 web 规则是
  // `.messages-page` 的**宽屏消息页版式**（messages.css 211–227，`@media (min-width: 769px)`），
  // 而 `.wide-messages-sidebar .messages-tabs`（259–263）又把它覆写回横排 ⇒ 组件只有横排一档。

  // ======================= 认证面板 =======================

  testWidgets('认证面板：四分组标题 + 行结构（头像 36 / 名称 / 留言 / 同意·拒绝）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaRequestsPanel(
          sectionHint: '好友申请、群邀请和入群申请',
          onFriendAction: (_, __) {},
          friendRequests: AylaSocialPage<AylaFriendRequest>(
            items: <AylaFriendRequest>[
              AylaFriendRequest(
                id: 'f1',
                fromUser: _u('u1', '小樱', online: true),
                message: '我是小樱',
                status: 'pending',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('好友申请、群邀请和入群申请'), findsOneWidget);
    expect(find.text('好友申请'), findsOneWidget);
    expect(find.text('小樱'), findsOneWidget);
    expect(find.text('我是小樱'), findsOneWidget);
    expect(find.text('同意'), findsOneWidget);
    expect(find.text('拒绝'), findsOneWidget);
    expect(find.text('暂无待处理认证消息'), findsNothing, reason: '有数据 ⇒ 不显示空态');
  });

  testWidgets('认证面板：行材质走 GlassSurface（glass-bg + compact 阴影 + radius 12）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaRequestsPanel(
          onFriendAction: (_, __) {},
          friendRequests: AylaSocialPage<AylaFriendRequest>(
            items: <AylaFriendRequest>[
              AylaFriendRequest(id: 'f1', fromUser: _u('u1', '小樱')),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final GlassSurface surface = tester.widget<GlassSurface>(
      find.ancestor(
        of: find.text('小樱'),
        matching: find.byType(GlassSurface),
      ).first,
    );
    expect(surface.radius, AylaRadii.rInput, reason: 'radius-input 12');
    expect(surface.shadow, AylaShadows.compact);
  });

  testWidgets('认证面板：同意/拒绝回调带 accept 布尔；busy 时禁用', (WidgetTester tester) async {
    final List<bool> calls = <bool>[];
    await tester.pumpWidget(
      host(
        tester,
        AylaRequestsPanel(
          onFriendAction: (AylaFriendRequest r, bool accept) => calls.add(accept),
          friendRequests: AylaSocialPage<AylaFriendRequest>(
            items: <AylaFriendRequest>[
              AylaFriendRequest(id: 'f1', fromUser: _u('u1', '小樱')),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('同意'));
    await tester.pump();
    await tester.tap(find.text('拒绝'));
    await tester.pump();
    expect(calls, <bool>[true, false]);
  });

  testWidgets('认证面板：全空 ⇒ 空态文案', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(tester, const AylaRequestsPanel()),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('暂无待处理认证消息'), findsOneWidget);
  });

  testWidgets('好友行：解除好友键可点（removing 时禁用 + 文案变化）', (WidgetTester tester) async {
    int removed = 0;
    await tester.pumpWidget(
      host(
        tester,
        AylaFriendRow(
          user: _u('u1', '小樱', online: true),
          online: true,
          onOpenChat: () {},
          onRemove: () => removed++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('解除好友'));
    await tester.pump();
    expect(removed, 1);
  });

  testWidgets('好友行：removing 时文案为「解除中…」', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaFriendRow(
          user: _u('u1', '小樱'),
          onOpenChat: () {},
          onRemove: () {},
          removing: true,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('解除中…'), findsOneWidget);
  });

  // ======================= 私聊面板 =======================

  testWidgets('私聊面板：三段结构（头部 56 高 / 消息区 / 输入区）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaPrivateChatPane(
          conversation: AylaConversationSummary(
            id: 'c1',
            type: AylaConversationType.private,
            title: '',
            avatar: '',
            peer: _u('u2', '小樱', online: true),
          ),
          messages: <AylaChatMessage>[_msg('a', 1, 'u2', '睡了吗？')],
          currentUserId: 'me',
          peerOnline: true,
          peerStatus: '在线',
          onMarkRead: (_, __) async {},
          composer: AylaMessageInput(onSubmit: (_) {}, draftKey: 'k'),
        ),
        viewport: const Size(420, 700),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('小樱'), findsOneWidget);
    expect(find.text('在线'), findsOneWidget);
    expect(find.text('睡了吗？'), findsOneWidget);
    expect(find.text('发送'), findsOneWidget, reason: '输入区在面板内');
    expect(
      tester.getSize(
        find.ancestor(of: find.text('小樱'), matching: find.byType(SizedBox)).first,
      ).height,
      AylaPrivateChatPane.headHeight,
      reason: '`.private-chat-head { height: 56px }`',
    );
  });

  testWidgets('私聊面板：typing 时状态行换成「对方正在输入…」并用 glow-500', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaPrivateChatPane(
          conversation: AylaConversationSummary(
            id: 'c1',
            type: AylaConversationType.private,
            title: '',
            avatar: '',
            peer: _u('u2', '小樱'),
          ),
          messages: const <AylaChatMessage>[],
          currentUserId: 'me',
          peerStatus: '在线',
          peerTyping: true,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('对方正在输入…'), findsOneWidget);
    expect(find.text('在线'), findsNothing, reason: 'typing 替换状态行（不加高顶栏）');
    final Text status = tester.widget<Text>(find.text('对方正在输入…'));
    expect(status.style!.color, AylaColors.glow500, reason: '`.is-typing { color: var(--glow-500) }`');
  });

  testWidgets('私聊面板：非好友禁发 ⇒ 提示替换输入区（warning-soft 底）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaPrivateChatPane(
          conversation: AylaConversationSummary(
            id: 'c1',
            type: AylaConversationType.private,
            title: '',
            avatar: '',
            peer: _u('u2', '小樱'),
          ),
          messages: <AylaChatMessage>[_msg('a', 1, 'u2', '在吗')],
          currentUserId: 'me',
          blocked: true,
          composer: AylaMessageInput(onSubmit: (_) {}, draftKey: 'k'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('对方已不是你的好友，无法发送消息'), findsOneWidget);
    expect(find.text('发送'), findsNothing, reason: '禁发时输入区被替换');
  });

  testWidgets('私聊面板：窄屏头部通栏方角 + 返回键', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaPrivateChatPane(
          conversation: AylaConversationSummary(
            id: 'c1',
            type: AylaConversationType.private,
            title: '',
            avatar: '',
            peer: _u('u2', '小樱'),
          ),
          messages: const <AylaChatMessage>[],
          currentUserId: 'me',
          narrow: true,
          onBack: () {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final GlassSurface narrowHead = tester.widget<GlassSurface>(
      find.byType(GlassSurface).first,
    );
    expect(narrowHead.radiusOverride, BorderRadius.zero, reason: '窄屏通栏无圆角');
    expect(
      find.byKey(const ValueKey<String>('private-chat-back')),
      findsOneWidget,
      reason: '窄屏有返回键（测试默认不开语义树，用件自带 key 定位）',
    );
  });

  testWidgets('私聊面板：宽屏头部卡片化（radius 16 + compact 阴影）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaPrivateChatPane(
          conversation: AylaConversationSummary(
            id: 'c1',
            type: AylaConversationType.private,
            title: '',
            avatar: '',
            peer: _u('u2', '小樱'),
          ),
          messages: const <AylaChatMessage>[],
          currentUserId: 'me',
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final GlassSurface wideHead = tester.widget<GlassSurface>(
      find.byType(GlassSurface).first,
    );
    expect(wideHead.radius, AylaRadii.rCard, reason: '宽屏卡片化 radius 16');
    expect(wideHead.shadow, AylaShadows.compact);
    expect(
      find.byKey(const ValueKey<String>('private-chat-back')),
      findsNothing,
      reason: '宽屏两列不渲染返回键',
    );
  });
}
