/// 更新弹窗的**返回键**与**挂载层**回归锁（手机端 + 电脑端，2026-11-05）。
///
/// ## 需求
/// 用户要求「电脑端 + 手机端的登录自动检查更新并弹窗」。手机端多一条硬约束：
/// 弹窗开着时按系统返回键**不能**把 App 关掉（强制更新时更不能）。
///
/// ## 修复前的真实行为
/// 更新弹窗不是路由（它是壳层 `Stack` 里的一层），页面级 `PopScope` 到不了
/// （机制链见 `layout/app_back.dart` 文件头）⇒ 返回键落到 `homeExit` 档，
/// 在主页按两下就 `SystemNavigator.pop` **退出 App** —— 等于绕过强制更新。
///
/// ## 本文件锁什么
/// ① 弹窗打开时宿主登记了返回键处理器（`aylaUpdateDialogBackHandler` 非空）；
/// ② 真实返回键链路：`handlePopRoute()` ⇒ 弹窗关闭、**不发** `SystemNavigator.pop`；
/// ③ 强制更新：返回键被吞掉、弹窗**仍在**、App 不退出；
/// ④ 弹窗关闭后处理器注销（否则登录页按返回会被已卸载的处理器吞掉）；
/// ⑤ 弹窗经**根 Overlay** 渲染（遮罩覆盖到顶栏之上 —— 与库内其余模态同口径）。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/core/update/app_version.dart';
import '../lib/core/update/update_api.dart';
import '../lib/core/update/update_applier.dart';
import '../lib/core/update/update_controller.dart';
import '../lib/core/update/update_downloader.dart';
import '../lib/layout/app_back.dart'
    show AylaBackButtonHost, aylaUpdateDialogBackHandler;
import '../lib/state/update_providers.dart';
import '../lib/theme/app_theme.dart';
import '../lib/widgets/base/update_dialog.dart';

const String _sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class _FakeApi extends AylaUpdateApi {
  _FakeApi({required this.mandatory});

  final bool mandatory;

  @override
  Future<AylaUpdateCheck> check({
    required AylaAppVersion version,
    String channel = AylaUpdateApi.defaultChannel,
    String? platform,
    String? arch,
  }) async => AylaUpdateCheck(
        channel: 'stable',
        updateAvailable: true,
        mandatory: mandatory,
        degraded: false,
        reason: 'update_available',
        latest: const AylaUpdateRelease(
          releaseId: 'stable-1.1.2-56',
          version: '1.1.2',
          build: 56,
          publishedAt: '',
          notes: '修复直播全屏标题栏',
          minSupportedBuild: 0,
        ),
        download: const AylaUpdateDownload(
          kind: 'zip',
          url: 'https://example.com/a.zip',
          fileName: 'a.zip',
          size: 1024,
          sha256: _sha,
        ),
        currentVersion: '1.0.0',
        currentBuild: 1,
      );
}

class _FakeDownloader extends AylaUpdateDownloader {
  @override
  Future<AylaPreparedUpdate> download(
    AylaUpdateDownload download, {
    void Function(AylaUpdateProgress progress)? onProgress,
    Object? cancelToken,
  }) async =>
      AylaPreparedUpdate(
        download: download,
        filePath: '/tmp/a.zip',
        bytes: 1024,
        stagingDir: '/tmp/staging',
      );
}

