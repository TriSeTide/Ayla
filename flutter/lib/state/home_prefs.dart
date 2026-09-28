/// 主页偏好 —— web `stores/home.ts`（73 行）的 Flutter 等价物。
///
/// ## 逐条对应
/// | 本类 | web |
/// |---|---|
/// | `layout`（card / list） | `home.ts:12/17–32`：localStorage key `ayla.home.layout`，**默认 card** |
/// | `recentGroupId` | `home.ts:13/34–49`：key `ayla.home.recent_group`；宽屏 `/group` 重定向据此定位 |
///
/// ## 平台差异（登记）
/// web 用 `localStorage`；Flutter 无 localStorage ⇒ 落盘应用支持目录下的同名 JSON 文件
/// （与 `state/search_history.dart` 同一手法）。读写失败**静默**（web 的 try/catch 同语义）。
///
/// ## 语义要点
/// - 读取时**只认 `"list"`**，其余（含 null / 未知值 / 存储不可用）一律 card
///   （`home.ts:20` 的 `v === "list" ? "list" : "card"` —— 不猜未知值）；
/// - `setRecentGroup(null)` = 删除键（`home.ts:44–45`）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 主页布局（`HomeLayout`）。
enum AylaHomeLayout {
  card,
  list;

  /// 存储值（localStorage 里就是这两个字符串）。
  String get wire => name;

  /// 解析：**只有 `"list"` 是 list**，其余（null / 未知）回落 card（`home.ts:20`）。
  static AylaHomeLayout parse(Object? raw) =>
      raw == 'list' ? AylaHomeLayout.list : AylaHomeLayout.card;
}

/// 读偏好（注入以便测试）。
typedef AylaHomePrefsReader = Future<Map<String, Object?>> Function();

/// 写偏好（注入以便测试）。
typedef AylaHomePrefsWriter = Future<void> Function(Map<String, Object?> prefs);

/// 主页偏好控制器。
class AylaHomePrefsController extends ChangeNotifier {
  AylaHomePrefsController({
    AylaHomePrefsReader? reader,
    AylaHomePrefsWriter? writer,
  })  : _read = reader ?? _readFromDisk,
        _write = writer ?? _writeToDisk;

  /// 落盘文件名（web 的两个 key 合成一个文件；键名原样保留）。
  static const String fileName = 'ayla_home_prefs.json';

  /// 布局键（web `LAYOUT_KEY`）。
  static const String layoutKey = 'ayla.home.layout';

  /// 最近群键（web `RECENT_GROUP_KEY`）。
  static const String recentGroupKey = 'ayla.home.recent_group';

  final AylaHomePrefsReader _read;
  final AylaHomePrefsWriter _write;

  AylaHomeLayout _layout = AylaHomeLayout.card;
  String? _recentGroupId;
  bool _loaded = false;
  bool _disposed = false;

  AylaHomeLayout get layout => _layout;

  String? get recentGroupId => _recentGroupId;

  bool get loaded => _loaded;

  /// 从存储加载一次（重复调用只加载一次；失败静默回落默认值）。
  Future<void> load() async {
    if (_loaded || _disposed) return;
    _loaded = true;
    try {
      final Map<String, Object?> stored = await _read();
      if (_disposed) return;
      _layout = AylaHomeLayout.parse(stored[layoutKey]);
      final Object? recent = stored[recentGroupKey];
      _recentGroupId = recent is String && recent.isNotEmpty ? recent : null;
      _notify();
    } catch (_) {
      // 存储不可用 → 默认偏好（web readLayout/readRecentGroup 的 catch 同）
      _layout = AylaHomeLayout.card;
      _recentGroupId = null;
      _notify();
    }
  }

  /// 切换布局并持久化。
  void setLayout(AylaHomeLayout next) {
    if (_layout == next) return;
    _layout = next;
    _notify();
    _persist();
  }

  /// 记录最近访问群（null = 清除）。
  void setRecentGroup(String? id) {
    final String? next = (id == null || id.isEmpty) ? null : id;
    if (_recentGroupId == next) return;
    _recentGroupId = next;
    _notify();
    _persist();
  }

  void _persist() {
    _write(<String, Object?>{
      layoutKey: _layout.wire,
      if (_recentGroupId != null) recentGroupKey: _recentGroupId,
    }).catchError((Object _) {
      // 存储不可用静默（web writeLayout/writeRecentGroup 的 catch）
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

  static Future<Map<String, Object?>> _readFromDisk() async {
    final File file = await _file();
    if (!file.existsSync()) return <String, Object?>{};
    final Object? decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return <String, Object?>{};
    return <String, Object?>{
      for (final MapEntry<Object?, Object?> e in decoded.entries)
        e.key.toString(): e.value,
    };
  }

  static Future<void> _writeToDisk(Map<String, Object?> prefs) async {
    final File file = await _file();
    await file.writeAsString(jsonEncode(prefs));
  }
}
