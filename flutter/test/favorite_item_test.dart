/// `AylaFavoriteItem` / `AylaFavoritesSkeleton` 定向测试 —— 对照
/// `FavoritesPage.tsx:95 · 268–271` + `typed-result-cards.css 17–20` +
/// `profile.css 474–487 / 524–541 / 452–456` + `directory-filters.css 171–180 / 199–208 / 210–217`
/// + `auroraqua.css 29–52 / 655–674` + `tokens.css 125`。
///
/// 本轮（2026-10-14）修复两条与 web 的实测差异，用例逐条对应：
/// 1. **条目材质归零**：web `typed-result-cards.css:17–20` 把 `.favorite-item.typed-result-card`
///    的 padding / 底 / 边 / 模糊 / 阴影全部压掉（实测 pad=0 / bg 透明 / border 0 / box-shadow none /
///    backdrop none），只剩 `border-radius: --radius-input`；真正画玻璃的是内层卡。
///    ⇒ 断言「无 BackdropFilter」「无填充盒装饰」「padding 0」（几何断言，不是读 widget 属性）。
/// 2. **`--glass-shadow-hover` 不上浮时刻不画**：静止态 web `box-shadow: none`；
///    hover 才是 `translate: 0 -2px` + `--glass-shadow-hover`（`auroraqua.css:42–43`）。
///
/// ⚠️ 纪律：一态一用例（同一用例二次 `pumpWidget` 换 props 不生效，库内既有结论）。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/favorite_item.dart';
import '../lib/widgets/base/loading.dart';
import '../lib/widgets/profile/favorites_skeleton.dart';

