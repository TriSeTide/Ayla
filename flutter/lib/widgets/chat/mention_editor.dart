/// @ 提及编辑器控制器 —— web `contentEditable` + `contenteditable=false` span 的 Flutter 等价。
///
/// ## 语义对照（web → Flutter）
///
/// | web | 本件 |
/// |---|---|
/// | mention = `contenteditable=false` 的 span（`@名称`，浏览器**原生整体删除**） | 文本里一个 **`\uFFFC`（对象替换字符）占位**；单字符 ⇒ 删除天然整块（光标不会落进块内） |
/// | span 渲染 `.mention-token.mention-token-input`（ice-500 底胶囊） | [buildTextSpan] 把占位符渲染成 `WidgetSpan` 胶囊（同款度量） |
/// | `extractBlocks`（DOM → blocks） | [extractBlocks]（文本 → blocks） |
/// | `renderBlocksToDOM`（blocks → DOM） | [setBlocks]（blocks → 文本 + 占位符） |
/// | `detectMentionAtCaret` / `insertMentionAtCaret` | [detectMention] / [insertMention] |
/// | 草稿 `@[user_id]` 序列化（`chatDrafts` store） | 纯函数在 `core/models/mention.dart`，**两端格式一致** |
///
/// ## 为什么用「单字符占位符」而不是把 `@名称` 直接写进文本
/// 若把显示名写进文本，用户在块中间按退格会拆掉半个名字（web 不允许）；占位符是
/// **单字符** ⇒ 选区/删除只能整块命中或完全不动，与 web 的 span 行为一致，
/// 且不需要自定义删除拦截（Flutter 的 `TextEditingController` 只需维护
/// 「占位符索引 → (user_id, name)」映射随文本变更迁移）。
///
/// ## 公开面
/// `AylaMentionSpan` · `AylaMentionTextController`

library;

import 'package:flutter/material.dart';

import '../../core/models/mention.dart';
import '../../theme/tokens.dart';

/// 编辑器内的一个 @ 占位（对应 web 的 mention span）。
class AylaMentionSpan {
  const AylaMentionSpan({
    required this.index,
    required this.userId,
    required this.name,
  });

  /// 占位符在文本中的**字符索引**（占位符本身占 1 个字符）。
  final int index;

  final String userId;
  final String name;

  AylaMentionSpan copyWith({int? index}) => AylaMentionSpan(
        index: index ?? this.index,
        userId: userId,
        name: name,
      );
}

/// @ 编辑器控制器（文本 + 原子 @Token）。
class AylaMentionTextController extends TextEditingController {
  AylaMentionTextController({super.text}) {
    if (text.isNotEmpty) {
      // 外部直接传 text（如草稿字符串）时没有 spans —— 调用方应改用 [setBlocks]。
      _spans.clear();
    }
  }

  /// 占位符字符（对象替换字符）。
  static const String placeholder = '\uFFFC';

  final List<AylaMentionSpan> _spans = <AylaMentionSpan>[];

  /// 当前 @ 占位（按索引升序）。
  List<AylaMentionSpan> get spans => List<AylaMentionSpan>.unmodifiable(_spans);

  /// 文本变更时迁移 spans 的索引（并移除被删掉的占位）。
  ///
  /// 走 `value` setter 而不是 listener：listener 在变更**之后**才触发，那时旧文本已丢失。
  @override
  set value(TextEditingValue newValue) {
    if (newValue.text != value.text) {
      _remapSpans(value.text, newValue.text);
    }
    super.value = newValue;
  }

  void _remapSpans(String oldText, String newText) {
    if (_spans.isEmpty) return;
    // 共同前缀 / 后缀 → 变更区间 [p, oldLen - s)
    int p = 0;
    final int oldLen = oldText.length;
    final int newLen = newText.length;
    while (p < oldLen && p < newLen && oldText[p] == newText[p]) {
      p++;
    }
    int s = 0;
    while (s < oldLen - p &&
        s < newLen - p &&
        oldText[oldLen - 1 - s] == newText[newLen - 1 - s]) {
      s++;
    }
    final int removedStart = p;
    final int removedEnd = oldLen - s;
    final int delta = newLen - oldLen;

    final List<AylaMentionSpan> next = <AylaMentionSpan>[];
    for (final AylaMentionSpan span in _spans) {
      if (span.index >= removedStart && span.index < removedEnd) {
        continue; // 占位符被删除 → 整块移除
      }
      if (span.index >= removedEnd) {
        next.add(span.copyWith(index: span.index + delta));
      } else {
        next.add(span);
      }
    }
    _spans
      ..clear()
      ..addAll(next);
  }

  /// `extractBlocks`（`utils/mention.ts:64–88`）：文本 + 占位符 → 草稿块（text/mention 交错）。
  List<AylaDraftBlock> extractBlocks() {
    final List<AylaDraftBlock> blocks = <AylaDraftBlock>[];
    final String text = value.text;
    int cursor = 0;
    for (final AylaMentionSpan span in _spans) {
      if (span.index > cursor) {
        _pushText(blocks, text.substring(cursor, span.index));
      }
      blocks.add(AylaDraftBlock.mention(userId: span.userId, name: span.name));
      cursor = span.index + 1;
    }
    if (cursor < text.length) {
      _pushText(blocks, text.substring(cursor));
    }
    return blocks;
  }

  static void _pushText(List<AylaDraftBlock> blocks, String raw) {
    // web：过滤零宽占位符 \u200B（本实现不需要零宽占位，但仍照做以保持同源）
    final String t = raw.replaceAll('\u200B', '');
    if (t.isEmpty) return;
    final AylaDraftBlock? last = blocks.isEmpty ? null : blocks.last;
    if (last != null && last.type == AylaDraftBlockType.text) {
      blocks[blocks.length - 1] = AylaDraftBlock.text(last.text + t);
    } else {
      blocks.add(AylaDraftBlock.text(t));
    }
  }

