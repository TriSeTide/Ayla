/// 群详情「成员可上传表情包」开关定向测试 —— 对照 web
/// `GroupInfo.tsx:128-130 / 222-242 / 252-263 / 584-599` +
/// `api/emoji.ts:33-35 / 62-67`。
///
/// ## 为什么必须有这条
/// 本页此前自登记「Flutter 侧尚无 emoji 域 api ⇒ 该行不渲染」
/// （group_info_page.dart 原头注第 1 条）。补齐 [AylaEmojiApi] 后必须把该行接上，
/// 否则用户会看到「群里能发表情但设置里没开关」的不一致。
///
/// ## 口径（逐条对齐 web）
/// | 用例 | web 依据 |
/// |---|---|
/// | 群主 + 摘要到达 ⇒ 渲染该行，label「成员可上传表情包」 | tsx:584-586 |
/// | 开关值 = `allow_member_upload`（后端真值，不是本地猜测） | tsx:229 |
/// | 404（包未创建）⇒ `allow_member_upload = false` **且仍渲染**（loaded=true） | tsx:234-236 |
/// | 非群主 ⇒ **不渲染** | tsx:584 的 `isOwner && emojiPolicyLoaded` |
/// | 摘要其它错误 ⇒ 落 managementError 且该行不渲染 | tsx:238 |
/// | 切换 ⇒ PATCH body 是 `{allow_member_upload: <新值>}` | api/emoji.ts:63-66 |
/// | 切换中 ⇒ 开关禁用（`busyAction !== null`） | tsx:591 |
///
/// ## 手法
/// 与 `group_info_page_layout_test.dart` 同源：真实页面 + dio 的
/// `HttpClientAdapter` 假传输层（JSON → 模型 → Pager → 页面仍然真实），
/// 并**记录 PATCH 的 body** 作为真实链路判据。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/net/dio_client.dart';
import '../lib/pages/group_info_page.dart';
import '../lib/theme/app_theme.dart' show buildAylaTheme;
import '../lib/widgets/group/group_info_settings.dart';

Map<String, dynamic> _page(List<Map<String, dynamic>> results) =>
    <String, dynamic>{
      'results': results,
      'next_cursor': null,
      'has_more': false,
      'total': results.length,
    };

/// 群表情包摘要（后端 `_group_pack_payload` 摘要档形状）。
Map<String, dynamic> _summary({required bool allowMemberUpload}) =>
    <String, dynamic>{
      'pack': <String, dynamic>{'id': '77', 'name': '群表情', 'item_count': 2},
      'allow_member_upload': allowMemberUpload,
      'can_upload': true,
      'can_delete': true,
    };

class _EmojiPolicyAdapter implements HttpClientAdapter {
  /// 群主的 my_role（'owner' / 'admin' / 'member'）。
  String myRole = 'owner';

  /// GET 摘要的状态码（404 = 包未创建，后端 views.py:230-232）。
  int summaryStatus = 200;

  /// 摘要的 allow_member_upload 初值。
  bool allowMemberUpload = false;

  /// PATCH 的响应状态码（非 200 ⇒ 切换失败分支）。
  int patchStatus = 200;

  /// PATCH 闸门：非 null 时挂起，直到测试 complete（量「切换中开关禁用」用）。
  /// 用可完成的 Completer 而不是「永不返回」——后者会在收尾留下 dio 的超时 Timer。
  Completer<void>? patchGate;

  final List<RequestOptions> requests = <RequestOptions>[];
  final List<Map<String, dynamic>> patchBodies = <Map<String, dynamic>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final String path = options.path;
    Object? body;
    int status = 200;

