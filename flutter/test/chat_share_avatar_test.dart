/// 聊天域接线回归锁（2026-10-21）：分享卡跳转 / 头像单击 / 头像长按 @。
///
/// | 本组 | web 事实源 |
/// |---|---|
/// | 【1】分享卡六类目标分流（群内/群外）+ /group 走 go、其余 push | components/chat/ShareBubble.tsx:75-94、utils/shareRoutes.ts:43-83 / 118-129 |
/// | 【2】头像单击 250ms -> `/user/:id`；自己 -> `/profile` | components/chat/MessageList.tsx:1067、utils/navigation.ts:25-35 |
/// | 【3】双击头像 -> poke 且不跳转 | components/chat/MessageBubble.tsx:178-208 |
/// | 【4】长按 500ms -> onMentionSender，随后 tap 不跳转 | MessageBubble.tsx:146-176、GroupChat.tsx:249-251 |
/// | 【5】AylaMessageInputController.insertMention 真的插入 @token | GroupChat.tsx:250 |
/// | 【6】fromShare 生命周期：切场景丢 URL query 后仍免白名单；换群重置 | GroupVoice.tsx:25/90/96/127、group_page.dart:541/550（go 不带 query） |
///
/// 纪律：**不起网络**。分享卡的群内存在性检查用注入的 onResolveTarget，
/// 路由用最小 GoRouter stub（只关心 go / push 的落点与历史栈）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/api/voice_api.dart' show AylaVoiceChannelSnapshot;
import '../lib/core/models/chat_message.dart';
import '../lib/core/models/conversation.dart';
import '../lib/core/models/share_payload.dart';
import '../lib/core/models/user_public.dart';
import '../lib/pages/group_voice_page.dart' show GroupVoicePage;
import '../lib/pages/group_live_page.dart' show GroupLivePage;
import '../lib/state/room_providers.dart' show liveStateProvider, voiceStateProvider;
import '../lib/widgets/live/live_channel_snapshot.dart' show AylaLiveChannelSnapshot;
import '../lib/theme/app_theme.dart' show buildAylaTheme;
import '../lib/theme/preview_theme.dart';
import '../lib/theme/sample_media.dart';
import '../lib/widgets/base/avatar_halo.dart';
import '../lib/widgets/chat/message_bubble.dart';
import '../lib/widgets/chat/message_input.dart';
import '../lib/widgets/chat/message_list.dart';
import '../lib/widgets/chat/share_bubble.dart';
import '../lib/widgets/voice/voice_room_body.dart' show AylaVoiceRoomBody;

// ======================= 夹具 =======================

AylaChatMessage _shareMsg({
  String id = 's1',
  AylaSharePayload? payload,
  String content = '',
}) =>
    AylaChatMessage(
      id: id,
      conversationId: 'g1',
      senderId: 'u1',
      type: AylaMessageType.share,
      content: content,
      sharePayload: payload,
      status: AylaMessageStatus.sent,
      seq: 1,
      createdAt: '2026-10-21T10:00:00Z',
    );

AylaChatMessage _msg({
  String id = 'm1',
  String senderId = 'u1',
  String content = '在吗',
}) =>
    AylaChatMessage(
      id: id,
      conversationId: 'g1',
      senderId: senderId,
      type: AylaMessageType.text,
      content: content,
      status: AylaMessageStatus.sent,
      seq: 2,
      createdAt: '2026-10-21T10:01:00Z',
    );

/// 群聊会话（两个成员：群内显示名 / 头像都从这里取）。
AylaConversationSummary _groupConv() => AylaConversationSummary(
      id: 'g1',
      type: AylaConversationType.group,
      title: '深夜电台群',
      members: <AylaConversationMember>[
        // 自己也在成员表里 —— 气泡渲染头像取 _memberAvatars，
        // 缺自己时「自己消息」根本没有头像可点（金标准：web 自己消息也显示头像）。
        AylaConversationMember(
          id: 'm-me',
          user: const AylaUserPublic(id: 'me', nickname: '我', username: 'me'),
        ),
        AylaConversationMember(
          id: 'm-u1',
          user: const AylaUserPublic(id: 'u1', nickname: '汐汐', username: 'xixi'),
        ),
        AylaConversationMember(
          id: 'm-u2',
          user: const AylaUserPublic(id: 'u2', nickname: '小樱', username: 'sakura'),
        ),
      ],
    );

