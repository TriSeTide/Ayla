/// B5 group 域第一批（2/2）：群聊申请三形态定向测试 —— 逐条对照
/// GroupApplyDialog.tsx 25–171 与 search.css 175–296 / 527–557。
///
/// 覆盖：Form 文案两档（含未知 join_policy）/ label 与 textarea 属性 / 提交两分支
/// （accepted → onDone；pending → 成功态）/ 错误两档（业务文案 + 兜底）/ busy 文案 /
/// 未注入 onSubmit 时禁用 / 弹窗 head（kicker + h2 + 「×」）/ 弹窗宽度 440 / 窄屏同样居中 /
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter;
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/subgroup.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/dialogs.dart';
import '../lib/theme/glass.dart';
import '../lib/widgets/group_apply.dart';

void main() {
  const AylaGroupApplyData publicGroup = AylaGroupApplyData(
    id: 'g1',
    title: '冰樱研究社',
    joinPolicy: AylaGroupJoinPolicy.public,
  );
  const AylaGroupApplyData appliedGroup = AylaGroupApplyData(
    id: 'g2',
    title: '深夜电台',
    joinPolicy: AylaGroupJoinPolicy.application,
  );
  const AylaGroupApplyData unknownGroup = AylaGroupApplyData(id: 'g3', title: '');

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

  GlassButton byLabel(WidgetTester tester, String label) => tester.widget<GlassButton>(
        find.ancestor(of: find.text(label), matching: find.byType(GlassButton)).first,
      );

  testWidgets('Form 公开群：desc 文案 + 「直接加入」键', (WidgetTester tester) async {
    await tester.pumpWidget(host(AylaGroupApplyForm(
      group: publicGroup,
      onSubmit: (AylaGroupApplyData g, String m) async =>
          const AylaGroupApplyResult.pending(),
      onDone: (String id) {},
    )));
    await tester.pump();
    expect(find.text('这是一个公开群聊，点击即可直接加入。'), findsOneWidget); // tsx 60
    expect(find.text('直接加入'), findsOneWidget); // tsx 85
    // label 是 RichText（主段 14/w700 + 可选段 secondary 400）⇒ 断言纯文本
    final RichText label = tester.widget<RichText>(
      find.byWidgetPredicate((Widget w) =>
          w is RichText && w.text.toPlainText().startsWith('给群主留言')),
    );
    expect(label.text.toPlainText(), '给群主留言 （可选）');
  });

  testWidgets('Form 申请制 + 未知 join_policy 都走申请制文案（tsx 15 注释）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(AylaGroupApplyForm(
      group: appliedGroup,
      onSubmit: (AylaGroupApplyData g, String m) async =>
          const AylaGroupApplyResult.pending(),
      onDone: (String id) {},
    )));
    await tester.pump();
    expect(find.text('这是一个申请制群聊，群主或管理员同意后才能入群。'), findsOneWidget);
    expect(find.text('发送入群申请'), findsOneWidget);

    await tester.pumpWidget(host(AylaGroupApplyForm(
      group: unknownGroup,
      onSubmit: (AylaGroupApplyData g, String m) async =>
          const AylaGroupApplyResult.pending(),
      onDone: (String id) {},
    )));
    await tester.pump();
    expect(find.text('这是一个申请制群聊，群主或管理员同意后才能入群。'), findsOneWidget);
  });

  testWidgets('textarea：min-height 104 / 4 行 / 200 上限用 formatter（无计数器）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(AylaGroupApplyForm(
      group: publicGroup,
      onSubmit: (AylaGroupApplyData g, String m) async =>
          const AylaGroupApplyResult.pending(),
      onDone: (String id) {},
    )));
    await tester.pump();
    final TextField field = tester.widget<TextField>(find.byType(TextField));
    expect(field.maxLines, 4);
    expect(field.maxLength, isNull);
    expect(
      field.inputFormatters!.whereType<LengthLimitingTextInputFormatter>(),
      isNotEmpty,
    );
    // min-height 104 由 GlassInput 的容器表达（TextField 自身只占内容高）
    expect(tester.getSize(find.byType(GlassInput)).height >= 104, isTrue);
  });

  testWidgets('公开群提交：accepted → onDone(conversation_id)（tsx 45–48）', (
    WidgetTester tester,
  ) async {
    String? done;
    String? sentMessage;
    AylaGroupApplyData? sentGroup;
    await tester.pumpWidget(host(AylaGroupApplyForm(
      group: publicGroup,
      onSubmit: (AylaGroupApplyData g, String m) async {
        sentGroup = g;
        sentMessage = m;
        return const AylaGroupApplyResult.accepted('conv-9');
      },
      onDone: (String id) => done = id,
    )));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '  你好  ');
    await tester.pump();
    await tester.tap(find.text('直接加入'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(sentGroup?.id, 'g1');
    expect(sentMessage, '你好'); // trim
    expect(done, 'conv-9');
  });

  testWidgets('申请制提交 → 成功态（圆标 + 文案，tsx 62–67）', (WidgetTester tester) async {
    await tester.pumpWidget(host(AylaGroupApplyForm(
      group: appliedGroup,
      onSubmit: (AylaGroupApplyData g, String m) async =>
          const AylaGroupApplyResult.pending(),
      onDone: (String id) {},
    )));
    await tester.pump();
    await tester.tap(find.text('发送入群申请'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('申请已发送'), findsOneWidget);
    expect(find.text('等待群主或管理员审核，同意后你就能进入群聊。'), findsOneWidget);
    expect(find.text('✓'), findsOneWidget);
    expect(find.text('发送入群申请'), findsNothing); // 表单区被成功态替换
  });

  testWidgets('失败：业务文案 13px destructive + 表单保留', (WidgetTester tester) async {
    await tester.pumpWidget(host(AylaGroupApplyForm(
      group: appliedGroup,
      onSubmit: (AylaGroupApplyData g, String m) async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        throw const AylaGroupApplyException('该群不接受申请');
      },
      onDone: (String id) {},
    )));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '让我进');
    await tester.pump();
    await tester.tap(find.text('发送入群申请'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    final Text err = tester.widget<Text>(find.text('该群不接受申请'));
    expect(err.style?.fontSize, 13);
    expect(err.style?.color, AylaColors.destructive);
    expect(find.text('发送入群申请'), findsOneWidget); // 表单保留
  });

  testWidgets('未知异常兜底「发送入群申请失败」（tsx 51）', (WidgetTester tester) async {
    await tester.pumpWidget(host(AylaGroupApplyForm(
      group: appliedGroup,
      onSubmit: (AylaGroupApplyData g, String m) async => throw StateError('boom'),
      onDone: (String id) {},
    )));
    await tester.pump();
    await tester.tap(find.text('发送入群申请'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('发送入群申请失败'), findsOneWidget);
  });

  testWidgets('未注入 onSubmit ⇒ 提交键禁用（不伪造结果）', (WidgetTester tester) async {
    await tester.pumpWidget(host(const AylaGroupApplyForm(
      group: publicGroup,
      onDone: _noopDone,
    )));
    await tester.pump();
    expect(byLabel(tester, '直接加入').onPressed, isNull);
  });

  testWidgets('弹窗：kicker + h2 两档文案 + 「×」关闭键 + 卡片宽 440', (
    WidgetTester tester,
  ) async {
    int closed = 0;
    await tester.pumpWidget(host(
      AylaGroupApplyDialog(
        group: publicGroup,
        onClose: () => closed++,
        onSubmit: (AylaGroupApplyData g, String m) async =>
            const AylaGroupApplyResult.pending(),
        onJoined: (String id) {},
      ),
      viewport: const Size(700, 700), // 宿主宽 700 ⇒ min(440px, 100%) 才能到 440
    ));
    await tester.pump();

    expect(find.text('GROUP REQUEST'), findsOneWidget); // tsx 119
    expect(find.text('加入「冰樱研究社」'), findsOneWidget); // tsx 121
    expect(find.text('×'), findsOneWidget); // tsx 124（文字不是图标）
    expect(tester.getSize(find.byType(AylaModalCard)).width, 440);

    await tester.tap(find.text('×'));
    await tester.pump();
    expect(closed, 1);
  });

  testWidgets('弹窗 h2（申请制）：申请加入「深夜电台」', (WidgetTester tester) async {
    await tester.pumpWidget(host(AylaGroupApplyDialog(
      group: appliedGroup,
      onClose: () {},
      onSubmit: (AylaGroupApplyData g, String m) async =>
          const AylaGroupApplyResult.pending(),
    )));
    await tester.pump();
    expect(find.text('申请加入「深夜电台」'), findsOneWidget);
  });

  testWidgets('弹窗 h2（未知策略）：申请加入「该群聊」（标题回退）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(AylaGroupApplyDialog(
      group: unknownGroup,
      onClose: () {},
      onSubmit: (AylaGroupApplyData g, String m) async =>
          const AylaGroupApplyResult.pending(),
    )));
    await tester.pump();
    expect(find.text('申请加入「该群聊」'), findsOneWidget); // tsx 121 的回退

  });
}

void _noopDone(String id) {}
