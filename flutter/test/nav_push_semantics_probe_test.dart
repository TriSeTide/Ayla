/// 探针：验证 go_router 在 ShellRoute 下 `push` 的语义。
///
/// 目的（2026-10-19，针对「手机端返回键直接退出应用」）：
/// 确认把 `context.go` 换成 `context.push` 之后：
/// 1. 壳层（AppShell / 底栏）**不重建**，只是内容页叠一层；
/// 2. 系统返回键 / `context.pop()` 能逐级回退到上一页；
/// 3. 对照 `go`：不建历史栈，pop 无处可回（正是返回键直退的根因）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  GoRouter buildRouter() => GoRouter(
        initialLocation: '/a',
        routes: <RouteBase>[
          ShellRoute(
            builder: (BuildContext c, GoRouterState s, Widget child) =>
                Scaffold(
              body: Column(
                children: <Widget>[
                  const Text('SHELL'),
                  Expanded(child: child),
                ],
              ),
            ),
            routes: <RouteBase>[
              GoRoute(
                path: '/a',
                builder: (BuildContext c, GoRouterState s) => const Text('PAGE-A'),
              ),
              GoRoute(
                path: '/b',
                builder: (BuildContext c, GoRouterState s) => const Text('PAGE-B'),
              ),
            ],
          ),
        ],
      );

  testWidgets('push 保留壳层，并可逐级 pop 回上一页', (WidgetTester tester) async {
    final GoRouter router = buildRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(find.text('PAGE-A'), findsOneWidget);
    expect(find.text('SHELL'), findsOneWidget);

    router.push('/b');
    await tester.pumpAndSettle();
    expect(find.text('PAGE-B'), findsOneWidget);
    expect(find.text('SHELL'), findsOneWidget);

    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('PAGE-A'), findsOneWidget);
    expect(find.text('PAGE-B'), findsNothing);
  });

  testWidgets('对照：go 会替换当前页，pop 无处可回', (WidgetTester tester) async {
    final GoRouter router = buildRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    router.go('/b');
    await tester.pumpAndSettle();
    expect(find.text('PAGE-B'), findsOneWidget);
    expect(router.canPop(), isFalse,
        reason: 'go 不建历史栈，这正是返回键直退的根因');
  });
}
