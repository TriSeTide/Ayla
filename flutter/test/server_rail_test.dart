/// AylaServerRail 定向测试（ServerRail.tsx + group.css 484–678 +
/// auroraqua.css 216 / 217–229 / 270 / 311–313 / 125–138 对照）。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/app_icons.dart' show AylaIcon;
import '../lib/theme/buttons.dart' show AylaIconButton;
import '../lib/theme/glass.dart' show AylaGlassSurface;
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/avatar_halo.dart';
import '../lib/widgets/base/avatar_status_badges.dart';
import '../lib/widgets/base/directory_controls.dart';
import '../lib/widgets/base/menu_item.dart';
import '../lib/widgets/base/primitives.dart'
    show AylaNavHighlight, AylaNavHighlightVariant;
import '../lib/widgets/base/reveal.dart' show AylaRevealItem;
import '../lib/widgets/shell/server_rail.dart';
import '../lib/widgets/base/tab_badge.dart';

const List<AylaServerRailGroup> kGroups = <AylaServerRailGroup>[
  AylaServerRailGroup(
    id: 'g1',
    title: '技术群',
    unreadCount: 12,
    postUnreadCount: 3,
    isPinned: true,
    presence: AylaAvatarStatus(live: true, voice: true),
  ),
  AylaServerRailGroup(id: 'g2', title: '摸鱼群'),
  AylaServerRailGroup(id: 'g3', title: '爱莉的客厅', unreadCount: 180),
];

