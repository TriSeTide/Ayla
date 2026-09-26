/// 公共件定向测试：`AylaNavHighlightList`（共享胶囊高亮列表）与 `AylaSidebarCard`
/// （宽屏侧栏玻璃卡）—— 两者分别是 2026-09-24 从 `AylaDirectoryFilters` 抽出的
/// 高亮机制与侧栏容器（会话列表与目录筛选侧栏**共用同一份实现**）。
///
/// 覆盖：胶囊实测定位与 300ms 迁移 / 按压 `.98` 同步 / 「挂载即命中」扫光直达 /
/// 键盘（方向键改选中、Home/End、wrap、`selectOnKeyNav: false`）/ 滚动揭示 /
/// 侧栏卡宽度权威（紧宿主不被夹回）+ 材质 + 入场。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/nav_highlight_list.dart';
import '../lib/widgets/base/primitives.dart' show AylaNavHighlight, AylaNavHighlightState;
import '../lib/widgets/base/reveal.dart';
import '../lib/widgets/base/sidebar_card.dart';

/// 简项：固定 40 高、带 hover/press 上报与键盘。
class _Item extends StatefulWidget {
  const _Item({required this.slot, required this.label});

  final AylaNavHighlightSlot slot;
  final String label;

  @override
  State<_Item> createState() => _ItemState();
}