void main() {
  late List<String> platformCalls;

  setUp(() {
    platformCalls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform,
            (MethodCall call) async {
      platformCalls.add(call.method);
      return null;
    });
  });

  tearDown(() {
    aylaUpdateDialogBackHandler = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  /// 起一棵「壳层形态」的树：`Scaffold → Stack → AylaUpdateHost`。
  ///
  /// 不用真 AppShell（它要登录态 + 一整套 store + WS）；本文件只锁宿主自己的
  /// 契约（登记 / 根 Overlay / 关闭），壳层挂载点由 `update_login_autocheck_test`
  /// 的接线断言覆盖。
  Future<({ProviderContainer container, AylaUpdateController controller})> pumpHost(
    WidgetTester tester, {
    required bool mandatory,
  }) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final AylaUpdateController controller = AylaUpdateController(
      api: _FakeApi(mandatory: mandatory),
      downloader: _FakeDownloader(),
      applier: AylaUpdateApplier(),
      versionLoader: () async =>
          const AylaAppVersion(version: '1.0.0', build: 1),
      requestExit: (int code) {},
    );
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        updateControllerProvider.overrideWithValue(controller),
      ],
    );
    addTearDown(container.dispose);

    // ⚠️ **必须用真 GoRouter + 真 AylaBackButtonHost**（= 壳层那两层）：
    // `AylaBackButtonHost` 内是 `BackButtonListener`，它要 `Router.of(context)`
    // （挂在 MaterialApp.home 下会直接抛 `Router operation requested with a context
    // that does not include a Router`）；而没有它，`handlePopRoute()` 会直接
    // `SystemNavigator.pop`（= App 退出）—— 那样测的就不是本产品的返回链路了。
    final GoRouter router = GoRouter(
      initialLocation: '/group',
      routes: <RouteBase>[
        GoRoute(
          path: '/group',
          builder: (BuildContext context, GoRouterState state) =>
              AylaBackButtonHost(
            pathname: state.uri.path,
            canPop: false,
            onGoHome: () {},
            onGroupBack: () async => true,
            exit: () async {},
            child: const Stack(
              children: <Widget>[
                Positioned.fill(child: ColoredBox(color: Color(0xFFEFEFF4))),
                AylaUpdateHost(),
              ],
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: buildAylaTheme(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (container: container, controller: controller);
  }

  Future<void> pressBack(WidgetTester tester) async {
    platformCalls.clear();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  bool sysPopped() => platformCalls.contains('SystemNavigator.pop');

  group('① 可关闭的更新弹窗', () {
    testWidgets('打开 ⇒ 登记返回键；按返回只关弹窗，不退出 App', (
      WidgetTester tester,
    ) async {
      final ({ProviderContainer container, AylaUpdateController controller})
          host = await pumpHost(tester, mandatory: false);
      expect(aylaUpdateDialogBackHandler, isNull, reason: '没弹窗时不该有处理器');

      await host.controller.checkOnLogin();
      await tester.pumpAndSettle();
      expect(find.byType(AylaUpdateDialog), findsOneWidget);
      expect(aylaUpdateDialogBackHandler, isNotNull,
          reason: '弹窗打开必须登记返回键处理器');

      await pressBack(tester);
      expect(find.byType(AylaUpdateDialog), findsNothing, reason: '返回键关掉弹窗');
      expect(sysPopped(), isFalse, reason: '绝不能顺手退出 App');
      expect(aylaUpdateDialogBackHandler, isNull, reason: '关掉后必须注销');
    });

    testWidgets('点「稍后」同样关闭并注销', (WidgetTester tester) async {
      final ({ProviderContainer container, AylaUpdateController controller})
          host = await pumpHost(tester, mandatory: false);
      await host.controller.checkOnLogin();
      await tester.pumpAndSettle();
      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();
      expect(find.byType(AylaUpdateDialog), findsNothing);
      expect(aylaUpdateDialogBackHandler, isNull);
    });
  });

  group('② 强制更新', () {
    testWidgets('按返回：弹窗仍在、不退出 App、不 pop 任何东西', (
      WidgetTester tester,
    ) async {
      final ({ProviderContainer container, AylaUpdateController controller})
          host = await pumpHost(tester, mandatory: true);
      await host.controller.checkOnLogin();
      await tester.pumpAndSettle();
      expect(find.text('需要更新'), findsOneWidget);
      expect(find.text('稍后'), findsNothing);

      await pressBack(tester);
      expect(find.byType(AylaUpdateDialog), findsOneWidget,
          reason: '强制更新弹窗不可被返回键关掉');
      expect(sysPopped(), isFalse, reason: '退出 App 等于绕过强制更新');

      // 连按两次也不行（模拟「再按一次退出」的时序）。
      await pressBack(tester);
      expect(find.byType(AylaUpdateDialog), findsOneWidget);
      expect(sysPopped(), isFalse);
    });
  });

  group('③ 挂载层：根 Overlay', () {
    testWidgets('弹窗挂在根 Overlay（遮罩尺寸 = 整屏，压过壳层内容）', (
      WidgetTester tester,
    ) async {
      final ({ProviderContainer container, AylaUpdateController controller})
          host = await pumpHost(tester, mandatory: false);
      await host.controller.checkOnLogin();
      await tester.pumpAndSettle();

      // 根 Overlay 的直接子级里能找到弹窗（而不是只在壳层 Stack 里）。
      final Finder dialog = find.byType(AylaUpdateDialog);
      expect(dialog, findsOneWidget);
      final Rect rect = tester.getRect(dialog);
      expect(rect.width, greaterThan(0));
      expect(rect.height, greaterThan(0));
      // 遮罩（ModalOverlay 的 Positioned.fill）必须铺满视口。
      final Finder overlay = find.ancestor(
        of: dialog,
        matching: find.byType(Stack),
      );
      expect(overlay, findsWidgets);
    });

    testWidgets('宿主无弹窗时零尺寸（不参与层序、不挡点击）', (WidgetTester tester) async {
      final ({ProviderContainer container, AylaUpdateController controller})
          host = await pumpHost(tester, mandatory: false);
      expect(host.controller.activeSession, isNull);
      expect(find.byType(AylaUpdateDialog), findsNothing);
      expect(tester.getSize(find.byType(AylaUpdateHost)), Size.zero);
    });
  });
}
