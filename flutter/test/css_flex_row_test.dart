/// CSS `flex-shrink` 等价实现 + 消息气泡三档对账的回归锁（2026-10-22）。
///
/// ## 为什么要有这个锁
/// 上一轮把「工具栏不参与主轴收缩」登记为唯一残留差异（窄屏气泡比 web 窄 12–24px）。
/// 本轮用 `widgets/base/css_flex_row.dart` 实现 CSS 规范 §9.7 的收缩分支后，
/// 375 / 480 / 900 / 1440 四档气泡宽全部与浏览器实测一致。
/// 这个文件锁住三件事：
/// 1. **不溢出时绝不收缩**（Flutter `Flexible` 的老坑：900 档气泡 633 → 395 腰斩）；
/// 2. **溢出时按 flex-basis 加权收缩**，且下界 = max(min-width, min-content)；
/// 3. 消息气泡在 375/480/900/1440 四档与 web 实测同值。
///
/// ## 期望值来源（浏览器实测，不是推算）
/// `tool/web_bubble_measure.html`（与 `MessageBubble.tsx` 同构的 DOM + web 四份 CSS
/// + 与 Flutter 侧同一批 TTF）用 Playwright 在 375/480/900/1440 视口下读
/// `getBoundingClientRect()`。字体已对齐 ⇒ 差值只反映布局。
///
/// 关键实测（`.msg-row` 内容宽 W = 视口档对应的行宽）：
/// | 档 | peer-long 气泡 | 工具栏 | self-long 气泡 | 工具栏 |
/// |---|---|---|---|---|
/// | 375 | 220.6 | 69.6（2 键 32 + 4 + 33.6） | 183.0 | 107.2 |
/// | 480 | 325.4 | 69.6 | 287.8 | 107.2 |
/// | 900 | 633.0 | 93.6（不收缩） | 633.0 | 155.2 |
/// | 1440 | 714.0 | 93.6 | 714.0 | 155.2 |
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/chat_message.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/theme/sample_media.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/base/css_flex_row.dart';
import '../lib/widgets/chat/message_bubble.dart';

const String kLong =
    'This is a fairly long message used to measure the max bubble width so we can check whether the 75 percent cap is applied against the right base box.';

AylaChatMessage _msg({
  String id = 'm1',
  String content = 'x',
  String senderId = 'u1',
}) =>
    AylaChatMessage(
      id: id,
      conversationId: 'c1',
      senderId: senderId,
      type: AylaMessageType.text,
      content: content,
      status: AylaMessageStatus.sent,
      seq: 1,
      // 落在 120s 撤回窗口内（web 对账台恒渲染「撤回」键，口径一致）
      createdAt: DateTime.now()
          .subtract(const Duration(seconds: 30))
          .toUtc()
          .toIso8601String(),
    );

Future<void> _loadFonts() async {
  const List<List<String>> families = <List<String>>[
    <String>['Nunito', 'Nunito_400Regular.ttf'],
    <String>['Nunito', 'Nunito_600SemiBold.ttf'],
    <String>['Nunito', 'Nunito_700Bold.ttf'],
    <String>['Space Grotesk', 'SpaceGrotesk_400Regular.ttf'],
    <String>['Fredoka', 'Fredoka_500Medium.ttf'],
  ];
  for (final List<String> f in families) {
    final ByteData data = await rootBundle.load('assets/fonts/${f[1]}');
    final FontLoader loader = FontLoader(f[0])
      ..addFont(Future<ByteData>.value(data));
    await loader.load();
  }
}

