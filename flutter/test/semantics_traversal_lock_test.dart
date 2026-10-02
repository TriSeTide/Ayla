/// 语义树崩溃回归锁 —— `traversalParentIdentifier` 重复断言（2026-10-02 根治）。
///
/// ## 被锁住的故障
/// debug 下 `main.dart` 常开语义树（`SemanticsBinding.instance.ensureSemantics()`），
/// 每次语义更新都会走 `SemanticsOwner.sendSemanticsUpdate`。当**带 GlobalKey 的行在
/// 未加 key 的列表 item 之间下移索引**时，Flutter 3.47.4 会报：
///
/// ```
/// 'package:flutter/src/semantics/semantics.dart': Failed assertion: line 5016 pos 13:
/// 'The traversalParentIdentifier must be unique. No two semantics nodes can share the
///  same traversalParentIdentifier.'
/// ```
///
/// 根因链（本地源码 + 实测复现，详见 `widgets/base/tooltip.dart` 文件头）：
/// `Tooltip` → `OverlayPortal` → `widgets/overlay.dart:2096/2116` **无条件**插入
/// `Semantics(traversalParentIdentifier: this)`；该锚点被 `absorb` 上提
/// （`semantics.dart:3884/6837`）后，两个 `IndexedSemantics` 节点同帧各自持有同一标识
/// ⇒ `semantics.dart:5016` 断言。
///
/// 上游：framework 缺陷。引入 commit `fccfa978a976`（"Reland Refactor OverlayPortal
/// semantics (#173005)"，随 3.41.0 发布），master 与 3.47.4 stable 均未修；
/// 上游 issue **#193677**（open）即此形态。
/// 处置 = 上游 issue 作者实测有效的 workaround：Tooltip 之外套 `Semantics(container: true)`。
///
/// ## 口径
/// 1. 判据用 `tester.takeException()` —— 语义断言在 `PipelineOwner.flushSemantics` 内抛出，
///    被 test binding 记为 test exception，不会让 `pumpAndSettle` 直接失败；必须显式取走。
/// 2. `SemanticsHandle` **必须用 try/finally 释放**：`addTearDown` 的时机晚于
///    `_endOfTestVerifications`，会额外报「A SemanticsHandle was active at the end of the test」。
/// 3. 正对照**不断言失败**，只在缺陷消失时打日志提醒复核 —— 避免将来 Flutter 修好后
///    留下一条永远红的用例。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../lib/router/app_router.dart';
import '../lib/state/auth_state.dart';
import '../lib/theme/app_theme.dart';
import '../lib/widgets/base/tooltip.dart' show AylaTooltip;

/// 语义开启下跑一段交互；无论成功失败都释放 handle（口径 2）。
Future<void> withSemantics(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  final SemanticsHandle handle = tester.ensureSemantics();
  try {
    await body();
  } finally {
    handle.dispose();
  }
}

/// 语义树里 `traversalParentIdentifier` 的持有节点（同一标识 > 1 即断言前兆）。
Map<Object, List<int>> anchors() {
  final Iterable<RenderView> views = RendererBinding.instance.renderViews;
  final SemanticsNode? root =
      views.isEmpty ? null : views.first.owner?.semanticsOwner?.rootSemanticsNode;
  final Map<Object, List<int>> out = <Object, List<int>>{};
  if (root == null) return out;
  void walk(SemanticsNode n) {
    final Object? id = n.traversalParentIdentifier;
    if (id != null) out.putIfAbsent(id, () => <int>[]).add(n.id);
    n.visitChildren((SemanticsNode c) {
      walk(c);
      return true;
    });
  }

  walk(root);
  return out;
}

/// 语义树里所有节点的 `label` / `tooltip`（`Tooltip` 的提示进的是 `tooltip:` 属性，
/// **不是** `label` —— 所以不能用 `find.bySemanticsLabel` 判它）。
List<(String label, String tooltip)> semanticsTexts() {
  final Iterable<RenderView> views = RendererBinding.instance.renderViews;
  final SemanticsNode? root =
      views.isEmpty ? null : views.first.owner?.semanticsOwner?.rootSemanticsNode;
  final List<(String, String)> out = <(String, String)>[];
  if (root == null) return out;
  void walk(SemanticsNode n) {
    final SemanticsData d = n.getSemanticsData();
    out.add((d.label, d.tooltip));
    n.visitChildren((SemanticsNode c) {
      walk(c);
      return true;
    });
  }

  walk(root);
  return out;
}

List<GlobalKey> makeKeys(int n) =>
    List<GlobalKey>.generate(n, (int i) => GlobalKey(debugLabel: 'row' + i.toString()));

/// 「未加 key 的 item 内、带 GlobalKey 的行」—— 崩溃形态的最小装配。
///
/// [useProductionTooltip] = true 走生产件 [AylaTooltip]；false 走**裸 `Tooltip`**（正对照）。
Widget listScene({
  required List<GlobalKey> keys,
  required List<int> order,
  required bool useProductionTooltip,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        height: 400,
        child: ListView(
          children: <Widget>[
            for (final int i in order)
              Column(
                children: <Widget>[
                  KeyedSubtree(
                    key: keys[i],
                    child: useProductionTooltip
                        ? AylaTooltip(
                            message: 'row' + i.toString(),
                            child: Text('row' + i.toString()),
                          )
                        : Tooltip(
                            message: 'row' + i.toString(),
                            child: Text('row' + i.toString()),
                          ),
                  ),
                ],
              ),
          ],
        ),
      ),
    ),
  );
}

