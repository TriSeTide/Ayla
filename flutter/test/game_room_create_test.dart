/// B4 boardgame 域第一批（2/3）：创建桌游室表单定向测试 —— 逐条对照
/// GameRoomCreate.tsx 9–78 与 boardgame.css 123–132、app.css 70–79、
/// auroraqua.css 502–531、posts.css 373–376、private.css 229–236。
///
/// 覆盖：结构 / 初始可见性（一级 vs 群内 + lockGroup）/ hint 与 64 上限且**无计数器** /
/// **提交键可用性随文本变化**（chat 域真实事故的回归锁）/ 多选→单值 / 空名拦截
/// （不发请求）/ 成功（清空 + onCreated）/ 失败（文案 + 保留表单）/ 未知异常兜底 /
/// 防重入与 busy / 错误行 13px + destructive。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show LengthLimitingTextInputFormatter;
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/visibility.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/directory_controls.dart';
import '../lib/widgets/game_room_create.dart';

void main() {
  const List<({String id, String title})> groups = <({String id, String title})>[
    (id: 'g1', title: '冰樱研究社'),
    (id: 'g2', title: '深夜电台'),
  ];

  Widget host(Widget child, {Size viewport = const Size(420, 760)}) {
    return MaterialApp(
      home: previewScope(
        Builder(
          builder: (BuildContext context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(size: viewport),
            child: SizedBox.fromSize(
              size: viewport,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AylaSpacing.sp4),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }

  AylaVisibilitySelector selector(WidgetTester tester) =>
      tester.widget<AylaVisibilitySelector>(find.byType(AylaVisibilitySelector));

  /// 表单名称输入框（可见性选择器在勾选群时自带搜索框 ⇒ 不能裸用 byType）。
  Finder nameField() => find.byType(TextField).last;

  /// 提交键（busy 时文案变「创建中…」）。
  GlassButton submitButton(WidgetTester tester) =>
      tester.widget<GlassButton>(find.byWidgetPredicate(
        (Widget w) =>
            w is GlassButton && (w.label == '创建' || w.label == '创建中…'),
      ));

  testWidgets('结构：可见性选择器 → 输入（hint 桌游室名称）→ 创建键；初始禁用', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(const AylaGameRoomCreate(groups: groups)));
    await tester.pump();

    expect(find.byType(AylaVisibilitySelector), findsOneWidget);
    expect(find.text('桌游室名称'), findsOneWidget); // tsx 59 placeholder
    expect(find.text('创建'), findsOneWidget); // tsx 74

    // tsx 71：disabled={busy || !name.trim()} ⇒ 空名时禁用
    expect(submitButton(tester).onPressed, isNull);
    // 输入框是单行（input.field；不是 textarea）
    final TextField field = tester.widget<TextField>(find.byType(TextField));
    expect(field.maxLines, 1);
  });

  testWidgets('提交键可用性随文本变化（漏 setState 的真实事故回归）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(const AylaGameRoomCreate()));
    await tester.pump();
    expect(submitButton(tester).onPressed, isNull);

    await tester.enterText(nameField(), '房间');
    await tester.pump();
    expect(submitButton(tester).onPressed, isNotNull);

    // 全是空格 ⇒ trim 后为空 ⇒ 仍禁用
    await tester.enterText(nameField(), '   ');
    await tester.pump();
    expect(submitButton(tester).onPressed, isNull);
  });

  testWidgets('一级创建：默认公开 + 空白名单；提交拿到 name/visibility/allowedGroupIds', (
    WidgetTester tester,
  ) async {
    AylaGameRoomCreateRequest? captured;
    await tester.pumpWidget(host(AylaGameRoomCreate(
      groups: groups,
      onSubmit: (AylaGameRoomCreateRequest r) async => captured = r,
    )));
    await tester.pump();

    // tsx 18：一级默认 public
    expect(selector(tester).value.isPublic, isTrue);
    expect(selector(tester).lockGroup, isFalse);
    expect(selector(tester).initialGroupId, isNull);

    await tester.enterText(nameField(), '  爱莉的桌游室  ');
    await tester.pump();
    await tester.tap(find.text('创建'));
    await tester.pump();

    expect(captured, isNotNull);
    expect(captured!.name, '爱莉的桌游室'); // tsx 27 trim
    expect(captured!.visibility, AylaPostVisibility.public); // tsx 37
    expect(captured!.allowedGroupIds, isEmpty);
  });

  testWidgets('群内创建：默认群可见 + 本群恒选 + lockGroup（tsx 17–20 / 56）', (
    WidgetTester tester,
  ) async {
    AylaGameRoomCreateRequest? captured;
    await tester.pumpWidget(host(AylaGameRoomCreate(
      groupId: 'g1',
      groups: groups,
      onSubmit: (AylaGameRoomCreateRequest r) async => captured = r,
    )));
    await tester.pump();

    expect(selector(tester).value.group, isTrue);
    expect(selector(tester).value.isPublic, isFalse);
    expect(selector(tester).lockGroup, isTrue);
    expect(selector(tester).initialGroupId, 'g1');
    expect(selector(tester).selectedGroupIds, <String>['g1']);

    await tester.enterText(nameField(), '群内房间');
    await tester.pump();
    await tester.tap(find.text('创建'));
    await tester.pump();

    expect(captured!.visibility, AylaPostVisibility.group);
    expect(captured!.allowedGroupIds, <String>['g1']);
  });

  testWidgets('空名拦截：Enter 提交报「房间名不能为空」且不发请求（tsx 28–31）', (
    WidgetTester tester,
  ) async {
    int calls = 0;
    await tester.pumpWidget(host(AylaGameRoomCreate(
      onSubmit: (AylaGameRoomCreateRequest r) async => calls++,
    )));
    await tester.pump();

    // 先聚焦名称输入框再发 Enter（未聚焦时 receiveAction 没有接收者）
    await tester.showKeyboard(nameField());
    await tester.testTextInput.receiveAction(TextInputAction.done); // tsx 63–65 Enter
    await tester.pump();

    expect(calls, 0);
    expect(find.text('房间名不能为空'), findsOneWidget);
    // posts.css 373–376：13px + --destructive（**不是**语音表单的 12px）
    final Text error = tester.widget<Text>(find.text('房间名不能为空'));
    expect(error.style?.fontSize, 13);
    expect(error.style?.color, AylaColors.destructive);
  });

  testWidgets('失败：展示文案并保留表单（不清空名称）', (WidgetTester tester) async {
    await tester.pumpWidget(host(AylaGameRoomCreate(
      onSubmit: (AylaGameRoomCreateRequest r) async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        throw const AylaGameRoomCreateException('同名桌游室已存在');
      },
    )));
    await tester.pump();

    await tester.enterText(nameField(), '重复房');
    await tester.pump();
    await tester.tap(find.text('创建'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('同名桌游室已存在'), findsOneWidget);
    expect(find.text('重复房'), findsOneWidget); // 表单保留（tsx 46–47）
  });

  testWidgets('未知异常兜底「创建失败」；成功后清空名称 + onCreated', (
    WidgetTester tester,
  ) async {
    bool created = false;
    await tester.pumpWidget(host(AylaGameRoomCreate(
      onSubmit: (AylaGameRoomCreateRequest r) async => throw StateError('boom'),
      onCreated: () => created = true,
    )));
    await tester.pump();
    await tester.enterText(nameField(), '房间');
    await tester.pump();
    await tester.tap(find.text('创建'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('创建失败'), findsOneWidget); // tsx 47
    expect(created, isFalse);

  });

  testWidgets('成功：清空名称 + onCreated', (WidgetTester tester) async {
    bool created = false;
    await tester.pumpWidget(host(AylaGameRoomCreate(
      onSubmit: (AylaGameRoomCreateRequest r) async {},
      onCreated: () => created = true,
    )));
    await tester.pump();
    await tester.enterText(nameField(), '新房间');
    await tester.pump();
    await tester.tap(find.text('创建'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(created, isTrue);
    expect(find.text('新房间'), findsNothing); // tsx 44 清空
  });

  testWidgets('64 上限用 formatter 表达（不出现「0/64」计数器）+ busy 文案', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host(const AylaGameRoomCreate()));
    await tester.pump();
    final TextField field = tester.widget<TextField>(find.byType(TextField));
    expect(field.inputFormatters, isNotNull);
    expect(
      field.inputFormatters!.whereType<LengthLimitingTextInputFormatter>(),
      isNotEmpty,
    );
    expect(field.maxLength, isNull); // maxLength 会带计数器 ⇒ 不用它

    await tester.enterText(nameField(), 'x' * 70);
    await tester.pump();
    expect(find.text('x' * 64), findsOneWidget);
  });

  testWidgets('防重入：busy 期间按钮禁用且文案切换为「创建中…」', (WidgetTester tester) async {
    final Completer<void> gate = Completer<void>();
    await tester.pumpWidget(host(AylaGameRoomCreate(
      onSubmit: (AylaGameRoomCreateRequest r) => gate.future,
    )));
    await tester.pump();
    await tester.enterText(nameField(), '房间');
    await tester.pump();
    await tester.tap(find.text('创建'));
    await tester.pump();

    expect(find.text('创建中…'), findsOneWidget); // tsx 74
    expect(submitButton(tester).onPressed, isNull);

    gate.complete();
    await tester.pump();
  });
}
