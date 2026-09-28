/// 聊天草稿 —— web `stores/chatDrafts.ts`（24 行）的 Flutter 等价物。
///
/// ## 与 web 的差异（**有意偏离，用户 2026-09-28 指示**）
/// web 的 `chatDrafts` 是**纯内存**（`chatDrafts.ts` 全文无 `localStorage`，刷新即失）；
/// 本实现按用户指示**落盘**（同 `state/home_prefs.dart` 的手法：应用支持目录下的 JSON 文件），
/// 使进程重启后草稿仍在。读取失败一律**静默回落空表**（存储不可用不是用户的错）。
/// 若后续要求严格对齐 web，删掉 [load] / [_persist] 两处调用即可。
///
/// ## 逐条对应
/// | 本类 | web |
/// |---|---|
/// | [draftFor] | `chatDrafts.ts:13`（缺省空串） |
/// | [setDraft] | `chatDrafts.ts:14–15` |
/// | [clearDraft] | `chatDrafts.ts:16–22`（**原本就没有该键 ⇒ 不触发通知**） |
/// | [reset] | `chatDrafts.ts:23` |
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 读草稿（注入以便测试）。
typedef AylaChatDraftsReader = Future<Map<String, String>> Function();

/// 写草稿（注入以便测试）。
typedef AylaChatDraftsWriter = Future<void> Function(Map<String, String> drafts);

/// 会话草稿控制器（键 = `draftKey`，与 `AylaMessageInput.draftKey` 同源）。
class AylaChatDraftsController extends ChangeNotifier {
  AylaChatDraftsController({
    AylaChatDraftsReader? reader,
    AylaChatDraftsWriter? writer,
  })  : _read = reader ?? _readFromDisk,
        _write = writer ?? _writeToDisk;

  /// 落盘文件名。
  static const String fileName = 'ayla_chat_drafts.json';

  final AylaChatDraftsReader _read;
  final AylaChatDraftsWriter _write;

  final Map<String, String> _drafts = <String, String>{};
  bool _loaded = false;
  bool _disposed = false;

  /// 全部草稿（只读投影）。
  Map<String, String> get drafts => Map<String, String>.unmodifiable(_drafts);

  bool get loaded => _loaded;

  /// 取某会话草稿（缺省空串）。
  String draftFor(String key) => _drafts[key] ?? '';

  /// 从存储加载一次（重复调用只加载一次；失败静默回落空表）。
  Future<void> load() async {
    if (_loaded || _disposed) return;
    _loaded = true;
    try {
      final Map<String, String> stored = await _read();
      if (_disposed) return;
      _drafts.addAll(stored);
      _notify();
    } catch (_) {
      _notify();
    }
  }

  void setDraft(String key, String content) {
    if (_drafts[key] == content) return;
    _drafts[key] = content;
    _notify();
    _persist();
  }

  void clearDraft(String key) {
    if (!_drafts.containsKey(key)) return;
    _drafts.remove(key);
    _notify();
    _persist();
  }

  void reset() {
    if (_drafts.isEmpty) return;
    _drafts.clear();
    _notify();
    _persist();
  }

  void _persist() {
    _write(Map<String, String>.of(_drafts)).catchError((Object _) {
      // 存储不可用静默（web 无落盘，故无对应 catch 语义；此处不让写盘失败影响输入）
    });
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  static Future<File> _file() async {
    final Directory dir = await getApplicationSupportDirectory();
    return File(dir.path + Platform.pathSeparator + fileName);
  }

  static Future<Map<String, String>> _readFromDisk() async {
    final File file = await _file();
    if (!file.existsSync()) return <String, String>{};
    final Object? decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return <String, String>{};
    return <String, String>{
      for (final MapEntry<Object?, Object?> e in decoded.entries)
        if (e.value is String) e.key.toString(): e.value! as String,
    };
  }

  static Future<void> _writeToDisk(Map<String, String> drafts) async {
    final File file = await _file();
    await file.writeAsString(jsonEncode(drafts));
  }
}
