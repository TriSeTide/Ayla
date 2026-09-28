/// 搜索历史（web stores/search.ts 52 行）。
///
/// ## 逐条对应的 web 语义
/// - 最近搜索词，**去重置顶**、上限 10（`search.ts:9` 的 MAX_HISTORY）；
/// - 清空（R-S 搜索页历史 chips 的「清空」键）；
/// - 存储不可用时忽略（`search.ts:24–27` 的 try/catch）。
///
/// ## 平台差异（登记）
/// web 用 `localStorage`（key `ayla.search.history`，JSON 字符串数组）；
/// Flutter 无 localStorage ⇒ 落盘到应用支持目录的同名 JSON 文件
/// （`path_provider` 的 applicationSupportDirectory）。读写均为 fire-and-forget：
/// 失败静默（与 web 的 try/catch 同语义）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 读历史（注入以便测试；默认读应用支持目录的 JSON 文件）。
typedef AylaSearchHistoryReader = Future<List<String>> Function();

/// 写历史（注入以便测试）。
typedef AylaSearchHistoryWriter = Future<void> Function(List<String> history);

/// 搜索历史控制器。
class AylaSearchHistoryController extends ChangeNotifier {
  AylaSearchHistoryController({
    AylaSearchHistoryReader? reader,
    AylaSearchHistoryWriter? writer,
  })  : _read = reader ?? _readFromDisk,
        _write = writer ?? _writeToDisk;

  /// 上限（web `MAX_HISTORY`）。
  static const int maxHistory = 10;

  /// 落盘文件名（web 的 key 是 `ayla.search.history`）。
  static const String fileName = 'ayla_search_history.json';

  final AylaSearchHistoryReader _read;
  final AylaSearchHistoryWriter _write;

  List<String> _history = <String>[];
  bool _loaded = false;
  bool _disposed = false;

  /// 最近搜索词（栈顶最新）。
  List<String> get history => List<String>.unmodifiable(_history);

  bool get loaded => _loaded;

  /// 从存储加载一次（重复调用只加载一次）。
  Future<void> load() async {
    if (_loaded || _disposed) return;
    _loaded = true;
    try {
      final List<String> stored = await _read();
      if (_disposed) return;
      _history = stored
          .where((String item) => item.trim().isNotEmpty)
          .take(maxHistory)
          .toList(growable: false);
      _notify();
    } catch (_) {
      // 存储不可用 → 空历史（web 同：readHistory 的 catch 返回 []）
      _history = <String>[];
      _notify();
    }
  }

  /// 记录一次搜索（去重置顶，上限 [maxHistory]）；空串忽略（web `search.ts:41–42`）。
  void push(String query) {
    final String trimmed = query.trim();
    if (trimmed.isEmpty) return;
    _history = <String>[
      trimmed,
      for (final String item in _history)
        if (item != trimmed) item,
    ].take(maxHistory).toList(growable: false);
    _notify();
    _persist();
  }

  /// 清空历史。
  void clear() {
    _history = <String>[];
    _notify();
    _persist();
  }

  void _persist() {
    final List<String> snapshot = List<String>.of(_history);
    _write(snapshot).catchError((Object _) {
      // 存储不可用静默（web writeHistory 的 catch）
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

  static Future<List<String>> _readFromDisk() async {
    final File file = await _file();
    if (!file.existsSync()) return const <String>[];
    final String raw = await file.readAsString();
    final Object? decoded = jsonDecode(raw);
    if (decoded is! List) return const <String>[];
    return <String>[
      for (final Object? item in decoded)
        if (item is String) item,
    ];
  }

  static Future<void> _writeToDisk(List<String> history) async {
    final File file = await _file();
    await file.writeAsString(jsonEncode(history));
  }
}
