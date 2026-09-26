/// B5 group 域第一批（1/2）：子群弹窗定向测试 —— 逐条对照
/// SubGroupDialog.tsx 18–110 与 group.css 2131–2231（含 overlay/卡片/head/禁言行/按钮排）。
///
/// 覆盖：add 与 edit 两态结构 / 初始值（名称 + 禁言）/ 空名禁用与「输入后可用」回归 /
/// 确定回调（add 的第二参数为 null）/ 禁言行切换（18×18 复选框）/ 默认组不可删 /
/// 错误行 13px destructive / busy（文案 + 全禁用）/ 遮罩点击关闭与 busy 拦截。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter;
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/subgroup.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/dialogs.dart';
import '../lib/widgets/base/directory_controls.dart';
import '../lib/widgets/group/subgroup_dialog.dart';

void main() {
  const AylaSubGroup custom = AylaSubGroup(
    id: 's1',
    conversationId: 'g1',
    name: '深夜组',
    isDefault: false,
    unreadCount: 3,
    muted: true,
  );
  const AylaSubGroup defaultGroup = AylaSubGroup(
    id: 's0',
    conversationId: 'g1',
    name: '默认组',
    isDefault: true,
    unreadCount: 0,
  );

  Widget host(Widget child, {Size viewport = const Size(420, 700)}) {
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: SizedBox.fromSize(size: viewport, child: child),
          ),
        ),
      ),
    );
  }

  /// 按文案取按钮（按钮内的 Text 是唯一锚点）。
  AylaGlassButton byLabel(WidgetTester tester, String label) => tester.widget<AylaGlassButton>(
        find.ancestor(of: find.text(label), matching: find.byType(AylaGlassButton)).first,
      );

  testWidgets('add 态结构：标题「添加子群」· hint · 无禁言行 · 无删除键 · 空名禁用', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(AylaSubGroupDialog(
      state: const AylaSubGroupDialogState.add(),
      onClose: () {},
      onConfirm: (String name, bool? muted) {},
    )));
    await tester.pump();

    expect(find.text('添加子群'), findsOneWidget); // tsx 50
    expect(find.text('子群群名'), findsOneWidget); // tsx 59 placeholder
    expect(find.text('禁言该子群'), findsNothing); // 仅 edit
    expect(find.text('删除'), findsNothing); // 仅 edit
    expect(byLabel(tester, '确定').onPressed, isNull); // disabled = !name.trim()
    expect(find.byType(AylaCheckbox), findsNothing);
    // 关闭键 = .icon-btn-40（40×40）
    expect(tester.getSize(find.byType(AylaModalCard)).width, 360); // min(360px, 100%)
  });

  testWidgets('输入后「确定」可用（漏 setState 的真实事故回归）', (WidgetTester tester) async {
    await tester.pumpWidget(host(AylaSubGroupDialog(
      state: const AylaSubGroupDialogState.add(),
      onClose: () {},
      onConfirm: (String name, bool? muted) {},
    )));
    await tester.pump();
    expect(byLabel(tester, '确定').onPressed, isNull);

    await tester.enterText(find.byType(TextField), '新子群');
    await tester.pump();
    expect(byLabel(tester, '确定').onPressed, isNotNull);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(byLabel(tester, '确定').onPressed, isNull); // trim 后为空
  });

  testWidgets('确定回调：add 态第二参数为 null，名称为 trim 值（tsx 98–101）', (
    WidgetTester tester,
  ) async {
    String? gotName;
    bool? gotMuted;
    bool called = false;
    await tester.pumpWidget(host(AylaSubGroupDialog(
      state: const AylaSubGroupDialogState.add(),
      onClose: () {},
      onConfirm: (String name, bool? muted) {
        called = true;
        gotName = name;
        gotMuted = muted;
      },
    )));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '  新子群  ');
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pump();

    expect(called, isTrue);
    expect(gotName, '新子群');
    expect(gotMuted, isNull);
  });

  testWidgets('edit 态：标题 + 预填名 + 禁言行（18×18 · 初始 muted=true）+ 删除键', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(AylaSubGroupDialog(
      state: const AylaSubGroupDialogState.edit(custom),
      onClose: () {},
      onConfirm: (String name, bool? muted) {},
      onDelete: () {},
    )));
    await tester.pump();

    expect(find.text('编辑子群'), findsOneWidget);
    expect(find.text('深夜组'), findsOneWidget); // 预填
    expect(find.text('禁言该子群'), findsOneWidget); // tsx 73
    expect(find.text('开启后仅群主/管理员可发言'), findsOneWidget); // tsx 74
    final AylaCheckbox box = tester.widget<AylaCheckbox>(find.byType(AylaCheckbox));
    expect(box.checked, isTrue); // muted: true
    expect(box.size, 18); // .subgroup-dialog-mute input 18×18
    expect(find.text('删除'), findsOneWidget);
    expect(byLabel(tester, '删除').onPressed, isNotNull); // 非默认组可删
  });

  testWidgets('默认组的 edit：删除键禁用（canDelete = !is_default）', (WidgetTester tester) async {
    await tester.pumpWidget(host(AylaSubGroupDialog(
      state: const AylaSubGroupDialogState.edit(defaultGroup),
      onClose: () {},
      onConfirm: (String name, bool? muted) {},
      onDelete: () {},
    )));
    await tester.pump();
    expect(byLabel(tester, '删除').onPressed, isNull);
  });

  testWidgets('禁言行：点整行切换（web label 语义），确定回传 muted', (
    WidgetTester tester,
  ) async {
    bool? gotMuted;
    await tester.pumpWidget(host(AylaSubGroupDialog(
      state: const AylaSubGroupDialogState.edit(custom),
      onClose: () {},
      onConfirm: (String name, bool? muted) => gotMuted = muted,
      onDelete: () {},
    )));
    await tester.pump();

    await tester.tap(find.text('禁言该子群')); // 整行可点
    await tester.pump();
    expect(tester.widget<AylaCheckbox>(find.byType(AylaCheckbox)).checked, isFalse);

    await tester.tap(find.text('确定'));
    await tester.pump();
    expect(gotMuted, isFalse);
  });

  testWidgets('错误行：13px + destructive', (WidgetTester tester) async {
    await tester.pumpWidget(host(AylaSubGroupDialog(
      state: const AylaSubGroupDialogState.add(),
      error: '同名子群已存在',
      onClose: () {},
      onConfirm: (String name, bool? muted) {},
    )));
    await tester.pump();
    final Text err = tester.widget<Text>(find.text('同名子群已存在'));
    expect(err.style?.fontSize, 13);
    expect(err.style?.color, AylaColors.destructive);
  });

  testWidgets('busy：确定文案「保存中…」+ 取消/关闭键禁用；遮罩点击不关闭', (
    WidgetTester tester,
  ) async {
    int closed = 0;
    await tester.pumpWidget(host(AylaSubGroupDialog(
      state: const AylaSubGroupDialogState.add(),
      busy: true,
      onClose: () => closed++,
      onConfirm: (String name, bool? muted) {},
    )));
    await tester.pump();

    expect(find.text('保存中…'), findsOneWidget);
    expect(byLabel(tester, '保存中…').onPressed, isNull);
    expect(byLabel(tester, '取消').onPressed, isNull);

    // 点遮罩（用卡片外侧坐标，避免依赖宿主在窗口里的位置）
    final Rect card = tester.getRect(find.byType(AylaModalCard));
    await tester.tapAt(Offset(card.left - 12, card.center.dy));
    await tester.pump();
    expect(closed, 0); // busy ⇒ onDismiss = null
  });

  testWidgets('遮罩点击关闭（非 busy）+ 关闭键回调', (WidgetTester tester) async {
    int closed = 0;
    await tester.pumpWidget(host(AylaSubGroupDialog(
      state: const AylaSubGroupDialogState.add(),
      onClose: () => closed++,
      onConfirm: (String name, bool? muted) {},
    )));
    await tester.pump();

    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(closed, 1);

    final Rect card = tester.getRect(find.byType(AylaModalCard));
    await tester.tapAt(Offset(card.left - 12, card.center.dy));
    await tester.pump();
    expect(closed, 2); // 遮罩点击 → onClose
  });

  testWidgets('64 上限用 formatter 表达（不出现计数器）', (WidgetTester tester) async {
    await tester.pumpWidget(host(AylaSubGroupDialog(
      state: const AylaSubGroupDialogState.add(),
      onClose: () {},
      onConfirm: (String name, bool? muted) {},
    )));
    await tester.pump();
    final TextField field = tester.widget<TextField>(find.byType(TextField));
    expect(field.maxLength, isNull);
    expect(
      field.inputFormatters!.whereType<LengthLimitingTextInputFormatter>(),
      isNotEmpty,
    );
  });
}
