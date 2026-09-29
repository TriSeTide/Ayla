/// `AylaRevealItem` 的**玻璃安全淡入**（2026-09-29）：Impeller 校验刷屏修复的定向锁。
///
/// 背景：`Opacity` 祖先 + `BackdropFilter` 后代会被 Impeller 拒绝并刷屏
/// （`Contents::SetInheritedOpacity should never be called when
/// Contents::CanAcceptOpacity returns false`）。处置与逐条依据见
/// `lib/widgets/base/reveal.dart` 文件头；本文件锁三件事：
///
/// ① **位移仍随时间推进**（不含玻璃与含玻璃两档都要 —— 玻璃档只是不淡入，位移不许丢）；
/// ② **含玻璃子树不再推 opacity**：玻璃子树向上最近的 `Opacity` 恒为 1.0，且 layer 树里
///    不得出现「`alpha != 255` 的 `OpacityLayer` 祖先 → `BackdropFilterLayer` 后代」
///    （依据 `rendering/layer.dart:2186–2200`：`OpacityLayer.addToScene` 只在
///    `alpha < 255` 时 `pushOpacity`，`alpha == 255` 走 `pushOffset`）；
/// ③ **既有用法**（`AylaSidebarCard` = 目录卡 / 侧栏卡共同件）照常构建与展开。
///
/// 另附**对照组**（②b）：证明 ② 的 layer 探针**不是恒 false 的假绿** ——
/// 真出现「整层 `Opacity(0.5)` 包玻璃」时它必须命中。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/base/reveal.dart';
import '../lib/widgets/base/sidebar_card.dart';

