/// 游标历史窗口 —— web `hooks/useCursorHistory.ts`（175 行）的 Flutter 等价物。
///
/// ## 为什么需要它
/// 语音房内聊天与直播弹幕都用同一套服务端契约：`?cursor=&before_id=&limit=` 的
/// 游标页（`api/mediaPagination.ts`），而**可见窗口必须有界**（web
/// `HISTORY_WINDOW_LIMIT = 500`），否则长会话会把内存吃光。web 用一个 hook 承载
/// 这套语义；Flutter 侧用同一个 ChangeNotifier 承载，页面只做装配。
///
/// ## 逐条对应（web `useCursorHistory.ts`）
/// | 本类 | web |
/// |---|---|
/// | [items] / [loading] / [error] / [hasMore] / [hasNewer] | `state` 的同名字段 |
/// | [loadOlder] / [returnLatest] / [retry] | 同名回调 |
/// | [append] | `append`（**只接受未见过的新 id**；上翻期间挂进 `pendingLive`） |
/// | [setFollowing] | `handleScroll`（`scrollHeight - scrollTop - clientHeight < 40`） |
/// | [hasNewer] / [returnLatest] | `hasNewer` / `returnLatest`（"成功读取后再替换窗口，失败保留原页"） |
/// | [invalidate] | `invalidate`（`invalidationRevision`） |
///
/// ## 为什么用 `idOf` / `createdAtOf` 而不是接口
/// 被合并的数据类型来自**不同层**（`core/api` 的 `AylaVoiceChatMessage`、
/// 数据层自己的直播弹幕行…），让它们反向实现 `state` 的接口会把依赖方向倒过来
/// ⇒ 改用两个投影函数注入（web 用 TS 结构化类型表达同一件事）。
///
/// ## 有意偏离（登记）
/// - **锚点恢复不进本类**：web 用 `useLayoutEffect` 直接改 `scrollTop`。Flutter 侧
///   列表是 `ListView`（无「按 id 找元素再定位」的 DOM 语义），本类只把
///   [pendingScrollToBottom] 暴露给页面，由页面的 `ScrollController` 决定如何落位
///   （语音房/弹幕两处的列表都只有"贴底跟随"档，上翻续读时**不跳位**即可满足
///   web 的锚点意图）。
/// - **500 条截断语义保留**（`HISTORY_WINDOW_LIMIT`）：超出时置 `cursorDetached`，
///   续读改走 `before_id = items.first.id`（与 web 一致）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api/media_page.dart';

/// 可见窗口上限（web `useCursorHistory.ts:4` `HISTORY_WINDOW_LIMIT`）。
const int kAylaHistoryWindowLimit = 500;

/// 历史读取失败（分页契约非法 / 续读位置缺失）——**显式失败**，不静默吞掉。
class AylaCursorHistoryException implements Exception {
  const AylaCursorHistoryException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 合并两批（web `mergeHistory`：按 id 去重，按 `created_at` 升序、
/// 同刻按 id 数字序 —— `localeCompare(..., { numeric: true })`）。
List<T> mergeHistoryBy<T>(
  Iterable<T> a,
  Iterable<T> b, {
  required String Function(T item) idOf,
  required String Function(T item) createdAtOf,
}) {
  final Map<String, T> rows = <String, T>{};
  for (final T item in a) {
    rows[idOf(item)] = item;
  }
  for (final T item in b) {
    rows[idOf(item)] = item;
  }
  final List<T> merged = rows.values.toList(growable: false);
  merged.sort((T x, T y) {
    final int byTime = createdAtOf(x).compareTo(createdAtOf(y));
    if (byTime != 0) return byTime;
    return compareNumericIds(idOf(x), idOf(y));
  });
  return merged;
}

/// 数字感知的 id 比较（web `localeCompare(..., { numeric: true })`）。
int compareNumericIds(String a, String b) {
  final int? ai = int.tryParse(a);
  final int? bi = int.tryParse(b);
  if (ai != null && bi != null) return ai.compareTo(bi);
  return a.compareTo(b);
}

/// 游标历史窗口（每页面/每 owner 一份实例）。
class AylaCursorHistory<T> extends ChangeNotifier {
  AylaCursorHistory({
    required this.owner,
    required this.fetchPage,
    required this.idOf,
    required this.createdAtOf,
    this.enabled = true,
  });

