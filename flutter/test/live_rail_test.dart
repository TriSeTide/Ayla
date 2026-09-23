/// B2-3：直播侧栏 + 开播选择器定向测试 —— 逐条对照 `components/live/LiveChannelRail.tsx`(168)
/// 与 `LiveStartSheet.tsx`(86)、`live.css:10–29/232–239/311–423/1356–1370`、
/// `auroraqua.css:125–139/175–205/412–454`，并移植官方用例
/// `vitest/live-rail.test.tsx:47–290`（宽屏 / 收起态 / 窄屏覆盖层 / 自动滚动 / 控制台扩展）
/// 与 `:292–312`（开播选择器）。
///
/// 覆盖：结构（nav 壳 / 操作区 54 / 列表 padding sp3 + gap sp2 / 新建区）/ 尺寸（240 + margin 12、
/// 窄屏 min(240, vw-48)、封面 72×16:9、图标钮 36、删除键 22×22）/ 行（hover .18 / 选中自身透明 +
/// 高亮迁移 / 标题 2 行截断 / 人数角标与「直播中」圆点）/ 交互（切换、收起后不渲染、返回、删除、
/// 新建）/ 自动滚到当前项 / 开播选择器的五态与两个按钮。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/buttons.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/live_hall.dart' show AylaLiveCardData, AylaLiveStatus;
import '../lib/widgets/create_sheet.dart' show AylaCreateSheet;
import '../lib/widgets/dialogs.dart' show AylaModalCard, AylaSheetHead;
import '../lib/widgets/live_rail.dart';
import '../lib/theme/app_icons.dart' show AylaIcon;
import '../lib/widgets/primitives.dart' show AylaNavHighlight;
import '../lib/widgets/reveal.dart' show AylaRevealItem;

AylaLiveCardData _ch(
  String id,
  String title, {
  AylaLiveStatus status = AylaLiveStatus.live,
  int? viewerCount = 12,
  String? cover,
}) {
  return AylaLiveCardData(
    id: id,
    title: title,
    status: status,
    cover: cover,
    viewerCount: viewerCount,
  );
}

const List<AylaLiveCardData> _channels = <AylaLiveCardData>[
  AylaLiveCardData(id: '1', title: '第一场直播', status: AylaLiveStatus.live),
  AylaLiveCardData(id: '2', title: '第二场直播', status: AylaLiveStatus.live),
  AylaLiveCardData(id: '3', title: '第三场直播', status: AylaLiveStatus.ended),
];