/// 私聊会话（对端 u2）。
AylaConversationSummary _privateConv() => AylaConversationSummary(
      id: 'c1',
      type: AylaConversationType.private,
      title: '',
      members: <AylaConversationMember>[
        AylaConversationMember(
          id: 'm-u1',
          user: const AylaUserPublic(id: 'u1', nickname: '汐汐', username: 'xixi'),
        ),
        // 对端也在成员表里：气泡渲染头像取 _memberAvatars（群/私聊同一条链）。
        AylaConversationMember(
          id: 'm-u2',
          user: const AylaUserPublic(id: 'u2', nickname: '小樱', username: 'sakura'),
        ),
      ],
      peer: const AylaUserPublic(id: 'u2', nickname: '小樱', username: 'sakura'),
    );

// ======================= 路由 stub =======================

/// 记录 go / push 落点的最小 GoRouter（页面体只放可断言的标记 Text）。
class _NavProbe {
  /// 宿主页内容（待测组件挂在这条路由上 —— 这样它在 GoRouter 的上下文里，
  /// `GoRouter.maybeOf(context)` 才拿得到 router）。
  Widget hostPage = const SizedBox.shrink();

  /// 已构建过的路由 location 序列（每个页面 builder 追加一条）。
  ///
  /// 用它断言「跳到了哪」比读 `currentConfiguration.uri` 稳：go_router 的
  /// `currentConfiguration` 在 push 后的更新时机随 pump 阶段变化，而 builder
  /// 被调用是**页面真的挂上**的直接证据。
  final List<String> visited = <String>[];

  Widget _page(GoRouterState s, Widget body) {
    visited.add(s.uri.toString());
    return body;
  }

  _NavProbe() {
    router = GoRouter(
      initialLocation: '/host',
      routes: <RouteBase>[
        GoRoute(
          path: '/host',
          builder: (BuildContext c, GoRouterState s) => _page(s, hostPage),
        ),
        GoRoute(
          path: '/group/:id/:scene',
          builder: (BuildContext c, GoRouterState s) =>
              _page(s, const Text('SCENE')),
        ),
        GoRoute(
          path: '/group/:id/voice/:cid',
          builder: (BuildContext c, GoRouterState s) =>
              _page(s, const Text('VOICE')),
        ),
        GoRoute(
          path: '/group/:id/live/:cid',
          builder: (BuildContext c, GoRouterState s) =>
              _page(s, const Text('LIVE')),
        ),
        GoRoute(
          path: '/group/:id/posts/:pid',
          builder: (BuildContext c, GoRouterState s) =>
              _page(s, const Text('POST')),
        ),
        GoRoute(
          path: '/group/:id',
          builder: (BuildContext c, GoRouterState s) =>
              _page(s, const Text('GROUP')),
        ),
        GoRoute(
          path: '/live/:id',
          builder: (BuildContext c, GoRouterState s) =>
              _page(s, const Text('OUT-LIVE')),
        ),
        GoRoute(
          path: '/voice/:id',
          builder: (BuildContext c, GoRouterState s) =>
              _page(s, const Text('OUT-VOICE')),
        ),
        GoRoute(
          path: '/posts/:id',
          builder: (BuildContext c, GoRouterState s) =>
              _page(s, const Text('OUT-POST')),
        ),
        GoRoute(
          path: '/games/:id',
          builder: (BuildContext c, GoRouterState s) =>
              _page(s, const Text('OUT-GAME')),
        ),
        GoRoute(
          path: '/user/:id',
          builder: (BuildContext c, GoRouterState s) =>
              _page(s, const Text('USER')),
        ),
        GoRoute(
          path: '/profile',
          builder: (BuildContext c, GoRouterState s) =>
              _page(s, const Text('PROFILE')),
        ),
      ],
    );
  }

  late final GoRouter router;

