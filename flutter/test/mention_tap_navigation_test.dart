/// @ 提及胶囊点击导航回归锁（2026-11-04，用户可见缺陷）。
///
/// ## 现象
/// 群聊/私聊消息里的 @ 胶囊**显示成可点按钮**（`SystemMouseCursors.click` +
/// `Semantics(button: true)`），但**点了完全没反应**；web 端点击是能进个人主页的。
///
/// ## 根因（结构性）
/// `AylaMediaContent.onMentionTap` / `AylaMessageBubble.onMentionTap` 在**全仓没有任何
/// 生产调用点传值**，调用链 8 层全是 `widget.onMentionTap` 透传，**最顶层恒 null**
/// ⇒ `_MixedMedia` 里 `_MentionToken(onTap: …widget.onMentionTap?.call(…))` 拿到 null
/// ⇒ `GestureDetector(onTap: null)`：外观仍是按钮，点击无响应。
///
/// ## 修复
/// 接线在 `message_list.dart` 的 `AylaMessageBubble(...)` 构造处（`onMentionTap: _goUserProfile`），
/// 与**同一条消息里的发送者头像** `onSenderClick: () => _goUserProfile(m.senderId)` 完全同构。
///
/// ## web 事实源
/// `components/chat/MediaContent.tsx:428–437`：
/// ```tsx
/// onClick={() => goUserProfile(currentUserId, seg.user_id)}
/// ```
/// 跳转口径 `utils/navigation.ts:24–35`：自己 → `/profile`，他人 → `/user/:id`，空 id 不跳。
///
/// ## 本文件锁的是**真实 tap + 真实路由**
/// 不是「断言参数存在」——参数存在正是修复前也成立的那种假绿（组件层用例
/// `media_content_test.dart:528` 自己喂参数，所以永远绿）。这里从 `AylaMessageList`
/// 这一**生产入口**出发，走 `tester.tap` → 真 `GoRouter` 换页。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/media/media_signer.dart';
import '../lib/core/models/chat_message.dart';
import '../lib/core/models/conversation.dart';
import '../lib/core/models/user_public.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/chat/message_list.dart';

const AylaUserPublic kMe = AylaUserPublic(id: 'me', nickname: '我');
const AylaUserPublic kPeer = AylaUserPublic(id: 'u2', nickname: '汐汐');

/// 群会话：成员 = 我 + 汐汐（真实生产里 `conversation.members` 就长这样）。
const AylaConversationSummary kGroup = AylaConversationSummary(
  id: 'g1',
  type: AylaConversationType.group,
  title: '测试群',
  members: <AylaConversationMember>[
    AylaConversationMember(id: 'm-me', user: kMe),
    AylaConversationMember(id: 'm-u2', user: kPeer),
  ],
);

/// `type: mixed` + 单个 `mention` 段（就是 web 渲染成 `.mention-token` 的那种消息）。
AylaChatMessage mentionMessage({String? userId = 'u2'}) => AylaChatMessage(
      id: 'msg-mention',
      conversationId: kGroup.id,
      senderId: 'u1',
      type: AylaMessageType.mixed,
      content: '',
      segments: <AylaMediaSegment>[
        AylaMediaSegment(
          type: AylaSegmentType.mention,
          userId: userId,
          userNickname: '汐汐',
        ),
      ],
      status: AylaMessageStatus.sent,
      seq: 1,
      createdAt: '2026-11-04T10:00:00Z',
    );

void main() {
  setUp(() => MediaSigner.instance.detach()); // 隔离：不触真实签名请求
  tearDown(() => MediaSigner.instance.detach());

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// 真 GoRouter 宿主：`/room` 挂 [AylaMessageList]，其余路径渲染成
  /// `route:<location>` 标记文本 —— 断言**真的换了页**，而不只是回调被调用。
  ({GoRouter router, Widget app}) routerHost(
    WidgetTester tester, {
    required String currentUserId,
    required AylaChatMessage message,
  }) {
    const Size viewport = Size(900, 700);
    setViewport(tester, viewport);
    final GoRouter router = GoRouter(
      initialLocation: '/room',
      routes: <RouteBase>[
        GoRoute(
          path: '/room',
          builder: (BuildContext c, GoRouterState s) => previewScope(
            Scaffold(
              body: AylaMessageList(
                messages: <AylaChatMessage>[message],
                currentUserId: currentUserId,
                conversation: kGroup,
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/:rest(.*)',
          builder: (BuildContext c, GoRouterState s) =>
              Scaffold(body: Text('route:${s.uri}')),
        ),
      ],
    );
    final Widget app = ProviderScope(
      child: MaterialApp.router(
        routerConfig: router,
        builder: (BuildContext context, Widget? nav) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: viewport),
          child: nav ?? const SizedBox.shrink(),
        ),
      ),
    );
    return (router: router, app: app);
  }

  /// 走真实触发路径前先让首帧落地（列表是 reverse: true 的懒构建）。
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  group('@ 提及胶囊 → 个人主页（web MediaContent.tsx:428–437）', () {
    testWidgets('★ 点他人 @胶囊 ⇒ 路由到 /user/u2（修复前：点了没反应，停在 /room）',
        (WidgetTester tester) async {
      final ({GoRouter router, Widget app}) host = routerHost(
        tester,
        currentUserId: 'me',
        message: mentionMessage(),
      );
      await tester.pumpWidget(host.app);
      await settle(tester);

      // 前提：胶囊确实渲染成了按钮外观（这是「看起来能点」的来源，
      // 也是修复前仍然成立的部分 —— 所以必须点它，不能只断言它存在）。
      expect(find.text('@汐汐'), findsOneWidget, reason: 'mention 段必须渲染成胶囊');
      expect(find.text('route:/room'), findsNothing,
          reason: '/room 是列表页，标记文本只出现在跳转后的目标页');

      await tester.tap(find.text('@汐汐'));
      await tester.pumpAndSettle();

      expect(find.text('route:/user/u2'), findsOneWidget,
          reason: '他人 @胶囊必须 push 到 /user/<id>（web goUserProfile 的他人分支）');
    });

    testWidgets('★ @ 的是自己 ⇒ 路由到 /profile（web 自己分支）',
        (WidgetTester tester) async {
      final ({GoRouter router, Widget app}) host = routerHost(
        tester,
        currentUserId: 'u2',
        message: mentionMessage(userId: 'u2'),
      );
      await tester.pumpWidget(host.app);
      await settle(tester);

      expect(find.text('@汐汐'), findsOneWidget);
      await tester.tap(find.text('@汐汐'));
      await tester.pumpAndSettle();

      expect(find.text('route:/profile'), findsOneWidget,
          reason: 'target == currentUserId ⇒ /profile（navigation.ts:30–32）');
    });

    testWidgets('反向锁：user_id 为空 ⇒ 点击不跳转也不崩（web seg.user_id 空值同义）',
        (WidgetTester tester) async {
      final ({GoRouter router, Widget app}) host = routerHost(
        tester,
        currentUserId: 'me',
        message: mentionMessage(userId: null),
      );
      await tester.pumpWidget(host.app);
      await settle(tester);

      expect(find.text('@汐汐'), findsOneWidget);
      await tester.tap(find.text('@汐汐'));
      await tester.pumpAndSettle();

      // 不跳：仍在 /room（列表页），且没有落到任何 route: 标记页。
      expect(find.byType(AylaMessageList), findsOneWidget,
          reason: '空 user_id 不得触发导航');
      expect(find.textContaining('route:'), findsNothing,
          reason: '不得跳到任何目标页（_goUserProfile 的 target 空缺早退）');
    });
  });
}