  /// `renderBlocksToDOM` 的等价：把草稿块写回编辑器（初始化/恢复草稿/子群切换）。
  void setBlocks(List<AylaDraftBlock> blocks) {
    final StringBuffer buffer = StringBuffer();
    final List<AylaMentionSpan> spans = <AylaMentionSpan>[];
    for (final AylaDraftBlock b in blocks) {
      if (b.type == AylaDraftBlockType.text) {
        buffer.write(b.text);
      } else {
        spans.add(
          AylaMentionSpan(
            index: buffer.length,
            userId: b.userId!,
            name: b.name!,
          ),
        );
        buffer.write(placeholder);
      }
    }
    _spans
      ..clear()
      ..addAll(spans);
    final String text = buffer.toString();
    // ⚠️ 走 `super.value`（**跳过** `_remapSpans`）：spans 已按新文本手动建好，
    // 再让 diff 迁移一次会双重调整（整体替换场景 diff 无意义）。
    super.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _spans
      ..clear()
      ..addAll(spans);
  }

  /// `detectMentionAtCaret`：当前光标是否处于 @ 触发态。
  ({int atIndex, String query})? detectMention() {
    final TextSelection sel = selection;
    if (!sel.isValid || !sel.isCollapsed) return null;
    return aylaDetectMentionAtCaret(value.text, sel.baseOffset);
  }

  /// `insertMentionAtCaret`：把光标前的 `@query` 替换为 @Token；返回是否插入成功。
  bool insertMention({required String userId, required String name}) {
    final ({int atIndex, String query})? detected = detectMention();
    if (detected == null) return false;
    final int caret = selection.baseOffset;
    final String text = value.text;
    final String before = text.substring(0, detected.atIndex);
    final String after = text.substring(caret);
    // 先移除被替换区间内的 spans（`@query` 区间内不该有占位符；防御性处理）
    _spans.removeWhere((AylaMentionSpan s) =>
        s.index >= detected.atIndex && s.index < caret);
    final int delta = 1 - (caret - detected.atIndex);
    final List<AylaMentionSpan> shifted = <AylaMentionSpan>[
      for (final AylaMentionSpan s in _spans)
        s.index >= caret ? s.copyWith(index: s.index + delta) : s,
    ];
    _spans
      ..clear()
      ..addAll(shifted)
      ..add(
        AylaMentionSpan(
          index: detected.atIndex,
          userId: userId,
          name: name,
        ),
      );
    _spans.sort((AylaMentionSpan a, AylaMentionSpan b) => a.index.compareTo(b.index));
    final String next = '$before$placeholder$after';
    final int nextCaret = detected.atIndex + 1;
    // `super.value`：spans 已手动迁移（跳过 _remapSpans 的二次调整）
    super.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: nextCaret),
    );
    return true;
  }

  /// `insertMentionToken`（长按头像 @ 路径）：在光标处直接插入（无 `@query` 前缀）。
  void insertMentionToken({required String userId, required String name}) {
    final int caret = selection.isValid ? selection.baseOffset : value.text.length;
    final int at = caret.clamp(0, value.text.length);
    final List<AylaMentionSpan> shifted = <AylaMentionSpan>[
      for (final AylaMentionSpan s in _spans)
        s.index >= at ? s.copyWith(index: s.index + 1) : s,
    ];
    _spans
      ..clear()
      ..addAll(shifted)
      ..add(AylaMentionSpan(index: at, userId: userId, name: name));
    _spans.sort((AylaMentionSpan a, AylaMentionSpan b) => a.index.compareTo(b.index));
    // `super.value`：同上，spans 已手动迁移
    super.value = TextEditingValue(
      text: value.text.substring(0, at) + placeholder + value.text.substring(at),
      selection: TextSelection.collapsed(offset: at + 1),
    );
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // 组字（中文输入法）期间交回默认实现：Flutter 需要维护 composing 区域的下划线，
    // 自定义 span 会与 IME 组合区冲突（web 无此概念，属平台差异）。
    if (withComposing && value.composing.isValid) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final String text = value.text;
    if (_spans.isEmpty) {
      return TextSpan(text: text, style: style);
    }
    final List<InlineSpan> children = <InlineSpan>[];
    int cursor = 0;
    for (final AylaMentionSpan span in _spans) {
      if (span.index > cursor) {
        children.add(TextSpan(text: text.substring(cursor, span.index)));
      }
      children.add(_tokenSpan(span));
      cursor = span.index + 1;
    }
    if (cursor < text.length) {
      children.add(TextSpan(text: text.substring(cursor)));
    }
    return TextSpan(style: style, children: children);
  }

  /// `.mention-token.mention-token-input`（app.css 2328–2361）的胶囊：
  /// `--ice-500` 底 + `--indigo-700` 字 + 700 + `padding: 0 6px` + `margin: 0 1px`
  /// + pill 圆角 + `line-height: 1.45` + 字号继承编辑器。
  WidgetSpan _tokenSpan(AylaMentionSpan span) {
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 1),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: AylaColors.ice500,
          borderRadius: AylaRadii.pill,
        ),
        child: Text(
          '@${span.name}',
          // `cursor: default; pointer-events: none`（输入框内的 token 不可点、不参与交互）
          style: const TextStyle(
            fontFamily: AylaFonts.body,
            fontFamilyFallback: AylaFonts.cjkFallback,
            fontSize: 15,
            fontWeight: FontWeight.w700,
            height: 1.45,
            color: AylaColors.indigo700,
          ),
        ),
      ),
    );
  }
}
