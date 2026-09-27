/// 转让群主弹窗 + 角色标签定向测试 —— 对照 `GroupInfo.tsx:904–1010` / `52–56` +
/// `app.css 3894–4005` / `group.css 1734–1750`。
///
/// 覆盖：角色标签三态（member 不渲染 · owner/admin 各自的底与字色）· 弹窗的 web 默认文案 ·
/// 非 member 才出标签 · 行选中回调 · 确认键的三档 disabled（无选中 / 选中 / busy）+ busy 文案 ·
/// 空态「没有匹配的成员」· 错误行 · 「已选择：X」提示 · 搜索框初值。
/// ⚠️ 一态一用例；需要同用例切状态的用 `StatefulBuilder` 宿主（同用例二次 pumpWidget 换 props 不生效）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/group/group_role_chip.dart';
import '../lib/widgets/group/transfer_owner_dialog.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
    home: previewScope(
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 620, height: 520, child: child),
      ),
    ),
  );

  const List<AylaTransferMember> members = <AylaTransferMember>[
    AylaTransferMember(id: 'u1', displayName: '爱莉', online: true),
    AylaTransferMember(id: 'u2', displayName: '小樱'),
    AylaTransferMember(id: 'u3', displayName: '小可', role: AylaGroupRole.admin),
  ];

  group('AylaGroupRoleChip（group.css 1734–1750）', () {
    testWidgets('owner：群主 + sakura-300 底 / grape-700 字', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(const AylaGroupRoleChip(role: AylaGroupRole.owner)),
      );
      expect(find.text('群主'), findsOneWidget);
      final Container box = tester.widget<Container>(find.byType(Container));
      final BoxDecoration deco = box.decoration! as BoxDecoration;
      expect(deco.color, AylaColors.sakura300);
      expect(deco.borderRadius, AylaRadii.pill);
      expect(box.padding, const EdgeInsets.symmetric(horizontal: 8, vertical: 1));
      expect(
        tester.widget<Text>(find.text('群主')).style!.color,
        AylaColors.grape700,
      );
    });

    testWidgets('admin：管理员 + ice-300 底 / indigo-700 字', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(const AylaGroupRoleChip(role: AylaGroupRole.admin)),
      );
      expect(find.text('管理员'), findsOneWidget);
      final BoxDecoration deco =
          tester.widget<Container>(find.byType(Container)).decoration!
              as BoxDecoration;
      expect(deco.color, AylaColors.ice300);
      expect(
        tester.widget<Text>(find.text('管理员')).style!.color,
        AylaColors.indigo700,
      );
    });

    testWidgets('member ⇒ 不渲染（web：role !== "member" 才出标签）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(const AylaGroupRoleChip(role: AylaGroupRole.member)),
      );
      expect(find.byType(Text), findsNothing);
    });
  });

  group('AylaTransferOwnerDialog（GroupInfo.tsx 904–1010）', () {
    testWidgets('web 默认文案齐：标题 / 说明 / 搜索占位 / 取消 / 确认', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaTransferOwnerDialog(
            members: members,
            selectedId: null,
            query: '',
            onClose: () {},
          ),
        ),
      );
      expect(find.text('转让群主'), findsOneWidget);
      expect(find.text('选择一位群成员接任群主。转让后你将成为普通成员。'), findsOneWidget);
      expect(find.text('搜索成员昵称/用户名'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('确认转让'), findsOneWidget);
      // 未选中 ⇒ 确认键 disabled
      final List<AylaGlassButton> buttons = tester
          .widgetList<AylaGlassButton>(find.byType(AylaGlassButton))
          .toList();
      expect(buttons.last.onPressed, isNull);
      // 搜索框左内距 34px
      final AylaGlassInput input = tester.widget<AylaGlassInput>(
        find.byType(AylaGlassInput),
      );
      expect(input.padding, const EdgeInsets.only(left: 34));
      expect(input.controller.text, '');
    });

    testWidgets('行：member 不出标签、admin 出标签；点行回调 onSelect', (WidgetTester tester) async {
      final List<String> log = <String>[];
      await tester.pumpWidget(
        host(
          AylaTransferOwnerDialog(
            members: members,
            selectedId: null,
            query: '',
            onSelect: (AylaTransferMember m) => log.add(m.id),
            onClose: () {},
          ),
        ),
      );
      expect(find.text('爱莉'), findsOneWidget);
      expect(find.text('小可'), findsOneWidget);
      expect(find.text('管理员'), findsOneWidget); // 只有 admin 那行有标签
      await tester.tap(find.text('小樱'));
      await tester.pump();
      expect(log, <String>['u2']);
    });

    testWidgets('已选中 ⇒ 出现「已选择：X」且确认键可用并回调', (WidgetTester tester) async {
      final List<String> log = <String>[];
      await tester.pumpWidget(
        host(
          AylaTransferOwnerDialog(
            members: members,
            selectedId: 'u1',
            query: '',
            onConfirm: (AylaTransferMember m) => log.add(m.id),
            onClose: () {},
          ),
        ),
      );
      expect(find.text('已选择：爱莉'), findsOneWidget);
      final List<AylaGlassButton> buttons = tester
          .widgetList<AylaGlassButton>(find.byType(AylaGlassButton))
          .toList();
      expect(buttons.last.onPressed, isNotNull);
      await tester.tap(find.text('确认转让'));
      await tester.pump();
      expect(log, <String>['u1']);
    });

    testWidgets('busy ⇒ 文案「转让中…」，取消与确认都禁用', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaTransferOwnerDialog(
            members: members,
            selectedId: 'u1',
            query: '',
            busy: true,
            onClose: () {},
          ),
        ),
      );
      expect(find.text('转让中…'), findsOneWidget);
      expect(find.text('确认转让'), findsNothing);
      for (final AylaGlassButton b in tester.widgetList<AylaGlassButton>(
        find.byType(AylaGlassButton),
      )) {
        expect(b.onPressed, isNull);
      }
    });

    testWidgets('空列表（非 loading/error）⇒「没有匹配的成员」', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaTransferOwnerDialog(
            members: const <AylaTransferMember>[],
            selectedId: null,
            query: 'zzz',
            onClose: () {},
          ),
        ),
      );
      expect(find.text('没有匹配的成员'), findsOneWidget);
      expect(
        tester.widget<AylaGlassInput>(find.byType(AylaGlassInput)).controller.text,
        'zzz',
      );
    });

    testWidgets('错误行走 liveRegion（web role=alert）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaTransferOwnerDialog(
            members: members,
            selectedId: null,
            query: '',
            error: '转让失败，请重试',
            onClose: () {},
          ),
        ),
      );
      expect(find.text('转让失败，请重试'), findsOneWidget);
      final Iterable<Semantics> alerts = tester
          .widgetList<Semantics>(find.byType(Semantics))
          .where((Semantics s) => s.properties.liveRegion == true);
      expect(alerts, isNotEmpty);
    });
  });
}
