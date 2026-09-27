/// `AylaPageTransition` / `AylaPageSwap` 定向测试 —— 逐条对照
/// `web/src/components/motion/PageTransition.tsx`（117 行）+ `auroraquaMotion.ts` + `AppShell.tsx:113`。
///
/// 覆盖：`resolvePageKey` 5 条归一规则 + `matchGroupId` · 进入动画（初始 0/+20/.95 → 500ms 终态，
/// 量**矩阵实时值**）· 搜索页 y 反向 · 群页/reduced-motion 只淡入 · `panelOwned` 不动画 ·
/// 退出宿主（新页立即挂载、旧页保留 300ms 淡出后卸载）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/preview_theme.dart';
import '../lib/widgets/motion/page_transition.dart';

void main() {
  Widget host(Widget child) => MaterialApp(home: previewScope(child));

  /// 取子树里所有 `Transform` 的 (scale, ty)（translate 与 scale 两层）。
  ({double scale, double ty}) transformOf(WidgetTester tester) {
    double scale = 1;
    double ty = 0;
    for (final Transform t in tester.widgetList<Transform>(
      find.descendant(
        of: find.byType(AylaPageTransition),
        matching: find.byType(Transform),
      ),
    )) {
      final List<double> m = t.transform.storage;
      ty += m[13];
      scale *= m[0];
    }
    return (scale: scale, ty: ty);
  }

  double opacityOf(WidgetTester tester) => tester
      .widget<Opacity>(
        find
            .descendant(
              of: find.byType(AylaPageTransition),
              matching: find.byType(Opacity),
            )
            .first,
      )
      .opacity;

  group('resolvePageKey / matchGroupId（tsx 20–67）', () {
    test('群页所有变体归一为 /group/:id', () {
      expect(aylaResolvePageKey('/group/g1'), '/group/g1');
      expect(aylaResolvePageKey('/group/g1/posts/p1'), '/group/g1');
      expect(aylaResolvePageKey('/group/g1/voice/v1'), '/group/g1');
      expect(aylaResolvePageKey('/group/g1/live/l1'), '/group/g1');
      expect(aylaResolvePageKey('/group/g1/games'), '/group/g1');
    });

    test('宽屏群壳 / 宽屏私聊壳', () {
      expect(
        aylaResolvePageKey('/group/g1/posts/p1', wideGroupShell: true),
        'wide-group-shell',
      );
      expect(
        aylaResolvePageKey('/chat/c1', wideGroupShell: true),
        'wide-private-chat-shell',
      );
      // 窄屏不归一
      expect(aylaResolvePageKey('/chat/c1'), '/chat/c1');
    });

    test('直播间归一 /live/room；开播台归一 /live/start（排除 start 被当直播间）', () {
      expect(aylaResolvePageKey('/live/l1'), '/live/room');
      expect(aylaResolvePageKey('/live/l2'), '/live/room');
      expect(aylaResolvePageKey('/live/start/ch1'), '/live/start');
      expect(aylaResolvePageKey('/live'), '/live');
    });

    test('其余路由原样；matchGroupId 非群页返回 null', () {
      expect(aylaResolvePageKey('/search'), '/search');
      expect(aylaResolvePageKey('/posts/mine'), '/posts/mine');
      expect(aylaMatchGroupId('/group'), isNull);
      expect(aylaMatchGroupId('/groupx/g1'), isNull);
      expect(aylaMatchGroupId('/live/l1'), isNull);
    });
  });

  group('AylaPageTransition（tsx 84–103）', () {
    testWidgets('普通路由：初始 opacity 0 / y +20 / scale .95，500ms 到终态', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AylaPageTransition(child: SizedBox(width: 100, height: 50)),
        ),
      );
      await tester.pump(); // 首帧
      expect(opacityOf(tester), 0);
      expect(transformOf(tester).ty, closeTo(AylaPageTransition.distance, 0.01));
      expect(
        transformOf(tester).scale,
        closeTo(AylaPageTransition.fadeScale, 0.001),
      );

      await tester.pump(const Duration(milliseconds: 250)); // 中途
      final double mid = opacityOf(tester);
      expect(mid, greaterThan(0));
      expect(mid, lessThan(1));

      await tester.pump(const Duration(milliseconds: 250)); // 500ms 到点
      expect(opacityOf(tester), 1);
      expect(transformOf(tester).ty, closeTo(0, 0.01));
      expect(transformOf(tester).scale, closeTo(1, 0.001));
    });

    testWidgets('搜索页：进入位移反向（y −20）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaPageTransition(
            searchScene: true,
            child: SizedBox(width: 100, height: 50),
          ),
        ),
      );
      await tester.pump();
      expect(
        transformOf(tester).ty,
        closeTo(-AylaPageTransition.distance, 0.01),
      );
    });

    testWidgets('群页：只淡入（无位移无缩放）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaPageTransition(
            groupScene: true,
            child: SizedBox(width: 100, height: 50),
          ),
        ),
      );
      await tester.pump();
      expect(opacityOf(tester), 0);
      expect(transformOf(tester).ty, 0);
      expect(transformOf(tester).scale, 1);
    });

    testWidgets('panelOwned：整页不动画（首帧即终态）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaPageTransition(
            panelOwned: true,
            child: SizedBox(width: 100, height: 50),
          ),
        ),
      );
      await tester.pump();
      expect(opacityOf(tester), 1);
      expect(transformOf(tester).ty, 0);
      expect(transformOf(tester).scale, 1);
    });

    testWidgets('reduced-motion：直接到终值（无过渡）', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: previewScope(
            Builder(
              builder: (BuildContext context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: const AylaPageTransition(
                  child: SizedBox(width: 100, height: 50),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(opacityOf(tester), 1);
      expect(transformOf(tester).ty, 0);
    });
  });

  group('AylaPageSwap（AppShell.tsx:113 的 AnimatePresence mode="sync" 等价）', () {
    testWidgets('换页：新页立即挂载，旧页保留 300ms 后卸载', (WidgetTester tester) async {
      final ValueNotifier<String> key = ValueNotifier<String>('/a');
      addTearDown(key.dispose);
      await tester.pumpWidget(
        host(
          ValueListenableBuilder<String>(
            valueListenable: key,
            builder: (BuildContext context, String value, Widget? _) =>
                AylaPageSwap(
                  pageKey: value,
                  builder: (BuildContext context) => Center(
                    child: Text(value == '/a' ? '页面 A' : '页面 B'),
                  ),
                ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('页面 A'), findsOneWidget);

      key.value = '/b';
      await tester.pump();
      await tester.pump(); // ticker 起跑帧（首帧 elapsed 0 ⇒ 值仍是 1）
      // 两页并存（旧页在下淡出）
      expect(find.text('页面 B'), findsOneWidget);
      expect(find.text('页面 A'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 150));
      // ⚠️ 作用域必须收紧到**旧页那一层**：previewScope/MaterialApp 自带 Route 的 FadeTransition，
      //    直接用 `find.byType(FadeTransition).first` 会读到它（活值恒 1）而误判「没淡出」。
      final FadeTransition fade = tester.widget<FadeTransition>(
        find
            .ancestor(
              of: find.text('页面 A'),
              matching: find.byType(FadeTransition),
            )
            .first,
      );
      expect(fade.opacity.value, greaterThan(0));
      expect(fade.opacity.value, lessThan(1));

      await tester.pump(const Duration(milliseconds: 200)); // 300ms 走完
      await tester.pump();
      expect(find.text('页面 A'), findsNothing);
      expect(find.text('页面 B'), findsOneWidget);
    });
  });
}
