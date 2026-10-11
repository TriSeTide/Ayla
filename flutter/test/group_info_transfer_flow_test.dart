/// 缺陷 1 回归锁：**群主转让全链路**（用户实报「转让群的问题」）。
///
/// ## 事实源（web，逐条）
/// ```
/// GroupInfo.tsx:106–111   transferOpen / confirmAction（kind:"transfer"）两个 state
/// GroupInfo.tsx:356–361   confirmTransfer：transferGroupOwner → 成功后才 setTransferOpen(false)
/// GroupInfo.tsx:629–631   管理卡「转让群主」ghost 键（**无 disabled**）
/// GroupInfo.tsx:797–805   <TransferOwnerDialog busy={busyAction==="transfer"} error onConfirm onClose/>
/// GroupInfo.tsx:875–889   二次确认 ConfirmDialog（confirmLabel「转让」，
///                         onConfirm：setConfirmAction(null) → confirmTransfer(m)）
/// GroupInfo.tsx:917–923   弹窗内部 state：query + selected；候选页 =
///                         useSocialPage("members", { groupId, q: query, excludeSelf: true })
/// GroupInfo.tsx:945–954   搜索框 onChange → setQuery（重查）
/// GroupInfo.tsx:955–988   候选行：点行 setSelected(m) + aria-pressed
/// GroupInfo.tsx:989       「已选择：{名}」
/// GroupInfo.tsx:994–1005  取消（busy 禁用）/ 确认转让（!selected || busy ⇒ disabled）
/// ```
///
/// ## 本轮修前实测（复现证据，2026-10-09）
/// `pages/group_info_page.dart` 把转让弹窗当**静态投影**渲染：
/// ```
/// :551  selectedId: null,            // 恒 null
/// :552  query: '',                   // 恒空
/// :553  onQueryChanged: (String _) {},   // 空实现
/// 无 onSelect                        // ⇒ 组件内 onTap 恒为 null
/// ```
/// ⇒ 点任何候选行**零反应** ⇒ `selected` 恒 null ⇒ 确认键恒禁用 ⇒ **转让功能完全不可用**；
/// 搜索框输入不触发重查。以下用例 2/3/4/5 在修前全部为红（见交付报告的失败输出）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/net/dio_client.dart';
import '../lib/pages/group_info_page.dart';
import '../lib/state/auth_state.dart';
import '../lib/theme/app_theme.dart';
import '../lib/theme/glass.dart' show AylaGlassButton;
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/group/transfer_owner_dialog.dart';
import '../lib/widgets/group/group_info_manage.dart';

Map<String, dynamic> _page(List<Map<String, dynamic>> results, {int? total}) =>
    <String, dynamic>{
      'results': results,
      'next_cursor': null,
      'has_more': false,
      'total': total ?? results.length,
    };

class _TransferAdapter implements HttpClientAdapter {
  /// 全部成员（含自己 u9 与群主 u1）。
  final List<Map<String, dynamic>> members = <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'm1',
      'role': 'owner',
      'user': <String, dynamic>{
        'id': 'u1',
        'username': 'owner',
        'nickname': '群主甲',
        'online': false,
      },
    },
    <String, dynamic>{
      'id': 'm2',
      'role': 'admin',
      'user': <String, dynamic>{
        'id': 'u2',
        'username': 'sakura',
        'nickname': '小樱',
        'online': true,
      },
    },
    <String, dynamic>{
      'id': 'm3',
      'role': 'member',
      'user': <String, dynamic>{
        'id': 'u3',
        'username': 'kero',
        'nickname': '小可',
        'online': false,
      },
    },
    <String, dynamic>{
      'id': 'm9',
      'role': 'owner',
      'user': <String, dynamic>{
        'id': 'u9',
        'username': 'me',
        'nickname': '我',
        'online': true,
      },
    },
  ];

  /// 当前登录用户（＝群主本人）。
  String selfId = 'u9';

  /// 已发生转让 ⇒ 之后的 metadata 返回 `my_role: member`（后端权威口径）。
  bool transferred = false;

  /// 转让接口被调用的次数与实参。
  final List<Map<String, dynamic>> transferCalls = <Map<String, dynamic>>[];

  /// 全部请求（path + query），供搜索断言。
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final String path = options.path;
    Object? body = <String, dynamic>{};
    int status = 200;

    if (path.endsWith('/transfer-owner/')) {
      transferCalls.add(<String, dynamic>{...options.data as Map<String, dynamic>});
      transferred = true;
      body = _conv(myRole: 'member');
    } else if (path.endsWith('/members/')) {
      // 服务端过滤：exclude_self=1 排除自己；q 按昵称/用户名过滤。
      final bool excludeSelf = '${options.queryParameters['exclude_self']}' == '1';
      final String q = '${options.queryParameters['q'] ?? ''}';
      final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[
        for (final Map<String, dynamic> m in members)
          if (!excludeSelf ||
              (m['user'] as Map<String, dynamic>)['id'] != selfId)
            if (q.isEmpty ||
                '${(m['user'] as Map<String, dynamic>)['nickname']}'
                        '${(m['user'] as Map<String, dynamic>)['username']}'
                    .contains(q))
              m,
      ];
      body = _page(rows, total: rows.length);
    } else if (path.endsWith('/subgroups/')) {
      body = _page(const <Map<String, dynamic>>[]);
    } else if (path.endsWith('/join-requests/')) {
      body = _page(const <Map<String, dynamic>>[]);
    } else if (path.contains('/chat/conversations/g1/')) {
      body = _conv(myRole: transferred ? 'member' : 'owner');
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: <String, List<String>>{
        'content-type': <String>['application/json; charset=utf-8'],
      },
    );
  }

  Map<String, dynamic> _conv({required String myRole}) => <String, dynamic>{
    'id': 'g1',
    'type': 'group',
    'title': '星海观测站',
    'announcement': '一起看星星',
    'avatar': '',
    'join_policy': 'application',
    'owner_id': 'u9',
    'my_role': myRole,
    'member_count': 4,
    'created_at': '2026-01-01T00:00:00Z',
  };

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

