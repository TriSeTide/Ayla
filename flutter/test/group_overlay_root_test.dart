/// 缺陷 3 回归锁：**群内弹层遮罩必须铺满整视口**（用户实报「被顶部导航栏截断」）。
///
/// ## 现象与复现（2026-10-09）
/// 用户在群里点「+」添加子群 / 语音 / 直播时，弹窗遮罩**没有盖住顶部导航栏**。
///
/// 修前实测（真实路由 + 真实 AppShell，1526×900）：
/// ```
/// 顶栏（AylaTopNav）        = (0,0)–(1526,76)
/// FAB 语音浮层遮罩           = (0,0)–(1526,900)   ✅ 本来就对
/// 侧栏「+」语音浮层遮罩      = (0,76)–(1526,900)   ❌ 顶栏那一条不压暗
/// 群信息页「添加子群」遮罩   = (368,76)–(1526,900) ❌ 同上 + 左边界也被截
/// 群信息页「转让群主」遮罩   = (368,76)–(1526,900) ❌ 同上
/// 群信息页「解散群聊」遮罩   = (368,76)–(1526,900) ❌ 同上
/// ```
///
/// ## 根因
/// AppShell 装配为 `Column[TopNav, Expanded(内容), BottomTabs]`（`layout/app_shell.dart`），
/// 而 go_router 的 `ShellRoute` 把页面放进 **shell navigator 的 Overlay** ——
/// 那一层 Overlay 的**上边界在顶栏之下**。挂在「组件所在那层 Overlay」的
/// `position: fixed` 语义遮罩因此只覆盖内容区。
///
/// ## 事实源（web）
/// 弹层全部 `createPortal(…, document.body)`，注释原文写明理由：
/// - `layout/CreateSheet.tsx:38 / 58–59`（「调用处（如 ChannelSidebar 的 backdrop-filter
///   玻璃侧栏）会创建 stacking context，成为 fixed 后代的 containing block →
///   弹层被裁剪/束缚在容器内」）
/// - `components/group/SubGroupDialog.tsx:41–42 / 108–109`（同义）
/// - `components/ConfirmDialog.tsx:52 / 118`
/// - `styles/private.css:185` / `group.css:2131–2143`：`.create-sheet-overlay` /
///   `.subgroup-dialog-overlay` 都是 `position: fixed; inset: 0` ⇒ **整视口**。
///
/// ## 修法
/// 新增 `AylaRootOverlay`（`widgets/shell/create_sheet.dart`）——
/// `OverlayPortal` + `OverlayChildLocation.rootOverlay`。**不是**
/// `Overlay.of(context, rootOverlay: true).insert(entry)`：entry 是独立子树、
/// 祖先链断在 Overlay（`overlay_host_test.dart` 记的 `FocusScope` 断言失败即此因），
/// 而 `OverlayPortal` 的 overlay child 仍是本 widget 的后代子树。
///
/// ⚠️ **portal 由调用方容器开一个、同组弹层共用一个**：每层各开一个会让同级弹层的
/// 层序不可控（实测「编辑子群 → 删除二次确认」被压在下层、点不中）。
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
import '../lib/widgets/group/subgroup_dialog.dart';
import '../lib/widgets/group/transfer_owner_dialog.dart';
import '../lib/widgets/shell/create_sheet.dart';
import '../lib/widgets/shell/top_nav.dart';

Map<String, dynamic> _page(List<Map<String, dynamic>> r) => <String, dynamic>{
  'results': r,
  'next_cursor': null,
  'has_more': false,
  'total': r.length,
};

