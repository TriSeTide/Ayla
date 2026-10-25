/// 群聊「别人的头像/昵称」回归锁 —— 用户 2026-10-23 实报
/// 「手机端群聊界面不显示别人的头像，私信没这个问题」。
///
/// ## 根因（web 侧没有、Flutter 独有的竞态）
/// 群成员的发送者头像/昵称来自 `conversation.members`
/// （`MessageList.tsx:360–369` 的 `memberAvatars` / Flutter
/// `message_list.dart:939–950` 的 `_memberAvatars`）。而后端
/// `ConversationMetadataSerializer.get_members` **有意对群返回 `[]`**
/// （`apps/chat/serializers.py`：群成员独立分页），会话目录同为空
/// ⇒ 必须靠「全量拉成员页 + 合并进 chatState」这一步才有头像。
///
/// 修复前 `_bootstrap()` 把 `_loadMembers()` 与 `getConversationMetadata()` **并发**跑，
/// 且 `_loadMembers` 结束时要求 `byId(groupId) != null` 才写。手机慢网下两条
/// 响应顺序一反过来（成员页先回、群摘要还没进 chatState）：
///   ① 成员被 `current == null` 直接丢弃；
///   ② metadata 之后才 upsert（members 空 + members_complete=false）；
///   ③ `_loadMembers` 已跑完、无第二次机会 ⇒ **成员永远为空** ⇒ 别人的头像与昵称全丢。
/// 自己的消息本来就不画头像（`MessageBubble` 的 `isSelf` 分支）⇒ 症状表现为
/// 「只有别人的没有」。
///
/// 私信无此问题：`ConversationMetadataSerializer` 对非群返回完整 `members[:2]`
/// （前端 `stores/chat.ts:127–133` 也额外从 members 推导 peer）。
///
/// web 也无此问题：`GroupChat.tsx:159–194` 的成员 effect **依赖
/// `activeConv?.members_complete`**，metadata upsert 后依赖变化 ⇒ effect 重跑。
///
/// ## 本文件锁什么
/// ① **响应顺序无关**：成员页比 metadata 快、慢两种时序都必须拿到头像；
/// ② **群摘要尚未进 chatState**（冷启动直链）时也不能丢成员；
/// ③ 成员页失败一次时不阻断聊天（缺头像可接受，但不许崩）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/net/dio_client.dart';
import '../lib/pages/group_chat_page.dart' show GroupChatPage;
import '../lib/state/chat_providers.dart'
    show aylaStartSocialTracking, chatStateProvider;
import '../lib/state/social_store.dart' show aylaSocialStore;
import '../lib/widgets/base/avatar_halo.dart';

class _NoToken implements AuthTokenStore {
  @override
  String? get accessToken => 't';
  @override
  String? get refreshToken => null;
  @override
  void setTokens(String access, String? refresh) {}
  @override
  void clear() {}
}

Map<String, dynamic> _memberJson(String id, String nick) => <String, dynamic>{
      'id': id,
      'user': <String, dynamic>{
        'id': id,
        'username': id,
        'nickname': nick,
        'avatar': '',
        'status': 'auto',
        'online': false,
        'display_status': '离线',
        'show_content': true,
      },
      'role': 'member',
      'muted': false,
    };