const Size kViewport = Size(1526, 900);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _TransferAdapter adapter;

  setUpAll(() {
    adapter = _TransferAdapter();
    DioClient.instance.init(tokenStore: _NoTokens(), onSessionExpired: () {});
    DioClient.instance.dio.httpClientAdapter = adapter;
  });

  setUp(() {
    adapter
      ..transferred = false
      ..selfId = 'u9'
      ..transferCalls.clear()
      ..requests.clear();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(kViewport);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // 当前登录用户 = 群主本人 u9（web `auth.currentUser.id`；`currentUserId` 参与
    // 「排除自己」与「我」chip 两条判据 ⇒ 必须注入，否则用例假红）。
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(authNotifierProvider.notifier)
      ..setTokens('a', 'r')
      ..setUser(
        const AuthUser(
          id: 'u9',
          username: 'me',
          nickname: '我',
          avatar: '',
          signature: '',
          status: '',
          online: true,
          displayStatus: '',
          dateJoined: '',
          isInVoice: false,
          voiceRoomId: null,
          isLive: false,
          liveRoomId: null,
          showContent: true,
          email: '',
        ),
      );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAylaTheme(),
          home: previewScope(
            Builder(
              builder: (BuildContext context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(size: kViewport),
                child: SizedBox.fromSize(
                  size: kViewport,
                  child: const GroupInfoPage(groupId: 'g1'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    for (int i = 0; i < 8; i += 1) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  /// 打开转让弹窗（管理卡「转让群主」ghost 键）。
  Future<void> openTransfer(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(AylaGlassButton, '转让群主'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AylaTransferOwnerDialog), findsOneWidget);
  }

  /// 弹窗**内**的文本锚点（成员卡里有同名成员文本 ⇒ 必须限定在弹窗子树）。
  Finder inDialog(String text) => find.descendant(
    of: find.byType(AylaTransferOwnerDialog),
    matching: find.text(text),
  );

  /// 弹窗内的候选行（web tsx 961–966 的 `.group-transfer-row` 按钮）。
  Finder transferRow(String name) =>
      find.ancestor(of: inDialog(name), matching: find.byType(GestureDetector));

  /// 弹窗内的搜索框（成员卡也有一个 `.field` ⇒ 必须限定在弹窗子树）。
  Finder transferSearchField() => find.descendant(
    of: find.byType(AylaTransferOwnerDialog),
    matching: find.byType(TextField),
  );

  AylaGlassButton confirmButton(WidgetTester tester) => tester
      .widgetList<AylaGlassButton>(
        find.descendant(
          of: find.byType(AylaTransferOwnerDialog),
          matching: find.byType(AylaGlassButton),
        ),
      )
      .last;

  testWidgets('① 点「转让群主」⇒ 弹窗在场，候选排除自己（exclude_self）', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester);
    await openTransfer(tester);

    // web tsx 922 的 `excludeSelf: true` ⇒ 自己（我）不进候选。
    // ⚠️ 限定在**弹窗内**：成员卡里本人那一行仍然照常显示「我」。
    final Finder inDialog = find.descendant(
      of: find.byType(AylaTransferOwnerDialog),
      matching: find.text('我'),
    );
    expect(inDialog, findsNothing, reason: 'exclude_self=1 必须真的排除自己');
    expect(
      find.descendant(
        of: find.byType(AylaTransferOwnerDialog),
        matching: find.text('小樱'),
      ),
      findsOneWidget,
    );
    // 群主自身也由 tsx 923 的 `role !== "owner"` 过滤（本人是 owner ⇒ 也不在）。
    expect(
      find.descendant(
        of: find.byType(AylaTransferOwnerDialog),
        matching: find.text('群主甲'),
      ),
      findsNothing,
      reason: 'web tsx 923 的 `filter(m => m.role !== "owner")`',
    );
    expect(
      adapter.requests.any(
        (RequestOptions r) =>
            r.path.endsWith('/members/') &&
            '${r.queryParameters['exclude_self']}' == '1',
      ),
      isTrue,
      reason: 'web tsx 922 的候选页必须带 `exclude_self=1`（服务端排除自己）',
    );
  });

  testWidgets('② 点候选行 ⇒ 出现「已选择：X」且确认键可用（修前：零反应）', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester);
    await openTransfer(tester);

    expect(confirmButton(tester).onPressed, isNull, reason: '未选中 ⇒ disabled（tsx 1002）');

    await tester.tap(transferRow('小樱').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      find.text('已选择：小樱'),
      findsOneWidget,
      reason: 'web tsx 989：选中后必须出现「已选择：{名}」'
          '（修前 onSelect 未接线 ⇒ 点行零反应）',
    );
    expect(
      confirmButton(tester).onPressed,
      isNotNull,
      reason: 'web tsx 1002：selected != null 且非 busy ⇒ 确认键可用（修前恒 disabled）',
    );
  });

  testWidgets('③ 搜索框输入 ⇒ 重新查询带 q=（修前：空实现，无重查）', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester);
    await openTransfer(tester);

    adapter.requests.clear();
    await tester.enterText(transferSearchField(), '小可');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final bool searched = adapter.requests.any(
      (RequestOptions r) =>
          r.path.endsWith('/members/') && '${r.queryParameters['q']}' == '小可',
    );
    expect(
      searched,
      isTrue,
      reason: 'web tsx 922 的候选页带 `q: query` ⇒ 输入必须触发带 q 的重查'
          '（修前 onQueryChanged 是空实现）',
    );
  });

  testWidgets('④ 确认转让 ⇒ 二次确认弹窗；转让弹窗**保持在场**（web tsx 802/359）', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester);
    await openTransfer(tester);
    await tester.tap(transferRow('小樱').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(inDialog('确认转让'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // tsx 875–889：二次确认框（confirmLabel「转让」，文案含「转让后你将成为普通成员」）。
    expect(find.text('转让'), findsOneWidget, reason: 'web tsx 881 的确认键文案是「转让」');
    expect(
      find.textContaining('转让后你将成为普通成员'),
      findsWidgets,
    );
    // ⚠️ tsx 802 只 setConfirmAction、**不动 transferOpen** ⇒ 选择弹窗仍在（busy 态）。
    expect(
      find.byType(AylaTransferOwnerDialog),
      findsOneWidget,
      reason: 'web tsx 802/359：转让弹窗要等接口成功后才关（修前：点确认立刻关掉）',
    );
  });

  testWidgets('⑤ 二次确认 ⇒ POST transfer-owner {user_id}，成功后关弹窗', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester);
    await openTransfer(tester);
    await tester.tap(transferRow('小樱').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(inDialog('确认转让'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('转让').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(adapter.transferCalls.length, 1, reason: 'web tsx 358 的接口调用');
    expect(adapter.transferCalls.single['user_id'], 'u2');
    expect(
      find.byType(AylaTransferOwnerDialog),
      findsNothing,
      reason: 'web tsx 359：成功后 setTransferOpen(false)',
    );
  });

  testWidgets('⑥ 转让成功后本地状态刷新：管理卡降级为「更多」+ 出现「退出群聊」', (
    WidgetTester tester,
  ) async {
    await pumpPage(tester);
    // 修前形状：管理卡是「管理」（本人 owner）
    expect(find.text('管理'), findsOneWidget);

    await openTransfer(tester);
    await tester.tap(transferRow('小樱').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(inDialog('确认转让'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('转让').last);
    await tester.pump();
    for (int i = 0; i < 8; i += 1) {
      await tester.pump(const Duration(milliseconds: 120));
    }

    // web：转让后当前用户降为普通成员 ⇒ canManage=false ⇒ 卡头「管理」→「更多」，
    // 危险操作区（转让/解散）消失，改为「退出群聊」（tsx 640–644）。
    expect(
      find.text('更多'),
      findsOneWidget,
      reason: '转让后 my_role=member ⇒ canManage=false（web tsx 525）',
    );
    expect(find.text('退出群聊'), findsOneWidget, reason: 'web tsx 641–643');
    expect(find.widgetWithText(AylaGlassButton, '转让群主'), findsNothing);
    expect(find.byType(AylaGroupInfoDangerActions), findsOneWidget);
  });
}