void main() {
  // 入场是**调用方给的开关**（`animateEntrance`），本件不持有任何模块级状态
  // ⇒ 用例之间无需复位（历史实现里的 `kAylaServerRailEntered` 已随 2026-11-02
  // 的 owner 迁移删除，见 `server_rail.dart` 的 `animateEntrance` 文档）。
  String? selected;
  int createTaps = 0;
  String? pinnedId;
  bool? pinnedValue;

  setUp(() {
    selected = null;
    createTaps = 0;
    pinnedId = null;
    pinnedValue = null;
  });

  Widget host({
    List<AylaServerRailGroup> groups = kGroups,
    String? currentGroupId = 'g1',
    bool animateEntrance = false,
    double height = 600,
  }) {
    return MaterialApp(
      home: previewScope(
        Center(
          child: SizedBox(
            height: height,
            child: AylaServerRail(
              groups: groups,
              currentGroupId: currentGroupId,
              onSelectGroup: (String id) => selected = id,
              onCreateGroup: () => createTaps++,
              loadMore: () async {},
              refresh: () async {},
              onTogglePin: (String id, bool pinned) async {
                pinnedId = id;
                pinnedValue = pinned;
              },
              animateEntrance: animateEntrance,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('结构：每群一个光环头像 + 底部 53px 加号 + 目录页脚', (WidgetTester tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.byType(AylaAvatarHalo), findsNWidgets(3));
    expect(find.byType(AylaAvatarStatusBadges), findsNWidgets(3));
    expect(find.byType(AylaIconButton), findsOneWidget);
    expect(find.byType(AylaDirectoryLoadMore), findsOneWidget);

    final Size create = tester.getSize(find.byType(AylaIconButton));
    expect(create.width, AylaServerRail.createButtonSize);
    expect(create.height, AylaServerRail.createButtonSize);

    final AylaAvatarHalo halo = tester.widget(find.byType(AylaAvatarHalo).first);
    expect(halo.size, 48);
    expect(halo.online, isTrue);
    expect(tester.getSize(find.byType(AylaAvatarHalo).first).width, 53);
  });

  testWidgets('容器：列宽 72、外距 12/0/12/12（auroraqua 270 覆写右 0）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(AylaGlassSurface).first).width, 72);
    expect(
      find.byWidgetPredicate(
        (Widget w) => w is Padding && w.padding == AylaServerRail.wideMargin,
      ),
      findsOneWidget,
    );
    expect(AylaServerRail.wideMargin, const EdgeInsets.fromLTRB(12, 12, 0, 12));
  });

  testWidgets('列表：padding 20/77、行距 12、clip 15、上 20 下 16 渐隐', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate(
        (Widget w) =>
            w is Padding &&
            w.padding ==
                const EdgeInsets.only(
                  top: AylaServerRail.listPaddingTop,
                  bottom: AylaServerRail.listPaddingBottom,
                ),
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate((Widget w) => w is Column && w.spacing == 12),
      findsWidgets,
    );
    final Finder clips = find.descendant(
      of: find.byType(AylaServerRail),
      matching: find.byType(ClipRRect),
    );
    expect(
      clips.evaluate().any(
        (Element e) =>
            (e.widget as ClipRRect).borderRadius ==
            BorderRadius.circular(AylaServerRail.railRadius - 1),
      ),
      isTrue,
    );
    final ShaderMask mask = tester.widget(find.byType(ShaderMask));
    expect(mask.blendMode, BlendMode.dstIn);
  });

  testWidgets('滚动条已关：Windows 平台下不挂 Scrollbar（web base.css 全局隐藏）', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(find.byType(Scrollbar), findsNothing);
      expect(find.byType(SingleChildScrollView), findsWidgets);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('指示条：3×32 rail 档，垂直居中于选中行、切群后迁移', (WidgetTester tester) async {
    String current = 'g1';
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: previewScope(
          Center(
            child: SizedBox(
              height: 600,
              child: StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) {
                  rebuild = setState;
                  return AylaServerRail(
                    groups: kGroups,
                    currentGroupId: current,
                    onSelectGroup: (String id) => selected = id,
                    onCreateGroup: () {},
                    loadMore: () async {},
                    refresh: () async {},
                    animateEntrance: false,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Finder indicator = find.byType(AylaNavHighlight);
    expect(indicator, findsOneWidget);
    expect(
      tester.widget<AylaNavHighlight>(indicator).variant,
      AylaNavHighlightVariant.rail,
    );
    expect(tester.getSize(indicator).width, 3);
    expect(tester.getSize(indicator).height, 32);

    final Rect row1 = tester.getRect(find.byType(AylaAvatarHalo).at(0));
    expect(tester.getRect(indicator).center.dy, closeTo(row1.center.dy, 0.5));

    rebuild(() => current = 'g3');
    await tester.pumpAndSettle();
    final Rect row3 = tester.getRect(find.byType(AylaAvatarHalo).at(2));
    expect(tester.getRect(indicator).center.dy, closeTo(row3.center.dy, 0.5));
  });

  testWidgets('未读徽标 = 消息未读 + 帖子未读，99+ 截断，0 不渲染', (WidgetTester tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    final List<AylaTabBadge> badges = tester
        .widgetList<AylaTabBadge>(find.byType(AylaTabBadge))
        .toList();
    expect(badges.length, 2);
    expect(badges[0].count, 15);
    expect(badges[1].count, 180);
    expect(badges[1].max, 99);
    for (final AylaTabBadge b in badges) {
      expect(b.metrics, AylaTabBadgeMetrics.serverItem);
    }
    expect(find.text('15'), findsOneWidget);
    expect(find.text('99+'), findsOneWidget);

    final Rect badgeRect = tester.getRect(find.byType(AylaTabBadge).first);
    final Rect haloRect = tester.getRect(find.byType(AylaAvatarHalo).first);
    expect(badgeRect.left, closeTo(haloRect.left - 3, 0.5));
    expect(badgeRect.bottom, closeTo(haloRect.bottom + 3, 0.5));
  });

  testWidgets('置顶 pin：左上角 -6/-4、45° 倾斜、--pink-500', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    final Iterable<AylaIcon> icons = tester.widgetList<AylaIcon>(
      find.descendant(
        of: find.byType(AylaServerRail),
        matching: find.byType(AylaIcon),
      ),
    );
    final AylaIcon pin = icons.firstWhere(
      (AylaIcon i) => i.color == AylaColors.pink500,
    );
    expect(pin.icon.name, 'iconPinFilled');
    expect(pin.size, 16);

    expect(
      find.byWidgetPredicate(
        (Widget w) => w is Positioned && w.top == -4 && w.left == -6,
      ),
      findsOneWidget,
    );
    final Rect haloRect = tester.getRect(find.byType(AylaAvatarHalo).first);
    final Offset pinCenter = tester.getRect(find.byWidget(pin)).center;
    expect(pinCenter.dx, closeTo(haloRect.left - 6 + 8, 0.5));
    expect(pinCenter.dy, closeTo(haloRect.top - 4 + 8, 0.5));

    final Iterable<Transform> transforms = tester.widgetList<Transform>(
      find.descendant(
        of: find.byType(AylaServerRail),
        matching: find.byType(Transform),
      ),
    );
    expect(
      transforms.any(
        (Transform t) =>
            (t.transform.storage[1] - (-math.sin(math.pi / 4))).abs() < 1e-6,
      ),
      isTrue,
    );
  });

  testWidgets('点击行切换群（头像区域）+ 点加号建群', (WidgetTester tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(AylaAvatarHalo).at(1));
    await tester.pump();
    expect(selected, 'g2');

    await tester.tap(find.byType(AylaIconButton));
    await tester.pump();
    expect(createTaps, 1);
  });

  testWidgets('选中头像 scale 52/48，其余 1.0', (WidgetTester tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    final List<AnimatedScale> scales = tester
        .widgetList<AnimatedScale>(
          find.descendant(
            of: find.byType(AylaServerRail),
            matching: find.byType(AnimatedScale),
          ),
        )
        .toList();
    final List<double> values = scales
        .map((AnimatedScale s) => s.scale)
        .toList();
    expect(
      values
          .where(
            (double v) => (v - AylaServerRail.activeAvatarScale).abs() < 1e-9,
          )
          .length,
      1,
    );
    expect(
      values.where((double v) => v == 1.0).length,
      greaterThanOrEqualTo(3),
    );
  });

  testWidgets('悬停展开置顶面板：锚点在行右缘 +2、垂直居中；移出 180ms 后收起', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(height: 700));
    await tester.pumpAndSettle();
    expect(find.text('置顶'), findsNothing);

    final TestGesture gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(AylaAvatarHalo).at(1)));
    await tester.pump();

    expect(find.text('置顶'), findsOneWidget);
    expect(find.text('摸鱼群'), findsOneWidget);

    final Finder panel = find.ancestor(
      of: find.text('置顶'),
      matching: find.byType(AylaGlassSurface),
    );
    expect(panel, findsOneWidget);
    expect(tester.widget<AylaGlassSurface>(panel).strong, isTrue);
    final Rect panelRect = tester.getRect(panel);
    final Rect railRect = tester.getRect(find.byType(AylaGlassSurface).first);
    final Rect rowRect = tester.getRect(find.byType(AylaAvatarHalo).at(1));
    expect(panelRect.center.dy, closeTo(rowRect.center.dy + 1, 0.5));
    expect(panelRect.left, closeTo(railRect.right + 2, 0.5));
    expect(panelRect.width, greaterThanOrEqualTo(136));

    await gesture.moveTo(const Offset(1, 1));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('置顶'), findsOneWidget, reason: '180ms 内不收起');
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('置顶'), findsNothing);
  });

  testWidgets('面板动作行：rail 档规格（34/8/8/13/14/6）与点击置顶', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(height: 700));
    await tester.pumpAndSettle();

    final TestGesture gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(AylaAvatarHalo).at(1)));
    await tester.pump();

    final AylaMenuItem item = tester.widget(find.byType(AylaMenuItem));
    expect(item.metrics, AylaMenuItemMetrics.rail);
    expect(item.label, '置顶');
    expect(
      tester.getSize(find.byType(AylaMenuItem)).height,
      greaterThanOrEqualTo(AylaMenuItemMetrics.rail.minHeight),
    );

    await tester.tap(find.byType(AylaMenuItem));
    await tester.pump();
    expect(pinnedId, 'g2');
    expect(pinnedValue, isTrue);
  });

  testWidgets('已置顶群的面板文案为「取消置顶」', (WidgetTester tester) async {
    await tester.pumpWidget(host(currentGroupId: 'g2', height: 700));
    await tester.pumpAndSettle();
    final TestGesture gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(AylaAvatarHalo).first));
    await tester.pump();
    expect(find.text('取消置顶'), findsOneWidget);
  });

  testWidgets('入场：animateEntrance=false 不挂 AylaRevealItem', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(animateEntrance: false));
    await tester.pumpAndSettle();
    expect(find.byType(AylaRevealItem), findsNothing);
  });

  /// ⚠️ `AylaRevealItem` **只在被新建时**播入场；复用同一实例时「再播一次」
  /// 会被它静默忽略 ⇒ 本件用 `_enterTick` 换 key 表达重播（见 `server_rail.dart`）。
  /// 这条锁住「开关 false→true 必须重播」与「true 期间不重播」。
  ///
  /// ⚠️ 宿主必须自己 setState 改 prop：`pumpWidget` 对同一个 `MaterialApp`
  /// **不会**重建 `home:` 路由（实测 `widget.animateEntrance` 仍是旧值），
  /// 那样写出来的用例是假绿。
  testWidgets('入场：animateEntrance false→true 重播一次；true 期间不重播', (
    WidgetTester tester,
  ) async {
    final GlobalKey<_RailToggleBodyState> key = GlobalKey<_RailToggleBodyState>();
    await tester.pumpWidget(_EntranceToggle(animate: false, bodyKey: key));
    await tester.pumpAndSettle();
    expect(find.byType(AylaRevealItem), findsNothing);

    key.currentState!.arm();
    await tester.pump();
    final Finder reveals = find.byType(AylaRevealItem);
    expect(reveals, findsOneWidget, reason: '抬起开关必须把入场层挂上');
    final AylaRevealItem fired = tester.widget(reveals);
    expect(fired.offset.dx, -20);
    expect(fired.duration, AylaDurations.auroraqua);
    expect(fired.curve, AylaCurves.auroraquaEaseInOut);
    final Key? firedKey = fired.key;

    // true 期间再触发若干次重建：key 不得变（换 key = 入场重来一次）。
    await tester.pumpAndSettle();
    key.currentState!.rebuild();
    await tester.pump();
    expect(
      tester.widget(reveals).key,
      firedKey,
      reason: 'true 期间不得重播（换 key 会让入场再来一次）',
    );
  });

  testWidgets('入场：animateEntrance=true → 左入 -20 / 300ms easeInOut', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(animateEntrance: true));
    await tester.pump();
    final AylaRevealItem reveal = tester.widget(find.byType(AylaRevealItem));
    expect(reveal.offset.dx, -20);
    expect(reveal.duration, AylaDurations.auroraqua);
    expect(reveal.curve, AylaCurves.auroraquaEaseInOut);
  });


  testWidgets('无选中群时不画指示条', (WidgetTester tester) async {
    await tester.pumpWidget(host(currentGroupId: null));
    await tester.pumpAndSettle();
    expect(find.byType(AylaNavHighlight), findsNothing);
  });
}