  /// 当前栈顶 location（= 最后一次跳转的完整 URL，含 query）。
  String get location =>
      router.routerDelegate.currentConfiguration.uri.toString();

  /// 历史栈深度（go 不建栈，push 建）。
  int get depth => router.routerDelegate.currentConfiguration.matches.length;
}

void main() {
  setUp(aylaDisableSampleMedia);
  tearDown(aylaDisableSampleMedia);

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// 普通宿主（无 GoRouter —— 走注入回调档）。
  Widget host(
    WidgetTester tester,
    Widget child, {
    Size viewport = const Size(720, 420),
  }) {
    setViewport(tester, viewport);
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: SizedBox(
              width: viewport.width,
              height: viewport.height,
              child: Align(alignment: Alignment.topLeft, child: child),
            ),
          ),
        ),
      ),
    );
  }

  /// 带真实 GoRouter 的宿主（验 go / push 语义与自导航）。
  Widget routerHost(
    WidgetTester tester,
    _NavProbe probe,
    Widget child, {
    Size viewport = const Size(720, 420),
  }) {
    setViewport(tester, viewport);
    probe.hostPage = Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: viewport.width,
        height: viewport.height,
        child: child,
      ),
    );
    // key：每次换 probe 都强制重挂整棵树（避免旧路由状态串场）。
    return MaterialApp.router(
      key: ObjectKey(probe),
      routerConfig: probe.router,
      builder: (BuildContext context, Widget? navigator) =>
          previewScope(navigator ?? const SizedBox.shrink()),
    );
  }

  // ===================== 1. 分享卡六类目标分流 =====================

  group('分享卡：六类目标分流（shareRoutes.ts）', () {
    final Map<AylaShareType, AylaSharePayload> payloads =
        <AylaShareType, AylaSharePayload>{
      AylaShareType.group: const AylaSharePayload(
        shareType: AylaShareType.group,
        targetId: 't1',
        title: '一个群',
      ),
      AylaShareType.voice: const AylaSharePayload(
        shareType: AylaShareType.voice,
        targetId: 't1',
        title: '一个语音房',
      ),
      AylaShareType.live: const AylaSharePayload(
        shareType: AylaShareType.live,
        targetId: 't1',
        title: '一个直播间',
      ),
      AylaShareType.post: const AylaSharePayload(
        shareType: AylaShareType.post,
        targetId: 't1',
        title: '一个帖子',
      ),
      AylaShareType.boardgame: const AylaSharePayload(
        shareType: AylaShareType.boardgame,
        targetId: 't1',
        title: '一个桌游室',
      ),
      AylaShareType.user: const AylaSharePayload(
        shareType: AylaShareType.user,
        targetId: 't1',
        title: '一个用户',
      ),
    };

    /// shareRoutes.ts:43-83 的两张表（群内 / 群外）。
    const Map<AylaShareType, String> inGroup = <AylaShareType, String>{
      AylaShareType.group: '/group/t1',
      AylaShareType.voice: '/group/g1/voice/t1',
      AylaShareType.live: '/group/g1/live/t1',
      AylaShareType.post: '/group/g1/posts/t1',
      AylaShareType.boardgame: '/group/g1/games',
      AylaShareType.user: '/user/t1',
    };
    const Map<AylaShareType, String> outGroup = <AylaShareType, String>{
      AylaShareType.group: '/group/t1',
      AylaShareType.voice: '/voice/t1',
      AylaShareType.live: '/live/t1',
      AylaShareType.post: '/posts/t1',
      AylaShareType.boardgame: '/games/t1',
      AylaShareType.user: '/user/t1',
    };

    for (final AylaShareType type in AylaShareType.values) {
      final String label = type.name;
      testWidgets('$label 群内命中 -> 群内路径（带 fromShare=1）',
          (WidgetTester tester) async {
        String? route;
        await tester.pumpWidget(
          host(
            tester,
            AylaShareBubble(
              msg: _shareMsg(payload: payloads[type]),
              groupId: 'g1',
              // 群分享卡先过「是否已加入」守卫（ShareBubble.tsx:77-86）：
              // 本组只测分流，故显式声明已加入，避免走到申请弹窗分支。
              isGroupJoined: (String id) => true,
              // 群内存在性检查命中（= web resolveShareTarget 的 ids.has 分支）
              onResolveTarget: (AylaSharePayload? p, String? g) async =>
                  inGroup[type],
              onNavigate: (String r) => route = r,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.text(payloads[type]!.title));
        await tester.pump();

        expect(route, isNotNull, reason: '必须跳转');
        final Uri uri = Uri.parse(route!);
        expect(uri.path, inGroup[type]);
        expect(uri.queryParameters['fromShare'], '1',
            reason: '分享跳转必须携带 fromShare（GroupVoice/GroupLive 免白名单的判据）');
      });

      testWidgets('$label 群外 -> 群外路径（带 fromShare=1）',
          (WidgetTester tester) async {
        String? route;
        await tester.pumpWidget(
          host(
            tester,
            AylaShareBubble(
              msg: _shareMsg(payload: payloads[type]),
              groupId: 'g1',
              isGroupJoined: (String id) => true,
              // 群内未命中 => 群外
              onResolveTarget: (AylaSharePayload? p, String? g) async =>
                  outGroup[type],
              onNavigate: (String r) => route = r,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.text(payloads[type]!.title));
        await tester.pump();

        expect(route, isNotNull);
        final Uri uri = Uri.parse(route!);
        expect(uri.path, outGroup[type]);
        expect(uri.queryParameters['fromShare'], '1');
      });
    }

    testWidgets('默认解析（未注入 onResolveTarget）无群上下文 => 群外',
        (WidgetTester tester) async {
      String? route;
      await tester.pumpWidget(
        host(
          tester,
          AylaShareBubble(
            msg: _shareMsg(
              payload: const AylaSharePayload(
                shareType: AylaShareType.live,
                targetId: '9',
                title: '今晚一起看星星',
              ),
            ),
            // 私聊/群外上下文（groupId 为 null）=> 不查目录、直接群外
            onNavigate: (String r) => route = r,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('今晚一起看星星'));
      await tester.pump();

      expect(Uri.parse(route!).path, '/live/9',
          reason: '无群上下文 => outRoute（shareRoutes.ts:128）');
    });

    testWidgets('/group 开头 => go（不建历史栈）', (WidgetTester tester) async {
      final _NavProbe probe = _NavProbe();
      addTearDown(probe.router.dispose);
      await tester.pumpWidget(
        routerHost(
          tester,
          probe,
          AylaShareBubble(
            msg: _shareMsg(
              payload: const AylaSharePayload(
                shareType: AylaShareType.voice,
                targetId: '7',
                title: '深夜电台',
              ),
            ),
            groupId: 'g1',
            isGroupJoined: (String id) => true,
            onResolveTarget: (AylaSharePayload? p, String? g) async =>
                '/group/g1/voice/7',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(probe.visited, <String>['/host'], reason: '初始落宿主页');
      await tester.tap(find.text('深夜电台'));
      await tester.pumpAndSettle();

      expect(probe.visited, contains('/group/g1/voice/7?fromShare=1'),
          reason: '自导航必须带上 fromShare=1（web 的 state.fromShare 等价物）');
      expect(probe.router.canPop(), isFalse,
          reason: '/group/* 五条路由共用固定 Page key => 必须 go，push 会触发 Navigator 断言');
    });

    testWidgets('非 /group 目标 => push（可返回）', (WidgetTester tester) async {
      final _NavProbe probe = _NavProbe();
      addTearDown(probe.router.dispose);
      await tester.pumpWidget(
        routerHost(
          tester,
          probe,
          AylaShareBubble(
            msg: _shareMsg(
              payload: const AylaSharePayload(
                shareType: AylaShareType.live,
                targetId: '9',
                title: '看星星',
              ),
            ),
            onResolveTarget: (AylaSharePayload? p, String? g) async => '/live/9',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('看星星'));
      await tester.pumpAndSettle();

      expect(probe.visited, contains('/live/9?fromShare=1'));
      expect(probe.router.canPop(), isTrue, reason: '非 /group 目标走 push，可返回');
    });
  });

  // ===================== 2. 头像单击 -> 个人主页 =====================

  group('头像单击（MessageList.tsx:1067 / navigation.ts:25-35）', () {
    testWidgets('他人：250ms 后 push /user/<encodeURIComponent(id)>',
        (WidgetTester tester) async {
      final _NavProbe probe = _NavProbe();
      addTearDown(probe.router.dispose);
      await tester.pumpWidget(
        routerHost(
          tester,
          probe,
          AylaMessageList(
            messages: <AylaChatMessage>[_msg(senderId: 'u2', content: '在吗')],
            conversation: _groupConv(),
            currentUserId: 'me',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byType(AylaAvatarHalo).first);
      await tester.pump(const Duration(milliseconds: 200));
      expect(probe.visited, <String>['/host'],
          reason: '单击延迟 250ms（DOUBLE_CLICK_MS）后才跳');
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pumpAndSettle();

      expect(probe.visited, contains('/user/u2'));
      expect(probe.router.canPop(), isTrue, reason: '个人主页走 push（可返回）');
    });

    testWidgets('自己：250ms 后 push /profile', (WidgetTester tester) async {
      final _NavProbe probe = _NavProbe();
      addTearDown(probe.router.dispose);
      await tester.pumpWidget(
        routerHost(
          tester,
          probe,
          AylaMessageList(
            messages: <AylaChatMessage>[_msg(senderId: 'me', content: '我说的')],
            conversation: _groupConv(),
            currentUserId: 'me',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byType(AylaAvatarHalo).first);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(probe.visited, contains('/profile'),
          reason: '自己 => /profile（navigation.ts:30-32）');
    });
  });

  // ===================== 3. 双击 -> poke 且不跳转 =====================

  testWidgets('双击头像：触发 poke，不跳个人主页（MessageBubble.tsx:178-208）',
      (WidgetTester tester) async {
    final _NavProbe probe = _NavProbe();
    addTearDown(probe.router.dispose);
    String? poked;
    await tester.pumpWidget(
      routerHost(
        tester,
        probe,
        AylaMessageList(
          messages: <AylaChatMessage>[_msg(senderId: 'u2', content: '在吗')],
          conversation: _groupConv(),
          currentUserId: 'me',
          onPoke: (String userId) => poked = userId,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byType(AylaAvatarHalo).first);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.byType(AylaAvatarHalo).first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(poked, 'u2', reason: '双击 => 戳被双击的成员');
    expect(probe.visited, <String>['/host'],
        reason: '双击取消挂起的单击 => 不进个人主页（路由从未离开宿主页）');
  });

  // ===================== 4. 长按 500ms -> @ =====================

  testWidgets('长按头像 500ms => onMentionSender，且随后的 tap 不跳转',
      (WidgetTester tester) async {
    final _NavProbe probe = _NavProbe();
    addTearDown(probe.router.dispose);
    String? mentionedId;
    String? mentionedName;
    await tester.pumpWidget(
      routerHost(
        tester,
        probe,
        AylaMessageList(
          messages: <AylaChatMessage>[_msg(senderId: 'u2', content: '在吗')],
          conversation: _groupConv(),
          currentUserId: 'me',
          onMentionSender: (String userId, String name) {
            mentionedId = userId;
            mentionedName = name;
          },
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    await tester.longPress(find.byType(AylaAvatarHalo).first);
    await tester.pump(const Duration(milliseconds: 600));

    expect(mentionedId, 'u2', reason: '长按头像 => @ 该成员（GroupChat.tsx:249-251）');
    expect(mentionedName, '小樱', reason: '显示名来自会话成员表');

    // 长按后紧随的 click 被抑制（MessageBubble.tsx:147 / :193-197）
    await tester.tap(find.byType(AylaAvatarHalo).first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(probe.visited, <String>['/host'],
        reason: '长按触发后抑制 click，不应跳个人主页');
  });

  testWidgets('私聊（未注入 onMentionSender）：长按不触发 @',
      (WidgetTester tester) async {
    final _NavProbe probe = _NavProbe();
    addTearDown(probe.router.dispose);
    await tester.pumpWidget(
      routerHost(
        tester,
        probe,
        AylaMessageList(
          messages: <AylaChatMessage>[_msg(senderId: 'u2', content: '在吗')],
          conversation: _privateConv(),
          currentUserId: 'me',
          // 私聊页面不传 onMentionSender（web 同）
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.longPress(find.byType(AylaAvatarHalo).first);
    await tester.pump(const Duration(milliseconds: 600));
    // canMention 为假 => 长按回调为空，不抛即可
    expect(find.byType(AylaMessageBubble), findsOneWidget);
  });

  // ===================== 5. AylaMessageInputController =====================

  group('AylaMessageInputController（GroupChat.tsx:250 的 inputRef 等价物）', () {
    testWidgets('insertMention 真的把 @token 插入编辑器（草稿序列化为 @[user_id]）',
        (WidgetTester tester) async {
      final List<String> drafts = <String>[];
      final AylaMessageInputController controller =
          AylaMessageInputController();
      await tester.pumpWidget(
        host(
          tester,
          AylaMessageInput(
            onSubmit: (_) {},
            draftKey: 'k',
            groupId: 'g1',
            controller: controller,
            onDraftChanged: (String k, String v) => drafts.add(v),
            members: <AylaConversationMember>[
              AylaConversationMember(
                id: 'm-u2',
                user: const AylaUserPublic(
                  id: 'u2',
                  nickname: '小樱',
                  username: 'sakura',
                ),
              ),
            ],
          ),
          viewport: const Size(760, 700),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      expect(controller.isAttached, isTrue, reason: '输入框挂载即 attach');
      controller.insertMention('u2', '小樱');
      await tester.pump(const Duration(milliseconds: 50));

      expect(drafts.last, '@[u2]',
          reason: '草稿序列化格式跨端一致（utils/mention.ts:39-41）');
      // 编辑器文本层只放单字符占位符（mention_editor.dart 的 placeholder）
      final EditableText editable =
          tester.widget<EditableText>(find.byType(EditableText));
      expect(editable.controller.text, '\uFFFC');
    });

    testWidgets('未挂载时静默 no-op（web inputRef.current?. 可选链）',
        (WidgetTester tester) async {
      final AylaMessageInputController controller =
          AylaMessageInputController();
      expect(controller.isAttached, isFalse);
      controller.insertMention('u2', '小樱'); // 不应抛
      expect(controller.isAttached, isFalse);
    });

    testWidgets('输入框卸载后 detach（页面再调不抛）', (WidgetTester tester) async {
      final AylaMessageInputController controller =
          AylaMessageInputController();
      final ValueNotifier<bool> show = ValueNotifier<bool>(true);
      addTearDown(show.dispose);
      setViewport(tester, const Size(760, 700));
      await tester.pumpWidget(
        MaterialApp(
          home: previewScope(
            ValueListenableBuilder<bool>(
              valueListenable: show,
              builder: (BuildContext context, bool visible, Widget? _) =>
                  visible
                      ? AylaMessageInput(
                          onSubmit: (_) {},
                          draftKey: 'k',
                          groupId: 'g1',
                          controller: controller,
                          members: <AylaConversationMember>[
                            AylaConversationMember(
                              id: 'm-u2',
                              user: const AylaUserPublic(
                                id: 'u2',
                                nickname: '小樱',
                                username: 'sakura',
                              ),
                            ),
                          ],
                        )
                      : const SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(controller.isAttached, isTrue, reason: '输入框在树上时已 attach');

      show.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(controller.isAttached, isFalse,
          reason: '输入框卸载 => State.dispose 解绑控制器');
      controller.insertMention('u2', '小樱'); // 不应抛（web inputRef.current?. 可选链）
    });
  });

  // ============ 6. fromShare 的生命周期（URL query 会被切场景丢掉）============

  group('fromShare 生命周期（2026-10-21 边界锁）', () {
    /// GroupPage 切场景用的是 `context.go('/group/<id>/<scene>')`（不带 query，
    /// `pages/group_page.dart:541/550`）⇒ 若只读 URL，`widget.fromShare` 会翻回 false；
    /// 而 GroupPage 的场景槽位由 `AylaSceneFade` 保管（切场景**不重挂** initState，
    /// 见 group_page.dart:1240-1242）⇒ 页面 State 必须自己「粘住」fromShare。
    ///
    /// ⚠️ 宿主必须是**持久的 StatefulWidget**（下面的 _VoiceHarness）：
    /// `previewScope` 内部是 `Overlay(initialEntries: …)`，其 entry 只构建一次，
    /// 连续 `pumpWidget` 换不同 child 不会重建 Overlay 里那棵子树（实测：换了 props
    /// 但页面上仍是旧 widget）⇒ 用 setState 驱动才能真验 State 复用。
    testWidgets('群语音：分享进房后 URL 丢 query（State 复用）⇒ 仍渲染房内，不退回骨架', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      // 房间属于**别的群**（白名单不含 g9）—— 只有 fromShare 才能看见。
      container.read(voiceStateProvider).upsertChannel(
            const AylaVoiceChannelSnapshot(
              id: 'v7',
              name: '分享来的房间',
              ownerId: 'u1',
              allowedGroupIds: <String>['g-other'],
            ),
          );

      await tester.pumpWidget(voiceHost(container, const VoiceHarness()));
      for (int i = 0; i < 6; i += 1) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.byType(AylaVoiceRoomBody), findsOneWidget,
          reason: '① 分享进入（fromShare=true）⇒ 免白名单（GroupVoice.tsx:90/96/127）');

      // ② 切场景再回来：URL 丢 query ⇒ widget.fromShare 变 false，
      //    但**同一个 State**（同 groupId、同 routeChannelId ⇒ 无 key 变化 ⇒ Element 复用）。
      final VoiceHarnessState harness =
          tester.state<VoiceHarnessState>(find.byType(VoiceHarness));
      harness.setConfig(fromShare: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      expect(find.byType(AylaVoiceRoomBody), findsOneWidget,
          reason: '② 粘性 fromShare 必须保住房内可见 —— 否则切场景回来就被踢成骨架'
              '（GroupPage._goScene 不保留 ?fromShare=1，group_page.dart:541）');
      expect(find.text('正在加载语音房…'), findsNothing);

      // ③ 换群（groupId 变）⇒ 这是**另一次**进群会话 ⇒ 粘性重置、严格白名单生效。
      harness.setConfig(groupId: 'g10');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.byType(AylaVoiceRoomBody), findsNothing,
          reason: '③ 换群必须重置粘性 fromShare（web 换群 = 新的 history entry）');
      expect(find.text('正在加载语音房…'), findsOneWidget,
          reason: '白名单不含 g10 ⇒ 保持骨架（不伪造可见）');
    });

    testWidgets('群直播：分享进直播后 URL 丢 query（State 复用）⇒ 不退成错误态', (
      WidgetTester tester,
    ) async {
      // 与群语音同一条边界（GroupLive.tsx:25 的 fromShare + :36/:49 的判据）：
      // 直播页的 `_syncRouteChannel` 用 `_visibleInGroup` 决定「报错」还是「进房」，
      // 若只读 URL，切场景回来 fromShare 翻 false ⇒ `_detailError` 被置成
      // 「该直播间不在本群可见范围内」⇒ 从分享点进的直播间消失。
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      // 直播间属于别的群（白名单不含 g9）—— 只有 fromShare 才能看见。
      container.read(liveStateProvider).upsertChannel(
            const AylaLiveChannelSnapshot(
              id: '9',
              title: '分享来的直播间',
              ownerId: 'u1',
              allowedGroupIds: <String>['g-other'],
            ),
          );

      await tester.pumpWidget(liveHost(container, const LiveHarness()));
      for (int i = 0; i < 8; i += 1) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.text('该直播间不在本群可见范围内'), findsNothing,
          reason: '① fromShare=true ⇒ 免白名单（GroupLive.tsx:36/49）');

      final LiveHarnessState harness =
          tester.state<LiveHarnessState>(find.byType(LiveHarness));
      harness.setConfig(fromShare: false);
      await tester.pump();
      for (int i = 0; i < 4; i += 1) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.text('该直播间不在本群可见范围内'), findsNothing,
          reason: '② 粘性 fromShare 必须保住可见 —— 否则切场景回来被踢成错误态');
    });
    testWidgets('群语音：粘性 fromShare 不越权 —— 白名单不含时既不渲染也不注入域 store', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      // v8 的白名单不含 g10；本用例**不带 fromShare**（正常进群档）。
      container.read(voiceStateProvider).upsertChannel(
            const AylaVoiceChannelSnapshot(
              id: 'v8',
              name: '只属于 g9 的房间',
              ownerId: 'u1',
              allowedGroupIds: <String>['g9'],
            ),
          );

      await tester.pumpWidget(
        voiceHost(
          container,
          const VoiceHarness(groupId: 'g10', channelId: 'v8', fromShare: false),
        ),
      );
      for (int i = 0; i < 6; i += 1) {
        await tester.pump(const Duration(milliseconds: 60));
      }

      // 关键：**store 里明明有这个频道**（模拟别处拉过 / 帧写入），
      // 但粘性标记初值 = widget.fromShare = false ⇒ 仍必须走严格白名单判据、
      // 不渲染房内。这证明「粘性」只在本次 fromShare 为真时生效，不会把
      // 「store 有该频道」误当成可见。
      expect(find.byType(AylaVoiceRoomBody), findsNothing,
          reason: 'v8 白名单不含 g10 且无 fromShare ⇒ 保持骨架（不伪造可见）');
      expect(find.text('正在加载语音房…'), findsOneWidget);
    });
  });
}

/// 群语音页在**固定宿主**里的最小容器（见「fromShare 生命周期」组的说明：
/// 必须用 setState 驱动 props，不能连续 pumpWidget 换 child）。
class VoiceHarness extends StatefulWidget {
  const VoiceHarness({
    super.key,
    this.groupId = 'g9',
    this.channelId = 'v7',
    this.fromShare = true,
  });

  final String groupId;
  final String channelId;
  final bool fromShare;

  @override
  State<VoiceHarness> createState() => VoiceHarnessState();
}

class VoiceHarnessState extends State<VoiceHarness> {
  late String _groupId = widget.groupId;
  late String _channelId = widget.channelId;
  late bool _fromShare = widget.fromShare;

  /// 模拟「路由换了参数」：同 groupId + 同 channelId + fromShare 翻 false
  /// = GroupPage 切场景后再回来（URL 丢了 query）时本页收到的 props。
  void setConfig({String? groupId, String? channelId, bool? fromShare}) {
    setState(() {
      if (groupId != null) _groupId = groupId;
      if (channelId != null) _channelId = channelId;
      if (fromShare != null) _fromShare = fromShare;
    });
  }

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topLeft,
        child: GroupVoicePage(
          groupId: _groupId,
          routeChannelId: _channelId,
          fromShare: _fromShare,
        ),
      );
}

Widget voiceHost(ProviderContainer container, Widget child) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAylaTheme(),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(1440, 900)),
          child: previewScope(child),
        ),
      ),
    );

/// 群直播页的最小固定宿主（同 [VoiceHarness]：必须 setState 驱动 props）。
class LiveHarness extends StatefulWidget {
  const LiveHarness({
    super.key,
    this.groupId = 'g9',
    this.channelId = '9',
    this.fromShare = true,
  });

  final String groupId;
  final String channelId;
  final bool fromShare;

  @override
  State<LiveHarness> createState() => LiveHarnessState();
}

class LiveHarnessState extends State<LiveHarness> {
  late String _groupId = widget.groupId;
  late String _channelId = widget.channelId;
  late bool _fromShare = widget.fromShare;

  void setConfig({String? groupId, String? channelId, bool? fromShare}) {
    setState(() {
      if (groupId != null) _groupId = groupId;
      if (channelId != null) _channelId = channelId;
      if (fromShare != null) _fromShare = fromShare;
    });
  }

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topLeft,
        child: GroupLivePage(
          groupId: _groupId,
          routeChannelId: _channelId,
          fromShare: _fromShare,
        ),
      );
}

Widget liveHost(ProviderContainer container, Widget child) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAylaTheme(),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(1440, 900)),
          child: previewScope(child),
        ),
      ),
    );