  /// owner 键（web `live-history:<uid>:<channelId>` / `voice-chat:<uid>:<channelId>`）。
  final String owner;

  /// 取一页（cursor = 继续位置；beforeId = 窗口脱挂时的续读锚点）。
  final Future<AylaMediaCursorPage<T>?> Function(String? cursor, String? beforeId)
      fetchPage;

  /// id 投影（去重键）。
  final String Function(T item) idOf;

  /// 创建时间投影（排序第一键）。
  final String Function(T item) createdAtOf;

  /// 是否启用（false ⇒ 不拉取，保持初始态；web `enabled`）。
  final bool enabled;

  List<T> _items = <T>[];
  String? _cursor;
  bool _cursorDetached = false;
  bool _hasMore = false;
  bool _hasNewer = false;
  bool _loading = false;
  bool _loaded = false;
  String? _error;
  bool _lastWasOlder = false;
  bool _following = true;
  bool _busy = false;
  final Map<String, T> _pendingLive = <String, T>{};
  final List<String> _seenLive = <String>[];

  int _generation = 0;
  int _invalidationRevision = 0;
  bool _disposed = false;

  /// 请求页面贴底（消费后由页面置回）。
  bool pendingScrollToBottom = false;

  List<T> get items => List<T>.unmodifiable(_items);
  bool get loading => _loading;
  bool get loaded => _loaded;
  String? get error => _error;
  bool get hasMore => _hasMore;
  bool get hasNewer => _hasNewer;
  bool get following => _following;

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

  List<T> _merge(Iterable<T> a, Iterable<T> b) =>
      mergeHistoryBy<T>(a, b, idOf: idOf, createdAtOf: createdAtOf);

  /// 打开/重置（web `useEffect(..., [enabled, owner])`：清状态后拉最新一页）。
  Future<void> reset({bool autoLoad = true}) async {
    _generation++;
    _busy = false;
    _following = true;
    _pendingLive.clear();
    _seenLive.clear();
    _items = <T>[];
    _cursor = null;
    _cursorDetached = false;
    _hasMore = false;
    _hasNewer = false;
    _loading = enabled;
    _loaded = false;
    _error = null;
    pendingScrollToBottom = false;
    _notify();
    if (enabled && autoLoad) await returnLatest();
  }

  Future<bool> loadOlder() async {
    if (!enabled) return false;
    if (!_hasMore || (_cursor == null && !_cursorDetached)) return false;
    return _load(older: true);
  }

  Future<bool> returnLatest() async => _load(older: false);

  Future<bool> retry() async => _load(older: _lastWasOlder);