/// 入场开关的**可切换宿主**（「false→true 重播」用例用）。
///
/// ⚠️ 两层结构**都是必须的**：
/// - `MaterialApp` 只建一次，`home:` 里放的是下面那个 **StatefulWidget** ———
///   `MaterialApp` 的 `home` 会被包进**一次性的 route builder**，随后台壳层
///   setState 再传新 `home` **不会**更新已存在的路由子树
///   （实测：宿主 `animate=false` 已重建，而 `tester.widget<AylaServerRail>().animateEntrance`
///   仍是旧值 ⇒ 用例会假绿）。
/// - 开关必须落在 route 内部的有状态件上，才能真正驱动本组件的 `didUpdateWidget`。
class _EntranceToggle extends StatefulWidget {
  const _EntranceToggle({super.key, required this.animate, required this.bodyKey});

  final bool animate;

  /// 挂在 route **内部**那个可切换板上的 key（宿主类自己是被 route 包住的，拿不到 State）。
  final GlobalKey<_RailToggleBodyState> bodyKey;

  @override
  State<_EntranceToggle> createState() => _EntranceToggleState();
}

class _EntranceToggleState extends State<_EntranceToggle> {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: previewScope(
        _RailToggleBody(key: widget.bodyKey, animate: widget.animate),
      ),
    );
  }
}

/// route 内部的可切换板（[GlobalKey] 就挂在它上面）。
class _RailToggleBody extends StatefulWidget {
  const _RailToggleBody({super.key, required this.animate});

  final bool animate;

  @override
  State<_RailToggleBody> createState() => _RailToggleBodyState();
}

class _RailToggleBodyState extends State<_RailToggleBody> {
  late bool _animate = widget.animate;

  /// 抬起入场开关（= 页面把 `_railEntrance` 由 false 翻成 true）。
  void arm() => setState(() => _animate = true);

  /// 纯重建（开关不变），验证 true 期间不重播。
  void rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned(
          left: 0,
          top: 0,
          height: 480,
          width: 200,
          child: AylaServerRail(
            groups: kGroups,
            currentGroupId: 'g1',
            onSelectGroup: (String id) {},
            onCreateGroup: () {},
            loadMore: () async {},
            refresh: () async {},
            animateEntrance: _animate,
          ),
        ),
      ],
    );
  }
}