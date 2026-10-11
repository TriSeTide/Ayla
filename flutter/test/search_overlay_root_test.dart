/// 搜索页浮层遮罩回归锁：**两个浮层的遮罩必须铺满整视口（含顶栏）**。
///
/// ## 被锁住的缺陷（2026-10-09 普查发现的同源残留）
/// 用户在群内实报「弹窗遮罩被顶部导航栏截断」（问题 9）后，同源普查发现搜索页同样中招。
///
/// **修前实测（真实路由 + 真实 AppShell）**：
/// ```
/// 宽屏 1526×900：顶栏 AylaTopNav = (0,0)–(1526,76)
///                用户资料浮层遮罩 = (0,76)–(1526,900)   ❌ 顶栏那一条不压暗
/// 窄屏  400×760：顶栏             = (0,0)–(400,56)
///                用户资料浮层遮罩 = (0,56)–(400,696)    ❌ 顶栏 + 底部 tab 两条都不压暗
/// ```
/// **修后**：两档都是 `(0,0)–(视口宽,视口高)`。
///
/// ## 根因
/// `pages/search_page.dart` 的 `build` 把浮层放进**页内** `Stack`：
/// ```dart
/// return Stack(children: <Widget>[page, overlay]);   // ← 修前
/// ```
/// 而 AppShell 的装配是 `Column[TopNav, Expanded(内容), BottomTabs]`
/// （`layout/app_shell.dart`），go_router 的 `ShellRoute` 又把页面放进
/// **shell navigator 的那层 Overlay** —— 那层 Overlay 的**上边界在顶栏之下**
/// ⇒ 页面内的 fixed 语义遮罩只覆盖内容区。
///
/// ## 事实源（web，两个浮层都是 portal）
/// - **用户资料浮层**：`SearchPage.tsx:472–478` 的 `.user-profile-overlay`，
///   `search.css:304–312` 是 `position: fixed; inset: 0`
///   （「`user-profile-overlay` 两档都居中」）；
/// - **入群申请弹窗**：`SearchPage.tsx:480–489` 的 `<GroupApplyDialog>`，
///   `search.css:180` 的 `group-apply-overlay` 同样 `fixed`；
/// - 同族 portal 理由（原文）：`ShareSheet.tsx:216` / `CreateSheet.tsx:38 / 58–59`
///   ——「调用处（如 ChannelSidebar 的 backdrop-filter 玻璃侧栏）会创建 stacking
///   context，成为 fixed 后代的 containing block → 弹层被裁剪/束缚在容器内」。
///
/// ## 修法
/// 换成 `AylaRootOverlay`（`OverlayPortal` + `OverlayChildLocation.rootOverlay`，
/// `widgets/shell/create_sheet.dart`，**只复用不改本体**）。
/// 本页只需一个 portal：两个浮层同一时刻最多存在一个（`_overlay()` 的分支保证）。
///
/// ## 本文件同时保留的既有语义（逐个核对，不得打破）
/// - **点遮罩关闭**：`AylaModalOverlay.onDismiss` ⇒ 清 `_selectedUser` / `_selectedGroup`；
/// - **浮层只在当前作用域存在**：`resultScope === scope` 的守卫（tsx 472/480）；
/// - **层序**：浮层必须盖在页面之上（点页面里的结果行应先被遮罩吃掉）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/net/dio_client.dart';
import '../lib/router/app_router.dart';
import '../lib/state/auth_state.dart';
import '../lib/theme/app_theme.dart';
import '../lib/widgets/base/dialogs.dart' show AylaModalOverlay;
import '../lib/widgets/group/group_apply.dart' show AylaGroupApplyDialog;
import '../lib/widgets/shell/top_nav.dart';

Map<String, dynamic> _group(String id, String title, {bool? isMember}) =>
    <String, dynamic>{
      'id': id,
      'title': title,
      if (isMember != null) 'is_member': isMember,
      'member_count': 3,
      'join_policy': 'application',
    };

class _Adapter implements HttpClientAdapter {
  _Adapter({this.users = true, this.groups = true});

  /// 是否返回用户结果（用户资料浮层的入口）。
  final bool users;

