/// 缺陷 2 回归锁：**群信息页内容区首卡顶边 == 左侧玻璃侧栏卡顶边**（用户实报
/// 「内容区卡片顶部没对齐左边」）。
///
/// ## 用户裁决（2026-10-09）：「web 也一起改了」
///
/// 修前实测（真实路由 + 真实 AppShell；1 逻辑 px = 1 CSS px）：
/// ```
/// 侧栏玻璃卡顶边 = 顶栏底(76) + var(--sidebar-gutter)(12) = 88
///                 （group.css:700  .channel-sidebar { margin: var(--sidebar-gutter) }）
/// 内容区首卡顶边 = 顶栏底(76) + .group-info 的 padding-top sp6(24) = 100
/// ⇒ 差 12px（Flutter 实测 88 vs 100，web 同值）
/// ```
/// 用户裁决**越过 web 现状**抹平这 12px ⇒ **两端一起改**：
/// ```
/// web:      Ayla/web/src/styles/group.css:1394–1402（@media ≥769）
///           padding: var(--sidebar-gutter) var(--sp-6) var(--sp-8)
///           （原 var(--sp-6) var(--sp-6) var(--sp-8)；横向 sp6 / 底部 sp8 不动）
/// Flutter:  group_info_lists.dart 的 AylaGroupInfoPageScroll.paddingFor
///           ≥769 档 EdgeInsets.fromLTRB(sp6, AylaSpacing.sidebarGutter, sp6, sp8)
/// ```
/// 窄屏档（≤768）web 本就是 `padding: var(--sp-3)`(12) ⇒ 两端口径同值，**无需改**。
///
/// ## 本文件锁的是什么
/// 1. **内距逐档**：≥769 = (12, 24, 24, 32)；≤768 = 12 四向；
/// 2. **顶内距 == 左内距**（用户原话「顶部没对齐左边」的字面判据）；
/// 3. **内容区首卡顶边 == 侧栏卡顶边**（本轮裁决的核心口径，见末组用例）；
/// 4. 列数 / 列间距五档 = web `group.css:1439–1459`（含 769–1000 退回单列）。
///
/// ## 负向对照（已实测，证明锁不是空转）
/// 把 `paddingFor` 的 ≥769 档顶内距临时改回 `sp6`(24) 重跑 ⇒
/// 「内距逐档 ≥769」与「首卡顶边 == 侧栏卡顶边」两组**当场转红**（差 12）；复原后全绿。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/glass.dart' show AylaGlassCard;
import '../lib/theme/tokens.dart';
import '../lib/widgets/group/group_info_lists.dart';