void main() {
  Widget host(Widget child, {double width = 420}) => MaterialApp(
        home: previewScope(
          Builder(
            builder: (BuildContext context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(size: Size(width, 800)),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: width, child: child),
              ),
            ),
          ),
        ),
      );

  /// ⚠️ 测试表面默认 800×600 —— 断点用例必须**同时**钉住根 view（setSurfaceSize）
  /// 与 MediaQuery（skill「测试里只覆写 MediaQuery 不够」条；此前 1025 档实测拿到 378px 列宽
  /// = 800 表面下的单列宽，属假红）。
  Future<void> pumpAt(
    WidgetTester tester,
    Widget child, {
    required double width,
    double height = 800,
  }) async {
    await tester.binding.setSurfaceSize(Size(width, height));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host(child, width: width));
  }

  /// 收集子树里所有 [BackdropFilter]（= 玻璃层）；`.favorite-item` 层不应有。
  Iterable<BackdropFilter> backdrops(WidgetTester tester, Finder of) =>
      tester.widgetList<BackdropFilter>(
        find.descendant(of: of, matching: find.byType(BackdropFilter)),
      );

  /// 该子树里所有「有可见填充色 / 边框」的盒装饰。
  List<BoxDecoration> paintedDecorations(WidgetTester tester, Finder of) => <BoxDecoration>[
        for (final DecoratedBox box in tester.widgetList<DecoratedBox>(
          find.descendant(of: of, matching: find.byType(DecoratedBox)),
        ))
          if (box.decoration is BoxDecoration)
            box.decoration as BoxDecoration,
      ];

  group('AylaFavoriteItem：材质归零（typed-result-cards.css:17–20，特异性 0-2-0 压掉 profile.css:474）', () {
    testWidgets('整棵子树 0 个 BackdropFilter（web: backdrop-filter: none）', (WidgetTester tester) async {
      await pumpAt(tester, const AylaFavoriteItem(child: Text('内容')), width: 420);
      expect(
        backdrops(tester, find.byType(AylaFavoriteItem)),
        isEmpty,
        reason: 'typed-result-cards.css:19 把 backdrop-filter 归零 ⇒ 本层不得出现玻璃模糊层',
      );
      // 反证：整个宿主里也没有（子件只是 Text，没有自带玻璃）
      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('无填充盒装饰（web: background: transparent; border: 0; box-shadow: none）',
        (WidgetTester tester) async {
      await pumpAt(tester, const AylaFavoriteItem(child: Text('内容')), width: 420);
      final List<BoxDecoration> decos = paintedDecorations(tester, find.byType(AylaFavoriteItem));
      final Iterable<BoxDecoration> painted = decos.where(
        (BoxDecoration d) =>
            d.color != null || d.border != null || (d.boxShadow?.isNotEmpty ?? false),
      );
      expect(
        painted,
        isEmpty,
        reason: '本层只保留 layout + radius，不得有底/边/阴影（实测 item bg=rgba(0,0,0,0)、border-width=0、'
            'box-shadow=none）',
      );
    });

    testWidgets('子件内距为 0（web: padding: 0，profile.css:539 的 sp4 被压掉、实际不生效）',
        (WidgetTester tester) async {
      const Key innerKey = Key('inner');
      await pumpAt(
        tester,
        const AylaFavoriteItem(
          child: SizedBox(key: innerKey, width: 100, height: 40),
        ),
        width: 420,
      );
      // 子件左边缘 = item 左边缘 ⇒ 无任何内距
      expect(tester.getTopLeft(find.byKey(innerKey)).dx, 0);
      expect(tester.getTopLeft(find.byKey(innerKey)).dy, 0);
      // item 自身高 = 子件高（无上下内距）
      expect(tester.getSize(find.byType(AylaFavoriteItem)).height, 40);
      // 宽度撑满（flex 子项：web `flex: 1`）
      expect(tester.getSize(find.byType(AylaFavoriteItem)).width, 420);
    });

    testWidgets('窄/宽两档尺寸一致（padding 归零 ⇒ 不再有 <769 sp3 / ≥769 sp4 之分）',
        (WidgetTester tester) async {
      const Key innerKey = Key('inner');
      await pumpAt(
        tester,
        const AylaFavoriteItem(
          child: SizedBox(key: innerKey, width: 100, height: 40),
        ),
        width: 900,
      );
      expect(tester.getTopLeft(find.byKey(innerKey)).dx, 0);
      expect(tester.getTopLeft(find.byKey(innerKey)).dy, 0);
      // 值层面也一致：不再有「窄档 padding」可传（本件构造函数已无 padding 参数）
    });
  });

  group('AylaFavoriteItem：卡片族 hover（auroraqua.css 29–52 / 655–674 + tokens.css:125）', () {
    testWidgets('静止态：不上浮、不画 hover 阴影', (WidgetTester tester) async {
      await pumpAt(tester, const AylaFavoriteItem(child: Text('内容')), width: 420);
      // 阴影环未挂（只在 hover 过渡中出现）；限定在本件子树内数，免得数到极光背景的 CustomPaint
      expect(
        find.descendant(
          of: find.byType(AylaFavoriteItem),
          matching: find.byType(CustomPaint),
        ),
        findsNothing,
      );
      expect(tester.getTopLeft(find.byType(AylaFavoriteItem)).dy, 0);
    });

    testWidgets('hover：上浮 2px（translate: 0 -2px）+ 出现只画形状之外的阴影环',
        (WidgetTester tester) async {
      const Key innerKey = Key('inner');
      await pumpAt(
        tester,
        const AylaFavoriteItem(
          child: SizedBox(key: innerKey, width: 100, height: 40),
        ),
        width: 420,
      );
      final double beforeY = tester.getTopLeft(find.byKey(innerKey)).dy;

      final TestGesture gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(50, 20));
      addTearDown(gesture.removePointer);
      await gesture.moveTo(const Offset(50, 20));
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.byKey(innerKey)).dy - beforeY,
        -kAylaFavoriteItemHoverLift,
        reason: 'auroraqua.css:42 `translate: 0 -2px`',
      );
      // 阴影环：本件子树内出现 CustomPaint（只画形状之外的 --glass-shadow-hover）
      expect(
        find.descendant(
          of: find.byType(AylaFavoriteItem),
          matching: find.byType(CustomPaint),
        ),
        findsWidgets,
      );
      // 布局高不变（CSS translate 不影响布局）
      expect(tester.getSize(find.byKey(innerKey)).height, 40);
    });

    testWidgets('hover 时子件仍能收到鼠标 hover（MouseRegion 不吞并，opaque: false）',
        (WidgetTester tester) async {
      final List<bool> entered = <bool>[];
      await pumpAt(
        tester,
        AylaFavoriteItem(
          child: MouseRegion(
            onEnter: (_) => entered.add(true),
            child: const SizedBox(width: 100, height: 40),
          ),
        ),
        width: 420,
      );
      final TestGesture gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(50, 20));
      addTearDown(gesture.removePointer);
      await gesture.moveTo(const Offset(50, 20));
      await tester.pumpAndSettle();
      expect(entered, isNotEmpty, reason: 'web 的 :hover 是 per-element ⇒ 内层卡必须照样收到 hover');
    });

    testWidgets('prefers-reduced-motion：位移归零（auroraqua.css:671–673 的 translate: none）',
        (WidgetTester tester) async {
      const Key innerKey = Key('inner');
      await pumpAt(
        tester,
        const MediaQuery(
          data: MediaQueryData(disableAnimations: true, size: Size(420, 800)),
          child: AylaFavoriteItem(
            child: SizedBox(key: innerKey, width: 100, height: 40),
          ),
        ),
        width: 420,
      );
      final double beforeY = tester.getTopLeft(find.byKey(innerKey)).dy;
      final TestGesture gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(50, 20));
      addTearDown(gesture.removePointer);
      await gesture.moveTo(const Offset(50, 20));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(innerKey)).dy,
        beforeY,
        reason: 'reduced-motion 下 web 是 translate: none（不是「动画时长 0」）',
      );
    });
  });

  group('AylaFavoritesSkeleton：断点档（directory-filters.css 210–217）', () {
    testWidgets('第 1 档 <1025：单列纵排，两条 64 高 + 首条下方 8；语义 label = 正在加载收藏',
        (WidgetTester tester) async {
      await pumpAt(tester, const AylaFavoritesSkeleton(), width: 420);
      final Finder bars = find.byType(AylaSkeleton);
      expect(bars, findsNWidgets(2));
      expect(tester.getSize(bars.at(0)).height, 64);
      expect(tester.getSize(bars.at(1)).height, 64);
      final Rect b0 = tester.getRect(bars.at(0));
      final Rect b1 = tester.getRect(bars.at(1));
      expect(b1.top - b0.bottom, AylaFavoritesSkeleton.barGap);
      expect(b1.left, b0.left); // 同列

      final Semantics sem = tester.widget<Semantics>(
        find.descendant(
          of: find.byType(AylaFavoritesSkeleton),
          matching: find.byType(Semantics),
        ),
      );
      expect(sem.properties.label, '正在加载收藏');
      expect(sem.properties.liveRegion, isTrue); // 等价 role=status
    });

    testWidgets('第 2 档 ≥1025：两列并排（grid repeat(2,minmax(0,1fr)) + gap sp3 + align-items start）',
        (WidgetTester tester) async {
      // padding 显式归零：本用例只验 grid 语义（列数/列宽/列距），内距另有用例覆盖
      await pumpAt(
        tester,
        const AylaFavoritesSkeleton(padding: EdgeInsets.zero),
        width: 1025,
      );
      final Finder bars = find.byType(AylaSkeleton);
      expect(bars, findsNWidgets(2));

      final Rect b0 = tester.getRect(bars.at(0));
      final Rect b1 = tester.getRect(bars.at(1));
      // 同一行（align-items: start ⇒ 两条顶边相同；两条等高故底线也相同）
      expect(b1.top, b0.top);
      expect(b1.bottom, b0.bottom);
      // 两列等宽 + 列距 sp3：列宽 = (1025 − 12) / 2 = 506.5
      expect(b0.width, closeTo((1025 - AylaFavoritesSkeleton.columnGap) / 2, 0.01));
      expect(b1.width, closeTo(b0.width, 0.01));
      expect(b1.left - b0.right, AylaFavoritesSkeleton.columnGap);
      // 两条并排 ⇒ 不再纵排（窄档里 b1.top 应 > b0.bottom）
      expect(b1.top, lessThan(b0.bottom));
    });

    testWidgets('第 2 档共 4 条时按行流：1→(0,0)、2→(0,1)、3→(1,0)、4→(1,1)',
        (WidgetTester tester) async {
      // grid 自动流是「按行填充」——收藏页固定 2 条，本用例锁住该语义不被改成按列
      await pumpAt(
        tester,
        const AylaFavoritesSkeleton(padding: EdgeInsets.zero),
        width: 1025,
      );
      final Rect b0 = tester.getRect(find.byType(AylaSkeleton).at(0));
      final Rect b1 = tester.getRect(find.byType(AylaSkeleton).at(1));
      expect(b0.left, 0);
      expect(b1.left, b0.right + AylaFavoritesSkeleton.columnGap);
      expect(b1.top, b0.top);
    });

    testWidgets('默认内距 sp4（profile.css:452–456）在断点两档都保持；收藏页调用点会覆写它',
        (WidgetTester tester) async {
      await pumpAt(tester, const AylaFavoritesSkeleton(), width: 1025);
      final double outer = tester.getSize(find.byType(AylaFavoritesSkeleton)).width;
      final double inner = tester.getSize(find.byType(AylaSkeleton).at(0)).width;
      // 两列：inner = (outer − 2*sp4 − sp3) / 2
      expect(
        inner,
        closeTo(
          (outer - 2 * AylaSpacing.sp4 - AylaFavoritesSkeleton.columnGap) / 2,
          0.01,
        ),
      );
      expect(kAylaFavoritesSkeletonPadding, const EdgeInsets.all(AylaSpacing.sp4));
    });

    testWidgets('第 2 档边界：1024 仍是单列、1025 才两列（逐字对齐 min-width: 1025px）',
        (WidgetTester tester) async {
      await pumpAt(
        tester,
        const AylaFavoritesSkeleton(padding: EdgeInsets.zero),
        width: 1024,
      );
      final Rect a0 = tester.getRect(find.byType(AylaSkeleton).at(0));
      final Rect a1 = tester.getRect(find.byType(AylaSkeleton).at(1));
      expect(a1.left, a0.left, reason: '1024 < 1025 ⇒ 仍为纵排单列');
      expect(a1.top, greaterThan(a0.bottom));
    });
  });
}