void main() {
  Widget host(Widget child) => MaterialApp(home: previewScope(child));

  /// `AylaRevealItem` 的 `Transform.translate` 平移量。
  ///
  /// 直接读矩阵（`storage[12]` = x / `[13]` = y），不依赖宿主布局 ——
  /// 与 `group_page_shell_test` 的侧栏入场判据同一口径。
  Matrix4 revealMatrix(WidgetTester tester) => tester
      .widget<Transform>(
        find
            .descendant(
              of: find.byType(AylaRevealItem),
              matching: find.byType(Transform),
            )
            .first,
      )
      .transform;
  double revealDx(WidgetTester tester) => revealMatrix(tester).storage[12];
  double revealDy(WidgetTester tester) => revealMatrix(tester).storage[13];

  /// 目标子树向上**最近**的 `Opacity` 的取值（`find.ancestor` 的 `.first` = 最近祖先）。
  double revealOpacity(WidgetTester tester, Finder target) => tester
      .widget<Opacity>(
        find.ancestor(of: target, matching: find.byType(Opacity)).first,
      )
      .opacity;

  /// layer 树里是否存在「`alpha != 255` 的 `OpacityLayer` 祖先 → `BackdropFilterLayer` 后代」。
  ///
  /// 这正是 Impeller 报错的触发条件：`alpha < 255` 才 `pushOpacity`，引擎把继承不透明度
  /// 传给子树内容，而 `BackdropFilter` 的 Contents `CanAcceptOpacity == false`。
  /// 拿不到 layer（`debugLayer == null`）时返回 false —— 失败方向是「漏报」，不会误报。
  bool hasOpacityAncestorOfBackdropFilter(WidgetTester tester) {
    bool walk(Layer? layer, bool underOpacity) {
      for (Layer? l = layer; l != null; l = l.nextSibling) {
        final bool under = underOpacity ||
            (l is OpacityLayer && (l.alpha ?? 255) != 255);
        if (l is BackdropFilterLayer && under) return true;
        if (l is ContainerLayer && walk(l.firstChild, under)) return true;
      }
      return false;
    }

    final ContainerLayer? rootLayer = tester.binding.renderViews.first.debugLayer;
    return walk(rootLayer, false);
  }

  /// 含玻璃的 reveal —— **按调用方声明**（`fadeGlass: false`）构造，与
  /// `sidebar_card.dart` / `channel_sidebar.dart` 等真实调用点一致。
  ///
  /// `AylaGlassSurface` 内部走 `AylaGlassBackdrop` ⇒ 真玻璃档有 `BackdropFilter`。
  Widget glassReveal({String label = '玻璃内容', bool fadeGlass = false}) =>
      AylaRevealItem(
        fadeGlass: fadeGlass,
        delay: Duration.zero,
        child: AylaGlassSurface(
          padding: const EdgeInsets.all(12),
          child: Text(label),
        ),
      );

  group('① 位移仍随时间推进', () {
    testWidgets('非玻璃子树：位移与淡入同步（保住 web 的「位移 + 淡入」）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          Center(
            child: AylaRevealItem(
              delay: Duration.zero,
              child: const Text('纯内容'),
            ),
          ),
        ),
      );
      await tester.pump(); // 首帧：t = 0（ticker 只记 _startTime）
      expect(revealDy(tester), greaterThan(0.0), reason: '起点 = 默认下入 offset.dy');
      expect(revealOpacity(tester, find.text('纯内容')), 0.0);

      await tester.pump(const Duration(milliseconds: 16)); // 起 tick
      await tester.pump(const Duration(milliseconds: 150)); // 中段
      final double midOpacity = revealOpacity(tester, find.text('纯内容'));
      final double midDy = revealDy(tester);
      expect(midOpacity, greaterThan(0.0));
      expect(midOpacity, lessThan(1.0), reason: '非玻璃子树必须仍有淡入');
      expect(midDy, lessThan(20.0), reason: '位移应从起点向 0 推进');
      expect(midDy, greaterThan(0.0));

      await tester.pump(const Duration(milliseconds: 400));
      expect(revealOpacity(tester, find.text('纯内容')), 1.0);
      expect(revealDy(tester), moreOrLessEquals(0.0, epsilon: 0.001));
    });

    testWidgets('含玻璃子树：位移照常推进（只是不再淡入）', (WidgetTester tester) async {
      await tester.pumpWidget(host(Center(child: glassReveal())));
      await tester.pump();
      expect(revealDy(tester), greaterThan(0.0), reason: '起点仍是 offset.dy');

      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 150));
      final double midDy = revealDy(tester);
      expect(midDy, lessThan(20.0), reason: '玻璃档也不许丢位移');
      expect(midDy, greaterThan(0.0));

      await tester.pump(const Duration(milliseconds: 400));
      expect(revealDy(tester), moreOrLessEquals(0.0, epsilon: 0.001));
      expect(tester.takeException(), isNull);
    });
  });

  group('② 含玻璃子树不产生 pushOpacity', () {
    testWidgets('整层 opacity 不作用在玻璃子树（widget 层 + layer 层双判据）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host(Center(child: glassReveal())));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      // 动画中段 = 唯一可能推 opacity 的时刻（两端由 alpha 0 / alpha 255 分支免掉）
      await tester.pump(const Duration(milliseconds: 150));

      expect(find.byType(BackdropFilter), findsWidgets, reason: '玻璃不许被去掉');
      expect(
        revealOpacity(tester, find.byType(AylaGlassSurface)),
        1.0,
        reason: '玻璃档的整层 opacity 必须恒为 1.0',
      );
      expect(
        hasOpacityAncestorOfBackdropFilter(tester),
        isFalse,
        reason: 'Impeller 会拒绝「OpacityLayer(alpha<255) 祖先 + BackdropFilterLayer」并刷屏',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('对照：不声明（默认 fadeGlass: true）时玻璃子树**确实**会进 opacity 中间态', (
      WidgetTester tester,
    ) async {
      // 这条锁住「默认值 = 改前行为」这个约定：漏声明的调用点表现**可见**
      //（opacity 中间态 + 控制台刷屏），而不是静默退化 —— 也正是必须逐个显式
      // 声明 `fadeGlass: false` 的原因。
      await tester.pumpWidget(
        host(Center(child: glassReveal(fadeGlass: true))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 150));
      final double o = revealOpacity(tester, find.byType(AylaGlassSurface));
      expect(o, greaterThan(0.0));
      expect(o, lessThan(1.0), reason: '默认档仍走整层 opacity（= 改前行为）');
    });

    testWidgets('对照组：整层 Opacity(0.5) 包玻璃 ⇒ 探针必须命中（证明上面不是假绿）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          Center(
            child: Opacity(
              opacity: 0.5,
              child: AylaGlassSurface(
                padding: const EdgeInsets.all(12),
                child: const Text('对照'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        hasOpacityAncestorOfBackdropFilter(tester),
        isTrue,
        reason: '探针有效性：真出现「Opacity 祖先 + BackdropFilter」时它必须命中',
      );
    });
  });

  group('③ 既有用法照常构建与展开', () {
    testWidgets('AylaSidebarCard（目录卡 / 侧栏卡共同件）：玻璃保留、入场由 −20 到 0', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 224,
              height: 400,
              child: AylaSidebarCard(
                child: Column(
                  children: const <Widget>[Text('语音房间'), Text('直播间')],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(AylaGlassSurface), findsWidgets, reason: '侧栏卡仍是玻璃材质');
      expect(find.byType(BackdropFilter), findsWidgets, reason: '模糊不许被去掉');
      expect(find.text('语音房间'), findsOneWidget);
      expect(revealDx(tester), lessThan(0.0), reason: '入场起点是左入 −20');

      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 250));
      final double midDx = revealDx(tester);
      expect(midDx, greaterThan(-20.0), reason: '位移应从 −20 向 0 推进');
      expect(midDx, lessThan(0.0));

      await tester.pumpAndSettle();
      expect(revealDx(tester), moreOrLessEquals(0.0, epsilon: 0.001));
      expect(tester.takeException(), isNull);
    });
  });
}