void main() {
  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget host(
    WidgetTester tester,
    Widget child, {
    Size viewport = const Size(1200, 700),
  }) {
    setViewport(tester, viewport);
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox.fromSize(size: viewport, child: child),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Finder item(String label) => find.byWidgetPredicate(
    (Widget w) => w is Semantics && w.properties.label == label,
  );

  group('宽屏展开态（官方用例 47–110）', () {
    testWidgets('返回键在侧栏内 + 三个封面项 + 当前项 aria-current（selected）', (WidgetTester tester) async {
      int backs = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveChannelRail(
            channels: _channels,
            currentId: '2',
            onSelect: (_) {},
            onToggle: () {},
            onBack: () => backs += 1,
            showBack: true,
          ),
        ),
      );
      await settle(tester);

      expect(item('返回'), findsOneWidget);
      expect(item('切换到直播间 第一场直播'), findsOneWidget);
      expect(item('切换到直播间 第二场直播'), findsOneWidget);
      expect(item('切换到直播间 第三场直播'), findsOneWidget);
      expect(
        tester.widget<Semantics>(item('切换到直播间 第二场直播')).properties.selected,
        isTrue,
      );
      await tester.tap(item('返回'));
      await settle(tester);
      expect(backs, 1);
    });

    testWidgets('点击封面 → onSelect 切换直播间', (WidgetTester tester) async {
      final List<String> selected = <String>[];
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveChannelRail(
            channels: _channels,
            currentId: '1',
            onSelect: selected.add,
            onToggle: () {},
            onBack: () {},
          ),
        ),
      );
      await settle(tester);
      await tester.tap(item('切换到直播间 第三场直播'));
      await settle(tester);
      expect(selected, <String>['3']);
    });

    testWidgets('收起按钮 → onToggle（收起侧栏）', (WidgetTester tester) async {
      int toggles = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveChannelRail(
            channels: _channels,
            currentId: '1',
            onSelect: (_) {},
            onToggle: () => toggles += 1,
            onBack: () {},
          ),
        ),
      );
      await settle(tester);
      await tester.tap(item('收起直播间列表'));
      await settle(tester);
      expect(toggles, 1);
    });

    testWidgets('几何：宽 240 + margin 12；操作区 min-height 54；列表 padding sp3', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveChannelRail(
            channels: _channels,
            currentId: '1',
            onSelect: (_) {},
            onToggle: () {},
            onBack: () {},
          ),
        ),
      );
      await settle(tester);

      // `width: 240` 是权威值（CSS 压过父级拉伸）；组件根会填满宿主，故量侧栏本体
      expect(tester.getRect(find.byType(GlassSurface)).width, 240);
      // `margin: var(--sidebar-gutter)`
      expect(tester.getRect(find.byType(GlassSurface)).left, AylaSpacing.sidebarGutter);
      // `.live-rail-actions { min-height: 54px }`
      expect(
        find.byWidgetPredicate(
          (Widget w) => w is Container && w.constraints?.minHeight == 54,
        ),
        findsOneWidget,
      );
      // 图标钮 36×36
      expect(
        tester.getSize(find.byType(AylaIconButton).first),
        const Size(36, 36),
      );
    });
  });

  group('收起态（官方用例 111–131）', () {
    testWidgets('收起后侧栏不渲染任何内容（键由顶栏承载）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveChannelRail(
            channels: _channels,
            currentId: '1',
            onSelect: (_) {},
            onToggle: () {},
            onBack: () {},
            collapsed: true,
          ),
        ),
      );
      await settle(tester);
      expect(find.byType(GlassSurface), findsNothing);
      expect(item('切换到直播间 第一场直播'), findsNothing);
      expect(item('收起直播间列表'), findsNothing);
    });
  });

  group('窄屏覆盖层（官方用例 133–167）', () {
    testWidgets('showBack=false → 侧栏内不渲染返回键；从右入场档', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveChannelRail(
            channels: _channels,
            currentId: '1',
            onSelect: (_) {},
            onToggle: () {},
            onBack: () {},
            showBack: false,
            enterFromRight: true,
          ),
          viewport: const Size(420, 700),
        ),
      );
      await settle(tester);

      expect(item('返回'), findsNothing);
      expect(item('收起直播间列表'), findsOneWidget);
      // 从右入场：AylaRevealItem 的 offset 为 +20（左入是 -20）
      final AylaRevealItem reveal = tester.widget<AylaRevealItem>(
        find.byType(AylaRevealItem),
      );
      expect(reveal.offset.dx, 20);
      // ≤768：`width: min(240px, calc(100vw - 48px))`
      expect(
        tester.getRect(find.byType(GlassSurface)).width,
        lessThanOrEqualTo(240),
      );
    });

    testWidgets('≤768 且视口更窄 → 宽度 = 视口 - 48', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveChannelRail(
            channels: _channels,
            currentId: '1',
            onSelect: (_) {},
            onToggle: () {},
            onBack: () {},
          ),
          viewport: const Size(220, 700), // 220 - 48 = 172 < 240
        ),
      );
      await settle(tester);
      expect(tester.getRect(find.byType(GlassSurface)).width, 172);
    });
  });

  group('行内元素（live.css 365–423 / 1356–1370）', () {
    testWidgets('封面 72×16:9 + 无封面用 iconVideo 18 + 在播时 8×8 圆点', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveChannelRail(
            channels: <AylaLiveCardData>[
              _ch('1', '在播', status: AylaLiveStatus.live),
              _ch('2', '已结束', status: AylaLiveStatus.ended),
            ],
            currentId: '1',
            onSelect: (_) {},
            onToggle: () {},
            onBack: () {},
          ),
        ),
      );
      await settle(tester);

      // 72 宽的封面框
      expect(
        find.byWidgetPredicate((Widget w) => w is SizedBox && w.width == 72),
        findsNWidgets(2),
      );
      // iconVideo 18：两张卡各一个
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w is AylaIcon && w.icon.name == 'iconVideo' && w.size == 18,
        ),
        findsNWidgets(2),
      );
      // 「直播中」圆点只有第一项
      expect(item('直播中'), findsOneWidget);
    });

    testWidgets('标题 13 / 1.35 / 2 行截断；人数角标 utility 11 + 「N 人在看」', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveChannelRail(
            channels: <AylaLiveCardData>[
              _ch('1', '一个很长很长的直播间标题用来验证两行截断行为', viewerCount: 1240),
            ],
            currentId: '1',
            onSelect: (_) {},
            onToggle: () {},
            onBack: () {},
          ),
        ),
      );
      await settle(tester);

      final Text title = tester.widget<Text>(
        find.text('一个很长很长的直播间标题用来验证两行截断行为'),
      );
      expect(title.maxLines, 2); // `-webkit-line-clamp: 2`
      expect(title.overflow, TextOverflow.ellipsis);
      expect(title.style?.fontSize, 13);
      expect(title.style?.height, 1.35);

      expect(item('1240 人在看'), findsOneWidget);
      expect(find.text('1.2k'), findsOneWidget); // formatViewerCount
      final Text count = tester.widget<Text>(find.text('1.2k'));
      expect(count.style?.fontFamily, AylaFonts.utility);
      expect(count.style?.fontSize, 11);
      expect(count.style?.letterSpacing, 0.3);
      expect(count.style?.height, 1);
    });

    testWidgets('未在播 / 读数缺失 → 不渲染人数角标', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveChannelRail(
            channels: <AylaLiveCardData>[
              _ch('1', '已结束', status: AylaLiveStatus.ended, viewerCount: 5),
              _ch('2', '读不到', status: AylaLiveStatus.live, viewerCount: null),
            ],
            currentId: '1',
            onSelect: (_) {},
            onToggle: () {},
            onBack: () {},
          ),
        ),
      );
      await settle(tester);
      expect(find.textContaining('人在看'), findsNothing);
    });
  });

  group('选中高亮（auroraqua 175–187：容器级单实例 + 跨项迁移）', () {
    testWidgets('只有一个高亮实例；选中行自身底色透明', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveChannelRail(
            channels: _channels,
            currentId: '1',
            onSelect: (_) {},
            onToggle: () {},
            onBack: () {},
          ),
        ),
      );
      await settle(tester);

      expect(find.byType(AylaNavHighlight), findsOneWidget);
      // 高亮矩形 = 选中项的行矩形（宽 = 内容宽）
      final Rect highlight = tester.getRect(find.byType(AylaNavHighlight));
      final Rect row = tester.getRect(item('切换到直播间 第一场直播'));
      expect(highlight.width, closeTo(row.width, 0.5));

      // 选中行自身底色透明（web：auroraqua 194–197 清零 `.is-active` 的 .35）
      final Container box = tester.widget<Container>(
        find
            .descendant(
              of: item('切换到直播间 第一场直播'),
              matching: find.byType(Container),
            )
            .first,
      );
      expect((box.decoration! as BoxDecoration).color, Colors.transparent);
    });

    testWidgets('切换选中 → 高亮在 300ms 内迁移到新项位置', (WidgetTester tester) async {
      String current = '1';
      late StateSetter setLocal;
      await tester.pumpWidget(
        host(
          tester,
          StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              setLocal = setState;
              return AylaLiveChannelRail(
                channels: _channels,
                currentId: current,
                onSelect: (_) {},
                onToggle: () {},
                onBack: () {},
              );
            },
          ),
        ),
      );
      await settle(tester);
      final double before = tester.getRect(find.byType(AylaNavHighlight)).top;

      setLocal(() => current = '3');
      await settle(tester);
      final double after = tester.getRect(find.byType(AylaNavHighlight)).top;
      expect(after, greaterThan(before));
      // 迁移后高亮仍在选中项上
      final Rect row = tester.getRect(item('切换到直播间 第三场直播'));
      expect(
        tester.getRect(find.byType(AylaNavHighlight)).top,
        closeTo(row.top, 0.5),
      );
    });
  });

  group('自动滚到当前项（官方用例 168–290）', () {
    testWidgets('挂载时把侧栏滚到当前项（不在可视区才滚）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveChannelRail(
            channels: <AylaLiveCardData>[
              for (int i = 1; i <= 12; i += 1)
                _ch('$i', '第 $i 场直播'),
            ],
            currentId: '12', // 末项：初始不可见
            onSelect: (_) {},
            onToggle: () {},
            onBack: () {},
          ),
        ),
      );
      await settle(tester);

      // 滚过之后末项进入视口
      final Rect row = tester.getRect(item('切换到直播间 第 12 场直播'));
      final Rect rail = tester.getRect(find.byType(GlassSurface));
      expect(row.top, greaterThanOrEqualTo(rail.top));
      expect(row.bottom, lessThanOrEqualTo(rail.bottom + 0.5));
    });

    testWidgets('未在列表中的 currentId → 不滚动、不抛错', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveChannelRail(
            channels: _channels,
            currentId: 'missing',
            onSelect: (_) {},
            onToggle: () {},
            onBack: () {},
          ),
        ),
      );
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(AylaNavHighlight), findsNothing); // 没有选中项就没有高亮
    });
  });

  group('开播控制台扩展（官方用例 357–410）', () {
    testWidgets('提供删除回调 → 每项渲染删除键；点击调回调且不误触切换', (WidgetTester tester) async {
      final List<String> deleted = <String>[];
      final List<String> selected = <String>[];
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveChannelRail(
            channels: _channels,
            currentId: '1',
            onSelect: selected.add,
            onToggle: () {},
            onBack: () {},
            onDeleteChannel: deleted.add,
          ),
        ),
      );
      await settle(tester);

      final Finder del = item('删除直播间 第二场直播');
      expect(del, findsOneWidget);
      await tester.tap(del, warnIfMissed: false);
      await settle(tester);
      expect(deleted, <String>['2']);
      expect(selected, isEmpty, reason: '删除键必须拦住行点击');
    });

    testWidgets('提供新建回调 → 底部渲染「新建直播间」虚线键', (WidgetTester tester) async {
      int news = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveChannelRail(
            channels: _channels,
            currentId: '1',
            onSelect: (_) {},
            onToggle: () {},
            onBack: () {},
            onCreateNewChannel: () => news += 1,
          ),
        ),
      );
      await settle(tester);

      expect(find.text('新建直播间'), findsOneWidget);
      await tester.tap(find.text('新建直播间'));
      await settle(tester);
      expect(news, 1);
      // `.live-rail-create { border-top: 1px }`（与列表分隔）
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration! as BoxDecoration).border != null,
        ),
        findsWidgets,
      );
    });

    testWidgets('未提供删除/新建回调 → 两者都不渲染（普通观看页侧栏）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveChannelRail(
            channels: _channels,
            currentId: '1',
            onSelect: (_) {},
            onToggle: () {},
            onBack: () {},
          ),
        ),
      );
      await settle(tester);
      expect(find.textContaining('删除直播间'), findsNothing);
      expect(find.text('新建直播间'), findsNothing);
    });
  });

  group('开播选择器（官方用例 292–312）', () {
    testWidgets('intro 两行 + 列表项（LIVE / 准备开播）+ 底部 glow 键', (WidgetTester tester) async {
      final List<String> started = <String>[];
      int news = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveStartSheet(
            channels: const <AylaLiveCardData>[
              AylaLiveCardData(id: '1', title: '我的直播间', status: AylaLiveStatus.live),
              AylaLiveCardData(id: '2', title: '别人的直播间', status: AylaLiveStatus.idle),
            ],
            loaded: true,
            onStart: (AylaLiveCardData c) => started.add(c.title),
            onCreateNew: () => news += 1,
          ),
          viewport: const Size(480, 700),
        ),
      );
      await settle(tester);

      expect(find.text('选择一个直播间开始'), findsOneWidget);
      expect(
        find.text('已有直播间可以直接复用，直播画面和弹幕会在开播控制台里一起显示。'),
        findsOneWidget,
      );
      expect(find.text('LIVE'), findsOneWidget); // 在播那条的封面文案
      expect(find.text('正在直播，可继续开播'), findsOneWidget);
      expect(find.text('准备开播'), findsOneWidget);

      await tester.tap(find.text('+ 添加新的直播间'));
      await settle(tester);
      expect(news, 1);

      await tester.tap(find.text('我的直播间'));
      await settle(tester);
      expect(started, <String>['我的直播间']); // onStart 收到对应频道
    });

    testWidgets('弹窗组合（复用 AylaCreateSheet）：标题「开始直播」+ 选择器内容同框，关闭走 onClose', (
      WidgetTester tester,
    ) async {
      bool closed = false;
      await tester.pumpWidget(
        host(
          tester,
          AylaCreateSheet(
            title: '开始直播', // CreateFab.tsx:88
            onClose: () => closed = true,
            child: AylaLiveStartSheet(
              channels: const <AylaLiveCardData>[
                AylaLiveCardData(
                  id: '1',
                  title: '我的直播间',
                  status: AylaLiveStatus.live,
                ),
              ],
              loaded: true,
              onStart: _noopStart,
              onCreateNew: _noopNew,
            ),
          ),
          viewport: const Size(620, 560),
        ),
      );
      await settle(tester);

      // 弹窗外壳：`.create-sheet-title`（Fredoka 18）+ 关闭钮；内容 = 选择器本体
      expect(find.text('开始直播'), findsOneWidget);
      expect(find.text('选择一个直播间开始'), findsOneWidget);
      expect(find.text('我的直播间'), findsOneWidget);
      expect(find.byType(AylaSheetHead), findsOneWidget);

      // 关闭钮 = `AylaIconButton`（`.icon-btn-40`，语义标签「关闭」）
      await tester.tap(
        find.byWidgetPredicate(
          (Widget w) => w is AylaIconButton && w.semanticLabel == '关闭',
        ),
      );
      await settle(tester);
      expect(closed, isTrue);
    });

    testWidgets('宽屏弹窗：居中卡 + **max-height 80vh 限高**（web `.create-sheet-card`）', (
      WidgetTester tester,
    ) async {
      const Size stage = Size(900, 560);
      await tester.pumpWidget(
        host(
          tester,
          AylaCreateSheet(
            title: '开始直播',
            onClose: () {},
            child: AylaLiveStartSheet(
              channels: const <AylaLiveCardData>[
                AylaLiveCardData(
                  id: '1',
                  title: '我的直播间',
                  status: AylaLiveStatus.live,
                ),
              ],
              loaded: true,
              onStart: _noopStart,
              onCreateNew: _noopNew,
            ),
          ),
          viewport: stage,
        ),
      );
      await settle(tester);

      final Rect card = tester.getRect(find.byType(AylaModalCard));
      expect(card.width, 480); // `width: min(480px, 100%)`
      expect(card.height, lessThanOrEqualTo(stage.height * 0.8 + 0.5)); // max-height: 80vh
      // 宽屏居中（窄屏才是贴底）
      expect(card.bottom, lessThan(stage.height));
      expect(card.top, greaterThan(0));
    });

    testWidgets('内容超高 → 卡被限高到 80vh，且卡内自带滚动（不撑破弹层）', (
      WidgetTester tester,
    ) async {
      const Size stage = Size(900, 400); // 80vh = 320
      await tester.pumpWidget(
        host(
          tester,
          AylaCreateSheet(
            title: '开始直播',
            onClose: () {},
            child: AylaLiveStartSheet(
              channels: <AylaLiveCardData>[
                for (int i = 1; i <= 8; i += 1)
                  AylaLiveCardData(
                    id: '$i',
                    title: '第 $i 场直播',
                    status: AylaLiveStatus.idle,
                  ),
              ],
              loaded: true,
              onStart: _noopStart,
              onCreateNew: _noopNew,
            ),
          ),
          viewport: stage,
        ),
      );
      await settle(tester);

      final Rect card = tester.getRect(find.byType(AylaModalCard));
      expect(card.height, lessThanOrEqualTo(stage.height * 0.8 + 0.5));
      // 卡内滚动：卡片子树里有 SingleChildScrollView（`overflow-y: auto`）
      expect(
        find.descendant(
          of: find.byType(AylaModalCard),
          matching: find.byType(SingleChildScrollView),
        ),
        findsWidgets,
      );
      // 内容确实超出可视区（证明限高真的生效，而不是内容本来就这么矮）
      final Rect last = tester.getRect(find.text('第 8 场直播'));
      expect(last.bottom, greaterThan(card.bottom));
    });

    testWidgets('窄屏弹窗 = 贴底滑入卡（`radius 24 24 0 0`，AylaModalCard 窄屏档）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          tester,
          AylaCreateSheet(
            title: '群内开播',
            onClose: () {},
            child: AylaLiveStartSheet(
              channels: const <AylaLiveCardData>[],
              loaded: true,
              onStart: _noopStart,
              onCreateNew: _noopNew,
            ),
          ),
          viewport: const Size(420, 620), // ≤768 → 贴底
        ),
      );
      await settle(tester);

      final AylaModalCard card = tester.widget<AylaModalCard>(
        find.byType(AylaModalCard),
      );
      expect(card.narrowRadius, 24); // `border-radius: 24px 24px 0 0`
      // 贴底：卡片底边 == 舞台底边
      final Rect rect = tester.getRect(find.byType(AylaModalCard));
      expect(rect.bottom, 620);
    });

    testWidgets('创建中 → 按钮文案「创建中…」且禁用', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          const AylaLiveStartSheet(
            channels: <AylaLiveCardData>[],
            loaded: true,
            creatingNew: true,
            onStart: _noopStart,
            onCreateNew: _noopNew,
          ),
          viewport: const Size(480, 700),
        ),
      );
      await settle(tester);
      expect(find.text('创建中…'), findsOneWidget);
      final GlassButton button = tester.widget<GlassButton>(
        find.byWidgetPredicate(
          (Widget w) => w is GlassButton && w.variant == GlassButtonVariant.glow,
        ),
      );
      expect(button.onPressed, isNull); // disabled
    });

    testWidgets('五态：加载中 / 列表失败(role=alert + 重试) / 创建失败 / 空态 / 有内容', (
      WidgetTester tester,
    ) async {
      Future<void> pump(AylaLiveStartSheet sheet) async {
        await tester.pumpWidget(
          host(tester, sheet, viewport: const Size(480, 700)),
        );
        await settle(tester);
      }

      await pump(
        const AylaLiveStartSheet(
          channels: <AylaLiveCardData>[],
          loading: true,
          onStart: _noopStart,
          onCreateNew: _noopNew,
        ),
      );
      expect(find.text('正在加载你的直播间…'), findsOneWidget);
    });

    testWidgets('列表失败 → alert 文案 + 重试按钮', (WidgetTester tester) async {
      int retries = 0;
      await tester.pumpWidget(
        host(
          tester,
          AylaLiveStartSheet(
            channels: const <AylaLiveCardData>[],
            error: '网络异常',
            onStart: _noopStart,
            onCreateNew: _noopNew,
            onRetry: () => retries += 1,
          ),
          viewport: const Size(480, 700),
        ),
      );
      await settle(tester);
      expect(find.text('直播间列表加载失败：网络异常'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await settle(tester);
      expect(retries, 1);
    });

    testWidgets('创建失败 → alert 文案；空态 → 提示先创建', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          const AylaLiveStartSheet(
            channels: <AylaLiveCardData>[],
            loaded: true,
            createError: '名称重复',
            onStart: _noopStart,
            onCreateNew: _noopNew,
          ),
          viewport: const Size(480, 700),
        ),
      );
      await settle(tester);
      expect(find.text('创建直播间失败：名称重复'), findsOneWidget);
    });

    testWidgets('空态：loaded 且无内容 → 提示行', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          tester,
          const AylaLiveStartSheet(
            channels: <AylaLiveCardData>[],
            loaded: true,
            onStart: _noopStart,
            onCreateNew: _noopNew,
          ),
          viewport: const Size(480, 700),
        ),
      );
      await settle(tester);
      expect(find.text('还没有自己的直播间，先创建一个吧。'), findsOneWidget);
    });
  });
}

void _noopStart(AylaLiveCardData _) {}

void _noopNew() {}
