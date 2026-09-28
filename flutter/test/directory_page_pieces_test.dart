/// 目录页族 A 类跨页复用件定向测试 —— 逐条对照 `directory-filters.css`（全文 258 行）
/// 与六个目录页 TSX。
///
/// 覆盖（本文件）：
/// 1. ≥769 两列几何：侧栏 **224** + body gap sp3 + 内容区剩余宽（含 ±12 绘制带外扩）；
/// 2. 内容区**独立滚动**：内层滚 100 不带动外层（真实指针路径，非 jumpTo）；
/// 3. ≤768 单列：顶栏在上 / 内容在下 / page padding 0 / content padding sp2 sp4 (68+safe)；
/// 4. 宽屏 content padding `sp3 (sp2+sp3) sp6`；
/// 5. 入场位移 **12 → 0**（300ms，量像素）；
/// 6. reduced-motion ⇒ 无动画、直接终值（249–254）；
/// 7. `key={scope}` 重挂载 ⇒ 入场重播（同 scope 不重播为对照）；
/// 8. header 三段文案与字号（10/17/12 + ls 1.4 + opacity .75）；
/// 9. decor 图标 size 64 + rotate −8° + opacity .42 + 不可命中；
/// 10. 返回键 40×40 + 图标 20 + `aria-label`；
/// 11. `aylaDirectoryListPaddingTop`：宽屏 0 / 窄屏 null（组规则 204–208）。
///
/// ⚠️ 几何断言前必须等入场动画结束（侧栏 `auroraqua-sidebar-in` 300ms 带 −20px 位移、
/// 内容区 `directory-content-in` 300ms 带 12px 位移）—— 否则量到的是动画中间帧。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/app_icons.dart';
import '../lib/theme/buttons.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/directory_page.dart';
import '../lib/widgets/base/profile_and_filters.dart';

