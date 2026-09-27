/// 群资料卡定向测试 —— 对照 `GroupInfo.tsx:461–520` + `group.css 1382–1610 / 2235–2240`。
///
/// 覆盖：展示态四段（群名 / 简介含空态 / 创建于（含无值「—」）/ 统计三格）· 返回键定位与语义 ·
/// canManage 两档（更换群头像 + 编辑群资料）· avatarPreview 档（hint + 保存群头像）·
/// 编辑态（初值 / 两键等宽 / 保存回传 / saving 文案与禁用）· 头像尺寸窄 76 宽 92。
/// ⚠️ 一态一用例（同用例二次 pumpWidget 换 props 不生效）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/buttons.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/avatar_halo.dart';
import '../lib/widgets/group/group_info_profile.dart';

void main() {
  Widget host(Widget child, {double width = 420}) => MaterialApp(
    home: previewScope(
      Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: Size(width, 900)),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    ),
  );

  const List<AylaGroupInfoStat> stats = <AylaGroupInfoStat>[
    AylaGroupInfoStat(value: '128', label: '成员'),
    AylaGroupInfoStat(value: '37', label: '已载入在线'),
    AylaGroupInfoStat(value: '4', label: '子群'),
  ];

  Widget card({
    String title = '星海观测站',
    String? about = '一起看星星',
    DateTime? createdAt,
    bool canManage = true,
    bool avatarPreview = false,
    bool editing = false,
    bool saving = false,
    String? error,
    void Function(String, String)? onSaveEdit,
    VoidCallback? onBack,
  }) => AylaGroupInfoProfile(
    title: title,
    about: about,
    createdAt: createdAt ?? DateTime(2026, 3, 14),
    stats: stats,
    canManage: canManage,
    avatarPreview: avatarPreview,
    editing: editing,
    saving: saving,
    error: error,
    initialTitle: title,
    initialAbout: about,
    onBack: onBack ?? () {},
    onChangeAvatar: () {},
    onSaveAvatar: () {},
    onEdit: () {},
    onSaveEdit: onSaveEdit,
    onCancelEdit: () {},
  );

  group('AylaGroupInfoProfile 展示态（tsx 496–516）', () {
    testWidgets('群名 / 群简介标签+正文 / 创建于日期 / 统计三格', (WidgetTester tester) async {
      await tester.pumpWidget(host(card()));
      expect(find.text('星海观测站'), findsOneWidget);
      expect(find.text('群简介'), findsOneWidget);
      expect(find.text('一起看星星'), findsOneWidget);
      expect(find.text('创建于 2026/3/14'), findsOneWidget); // zh-CN 的 y/M/d
      for (final String label in <String>['成员', '已载入在线', '子群']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('128'), findsOneWidget);
    });

    testWidgets('简介为空 ⇒「暂无简介」（web `conv.announcement || "暂无简介"`）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host(card(about: '')));
      expect(find.text('暂无简介'), findsOneWidget);
    });

    testWidgets('创建时间为空 ⇒「创建于 —」（web formatDate 无值返回「—」）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaGroupInfoProfile(
            title: '星海观测站',
            createdAt: null,
            stats: stats,
          ),
        ),
      );
      expect(find.text('创建于 —'), findsOneWidget);
    });

    testWidgets('返回键：语义「返回群聊」，浮在卡左上（absolute top sp3 / left sp3）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host(card()));
      final AylaIconButton back = tester.widget<AylaIconButton>(
        find.byType(AylaIconButton),
      );
      expect(back.semanticLabel, '返回群聊');
      expect(tester.getRect(find.byType(AylaIconButton)).left, AylaSpacing.sp3);
      expect(tester.getRect(find.byType(AylaIconButton)).top, AylaSpacing.sp3);
    });
  });

  group('AylaGroupInfoProfile 头像块与权限档（tsx 466–493）', () {
    testWidgets('canManage ⇒ 出「更换群头像」与「编辑群资料」', (WidgetTester tester) async {
      await tester.pumpWidget(host(card()));
      expect(find.text('更换群头像'), findsOneWidget);
      expect(find.text('编辑群资料'), findsOneWidget);
    });

    testWidgets('非 canManage ⇒ 两个都不出（普通成员视角）', (WidgetTester tester) async {
      await tester.pumpWidget(host(card(canManage: false)));
      expect(find.text('更换群头像'), findsNothing);
      expect(find.text('编辑群资料'), findsNothing);
    });

    testWidgets('avatarPreview ⇒ hint「新头像将在保存后生效」+「保存群头像」', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host(card(avatarPreview: true)));
      expect(find.text('新头像将在保存后生效'), findsOneWidget);
      expect(find.text('保存群头像'), findsOneWidget);
    });

    testWidgets('窄档头像 76 / 宽档头像 92', (WidgetTester tester) async {
      await tester.pumpWidget(host(card(), width: 420)); // <769
      expect(tester.widget<AylaAvatarHalo>(find.byType(AylaAvatarHalo)).size, 76);
    });

    testWidgets('宽档（≥769）头像 92', (WidgetTester tester) async {
      await tester.pumpWidget(host(card(), width: 900));
      expect(tester.widget<AylaAvatarHalo>(find.byType(AylaAvatarHalo)).size, 92);
    });
  });

  group('AylaGroupInfoProfile 编辑态（tsx 495–514）', () {
    testWidgets('两个输入填当前值 + 两键等宽 + 保存回传 (群名, 群简介)', (
      WidgetTester tester,
    ) async {
      final List<String> log = <String>[];
      await tester.pumpWidget(
        host(card(editing: true, onSaveEdit: (String a, String b) => log.add('$a|$b'))),
      );
      final List<AylaGlassInput> inputs = tester
          .widgetList<AylaGlassInput>(find.byType(AylaGlassInput))
          .toList();
      expect(inputs.length, 2);
      expect(inputs[0].controller.text, '星海观测站'); // 群名初值
      expect(inputs[1].controller.text, '一起看星星'); // 群简介初值
      expect(find.text('保存'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      // 两键等宽（`.group-info-edit-actions .btn { flex: 1 }`）
      // ⚠️ 别用 `find.byType(...).at(0)`：编辑态下第一个按钮是头像块的「更换群头像」
      final double wSave = tester
          .getSize(find.widgetWithText(AylaGlassButton, '保存'))
          .width;
      final double wCancel = tester
          .getSize(find.widgetWithText(AylaGlassButton, '取消'))
          .width;
      expect(wCancel, closeTo(wSave, 0.5));
      // ⚠️ 只量「槽位宽」抓不到真 bug：`Expanded` 给的槽位本来就等宽，而按钮内部视觉盒按内容
      // 宽度排 ⇒ 不传 `expand: true` 时文字会偏向一侧（2026-09-25 用户实测「保存按钮左偏了」）。
      // 因此这里量**文字中心 vs 槽位中心**。
      for (final String label in <String>['保存', '取消']) {
        final Rect slot = tester.getRect(
          find.widgetWithText(AylaGlassButton, label),
        );
        final Rect text = tester.getRect(find.text(label));
        expect(
          text.center.dx,
          closeTo(slot.center.dx, 1.0),
          reason: '「$label」的文字应在等宽槽位里居中（视觉撑满 ⇒ expand: true）',
        );
      }
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(log, <String>['星海观测站|一起看星星']);
    });

    testWidgets('saving ⇒ 文案「保存中…」且键禁用', (WidgetTester tester) async {
      await tester.pumpWidget(host(card(editing: true, saving: true)));
      expect(find.text('保存中…'), findsOneWidget);
      expect(
        tester
            .widget<AylaGlassButton>(
              find.widgetWithText(AylaGlassButton, '保存中…'),
            )
            .onPressed,
        isNull,
      );
    });
  });
}
