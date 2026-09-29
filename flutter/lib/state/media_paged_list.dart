/// 媒体游标分页列表 —— web `hooks/usePagedMediaList.ts`（81 行）的 Flutter 等价物。
///
/// 与 `state/paged_list.dart` 的 [AylaPagedList] 分开的原因（**两条契约不同**）：
/// | | 目录页 (`useDirectoryPage`) | 媒体页 (`usePagedMediaList`) |
/// |---|---|---|
/// | 响应 | `DirectoryPage`（含 `total_member_count`） | `MediaPage`（`results/next_cursor/has_more/total`） |
/// | 去重键 | 调用方给 `keyOf` | `String(item.id)` |
/// | 游标异常 | 显式失败（报错） | **静默降级**（`loading=false`、保留上一页，web `usePagedMediaList.ts:46–50`） |
/// | 用途 | 大厅/收藏/搜索的目录 | 语音成员分页、弹幕/聊天历史的**可见分页** |
///
/// 语义逐条对齐 web：scope 变化即重置（`state.scope !== scope` ⇒ 按初始态渲染）；
/// 错误**保留上一次成功的页**（`errors retain the last successful page`）；
/// `loadMore` 在错误态时**回到第一页重试**（`retryReset`）。
library;

import 'package:flutter/foundation.dart';

import '../core/api/media_page.dart';

/// 取一页（cursor = 继续位置；null = 第一页）。
typedef AylaMediaPageRequest<T> = Future<AylaMediaCursorPage<T>?> Function(
  String? cursor,
);

/// 媒体游标分页列表（每页面一份实例；[scope] 变化 ⇒ [reset]）。
class AylaMediaPagedList<T> extends ChangeNotifier {
  AylaMediaPagedList({
    required this.scope,
    required this.request,
    required this.idOf,
    bool enabled = true,
  }) : _enabled = enabled,
        _loading = enabled;

  /// 作用域键（web `voice-members:<uid>:<channelId>` 等）。
  final String scope;

  final AylaMediaPageRequest<T> request;

  /// 去重键（web `String(item.id)`）。
  final String Function(T item) idOf;

  final bool _enabled;

  List<T> _items = <T>[];
  String? _cursor;
  bool _hasMore = false;
  int _total = 0;
  bool _loading;
  bool _loaded = false;
  String? _error;
  int _generation = 0;
  bool _busy = false;
  bool _retryReset = true;
  bool _disposed = false;

  List<T> get items => List<T>.unmodifiable(_items);
  bool get loading => _loading;
  bool get loaded => _loaded;
  bool get hasMore => _hasMore;
  int get total => _total;
  String? get error => _error;

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// 重置到初始态并拉第一页（scope 变化时调用）。
  Future<void> reset() {
    _busy = false;
    _items = <T>[];
    _cursor = null;
    _hasMore = false;
    _total = 0;
    _loaded = false;
    _error = null;
    _loading = _enabled;
    _generation++;
    _notify();
    return refreshPage();
  }

  Future<AylaMediaCursorPage<T>?> refreshPage() => _load(reset: true);

  /// 刷新（web `refresh`：等它完成，供下拉刷新/刷新键）。
  Future<void> refresh() async {
    await _load(reset: true);
  }

  /// 加载下一页（错误态 ⇒ 回到第一页重试，web `retryReset`）。
  Future<void> loadMore() => _load(reset: _error != null && _retryReset);

  /// 局部改写条目（web `updateItems`；成员面板的 `left` 帧剔除用它）。
  void updateItems(List<T> Function(List<T> items) update) {
    _items = update(List<T>.of(_items));
    _notify();
  }

  Future<AylaMediaCursorPage<T>?> _load({required bool reset}) async {
    if (!_enabled) return null;
    if (!reset && _busy) return null;
    if (!reset && (!_hasMore || _cursor == null)) return null;
    // ⚠️ 局部变量不能叫 `request` —— 会遮蔽同名的字段（函数类型）导致调用失败。
    final int requestId = ++_generation;
    _retryReset = reset;
    final String? cursor = reset ? null : _cursor;
    _busy = true;
    _loading = true;
    _error = null;
    _notify();
    try {
      final AylaMediaCursorPage<T>? page = await request(cursor);
      if (_disposed || _generation != requestId) return null;
      if (page == null) {
        _loading = false;
        _error = '加载失败，请重试';
        _notify();
        return null;
      }
      if (page.hasMore &&
          (page.nextCursor == null ||
              page.nextCursor == cursor ||
              page.results.isEmpty)) {
        // 游标异常（防御性检查，正常不触发）：**静默降级**，不打扰用户（web 原话）。
        _loading = false;
        _notify();
        return null;
      }
      final Map<String, T> rows = <String, T>{
        if (!reset)
          for (final T item in _items) idOf(item): item,
      };
      for (final T item in page.results) {
        rows[idOf(item)] = item;
      }
      _items = rows.values.toList(growable: false);
      _cursor = page.nextCursor;
      _hasMore = page.hasMore;
      _total = page.total;
      _loading = false;
      _loaded = true;
      _error = null;
      _notify();
      return page;
    } catch (error) {
      if (!_disposed && _generation == requestId) {
        _loading = false;
        _error = error is Exception ? '$error' : '加载失败，请重试';
        _notify();
      }
      return null;
    } finally {
      if (_generation == requestId) _busy = false;
    }
  }
}