void main() {
  const List<({String key, String label})> options =
      <({String key, String label})>[
    (key: 'all', label: '全部'),
    (key: 'post', label: '帖子'),
  ];

  AylaDirectoryFilters filters({
    bool narrow = false,
    String value = 'all',
    ValueChanged<String>? onChange,
    Widget? leading,
    Widget? decor,
    Widget? header,
  }) {
    return AylaDirectoryFilters(
      label: '收藏分类',
      options: options,
      value: value,
      onChange: onChange ?? (String _) {},
      narrow: narrow,
      leading: leading,
      decor: decor,
      header: header,
    );
  }

  /// 把测试表面设成目标视口。
  ///
  /// ⚠️ `SizedBox.fromSize(大尺寸)` 会被 flutter_test 默认的 800×600 表面**夹住**
  /// （实测：1600 宽被夹成 800 ⇒ 内容区宽度断言全错），必须改真实表面尺寸。
  Future<void> useViewport(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  /// 有界宿主（等价 web `.directory-page { height: 100% }` 的父级）。
  Widget host(
    Widget child, {
    Size viewport = const Size(1600, 900),
    EdgeInsets viewPadding = EdgeInsets.zero,
    bool disableAnimations = false,
  }) {
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: viewport,
              viewPadding: viewPadding,
              disableAnimations: disableAnimations,
            ),
            child: SizedBox.expand(child: child),
          ),
        ),
      ),
    );
  }

  Widget page({
    bool narrow = false,
    ScrollController? controller,
    Object? scope,
    Widget? child,
  }) {
    return AylaDirectoryPage(
      filters: filters(narrow: narrow),
      content: AylaDirectoryContent(
        controller: controller,
        scope: scope,
        label: '全部',
        child: child ?? const Text('第一行'),
      ),
    );
  }

  /// 按 controller 精确定位内容区的滚动视图（侧栏内部也有滚动视图，不能用 byType）。
  Finder scrollerOf(ScrollController c) => find.byWidgetPredicate(
        (Widget w) => w is SingleChildScrollView && w.controller == c,
      );

  /// 等入场动画走完（≤400ms）。
  Future<void> settle(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 400));

  testWidgets('≥769 两列几何：侧栏 224 + body gap sp3 + 内容区剩余宽（含绘制带外扩）', (
    WidgetTester tester,
  ) async {
    await useViewport(tester, const Size(1600, 900));
    final ScrollController inner = ScrollController();
    addTearDown(inner.dispose);
    await tester.pumpWidget(host(page(controller: inner)));
    await settle(tester);

    // 侧栏：.directory-page .directory-filters { width: 224px; flex: 0 0 224px }（27–30）
    final Rect sidebar = tester.getRect(find.byType(AylaDirectoryFilters));
    expect(sidebar.width, AylaDirectoryFilters.sidebarWidth); // 224
    expect(sidebar.left, AylaSpacing.sp3); // .directory-page padding-left: sp3

    // 内容区：flex 1 1 0 ⇒ 剩余宽 = 视口 − 左右 padding − 侧栏 − gap sp3
    const double viewportWidth = 1600;
    final double remaining =
        viewportWidth - AylaSpacing.sp3 * 2 - AylaDirectoryFilters.sidebarWidth - AylaSpacing.sp3;
    expect(remaining, 1340);

    final Rect content = tester.getRect(scrollerOf(inner));
    // ≥769 的 margin: -sp3 -sp3 0 ⇒ 左右各外扩 12（199–203）
    expect(content.width, remaining + AylaSpacing.sp3 * 2); // 1364
    expect(content.left, AylaSpacing.sp3 + AylaDirectoryFilters.sidebarWidth + AylaSpacing.sp3 - AylaSpacing.sp3); // 236
    // 顶部外扩 12 ⇒ 裁剪盒顶边落在页面物理顶边（12 − 12）
    expect(content.top, 0);
    // 内容位置不变：padding sp3 与 margin −sp3 相抵
    expect(tester.getTopLeft(find.text('第一行')).dy, AylaSpacing.sp3);
  });

  testWidgets('内容区独立滚动：内层滚 100 不带动外层（真实指针路径）', (WidgetTester tester) async {
    await useViewport(tester, const Size(1600, 900));
    final ScrollController inner = ScrollController();
    final ScrollController outer = ScrollController();
    addTearDown(inner.dispose);
    addTearDown(outer.dispose);

    await tester.pumpWidget(host(
      SingleChildScrollView(
        controller: outer,
        child: SizedBox(
          height: 1400, // 外层可滚（视口 900）
          child: page(
            controller: inner,
            child: Column(
              children: <Widget>[
                for (int i = 0; i < 60; i++)
                  SizedBox(height: 40, child: Text('行 ${i}')),
              ],
            ),
          ),
        ),
      ),
    ));
    await settle(tester);
    expect(outer.offset, 0);

    // 真实指针：拖动内层 —— 手势竞技场由最内层 Scrollable 赢得。
    // 第一步只用于越过 kTouchSlop（DragStartBehavior.start 会丢弃这段位移，
    // 实测：一次 moveBy(-100) 只得 70），第二步才是被完整消费的滚动量。
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.text('行 0')),
    );
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(inner.offset, moreOrLessEquals(100, epsilon: 5));
    expect(outer.offset, 0); // ⚠️ 本用例的核心断言
  });

  testWidgets('≤768 单列：顶栏在上 / 内容在下 / page padding 0 / 底部安全区', (
    WidgetTester tester,
  ) async {
    await useViewport(tester, const Size(460, 700));
    final ScrollController inner = ScrollController();
    addTearDown(inner.dispose);
    await tester.pumpWidget(host(
      page(narrow: true, controller: inner),
      viewport: const Size(460, 700),
      viewPadding: const EdgeInsets.only(bottom: 34),
    ));
    await settle(tester);

    // .directory-page { padding: 0 }（220）+ body column + gap 0（221）
    final Rect sidebar = tester.getRect(find.byType(AylaDirectoryFilters));
    final Rect content = tester.getRect(scrollerOf(inner));
    expect(sidebar.left, 0);
    expect(sidebar.top, 0);
    expect(sidebar.width, 460);
    expect(content.left, 0);
    expect(content.width, 460);
    expect(content.top, sidebar.bottom); // gap 0

    // content: padding sp2 sp4 calc(68px + env(safe-area-inset-bottom))（244–246）
    final SingleChildScrollView view =
        tester.widget<SingleChildScrollView>(scrollerOf(inner));
    expect(
      view.padding,
      const EdgeInsets.fromLTRB(
        AylaSpacing.sp4,
        AylaSpacing.sp2,
        AylaSpacing.sp4,
        68 + 34,
      ),
    );
  });

  testWidgets('≥769 content padding：sp3 (sp2+sp3) sp6', (WidgetTester tester) async {
    await useViewport(tester, const Size(1600, 900));
    final ScrollController inner = ScrollController();
    addTearDown(inner.dispose);
    await tester.pumpWidget(host(page(controller: inner)));
    await settle(tester);

    final SingleChildScrollView view =
        tester.widget<SingleChildScrollView>(scrollerOf(inner));
    expect(
      view.padding,
      const EdgeInsets.fromLTRB(
        AylaSpacing.sp2 + AylaSpacing.sp3, // 左右 20
        AylaSpacing.sp3, // 上 12
        AylaSpacing.sp2 + AylaSpacing.sp3,
        AylaSpacing.sp6, // 下 24
      ),
    );

    // 列表容器 padding-top 归零的调用契约（204–208）
    final BuildContext context = tester.element(find.byType(AylaDirectoryContent));
    expect(aylaDirectoryIsWide(context), isTrue);
    expect(aylaDirectoryListPaddingTop(context), 0);
  });

  testWidgets('入场位移 12 → 0（directory-content-in 300ms）', (WidgetTester tester) async {
    await useViewport(tester, const Size(1600, 900));
    final ScrollController inner = ScrollController();
    addTearDown(inner.dispose);
    await tester.pumpWidget(host(page(controller: inner)));

    // 首帧：translateY(12px) + opacity 0（158–167）
    final double start = tester.getTopLeft(find.text('第一行')).dy;
    await tester.pump(const Duration(milliseconds: 300));
    final double end = tester.getTopLeft(find.text('第一行')).dy;

    expect(start - end, moreOrLessEquals(12, epsilon: 0.01));
    expect(end, AylaSpacing.sp3); // 终值 = 内容 padding-top
  });

  testWidgets('reduced-motion：animation none ⇒ 无位移、直接终值', (WidgetTester tester) async {
    await useViewport(tester, const Size(1600, 900));
    final ScrollController inner = ScrollController();
    addTearDown(inner.dispose);
    await tester.pumpWidget(
      host(page(controller: inner), disableAnimations: true),
    );

    final double start = tester.getTopLeft(find.text('第一行')).dy;
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getTopLeft(find.text('第一行')).dy, start);
    expect(start, AylaSpacing.sp3);
  });

  testWidgets('key={scope} 重挂载 ⇒ 入场重播；同 scope 不重播（对照）', (WidgetTester tester) async {
    await useViewport(tester, const Size(1600, 900));
    final ScrollController inner = ScrollController();
    addTearDown(inner.dispose);
    final GlobalKey<_ScopeHostState> hostKey = GlobalKey<_ScopeHostState>();
    await tester.pumpWidget(host(_ScopeHost(key: hostKey, controller: inner)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getTopLeft(find.text('第一行')).dy, AylaSpacing.sp3);

    // 对照：setState 重建但 scope 不变 ⇒ key 不变 ⇒ 不重播。
    // ⚠️ 必须走宿主 setState —— 同一用例里二次 pumpWidget 换 props **不生效**
    // （MaterialApp 的 route 复用旧 home；本项目已登记的「一态一用例」纪律）。
    hostKey.currentState!.setScope('all');
    await tester.pump();
    expect(tester.getTopLeft(find.text('第一行')).dy, AylaSpacing.sp3);

    // 换 scope ⇒ ValueKey 变化 ⇒ 重挂载 ⇒ 回到 12px 起始位移并重播
    hostKey.currentState!.setScope('post');
    await tester.pump();
    expect(tester.getTopLeft(find.text('第一行')).dy, AylaSpacing.sp3 + 12);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getTopLeft(find.text('第一行')).dy, AylaSpacing.sp3);
  });

  testWidgets('header 三段：kicker 10/w600/ls1.4/pink+.75 · title 17/w700 · stats 12/utility', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(
      const Center(
        child: SizedBox(
          width: 224,
          child: AylaDirectorySidebarHeader(
            kicker: 'Voice',
            title: '语音房间',
            stats: '12 房间在线 · 3 人在聊',
          ),
        ),
      ),
    ));

    // text-transform: uppercase（80）
    final Text kicker = tester.widget<Text>(find.text('VOICE'));
    expect(kicker.style!.fontFamily, AylaFonts.display);
    expect(kicker.style!.fontSize, 10);
    expect(kicker.style!.fontWeight, FontWeight.w600);
    expect(kicker.style!.letterSpacing, 1.4); // 0.14em × 10px
    expect(kicker.style!.color, AylaColors.pink500);
    final Opacity kickerOpacity = tester.widget<Opacity>(
      find.ancestor(of: find.text('VOICE'), matching: find.byType(Opacity)).first,
    );
    expect(kickerOpacity.opacity, 0.75); // opacity: 0.75（79）

    final Text title = tester.widget<Text>(find.text('语音房间'));
    expect(title.style!.fontFamily, AylaFonts.display);
    expect(title.style!.fontSize, 17);
    expect(title.style!.fontWeight, FontWeight.w700);
    expect(title.style!.color, AylaColors.textPrimary);
    expect(title.style!.height, 1.25);

    final Text stats = tester.widget<Text>(find.text('12 房间在线 · 3 人在聊'));
    expect(stats.style!.fontFamily, AylaFonts.utility);
    expect(stats.style!.fontSize, 12);
    expect(stats.style!.color, AylaColors.textSecondary);
  });

  testWidgets('decor：size 64 + rotate −8° + opacity .42 + pointer-events none', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(
      Center(
        child: SizedBox(
          width: 224,
          child: AylaDirectoryDecorIcon(icon: aylaIconByName('iconMic')!),
        ),
      ),
    ));

    final AylaIcon icon = tester.widget<AylaIcon>(find.byType(AylaIcon));
    expect(icon.icon.name, 'iconMic'); // VoiceHubPage.tsx:275
    expect(icon.size, 64);
    expect(icon.color, AylaColors.pink500);
    // 旋转不改变布局盒（web transform 同理）
    expect(tester.getSize(find.byType(AylaIcon)), const Size(64, 64));

    final Opacity opacity = tester.widget<Opacity>(
      find.ancestor(of: find.byType(AylaIcon), matching: find.byType(Opacity)).first,
    );
    expect(opacity.opacity, 0.42);

    final Transform rotate = tester.widget<Transform>(
      find.ancestor(of: find.byType(AylaIcon), matching: find.byType(Transform)).first,
    );
    final double angle = -8 * math.pi / 180;
    expect(rotate.transform.entry(0, 0), moreOrLessEquals(math.cos(angle), epsilon: 1e-9));
    expect(rotate.transform.entry(1, 0), moreOrLessEquals(math.sin(angle), epsilon: 1e-9));

    expect(
      find.ancestor(of: find.byType(AylaIcon), matching: find.byType(IgnorePointer)),
      findsWidgets,
    );
  });

  testWidgets('返回键：.icon-btn-40 档 40×40 + 图标 20 + aria-label「返回」', (
    WidgetTester tester,
  ) async {
    int taps = 0;
    await tester.pumpWidget(host(
      Center(child: AylaDirectoryBackButton(onPressed: () => taps++)),
    ));
    await tester.pump();

    final AylaIconButton button =
        tester.widget<AylaIconButton>(find.byType(AylaIconButton));
    expect(button.size, 40);
    expect(button.square, isFalse); // pill（.icon-btn-40 radius-pill）
    expect(button.semanticLabel, '返回');
    expect(tester.getSize(find.byType(AylaIconButton)), const Size(40, 40));

    final AylaIcon icon = tester.widget<AylaIcon>(find.byType(AylaIcon));
    expect(icon.icon.name, 'iconBack');
    expect(icon.size, 20);

    await tester.tap(find.byType(AylaIconButton));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('窄屏 helper：aylaDirectoryListPaddingTop 为 null、isWide 为 false', (
    WidgetTester tester,
  ) async {
    await useViewport(tester, const Size(460, 700));
    final ScrollController inner = ScrollController();
    addTearDown(inner.dispose);
    await tester.pumpWidget(host(
      page(narrow: true, controller: inner),
      viewport: const Size(460, 700),
    ));
    await settle(tester);

    final BuildContext context = tester.element(find.byType(AylaDirectoryContent));
    expect(aylaDirectoryIsNarrow(context), isTrue);
    expect(aylaDirectoryListPaddingTop(context), isNull);
  });
}

/// scope 变化宿主 —— 真实交互路径（setState 换 `scope` ⇒ [AylaDirectoryContent] 换 key）。
///
/// 不用二次 `pumpWidget` 换 props：MaterialApp 的 route 会复用旧 home，
/// 新 props 根本到不了组件（实测：scope 仍读到 'all'）。
class _ScopeHost extends StatefulWidget {
  const _ScopeHost({super.key, required this.controller});

  final ScrollController controller;

  @override
  State<_ScopeHost> createState() => _ScopeHostState();
}

class _ScopeHostState extends State<_ScopeHost> {
  String _scope = 'all';

  /// 换分类作用域（web `key={scope}`）。
  void setScope(String next) => setState(() => _scope = next);

  @override
  Widget build(BuildContext context) {
    return AylaDirectoryPage(
      filters: AylaDirectoryFilters(
        label: '收藏分类',
        options: const <({String key, String label})>[
          (key: 'all', label: '全部'),
          (key: 'post', label: '帖子'),
        ],
        value: _scope,
        onChange: (String _) {},
      ),
      content: AylaDirectoryContent(
        controller: widget.controller,
        scope: _scope,
        label: '全部',
        child: const Text('第一行'),
      ),
    );
  }
}
