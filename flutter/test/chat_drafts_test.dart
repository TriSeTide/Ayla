/// 会话草稿测试 —— `stores/chatDrafts.ts` 语义 + 落盘（用户指示的增量）。
library;

import 'package:flutter_test/flutter_test.dart';

import '../lib/state/chat_drafts.dart';

void main() {
  test('setDraft / draftFor / clearDraft / reset', () {
    final AylaChatDraftsController d = AylaChatDraftsController(
      reader: () async => <String, String>{},
      writer: (Map<String, String> _) async {},
    );
    expect(d.draftFor('c1'), '', reason: '缺省空串');
    d.setDraft('c1', '你好');
    expect(d.draftFor('c1'), '你好');
    d.clearDraft('c1');
    expect(d.draftFor('c1'), '');
    d.setDraft('c2', 'x');
    d.reset();
    expect(d.drafts, isEmpty);
  });

  test('clearDraft 对不存在的键不触发通知（web 同）', () {
    final AylaChatDraftsController d = AylaChatDraftsController(
      reader: () async => <String, String>{},
      writer: (Map<String, String> _) async {},
    );
    int notified = 0;
    d.addListener(() => notified++);
    d.clearDraft('nope');
    expect(notified, 0);
  });

  test('load 读盘一次并写入内存；写盘收到快照', () async {
    Map<String, String>? written;
    final AylaChatDraftsController d = AylaChatDraftsController(
      reader: () async => <String, String>{'c1': '@[u1] 在吗'},
      writer: (Map<String, String> drafts) async => written = drafts,
    );
    await d.load();
    expect(d.draftFor('c1'), '@[u1] 在吗');
    d.setDraft('c2', 'hi');
    expect(written, isNotNull);
    expect(written!['c2'], 'hi');
  });

  test('读盘失败静默回落空表（存储不可用不是用户的错）', () async {
    final AylaChatDraftsController d = AylaChatDraftsController(
      reader: () async => throw StateError('no storage'),
      writer: (Map<String, String> _) async {},
    );
    await d.load();
    expect(d.drafts, isEmpty);
  });
}
