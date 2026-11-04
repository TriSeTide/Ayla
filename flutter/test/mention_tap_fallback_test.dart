/// @ 提及胶囊「组件自带导航回退」回归锁（2026-11-04，第三次同款缺口收口）。
///
/// ## 背景：同一个缺陷形态已经出现三次
/// 1. `AylaMessageList` —— 主聊天链路（task-3 修复：`onMentionTap: _goUserProfile`）；
/// 2. `directory_result_cards.dart:411` 的收藏/搜索「消息卡」—— 只传了 `currentUserId`，
///    没传 `onMentionTap`（本任务修复）；
/// 3. 将来任何新的 `AylaMediaContent` 调用点。
///
/// 根因是**结构性的**：Flutter 侧把导航完全推给上层回调，而 web 的
/// `components/chat/MediaContent.tsx:428–437` 是组件**自己**调
/// `goUserProfile(currentUserId, seg.user_id)`（`currentUserId` 由组件自己
/// `useAuthStore` 取，`:379`），**不依赖父级注入**。
///
/// ## 修复语义（本文件锁的就是它）
/// `AylaMediaContent` 内部 **回调优先**：
/// · 传了 `onMentionTap` ⇒ 只走回调（已接线调用点行为一字不变，**不会两条路都跳**）；
/// · 没传 ⇒ `_fallbackGoUserProfile` 用 `GoRouter.maybeOf` 自己跳（对齐 web）。
///
/// ## 为什么不能用 `media_content_test.dart` 兜底
/// 那个文件的 mention 用例（`:528`）**自己给组件喂 `onMentionTap`** 再断言回调被调
/// ⇒ 修复前也绿，永远发现不了「调用点没传」。本文件刻意**不传**回调，锁回退路径。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/media/media_signer.dart';
import '../lib/core/models/chat_message.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/chat/media_content.dart';

/// `type: mixed` + 单个 `mention` 段（web 渲染成 `.mention-token` 的那种消息）。
AylaChatMessage mentionMessage({
  String id = 'msg-mention',
  String? userId = 'u2',
  String nickname = '汐汐',
}) =>
    AylaChatMessage(
      id: id,
      conversationId: 'c1',
      senderId: 'u1',
      type: AylaMessageType.mixed,
      content: '',
      segments: <AylaMediaSegment>[
        AylaMediaSegment(
          type: AylaSegmentType.mention,
          userId: userId,
          userNickname: nickname,
        ),
      ],
      status: AylaMessageStatus.sent,
      seq: 1,
      createdAt: '2026-11-04T10:00:00Z',
    );

void main() {
  setUp(() => MediaSigner.instance.detach()); // 隔离：不触真实签名请求
  tearDown(() => MediaSigner.instance.detach());

  /// 真 GoRouter 宿主：`/room` 挂被测组件，其余路径渲染 `route:<uri>` 标记文本
  /// —— 断言**真的换了页**，而不只是「某个回调被调用」。
  Widget routerHost(
    WidgetTester tester,
    Widget child, {
    Size viewport = const Size(900, 700),
  }) {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final GoRouter router = GoRouter(
      initialLocation: '/room',
      routes: <RouteBase>[
        GoRoute(
          path: '/room',
          builder: (BuildContext c, GoRouterState s) => previewScope(
            Scaffold(
              body: Center(
                child: SizedBox(width: 600, child: child),
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
    return MaterialApp.router(
      routerConfig: router,
      builder: (BuildContext context, Widget? nav) => MediaQuery(
        data: MediaQuery.of(context).copyWith(size: viewport),
        child: nav ?? const SizedBox.shrink(),
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  group('AylaMediaContent 自带导航回退（web MediaContent.tsx:428–437）', () {
    testWidgets('★ 不传 onMentionTap ⇒ 组件自己跳 /user/u2（directory_result_cards 那条支线）',
        (WidgetTester tester) async {
      await tester.pumpWidget(routerHost(
        tester,
        AylaMediaContent(
          // 刻意**不传** onMentionTap —— 复现收藏/搜索消息卡的调用形态
          currentUserId: 'me',
          msg: mentionMessage(),
        ),
      ));
      await settle(tester);

      expect(find.text('@汐汐'), findsOneWidget, reason: 'mention 段必须渲染成胶囊');
      expect(find.textContaining('route:'), findsNothing, reason: '点击前不应有任何跳转');

      await tester.tap(find.text('@汐汐'));
      await tester.pumpAndSettle();

      expect(find.text('route:/user/u2'), findsOneWidget,
          reason: '未注入回调时必须由组件自己 push /user/<id>（web goUserProfile 他人分支）');
    });

    testWidgets('★ 不传回调 + currentUserId == seg.userId ⇒ 组件自己跳 /profile',
        (WidgetTester tester) async {
      await tester.pumpWidget(routerHost(
        tester,
        AylaMediaContent(
          currentUserId: 'u2',
          msg: mentionMessage(userId: 'u2'),
        ),
      ));
      await settle(tester);

      await tester.tap(find.text('@汐汐'));
      await tester.pumpAndSettle();

      expect(find.text('route:/profile'), findsOneWidget,
          reason: 'target == currentUserId ⇒ /profile（navigation.ts:30–32）');
    });

    testWidgets('★ 回调优先：传了 onMentionTap ⇒ 只走回调，**不**触发路由（防两条路都跳）',
        (WidgetTester tester) async {
      final List<String> tapped = <String>[];
      await tester.pumpWidget(routerHost(
        tester,
        AylaMediaContent(
          currentUserId: 'me',
          onMentionTap: tapped.add,
          msg: mentionMessage(),
        ),
      ));
      await settle(tester);

      await tester.tap(find.text('@汐汐'));
      await tester.pumpAndSettle();

      expect(tapped, <String>['u2'], reason: '回调必须收到被点的 userId');
      expect(find.textContaining('route:'), findsNothing,
          reason: '注入回调时组件**不得**再自己跳（否则已接线的 message_list 会双跳）');
      expect(find.text('@汐汐'), findsOneWidget, reason: '仍停在原页');
    });

    testWidgets('反向锁：seg.userId 为空 ⇒ 胶囊不可点、不跳、不崩（web 空 id 早退同义）',
        (WidgetTester tester) async {
      await tester.pumpWidget(routerHost(
        tester,
        AylaMediaContent(
          currentUserId: 'me',
          msg: mentionMessage(userId: null),
        ),
      ));
      await settle(tester);

      expect(find.text('@汐汐'), findsOneWidget);
      await tester.tap(find.text('@汐汐'));
      await tester.pumpAndSettle();

      expect(find.textContaining('route:'), findsNothing,
          reason: '空 user_id 不得触发导航（_fallbackGoUserProfile 的 target 空缺早退）');
      expect(find.text('@汐汐'), findsOneWidget, reason: '不崩、仍在原页');
    });

    testWidgets('无 GoRouter 宿主 ⇒ 静默 no-op，不抛（web 未注册 bridge 时同款）',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: previewScope(
            Center(
              child: SizedBox(
                width: 600,
                child: AylaMediaContent(
                  currentUserId: 'me',
                  msg: mentionMessage(),
                ),
              ),
            ),
          ),
        ),
      );
      await settle(tester);

      await tester.tap(find.text('@汐汐'));
      await tester.pumpAndSettle();
      // 没崩 = 通过（GoRouter.maybeOf 返回 null ⇒ 早退）
      expect(find.text('@汐汐'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
