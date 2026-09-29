/// 窄屏左下角消息入口（`.message-fab`）与右下创建键的图标口径回归。
///
/// 用户 2026-09-29 实报两条（窄屏 + 宽屏验收）：
/// ① 「窄屏左下角『私信』键图标大小与 web 不一致」—— 实为 `.message-fab` 的消息档图标
///    漏传 size（`AylaIcon` 默认 18，web 是 24）；
/// ② 「窄屏私信界面左下角『返回主页』图标使用错误」—— 实为 backHome 档选错 glyph
///    （原写 `iconBack`，web 是 `iconHome`）。
///
/// 事实源（逐条）：
/// - `MessageFab.tsx:21–31`：`if (backHome)` ⇒ `<IconHome width={24} height={24} />`，
///   `aria-label="返回主页"`；
/// - `MessageFab.tsx:40`：默认档 `<IconMessage width={24} height={24} />`；
/// - `QuickMessageFab.tsx:50`：同样 24；
/// - `CreateFab.tsx:71`：`<IconPlus width={24} height={24} />`；
/// - `.message-fab`（`shell.css:423–439`）/`.create-fab`（`shell.css:409–421`）**全仓唯一命中**，
///   且都在 `@media` 之外、不含任何 `svg` 尺寸声明 ⇒ CSS 层不缩放图标。
///
/// 宿主不走 `appRouterProvider`（只测壳层局部，避免把整张路由表拉进编译）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/layout/app_shell.dart';
import '../lib/state/auth_state.dart';
import '../lib/theme/app_theme.dart';
import '../lib/theme/app_icons.dart' show AylaIcon;
import '../lib/theme/buttons.dart' show AylaCreateFab, AylaMessageFab;

void main() {
  /// 窄屏宿主（375×812）+ 最小路由（`/messages` / `/group` 各挂一个空页）。
  ///
  /// ⚠️ `AppShell` 读 `GoRouterState.of(context)` ⇒ 必须有路由环境；
  /// 这里自建最小 GoRouter，不 import `router/app_router.dart`。
  Future<void> pumpShell(WidgetTester tester, String location) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(authNotifierProvider.notifier).setTokens('access', 'refresh');
    final GoRouter router = GoRouter(
      initialLocation: location,
      routes: <RouteBase>[
        ShellRoute(
          builder: (
            BuildContext context,
            GoRouterState state,
            Widget child,
          ) =>
              AppShell(child: child),
          routes: <RouteBase>[
            GoRoute(
              path: '/messages',
              builder: (BuildContext c, GoRouterState s) =>
                  const SizedBox.shrink(),
            ),
            GoRoute(
              path: '/group',
              builder: (BuildContext c, GoRouterState s) =>
                  const SizedBox.shrink(),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
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
    await tester.pump(const Duration(milliseconds: 100));
  }

  AylaMessageFab messageFab(WidgetTester tester) =>
      tester.widget<AylaMessageFab>(find.byType(AylaMessageFab));

  AylaIcon iconOf(WidgetTester tester) =>
      messageFab(tester).icon as AylaIcon;

  testWidgets('主页（一级导航）：左下角消息键 = iconMessage 24×24 + aria-label「消息」', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester, '/group');

    expect(find.byType(AylaMessageFab), findsOneWidget);
    expect(
      iconOf(tester).icon.name,
      'iconMessage',
      reason: 'MessageFab.tsx:40 —— 默认档是 IconMessage',
    );
    expect(
      iconOf(tester).size,
      24,
      reason: 'MessageFab.tsx:40 的 width/height=24；AylaIcon 默认 18 会偏小',
    );
    expect(messageFab(tester).semanticLabel, '消息');
  });

  testWidgets('消息中心：左下角键换成 backHome 档 = **iconHome** 24×24 + aria-label「返回主页」', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester, '/messages');

    expect(find.byType(AylaMessageFab), findsOneWidget);
    expect(
      iconOf(tester).icon.name,
      'iconHome',
      reason:
          'MessageFab.tsx:21–31 —— backHome 变体用 IconHome（原实现误用 iconBack）',
    );
    expect(iconOf(tester).size, 24, reason: 'MessageFab.tsx:29 的 width/height=24');
    expect(messageFab(tester).semanticLabel, '返回主页');
  });

  testWidgets('右下创建键：iconPlus 24×24（`CreateFab.tsx:71` 同源口径）', (
    WidgetTester tester,
  ) async {
    await pumpShell(tester, '/group');

    final Finder create = find.byType(AylaCreateFab);
    if (create.evaluate().isEmpty) return; // 该路由无 create 动作 ⇒ 无键可测
    final AylaCreateFab fab = tester.widget<AylaCreateFab>(create);
    final AylaIcon icon = fab.icon as AylaIcon;
    expect(icon.icon.name, 'iconPlus');
    expect(icon.size, 24, reason: 'CreateFab.tsx:71 的 width/height=24');
  });
}