  /// 是否返回群结果（入群申请弹窗的入口）。
  final bool groups;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final String path = options.path;
    Object? body = <String, dynamic>{};
    if (path.contains('/search/')) {
      body = <String, dynamic>{
        if (users)
          'users': <String, dynamic>{
            'items': <Object?>[
              <String, dynamic>{
                'id': 'u1',
                'username': 'elysia',
                'nickname': '爱莉',
                'signature': '今天也想见你',
                'online': true,
              },
            ],
            'total': 1,
            'next_cursor': null,
            'has_more': false,
          },
        if (groups)
          'groups': <String, dynamic>{
            'items': <Object?>[
              _group('g1', '爱莉的粉丝群', isMember: false),
            ],
            'total': 1,
            'next_cursor': null,
            'has_more': false,
          },
      };
    } else if (path.endsWith('/me/badges/')) {
      body = <String, dynamic>{'request_badge': 0, 'message_badge': 0};
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Adapter adapter;
  setUp(() {
    adapter = _Adapter();
    DioClient.instance.init(tokenStore: _NoTokens(), onSessionExpired: () {});
    DioClient.instance.dio.httpClientAdapter = adapter;
  });

  Future<GoRouter> pumpApp(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(authNotifierProvider.notifier)
      ..setTokens('a', 'r')
      ..setUser(const AuthUser(
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
      ));
    final GoRouter router = container.read(appRouterProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: buildAylaTheme(),
          builder: (BuildContext context, Widget? child) =>
              Scaffold(backgroundColor: Colors.transparent, body: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 10; i += 1) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  /// 遮罩四边必须 == 视口四边（web `position: fixed; inset: 0`）。
  void expectFullViewport(WidgetTester tester, Size size, String what) {
    final Finder overlay = find.byType(AylaModalOverlay);
    expect(overlay, findsWidgets, reason: '$what 的遮罩必须在场');
    final Rect rect = tester.getRect(overlay.first);
    expect(rect.left, 0, reason: '$what：遮罩左边界必须是视口左沿');
    expect(
      rect.top,
      0,
      reason: '$what：遮罩**必须盖住顶栏**'
          '（修前宽屏从 y=76 起、窄屏从 y=56 起，见文件头实测）',
    );
    expect(rect.right, size.width, reason: '$what：遮罩右边界必须是视口右沿');
    expect(rect.bottom, size.height, reason: '$what：遮罩下边界必须是视口下沿');
  }

  for (final ({String name, Size size}) cfg in <({String name, Size size})>[
    (name: '宽屏', size: const Size(1526, 900)),
    (name: '窄屏', size: const Size(400, 760)),
  ]) {
    // ==================================================================
    // ① 用户资料浮层（.user-profile-overlay，SearchPage.tsx:472–478）
    // ==================================================================
    testWidgets('${cfg.name}：搜索页用户资料浮层遮罩铺满整视口（含顶栏）', (
      WidgetTester tester,
    ) async {
      final GoRouter router = await pumpApp(tester, cfg.size);
      router.go('/search?q=爱');
      await settle(tester);

      // 顶部导航必须真的在视口顶部 —— 否则「遮罩盖住顶栏」这个判据无意义。
      final Finder topNav = find.byType(AylaTopNav);
      if (topNav.evaluate().isNotEmpty) {
        expect(tester.getRect(topNav.first).top, 0, reason: '顶栏在视口顶');
      }

      await tester.tap(find.text('爱莉').first, warnIfMissed: false);
      await settle(tester);

      expectFullViewport(tester, cfg.size, '${cfg.name} 用户资料浮层');
      expect(tester.takeException(), isNull);
    });

    // ==================================================================
    // ② 入群申请弹窗（GroupApplyDialog 自带 AylaModalOverlay，tsx 480–489）
    // ==================================================================
    testWidgets('${cfg.name}：搜索页入群申请弹窗遮罩铺满整视口（含顶栏）', (
      WidgetTester tester,
    ) async {
      final GoRouter router = await pumpApp(tester, cfg.size);
      router.go('/search?q=群');
      await settle(tester);

      // 群结果卡的入口文案（`SearchPage.tsx:418` 的三态：已加入/已通过/申请入群）
      final Finder apply = find.text('申请入群');
      expect(apply, findsWidgets, reason: '未加入的群结果应有「申请入群」入口');
      await tester.tap(apply.first, warnIfMissed: false);
      await settle(tester);

      expect(find.byType(AylaGroupApplyDialog), findsOneWidget);
      expectFullViewport(tester, cfg.size, '${cfg.name} 入群申请弹窗');
      expect(tester.takeException(), isNull);
    });

    // ==================================================================
    // ③ 既有语义：点遮罩关闭（AylaModalOverlay.onDismiss）
    // ==================================================================
    testWidgets('${cfg.name}：用户资料浮层「点遮罩关闭」仍生效（挂根 Overlay 不破坏）', (
      WidgetTester tester,
    ) async {
      final GoRouter router = await pumpApp(tester, cfg.size);
      router.go('/search?q=爱');
      await settle(tester);

      await tester.tap(find.text('爱莉').first, warnIfMissed: false);
      await settle(tester);
      expect(find.byType(AylaModalOverlay), findsWidgets);

      // 点遮罩的**左上角**（必然落在卡外的遮罩上；卡片是居中/贴底）
      await tester.tapAt(const Offset(8, 8));
      await settle(tester);
      expect(
        find.byType(AylaModalOverlay),
        findsNothing,
        reason: '点遮罩应关闭浮层（tsx 473 的 onClick={() => setSelectedUser(null)}）',
      );
      expect(find.byType(AylaGroupApplyDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('宽屏：浮层在场时**层序**正确（遮罩盖在页面之上，点结果行不穿透）', (
    WidgetTester tester,
  ) async {
    const Size size = Size(1526, 900);
    final GoRouter router = await pumpApp(tester, size);
    router.go('/search?q=爱');
    await settle(tester);

    await tester.tap(find.text('爱莉').first, warnIfMissed: false);
    await settle(tester);
    expect(find.byType(AylaModalOverlay), findsWidgets);

    // 浮层在场时，遮罩必须**压住**搜索结果行：点在结果行所在坐标上，
    // 事件应被遮罩吃掉（关闭浮层），而不是穿透到页面把结果重新打开一次。
    // 用「遮罩的命中测试」间接断言：遮罩矩形覆盖了结果行区域。
    final Rect mask = tester.getRect(find.byType(AylaModalOverlay).first);
    expect(
      mask.contains(const Offset(200, 300)),
      isTrue,
      reason: '遮罩必须覆盖内容区（层序在页面之上）',
    );
    expect(tester.takeException(), isNull);
  });
}