/// 真实路由 + 真实主题 + 真实表面（与 `group_page_shell_test.dart` 同款口径）。
Future<({ProviderContainer container, GoRouter router})> pumpApp(
  WidgetTester tester,
  Size size,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final ProviderContainer container = ProviderContainer();
  addTearDown(container.dispose);
  container.read(authNotifierProvider.notifier).setTokens('access', 'refresh');
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
  return (container: container, router: router);
}

const String kUniqueAssertion = 'traversalParentIdentifier must be unique';

void main() {
  group('GlobalKey 行下移索引（#193677 形态）', () {
    testWidgets('生产 AylaTooltip：连续重排不抛语义断言', (WidgetTester tester) async {
      await withSemantics(tester, () async {
        final List<GlobalKey> keys = makeKeys(4);

        Future<void> pumpOrder(List<int> order) async {
          await tester.pumpWidget(
            listScene(keys: keys, order: order, useProductionTooltip: true),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: '语义树更新抛异常（traversalParentIdentifier 重复）—— 见文件头根因链',
          );
        }

        await pumpOrder(<int>[0, 1, 2, 3]);
        await pumpOrder(<int>[0, 2, 1, 3]); // 行 2 下移到 index 1
        await pumpOrder(<int>[2, 0, 1, 3]); // 行 2 再下移到 index 0
        await pumpOrder(<int>[2, 0, 3, 1]); // 尾部再换序
      });
    });

    testWidgets('正对照：裸 Tooltip —— 记录缺陷是否仍在（不判失败）', (WidgetTester tester) async {
      await withSemantics(tester, () async {
        final List<GlobalKey> keys = makeKeys(4);
        await tester.pumpWidget(
          listScene(keys: keys, order: <int>[0, 1, 2, 3], useProductionTooltip: false),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '首帧不应抛');

        await tester.pumpWidget(
          listScene(keys: keys, order: <int>[0, 2, 1, 3], useProductionTooltip: false),
        );
        await tester.pumpAndSettle();
        final Object? caught = tester.takeException();
        if (caught == null) {
          // Flutter 修好 #193677 后会走到这里 —— 提醒复核规避是否仍然必要。
          debugPrint(
            '[SEM-LOCK] 裸 Tooltip 已不再触发该缺陷：Flutter 可能已修复 #193677，'
            '请复核 AylaTooltip 的 Semantics(container: true) 包裹是否仍必要',
          );
          return;
        }
        expect(
          caught.toString(),
          contains(kUniqueAssertion),
          reason: '抛的不是目标断言 ⇒ 崩溃形态已漂移，本锁失去判据价值，需重新取形态',
        );
      });
    });
  });

  group('语义等价：修复不得削弱无障碍', () {
    testWidgets('提示语义（tooltip）保留，且标识持有者唯一', (WidgetTester tester) async {
      await withSemantics(tester, () async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: Center(
                child: AylaTooltip(message: '一键禁音', child: Text('禁音')),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // web 的 `title=` 在 Flutter 的等价物 = `Semantics(tooltip:)`（`Tooltip` 自带），
        // 它必须原样保留；同时文字本身仍是 label。
        final List<(String, String)> texts = semanticsTexts();
        expect(
          texts.any(( (String, String) t) => t.$1 == '禁音'),
          isTrue,
          reason: '文字 label 丢失；实测语义树 = ' + texts.toString(),
        );
        expect(
          texts.any(( (String, String) t) => t.$2 == '一键禁音'),
          isTrue,
          reason: 'tooltip 语义丢失 —— Semantics 包裹削弱了无障碍；实测 = ' + texts.toString(),
        );

        for (final MapEntry<Object, List<int>> e in anchors().entries) {
          expect(e.value.length, 1, reason: '同一标识被多个节点持有：' + e.toString());
        }
      });
    });
  });

  group('端到端：真实路由下的语义树更新', () {
    testWidgets('群页五场景来回切换（宽屏）不抛异常', (WidgetTester tester) async {
      await withSemantics(tester, () async {
        final ({ProviderContainer container, GoRouter router}) app =
            await pumpApp(tester, const Size(1440, 900));
        const List<String> scenes = <String>[
          '/group/g1',
          '/group/g1/voice',
          '/group/g1/live',
          '/group/g1/posts',
          '/group/g1/games',
        ];
        for (int round = 0; round < 2; round++) {
          for (final String r in scenes) {
            app.router.go(r);
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: '切到 ' + r + ' 时语义树更新抛异常',
            );
          }
        }
      });
    });

    testWidgets('宽屏 rail 重排（尺寸变化）不抛异常', (WidgetTester tester) async {
      await withSemantics(tester, () async {
        final ({ProviderContainer container, GoRouter router}) app =
            await pumpApp(tester, const Size(1440, 900));
        app.router.go('/group/g1');
        await tester.pumpAndSettle();
        for (final Size s in <Size>[
          const Size(900, 900),
          const Size(1440, 900),
          const Size(700, 900),
          const Size(1600, 900),
        ]) {
          tester.view.physicalSize = s;
          await tester.binding.setSurfaceSize(s);
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: '重排到宽度 ' + s.width.toString() + ' 时语义树更新抛异常',
          );
        }
      });
    });
  });
}