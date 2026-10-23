/// 窄屏工具行「等分铺满」回归锁（2026-10-24 用户实报）。
///
/// ## 需求原文
/// 「修一下群聊和私聊界面窄屏下方的按钮，要像 web 那样均匀分布」。
///
/// ## 事实源（唯一）
/// `Ayla/web/src/styles/auroraqua.css:456-473` —— `@media (max-width: 900px)`：
/// ```css
/// .composer-tools-narrow, .composer-row > .composer-tools {
///   display: grid;
///   grid-auto-flow: column;
///   grid-auto-columns: minmax(0, 1fr);   /* 每列等宽、可收缩 */
///   gap: var(--sp-2);                    /* 8 */
///   padding: 0;
/// }
/// .composer-tools-narrow > .composer-tool-btn, … {
///   width: 100%; min-width: 0; height: 40px;
/// }
/// ```
/// 块注释原文：「One column per actual tool: four in groups, three in private chat.」
///
/// 容器内距：窄屏 `.composer { padding: var(--sp-2) var(--sp-3) var(--sp-3) }`
/// （`app.css:3206-3209`）⇒ 工具行左右各 **12**。
///
/// ## 修复前的缺陷
/// Flutter 用 `Padding(sp1=4) + Row(spaceBetween)` + 固定 40px 钮 ⇒
/// 375 档按钮间巨缝 61、900 档 236，与 web 的「等分铺满」完全不同
/// （用户看到的就是「不居中 / 不均匀」）。
///
/// ## 覆盖
/// ① 群聊 4 键（含表情）：等宽 + 首尾贴齐容器内距 + 相邻间距恒 8；
/// ② 私聊 3 键（无表情）：笔数跟着实际按钮数走（web `grid-auto-flow: column`）；
/// ③ 窄屏最高档 768 仍成立（不只在最小屏对）；
/// ④ 宽屏档不受影响（仍为 40px 固定钮 + sp2 间距）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/media/media_picker.dart' show AylaPickResult;
import '../lib/theme/app_theme.dart';
import '../lib/theme/tokens.dart';
import '../lib/widgets/chat/message_input.dart';

/// 窄屏 `.composer` 的左右内距（`app.css:3206-3209` 的 `var(--sp-3)`）。
const double kComposerPadX = AylaSpacing.sp3;

/// 工具行 gap（`auroraqua.css:463` 的 `var(--sp-2)`）。
const double kToolGap = AylaSpacing.sp2;

