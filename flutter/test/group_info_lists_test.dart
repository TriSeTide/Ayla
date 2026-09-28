/// 群信息「右列两卡 + 两列布局」三件定向测试 —— 对照 group.css
/// 1421–1459 / 1461–1465 / 1690–1732 / 1752–1787 / 2062–2128 与
/// GroupInfo.tsx 670–790 / 1012–1018。
///
/// ⚠️ 一态一用例（同用例内二次 pumpWidget 换 props 不生效，收尾轮实测）。
/// ⚠️ 宽档几何断言先 setSurfaceSize（flutter_test 默认表面 800×600）。
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/avatar_halo.dart';
import '../lib/widgets/base/loading.dart';
import '../lib/widgets/base/tab_badge.dart';
import '../lib/widgets/group/group_info_lists.dart';
import '../lib/widgets/group/group_role_chip.dart';

void main() {
  /// 宿主：预览三件套（主题 + 极光背景 + ProviderScope）+ 受控宽度 / 视口。
  ///
  /// [width] 是**组件的可用宽**（SizedBox）；[viewport] 是断点判据用的视口宽
  /// （MediaQuery）——两者在真实页面里并不相等（页面左右 rails + padding 会吃掉宽度）。
  Widget host(Widget child, {double? width, required double viewport}) {
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            // ⚠️ 视口用 viewport（断点判据 = MediaQuery），组件可用宽另由 width 给
            data: MediaQuery.of(context).copyWith(
              size: Size(viewport, 1600),
            ),
            child: Align(
              alignment: Alignment.topLeft,
              child: width == null
                  ? child
                  : SizedBox(width: width, child: child),
            ),
          ),
        ),
      ),
    );
  }

  /// 表面尺寸（宽档几何必须先设：默认 800×600 会把宽样张卡到 800）。
  Future<void> useSurface(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  /// 真实语义树里的全部可访问名。
  ///
  /// ⚠️ 不用 `find.bySemanticsLabel`：它要求某个 RenderObject 的 label **精确等于**目标，
  /// 而库内复用件（如 AylaAvatarHalo 会把「，在线」拼进 label）与默认合并行为都会让
  /// 精确匹配落空 ⇒ 遍历整棵树取集合、用 contains 断言更稳（同 voice_member_row_test 口径）。
  Set<String> semanticsLabels(WidgetTester tester) {
    // ignore: deprecated_member_use
    final SemanticsOwner? owner = tester.binding.pipelineOwner.semanticsOwner;
    final Set<String> out = <String>{};
    void walk(SemanticsNode node) {
      if (node.label.isNotEmpty) out.add(node.label);
      node.visitChildren((SemanticsNode child) {
        walk(child);
        return true;
      });
    }

    final SemanticsNode? root = owner?.rootSemanticsNode;
    if (root != null) walk(root);
    return out;
  }

  /// 语义名里是否**包含**该片段。
  ///
  /// ⚠️ 库内公共件（AylaGlassButton / AylaAvatarHalo）的 label 会与子文本**合并**成同一节点
  /// （实测：「添加子群\n添加子群」；头像行：「查看 X 的个人主页，在线\n汐\n汐汐\n我」）
  /// ⇒ 精确相等断言必落空，按片段包含判定。
  bool hasSemantics(WidgetTester tester, String needle) => semanticsLabels(
    tester,
  ).any((String label) => label.contains(needle));

  /// 行内 AnimatedContainer（行的底/几何都挂在它上面）。
  Finder rowBox(String key) => find
      .descendant(
        of: find.byKey(ValueKey<String>(key)),
        matching: find.byType(AnimatedContainer),
      )
      .first;

  // ═════════════════ ① AylaGroupInfoLayout ═════════════════

  group('AylaGroupInfoLayout', () {
    testWidgets('宽档 1400：左列 340（clamp 上限）· 右列 1044（− 左列 − gap sp4）· 列内 gap sp4', (
      WidgetTester tester,
    ) async {
      await useSurface(tester, const Size(1440, 1200));
      await tester.pumpWidget(
        host(
          const AylaGroupInfoLayout(
            side: <Widget>[SizedBox(height: 40)],
            main: <Widget>[SizedBox(height: 40)],
          ),
          width: 1400,
          viewport: 1440,
        ),
      );
      await tester.pumpAndSettle();

      final Finder sideKey = find.byKey(AylaGroupInfoLayout.sideKey);
      final Finder mainKey = find.byKey(AylaGroupInfoLayout.mainKey);
      expect(tester.getSize(sideKey).width, moreOrLessEquals(340, epsilon: 0.01));
      expect(
        tester.getSize(mainKey).width,
        moreOrLessEquals(1400 - 340 - AylaSpacing.sp4, epsilon: 0.01),
      );
      final Rect s = tester.getRect(sideKey);
      final Rect m = tester.getRect(mainKey);
      expect(m.left - s.right, moreOrLessEquals(AylaSpacing.sp4, epsilon: 0.01));
      expect(s.top, moreOrLessEquals(m.top, epsilon: 0.01)); // align-items: start
      // 1447：≥769 两列各自 gap sp4
      final Column col = tester.widget<Column>(
        find.descendant(of: sideKey, matching: find.byType(Column)).first,
      );
      expect(col.spacing, AylaSpacing.sp4);
    });

    testWidgets('中档 1010：左列 = 32% × 可用宽（323.2）· 右列 670.8', (
      WidgetTester tester,
    ) async {
      await useSurface(tester, const Size(1440, 1200));
      await tester.pumpWidget(
        host(
          const AylaGroupInfoLayout(
            side: <Widget>[SizedBox(height: 40)],
            main: <Widget>[SizedBox(height: 40)],
          ),
          width: 1010,
          viewport: 1440,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byKey(AylaGroupInfoLayout.sideKey)).width,
        moreOrLessEquals(1010 * 0.32, epsilon: 0.01),
      );
      expect(
        tester.getSize(find.byKey(AylaGroupInfoLayout.mainKey)).width,
        moreOrLessEquals(1010 - 1010 * 0.32 - AylaSpacing.sp4, epsilon: 0.01),
      );
    });

    testWidgets('窄档 800：左列 280（clamp 下限——32% 只有 256）', (
      WidgetTester tester,
    ) async {
      await useSurface(tester, const Size(1440, 1200));
      await tester.pumpWidget(
        host(
          const AylaGroupInfoLayout(
            side: <Widget>[SizedBox(height: 40)],
            main: <Widget>[SizedBox(height: 40)],
          ),
          width: 800,
          viewport: 1440,
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.getSize(find.byKey(AylaGroupInfoLayout.sideKey)).width, 280);
      expect(
        tester.getSize(find.byKey(AylaGroupInfoLayout.mainKey)).width,
        moreOrLessEquals(800 - 280 - AylaSpacing.sp4, epsilon: 0.01),
      );
    });

    testWidgets('769–1000 视口退回单列（1455–1459）：两列同宽 900 上下排列 · 网格 gap sp3', (
      WidgetTester tester,
    ) async {
      await useSurface(tester, const Size(900, 1200));
      await tester.pumpWidget(
        host(
          const AylaGroupInfoLayout(
            side: <Widget>[SizedBox(height: 40)],
            main: <Widget>[SizedBox(height: 40)],
          ),
          width: 900,
          viewport: 900,
        ),
      );
      await tester.pumpAndSettle();

      final Finder sideKey = find.byKey(AylaGroupInfoLayout.sideKey);
      final Finder mainKey = find.byKey(AylaGroupInfoLayout.mainKey);
      final Rect s = tester.getRect(sideKey);
      final Rect m = tester.getRect(mainKey);
      expect(s.width, moreOrLessEquals(900, epsilon: 0.01));
      expect(m.width, moreOrLessEquals(900, epsilon: 0.01));
      expect(m.top, moreOrLessEquals(s.bottom + AylaSpacing.sp3, epsilon: 0.01));
      final Column col = tester.widget<Column>(
        find.descendant(of: sideKey, matching: find.byType(Column)).first,
      );
      expect(col.spacing, AylaSpacing.sp3); // 1433：单列档列内 gap sp3
    });

    testWidgets('窄屏 375 视口：单列 + 主列容器宽 = 单列宽（供 @container 判据）', (
      WidgetTester tester,
    ) async {
      await useSurface(tester, const Size(375, 1200));
      await tester.pumpWidget(
        host(
          const AylaGroupInfoLayout(
            side: <Widget>[SizedBox(height: 40)],
            main: <Widget>[
              AylaGroupMemberList(
                members: <AylaGroupMemberItem>[
                  AylaGroupMemberItem(id: 'u-1', name: '爱莉'),
                ],
                canManage: true,
                isOwner: true,
              ),
            ],
          ),
          width: 375,
          viewport: 375,
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.getSize(find.byKey(AylaGroupInfoLayout.sideKey)).width, 375);
      expect(
        tester.getSize(find.byKey(AylaGroupInfoLayout.mainKey)).width,
        moreOrLessEquals(375, epsilon: 0.01),
      );
      // 宿主把**主列容器宽**下发（= 375 ≤ 420）⇒ 换行档 + 常显；
      // 窄屏（≤768）头像 36 ⇒ 行高 = (36 + sp2×2) + 行距 sp3 + 操作区 30
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(AylaGroupMemberList.actionsKey('u-1')),
            )
            .opacity,
        1,
      );
      const double avatar = 36 + AylaAvatarHalo.haloWidth * 2; // 本体 + 2.5px 光环
      expect(
        tester.getSize(find.byKey(AylaGroupMemberList.rowKey('u-1'))).height,
        moreOrLessEquals(
          avatar + AylaSpacing.sp2 * 2 + AylaSpacing.sp3 + 30,
          epsilon: 0.5,
        ),
      );
    });

    testWidgets('loading 档：padding sp4 + 三个 height 64 骨架（前两块 margin-bottom 8）· 不渲染两列', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AylaGroupInfoLayout(loading: true),
          width: 420,
          viewport: 375,
        ),
      );
      // 骨架的 frost-pulse 是无限动画 ⇒ 不能 pumpAndSettle
      await tester.pump();

      expect(find.byKey(AylaGroupInfoLayout.sideKey), findsNothing);
      expect(find.byKey(AylaGroupInfoLayout.mainKey), findsNothing);
      final Padding box = tester.widget<Padding>(
        find.byKey(AylaGroupInfoLayout.loadingKey),
      );
      expect(box.padding, const EdgeInsets.all(AylaSpacing.sp4));
      expect(
        tester.getSize(find.byKey(AylaGroupInfoLayout.loadingKey)).height,
        moreOrLessEquals(AylaSpacing.sp4 * 2 + 64 * 3 + AylaSpacing.sp2 * 2, epsilon: 0.01),
      );
      final List<AylaSkeleton> bones = tester
          .widgetList<AylaSkeleton>(find.byType(AylaSkeleton))
          .toList();
      expect(bones.length, 3);
      expect(bones.every((AylaSkeleton b) => b.height == 64), isTrue);
      final List<Padding> pads = tester
          .widgetList<Padding>(
            find.descendant(
              of: find.byKey(AylaGroupInfoLayout.loadingKey),
              matching: find.byType(Padding),
            ),
          )
          .toList();
      expect(
        pads
            .where(
              (Padding p) =>
                  p.padding == const EdgeInsets.only(bottom: AylaSpacing.sp2),
            )
            .length,
        2,
      );
    });
  });

  // ═════════════════ ② AylaGroupSubgroupList ═════════════════

  group('AylaGroupSubgroupList', () {
    testWidgets('默认组 chip：文案「默认组」+ owner 档色（sakura-300 底 / grape-700 字 / pill / 1px 8px）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AylaGroupSubgroupList(
            subgroups: <AylaGroupSubgroupItem>[
              AylaGroupSubgroupItem(id: 'all', name: '大厅', isDefault: true),
            ],
          ),
          width: 420,
          viewport: 420,
        ),
      );
      await tester.pumpAndSettle();

      final Text chip = tester.widget<Text>(find.text('默认组'));
      expect(chip.style!.fontSize, 11); // 1739
      expect(chip.style!.color, AylaColors.grape700); // 1744
      // ⚠️ **复用件的既有偏离**：group_role_chip.dart:56 用 t.timestamp（Space Grotesk），
      // 而 web .group-info-role 是 font-family: var(--font-display) = Fredoka（group.css 1738）。
      // 本件被指定复用 AylaGroupRoleChip（跨组件改动须先经用户裁决）⇒ 这里如实按现状断言，
      // 偏离已登记在文件头「有意偏离」与被交付报告里。
      expect(chip.style!.fontFamily, AylaFonts.utility);
      expect(chip.style!.fontFamily, isNot(AylaFonts.display));
      final Container box = tester.widget<Container>(
        find
            .ancestor(of: find.text('默认组'), matching: find.byType(Container))
            .first,
      );
      final BoxDecoration deco = box.decoration! as BoxDecoration;
      expect(deco.color, AylaColors.sakura300); // 1743
      expect(deco.borderRadius, AylaRadii.pill);
      expect(box.padding, const EdgeInsets.symmetric(horizontal: 8, vertical: 1));
      // 复用件身份：确实是 AylaGroupRoleChip(owner, label: 默认组)
      final AylaGroupRoleChip role = tester.widget<AylaGroupRoleChip>(
        find.byType(AylaGroupRoleChip),
      );
      expect(role.role, AylaGroupRole.owner);
      expect(role.label, '默认组');
    });

    testWidgets('禁言 chip：11 w700 textSecondary（2062）+ ice-300 底 / pill / 1px 6px（318）+ title 提示', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AylaGroupSubgroupList(
            subgroups: <AylaGroupSubgroupItem>[
              AylaGroupSubgroupItem(id: 'sg-2', name: '深夜电台', muted: true),
            ],
          ),
          width: 420,
          viewport: 420,
        ),
      );
      await tester.pumpAndSettle();

      final Text chip = tester.widget<Text>(find.text('禁言'));
      expect(chip.style!.fontSize, 11); // 2064
      expect(chip.style!.fontWeight, FontWeight.w700); // 2065
      expect(chip.style!.color, AylaColors.textSecondary); // 2066
      expect(chip.style!.fontFamily, AylaFonts.display); // 318–331（未被 2062 覆写）
      expect(chip.style!.height, 1.4); // line-height: 1.4
      final Container box = tester.widget<Container>(
        find
            .ancestor(of: find.text('禁言'), matching: find.byType(Container))
            .first,
      );
      final BoxDecoration deco = box.decoration! as BoxDecoration;
      expect(deco.color, AylaColors.ice300); // 318–331 的灰底**仍然生效**
      expect(deco.borderRadius, AylaRadii.pill);
      expect(box.padding, const EdgeInsets.symmetric(horizontal: 6, vertical: 1));
      expect(find.byTooltip('已禁言（仅群主/管理员可发言）'), findsOneWidget);
    });

    testWidgets('未读徽标：120 ⇒「99+」· aria-label「120 条未读」· 3 ⇒「3」· 复用 serverItem 档', (
      WidgetTester tester,
    ) async {
      // ⚠️ 必须**显式** dispose：句柄未释放的校验跑在 addTearDown 之前（收尾轮实测）
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(
          const AylaGroupSubgroupList(
            subgroups: <AylaGroupSubgroupItem>[
              AylaGroupSubgroupItem(id: 'sg-3', name: '星海观测站', unread: 120),
              AylaGroupSubgroupItem(id: 'sg-4', name: '深夜电台', unread: 3),
            ],
          ),
          width: 420,
          viewport: 420,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('99+'), findsOneWidget); // >99 截断（tsx 688）
      expect(find.text('3'), findsOneWidget);
      // aria-label「{n} 条未读」用**原始**计数（与可见「99+」不同）
      final Set<String> labels = semanticsLabels(tester);
      expect(
        labels,
        contains('120 条未读'),
        reason: '实际语义名：${labels.join(' / ')}',
      );
      expect(
        labels,
        contains('3 条未读'),
        reason: '实际语义名：${labels.join(' / ')}',
      );
      final AylaTabBadge badge = tester.widget<AylaTabBadge>(
        find.byType(AylaTabBadge).first,
      );
      expect(badge.metrics, AylaTabBadgeMetrics.serverItem); // 逐条同值 ⇒ 不新造档
      expect(badge.max, 99);
      expect(badge.placement, AylaTabBadgePlacement.inline);
      expect(
        tester.getSize(find.byType(AylaTabBadge).first).height,
        moreOrLessEquals(16, epsilon: 0.01), // height: 16px
      );
      handle.dispose();
    });

    testWidgets('行几何：padding sp2 sp3 + radius-input + hover 底 rgba(157,191,230,.14)', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AylaGroupSubgroupList(
            subgroups: <AylaGroupSubgroupItem>[
              AylaGroupSubgroupItem(id: 'sg-1', name: '星海观测站'),
            ],
          ),
          width: 420,
          viewport: 420,
        ),
      );
      await tester.pumpAndSettle();

      final Finder box = rowBox('ayla-group-subgroup-sg-1');
      BoxDecoration deco() =>
          tester.widget<AnimatedContainer>(box).decoration! as BoxDecoration;
      final AnimatedContainer container = tester.widget<AnimatedContainer>(box);
      expect(
        container.padding,
        const EdgeInsets.symmetric(
          horizontal: AylaSpacing.sp3,
          vertical: AylaSpacing.sp2,
        ),
      );
      expect(deco().borderRadius, BorderRadius.circular(AylaRadii.rInput));
      expect(deco().color, Colors.transparent); // 静息无背景

      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: const Offset(700, 560)); // 宿主之外起手
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(box));
      await tester.pumpAndSettle();
      expect(deco().color, AylaColors.ice500.withValues(alpha: 0.14)); // 1709
    });

    testWidgets('编辑键：32×32 + 铅笔 glyph 14 + aria-label「编辑子群 {名}」+ title「编辑子群」', (
      WidgetTester tester,
    ) async {
      // ⚠️ 必须**显式** dispose：句柄未释放的校验跑在 addTearDown 之前（收尾轮实测）
      final SemanticsHandle handle = tester.ensureSemantics();
      String? edited;
      await tester.pumpWidget(
        host(
          AylaGroupSubgroupList(
            subgroups: const <AylaGroupSubgroupItem>[
              AylaGroupSubgroupItem(id: 'sg-1', name: '星海观测站'),
            ],
            canManage: true,
            editing: true,
            onEdit: (AylaGroupSubgroupItem sg) => edited = sg.name,
          ),
          width: 420,
          viewport: 420,
        ),
      );
      await tester.pumpAndSettle();

      final Finder btn = find.byKey(
        AylaGroupSubgroupList.editButtonKey('sg-1'),
      );
      expect(tester.getSize(btn), const Size(32, 32)); // width/height: 32px
      expect(
        find.descendant(
          of: btn,
          matching: find.byWidgetPredicate(
            (Widget w) => w is CustomPaint && w.size == const Size(14, 14),
          ),
        ),
        findsOneWidget, // <svg width="14" height="14">
      );
      expect(find.byTooltip('编辑子群'), findsOneWidget);
      final Set<String> labels = semanticsLabels(tester);
      expect(
        labels,
        contains('编辑子群 星海观测站'),
        reason: '实际语义名：${labels.join(' / ')}',
      );
      await tester.tap(btn);
      await tester.pump();
      expect(edited, '星海观测站');
      // 编辑键在行尾（右侧）而不是行首
      expect(
        tester.getRect(btn).left,
        greaterThan(tester.getRect(find.text('星海观测站')).right),
      );
      handle.dispose();
    });

    testWidgets('编辑键条件：canManage 与 editing 缺一不渲染（GroupInfo.tsx:691）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AylaGroupSubgroupList(
            subgroups: <AylaGroupSubgroupItem>[
              AylaGroupSubgroupItem(id: 'sg-1', name: '星海观测站'),
            ],
            canManage: true,
            // editing 默认 false
          ),
          width: 420,
          viewport: 420,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(AylaGroupSubgroupList.editButtonKey('sg-1')),
        findsNothing,
      );
      expect(find.byKey(AylaGroupSubgroupList.editActionsKey), findsNothing);
    });

    testWidgets('编辑态两键：flex 1 等宽 + min-h 36 + 13px + primary 带 IconPlus + aria-label 两档', (
      WidgetTester tester,
    ) async {
      // ⚠️ 必须**显式** dispose：句柄未释放的校验跑在 addTearDown 之前（收尾轮实测）
      final SemanticsHandle handle = tester.ensureSemantics();
      int added = 0;
      int done = 0;
      await tester.pumpWidget(
        host(
          AylaGroupSubgroupList(
            subgroups: const <AylaGroupSubgroupItem>[
              AylaGroupSubgroupItem(id: 'sg-1', name: '星海观测站'),
            ],
            canManage: true,
            editing: true,
            onAdd: () => added++,
            onDone: () => done++,
          ),
          width: 420,
          viewport: 420,
        ),
      );
      await tester.pumpAndSettle();

      final Finder actions = find.byKey(AylaGroupSubgroupList.editActionsKey);
      expect(actions, findsOneWidget);
      final Finder add = find.widgetWithText(AylaGlassButton, '添加子群');
      final Finder finish = find.widgetWithText(AylaGlassButton, '完成');
      final AylaGlassButton addBtn = tester.widget<AylaGlassButton>(add);
      final AylaGlassButton doneBtn = tester.widget<AylaGlassButton>(finish);
      expect(addBtn.minHeight, 36); // 2126
      expect(addBtn.fontSize, 13); // 2127
      expect(addBtn.variant, AylaGlassButtonVariant.primary);
      expect(addBtn.icon, isNotNull); // <IconPlus width={16} height={16} />
      expect(doneBtn.variant, AylaGlassButtonVariant.ghost);
      expect(doneBtn.minHeight, 36);
      // flex 1 ⇒ 两键等宽（卡内 420 − gap sp2 = 412 ⇒ 206 / 206）
      expect(tester.getSize(add).width, moreOrLessEquals(206, epsilon: 0.5));
      expect(tester.getSize(finish).width, moreOrLessEquals(206, epsilon: 0.5));
      expect(tester.getSize(actions).height, moreOrLessEquals(36, epsilon: 0.5));
      // aria-label 两档（GroupInfo.tsx:731 / 739）
      expect(addBtn.semanticLabel, '添加子群');
      expect(doneBtn.semanticLabel, '完成子群编辑');
      expect(
        hasSemantics(tester, '添加子群'),
        isTrue,
        reason: '实际语义名：${semanticsLabels(tester).join(' / ')}',
      );
      expect(
        hasSemantics(tester, '完成子群编辑'),
        isTrue,
        reason: '实际语义名：${semanticsLabels(tester).join(' / ')}',
      );
      await tester.tap(add);
      await tester.tap(finish);
      await tester.pump();
      expect(added, 1);
      expect(done, 1);
      handle.dispose();
    });

    testWidgets('空态一档 loading：「加载中…」（13 / text-secondary）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AylaGroupSubgroupList(
            subgroups: <AylaGroupSubgroupItem>[],
            loading: true,
          ),
          width: 420,
          viewport: 420,
        ),
      );
      await tester.pumpAndSettle();
      final Text text = tester.widget<Text>(
        find.byKey(AylaGroupSubgroupList.placeholderKey),
      );
      expect(text.data, '加载中…'); // GroupInfo.tsx:671 逐字
      expect(text.style!.fontSize, 13); // 1685
      expect(text.style!.color, AylaColors.textSecondary); // 1686
    });

    testWidgets('空态二档 error：「子群加载失败」', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaGroupSubgroupList(
            subgroups: <AylaGroupSubgroupItem>[],
            error: true,
          ),
          width: 420,
          viewport: 420,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(AylaGroupSubgroupList.placeholderKey))
            .data,
        '子群加载失败',
      );
    });

    testWidgets('空态三档默认：「暂无子群」· 且编辑态两键在空列表时仍渲染（tsx 722 在三元之外）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AylaGroupSubgroupList(
            subgroups: <AylaGroupSubgroupItem>[],
            canManage: true,
            editing: true,
          ),
          width: 420,
          viewport: 420,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(AylaGroupSubgroupList.placeholderKey))
            .data,
        '暂无子群',
      );
      expect(find.byKey(AylaGroupSubgroupList.editActionsKey), findsOneWidget);
      expect(find.text('添加子群'), findsOneWidget);
    });
  });

  // ═════════════════ ③ AylaGroupMemberList ═════════════════

  const List<AylaGroupMemberItem> trio = <AylaGroupMemberItem>[
    AylaGroupMemberItem(id: 'u-self', name: '汐汐', online: true, isSelf: true),
    AylaGroupMemberItem(
      id: 'u-owner',
      name: '爱莉',
      online: true,
      role: AylaGroupRole.owner,
    ),
    AylaGroupMemberItem(
      id: 'u-admin',
      name: '管理员小樱',
      online: true,
      role: AylaGroupRole.admin,
    ),
  ];

  group('AylaGroupMemberList', () {
    testWidgets('成员行：「我」chip（sakura-300 @28% / grape-700 / 11）+ 角色 chip 两档 + 名字 14/w600 省略', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AylaGroupMemberList(members: trio),
          width: 420,
          viewport: 1440,
        ),
      );
      await tester.pumpAndSettle();

      // 「我」chip（1724–1732）
      final Text me = tester.widget<Text>(find.text('我'));
      expect(me.style!.fontSize, 11);
      expect(me.style!.color, AylaColors.grape700); // --grape-700
      expect(me.style!.fontFamily, AylaFonts.display);
      final Container meBox = tester.widget<Container>(
        find.ancestor(of: find.text('我'), matching: find.byType(Container)).first,
      );
      expect(
        (meBox.decoration! as BoxDecoration).color,
        AylaColors.sakura300.withValues(alpha: 0.28), // rgba(249,176,255,.28)
      );
      expect(meBox.padding, const EdgeInsets.symmetric(horizontal: 8, vertical: 1));

      // 角色 chip：owner / admin 出，member 不出（AylaGroupRoleChip 自带 member ⇒ shrink）
      expect(find.text('群主'), findsOneWidget);
      expect(find.text('管理员'), findsOneWidget);
      expect(find.byType(AylaGroupRoleChip), findsNWidgets(2));

      // 名字（1712–1722）
      final Text name = tester.widget<Text>(find.text('汐汐'));
      expect(name.style!.fontSize, 14);
      expect(name.style!.fontWeight, FontWeight.w600);
      expect(name.style!.color, AylaColors.textPrimary);
      expect(name.maxLines, 1);
      expect(name.overflow, TextOverflow.ellipsis);
      expect(find.byTooltip('汐汐'), findsOneWidget); // tsx 769 的 title
    });

    testWidgets('头像：宽屏 40 + 语义「查看 {名} 的个人主页」+ 在线态透传', (
      WidgetTester tester,
    ) async {
      // ⚠️ 必须**显式** dispose：句柄未释放的校验跑在 addTearDown 之前（收尾轮实测）
      final SemanticsHandle handle = tester.ensureSemantics();
      final List<String> opened = <String>[];
      await tester.pumpWidget(
        host(
          AylaGroupMemberList(
            members: trio,
            onOpenProfile: (AylaGroupMemberItem m) => opened.add(m.id),
          ),
          width: 420,
          viewport: 1440,
        ),
      );
      await tester.pumpAndSettle();

      final AylaAvatarHalo avatar = tester.widget<AylaAvatarHalo>(
        find.byType(AylaAvatarHalo).first,
      );
      expect(avatar.size, 40); // isNarrow ? 36 : 40
      expect(avatar.online, isTrue);
      expect(avatar.semanticLabel, '查看 汐汐 的个人主页'); // 调用点传 web 的 ariaLabel
      // ⚠️ 复用件的语义名是「{semanticLabel}，{在线|离线}」（avatar_halo.dart:310–316 双通道）
      expect(
        hasSemantics(tester, '查看 汐汐 的个人主页，在线'),
        isTrue,
        reason: '实际语义名：${semanticsLabels(tester).join(' / ')}',
      );
      await tester.tap(find.byType(AylaAvatarHalo).first);
      await tester.pump();
      expect(opened, <String>['u-self']);
      handle.dispose();
    });

    testWidgets('头像：窄屏（≤768）36', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaGroupMemberList(members: trio),
          width: 375,
          viewport: 375,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<AylaAvatarHalo>(find.byType(AylaAvatarHalo).first).size,
        36,
      );
    });

    testWidgets('操作区条件：canManage && 非自己 && role !== owner 才渲染（tsx 776）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AylaGroupMemberList(
            members: trio,
            canManage: true,
            isOwner: true,
          ),
          width: 420,
          viewport: 1440,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(AylaGroupMemberList.actionsKey('u-admin')),
        findsOneWidget,
      );
      // 自己不算操作对象；群主不出现操作区
      expect(find.byKey(AylaGroupMemberList.actionsKey('u-self')), findsNothing);
      expect(
        find.byKey(AylaGroupMemberList.actionsKey('u-owner')),
        findsNothing,
      );
    });

    testWidgets('非 canManage：整块操作区不渲染', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaGroupMemberList(members: trio),
          width: 420,
          viewport: 1440,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(AylaGroupMemberList.actionsKey('u-admin')), findsNothing);
      expect(find.text('移除'), findsNothing);
    });

    testWidgets('操作区文案：admin ⇒「撤销管理员」· member ⇒「设为管理员」· 恒有「移除」', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AylaGroupMemberList(
            members: <AylaGroupMemberItem>[
              AylaGroupMemberItem(
                id: 'u-admin',
                name: '管理员小樱',
                role: AylaGroupRole.admin,
              ),
              AylaGroupMemberItem(id: 'u-plain', name: '普通成员'),
            ],
            canManage: true,
            isOwner: true,
          ),
          width: 420,
          viewport: 1440,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('撤销管理员'), findsOneWidget); // role === admin
      expect(find.text('设为管理员'), findsOneWidget); // role === member
      expect(find.text('移除'), findsNWidgets(2));
      // 两键几何：min-h 30 / padding 2 12 / 12px / pill（1772–1777）
      final AylaGlassButton remove = tester.widget<AylaGlassButton>(
        find.widgetWithText(AylaGlassButton, '移除').first,
      );
      expect(remove.minHeight, 30);
      expect(remove.fontSize, 12);
      expect(remove.borderRadius, AylaRadii.rPill);
      expect(
        remove.padding,
        const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      );
    });

    testWidgets('非 busy 档：文案「移除」且按钮可点', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaGroupMemberList(
            members: trio,
            canManage: true,
            isOwner: true,
            busyAction: null,
          ),
          width: 420,
          viewport: 1440,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('移除中…'), findsNothing);
      expect(find.text('移除'), findsOneWidget);
    });

    testWidgets('busy 档：文案「移除中…」+ 操作区两键全部 disabled（tsx 779/783）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaGroupMemberList(
            canManage: true,
            isOwner: true,
            // busyAction 键走公共工厂（web 的 remove-{id}）；
            // 第二行（member 角色）用来验证"busy 期间**其它行**的移除键也一并禁用"
            members: <AylaGroupMemberItem>[
              AylaGroupMemberItem(
                id: 'u-admin',
                name: '管理员小樱',
                role: AylaGroupRole.admin,
              ),
              AylaGroupMemberItem(id: 'u-plain', name: '普通成员'),
            ],
            busyAction: AylaGroupMemberList.removeActionKey('u-admin'),
          ),
          width: 420,
          viewport: 1440,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('移除中…'), findsOneWidget);
      expect(
        tester
            .widget<AylaGlassButton>(
              find.widgetWithText(AylaGlassButton, '移除中…'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<AylaGlassButton>(
              find.widgetWithText(AylaGlassButton, '设为管理员'),
            )
            .onPressed,
        isNull,
      );
      // busyAction 非 null ⇒ 其它行的「移除」也一并禁用
      expect(
        tester
            .widget<AylaGlassButton>(find.widgetWithText(AylaGlassButton, '移除'))
            .onPressed,
        isNull,
      );
    });

    testWidgets('宽屏操作区初始 opacity 0（1761–1764）· 行 hover ⇒ 1（1766–1769）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AylaGroupMemberList(
            members: trio,
            canManage: true,
            isOwner: true,
          ),
          width: 420,
          viewport: 1440,
        ),
      );
      await tester.pumpAndSettle();

      final Finder actions = find.byKey(AylaGroupMemberList.actionsKey('u-admin'));
      double opacity() =>
          tester.widget<AnimatedOpacity>(actions).opacity;
      expect(opacity(), 0);

      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: const Offset(700, 560)); // 宿主之外起手
      addTearDown(mouse.removePointer);
      await mouse.moveTo(
        tester.getCenter(find.byKey(AylaGroupMemberList.rowKey('u-admin'))),
      );
      await tester.pumpAndSettle();
      expect(opacity(), 1);
    });

    testWidgets('focus-within（无 hover）：焦点进入操作键 ⇒ opacity 1', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AylaGroupMemberList(
            members: trio,
            canManage: true,
            isOwner: true,
          ),
          width: 420,
          viewport: 1440,
        ),
      );
      await tester.pumpAndSettle();

      final Finder actions = find.byKey(AylaGroupMemberList.actionsKey('u-admin'));
      expect(tester.widget<AnimatedOpacity>(actions).opacity, 0);

      final FocusNode? node = Focus.maybeOf(tester.element(find.text('移除')));
      expect(node, isNotNull);
      node!.requestFocus();
      await tester.pump(); // 焦点在微任务里生效
      await tester.pump(); // 行 setState 后的重建
      expect(tester.widget<AnimatedOpacity>(actions).opacity, 1);

      // 焦点离开 ⇒ 回到 0
      node.unfocus();
      await tester.pump();
      await tester.pump();
      expect(tester.widget<AnimatedOpacity>(actions).opacity, 0);
    });

    testWidgets('窄屏（≤768）操作区常显：opacity 1（触摸无 hover）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AylaGroupMemberList(
            members: trio,
            canManage: true,
            isOwner: true,
          ),
          width: 375,
          viewport: 375,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(AylaGroupMemberList.actionsKey('u-admin')),
            )
            .opacity,
        1,
      );
    });

    testWidgets('容器 ≤420（卡内 372 + 卡内距 32 = 404）：行换行 + 操作区右对齐 + opacity 1', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AylaGroupMemberList(
            members: <AylaGroupMemberItem>[
              AylaGroupMemberItem(
                id: 'u-admin',
                name: '管理员小樱',
                role: AylaGroupRole.admin,
              ),
            ],
            canManage: true,
            isOwner: true,
          ),
          width: 372,
          viewport: 1440,
        ),
      );
      await tester.pumpAndSettle();

      final Rect row = tester.getRect(
        find.byKey(AylaGroupMemberList.rowKey('u-admin')),
      );
      final Rect actions = tester.getRect(
        find.byKey(AylaGroupMemberList.actionsKey('u-admin')),
      );
      final Rect name = tester.getRect(find.text('管理员小樱'));
      expect(actions.top, greaterThanOrEqualTo(name.bottom)); // 换到下一行
      expect(
        row.right - actions.right,
        moreOrLessEquals(AylaSpacing.sp3, epsilon: 0.5), // flex-end + padding sp3
      );
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(AylaGroupMemberList.actionsKey('u-admin')),
            )
            .opacity,
        1, // 换行档强制 opacity 1（1782–1786）
      );
      // 行高 = 头像（40 + 光环 2.5×2）+ padding sp2×2 + 行距 sp3 + 操作区 30
      const double avatar = 40 + AylaAvatarHalo.haloWidth * 2;
      expect(
        row.height,
        moreOrLessEquals(
          avatar + AylaSpacing.sp2 * 2 + AylaSpacing.sp3 + 30,
          epsilon: 0.5,
        ),
      );
    });

    testWidgets('容器 >420（卡内 440 + 32 = 472）：不换行（操作区与名字同行）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AylaGroupMemberList(
            members: <AylaGroupMemberItem>[
              AylaGroupMemberItem(
                id: 'u-admin',
                name: '管理员小樱',
                role: AylaGroupRole.admin,
              ),
            ],
            canManage: true,
            isOwner: true,
          ),
          width: 440,
          viewport: 1440,
        ),
      );
      await tester.pumpAndSettle();

      final Rect row = tester.getRect(
        find.byKey(AylaGroupMemberList.rowKey('u-admin')),
      );
      final Rect actions = tester.getRect(
        find.byKey(AylaGroupMemberList.actionsKey('u-admin')),
      );
      const double avatar = 40 + AylaAvatarHalo.haloWidth * 2;
      expect(
        row.height,
        moreOrLessEquals(avatar + AylaSpacing.sp2 * 2, epsilon: 0.5),
      );
      expect(
        actions.left,
        greaterThan(tester.getRect(find.text('管理员小樱')).right),
      );
    });

    testWidgets('空态二档 error：「成员加载失败」', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaGroupMemberList(
            members: <AylaGroupMemberItem>[],
            error: true,
          ),
          width: 420,
          viewport: 420,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(AylaGroupMemberList.placeholderKey))
            .data,
        '成员加载失败',
      );
    });

    testWidgets('空态三档默认：「没有匹配的成员」（13 / text-secondary）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AylaGroupMemberList(members: <AylaGroupMemberItem>[]),
          width: 420,
          viewport: 420,
        ),
      );
      await tester.pumpAndSettle();
      final Text text = tester.widget<Text>(
        find.byKey(AylaGroupMemberList.placeholderKey),
      );
      expect(text.data, '没有匹配的成员');
      expect(text.style!.fontSize, 13);
      expect(text.style!.color, AylaColors.textSecondary);
    });
  });

  // ═════════════════ 画布样张 ═════════════════

  group('aylaGroupInfoListsSamples', () {
    testWidgets('样张冒烟：800×600 宿主可渲染（宽档走横向滚动宿主）且无溢出', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          SingleChildScrollView(child: aylaGroupInfoListsSamples()),
          viewport: 800,
        ),
      );
      // 加载档里的骨架是无限脉冲 ⇒ 不 pumpAndSettle
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(find.byType(AylaGroupInfoLayout), findsWidgets);
      expect(find.byType(AylaGroupSubgroupList), findsWidgets);
      expect(find.byType(AylaGroupMemberList), findsWidgets);
    });
  });
}
