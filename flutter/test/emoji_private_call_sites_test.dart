/// 群表情包键的**调用点审计锁** —— 源码级（同 `font_fallback_audit_test.dart` 的范式）。
///
/// ## 为什么必须有这条
/// web `MessageInput.tsx:89` 的注释原文：「群聊才有 members：@ 与群表情包按钮均仅群聊展示
/// （**私信不显示表情包按钮**）」⇒ 只有**群聊**的 composer 可以传
/// `showEmojiButton` / `emojiPanel`；私聊（`chat_support.dart` 的
/// `AylaChatPaneHost`、`private_chat_pane.dart` 的样张）一律不传。
///
/// 行为侧的锁在 `chat_emoji_button_test.dart`（真页面链）；本文件补的是**调用点面**：
/// 将来有人给私聊补上这两个参数（看起来"功能更全"），行为测试未必覆盖到那条链路
/// （私聊宿主的既有 Riverpod 断言会先炸），但**调用点审计**一定能挡住。
///
/// ## 方法
/// 扫描 `lib/**/*.dart`，用**括号配对**提取每个 `AylaMessageInput(` 的实参文本，
/// 逐个判定「这个调用点在哪个文件、有没有传这两个参数」。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 一个 `AylaMessageInput(...)` 调用点：文件路径 + 实参原文。
class _CallSite {
  const _CallSite(this.path, this.args, this.line);

  final String path;
  final String args;
  final int line;

  bool get passesButton => args.contains('showEmojiButton');
  bool get passesPanel => args.contains('emojiPanel');
}

/// 扫描 lib 下所有 Dart 文件里的 `AylaMessageInput(` 调用点。
List<_CallSite> _scanCallSites() {
  final List<_CallSite> sites = <_CallSite>[];
  final Directory dir = Directory('lib');
  final List<File> files = dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((File f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((File a, File b) => a.path.compareTo(b.path));
  for (final File file in files) {
    final String src = file.readAsStringSync();
    const String needle = 'AylaMessageInput(';
    int idx = 0;
    while (true) {
      final int at = src.indexOf(needle, idx);
      if (at < 0) break;
      idx = at + 1;
      // 提取平衡括号内的实参文本（跳过构造器名后面的第一个 '('）。
      int i = at + needle.length;
      // 深度从 1 起（进入的是构造器的实参列表本身）。
      int depth = 1;
      final StringBuffer buf = StringBuffer();
      while (i < src.length) {
        final String ch = src[i];
        if (ch == '(') {
          depth++;
        } else if (ch == ')') {
          depth--;
          if (depth == 0) break;
        }
        buf.write(ch);
        i++;
      }
      if (depth != 0) continue; // 括号不配对（截断/异常源码）⇒ 跳过，不误判
      final int line = '\n'.allMatches(src.substring(0, at)).length + 1;
      sites.add(_CallSite(file.path, buf.toString(), line));
    }
  }
  return sites;
}

// $BODY$

void main() {
  late List<_CallSite> sites;

  setUpAll(() {
    sites = _scanCallSites();
    // 扫描必须真的扫到东西（否则本文件的"全绿"是空断言 —— AGENTS.md §12：
    // 不得把"收集到 0 项"当作通过）。
    expect(sites.length, greaterThanOrEqualTo(5),
        reason: 'lib 下的 AylaMessageInput 调用点（含组件样张）应远多于 5 处');
  });

  test('★ 只有群聊页的 composer 传 showEmojiButton / emojiPanel', () {
    final List<_CallSite> withButton =
        sites.where((_CallSite s) => s.passesButton).toList();
    final List<_CallSite> withPanel =
        sites.where((_CallSite s) => s.passesPanel).toList();

    // 白名单 = 群聊页（本任务接线点）+ message_input.dart（该件自己的样张，
    // 位于 lib/widgets/chat/message_input.dart，与 preview 画布同源）。
    for (final _CallSite s in <_CallSite>[...withButton, ...withPanel]) {
      final bool allowed = s.path.endsWith('pages\\group_chat_page.dart') ||
          s.path.endsWith('widgets\\chat\\message_input.dart');
      expect(allowed, isTrue,
          reason: '★ ${s.path}:${s.line} 传了表情包参数；'
              '只有群聊页可以传（web MessageInput.tsx:89「私信不显示表情包按钮」）');
    }

    // 群聊页**必须**传（这是本次修复的落点；只锁"没人乱传"会让删掉它也不报错）。
    final Iterable<_CallSite> groupPage = sites
        .where((_CallSite s) => s.path.endsWith('pages\\group_chat_page.dart'));
    expect(groupPage, isNotEmpty, reason: '群聊页应有 composer 调用点');
    for (final _CallSite s in groupPage) {
      expect(s.passesButton, isTrue,
          reason: '★ ${s.path}:${s.line} 必须传 showEmojiButton: true（用户实报缺键）');
      expect(s.passesPanel, isTrue,
          reason: '★ ${s.path}:${s.line} 必须传 emojiPanel（缺它键不渲染）');
    }
  });

  test('★ 私聊两处调用点（chat_support / private_chat_pane）都不传这两个参数', () {
    for (final String suffix in <String>[
      'pages\\chat_support.dart',
      'widgets\\chat\\private_chat_pane.dart',
    ]) {
      final List<_CallSite> hits =
          sites.where((_CallSite s) => s.path.endsWith(suffix)).toList();
      expect(hits, isNotEmpty, reason: '$suffix 应有 composer 调用点（审计面完整）');
      for (final _CallSite s in hits) {
        expect(s.passesButton, isFalse,
            reason: '★ ${s.path}:${s.line} 私聊不得传 showEmojiButton（tsx:89）');
        expect(s.passesPanel, isFalse,
            reason: '★ ${s.path}:${s.line} 私聊不得传 emojiPanel（tsx:89）');
      }
    }
  });

  test('审计面：扫描确实覆盖了四个已知调用点文件', () {
    final Set<String> files =
        sites.map((_CallSite s) => s.path.replaceAll('\\', '/')).toSet();
    for (final String needed in <String>[
      'lib/pages/group_chat_page.dart',
      'lib/pages/chat_support.dart',
      'lib/widgets/chat/private_chat_pane.dart',
      'lib/widgets/chat/message_input.dart',
    ]) {
      expect(files, contains(needed), reason: '$needed 应在扫描结果里');
    }
  });
}