Future<void> _pump(
  WidgetTester tester,
  Size size, {
  required bool narrow,
  required bool groupLike,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    MaterialApp(
      theme: buildAylaTheme(),
      home: Scaffold(
        body: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            AylaMessageInput(
              narrow: narrow,
              onSubmit: (_) {},
              // 群聊有表情键、私聊没有（web `tsx:559-571` 的 `isGroup &&`）。
              showEmojiButton: groupLike,
              emojiPanel: groupLike ? const SizedBox(height: 100) : null,
              pickImages: () async => const AylaPickResult(),
              pickFile: () async => const AylaPickResult(),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

List<Rect> _toolRects(WidgetTester tester) {
  final Finder tools = find.byWidgetPredicate(
    (Widget x) => x.runtimeType.toString() == 'AylaToolButton',
  );
  return <Rect>[
    for (int i = 0; i < tools.evaluate().length; i += 1)
      tester.getRect(tools.at(i)),
  ];
}

void main() {
  group('① 群聊 4 键：等分铺满', () {
    testWidgets('375 宽：列宽 = (可用宽 − gap×3) / 4，首尾贴齐内距', (
      WidgetTester tester,
    ) async {
      const Size size = Size(375, 800);
      await _pump(tester, size, narrow: true, groupLike: true);

      final List<Rect> rects = _toolRects(tester);
      expect(rects.length, 4, reason: '群聊 = 图片/语音/表情/文件四键');

      final double usable = size.width - kComposerPadX * 2 - kToolGap * 3;
      final double expectedCol = usable / 4;

      for (int i = 0; i < rects.length; i += 1) {
        expect(
          rects[i].width,
          moreOrLessEquals(expectedCol, epsilon: 0.01),
          reason: '第 ${i + 1} 键宽度必须 = 等分列宽（web minmax(0,1fr)）',
        );
        expect(rects[i].height, 40, reason: '高度恒 40（web width:100%/height:40px）');
      }

      // 首尾贴齐容器内距
      expect(rects.first.left, moreOrLessEquals(kComposerPadX, epsilon: 0.01),
          reason: '首键左边 = .composer 左内距 12');
      expect(rects.last.right, moreOrLessEquals(size.width - kComposerPadX, epsilon: 0.01),
          reason: '末键右边 = .composer 右内距 12（铺满整行）');

      // 相邻间距恒为 gap 8
      for (int i = 1; i < rects.length; i += 1) {
        expect(
          rects[i].left - rects[i - 1].right,
          moreOrLessEquals(kToolGap, epsilon: 0.01),
          reason: '第 ${i}、「${i + 1}」键之间的间距 = var(--sp-2) 8',
        );
      }
    });
  });

  group('② 私聊 3 键：笔数跟随实际按钮', () {
    testWidgets('375 宽：列宽 = (可用宽 − gap×2) / 3', (WidgetTester tester) async {
      const Size size = Size(375, 800);
      await _pump(tester, size, narrow: true, groupLike: false);

      final List<Rect> rects = _toolRects(tester);
      expect(rects.length, 3, reason: '私聊 = 图片/语音/文件三键（无表情包）');

      final double usable = size.width - kComposerPadX * 2 - kToolGap * 2;
      final double expectedCol = usable / 3;

      for (final Rect r in rects) {
        expect(r.width, moreOrLessEquals(expectedCol, epsilon: 0.01));
      }
      expect(rects.first.left, moreOrLessEquals(kComposerPadX, epsilon: 0.01));
      expect(rects.last.right,
          moreOrLessEquals(size.width - kComposerPadX, epsilon: 0.01));
    });
  });

  group('③ 窄屏最高档 768 仍成立', () {
    testWidgets('768 宽：仍等分、无巨缝', (WidgetTester tester) async {
      const Size size = Size(768, 800);
      await _pump(tester, size, narrow: true, groupLike: true);

      final List<Rect> rects = _toolRects(tester);
      final double usable = size.width - kComposerPadX * 2 - kToolGap * 3;
      final double expectedCol = usable / 4;
      for (final Rect r in rects) {
        expect(r.width, moreOrLessEquals(expectedCol, epsilon: 0.01));
        // 修复前这里的间距是 236px —— 锁死「不再出现巨缝」。
        expect(r.width, greaterThan(100),
            reason: '宽档窄屏下按钮应明显宽于 40（修复前固定 40 造成巨缝）');
      }
      expect(rects.last.right,
          moreOrLessEquals(size.width - kComposerPadX, epsilon: 0.01));
    });
  });

  group('④ 宽屏档不受影响', () {
    testWidgets('1440 宽：仍是 40px 固定钮 + sp2 间距（不参与等分）', (
      WidgetTester tester,
    ) async {
      const Size size = Size(1440, 900);
      await _pump(tester, size, narrow: false, groupLike: true);

      final List<Rect> rects = _toolRects(tester);
      expect(rects.length, 4);
      for (final Rect r in rects) {
        expect(r.width, 40, reason: '宽屏 `.composer-tool-btn { width: 40px }`');
        expect(r.height, 40);
      }
      // 宽屏是输入框左侧的一排，间距 sp2
      for (int i = 1; i < rects.length; i += 1) {
        expect(rects[i].left - rects[i - 1].right,
            moreOrLessEquals(kToolGap, epsilon: 0.01));
      }
    });
  });
}
