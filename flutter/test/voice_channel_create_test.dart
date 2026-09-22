/// B1-3（第一件）：建语音频道表单定向测试 —— 逐条对照
/// `VoiceChannelCreate.tsx`(80) 与 `app.css:2848–2869`、`auroraqua.css:502–531`、
/// `private.css:229–236`。
///
/// 覆盖：结构 / 初始可见性（一级 vs 群内）/ 输入属性（hint·13px·min-height 36·64 上限
/// 且**无计数器**）/ Enter 提交 / 空名拦截 / 成功（清空 + onCreated）/ 失败（文案 + 保留表单）/
/// 未知异常兜底 / 防重入与 busy / 多选→单值映射 / sheet 作用域宽度 / 错误行样式 / 群列表透传 /
/// 错误不随输入自动清除。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show LengthLimitingTextInputFormatter, TextInputAction;
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/visibility.dart';
import '../lib/theme/glass.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/directory_controls.dart';
import '../lib/widgets/voice_channel_create.dart';

void main() {
  const List<({String id, String title})> groups = <({String id, String title})>[
    (id: 'g1', title: '冰樱研究社'),
    (id: 'g2', title: '深夜电台'),
  ];

  Widget host(Widget child, {Size viewport = const Size(420, 620)}) {
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

  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  AylaVisibilitySelector selector(WidgetTester tester) =>
      tester.widget<AylaVisibilitySelector>(
        find.byType(AylaVisibilitySelector),
      );

  /// 本表单的名称输入框。
  ///
  /// ⚠️ `AylaVisibilitySelector` 的**群搜索框也复用了 `GlassInput`**
  /// （`directory_controls.dart:970`，且只在「指定群可见」勾选时渲染）
  /// ⇒ 按类型取会命中两个；这里按 hint 唯一锁定。
  Finder nameInput() => find.byWidgetPredicate(
        (Widget w) => w is GlassInput && w.hintText == '新语音频道名称',
      );

  GlassInput input(WidgetTester tester) => tester.widget<GlassInput>(nameInput());

  Finder nameField() => find.descendant(
        of: nameInput(),
        matching: find.byType(TextField),
      );

  GlassButton submitButton(WidgetTester tester) =>
      tester.widget<GlassButton>(find.byType(GlassButton));

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  // ======================= 结构与初始值 =======================

  testWidgets('结构：可见性选择器 → 名称输入 → 建频道按钮（tsx 56–78）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(420, 620));
    await tester.pumpWidget(host(const AylaVoiceChannelCreate(groups: groups)));

    expect(find.byType(AylaVisibilitySelector), findsOneWidget);
    expect(nameInput(), findsOneWidget);
    expect(find.text('建频道'), findsOneWidget);
    // 顺序：选择器在上、输入居中、按钮在下
    final double selectorTop = tester.getRect(find.byType(AylaVisibilitySelector)).top;
    final double inputTop = tester.getRect(nameInput()).top;
    final double buttonTop = tester.getRect(find.text('建频道')).top;
    expect(selectorTop, lessThan(inputTop));
    expect(inputTop, lessThan(buttonTop));
  });

  testWidgets('初始可见性：一级创建 → 公开 + 无白名单群（tsx 20）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(420, 620));
    await tester.pumpWidget(host(const AylaVoiceChannelCreate(groups: groups)));

    final AylaVisibilitySelector s = selector(tester);
    expect(s.value.isPublic, isTrue);
    expect(s.value.friends, isFalse);
    expect(s.value.group, isFalse);
    expect(s.selectedGroupIds, isEmpty);
    expect(s.lockGroup, isFalse);
    expect(s.initialGroupId, isNull);
  });

  testWidgets('初始可见性：群内创建 → 群可见 + 本群 + 锁定（tsx 20–22 / 58）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(420, 620));
    await tester.pumpWidget(
      host(const AylaVoiceChannelCreate(groupId: 'g1', groups: groups)),
    );

    final AylaVisibilitySelector s = selector(tester);
    expect(s.value.group, isTrue);
    expect(s.value.isPublic, isFalse);
    expect(s.selectedGroupIds, <String>['g1']);
    expect(s.lockGroup, isTrue); // `lockGroup={!!group}`
    expect(s.initialGroupId, 'g1');
  });

  testWidgets('输入属性：hint「新语音频道名称」/ min-height 36 / 13px / 无计数器 64 上限',
      (WidgetTester tester) async {
    setViewport(tester, const Size(420, 620));
    await tester.pumpWidget(host(const AylaVoiceChannelCreate(groups: groups)));

    final GlassInput field = input(tester);
    expect(field.hintText, '新语音频道名称');
    expect(field.minHeight, 36);
    expect(field.textStyle!.fontSize, 13);
    expect(
      field.padding,
      const EdgeInsets.symmetric(horizontal: AylaSpacing.sp3, vertical: 8),
    );
    // tsx 63 `maxLength={64}`：用 formatter 表达 —— `maxLength` 会带「0/64」计数器（web 没有）
    expect(field.maxLength, isNull);
    expect(field.inputFormatters!.length, 1);
    expect(field.inputFormatters!.first, isA<LengthLimitingTextInputFormatter>());

    // 真输入 70 字符 → 截到 64
    await tester.enterText(nameField(), 'x' * 70);
    await tester.pump();
    expect(
      tester.widget<TextField>(nameField()).controller!.text.length,
      64,
    );
    // 且**没有**计数器文案
    expect(find.textContaining('/64'), findsNothing);
    expect(find.textContaining('70'), findsNothing);
  });

  testWidgets('sheet 作用域宽度：输入与按钮都是整宽（private.css 229–236）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(420, 620));
    await tester.pumpWidget(host(const AylaVoiceChannelCreate(groups: groups)));

    expect(submitButton(tester).expand, isTrue); // `.btn-primary { width: 100% }`
    final double available = 420 - AylaSpacing.sp4 * 2; // host padding 两侧
    expect(tester.getRect(nameInput()).width, available);
    expect(tester.getRect(find.byType(GlassButton)).width, available); // 按钮同样整宽
  });

  // ======================= 提交路径 =======================

  testWidgets('空名：显示「频道名称不能为空」且**不发请求**（tsx 29–33）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(420, 620));
    int submits = 0;
    await tester.pumpWidget(
      host(
        AylaVoiceChannelCreate(
          groups: groups,
          onSubmit: (_) async => submits++,
        ),
      ),
    );

    await tester.tap(find.text('建频道'));
    await settle(tester);

    expect(find.text(AylaVoiceChannelCreate.emptyNameError), findsOneWidget);
    expect(submits, 0);
  });

  testWidgets('Enter 提交（tsx 65–67）', (WidgetTester tester) async {
    setViewport(tester, const Size(420, 620));
    int submits = 0;
    await tester.pumpWidget(
      host(
        AylaVoiceChannelCreate(
          groups: groups,
          onSubmit: (_) async => submits++,
        ),
      ),
    );
    await tester.tap(nameField());
    await tester.enterText(nameField(), '深夜电台');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(submits, 1);
  });

  testWidgets('成功：请求体（trim + 单值可见性 + 群 id）· 清空输入 · onCreated · 清错误',
      (WidgetTester tester) async {
    setViewport(tester, const Size(420, 620));
    final List<AylaVoiceChannelCreateRequest> requests =
        <AylaVoiceChannelCreateRequest>[];
    int created = 0;
    await tester.pumpWidget(
      host(
        AylaVoiceChannelCreate(
          groupId: 'g1',
          groups: groups,
          onSubmit: (AylaVoiceChannelCreateRequest r) async => requests.add(r),
          onCreated: () => created++,
        ),
      ),
    );

    // 先制造一次错误，再成功 → 错误应被清掉
    await tester.tap(find.text('建频道'));
    await settle(tester);
    expect(find.text(AylaVoiceChannelCreate.emptyNameError), findsOneWidget);

    await tester.enterText(nameField(), '  深夜电台  ');
    await tester.pump();
    await tester.tap(find.text('建频道'));
    await settle(tester);

    expect(requests.length, 1);
    expect(requests.single.name, '深夜电台'); // trim（tsx 29）
    expect(requests.single.visibility, AylaPostVisibility.group); // 群内默认群可见
    expect(requests.single.allowedGroupIds, <String>['g1']);
    expect(
      tester.widget<TextField>(nameField()).controller!.text,
      isEmpty, // tsx 46：成功才清空
    );
    expect(created, 1);
    expect(find.text(AylaVoiceChannelCreate.emptyNameError), findsNothing);
  });

  testWidgets('失败：显示异常文案 + **保留输入** + 不回调 onCreated（tsx 48–53）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(420, 620));
    int created = 0;
    await tester.pumpWidget(
      host(
        AylaVoiceChannelCreate(
          groups: groups,
          onSubmit: (_) async => throw const AylaVoiceChannelCreateException('同名频道已存在'),
          onCreated: () => created++,
        ),
      ),
    );
    await tester.enterText(nameField(), '深夜电台');
    await tester.pump();
    await tester.tap(find.text('建频道'));
    await settle(tester);

    expect(find.text('同名频道已存在'), findsOneWidget);
    expect(
      tester.widget<TextField>(nameField()).controller!.text,
      '深夜电台', // 表单保留
    );
    expect(created, 0);

    // 错误行样式：12px + --destructive（app.css 2866–2869）
    final Text error = tester.widget<Text>(find.text('同名频道已存在'));
    expect(error.style!.fontSize, 12);
    expect(error.style!.color, AylaColors.destructive);
  });

  testWidgets('未知异常 → 兜底「创建失败」（tsx 49）', (WidgetTester tester) async {
    setViewport(tester, const Size(420, 620));
    await tester.pumpWidget(
      host(
        AylaVoiceChannelCreate(
          groups: groups,
          onSubmit: (_) async => throw StateError('boom'),
        ),
      ),
    );
    await tester.enterText(nameField(), '深夜电台');
    await tester.pump();
    await tester.tap(find.text('建频道'));
    await settle(tester);
    expect(find.text(AylaVoiceChannelCreate.fallbackError), findsOneWidget);
  });

  testWidgets('错误不随输入自动清除（web 只在下次提交时 setError(null)）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(420, 620));
    await tester.pumpWidget(host(const AylaVoiceChannelCreate(groups: groups)));
    await tester.tap(find.text('建频道'));
    await settle(tester);
    expect(find.text(AylaVoiceChannelCreate.emptyNameError), findsOneWidget);

    await tester.enterText(nameField(), '深夜电台');
    await tester.pump();
    expect(find.text(AylaVoiceChannelCreate.emptyNameError), findsOneWidget);
  });

  testWidgets('防重入：提交进行中按钮禁用且重复点击只发一次（tsx 24/28/70）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(420, 620));
    final Completer<void> gate = Completer<void>();
    int submits = 0;
    await tester.pumpWidget(
      host(
        AylaVoiceChannelCreate(
          groups: groups,
          onSubmit: (_) async {
            submits++;
            await gate.future;
          },
        ),
      ),
    );
    await tester.enterText(nameField(), '深夜电台');
    await tester.pump();
    await tester.tap(find.text('建频道'));
    await tester.pump();

    expect(submits, 1);
    expect(submitButton(tester).onPressed, isNull); // busy → disabled
    await tester.tap(find.text('建频道'), warnIfMissed: false);
    await tester.pump();
    expect(submits, 1); // 重复点击被守卫吃掉

    gate.complete();
    await settle(tester);
    expect(submitButton(tester).onPressed, isNotNull);
  });

  // ======================= 可见性映射与透传 =======================

  testWidgets('多选→单值映射：公开优先、其次好友、否则群（tsx 39）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(420, 620));
    final List<AylaVoiceChannelCreateRequest> requests =
        <AylaVoiceChannelCreateRequest>[];
    await tester.pumpWidget(
      host(
        AylaVoiceChannelCreate(
          groups: groups,
          onSubmit: (AylaVoiceChannelCreateRequest r) async => requests.add(r),
        ),
      ),
    );

    // ① 默认公开
    await tester.enterText(nameField(), 'a');
    await tester.pump();
    await tester.tap(find.text('建频道'));
    await settle(tester);
    expect(requests.last.visibility, AylaPostVisibility.public);
  });

  testWidgets('多选→单值：勾「好友」后单值为 friends（互斥由选择器保证）',
      (WidgetTester tester) async {
    setViewport(tester, const Size(420, 620));
    final List<AylaVoiceChannelCreateRequest> requests =
        <AylaVoiceChannelCreateRequest>[];
    await tester.pumpWidget(
      host(
        AylaVoiceChannelCreate(
          groups: groups,
          onSubmit: (AylaVoiceChannelCreateRequest r) async => requests.add(r),
        ),
      ),
    );
    // 先取消「公开」，再勾「好友可见」（web 文案：公开 / 好友可见 / 指定群可见）
    await tester.tap(find.text('公开'));
    await tester.pump();
    await tester.tap(find.text('好友可见'));
    await tester.pump();
    await tester.enterText(nameField(), 'a');
    await tester.pump();
    await tester.tap(find.text('建频道'));
    await settle(tester);
    expect(requests.last.visibility, AylaPostVisibility.friends);
    expect(requests.last.allowedGroupIds, isEmpty);
  });

  testWidgets('群列表与加载态透传给选择器（页面层注入）', (WidgetTester tester) async {
    setViewport(tester, const Size(420, 620));
    await tester.pumpWidget(
      host(
        const AylaVoiceChannelCreate(
          groups: groups,
          groupsLoading: true,
        ),
      ),
    );
    final AylaVisibilitySelector s = selector(tester);
    expect(s.groups, groups);
    expect(s.groupsLoading, isTrue);
  });
}