class _ItemState extends State<_Item> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AylaNavHighlightSlot slot = widget.slot;
    return Focus(
      focusNode: slot.focusNode,
      onKeyEvent: slot.onKey,
      child: Listener(
        onPointerDown: (_) => slot.onPressedChanged(true),
        onPointerUp: (_) => slot.onPressedChanged(false),
        onPointerCancel: (_) => slot.onPressedChanged(false),
        child: MouseRegion(
          onEnter: (_) {
            setState(() => _hovered = true);
            slot.onHoverChanged(true);
            if (slot.active) slot.onSweep(true);
          },
          onExit: (_) {
            setState(() => _hovered = false);
            slot.onHoverChanged(false);
            if (slot.active) slot.onSweep(false);
          },
          child: GestureDetector(
            onTap: slot.onTap,
            child: Container(
              height: 40,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              // 选中项**自身底透明**（底归胶囊，auroraqua 194–197）
              color: slot.active
                  ? null
                  : (_hovered ? const Color(0x2E9DBFE6) : null),
              child: Text(widget.label),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget host(
    WidgetTester tester,
    Widget child, {
    Size viewport = const Size(280, 400),
  }) {
    setViewport(tester, viewport);
    return MaterialApp(
      home: previewTheme(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 224, child: child),
            ),
          ),
        ),
      ),
    );
  }

  // ======================= 胶囊定位与迁移 =======================

  testWidgets('胶囊 = 选中项实测矩形；切换后 300ms 迁移到新项', (WidgetTester tester) async {
    int selected = 0;
    late StateSetter setLocal;
    await tester.pumpWidget(
      host(
        tester,
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setter) {
            setLocal = setter;
            return AylaNavHighlightList(
              itemCount: 3,
              selectedIndex: selected,
              gap: 8,
              onSelect: (int i) => setLocal(() => selected = i),
              itemBuilder: (BuildContext ctx, AylaNavHighlightSlot slot) =>
                  _Item(slot: slot, label: '项${slot.index}'),
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50)); // 等 postFrame 测量

    final Rect first = tester.getRect(find.byType(AylaNavHighlight));
    final Rect item0 = tester.getRect(find.byType(_Item).at(0));
    expect(first.top, moreOrLessEquals(item0.top, epsilon: 0.5), reason: '胶囊贴槽位顶');
    expect(first.height, moreOrLessEquals(40, epsilon: 0.5));
    expect(first.width, moreOrLessEquals(224, epsilon: 0.5));

    // 切换 → 迁移（didUpdateWidget 当帧重测，不白等一帧）
    setLocal(() => selected = 2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final Rect third = tester.getRect(find.byType(AylaNavHighlight));
    expect(third.top, moreOrLessEquals(2 * (40 + 8), epsilon: 0.5));
    expect(third.top, greaterThan(first.top));
  });

  testWidgets('点击非选中项 → 「挂载即命中」扫光直达终点（jump）', (WidgetTester tester) async {
    int selected = 0;
    late StateSetter setLocal;
    await tester.pumpWidget(
      host(
        tester,
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setter) {
            setLocal = setter;
            return AylaNavHighlightList(
              itemCount: 3,
              selectedIndex: selected,
              onSelect: (int i) => setLocal(() => selected = i),
              itemBuilder: (BuildContext ctx, AylaNavHighlightSlot slot) =>
                  _Item(slot: slot, label: '项${slot.index}'),
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final AylaNavHighlightState state =
        tester.state<AylaNavHighlightState>(find.byType(AylaNavHighlight));
    expect(state.sweepProgress, lessThanOrEqualTo(1.0));

    await tester.tap(find.text('项1'));
    await tester.pump();
    expect(state.sweepProgress, 1.0, reason: '点击命中项 → 进度直接置到终点（不重播从左往右）');
  });

  testWidgets('按压选中项 → 胶囊同步 scale .98（web 的胶囊是按钮子元素）', (WidgetTester tester) async {
    await tester.pumpWidget(
      host(
        tester,
        AylaNavHighlightList(
          itemCount: 2,
          selectedIndex: 0,
          itemBuilder: (BuildContext ctx, AylaNavHighlightSlot slot) =>
              _Item(slot: slot, label: '项${slot.index}'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    double scaleNow() =>
        tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;
    expect(scaleNow(), 1.0);

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.text('项0')),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(scaleNow(), 0.98, reason: '按压选中项 → 胶囊 .98（时长/曲线与按钮组一致）');
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));
    expect(scaleNow(), 1.0);
  });

  // ======================= 键盘 =======================

  testWidgets('键盘：方向键改选中并循环；Home/End 跳首末', (WidgetTester tester) async {
    int selected = 0;
    late StateSetter setLocal;
    await tester.pumpWidget(
      host(
        tester,
        StatefulBuilder(
          builder: (BuildContext context, StateSetter setter) {
            setLocal = setter;
            return AylaNavHighlightList(
              itemCount: 3,
              selectedIndex: selected,
              onSelect: (int i) => setLocal(() => selected = i),
              itemBuilder: (BuildContext ctx, AylaNavHighlightSlot slot) =>
                  _Item(slot: slot, label: '项${slot.index}'),
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 聚焦首项（键盘事件需要焦点在列表内）
    await tester.tap(find.text('项0'));
    await tester.pump();
    final FocusNode node = tester
        .widget<Focus>(find.ancestor(
          of: find.text('项0'),
          matching: find.byType(Focus),
        ).first)
        .focusNode!;
    node.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(selected, 1, reason: '方向键同时改变选中（tsx onKeyDown）');

    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pump();
    expect(selected, 2);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(selected, 0, reason: '循环回首个');
  });

  testWidgets('selectOnKeyNav: false → 只挪焦点、不改选中', (WidgetTester tester) async {
    int selectedCalls = 0;
    await tester.pumpWidget(
      host(
        tester,
        AylaNavHighlightList(
          itemCount: 3,
          selectedIndex: 0,
          selectOnKeyNav: false,
          onSelect: (_) => selectedCalls++,
          itemBuilder: (BuildContext ctx, AylaNavHighlightSlot slot) =>
              _Item(slot: slot, label: '项${slot.index}'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final FocusNode node = tester
        .widget<Focus>(find.ancestor(
          of: find.text('项0'),
          matching: find.byType(Focus),
        ).first)
        .focusNode!;
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(selectedCalls, 0, reason: '只挪焦点（会话列表等以点击选择为主）');
  });

  // ======================= 滚动揭示 =======================

  testWidgets('滚动揭示：聚焦视口外的项只滚动本列表', (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      host(
        tester,
        SizedBox(
          height: 120, // 只容 2 项多 ⇒ 第 8 项在视口外
          child: SingleChildScrollView(
            controller: controller,
            child: AylaNavHighlightList(
              itemCount: 10,
              selectedIndex: 8,
              scrollController: controller,
              itemBuilder: (BuildContext ctx, AylaNavHighlightSlot slot) =>
                  _Item(slot: slot, label: '项${slot.index}'),
            ),
          ),
        ),
        viewport: const Size(280, 400),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // 聚焦视口外的项 → 公共件的 FocusNode listener 触发滚动揭示
    final FocusNode node = tester
        .widget<Focus>(find.ancestor(
          of: find.text('项8'),
          matching: find.byType(Focus),
        ).first)
        .focusNode!;
    node.requestFocus();
    await tester.pump(const Duration(milliseconds: 50));
    expect(controller.offset, greaterThan(0), reason: '选中项在视口外 → 滚入（scroll-padding sp3 补偿）');
  });

  // ======================= 侧栏卡 =======================

  group('AylaSidebarCard', () {
    testWidgets('宽度权威：紧宿主下仍是 224（不被 constraints.enforce 夹回）', (WidgetTester tester) async {
      setViewport(tester, const Size(600, 400));
      await tester.pumpWidget(
        MaterialApp(
          home: previewTheme(
            Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 600, // 紧宽宿主
                height: 400,
                child: AylaSidebarCard(
                  width: 224,
                  enter: false,
                  child: const Text('内容'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      // 量**卡片本体**（`AylaGlassSurface`），不是外层的 `UnconstrainedBox` ——
      // 后者自身会被紧宿主 clamp 到宿主宽（同「槽位宽度 ≠ 可见胶囊宽度」，skill §五）
      expect(
        tester.getSize(find.byType(AylaGlassSurface)).width,
        224,
        reason: '内部用 UnconstrainedBox 松横向紧约束（live_rail 先例）',
      );
    });

    testWidgets('材质与入场：AylaGlassSurface 圆角 16 + 阴影档可配 + 入场件默认存在', (
      WidgetTester tester,
    ) async {
      setViewport(tester, const Size(400, 400));
      await tester.pumpWidget(
        MaterialApp(
          home: previewTheme(
            Align(
              alignment: Alignment.topLeft,
              child: AylaSidebarCard(
                width: 224,
                shadow: AylaShadows.compact,
                child: const Text('内容'),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      final AylaGlassSurface surface = tester.widget<AylaGlassSurface>(
        find.byType(AylaGlassSurface),
      );
      expect(surface.radius, AylaRadii.rCard, reason: 'border-radius: var(--radius-card)');
      expect(surface.shadow, AylaShadows.compact, reason: '`.directory-filters` 用 compact 阴影');
      expect(find.byType(AylaRevealItem), findsOneWidget, reason: 'auroraqua-sidebar-in 入场');
    });
  });
}
