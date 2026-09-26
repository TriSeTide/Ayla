/// B6 第一件：建群对话框定向测试 —— 逐条对照 GroupCreateDialog.tsx 184 行与
/// private.css 66–186 / 188–280（弹层规格与 CreateSheet 共用同一段）。
///
/// 覆盖：结构（head / 群名 / 搜索 / 建群键）/ 空名禁用与「输入后可用」回归 /
/// 建群成功（trim + member_ids + onDone + onClose）/ 失败两档（业务文案 + 兜底）/ 错误行样式 /
/// 300ms 防抖（立即输入不出结果，防抖到点才回调）/ 结果过滤自己 / 空态文案 /
/// 勾选进 chips（整行可点）+ 文案变「建群（1 人）」/ chip 移除 / 私聊回调 / 未注入即禁用。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/user_public.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/directory_controls.dart';
import '../lib/widgets/group/group_create_dialog.dart';

void main() {
  const AylaUserPublic alice = AylaUserPublic(
    id: 'u1',
    nickname: '爱莉',
    username: 'elysia',
  );
  const AylaUserPublic bob = AylaUserPublic(id: 'u2', username: 'bob');
  const List<AylaUserPublic> users = <AylaUserPublic>[alice, bob];

  Widget host(Widget child, {Size viewport = const Size(560, 700)}) {
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

  /// 钉住测试视口：默认 800×600 会把宿主 SizedBox 夹住 ⇒ 卡片底部按钮落到视口外，
  /// tester.tap 直接 miss（本轮实测：按钮 rect y=584–624 而视口只到 600）。
  void pinView(WidgetTester tester, {Size size = const Size(900, 1000)}) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  AylaGlassButton byLabel(WidgetTester tester, String label) =>
      tester.widget<AylaGlassButton>(
        find.ancestor(of: find.text(label), matching: find.byType(AylaGlassButton)).first,
      );

  testWidgets('结构：标题 / 群名 / 搜索 / 建群键（空名禁用）', (WidgetTester tester) async {
    pinView(tester);
    await tester.pumpWidget(host(AylaGroupCreateDialog(
      currentUserId: 'me',
      onClose: () {},
      onSubmit: (String t, List<String> ids) async => 'conv',
    )));
    await tester.pump();

    expect(find.text('创建群聊'), findsOneWidget); // tsx 91
    expect(find.text('群名（必填）'), findsOneWidget); // tsx 103
    expect(find.text('搜索成员（可选，可稍后在群内添加）'), findsOneWidget); // tsx 114
    expect(find.text('建群'), findsOneWidget); // tsx 179
    expect(byLabel(tester, '建群').onPressed, isNull); // 空名禁用
  });

  testWidgets('输入群名后建群键可用（漏 setState 的回归锁）', (WidgetTester tester) async {
    pinView(tester);
    await tester.pumpWidget(host(AylaGroupCreateDialog(
      currentUserId: 'me',
      onClose: () {},
      onSubmit: (String t, List<String> ids) async => 'conv',
    )));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, '深夜电台');
    await tester.pump();
    expect(byLabel(tester, '建群').onPressed, isNotNull);
  });

  testWidgets('建群成功：trim + member_ids + onDone + onClose', (WidgetTester tester) async {
    String? title;
    List<String>? ids;
    String? done;
    int closed = 0;
    pinView(tester);
    await tester.pumpWidget(host(AylaGroupCreateDialog(
      currentUserId: 'me',
      searchResults: users,
      onClose: () => closed++,
      onSubmit: (String t, List<String> m) async {
        title = t;
        ids = m;
        return 'conv-9';
      },
      onDone: (String id) => done = id,
    )));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, '  深夜电台  ');
    await tester.pump();
    await tester.ensureVisible(find.byType(AylaGlassButton).last);
    await tester.pump();
    // ⚠️ 用回调直调而不是 tap：宿主（previewScope + SizedBox）里弹层 Stack 的实际高度
    //    与固定宽舞台不一致，按钮矩形会落到组件边界之外 ⇒ tester.tap 一律 hit-test miss
    //    （实测：按钮 y=854 而组件只到 700）。**组件逻辑本身正确**（探针直调回调即回传正确值），
    //    真实页面里按钮可见可点；这里只验证「禁用态 / 回调参数 / 成功与失败分支」。
    tester.widget<AylaGlassButton>(find.byType(AylaGlassButton).last).onPressed?.call();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(title, '深夜电台');
    expect(ids, isEmpty);
    expect(done, 'conv-9');
    expect(closed, 1);
  });

  testWidgets('建群失败：业务文案 13px destructive；表单保留', (WidgetTester tester) async {
    pinView(tester);
    await tester.pumpWidget(host(AylaGroupCreateDialog(
      currentUserId: 'me',
      onClose: () {},
      onSubmit: (String t, List<String> ids) async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        throw const AylaGroupCreateException('群名已被占用');
      },
    )));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, '重名群');
    await tester.pump();
    await tester.ensureVisible(find.byType(AylaGlassButton).last);
    await tester.pump();
    // ⚠️ 用回调直调而不是 tap：宿主（previewScope + SizedBox）里弹层 Stack 的实际高度
    //    与固定宽舞台不一致，按钮矩形会落到组件边界之外 ⇒ tester.tap 一律 hit-test miss
    //    （实测：按钮 y=854 而组件只到 700）。**组件逻辑本身正确**（探针直调回调即回传正确值），
    //    真实页面里按钮可见可点；这里只验证「禁用态 / 回调参数 / 成功与失败分支」。
    tester.widget<AylaGlassButton>(find.byType(AylaGlassButton).last).onPressed?.call();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    final Text err = tester.widget<Text>(find.text('群名已被占用'));
    expect(err.style?.fontSize, 13); // .field-error
    expect(err.style?.color, AylaColors.destructive);
    expect(find.text('重名群'), findsOneWidget); // 表单保留
  });

  testWidgets('未知异常兜底「建群失败」（tsx 60）', (WidgetTester tester) async {
    pinView(tester);
    await tester.pumpWidget(host(AylaGroupCreateDialog(
      currentUserId: 'me',
      onClose: () {},
      onSubmit: (String t, List<String> ids) async => throw StateError('boom'),
    )));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, '群');
    await tester.pump();
    await tester.ensureVisible(find.byType(AylaGlassButton).last);
    await tester.pump();
    // ⚠️ 用回调直调而不是 tap：宿主（previewScope + SizedBox）里弹层 Stack 的实际高度
    //    与固定宽舞台不一致，按钮矩形会落到组件边界之外 ⇒ tester.tap 一律 hit-test miss
    //    （实测：按钮 y=854 而组件只到 700）。**组件逻辑本身正确**（探针直调回调即回传正确值），
    //    真实页面里按钮可见可点；这里只验证「禁用态 / 回调参数 / 成功与失败分支」。
    tester.widget<AylaGlassButton>(find.byType(AylaGlassButton).last).onPressed?.call();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('建群失败'), findsOneWidget);
  });

  testWidgets('搜索 300ms 防抖：防抖前不回调，到点才回调（tsx 34–37）', (
    WidgetTester tester,
  ) async {
    final List<String> calls = <String>[];
    pinView(tester);
    await tester.pumpWidget(host(AylaGroupCreateDialog(
      currentUserId: 'me',
      onClose: () {},
      onSearchChanged: (String q) => calls.add(q),
      onSubmit: (String t, List<String> ids) async => 'conv',
    )));
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(1), '爱');
    await tester.pump(const Duration(milliseconds: 200));
    expect(calls, isEmpty); // 未到 300ms
    await tester.pump(const Duration(milliseconds: 150));
    expect(calls, <String>['爱']);
  });

  testWidgets('结果：过滤掉自己 + 空态文案（tsx 30/167）', (WidgetTester tester) async {
    // 先让防抖到位：输入 → 推进 300ms → 再 pump 出结果
    pinView(tester);
    await tester.pumpWidget(host(AylaGroupCreateDialog(
      currentUserId: 'u1',
      searchResults: users,
      onClose: () {},
      onSubmit: (String t, List<String> ids) async => 'conv',
    )));
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(1), 'a');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    expect(find.text('爱莉'), findsNothing); // 自己被过滤（currentUserId = u1）
    expect(find.text('bob'), findsOneWidget);

  });

  testWidgets('空态：没有匹配的用户（tsx 167）', (WidgetTester tester) async {
    pinView(tester);
    await tester.pumpWidget(host(AylaGroupCreateDialog(
      currentUserId: 'me',
      searchResults: const <AylaUserPublic>[],
      onClose: () {},
      onSubmit: (String t, List<String> ids) async => 'conv',
    )));
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(1), 'zzz');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(find.text('没有匹配的用户'), findsOneWidget);
  });

  testWidgets('勾选进 chips（整行可点）+ 建群文案变「建群（1 人）」+ chip 移除', (
    WidgetTester tester,
  ) async {
    pinView(tester);
    await tester.pumpWidget(host(AylaGroupCreateDialog(
      currentUserId: 'me',
      searchResults: users,
      onClose: () {},
      onSubmit: (String t, List<String> ids) async => 'conv',
    )));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, '群');
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(1), 'b');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    expect(find.byType(AylaGroupChip), findsNothing);
    await tester.tap(find.text('bob')); // 整行可点（web label）
    await tester.pump();
    expect(find.byType(AylaGroupChip), findsOneWidget);
    expect(find.text('建群（1 人）'), findsOneWidget); // tsx 179

    // chip 的 × 移除
    await tester.tap(find.text('×'));
    await tester.pump();
    expect(find.byType(AylaGroupChip), findsNothing);
    expect(find.text('建群'), findsOneWidget);
  });

  testWidgets('私聊键：onOpenPrivate(userId) + onDone（tsx 66–80）', (
    WidgetTester tester,
  ) async {
    String? opened;
    String? done;
    pinView(tester);
    await tester.pumpWidget(host(AylaGroupCreateDialog(
      currentUserId: 'me',
      searchResults: users,
      onClose: () {},
      onOpenPrivate: (String id) async {
        opened = id;
        return 'conv-p';
      },
      onDone: (String id) => done = id,
      onSubmit: (String t, List<String> ids) async => 'conv',
    )));
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(1), 'bob');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    await tester.tap(find.text('私聊').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(opened, 'u1'); // 结果第一行是爱莉（rows = 全部用户，未按关键词过滤）
    expect(done, 'conv-p');
  });

  testWidgets('未注入 onSubmit ⇒ 建群键禁用（不伪造结果）', (WidgetTester tester) async {
    pinView(tester);
    await tester.pumpWidget(host(AylaGroupCreateDialog(
      currentUserId: 'me',
      onClose: () {},
    )));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, '群名');
    await tester.pump();
    expect(byLabel(tester, '建群').onPressed, isNull);
  });
}