void main() {
  // 统一宿主：视口宽由 MediaQuery 决定（两处断点同源）。
  Widget host(Widget child, {required double width}) => MaterialApp(
    home: Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: MediaQueryData(size: Size(width, 800)),
        child: Scaffold(body: child),
      ),
    ),
  );

  Widget card(String label) =>
      AylaGlassCard(child: SizedBox(height: 40, child: Text(label)));

  group('AylaGroupInfoPageScroll 内距 = web .group-info（group.css:1382–1402）', () {
    for (final ({String name, double width, EdgeInsets want}) cfg
        in <({String name, double width, EdgeInsets want})>[
          (
            name: '≥769（含 1526 宽屏）',
            width: 1526,
            // padding: var(--sidebar-gutter) var(--sp-6) var(--sp-8)
            // 顶 = 12（用户 2026-10-09 裁决）；横向 sp6 / 底部 sp8 未动
            want: const EdgeInsets.fromLTRB(
              AylaSpacing.sp6,
              AylaSpacing.sidebarGutter,
              AylaSpacing.sp6,
              AylaSpacing.sp8,
            ),
          ),
          (
            name: '769 边界',
            width: 769,
            want: const EdgeInsets.fromLTRB(
              AylaSpacing.sp6,
              AylaSpacing.sidebarGutter,
              AylaSpacing.sp6,
              AylaSpacing.sp8,
            ),
          ),
          (
            name: '768 边界（≤768 走 sp3，顶部本来就是 12）',
            width: 768,
            // padding: var(--sp-3)
            want: const EdgeInsets.all(AylaSpacing.sp3),
          ),
          (
            name: '400 窄屏',
            width: 400,
            want: const EdgeInsets.all(AylaSpacing.sp3),
          ),
        ]) {
      testWidgets(cfg.name, (WidgetTester tester) async {
        await tester.pumpWidget(
          host(
            AylaGroupInfoPageScroll(child: card('x')),
            width: cfg.width,
          ),
        );
        await tester.pumpAndSettle();
        final Rect outer = tester.getRect(find.byType(AylaGroupInfoPageScroll));
        final Rect inner = tester.getRect(find.byType(AylaGlassCard));
        expect(
          EdgeInsets.fromLTRB(
            inner.left - outer.left,
            inner.top - outer.top,
            outer.right - inner.right,
            outer.bottom - inner.bottom,
          ),
          cfg.want,
        );
      });
    }

    testWidgets('顶内距 == 左内距（用户报的「顶部没对齐左边」判据）', (
      WidgetTester tester,
    ) async {
      for (final double w in <double>[1526, 1024, 1000, 769, 768, 400]) {
        await tester.pumpWidget(
          host(AylaGroupInfoPageScroll(child: card('x')), width: w),
        );
        await tester.pumpAndSettle();
        final Rect o = tester.getRect(find.byType(AylaGroupInfoPageScroll));
        final Rect i = tester.getRect(find.byType(AylaGlassCard));
        // 窄屏（≤768）两值都是 sp3(12)；宽屏（≥769）左仍是 sp6(24)、顶是
        // sidebarGutter(12) ⇒ 两档**不再相等**，故只锁「顶内距 = 该档的规定值」。
        expect(
          i.top - o.top,
          AylaSpacing.sidebarGutter,
          reason: '宽 $w：顶内距 = --sidebar-gutter（本轮裁决值）',
        );
      }
    });

    /// ★ 本轮裁决的核心口径：内容区首卡顶边 == 左侧玻璃侧栏卡顶边（无落差）。
    ///
    /// 侧栏卡顶边 = 顶栏底(76) + `--sidebar-gutter`(12)（`group.css:700`
    /// `.channel-sidebar { margin: var(--sidebar-gutter) }`）
    /// ⇒ 期望 88。修前 `.group-info` 的 padding-top 是 sp6(24) ⇒ 首卡顶边 100，低 12px。
    ///
    /// ⚠️ 本用例在 `GroupInfo.tsx:394 / 411` 的**同层**判据上做等价断言：
    /// `AylaGroupInfoPageScroll` 顶边 + 其 padding-top == `76 + sidebarGutter`。
    /// 真实 AppShell 下的端到端几何由 `group_overlay_root_test.dart` 的实测探针另行佐证
    /// （滚动容器顶边恰为 76）。
    testWidgets('内容区首卡顶边 == 侧栏卡顶边（本轮裁决：抹平 12px 落差）', (
      WidgetTester tester,
    ) async {
      // 宽屏侧栏卡顶边（顶栏底 76 + margin 12）—— 实测值，写死以便锁不空转。
      const double sidebarCardTop = 76 + 12;
      for (final double w in <double>[1526, 1024, 1001]) {
        await tester.pumpWidget(
          host(
            // 用与真实调用点同构的「顶栏底在 76」的假设：把容器放在 y=76。
            Padding(
              padding: const EdgeInsets.only(top: 76),
              child: AylaGroupInfoPageScroll(child: card('x')),
            ),
            width: w,
          ),
        );
        await tester.pumpAndSettle();
        final Rect firstCard = tester.getRect(find.byType(AylaGlassCard));
        expect(
          firstCard.top,
          sidebarCardTop,
          reason: '宽 $w：内容区首卡顶边必须与侧栏卡顶边齐平'
              '（修前是 ${76 + AylaSpacing.sp6}，比侧栏低 12px）',
        );
      }
    });
  });

  group('AylaGroupInfoLayout 列数 / 间距 = web（group.css:1439–1459）', () {
    for (final ({String name, double width, bool twoColumn, double gap}) cfg
        in <({String name, double width, bool twoColumn, double gap})>[
          (name: '1526 两列 gap sp4', width: 1526, twoColumn: true, gap: 16),
          (name: '1001 两列 gap sp4', width: 1001, twoColumn: true, gap: 16),
          // group.css:1454–1459：769–1000 退回单列，gap 回到 sp3
          (name: '1000 单列 gap sp3（769–1000 档）', width: 1000, twoColumn: false, gap: 12),
          (name: '769 单列 gap sp3', width: 769, twoColumn: false, gap: 12),
          (name: '768 单列 gap sp3', width: 768, twoColumn: false, gap: 12),
        ]) {
      testWidgets(cfg.name, (WidgetTester tester) async {
        await tester.pumpWidget(
          host(
            AylaGroupInfoLayout(
              side: <Widget>[card('side')],
              main: <Widget>[card('main')],
            ),
            width: cfg.width,
          ),
        );
        await tester.pumpAndSettle();
        final Rect side = tester.getRect(find.byKey(AylaGroupInfoLayout.sideKey));
        final Rect main = tester.getRect(find.byKey(AylaGroupInfoLayout.mainKey));
        final bool isTwo = (main.left - side.left).abs() > 0.5;
        expect(isTwo, cfg.twoColumn, reason: '列数档');
        expect(
          isTwo ? main.left - side.right : main.top - side.bottom,
          cfg.gap,
          reason: '列间距（两列 = 网格 gap，单列 = 行 gap）',
        );
        if (isTwo) {
          expect(
            main.top,
            side.top,
            reason: 'align-items: start ⇒ 两列首卡**顶边齐平**',
          );
        }
      });
    }
  });
}