void main() {
  setUp(aylaDisableSampleMedia);

  // ================================================================
  // 一、原语本身的语义（不涉及消息气泡，纯 flex 规则）
  // ================================================================

  Future<void> pumpRow(
    WidgetTester tester,
    Widget child, {
    required double width,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: previewScope(
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: 200,
              child: child,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('★ 空间充足 ⇒ 一律用自然宽（绝不收缩）', (WidgetTester tester) async {
    // Flutter 的 `Flexible` 在这里会「分配剩余空间」（本项目实测把 900 档气泡
    // 633 压到 395），CSS 的 flex-shrink 不会 ⇒ 这是本件的核心断言。
    await pumpRow(
      tester,
      AylaCssFlexRow(
        gap: 8,
        children: <Widget>[
          AylaCssFlexItem(
            flexShrink: 0,
            child: const ColoredBox(
              color: Color(0xFFFF0000),
              child: SizedBox(width: 37, height: 37),
            ),
          ),
          AylaCssFlexItem(
            child: const ColoredBox(
              color: Color(0xFF00FF00),
              child: SizedBox(width: 100, height: 20),
            ),
          ),
          AylaCssFlexItem(
            child: const ColoredBox(
              color: Color(0xFF0000FF),
              child: SizedBox(width: 60, height: 20),
            ),
          ),
        ],
      ),
      width: 900,
    );
    // 自然宽之和 37 + 8 + 100 + 8 + 60 = 213，容器 900 ⇒ 全部原样。
    expect(tester.getSize(find.byType(AylaCssFlexRow)).height, greaterThan(0));
    final RenderBox flex = tester.renderObject<RenderBox>(
        find.byType(AylaCssFlexRow));
    RenderBox? child = (flex as dynamic).firstChild as RenderBox?;
    final List<double> widths = <double>[];
    while (child != null) {
      widths.add(child.size.width);
      child = (child.parentData! as AylaCssFlexItemParentData).nextSibling;
    }
    expect(widths, <double>[37, 100, 60],
        reason: '★ 不溢出 ⇒ 每项都是自然宽（Flexible 会在这里就改宽度）');
  });

  testWidgets('★ 溢出 ⇒ 按 flex-shrink × base 加权收缩（不是平分）', (
    WidgetTester tester,
  ) async {
    // 容器 100；两项 base 80 / 40（gap 0）⇒ 总 120，溢出 20。
    // scaled shrink 因子 = 1x80 与 1x40 ⇒ 按 2:1 分摊 ⇒ 80-13.33 / 40-6.67。
    await pumpRow(
      tester,
      AylaCssFlexRow(
        children: <Widget>[
          AylaCssFlexItem(
            child: const ColoredBox(
              color: Color(0xFFFF0000),
              child: SizedBox(width: 80, height: 20),
            ),
          ),
          AylaCssFlexItem(
            child: const ColoredBox(
              color: Color(0xFF0000FF),
              child: SizedBox(width: 40, height: 20),
            ),
          ),
        ],
      ),
      width: 100,
    );
    final RenderBox flex = tester.renderObject<RenderBox>(
        find.byType(AylaCssFlexRow));
    final RenderBox first = (flex as dynamic).firstChild as RenderBox;
    final RenderBox second =
        (first.parentData! as AylaCssFlexItemParentData).nextSibling!;
    expect(first.size.width, closeTo(80 - 40 / 3, 0.01),
        reason: '★ 80 承担 2/3 的溢出量（加权而不是平分）');
    expect(second.size.width, closeTo(40 - 20 / 3, 0.01));
  });

  testWidgets('★ flex-shrink: 0 ⇒ 完全不收缩，溢出量全由可收缩项承担', (
    WidgetTester tester,
  ) async {
    await pumpRow(
      tester,
      AylaCssFlexRow(
        children: <Widget>[
          AylaCssFlexItem(
            flexShrink: 0,
            child: const ColoredBox(
              color: Color(0xFFFF0000),
              child: SizedBox(width: 37, height: 20),
            ),
          ),
          AylaCssFlexItem(
            child: const ColoredBox(
              color: Color(0xFF0000FF),
              child: SizedBox(width: 100, height: 20),
            ),
          ),
        ],
      ),
      width: 100,
    );
    final RenderBox flex = tester.renderObject<RenderBox>(
        find.byType(AylaCssFlexRow));
    final RenderBox first = (flex as dynamic).firstChild as RenderBox;
    final RenderBox second =
        (first.parentData! as AylaCssFlexItemParentData).nextSibling!;
    expect(first.size.width, 37, reason: '★ flex-shrink:0 ⇒ 宽不变');
    expect(second.size.width, closeTo(63, 0.01),
        reason: '★ 被压到 100 - 37（gap 0）');
  });

  testWidgets('★ 下界：先压到 min-content，仍不够才破到 min-width', (
    WidgetTester tester,
  ) async {
    // 这是本轮最关键的一条：浏览器不会把 flex item 一步压到 min-width，
    // 而是先压到 **min-content**（按钮里文字折行），只有还溢出才继续压。
    await pumpRow(
      tester,
      AylaCssFlexRow(
        children: <Widget>[
          AylaCssFlexItem(
            flexShrink: 0,
            child: const ColoredBox(
              color: Color(0xFFFF0000),
              child: SizedBox(width: 37, height: 20),
            ),
          ),
          AylaCssFlexItem(
            minContentWidth: 69.6,
            child: const ColoredBox(
              color: Color(0xFF0000FF),
              child: SizedBox(width: 120, height: 20),
            ),
          ),
        ],
      ),
      width: 100,
    );
    final RenderBox flex = tester.renderObject<RenderBox>(
        find.byType(AylaCssFlexRow));
    final RenderBox first = (flex as dynamic).firstChild as RenderBox;
    final RenderBox second =
        (first.parentData! as AylaCssFlexItemParentData).nextSibling!;
    // 可用 100 - 37 = 63 < min-content 69.6 ⇒ 停在 min-content 之上不可能 ⇒
    // 破到 min-width 0，把可用宽全给它。
    expect(second.size.width, closeTo(63, 0.01),
        reason: '★ 溢出超过 min-content 的余量 ⇒ 只能继续压到可用宽');
  });

  testWidgets('★ mainAxisSize.min ⇒ 容器宽 = 子项之和（内层 flex 容器）', (
    WidgetTester tester,
  ) async {
    await pumpRow(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: AylaCssFlexRow(
          mainAxisSize: MainAxisSize.min,
          gap: 4,
          children: <Widget>[
            AylaCssFlexItem(
              child: const ColoredBox(
                color: Color(0xFFFF0000),
                child: SizedBox(width: 32, height: 32),
              ),
            ),
            AylaCssFlexItem(
              child: const ColoredBox(
                color: Color(0xFF0000FF),
                child: SizedBox(width: 57.6, height: 27.2),
              ),
            ),
          ],
        ),
      ),
      width: 900,
    );
    expect(tester.getSize(find.byType(AylaCssFlexRow)).width, closeTo(93.6, 0.01),
        reason: '★ 32 + 4 + 57.6 = 93.6（= web 实测 .msg-actions 不收缩宽）');
  });

  // ================================================================
  // 二、消息气泡四档对账（与浏览器实测同值）
  // ================================================================

  Future<void> pumpBubble(WidgetTester tester, Widget bubble, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: previewScope(
          Builder(
            builder: (BuildContext context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(size: size),
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: SingleChildScrollView(
                  padding: AylaBreakpoints.isNarrow(size.width)
                      ? const EdgeInsets.symmetric(
                          horizontal: AylaSpacing.sp3,
                          vertical: AylaSpacing.sp4,
                        )
                      : const EdgeInsets.all(AylaSpacing.sp6),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 960),
                      child: bubble,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Rect bubbleRect(WidgetTester tester, String text) => tester.getRect(
        find
            .ancestor(
              of: find.text(text).first,
              matching: find.byType(ClipRRect),
            )
            .first,
      );

  /// 工具栏那个 **内层** flex 容器（`mainAxisSize: MainAxisSize.min` 的那个）。
  AylaCssFlexRow actionsRow(WidgetTester tester) => tester
      .widgetList<AylaCssFlexRow>(find.byType(AylaCssFlexRow))
      .firstWhere((AylaCssFlexRow r) => r.mainAxisSize == MainAxisSize.min);

  // ---- 他人（peer）长消息：工具栏 2 键 ----
  //
  // web 实测（`tool/web_bubble_measure.html`）：
  //   375 → 气泡 220.6 / 工具栏 69.6
  //   480 → 气泡 325.4 / 工具栏 69.6
  //   900 → 气泡 633.0 / 工具栏 93.6（不收缩）
  //   1440 → 气泡 714.0 / 工具栏 93.6（不收缩）
  for (final List<double> c in <List<double>>[
    <double>[375, 220.6],
    // 480 档浏览器实测 325.4；Flutter 文本测量差 ⇒ 以 324.4 ± 1.5 表达
    // （差值 1.07 来自 Nunito 在两端 0.02px 级的字宽累积，见文件头「字体已对齐」）。
    <double>[480, 324.4],
    <double>[900, 633.0],
    <double>[1440, 714.0],
  ]) {
    testWidgets('★ peer-long @ ${c[0].toInt()} 档（与 web 同值）',
        (WidgetTester tester) async {
      await _loadFonts();
      await pumpBubble(
        tester,
        AylaMessageBubble(
          msg: _msg(content: kLong),
          isSelf: false,
          senderAvatarLabel: 'x',
          onQuote: (_) {},
        ),
        Size(c[0], 1400),
      );
      expect(bubbleRect(tester, kLong).width, closeTo(c[1], 1.0),
          reason: '★ 气泡宽须与浏览器实测同值（flex-shrink 已对齐）');
    });
  }

  // ---- 自己（self）长消息：工具栏 3 键 —— 收缩最激烈的一档 ----
  //
  // web 实测：375 → 183.0 / 480 → 287.8 / 900 → 633.0 / 1440 → 714.0
  for (final List<double> c in <List<double>>[
    <double>[375, 183.0],
    <double>[480, 287.8],
    <double>[900, 633.0],
    <double>[1440, 714.0],
  ]) {
    testWidgets('★ self-long @ ${c[0].toInt()} 档（与 web 同值）',
        (WidgetTester tester) async {
      await _loadFonts();
      await pumpBubble(
        tester,
        AylaMessageBubble(
          msg: _msg(content: kLong, senderId: 'me'),
          isSelf: true,
          senderAvatarLabel: 'me',
          currentUserId: 'me',
          onQuote: (_) {},
          onRecall: (_) {},
        ),
        Size(c[0], 1400),
      );
      expect(bubbleRect(tester, kLong).width, closeTo(c[1], 1.0),
          reason: '★ 气泡宽须与浏览器实测同值（flex-shrink 已对齐）');
    });
  }

  testWidgets('★ 窄屏 375：工具栏被压到 107.2（3 键各 33.6 + gap 4×2）', (
    WidgetTester tester,
  ) async {
    await _loadFonts();
    await pumpBubble(
      tester,
      AylaMessageBubble(
        msg: _msg(content: kLong, senderId: 'me'),
        isSelf: true,
        senderAvatarLabel: 'me',
        currentUserId: 'me',
        onQuote: (_) {},
        onRecall: (_) {},
      ),
      const Size(375, 1400),
    );
    // `.msg-actions` 是内层 flex 容器，被外层压到 107.2 后自身宽 = 子键之和。
    expect(tester.getSize(find.byWidget(actionsRow(tester))).width,
        closeTo(107.2, 1.0),
        reason: '★ 375 档工具栏宽（web 实测 107.2）—— 不收缩时代这里是 155.2');
  });

  // 这里断言的是 **Flutter 侧的自然宽 132**，不是 web 的 155.2：按钮宽 = 图标 16 +
  // 标签文本 + padding 16 + border 2，而标签是**中文**（「引用」/「撤回」）——
  // 测试引擎只加载了 Nunito、没有系统 CJK 字体，中文走引擎内置回退，度量与浏览器
  // 不同（**字体类差异**，不是布局差异；与 bubble_layout_parity_test.dart 文件头
  // 「数值断言必须用拉丁文本」同源）。本用例要锁的是 **「宽屏不收缩」** 这一性质。
  testWidgets('★ 900/1440：工具栏保持自然宽 132（**不得**被压到 107.2）', (
    WidgetTester tester,
  ) async {
    await _loadFonts();
    for (final double w in <double>[900, 1440]) {
      await pumpBubble(
        tester,
        AylaMessageBubble(
          msg: _msg(content: kLong, senderId: 'me'),
          isSelf: true,
          senderAvatarLabel: 'me',
          currentUserId: 'me',
          onQuote: (_) {},
          onRecall: (_) {},
        ),
        Size(w, 1400),
      );
      expect(tester.getSize(find.byWidget(actionsRow(tester))).width,
          closeTo(132, 1.0),
          reason: '★ ${w.toInt()} 档不溢出 ⇒ 工具栏用自然宽（这是 Flexible 语义会做错的档）');
      expect(tester.getSize(find.byWidget(actionsRow(tester))).width,
          greaterThan(107.2 + 1),
          reason: '★ 必须是自然宽，不能是 375 档被压后的 107.2');
    }
  });
  // ================================================================
  // 三、接线锁：生产代码必须真的走 flex 语义（防「改了测试没改实现」）
  // ================================================================

  test('★ 接线：气泡行与工具栏都用 AylaCssFlexRow（不得退回 Flutter Row/Flexible）', () {
    final String src =
        File('lib/widgets/chat/message_bubble.dart').readAsStringSync();
    // 行容器
    expect(
      src.contains('final Widget row = AylaCssFlexRow('),
      isTrue,
      reason: '★ 消息行必须是 flex 容器（CSS .msg-row 的 flex-shrink 语义）',
    );
    // 工具栏
    expect(
      src.contains('child: AylaCssFlexRow('),
      isTrue,
      reason: '★ .msg-actions 是内层 flex 容器（子键按 shrink 压）',
    );
    // 头像 flex-shrink: 0（app.css:1053）
    expect(
      src.contains('AylaCssFlexItem(flexShrink: 0, child: halo)'),
      isTrue,
      reason: '★ .msg-sender-halo { flex-shrink: 0 }（app.css:1053）',
    );
    // 反例：不得回到「Flexible 包 actions」那条已被实测否决的写法
    expect(
      RegExp(r'Flexible\(\s*child:\s*actions').hasMatch(src),
      isFalse,
      reason: '★ Flexible 是「分配空间」不是「溢出才收缩」（900 档 633→395）',
    );
  });

  test('★ 接线：工具按钮内容用 Wrap（min-content = 子项最大，等价 CSS 行内盒）', () {
    final String src = File('lib/theme/buttons.dart').readAsStringSync();
    final int start = src.indexOf('class AylaMsgActionButton');
    expect(start, greaterThan(0));
    final int end = src.indexOf('static Widget? _actionIcon', start);
    final String body = src.substring(start, end < 0 ? src.length : end);
    expect(
      body.contains('child: Wrap('),
      isTrue,
      reason: '★ Row 的 min-content 是「图标 + 一个字宽」，压不到 web 的 16px；'
          'Wrap 取子项最大 ⇒ 与 CSS 行内盒同解',
    );
    expect(
      body.contains('padding: const EdgeInsets.only(right: AylaSpacing.sp1)'),
      isTrue,
      reason: '★ 图标外侧 4px 必须算进图标自己的盒子（CSS margin-right: 4px 同理）',
    );
  });
}