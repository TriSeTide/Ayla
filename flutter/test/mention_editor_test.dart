/// B3 chat 第三批：@ 编辑器与草稿块定向测试 —— 对照
/// `Ayla/web/src/utils/mention.ts`（210 行）与 `MessageInput.tsx` 的 @ 路径。
///
/// 覆盖：六个纯函数（blocksText / hasMention / toSegments / serialize / parse / detect）
/// + 控制器（插入替换 `@query`、长按头像路径插入、blocks → 文本 → blocks 往返、
/// **整块删除**、占位符索引随文本迁移、胶囊 WidgetSpan 渲染）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models/chat_message.dart';
import '../lib/core/models/mention.dart';
import '../lib/theme/preview_theme.dart';
import '../lib/widgets/chat/mention_editor.dart';

void main() {
  // ======================= 纯函数（utils/mention.ts） =======================

  group('草稿块纯函数（mention.ts:13–59）', () {
    test('blocksText：仅文本块拼接（mention 不进 content）', () {
      final List<AylaDraftBlock> blocks = <AylaDraftBlock>[
        const AylaDraftBlock.text('你好 '),
        const AylaDraftBlock.mention(userId: 'u1', name: '小樱'),
        const AylaDraftBlock.text(' 在吗'),
      ];
      expect(aylaBlocksText(blocks), '你好  在吗');
      expect(aylaBlocksHasMention(blocks), isTrue);
      expect(aylaBlocksHasMention(const <AylaDraftBlock>[AylaDraftBlock.text('x')]), isFalse);
    });

    test('blocksToSegments：text/mention 段交错（媒体段由调用方追加尾部）', () {
      final List<AylaMediaSegment> segs = aylaBlocksToSegments(<AylaDraftBlock>[
        const AylaDraftBlock.text('hi '),
        const AylaDraftBlock.mention(userId: 'u2', name: '阿澈'),
      ]);
      expect(segs.length, 2);
      expect(segs[0].type, AylaSegmentType.text);
      expect(segs[0].text, 'hi ');
      expect(segs[1].type, AylaSegmentType.mention);
      expect(segs[1].userId, 'u2');
      expect(segs[1].name, '阿澈');
    });

    test('serialize/parse 往返（`@[user_id]`；查不到名字回退「未知用户」）', () {
      final List<AylaDraftBlock> blocks = <AylaDraftBlock>[
        const AylaDraftBlock.text('早 '),
        const AylaDraftBlock.mention(userId: 'u9', name: '汐汐'),
        const AylaDraftBlock.text(' 好'),
      ];
      final String serialized = aylaSerializeBlocks(blocks);
      expect(serialized, '早 @[u9] 好');

      // 名字可解析 → 用解析值
      final List<AylaDraftBlock> parsed =
          aylaParseBlocks(serialized, (String id) => id == 'u9' ? '汐汐' : null);
      expect(parsed.length, 3);
      expect(parsed[1].type, AylaDraftBlockType.mention);
      expect(parsed[1].userId, 'u9');
      expect(parsed[1].name, '汐汐');

      // 查不到 → 「未知用户」（与 web 同口径）
      final List<AylaDraftBlock> unknown = aylaParseBlocks(serialized, (_) => null);
      expect(unknown[1].name, '未知用户');
    });

    test('detectMentionAtCaret：最近的 @ / 空白即失效 / @ 前不要求边界', () {
      // 刚输入 @
      expect(aylaDetectMentionAtCaret('@', 1)?.query, '');
      // 输入中
      expect(aylaDetectMentionAtCaret('你好 @小', 5)?.query, '小');
      // @ 后出现空白 → 失效
      expect(aylaDetectMentionAtCaret('@小 樱', 4), isNull);
      // 无 @
      expect(aylaDetectMentionAtCaret('你好', 2), isNull);
      // 文本中间（@ 前无空白也可触发，tsx 127）
      expect(aylaDetectMentionAtCaret('abc@xy', 6)?.atIndex, 3);
      // 多次 @ → 取最近的
      expect(aylaDetectMentionAtCaret('@a @b', 5)?.atIndex, 3);
      // 光标越界 → null
      expect(aylaDetectMentionAtCaret('ab', 9), isNull);
    });
  });

  // ======================= 控制器 =======================

  group('AylaMentionTextController', () {
    test('insertMention：把 `@query` 换成占位符，光标落到占位符之后', () {
      final AylaMentionTextController c = AylaMentionTextController();
      addTearDown(c.dispose);
      c.value = const TextEditingValue(
        text: '你好 @小',
        selection: TextSelection.collapsed(offset: 5),
      );
      expect(c.insertMention(userId: 'u1', name: '小樱'), isTrue);
      // 文本里 @小 → 一个占位符；其后无残留
      expect(c.text, '你好 ${AylaMentionTextController.placeholder}');
      expect(c.selection.baseOffset, 4, reason: '光标在占位符之后（= @ 位置 + 1）');
      expect(c.spans.length, 1);
      expect(c.spans.first.userId, 'u1');
      expect(c.spans.first.name, '小樱');
      expect(c.spans.first.index, 3);
    });

    test('insertMention：不在 @ 触发态时返回 false（不改文本）', () {
      final AylaMentionTextController c = AylaMentionTextController();
      addTearDown(c.dispose);
      c.value = const TextEditingValue(
        text: '你好',
        selection: TextSelection.collapsed(offset: 2),
      );
      expect(c.insertMention(userId: 'u1', name: '小樱'), isFalse);
      expect(c.text, '你好');
      expect(c.spans, isEmpty);
    });

    test('insertMentionToken：无 @ 前缀，在光标处直接插入（长按头像路径）', () {
      final AylaMentionTextController c = AylaMentionTextController();
      addTearDown(c.dispose);
      c.value = const TextEditingValue(
        text: 'abc',
        selection: TextSelection.collapsed(offset: 1),
      );
      c.insertMentionToken(userId: 'u7', name: '林深');
      expect(c.text, 'a${AylaMentionTextController.placeholder}bc');
      expect(c.spans.single.index, 1);
      expect(c.selection.baseOffset, 2);
    });

    test('extractBlocks / setBlocks 往返（含前后文本与多个 @）', () {
      final AylaMentionTextController c = AylaMentionTextController();
      addTearDown(c.dispose);
      c.setBlocks(<AylaDraftBlock>[
        const AylaDraftBlock.text('早 '),
        const AylaDraftBlock.mention(userId: 'u1', name: '小樱'),
        const AylaDraftBlock.text(' 与 '),
        const AylaDraftBlock.mention(userId: 'u2', name: '阿澈'),
        const AylaDraftBlock.text(' 好'),
      ]);
      final List<AylaDraftBlock> back = c.extractBlocks();
      expect(back.length, 5);
      expect(back[0].text, '早 ');
      expect(back[1].userId, 'u1');
      expect(back[2].text, ' 与 ');
      expect(back[3].userId, 'u2');
      expect(back[4].text, ' 好');
      expect(aylaSerializeBlocks(back), '早 @[u1] 与 @[u2] 好');
    });

    test('整块删除：占位符是单字符 ⇒ 退格即整块消失（web span 的原生语义）', () {
      final AylaMentionTextController c = AylaMentionTextController();
      addTearDown(c.dispose);
      c.setBlocks(<AylaDraftBlock>[
        const AylaDraftBlock.text('hi '),
        const AylaDraftBlock.mention(userId: 'u1', name: '小樱'),
      ]);
      expect(c.spans.length, 1);
      // 模拟在末尾按一次退格（删除占位符这一个字符）
      final String text = c.text;
      final TextEditingValue next = TextEditingValue(
        text: text.substring(0, text.length - 1),
        selection: TextSelection.collapsed(offset: text.length - 1),
      );
      c.value = next;
      expect(c.spans, isEmpty, reason: '占位符被删除 ⇒ span 一并移除');
      expect(c.text, 'hi ');
      expect(c.extractBlocks().length, 1);
    });

    test('占位符索引随文本迁移（在占位符之前插入字符 → index 右移）', () {
      final AylaMentionTextController c = AylaMentionTextController();
      addTearDown(c.dispose);
      c.setBlocks(<AylaDraftBlock>[
        const AylaDraftBlock.text('ab'),
        const AylaDraftBlock.mention(userId: 'u1', name: '小樱'),
      ]);
      expect(c.spans.single.index, 2);
      // 在开头插入 'X'
      c.value = TextEditingValue(
        text: 'X${c.text}',
        selection: const TextSelection.collapsed(offset: 1),
      );
      expect(c.spans.single.index, 3, reason: '前插 1 字符 ⇒ 索引 +1');
      expect(c.extractBlocks().first.text, 'Xab');
    });

    test('占位符之后的文本变化不影响其索引', () {
      final AylaMentionTextController c = AylaMentionTextController();
      addTearDown(c.dispose);
      c.setBlocks(<AylaDraftBlock>[
        const AylaDraftBlock.mention(userId: 'u1', name: '小樱'),
        const AylaDraftBlock.text('尾'),
      ]);
      expect(c.spans.single.index, 0);
      c.value = TextEditingValue(
        text: '${c.text}额外',
        selection: TextSelection.collapsed(offset: c.text.length + 2),
      );
      expect(c.spans.single.index, 0);
      expect(c.extractBlocks().first.userId, 'u1');
    });

    testWidgets('buildTextSpan：占位符渲染成 @名称 胶囊（WidgetSpan）', (WidgetTester tester) async {
      final AylaMentionTextController c = AylaMentionTextController();
      addTearDown(c.dispose);
      c.setBlocks(<AylaDraftBlock>[
        const AylaDraftBlock.text('hi '),
        const AylaDraftBlock.mention(userId: 'u1', name: '小樱'),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: previewTheme(
            Builder(
              builder: (BuildContext context) {
                final TextSpan span = c.buildTextSpan(
                  context: context,
                  style: const TextStyle(fontSize: 15),
                  withComposing: false,
                );
                final List<InlineSpan> children =
                    span.children ?? const <InlineSpan>[];
                // 文本段 + 胶囊段（无尾随空文本）
                expect(children.length, 2);
                expect((children.first as TextSpan).text, 'hi ');
                expect(children.last, isA<WidgetSpan>(), reason: '占位符 → 胶囊');
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
    });

    testWidgets('真实输入框里：输入 @ 触发检测、选中成员后胶囊出现', (WidgetTester tester) async {
      final AylaMentionTextController c = AylaMentionTextController();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: previewTheme(
            MaterialApp(
              home: Scaffold(
                body: TextField(controller: c),
              ),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '@樱');
      await tester.pump();
      expect(c.detectMention()?.query, '樱');
      expect(c.insertMention(userId: 'u1', name: '小樱'), isTrue);
      await tester.pump();
      expect(find.text('@小樱'), findsOneWidget, reason: '胶囊文本渲染在编辑器内');
      expect(c.text.contains(AylaMentionTextController.placeholder), isTrue);
    });
  });
}
