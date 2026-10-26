/// 私信头像「显示成文字首字」的三条根因回归锁（2026-10-25，用户实报）。
///
/// ## 现象
/// Ayla Flutter 私信界面（消息页会话列表 + 私聊会话页）头像**永远显示文字首字**，
/// 真实头像图不出现。
///
/// ## 三条根因（各自独立，本文件三条独立锁）
///
/// ### ① 私聊 peer 推导漏了「排除自己」（数据层，最致命）
/// `ConversationMetadataSerializer`（后端 `apps/chat/serializers.py:514–535`）**对私聊也不给
/// `peer` 字段**（只有 `ConversationListSerializer` 给），而
/// `GET /chat/conversations/<id>/?metadata=1`（`views.py:410–415`）走的正是前者
/// ⇒ 私聊详情响应必然无 `peer` ⇒ 必然落到 `AylaChatState._normalize` 推导。
///
/// 修复前实现是 `conv.members.first.user`；web 事实源 `stores/chat.ts:129–133` 是
/// `members.find(m => m.user.id !== me) ?? members[0]`（**排除自己**）。
/// 后端成员表是 `obj.members.select_related("user")[:2]`（**无 `order_by`**），
/// 实测真库 **30 个「私聊会话 × 成员视角」组合里 15 个的 `members[0]` 就是自己**
/// ⇒ peer 被写成自己 ⇒ 顶栏头像/昵称变成自己（自己没设头像 ⇒ 空串 ⇒ 文字首字）。
///
/// 且该错值**会粘住**：`upsertConversation` 合并写 `peer: prev.peer`
/// （`copyWith` 的 null = 保留旧值）⇒ 之后正确的目录摘要也覆盖不回来。
///
/// ### ② 空串 ≠ null（渲染层，全库 31 个光环使用点）
/// 后端 `User.avatar` 是 `CharField(blank=True, default="")`（`accounts/models.py:33`）
/// ⇒ **没有头像的用户返回空串，不是 null**。而 `AylaAvatarHalo` 修复前用
/// `resourceUrl == null` 判「有没有图」⇒ 空串命中「有图」分支 ⇒
/// `AylaResourceImage(src: '')` ⇒ `resource_image.dart:307` 直接判 failed ⇒
/// 装饰图（`alt: ''`）只渲染 fallback ⇒ **视觉上就是文字首字**。
/// 即「没头像」这种正常情况走了「图片加载失败」的路径。
///
/// web 事实源 `components/Avatar.tsx:46`：`imageUrl ? <ResourceImage …/> : 首字`
/// —— JS 假值判断把 `''` 与 `null` 一视同仁，走**文字分支**。
///
/// ### ③ 私信两条渲染路径必须把真头像 URL 送到光环（接线层）
/// 顶栏 `private_chat_pane.dart:314–324` 用 `conv?.peer?.avatar`；
/// 气泡 `message_list.dart:939–950` 的 `_memberAvatars` 用 `m.user.avatar`，
/// 在 `:1059` 传 `senderAvatarUrl`。两条链任一断（peer 错 / members 丢）都会退回文字。
/// 对照组：`conversation_list.dart:400` 对**群**头像做了 `_nonEmpty` 归一，私聊分支没有。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/chat_message.dart';
import '../lib/core/models/conversation.dart';
import '../lib/core/models/user_public.dart';
import '../lib/state/chat_state.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/base/avatar_halo.dart';
import '../lib/widgets/base/resource_image.dart';
import '../lib/widgets/chat/message_list.dart';
import '../lib/widgets/chat/private_chat_pane.dart';

/// 真库里的真实头像 content URL 形态（`apps/media/services.py:675` 规定只能长这样）。
const String kPeerAvatar = '/api/v1/media/3b0c538297534db1a5f1086e5f5ac241/content';

const AylaUserPublic kMe = AylaUserPublic(id: 'me', nickname: '123', username: '123');
const AylaUserPublic kPeer = AylaUserPublic(
  id: 'u2',
  nickname: '汐汐',
  username: 'xixi',
  avatar: kPeerAvatar,
);

/// 私聊会话：**自己在 members 最前**（真库 15/30 就是这个顺序），且**不带 peer**
/// （`metadata=1` 响应的真实形态 —— 这是本条 bug 的触发条件）。
AylaConversationSummary privateConvWithoutPeer({
  bool selfFirst = true,
  String selfAvatar = '',
  String peerAvatar = kPeerAvatar,
}) {
  final AylaConversationMember me = AylaConversationMember(
    id: 'm-me',
    user: AylaUserPublic(
      id: kMe.id,
      nickname: kMe.nickname,
      username: kMe.username,
      avatar: selfAvatar,
    ),
  );
  final AylaConversationMember peer = AylaConversationMember(
    id: 'm-u2',
    user: AylaUserPublic(
      id: kPeer.id,
      nickname: kPeer.nickname,
      username: kPeer.username,
      avatar: peerAvatar,
    ),
  );
  return AylaConversationSummary(
    id: 'c1',
    type: AylaConversationType.private,
    title: '',
    members: selfFirst
        ? <AylaConversationMember>[me, peer]
        : <AylaConversationMember>[peer, me],
  );
}