/// 可编程延迟/失败的假 HTTP 层（只覆盖本页用到的三个端点）。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({
    this.metadataDelay = Duration.zero,
    this.membersDelay = Duration.zero,
    this.membersFailTimes = 0,
  });

  final Duration metadataDelay;
  final Duration membersDelay;
  int membersFailTimes;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final String path = options.path;
    dynamic body;
    int status = 200;
    if (path.contains('/members/')) {
      await Future<void>.delayed(membersDelay);
      if (membersFailTimes > 0) {
        membersFailTimes -= 1;
        status = 500;
        body = <String, dynamic>{'detail': 'boom'};
      } else {
        body = <String, dynamic>{
          'results': <dynamic>[_memberJson('u2', '樱'), _memberJson('me', '我')],
          'next_cursor': null,
          'has_more': false,
          'total': 2,
        };
      }
    } else if (path.contains('/messages/')) {
      body = <dynamic>[
        <String, dynamic>{
          'id': 'm1',
          'conversation_id': 'g1',
          'sender_id': 'u2',
          'type': 'text',
          'content': '你好',
          'seq': 1,
          'status': 'sent',
          'created_at': '2026-10-23T10:00:00Z',
        },
      ];
    } else if (path.contains('/subgroups/')) {
      body = <String, dynamic>{
        'results': <dynamic>[],
        'next_cursor': null,
        'has_more': false,
        'total': 0,
        'default': null,
      };
    } else if (path.contains('/conversations/')) {
      // metadata=directory / metadata=1 —— **群成员被后端有意排除**
      await Future<void>.delayed(metadataDelay);
      body = <String, dynamic>{
        'id': 'g1',
        'type': 'group',
        'title': '群',
        'announcement': '',
        'avatar': '',
        'owner_id': 'me',
        'members': <dynamic>[],
        'members_complete': false,
        'my_role': 'member',
        'my_muted': false,
        'member_count': 2,
        'unread_count': 0,
        'last_read_seq': 1,
        'is_pinned': false,
        'created_at': '2026-10-01T00:00:00Z',
      };
    } else {
      body = <String, dynamic>{
        'results': <dynamic>[],
        'next_cursor': null,
        'has_more': false,
        'total': 0,
      };
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  // `GroupChatPage` 会构造录音器（语音消息键）—— 测试环境没有该插件，
  // 不 mock 会在 runAsync 推进真实时间轴时抛 MissingPluginException。
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      (MethodCall call) async => null,
    );
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      null,
    );
  });

  /// 起真 `GroupChatPage` + 假 HTTP。返回容器供断言 chatState。
  Future<ProviderContainer> boot(
    WidgetTester tester,
    _FakeAdapter adapter,
  ) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    DioClient.instance.debugBaseUrlOverride = 'http://fake.local';
    DioClient.instance.init(tokenStore: _NoToken(), onSessionExpired: () {});
    DioClient.instance.dio.httpClientAdapter = adapter;

    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    aylaStartSocialTracking(container);
    aylaSocialStore.reset();
    aylaSocialStore.userId = 'me';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            backgroundColor: const Color(0xFFFFFFFF),
            body: Builder(
              builder: (BuildContext context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(size: const Size(420, 900)),
                child: const GroupChatPage(groupId: 'g1'),
              ),
            ),
          ),
        ),
      ),
    );
    // 真实时间轴推进（假 adapter 的延迟要真的走完；单纯 pump 不会让 Future.delayed 到时）
    for (int i = 0; i < 16; i += 1) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
    return container;
  }

  /// 别人的消息行必须画出头像（`halo` 数 ≥ 1）并显示昵称。
  void expectPeerAvatarRendered(WidgetTester tester) {
    expect(find.text('你好'), findsOneWidget, reason: '消息本身必须渲染');
    expect(
      tester.widgetList<AylaAvatarHalo>(find.byType(AylaAvatarHalo)).length,
      greaterThanOrEqualTo(1),
      reason: '★ 群聊里别人的消息必须画头像（用户实报「不显示别人的头像」）',
    );
    expect(find.text('樱'), findsWidgets, reason: '发送者昵称同样来自成员表');
  }

  testWidgets('① 成员页比 metadata 快 ⇒ 仍拿到头像（修复前正是这条丢失）',
      (WidgetTester tester) async {
    final _FakeAdapter adapter = _FakeAdapter(
      metadataDelay: const Duration(milliseconds: 150),
      membersDelay: const Duration(milliseconds: 10),
    );
    await boot(tester, adapter);
    expectPeerAvatarRendered(tester);
  });

  testWidgets('② 成员页比 metadata 慢 ⇒ 拿到头像（对照档，两条时序都锁）',
      (WidgetTester tester) async {
    final _FakeAdapter adapter = _FakeAdapter(
      metadataDelay: const Duration(milliseconds: 10),
      membersDelay: const Duration(milliseconds: 150),
    );
    await boot(tester, adapter);
    expectPeerAvatarRendered(tester);
  });

  testWidgets('③ 冷启动直链（群摘要尚未进 chatState）⇒ 成员仍落库', (WidgetTester tester) async {
    // boot 里不预置 chatState ⇒ 模拟「直接输链接进群 / 列表还没加载」
    final _FakeAdapter adapter = _FakeAdapter(
      metadataDelay: const Duration(milliseconds: 150),
      membersDelay: const Duration(milliseconds: 10),
    );
    final ProviderContainer container = await boot(tester, adapter);
    expectPeerAvatarRendered(tester);
    expect(
      container.read(chatStateProvider).byId('g1')?.members.length,
      2,
      reason: '成员必须落进 chatState（气泡的头像/昵称唯一事实源）',
    );
  });

  testWidgets('④ 成员页失败一次 ⇒ 不崩、聊天照常（失败不阻断）', (WidgetTester tester) async {
    final _FakeAdapter adapter = _FakeAdapter(membersFailTimes: 1);
    await boot(tester, adapter);
    // 缺头像可接受（web 同：失败只缺头像/昵称），但消息必须正常、不得抛异常。
    expect(find.text('你好'), findsOneWidget);
  });
}
