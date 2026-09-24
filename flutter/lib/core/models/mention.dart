/// @ 能力草稿块与纯函数（`Ayla/web/src/utils/mention.ts` 的 Dart 等价）。
///
/// ## 事实源
///
/// | 本文件 | web |
/// |---|---|
/// | [AylaDraftBlock] | `api/types.ts:231–234` DraftBlock（text / mention 交错序列） |
/// | [aylaBlocksText] | `utils/mention.ts:13–18` |
/// | [aylaBlocksHasMention] | tsx 21–23 |
/// | [aylaBlocksToSegments] | tsx 26–34（发送 payload 的 text/mention 段；媒体段由调用方追加尾部） |
/// | [aylaSerializeBlocks] | tsx 39–41（mention → `@[user_id]`，**跨端草稿格式一致**） |
/// | [aylaParseBlocks] | tsx 44–59（正则 `@\[([^\]]+)\]`；查不到名字回退「未知用户」） |
/// | [aylaDetectMentionAtCaret] | tsx 110–129（光标前最近的 `@`；`@` 到光标之间不允许空白；**`@` 前不强制空白边界**） |
///
/// ## 与 web 的差异（有意，登记）
/// web 的编辑器是 `contentEditable`，mention 是 `contenteditable=false` 的 span，
/// 「整体删除」由浏览器原生提供。Flutter 没有 contentEditable ⇒ 编辑器侧用
/// **单字符占位符 `\uFFFC`** 表达同一语义（单字符天然整块删除），
/// 见 `widgets/mention_editor.dart`。本文件的纯函数与 web 逐条同源，两端草稿互通。
library;

import 'chat_message.dart' show AylaMediaSegment, AylaSegmentType;

/// 草稿块类型（`types.ts:231–234`）。
enum AylaDraftBlockType { text, mention }

/// 草稿块：文本 或 一个 @ 用户。
class AylaDraftBlock {
  const AylaDraftBlock.text(this.text)
      : type = AylaDraftBlockType.text,
        userId = null,
        name = null;

  const AylaDraftBlock.mention({required String this.userId, required String this.name})
      : type = AylaDraftBlockType.mention,
        text = '';

  final AylaDraftBlockType type;

  /// 文本块正文（mention 块为空串）。
  final String text;

  /// 被 @ 的用户 id（文本块为 null）。
  final String? userId;

  /// 展示名（文本块为 null）。
  final String? name;
}

/// `blocksText`（tsx 13–18）：仅文本块拼接（mention 不进 `content`）。
String aylaBlocksText(List<AylaDraftBlock> blocks) => blocks
    .where((AylaDraftBlock b) => b.type == AylaDraftBlockType.text)
    .map((AylaDraftBlock b) => b.text)
    .join();

/// `blocksHasMention`（tsx 21–23）。
bool aylaBlocksHasMention(List<AylaDraftBlock> blocks) =>
    blocks.any((AylaDraftBlock b) => b.type == AylaDraftBlockType.mention);

/// `blocksToSegments`（tsx 26–34）：发送 payload 的 text/mention 段前缀
/// （媒体段由输入区按选中的媒体追加在尾部）。
List<AylaMediaSegment> aylaBlocksToSegments(List<AylaDraftBlock> blocks) => <AylaMediaSegment>[
      for (final AylaDraftBlock b in blocks)
        b.type == AylaDraftBlockType.text
            ? AylaMediaSegment(type: AylaSegmentType.text, text: b.text)
            : AylaMediaSegment(
                type: AylaSegmentType.mention,
                userId: b.userId,
                name: b.name,
              ),
    ];

/// `serializeBlocks`（tsx 39–41）：mention → `@[user_id]`。
String aylaSerializeBlocks(List<AylaDraftBlock> blocks) => blocks
    .map((AylaDraftBlock b) =>
        b.type == AylaDraftBlockType.text ? b.text : '@[${b.userId}]')
    .join();

/// `parseBlocks`（tsx 44–59）：草稿字符串 → blocks。
///
/// [nameOf] 提供 `user_id → 显示名`；查不到回退「未知用户」（**与 web 同口径**）。
List<AylaDraftBlock> aylaParseBlocks(
  String str,
  String? Function(String id) nameOf,
) {
  final List<AylaDraftBlock> blocks = <AylaDraftBlock>[];
  final RegExp re = RegExp(r'@\[([^\]]+)\]');
  int last = 0;
  for (final RegExpMatch m in re.allMatches(str)) {
    if (m.start > last) {
      blocks.add(AylaDraftBlock.text(str.substring(last, m.start)));
    }
    final String id = m.group(1)!;
    blocks.add(AylaDraftBlock.mention(userId: id, name: nameOf(id) ?? '未知用户'));
    last = m.end;
  }
  if (last < str.length) blocks.add(AylaDraftBlock.text(str.substring(last)));
  return blocks;
}

/// `detectMentionAtCaret`（tsx 110–129）的纯函数版：给定文本与光标偏移，
/// 返回 `@` 的位置与过滤词（空串 = 刚输入 `@`）；不处于 @ 触发态返回 null。
///
/// 规则：取光标前的文本，找**最近的** `@`；`@` 之后到光标之间不允许空白/换行；
/// `@` 前不要求空白边界（QQ 式：文本中/多次 @ 都可触发）。
({int atIndex, String query})? aylaDetectMentionAtCaret(String text, int caret) {
  if (caret < 0 || caret > text.length) return null;
  final String before = text.substring(0, caret);
  final int atIdx = before.lastIndexOf('@');
  if (atIdx < 0) return null;
  final String query = before.substring(atIdx + 1);
  if (RegExp(r'[\s\n]').hasMatch(query)) return null;
  return (atIndex: atIdx, query: query);
}