AylaChatMessage peerMessage() => const AylaChatMessage(
      id: 'm1',
      conversationId: 'c1',
      senderId: 'u2',
      type: AylaMessageType.text,
      content: '在吗',
      status: AylaMessageStatus.sent,
      seq: 1,
      createdAt: '2026-10-20T10:00:00Z',
    );

void main() {
  // 当前用户 id 注入的复原（生产由 main.dart 接线；测试各自覆盖）
  tearDown(() => aylaRegisterChatStateCurrentUserId(null));

  // ===================================================================
  // ① 私聊 peer 推导必须排除自己
  // ===================================================================
  group('① _normalize：私聊 peer 推导排除自己（web stores/chat.ts:129–133）', () {
    test('★ members[0] 是自己时，peer 仍应是对端（修复前 = 自己）', () {
      aylaRegisterChatStateCurrentUserId(() => kMe.id);
      final AylaChatState state = AylaChatState();
      state.upsertConversation(privateConvWithoutPeer(selfFirst: true));

      final AylaConversationSummary? stored = state.byId('c1');
      expect(stored?.peer?.id, 'u2',
          reason: '后端 members[0] 是本人（真库 15/30）⇒ 必须排除自己再取对端');
      expect(stored?.peer?.nickname, '汐汐');
      expect(stored?.peer?.avatar, kPeerAvatar,
          reason: '对端头像必须带出来（顶栏/气泡都读它）');
    });

    test('members[0] 是别人时同样取对端（顺序无关）', () {
      aylaRegisterChatStateCurrentUserId(() => kMe.id);
      final AylaChatState state = AylaChatState();
      state.upsertConversation(privateConvWithoutPeer(selfFirst: false));
      expect(state.byId('c1')?.peer?.id, 'u2');
    });

    test('已带 peer 的目录摘要不被推导覆盖（peer != null 直接返回）', () {
      aylaRegisterChatStateCurrentUserId(() => kMe.id);
      final AylaChatState state = AylaChatState();
      state.upsertConversation(
        privateConvWithoutPeer(selfFirst: true).copyWith(peer: kPeer),
      );
      expect(state.byId('c1')?.peer?.id, 'u2');
    });

    test('未注入当前用户（画布/纯组件测试）⇒ 退回 members 首条，不崩', () {
      aylaRegisterChatStateCurrentUserId(null);
      final AylaChatState state = AylaChatState();
      state.upsertConversation(privateConvWithoutPeer(selfFirst: true));
      expect(state.byId('c1')?.peer?.id, 'me',
          reason: '无身份信息时保持修复前行为（不抛、不造 null）');
    });

    test('脏数据（members 全是自己）⇒ 取首条，不造 null', () {
      aylaRegisterChatStateCurrentUserId(() => kMe.id);
      final AylaChatState state = AylaChatState();
      state.upsertConversation(AylaConversationSummary(
        id: 'c2',
        type: AylaConversationType.private,
        title: '',
        members: <AylaConversationMember>[
          AylaConversationMember(id: 'm1', user: kMe),
        ],
      ));
      expect(state.byId('c2')?.peer?.id, 'me',
          reason: 'web `?? members[0]` 同义：宁可取自己也不丢 peer');
    });

    test('群会话不走 peer 推导（isPrivate 门控）', () {
      aylaRegisterChatStateCurrentUserId(() => kMe.id);
      final AylaChatState state = AylaChatState();
      state.upsertConversation(AylaConversationSummary(
        id: 'g1',
        type: AylaConversationType.group,
        title: '群',
        members: <AylaConversationMember>[
          AylaConversationMember(id: 'm1', user: kMe),
          AylaConversationMember(id: 'm2', user: kPeer),
        ],
      ));
      expect(state.byId('g1')?.peer, isNull, reason: '群没有「对端」概念');
    });
  });

  // ===================================================================
  // ② 空串头像 ≡ null：走文字首字档，不走进图片加载
  // ===================================================================
  group('② AylaAvatarHalo：空串头像必须等价 null（web Avatar.tsx:46 假值判断）', () {
    Widget host(Widget child) => MaterialApp(
          home: previewTheme(
            SizedBox(width: 200, height: 200, child: Center(child: child)),
          ),
        );

    testWidgets('★ resourceUrl: "" ⇒ 不构造 AylaResourceImage，直接画首字',
        (WidgetTester tester) async {
      await tester.pumpWidget(host(
        const AylaAvatarHalo(label: '汐汐', size: 40, resourceUrl: ''),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(AylaResourceImage), findsNothing,
          reason: '空串不是图片地址 ⇒ 不得进入图片分支（修复前会构造 src:"" 并判 failed）');
      expect(find.text('汐'), findsOneWidget, reason: '应显示名字首字');
    });

    testWidgets('resourceUrl: null 同样走文字档（对照）', (WidgetTester tester) async {
      await tester.pumpWidget(host(
        const AylaAvatarHalo(label: '汐汐', size: 40),
      ));
      await tester.pump();
      expect(find.byType(AylaResourceImage), findsNothing);
      expect(find.text('汐'), findsOneWidget);
    });

    testWidgets('纯空白串 "   " 也按 null 处理（防御后端脏值）', (WidgetTester tester) async {
      await tester.pumpWidget(host(
        const AylaAvatarHalo(label: '汐汐', size: 40, resourceUrl: '   '),
      ));
      await tester.pump();
      expect(find.byType(AylaResourceImage), findsNothing);
      expect(find.text('汐'), findsOneWidget);
    });

    testWidgets('有真 URL ⇒ 进图片分支（不误伤）', (WidgetTester tester) async {
      await tester.pumpWidget(host(
        const AylaAvatarHalo(label: '汐汐', size: 40, resourceUrl: kPeerAvatar),
      ));
      await tester.pump();
      final Finder img = find.byType(AylaResourceImage);
      expect(img, findsOneWidget, reason: '非空 URL 必须走签名/加载链路');
      expect(tester.widget<AylaResourceImage>(img).src, kPeerAvatar);
      expect(tester.widget<AylaResourceImage>(img).alt, '',
          reason: '头像 = 装饰图（alt:""，失败静默回退首字，同 web）');
    });
  });

  // ===================================================================
  // ③ 私信两条渲染路径真的把真头像 URL 送到光环
  // ===================================================================
  group('③ 私信渲染路径：顶栏与气泡都必须把真头像 URL 送到光环', () {
    Widget host(Widget child) => MaterialApp(
          home: previewTheme(
            SizedBox(width: 720, height: 480, child: child),
          ),
        );

    testWidgets('★ 私聊顶栏光环拿到 peer.avatar（不是空串/不是自己）',
        (WidgetTester tester) async {
      aylaRegisterChatStateCurrentUserId(() => kMe.id);
      final AylaChatState state = AylaChatState();
      state.upsertConversation(privateConvWithoutPeer(selfFirst: true));
      await tester.pumpWidget(host(
        AylaPrivateChatPane(
          conversation: state.byId('c1'),
          messages: const <AylaChatMessage>[],
          currentUserId: kMe.id,
        ),
      ));
      await tester.pump();

      final AylaAvatarHalo halo = tester.widget<AylaAvatarHalo>(
        find.byType(AylaAvatarHalo).first,
      );
      expect(halo.resourceUrl, kPeerAvatar,
          reason: '顶栏必须拿到对端真头像（修复前 peer 被推成自己 ⇒ 空串 ⇒ 首字）');
      expect(find.byType(AylaResourceImage), findsWidgets,
          reason: '有真 URL ⇒ 应进入图片链路');
    });

    testWidgets('★ 私信气泡头像拿到 members 里的真 avatar', (WidgetTester tester) async {
      aylaRegisterChatStateCurrentUserId(() => kMe.id);
      final AylaChatState state = AylaChatState();
      state.upsertConversation(privateConvWithoutPeer(selfFirst: true));
      await tester.pumpWidget(host(
        AylaMessageList(
          messages: <AylaChatMessage>[peerMessage()],
          currentUserId: kMe.id,
          conversation: state.byId('c1'),
        ),
      ));
      await tester.pump();

      final List<AylaAvatarHalo> halos =
          tester.widgetList<AylaAvatarHalo>(find.byType(AylaAvatarHalo)).toList();
      expect(halos, isNotEmpty, reason: '别人（对端）的气泡必须画头像');
      final AylaAvatarHalo senderHalo = halos.firstWhere(
        (AylaAvatarHalo h) => h.label == '汐汐',
        orElse: () => halos.first,
      );
      expect(senderHalo.resourceUrl, kPeerAvatar,
          reason: '气泡发送者头像取 conversation.members 的 user.avatar');
    });

    testWidgets('对端没头像（avatar: ""）⇒ 光环拿到空串但不崩、走首字（回归对照）',
        (WidgetTester tester) async {
      aylaRegisterChatStateCurrentUserId(() => kMe.id);
      final AylaChatState state = AylaChatState();
      state.upsertConversation(
        privateConvWithoutPeer(selfFirst: true, peerAvatar: ''),
      );
      await tester.pumpWidget(host(
        AylaPrivateChatPane(
          conversation: state.byId('c1'),
          messages: const <AylaChatMessage>[],
          currentUserId: kMe.id,
        ),
      ));
      await tester.pump();

      final AylaAvatarHalo halo = tester.widget<AylaAvatarHalo>(
        find.byType(AylaAvatarHalo).first,
      );
      expect(halo.resourceUrl, '',
          reason: '数据层如实透出空串（不伪造 null）—— 归一在渲染层组件内做');
      expect(find.byType(AylaResourceImage), findsNothing,
          reason: '但空串必须走文字档（② 的归一），不得进图片分支');
      expect(find.text('汐'), findsWidgets);
    });
  });
}
