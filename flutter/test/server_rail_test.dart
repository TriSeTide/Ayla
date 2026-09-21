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
import '../lib/theme/glass.dart' show GlassSurface;
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/avatar_halo.dart';
import '../lib/widgets/avatar_status_badges.dart';
import '../lib/widgets/directory_controls.dart';
import '../lib/widgets/menu_item.dart';
import '../lib/widgets/primitives.dart'
    show AylaNavHighlight, AylaNavHighlightVariant;
import '../lib/widgets/reveal.dart' show AylaRevealItem;
import '../lib/widgets/server_rail.dart';
import '../lib/widgets/tab_badge.dart';

const List<AylaServerRailGroup> kGroups = <AylaServerRailGroup>[
  AylaServerRailGroup(
    id: 'g1',
    title: '技术群',
    unreadCount: 12,
    postUnreadCount: 3,
    isPinned: true,
    presence: AvatarStatus(live: true, voice: true),
  ),
  AylaServerRailGroup(id: 'g2', title: '摸鱼群'),
  AylaServerRailGroup(id: 'g3', title: '爱莉的客厅', unreadCount: 180),
];

void main() {
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

    expect(find.byType(AvatarHalo), findsNWidgets(3));
    expect(find.byType(AylaAvatarStatusBadges), findsNWidgets(3));
    expect(find.byType(AylaIconButton), findsOneWidget);
    expect(find.byType(AylaDirectoryLoadMore), findsOneWidget);

    final Size create = tester.getSize(find.byType(AylaIconButton));
    expect(create.width, AylaServerRail.createButtonSize);
    expect(create.height, AylaServerRail.createButtonSize);

    final AvatarHalo halo = tester.widget(find.byType(AvatarHalo).first);
    expect(halo.size, 48);
    expect(halo.online, isTrue);
    expect(tester.getSize(find.byType(AvatarHalo).first).width, 53);
  });

  testWidgets('容器：列宽 72、外距 12/0/12/12（auroraqua 270 覆写右 0）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byType(GlassSurface).first).width, 72);
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

    final Rect row1 = tester.getRect(find.byType(AvatarHalo).at(0));
    expect(tester.getRect(indicator).center.dy, closeTo(row1.center.dy, 0.5));

    rebuild(() => current = 'g3');
    await tester.pumpAndSettle();
    final Rect row3 = tester.getRect(find.byType(AvatarHalo).at(2));
    expect(tester.getRect(indicator).center.dy, closeTo(row3.center.dy, 0.5));
  });

  testWidgets('未读徽标 = 消息未读 + 帖子未读，99+ 截断，0 不渲染', (WidgetTester tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    final List<TabBadge> badges = tester
        .widgetList<TabBadge>(find.byType(TabBadge))
        .toList();
    expect(badges.length, 2);
    expect(badges[0].count, 15);
    expect(badges[1].count, 180);
    expect(badges[1].max, 99);
    for (final TabBadge b in badges) {
      expect(b.metrics, TabBadgeMetrics.serverItem);
    }
    expect(find.text('15'), findsOneWidget);
    expect(find.text('99+'), findsOneWidget);

    final Rect badgeRect = tester.getRect(find.byType(TabBadge).first);
    final Rect haloRect = tester.getRect(find.byType(AvatarHalo).first);
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
    final Rect haloRect = tester.getRect(find.byType(AvatarHalo).first);
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

    await tester.tap(find.byType(AvatarHalo).at(1));
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
    await gesture.moveTo(tester.getCenter(find.byType(AvatarHalo).at(1)));
    await tester.pump();

    expect(find.text('置顶'), findsOneWidget);
    expect(find.text('摸鱼群'), findsOneWidget);

    final Finder panel = find.ancestor(
      of: find.text('置顶'),
      matching: find.byType(GlassSurface),
    );
    expect(panel, findsOneWidget);
    expect(tester.widget<GlassSurface>(panel).strong, isTrue);
    final Rect panelRect = tester.getRect(panel);
    final Rect railRect = tester.getRect(find.byType(GlassSurface).first);
    final Rect rowRect = tester.getRect(find.byType(AvatarHalo).at(1));
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
    await gesture.moveTo(tester.getCenter(find.byType(AvatarHalo).at(1)));
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
    await gesture.moveTo(tester.getCenter(find.byType(AvatarHalo).first));
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