class _Adapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final String path = options.path;
    Object? body = <String, dynamic>{};
    if (path.endsWith('/subgroups/')) {
      body = _page(<Map<String, dynamic>>[
        for (int i = 1; i <= 4; i += 1)
          <String, dynamic>{
            'id': 'sg$i',
            'conversation_id': 'g1',
            'name': '子群 $i',
            'is_default': i == 1,
            'unread_count': 0,
          },
      ]);
    } else if (path.endsWith('/members/')) {
      body = _page(<Map<String, dynamic>>[
        for (int i = 1; i <= 4; i += 1)
          <String, dynamic>{
            'id': 'm$i',
            'role': i == 1 ? 'owner' : 'member',
            'user': <String, dynamic>{
              'id': 'u$i',
              'username': 'user$i',
              'nickname': '成员 $i',
              'online': false,
            },
          },
      ]);
    } else if (path.endsWith('/join-requests/')) {
      body = _page(const <Map<String, dynamic>>[]);
    } else if (path.contains('/voice/channels/')) {
      // 语音房详情/列表：`owner_id == 登录用户` ⇒ `isOwner` 真 ⇒ 渲染「删除房间」
      // （`voice_support.dart:999` 的 `channel.ownerId == selfId`）。
      body = <String, dynamic>{
        'id': 1,
        'name': '测试语音房',
        'room_name': '测试语音房',
        'conversation_id': 'g1',
        'owner_id': 'u9',
        'owner_nickname': '我',
        'member_count': 1,
        'mine': true,
        'created_at': '2026-01-01T00:00:00Z',
      };
    } else if (path.contains('/chat/conversations/g1/')) {
      body = <String, dynamic>{
        'id': 'g1',
        'type': 'group',
        'title': '星海观测站',
        'announcement': '一起看星星',
        'avatar': '',
        'join_policy': 'application',
        'owner_id': 'u1',
        'my_role': 'owner',
        'member_count': 4,
        'created_at': '2026-01-01T00:00:00Z',
      };
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

  final _Adapter adapter = _Adapter();

  setUpAll(() {
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
      ..setUser(
        // 语音房「删除房间」需要 `ownerId == selfId`（`voice_support.dart:999`）才渲染。
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
    final GoRouter router = container.read(appRouterProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: buildAylaTheme(),
          builder: (BuildContext context, Widget? child) => Scaffold(
            backgroundColor: Colors.transparent,
            body: child,
          ),
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

  /// 点击入口（弹层入口在滚动内容里，可能不在视口内 ⇒ 先滚到可见）。
  ///
  /// ⚠️ **先量再滚**：入口已在视口内时不动滚动位置 —— `ensureVisible` 对已可见的
  /// 目标也会触发一次对齐滚动，实测会把入口滚离命中区、点击落空。
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    expect(finder, findsWidgets, reason: '被点的入口必须在树中');
    final Rect rect = tester.getRect(finder.first);
    final Size vp = tester.view.physicalSize / tester.view.devicePixelRatio;
    if (rect.top < 0 || rect.bottom > vp.height) {
      await tester.ensureVisible(finder.first);
      await settle(tester);
    }
    await tester.tap(finder.first, warnIfMissed: false);
    await settle(tester);
  }

  /// 遮罩必须铺满**整视口**（web `position: fixed; inset: 0`）。
  ///
  /// [maskOf] 给出「承载遮罩的那个 widget」：多数弹层用 [AylaModalOverlay]，
  /// 而 [AylaTransferOwnerDialog] 自带 `Container(color: rgba(70,91,146,.25))`
  /// 作遮罩根（web `.group-transfer-overlay`，`app.css:3889–3898`）⇒ 按类型区分。
  void expectFullViewport(
    WidgetTester tester,
    Size size,
    String what, {
    Finder? maskOf,
  }) {
    final Finder overlay = maskOf ?? find.byType(AylaModalOverlay);
    expect(overlay, findsWidgets, reason: '$what 的遮罩必须在场');
    final Rect rect = tester.getRect(overlay.first);
    expect(rect.left, 0, reason: '$what：遮罩左边界必须是视口左沿');
    expect(rect.top, 0, reason: '$what：遮罩**必须盖住顶栏**（修前从 y=76 起，见文件头实测）');
    expect(rect.right, size.width, reason: '$what：遮罩右边界必须是视口右沿');
    expect(rect.bottom, size.height, reason: '$what：遮罩下边界必须是视口下沿');
  }

  for (final ({String name, Size size}) cfg in <({String name, Size size})>[
    (name: '宽屏', size: const Size(1526, 900)),
    (name: '窄屏', size: const Size(400, 760)),
  ]) {
    testWidgets('${cfg.name}：群信息页「添加子群」遮罩铺满整视口（含顶栏）', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle h = tester.ensureSemantics();
      final GoRouter router = await pumpApp(tester, cfg.size);
      router.go('/group/g1/info');
      await settle(tester);

      // 顶部导航必须真的在视口顶部 —— 否则「遮罩盖住顶栏」这个判据无意义。
      final Finder topNav = find.byType(AylaTopNav);
      if (topNav.evaluate().isNotEmpty) {
        expect(tester.getRect(topNav).top, 0, reason: '宽屏 TopNav 在视口顶');
      }

      final Finder edit = find.text('编辑子群');
      await tester.ensureVisible(edit.first);
      await settle(tester);
      await tester.tap(edit.first, warnIfMissed: false);
      await settle(tester);

      final Finder add = find.text('添加子群');
      await tester.ensureVisible(add.first);
      await settle(tester);
      await tester.tap(add.first, warnIfMissed: false);
      await settle(tester);

      expect(find.byType(AylaSubGroupDialog), findsOneWidget);
      expectFullViewport(tester, cfg.size, '${cfg.name} 添加子群');
      expect(tester.takeException(), isNull);
      h.dispose();
    });

    testWidgets('${cfg.name}：群信息页「转让群主」遮罩铺满整视口（含顶栏）', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle h = tester.ensureSemantics();
      final GoRouter router = await pumpApp(tester, cfg.size);
      router.go('/group/g1/info');
      await settle(tester);
      await tapVisible(tester, find.text('转让群主'));

      expect(find.byType(AylaTransferOwnerDialog), findsOneWidget);
      expectFullViewport(tester, cfg.size, '${cfg.name} 转让群主', maskOf: find.byType(AylaTransferOwnerDialog));
      expect(tester.takeException(), isNull);
      h.dispose();
    });
  }

  testWidgets('宽屏：群信息页「解散群聊」确认框遮罩铺满整视口（含顶栏）', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle h = tester.ensureSemantics();
    const Size size = Size(1526, 900);
    final GoRouter router = await pumpApp(tester, size);
    router.go('/group/g1/info');
    await settle(tester);
    await tapVisible(tester, find.text('解散群聊'));

    expect(find.text('确定解散群聊'), findsNothing); // 标题在 head 里，不在正文
    expectFullViewport(tester, size, '解散群聊');
    expect(tester.takeException(), isNull);
    h.dispose();
  });

  testWidgets('宽屏：侧栏「+」语音浮层遮罩铺满整视口（含顶栏）', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle h = tester.ensureSemantics();
    const Size size = Size(1526, 900);
    final GoRouter router = await pumpApp(tester, size);
    router.go('/group/g1');
    await settle(tester);
    await tapVisible(tester, find.bySemanticsLabel('创建语音房'));

    expect(find.byType(AylaCreateSheet), findsOneWidget);
    expectFullViewport(tester, size, '侧栏语音浮层');
    expect(tester.takeException(), isNull);
    h.dispose();
  });

  testWidgets('宽屏：侧栏「+」直播浮层遮罩铺满整视口（含顶栏）', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle h = tester.ensureSemantics();
    const Size size = Size(1526, 900);
    final GoRouter router = await pumpApp(tester, size);
    router.go('/group/g1');
    await settle(tester);
    await tapVisible(tester, find.bySemanticsLabel('创建直播'));

    expect(find.byType(AylaCreateSheet), findsOneWidget);
    expectFullViewport(tester, size, '侧栏直播浮层');
    expect(tester.takeException(), isNull);
    h.dispose();
  });

  testWidgets('宽屏：群内语音页 FAB 浮层遮罩铺满整视口（对照组，本来就对）', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle h = tester.ensureSemantics();
    const Size size = Size(1526, 900);
    final GoRouter router = await pumpApp(tester, size);
    router.go('/group/g1/voice');
    await settle(tester);
    await tapVisible(tester, find.bySemanticsLabel('创建群内语音房'));

    expect(find.byType(AylaCreateSheet), findsOneWidget);
    expectFullViewport(tester, size, 'FAB 语音浮层');
    expect(tester.takeException(), isNull);
    h.dispose();
  });

  /// 语音房**一级页面**（`/voice/:channelId`）的「删除房间」确认框。
  ///
  /// 现象（2026-10-09 用户实报同族问题后普查发现）：遮罩只有 `(0,76)–(1526,900)`，
  /// **顶栏那一整条不被压暗**。
  ///
  /// 根因：`pages/voice_support.dart:1166–1175` 把 `AylaConfirmDialog` 放在页内
  /// `Positioned.fill(...)` 里 ⇒ 落在 shell navigator 的那层 Overlay
  /// （其上边界在顶栏之下，`layout/app_shell.dart` 的 `Column[TopNav, Expanded(内容)]`）。
  ///
  /// 依据（web）：`components/ConfirmDialog.tsx:10 / 52 / 118` 自身
  /// `createPortal(…, document.body)` ⇒ 遮罩 `position: fixed; inset: 0`
  /// （`styles/private.css:185` 的 `.create-sheet-overlay`）= **整视口**。
  /// 调用点 `pages/VoiceHubPage.tsx:238–255`（一级）与
  /// `pages/group/GroupVoice.tsx:177–195`（群内）都只是把 `<ConfirmDialog>` 平铺在
  /// 页面 JSX 里，**靠弹层自身的 portal 逃出容器**。
  ///
  /// 修法：换成 `AylaRootOverlay(builder: ...)` ⇒ 挂根 Overlay。
  testWidgets('宽屏：语音房「删除房间」确认框遮罩铺满整视口（含顶栏）', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle h = tester.ensureSemantics();
    const Size size = Size(1526, 900);
    final GoRouter router = await pumpApp(tester, size);
    router.go('/voice/1');
    await settle(tester);

    final Finder del = find.text('删除房间');
    expect(del, findsWidgets, reason: '房主视角必须有「删除房间」');
    await tapVisible(tester, del);

    expect(find.text('确定删除语音房'), findsNothing); // 标题在 head 里
    expectFullViewport(tester, size, '语音房删除确认框');
    expect(tester.takeException(), isNull);
    h.dispose();
  });
}