    if (path.contains('/emoji/groups/')) {
      if (options.method == 'PATCH') {
        final Object? data = options.data;
        final Map<String, dynamic> sent = data is Map
            ? data.cast<String, dynamic>()
            : <String, dynamic>{};
        patchBodies.add(sent);
        final Completer<void>? gate = patchGate;
        if (gate != null) await gate.future;
        if (patchStatus != 200) {
          status = patchStatus;
          body = <String, dynamic>{'detail': '设置失败（测试注入）'};
        } else {
          allowMemberUpload = sent['allow_member_upload'] == true;
          body = _summary(allowMemberUpload: allowMemberUpload);
        }
      } else if (summaryStatus == 404) {
        status = 404;
        body = <String, dynamic>{'detail': 'group_pack_not_found'};
      } else if (summaryStatus != 200) {
        status = summaryStatus;
        body = <String, dynamic>{'detail': '表情上传权限加载失败（测试注入）'};
      } else {
        body = _summary(allowMemberUpload: allowMemberUpload);
      }
    } else if (path.endsWith('/subgroups/') || path.endsWith('/members/')) {
      body = _page(const <Map<String, dynamic>>[]);
    } else if (path.endsWith('/join-requests/')) {
      body = _page(const <Map<String, dynamic>>[]);
    } else if (path.contains('/chat/conversations/g1/')) {
      body = <String, dynamic>{
        'id': 'g1',
        'type': 'group',
        'title': '星海观测站',
        'announcement': '',
        'avatar': '',
        'join_policy': 'application',
        'owner_id': 'u1',
        'my_role': myRole,
        'member_count': 2,
        'created_at': '2026-01-01T00:00:00Z',
      };
    } else {
      body = <String, dynamic>{};
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: <String, List<String>>{
        'content-type': <String>['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _NoTokens implements AuthTokenStore {
  @override
  String? get accessToken => null;
  @override
  String? get refreshToken => null;
  @override
  void setTokens(String access, String? refresh) {}
  @override
  void clear() {}
}

// $BODY$

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const Size viewport = Size(1526, 900);

  late _EmojiPolicyAdapter adapter;

  setUpAll(() {
    adapter = _EmojiPolicyAdapter();
    // `DioClient.dio` 是 late final ⇒ 先 init 再换传输层。
    DioClient.instance.init(tokenStore: _NoTokens(), onSessionExpired: () {});
    DioClient.instance.dio.httpClientAdapter = adapter;
  });

  setUp(() {
    adapter
      ..requests.clear()
      ..patchBodies.clear()
      ..myRole = 'owner'
      ..summaryStatus = 200
      ..allowMemberUpload = false
      ..patchStatus = 200
      ..patchGate = null;
  });

  Widget host(Widget child) => ProviderScope(
        child: MaterialApp(
          theme: buildAylaTheme(),
          home: Scaffold(
            body: Builder(
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
        ),
      );

  /// 挂页面 → 数据落地 → 入场动画走完。
  Future<void> pumpPage(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(viewport);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host(const GroupInfoPage(groupId: 'g1')));
    await tester.pump();
    for (int i = 0; i < 8; i += 1) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  /// 该行（label 文案 = web tsx:586 的「成员可上传表情包」）。
  Finder switchRow() => find.byType(AylaGroupInfoSwitch);

  group('渲染条件（web GroupInfo.tsx:584 的 isOwner && emojiPolicyLoaded）', () {
    testWidgets('★ 群主 + 摘要 200 ⇒ 渲染该行，label 逐字', (WidgetTester tester) async {
      adapter.allowMemberUpload = true;
      await pumpPage(tester);

      expect(switchRow(), findsOneWidget,
          reason: '★ 修复前该行恒不渲染（自登记「尚无 emoji 域 api」）；'
              'web tsx:584-599 在 isOwner && emojiPolicyLoaded 时渲染');
      expect(find.text('成员可上传表情包'), findsOneWidget,
          reason: 'web tsx:586 的 label 原文');
      final AylaGroupInfoSwitch row =
          tester.widget<AylaGroupInfoSwitch>(switchRow());
      expect(row.value, isTrue,
          reason: '开关值取后端 allow_member_upload（tsx:229），不是本地默认');
    });

    testWidgets('★ 摘要 404（包未创建）⇒ 仍渲染，但 value = false', (WidgetTester tester) async {
      adapter.summaryStatus = 404;
      await pumpPage(tester);

      expect(switchRow(), findsOneWidget,
          reason: '★ tsx:234-236：404 也置 emojiPolicyLoaded = true ⇒ 该行要渲染');
      final AylaGroupInfoSwitch row =
          tester.widget<AylaGroupInfoSwitch>(switchRow());
      expect(row.value, isFalse,
          reason: 'tsx:235「setAllowMemberUpload(false)」');
    });

    testWidgets('★ 非群主（admin / member）⇒ 不渲染该行', (WidgetTester tester) async {
      for (final String role in <String>['admin', 'member']) {
        adapter.myRole = role;
        await pumpPage(tester);
        expect(switchRow(), findsNothing,
            reason: '★ tsx:584 的 isOwner 门控（$role 不该看到该开关）');
      }
    });

    testWidgets('★ 非群主 ⇒ 连摘要请求都不发（web tsx:223 的 if (!isOwner) return）', (
      WidgetTester tester,
    ) async {
      // 这条比「不渲染」更硬：非群主时**网络层**就不该碰 /emoji/groups/。
      // 两层门控（本页不发请求 + 渲染前再判 isOwner）任一层被删都会被这条挡住。
      for (final String role in <String>['admin', 'member']) {
        adapter.myRole = role;
        await pumpPage(tester);
        final Iterable<RequestOptions> emojiRequests = adapter.requests
            .where((RequestOptions r) => r.path.contains('/emoji/groups/'));
        expect(emojiRequests, isEmpty,
            reason: '★ tsx:222-223 的 effect 第一行就是 if (!isOwner) return（$role 不该发）');
      }
    });

    testWidgets('群主 ⇒ 摘要请求真的发出（证明上面的「不发」不是空断言）', (
      WidgetTester tester,
    ) async {
      adapter.myRole = 'owner';
      await pumpPage(tester);
      final Iterable<RequestOptions> emojiRequests = adapter.requests
          .where((RequestOptions r) => r.path.contains('/emoji/groups/'));
      expect(emojiRequests, hasLength(greaterThanOrEqualTo(1)),
          reason: '群主必须拉摘要（web tsx:226 getGroupEmojiPackSummary）');
      final RequestOptions first = emojiRequests.first;
      expect(first.method, 'GET');
      expect(first.path, contains('/emoji/groups/g1/pack/'));
      expect(first.queryParameters['summary'], '1',
          reason: 'api/emoji.ts:34 的 ?summary=1');
    });

    testWidgets('★ 摘要非 404 错误 ⇒ 不渲染该行（loaded 仍 false）', (WidgetTester tester) async {
      adapter.summaryStatus = 500;
      await pumpPage(tester);

      expect(switchRow(), findsNothing,
          reason: '★ tsx:238 落 managementError 且 loaded 保持 false ⇒ 行不渲染');
      expect(find.textContaining('表情上传权限加载失败'), findsOneWidget,
          reason: 'tsx:238 的文案（归一化后是后端 detail）');
    });

    testWidgets('群主但摘要 200 且开关为 false ⇒ 仍渲染（区分「未加载」与「false」）', (
      WidgetTester tester,
    ) async {
      adapter.allowMemberUpload = false;
      await pumpPage(tester);
      expect(switchRow(), findsOneWidget);
      expect(tester.widget<AylaGroupInfoSwitch>(switchRow()).value, isFalse);
    });
  });

  group('切换（web GroupInfo.tsx:252-263 / api/emoji.ts:62-67）', () {
    testWidgets('★ 点开关 ⇒ PATCH body 是 {allow_member_upload: true}，回写后端值', (
      WidgetTester tester,
    ) async {
      adapter.allowMemberUpload = false;
      await pumpPage(tester);
      expect(tester.widget<AylaGroupInfoSwitch>(switchRow()).value, isFalse);

      await tester.tap(switchRow());
      await tester.pump();
      for (int i = 0; i < 6; i += 1) {
        await tester.pump(const Duration(milliseconds: 120));
      }

      expect(adapter.patchBodies, hasLength(1),
          reason: '★ 真实 PATCH 到达（不是本地翻转）');
      expect(adapter.patchBodies.single, <String, dynamic>{'allow_member_upload': true},
          reason: 'api/emoji.ts:65 的 body 只有这一个键');
      expect(tester.widget<AylaGroupInfoSwitch>(switchRow()).value, isTrue,
          reason: 'tsx:257「setAllowMemberUpload(d.allow_member_upload)」——用**后端回值**');
    });

    testWidgets('★ 再点一次 ⇒ PATCH {allow_member_upload: false}', (WidgetTester tester) async {
      adapter.allowMemberUpload = true;
      await pumpPage(tester);

      await tester.tap(switchRow());
      for (int i = 0; i < 6; i += 1) {
        await tester.pump(const Duration(milliseconds: 120));
      }

      expect(adapter.patchBodies.single['allow_member_upload'], isFalse);
      expect(tester.widget<AylaGroupInfoSwitch>(switchRow()).value, isFalse);
    });

    testWidgets('★ 切换中 ⇒ 开关禁用（web busyAction !== null ⇒ disabled）', (
      WidgetTester tester,
    ) async {
      final Completer<void> gate = Completer<void>();
      adapter
        ..allowMemberUpload = false
        ..patchGate = gate;
      await pumpPage(tester);
      expect(tester.widget<AylaGroupInfoSwitch>(switchRow()).onChanged, isNotNull);

      await tester.tap(switchRow());
      await tester.pump();

      expect(tester.widget<AylaGroupInfoSwitch>(switchRow()).onChanged, isNull,
          reason: '★ tsx:591 的 disabled={busyAction !== null}');

      // 放行挂起的 PATCH 并走完（否则收尾报 "A Timer is still pending"）。
      adapter.patchGate = null;
      gate.complete();
      for (int i = 0; i < 6; i += 1) {
        await tester.pump(const Duration(milliseconds: 120));
      }
    });

    testWidgets('切换失败 ⇒ 值不翻转（tsx:258-262 只写 managementError）', (
      WidgetTester tester,
    ) async {
      // 让 PATCH 失败（摘要仍 200 ⇒ 行在场），断言值不乐观翻转。
      adapter.allowMemberUpload = false;
      await pumpPage(tester);
      adapter.patchStatus = 500;

      await tester.tap(switchRow());
      for (int i = 0; i < 6; i += 1) {
        await tester.pump(const Duration(milliseconds: 120));
      }

      expect(tester.widget<AylaGroupInfoSwitch>(switchRow()).value, isFalse,
          reason: '失败不得把值乐观翻转（web 只在 success 分支 setAllowMemberUpload）');
    });
  });
}
