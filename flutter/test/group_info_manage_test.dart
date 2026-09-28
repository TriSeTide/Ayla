/// 群信息右列 / 管理卡三件定向测试 —— 对照 `GroupInfo.tsx:523–526 / 628–645 / 651–663 / 748–752` +
/// `group.css 1610–1675 / 2050–2107`。
///
/// 覆盖：区块标题（图标 18 + 文案 + margin-bottom sp3）· 卡片头（图标/标题/计数胶囊/在线行/头部动作 +
/// 推右几何）· 危险操作（owner 两键 / 非 owner 单击 / busy 文案与禁用 / 全宽 min-h 40 / gap sp2）。
///
/// ⚠️ 一态一用例（同用例二次 pumpWidget 换 props 不生效）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/app_icons.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/group/group_info_manage.dart';

void main() {
  Widget host(Widget child, {double width = 420}) => MaterialApp(
    home: previewScope(
      Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: Size(width, 1200)),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    ),
  );

  group('AylaGroupInfoSectionTitle', () {
    testWidgets('图标 18 + --text-secondary · 文案 Display 17/w500 · margin-bottom sp3', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaGroupInfoSectionTitle(
            title: '管理',
            icon: aylaIconByName('iconMenu'),
          ),
        ),
      );
      expect(find.text('管理'), findsOneWidget);

      final AylaIcon icon = tester.widget<AylaIcon>(find.byType(AylaIcon));
      expect(icon.size, 18); // web <IconMenu width={18} height={18} />
      expect(icon.color, AylaColors.textSecondary); // .group-info-section-title svg

      final Text title = tester.widget<Text>(find.text('管理'));
      expect(title.style!.fontSize, 17); // group.css 1615
      expect(title.style!.fontWeight, FontWeight.w500);
      expect(title.style!.fontFamily, AylaFonts.display);
      expect(title.style!.color, AylaColors.textPrimary);

      // margin-bottom: var(--sp-3)
      final Padding pad = tester.widget<Padding>(
        find
            .ancestor(
              of: find.text('管理'),
              matching: find.byType(Padding),
            )
            .first,
      );
      expect(pad.padding, const EdgeInsets.only(bottom: AylaSpacing.sp3));
    });

    testWidgets('不带图标档：只有文案（web 的 svg 是子节点，缺省即无）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host(const AylaGroupInfoSectionTitle(title: '更多')));
      expect(find.text('更多'), findsOneWidget);
      expect(find.byType(AylaIcon), findsNothing);
    });

    testWidgets('标题语义：header=true（web 是 <h3>，GroupInfo.tsx:523）', (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(const AylaGroupInfoSectionTitle(title: '管理')),
      );
      expect(
        tester
            .getSemantics(find.text('管理'))
            .flagsCollection
            .isHeader, // web <h3>
        isTrue,
      );
      handle.dispose();
    });
  });

  group('AylaGroupInfoCardHead', () {
    testWidgets('子群档：图标 + 标题 + 计数胶囊 + 「编辑子群」ghost（min-h 30 / padding 2 12 / pill）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaGroupInfoCardHead(
            title: '子群',
            icon: aylaIconByName('iconGrid'),
            count: 6,
            actionLabel: '编辑子群',
            actionSemanticLabel: '编辑子群',
            onAction: () {},
          ),
        ),
      );
      expect(find.text('子群'), findsOneWidget);
      expect(find.text('6'), findsOneWidget);
      expect(find.text('编辑子群'), findsOneWidget);

      final AylaIcon icon = tester.widget<AylaIcon>(find.byType(AylaIcon));
      expect(icon.size, 18);
      expect(icon.color, AylaColors.textSecondary);

      // 计数胶囊：min-width 20 / height 20 / radius pill / rgba(157,191,230,.32)
      final Container pill = tester.widget<Container>(
        find.byWidgetPredicate(
          (Widget w) =>
              w is Container &&
              w.constraints?.minWidth == 20 &&
              w.constraints?.maxHeight == 20,
        ),
      );
      final BoxDecoration decor = pill.decoration! as BoxDecoration;
      expect(decor.color, AylaColors.ice500.withValues(alpha: 0.32));
      expect(decor.borderRadius, AylaRadii.pill);
      final Text countText = tester.widget<Text>(
        find.descendant(of: find.byWidget(pill), matching: find.byType(Text)),
      );
      expect(countText.style!.fontSize, 11);
      expect(countText.style!.fontFamily, AylaFonts.utility);
      expect(countText.style!.color, AylaColors.indigo700);

      final AylaGlassButton btn = tester.widget<AylaGlassButton>(
        find.byType(AylaGlassButton),
      );
      expect(btn.minHeight, 30); // .group-info-head-action
      expect(btn.fontSize, 12);
      expect(btn.variant, AylaGlassButtonVariant.ghost);
      expect(btn.semanticLabel, '编辑子群'); // aria-label
    });

    testWidgets('成员档：在线行文案逐字 + 6×6 --success 圆点 + 推右到卡右缘', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaGroupInfoCardHead(
            title: '成员',
            icon: aylaIconByName('iconUsers'),
            count: 128,
            onlineCount: 12,
          ),
        ),
      );
      expect(find.text('已载入成员在线 12'), findsOneWidget); // web 原文

      final Container dot = tester.widget<Container>(
        find.byWidgetPredicate(
          (Widget w) =>
              w is Container &&
              w.constraints?.maxWidth == 6 &&
              w.constraints?.maxHeight == 6,
        ),
      );
      expect(
        (dot.decoration! as BoxDecoration).color,
        AylaColors.success, // ::before background: var(--success)
      );
      final Text online = tester.widget<Text>(find.text('已载入成员在线 12'));
      expect(online.style!.fontSize, 12);
      expect(online.style!.color, AylaColors.textSecondary);

      // margin-left: auto ⇒ 在线行右缘贴卡右缘（宿主宽 420）
      expect(tester.getRect(find.text('已载入成员在线 12')).right, closeTo(420, 1));
    });

    testWidgets('卡头标题语义：header=true（web 是 <h3>，GroupInfo.tsx:653 / 750）', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(const AylaGroupInfoCardHead(title: '成员')),
      );
      expect(tester.getSemantics(find.text('成员')).flagsCollection.isHeader, isTrue);
      handle.dispose();
    });

    testWidgets('计数与在线都缺省 ⇒ 不渲染胶囊/在线行（web 条件渲染）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(const AylaGroupInfoCardHead(title: '子群')),
      );
      expect(find.text('子群'), findsOneWidget);
      expect(find.byType(Container), findsNothing);
      expect(find.textContaining('已载入成员在线'), findsNothing);
    });
  });

  group('AylaGroupInfoDangerActions', () {
    testWidgets('owner 档：转让群主 ghost + 解散群聊 destructive · 全宽 min-h 40 · gap sp2', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaGroupInfoDangerActions(onTransfer: () {}, onDissolve: () {}),
        ),
      );
      expect(find.text('转让群主'), findsOneWidget);
      expect(find.text('解散群聊'), findsOneWidget);

      final List<AylaGlassButton> btns = tester
          .widgetList<AylaGlassButton>(find.byType(AylaGlassButton))
          .toList();
      expect(btns.length, 2);
      expect(btns[0].variant, AylaGlassButtonVariant.ghost); // 转让群主
      expect(btns[1].variant, AylaGlassButtonVariant.destructive); // 解散群聊
      for (final AylaGlassButton b in btns) {
        expect(b.minHeight, 40); // .group-info-action-row { min-height: 40px }
        expect(b.expand, isTrue); // width: 100%
      }

      // 全宽：两键的视觉盒宽 = 宿主宽（420）
      expect(tester.getSize(find.text('转让群主')).width, greaterThan(0));
      expect(tester.getRect(find.byType(AylaGlassButton).first).width, 420);
      // gap: sp2 ⇒ 两键垂直间距 = 8
      final double gap =
          tester.getRect(find.byType(AylaGlassButton).last).top -
          tester.getRect(find.byType(AylaGlassButton).first).bottom;
      expect(gap, closeTo(AylaSpacing.sp2, 0.01));
    });

    testWidgets('非 owner 档：只出「退出群聊」（destructive）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(AylaGroupInfoDangerActions(onLeave: () {})),
      );
      expect(find.text('退出群聊'), findsOneWidget);
      expect(find.text('转让群主'), findsNothing);
      expect(find.text('解散群聊'), findsNothing);
    });

    testWidgets('busy 档逐键不同：解散/退出切文案，**只有「退出群聊」禁用**（web tsx:629/632/641）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaGroupInfoDangerActions(
            dissolveBusy: true,
            leaveBusy: true,
            anyActionBusy: true,
            onTransfer: () {},
            onDissolve: () {},
            onLeave: () {},
          ),
        ),
      );
      expect(find.text('转让群主'), findsOneWidget); // web 该键无 busy 文案
      expect(find.text('解散中…'), findsOneWidget);
      expect(find.text('退出中…'), findsOneWidget);

      final List<AylaGlassButton> btns = tester
          .widgetList<AylaGlassButton>(find.byType(AylaGlassButton))
          .toList();
      expect(btns[0].onPressed, isNotNull, reason: '转让群主：web 无 disabled');
      expect(btns[1].onPressed, isNotNull, reason: '解散群聊：web 只切文案、不禁用');
      expect(btns[2].onPressed, isNull, reason: '退出群聊：web disabled={busyAction !== null}');
    });

    testWidgets('任意管理动作在途只禁「退出群聊」（转让/解散仍可点）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaGroupInfoDangerActions(
            anyActionBusy: true, // 例如 emoji-policy / join-* 在途
            onTransfer: () {},
            onDissolve: () {},
            onLeave: () {},
          ),
        ),
      );
      // 无 busy 文案（不是本动作在途 ⇒ 文案保持原样）
      expect(find.text('解散群聊'), findsOneWidget);
      expect(find.text('退出群聊'), findsOneWidget);
      final List<AylaGlassButton> btns = tester
          .widgetList<AylaGlassButton>(find.byType(AylaGlassButton))
          .toList();
      expect(btns[0].onPressed, isNotNull);
      expect(btns[1].onPressed, isNotNull);
      expect(btns[2].onPressed, isNull);
    });

    testWidgets('三个回调都为空 ⇒ 不渲染任何行', (WidgetTester tester) async {
      await tester.pumpWidget(host(const AylaGroupInfoDangerActions()));
      expect(find.byType(AylaGlassButton), findsNothing);
    });

    testWidgets('点击回调回传（转让群主）', (WidgetTester tester) async {
      int calls = 0;
      await tester.pumpWidget(
        host(AylaGroupInfoDangerActions(onTransfer: () => calls++)),
      );
      await tester.tap(find.text('转让群主'));
      await tester.pump();
      expect(calls, 1);
    });
  });
}