  Future<bool> _load({required bool older}) async {
    if (!enabled) return false;
    final int request = ++_generation;
    final int revision = _invalidationRevision;
    final String? cursor = older && !_cursorDetached ? _cursor : null;
    final String? beforeId = older && _cursorDetached
        ? (_items.isEmpty ? null : idOf(_items.first))
        : null;
    _busy = true;
    _pendingLive.clear();
    if (older) _following = false;
    _loading = true;
    _error = null;
    _lastWasOlder = older;
    _notify();
    try {
      final AylaMediaCursorPage<T>? page = await fetchPage(cursor, beforeId);
      if (_disposed || _generation != request) return false;
      if (page == null) {
        throw const AylaCursorHistoryException('历史分页响应结构非法');
      }
      if (page.hasMore &&
          (page.nextCursor == null ||
              page.nextCursor == cursor ||
              page.results.isEmpty)) {
        throw const AylaCursorHistoryException('历史分页响应缺少有效的继续位置，请重试');
      }
      final List<T> previous = _items;
      final List<T> merged =
          _merge(older ? previous : <T>[], page.results);
      final T? first = page.results.isEmpty ? null : page.results.first;
      final List<T> liveTail = <T>[];
      if (first != null) {
        for (final T item in _pendingLive.values) {
          final int byTime = createdAtOf(item).compareTo(createdAtOf(first));
          if (byTime > 0 ||
              (byTime == 0 && compareNumericIds(idOf(item), idOf(first)) >= 0)) {
            liveTail.add(item);
          }
        }
      }
      final List<T> latestRows =
          older ? <T>[] : _merge(merged, liveTail);
      final List<T> next = older
          ? (merged.length > kAylaHistoryWindowLimit
              ? merged.sublist(0, kAylaHistoryWindowLimit)
              : merged)
          : (latestRows.length > kAylaHistoryWindowLimit
              ? latestRows.sublist(latestRows.length - kAylaHistoryWindowLimit)
              : latestRows);
      if (older && first != null && !next.any((T i) => idOf(i) == idOf(first))) {
        _loading = false;
        _error = '请先滚动到列表顶部，再加载更早记录';
        _notify();
        return false;
      }
      _following = !older;
      pendingScrollToBottom = !older;
      final bool detached = !older && latestRows.length > kAylaHistoryWindowLimit;
      _items = next;
      _cursor = page.nextCursor;
      _cursorDetached = detached;
      _hasMore = page.hasMore || detached;
      _hasNewer = _invalidationRevision != revision ||
          (older &&
              (_hasNewer ||
                  merged.length > kAylaHistoryWindowLimit ||
                  _pendingLive.isNotEmpty));
      _loading = false;
      _loaded = true;
      _error = null;
      _notify();
      return true;
    } on AylaCursorHistoryException catch (failure) {
      if (!_disposed && _generation == request) {
        _loading = false;
        _error = failure.message;
        _notify();
      }
      return false;
    } catch (_) {
      if (!_disposed && _generation == request) {
        _loading = false;
        _error = '读取历史失败，请重试';
        _notify();
      }
      return false;
    } finally {
      if (_generation == request) _busy = false;
    }
  }

  /// 实时到达（WS 帧 / 乐观回显）——**按 id 幂等**。
  ///
  /// 阅读窗口已脱挂（`hasNewer`）或正在读取（`_busy`）时挂进 `pendingLive`，
  /// 等下一次成功读取再并入（web 原话：「Live arrivals stay outside an older
  /// reading window until the reader returns」）。
  bool append(T item) {
    final String id = idOf(item);
    if (_seenLive.contains(id)) return false;
    _seenLive.add(id);
    if (_seenLive.length > kAylaHistoryWindowLimit * 2) {
      _seenLive.removeAt(0);
    }
    if (_busy) {
      _pendingLive[id] = item;
      if (_pendingLive.length > kAylaHistoryWindowLimit) {
        _pendingLive.remove(_pendingLive.keys.first);
      }
    }
    if (_items.any((T row) => idOf(row) == id)) return false;
    if (!_following || _hasNewer) {
      _hasNewer = true;
      _notify();
      return true;
    }
    pendingScrollToBottom = true;
    final List<T> merged = _merge(_items, <T>[item]);
    final bool evicted = merged.length > kAylaHistoryWindowLimit;
    _items = evicted
        ? merged.sublist(merged.length - kAylaHistoryWindowLimit)
        : merged;
    _cursorDetached = _cursorDetached || evicted;
    _hasMore = _hasMore || evicted;
    _notify();
    return true;
  }

  /// 列表滚动上报（web `handleScroll`：距底 < 40 且无新内容 ⇒ 继续跟随）。
  void setFollowing(bool atBottom) {
    if (_hasNewer) return;
    _following = atBottom;
  }

  /// 标失效（web `invalidate`）：下一次读取走"最新"档。
  void invalidate() {
    _invalidationRevision += 1;
    if (!_hasNewer) {
      _hasNewer = true;
      _notify();
    }
  }

  /// 消费"贴底"请求（页面在 post-frame 里调用）。
  bool consumeScrollToBottom() {
    if (!pendingScrollToBottom) return false;
    pendingScrollToBottom = false;
    return true;
  }

  /// 当前可见的最后一条 id（测试/对账用）。
  String? get lastId => _items.isEmpty ? null : idOf(_items.last);
}
