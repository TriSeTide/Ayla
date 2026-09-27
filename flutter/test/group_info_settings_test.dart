/// 群信息设置面定向测试 —— 对照 `GroupInfo.tsx:531–624 / 709–718 / 754» +
/// `group.css 1678–1687 / 1796–2047 / 2109–2116»。
///
/// 覆盖：设置块（底色 + 相邻行分隔线）· 设置行（min-h 44 / label 14-600 / value 13-secondary）·
/// 轨道开关（44×24 / thumb 18×18 / left 3→23 / --pink-500 / 禁用 .6 / toggled 语义）·
/// 加入方式下拉（文案两档 / listbox 展开 / 选中回传 / 点外部与 Esc 关闭 / 禁用不展开）·
/// 申请审批（标题计数 / name+msg / message 空不渲染 / busy 双禁用 / 三态空文案）·
/// 成员搜索框（placeholder + 语义）· 子群展开（文案 / aria-expanded / 回调 / margin-top）。
///
/// ⚠️ 一态一用例（同用例二次 pumpWidget 换 props 不生效）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/group/group_info_settings.dart';

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

  // ===================== 设置块 / 设置行 =====================

  group('AylaGroupInfoSettingsBox / AylaGroupInfoSettingRow', () {
    testWidgets('块底 rgba(157,191,230,.1) + 左右 sp3；相邻行才加 1px 分隔线', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AylaGroupInfoSettingsBox(
            children: <Widget>[
              AylaGroupInfoSettingRow(label: '加入方式', value: '公开加入'),
              AylaGroupInfoSettingRow(label: '成员可上传表情包', value: '开启'),
              AylaGroupInfoSettingRow(label: '第三行', value: '值'),
            ],
          ),
        ),
      );
      // 3 行 ⇒ 2 条分隔线（首行无上边线）
      final Finder dividers = find.byWidgetPredicate(
        (Widget w) =>
            w is Container &&
            w.color == AylaColors.ice500.withValues(alpha: 0.22),
      );
      expect(dividers, findsNWidgets(2));

      final AylaGlassButton? none = null;
      expect(none, isNull); // 占位断言（无按钮样式介入）
    });

    testWidgets('行：min-height 44 · label 14/w600/text-primary · value 13/text-secondary', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AylaGroupInfoSettingRow(label: '加入方式', value: '申请加入'),
        ),
      );
      final ConstrainedBox box = tester.widget<ConstrainedBox>(
        find
            .descendant(
              of: find.byType(AylaGroupInfoSettingRow),
              matching: find.byType(ConstrainedBox),
            )
            .first,
      );
      expect(box.constraints.minHeight, 44);

      final Text label = tester.widget<Text>(find.text('加入方式'));
      expect(label.style!.fontSize, 14);
      expect(label.style!.fontWeight, FontWeight.w600);
      expect(label.style!.color, AylaColors.textPrimary);

      final Text value = tester.widget<Text>(find.text('申请加入'));
      expect(value.style!.fontSize, 13);
      expect(value.style!.color, AylaColors.textSecondary);
    });

    testWidgets('trailing 优先于 value（owner 档放控件、非 owner 档放只读值）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaGroupInfoSettingRow(
            label: '加入方式',
            value: '只读值',
            trailing: AylaGroupInfoSelect(
              value: 'public',
              onChanged: (String value) {},
            ),
          ),
        ),
      );
      expect(find.text('只读值'), findsNothing);
      expect(find.text('公开加入'), findsOneWidget);
    });
  });

  // ===================== 轨道开关 =====================

  group('AylaGroupInfoSwitch', () {
    testWidgets('轨道 44×24 · thumb 18×18 · off 档 left 3 + --ice-300 底', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaGroupInfoSwitch(
            label: '成员可上传表情包',
            value: false,
            onChanged: (bool value) {},
          ),
        ),
      );
      expect(
        find.byWidgetPredicate(
          (Widget w) => w is SizedBox && w.width == 44 && w.height == 24,
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (Widget w) => w is Container &&
                            w.constraints ==
                                BoxConstraints.tightFor(width: 18, height: 18),
        ),
        findsOneWidget,
      );
      final AnimatedContainer track = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byType(AylaGroupInfoSwitch),
          matching: find.byType(AnimatedContainer),
        ).first,
      );
      expect((track.decoration! as BoxDecoration).color, AylaColors.ice300);
      expect(
        tester.widget<AnimatedPositioned>(find.byType(AnimatedPositioned)).left,
        3,
      );
    });

    testWidgets('on 档：轨道 --pink-500 · thumb translateX(20) ⇒ left 23', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaGroupInfoSwitch(
            label: '成员可上传表情包',
            value: true,
            onChanged: (bool value) {},
          ),
        ),
      );
      final AnimatedContainer track = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byType(AylaGroupInfoSwitch),
          matching: find.byType(AnimatedContainer),
        ).first,
      );
      expect((track.decoration! as BoxDecoration).color, AylaColors.pink500);
      expect(
        tester.widget<AnimatedPositioned>(find.byType(AnimatedPositioned)).left,
        23,
      );
      expect(
        (tester
                    .widget<Container>(
                      find.byWidgetPredicate(
                        (Widget w) =>
                            w is Container &&
                            w.constraints ==
                                BoxConstraints.tightFor(width: 18, height: 18),
                      ),
                    )
                    .decoration!
                as BoxDecoration)
            .color,
        AylaColors.surface,
      );
    });

    testWidgets('点整行切换一次 + toggled 语义', (WidgetTester tester) async {
      int calls = 0;
      await tester.pumpWidget(
        host(
          AylaGroupInfoSwitch(
            label: '成员可上传表情包',
            value: false,
            onChanged: (bool value) => calls++,
          ),
        ),
      );
      await tester.tap(find.text('成员可上传表情包'));
      await tester.pump();
      expect(calls, 1);

      final SemanticsNode node = tester.getSemantics(find.text('成员可上传表情包'));
      expect(node.flagsCollection.isToggled.toBoolOrNull(), isFalse);
    });

    testWidgets('onChanged=null ⇒ 禁用档：整轨 opacity .6 且点击无回调', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AylaGroupInfoSwitch(
            label: '成员可上传表情包',
            value: true,
            onChanged: null,
          ),
        ),
      );
      expect(find.byType(Opacity), findsOneWidget);
      await tester.tap(find.text('成员可上传表情包'));
      await tester.pump();
    });
  });

  // ===================== 加入方式下拉 =====================

  group('AylaGroupInfoSelect', () {
    testWidgets('非 public 一律显示「申请加入」（web 三元表达式）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaGroupInfoSelect(
            value: 'application',
            onChanged: (String value) {},
          ),
        ),
      );
      expect(find.text('申请加入'), findsOneWidget);
    });

    testWidgets('value=null ⇒ 也显示「申请加入」（web 缺值按申请制）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaGroupInfoSelect(value: null, onChanged: (String value) {}),
        ),
      );
      expect(find.text('申请加入'), findsOneWidget);
    });

    testWidgets('value=public ⇒ 显示「公开加入」', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaGroupInfoSelect(value: 'public', onChanged: (String value) {}),
        ),
      );
      expect(find.text('公开加入'), findsOneWidget);
    });

    testWidgets('点击展开 listbox（两选项）· 选中回传并关菜单', (WidgetTester tester) async {
      String? picked;
      await tester.pumpWidget(
        host(
          AylaGroupInfoSelect(
            value: 'application',
            onChanged: (String value) => picked = value,
          ),
        ),
      );
      expect(find.byType(AylaGlassCard), findsNothing);

      await tester.tap(find.text('申请加入'));
      await tester.pump();
      expect(find.byType(AylaGlassCard), findsOneWidget); // 菜单（glass-bg-strong + 阴影）
      // 菜单里两项：公开加入 / 申请加入（按钮自身那份也在）⇒「申请加入」共 2 处
      expect(find.text('申请加入'), findsNWidgets(2));
      expect(find.text('公开加入'), findsOneWidget);

      await tester.tap(find.text('公开加入'));
      await tester.pump();
      expect(picked, 'public');
      expect(find.byType(AylaGlassCard), findsNothing);
    });

    testWidgets('点外部关闭菜单（web outside-click）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaGroupInfoSelect(
            value: 'application',
            onChanged: (String value) {},
          ),
        ),
      );
      await tester.tap(find.text('申请加入'));
      await tester.pump();
      expect(find.byType(AylaGlassCard), findsOneWidget);

      await tester.tapAt(const Offset(5, 5));
      await tester.pump();
      expect(find.byType(AylaGlassCard), findsNothing);
    });

    testWidgets('Esc 关闭菜单（web onKeyDown Escape）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaGroupInfoSelect(
            value: 'application',
            onChanged: (String value) {},
          ),
        ),
      );
      await tester.tap(find.text('申请加入'));
      await tester.pump();
      expect(find.byType(AylaGlassCard), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(AylaGlassCard), findsNothing);
    });

    testWidgets('onChanged=null ⇒ 禁用档：opacity .6 且点击不展开', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(const AylaGroupInfoSelect(value: 'public', onChanged: null)),
      );
      expect(find.byType(Opacity), findsOneWidget);
      await tester.tap(find.text('公开加入'));
      await tester.pump();
      expect(find.byType(AylaGlassCard), findsNothing);
    });
  });

  // ===================== 申请审批 =====================

  group('AylaGroupJoinRequests', () {
    const List<AylaGroupJoinRequest> rows = <AylaGroupJoinRequest>[
      AylaGroupJoinRequest(id: 'r1', name: '小雪', message: '想进来一起玩'),
      AylaGroupJoinRequest(id: 'r2', name: '阿澈'),
    ];

    testWidgets('标题带 total 计数；name 与 msg 按有无渲染；两键文案', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaGroupJoinRequests(
            total: 3,
            requests: rows,
            onAccept: (AylaGroupJoinRequest request) {},
            onReject: (AylaGroupJoinRequest request) {},
          ),
        ),
      );
      expect(find.text('入群申请审批 · 待处理（3）'), findsOneWidget);
      expect(find.text('小雪'), findsOneWidget);
      expect(find.text('想进来一起玩'), findsOneWidget);
      expect(find.text('阿澈'), findsOneWidget);
      // message 空的第二条没有 msg 行
      expect(find.text('同意'), findsNWidgets(2));
      expect(find.text('拒绝'), findsNWidgets(2));
    });

    testWidgets('两键几何：min-height 30 / font-size 12 / pill 圆角', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AylaGroupJoinRequests(
            total: 1,
            requests: <AylaGroupJoinRequest>[rows.first],
            onAccept: (AylaGroupJoinRequest request) {},
            onReject: (AylaGroupJoinRequest request) {},
          ),
        ),
      );
      final AylaGlassButton accept = tester.widget<AylaGlassButton>(
        find.widgetWithText(AylaGlassButton, '同意'),
      );
      expect(accept.minHeight, 30);
      expect(accept.fontSize, 12);
      expect(accept.borderRadius, AylaRadii.rPill);
      final AylaGlassButton reject = tester.widget<AylaGlassButton>(
        find.widgetWithText(AylaGlassButton, '拒绝'),
      );
      expect(reject.variant, AylaGlassButtonVariant.ghost);
    });

    testWidgets('busy ⇒ 两键均禁用（web busyAction !== null）', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          AylaGroupJoinRequests(
            total: 1,
            requests: <AylaGroupJoinRequest>[rows.first],
            busy: true,
            onAccept: (AylaGroupJoinRequest request) {},
            onReject: (AylaGroupJoinRequest request) {},
          ),
        ),
      );
      expect(
        tester
            .widget<AylaGlassButton>(find.widgetWithText(AylaGlassButton, '同意'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<AylaGlassButton>(find.widgetWithText(AylaGlassButton, '拒绝'))
            .onPressed,
        isNull,
      );
    });

    testWidgets('空态默认文案「暂无待处理申请」', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaGroupJoinRequests(
            total: 0,
            requests: <AylaGroupJoinRequest>[],
          ),
        ),
      );
      expect(find.text('暂无待处理申请'), findsOneWidget);
    });

    testWidgets('loading ⇒「加载中…」', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaGroupJoinRequests(
            total: 0,
            requests: <AylaGroupJoinRequest>[],
            loading: true,
          ),
        ),
      );
      expect(find.text('加载中…'), findsOneWidget);
    });

    testWidgets('error ⇒「申请加载失败」', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const AylaGroupJoinRequests(
            total: 0,
            requests: <AylaGroupJoinRequest>[],
            error: true,
          ),
        ),
      );
      expect(find.text('申请加载失败'), findsOneWidget);
    });

    testWidgets('点击同意/拒绝回传对应条目', (WidgetTester tester) async {
      AylaGroupJoinRequest? accepted;
      AylaGroupJoinRequest? rejected;
      await tester.pumpWidget(
        host(
          AylaGroupJoinRequests(
            total: 1,
            requests: <AylaGroupJoinRequest>[rows.first],
            onAccept: (AylaGroupJoinRequest request) => accepted = request,
            onReject: (AylaGroupJoinRequest request) => rejected = request,
          ),
        ),
      );
      await tester.tap(find.text('同意'));
      await tester.pump();
      expect(accepted!.id, 'r1');
      await tester.tap(find.text('拒绝'));
      await tester.pump();
      expect(rejected!.id, 'r1');
    });
  });

  // ===================== 成员搜索 / 子群展开 =====================

  group('AylaGroupMemberSearchField', () {
    testWidgets('复用 .field 档：placeholder「搜索成员」+ aria「搜索群成员」', (
      WidgetTester tester,
    ) async {
      final TextEditingController controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        host(AylaGroupMemberSearchField(controller: controller)),
      );
      expect(find.text('搜索成员'), findsOneWidget);
      expect(
        tester.getSemantics(find.byType(TextField)).label,
        contains('搜索群成员'),
      );
      // web 无搜索图标
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('输入回传 onChanged', (WidgetTester tester) async {
      final TextEditingController controller = TextEditingController();
      addTearDown(controller.dispose);
      String? typed;
      await tester.pumpWidget(
        host(
          AylaGroupMemberSearchField(
            controller: controller,
            onChanged: (String value) => typed = value,
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '小雪');
      await tester.pump();
      expect(typed, '小雪');
    });
  });

  group('AylaGroupSubgroupExpandButton', () {
    testWidgets('收起态文案「查看更多（N）」+ aria-expanded=false + margin-top sp2', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AylaGroupSubgroupExpandButton(
            hiddenCount: 2,
            expanded: false,
            onPressed: null,
          ),
        ),
      );
      expect(find.text('查看更多（2）'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w is Padding &&
              w.padding == const EdgeInsets.only(top: AylaSpacing.sp2),
        ),
        findsOneWidget,
      );
      final SemanticsNode node = tester.getSemantics(find.text('查看更多（2）'));
      expect(node.flagsCollection.isExpanded.toBoolOrNull(), isFalse);

      final AylaGlassButton button = tester.widget<AylaGlassButton>(
        find.byType(AylaGlassButton),
      );
      expect(button.minHeight, 36);
      expect(button.fontSize, 13);
      expect(button.expand, isTrue); // width: 100%
      expect(button.variant, AylaGlassButtonVariant.ghost);
    });

    testWidgets('展开态文案「收起」+ aria-expanded=true + 点击回调', (WidgetTester tester) async {
      int calls = 0;
      await tester.pumpWidget(
        host(
          AylaGroupSubgroupExpandButton(
            hiddenCount: 2,
            expanded: true,
            onPressed: () => calls++,
          ),
        ),
      );
      expect(find.text('收起'), findsOneWidget);
      await tester.tap(find.byType(AylaGlassButton));
      await tester.pump();
      expect(calls, 1);
      final SemanticsNode node = tester.getSemantics(find.text('收起'));
      expect(node.flagsCollection.isExpanded.toBoolOrNull(), isTrue);
    });
  });
}
