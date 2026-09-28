/// 游标分页列表状态机 —— web `stores/directory.ts` 的 `loadDirectory` 里
/// 「一页一取、游标推进、在途作废」那部分的 Flutter 等价物。
///
/// ## 为什么是 ChangeNotifier 而不是 provider 缓存
/// web 的 directory store 是**跨页共享 + WS 增量对账**的（`useDirectoryStore`）；
/// Flutter 侧本轮页面（VoiceHub / LiveHub / GamesHub / Favorites）只需「按当前分类
/// 独立游标取页」这一层，WS 增量对账属后续接线 ⇒ 只实现 [AylaPagedList]：
/// 每个页面（或每个分类 tab）持有一个实例，切 tab 直接换实例（等价 web 的
/// `filter` 进 directory key ⇒ 每个 tab 独立游标）。
///
/// ## 逐条对应的 web 语义（`stores/directory.ts:264–341`）
/// - 首页取 `cursor=null`；追加取当前 `nextCursor`；
/// - `has_more && (!next_cursor || next_cursor === cursor)` ⇒ **游标无效**：
///   静默降级（停止 loading，不报错、不把它当成功页）；
/// - 错误只写 `error`，**保留已加载 items**（footer 显示错误 + 重试）；
/// - 在途请求的 revision 守卫：切 tab / 重新加载后，旧响应一律丢弃。
///
/// ## 未实现（登记）
/// - web 的 `fetchedAt` 60s 内首屏复用缓存跳过一次请求（`directory.ts:274`）——
///   Flutter 侧无跨页缓存，每次进入页面按需请求；
/// - WS 增量（`createdIds` / `recentlyRemoved` / `invalidated` 自动重取）属
///   后续批次；`invalidated` 字段保留给 [AylaDirectoryLoadMore] 的契约。
library;

import 'package:flutter/foundation.dart';

import '../core/api/directory_page.dart';
import '../core/net/dio_client.dart' show ApiException;

/// 取一页的请求函数（cursor 为 null = 首页）。
typedef AylaPageRequest<T> = Future<AylaDirectoryPage<T>> Function(
  String? cursor,
);

/// 单分类的游标分页列表。
class AylaPagedList<T> extends ChangeNotifier {
  AylaPagedList({
    required this.request,
    required this.keyOf,
    this.pageSize = 20,
  });

  /// 取页请求（由页面注入具体 api 调用）。
  final AylaPageRequest<T> request;

  /// 条目标识（web 合并页时用 `String(item.id)`；收藏/搜索等按各自主键注入）。
  final String Function(T item) keyOf;

  /// 页大小（web 六个目录页均为 20：`stores/directory.ts:284`）。
  final int pageSize;

  List<T> _items = <T>[];
  bool _loading = false;
  bool _loaded = false;
  bool _hasMore = false;
  final bool _invalidated = false;
  String? _error;
  String? _nextCursor;
  int _total = 0;
  int? _totalMemberCount;
  int _revision = 0;
  bool _busy = false;
  bool _disposed = false;

  /// 已加载的条目（刷新后整体替换，追加后合并）。
  List<T> get items => List<T>.unmodifiable(_items);

  /// 是否正在请求。
  bool get loading => _loading;

  /// 是否已成功取到过至少一页（决定首屏骨架 vs 空态）。
  bool get loaded => _loaded;

  /// 是否还有下一页。
  bool get hasMore => _hasMore;

  /// 数据被并发更新（WS 增量场景；本轮恒 false）。
  bool get invalidated => _invalidated;

  /// 最近一次请求的错误（null = 无错误）。
  String? get error => _error;

  /// 服务端截断前总数。
  int get total => _total;

  /// 语音目录的成员总数（null = 后端未给 / 非语音目录）。
  int? get totalMemberCount => _totalMemberCount;

  /// 取页。[append] = true 走下一页，否则重取首页。
  ///
  /// - 追加前置条件：必须有 `hasMore` 且 `nextCursor` 非空，且当前无在途请求；
  /// - 重取首页：使在途请求作废（revision 递增）后发起，结果回来后整体替换。
  Future<void> load({bool append = false}) async {
    if (_disposed) return;
    if (append && (_busy || !_hasMore || _nextCursor == null)) return;
    if (append && _nextCursor == _lastCursor) return;
    final String? cursor = append ? _nextCursor : null;
    final int revision = ++_revision;
    _busy = true;
    _loading = true;
    _error = null;
    _notify();
    try {
      final AylaDirectoryPage<T> page = await request(cursor);
      if (_disposed || revision != _revision) return;
      _lastCursor = cursor;
      if (page.hasMore && (page.nextCursor == null || page.nextCursor == cursor)) {
        // 游标无效（防御性检查，正常不触发）：静默降级，不打扰用户。
        _loading = false;
        _busy = false;
        _notify();
        return;
      }
      final Map<String, T> merged = <String, T>{};
      if (append) {
        for (final T item in _items) {
          merged[keyOf(item)] = item;
        }
      }
      for (final T item in page.results) {
        merged[keyOf(item)] = item;
      }
      _items = merged.values.toList(growable: false);
      _nextCursor = page.nextCursor;
      _hasMore = page.hasMore;
      _total = page.total;
      _totalMemberCount = page.totalMemberCount;
      _loaded = true;
    } catch (err) {
      if (_disposed || revision != _revision) return;
      // 失败保留已加载内容（web 同：错误只影响 footer）。
      _error = err is ApiException ? err.message : '加载列表失败';
    } finally {
      if (!_disposed && revision == _revision) {
        _loading = false;
        _busy = false;
        _notify();
      }
    }
  }

  /// 上一次请求使用的游标（用于「游标未推进」的防御性判定）。
  String? _lastCursor;

  /// 本地替换条目（web `updateSocialItems`：处理完一条申请后把它从列表里去掉）。
  ///
  /// - `total` 按条目数增减同步（web `Math.max(0, total + items.length - previous.items.length)`）；
  /// - 只动**已加载投影**，不改变游标与 `hasMore`（下一页仍按原游标取）。
  void setItems(List<T> items) {
    final List<T> next = List<T>.unmodifiable(items);
    if (next.length == _items.length) {
      bool same = true;
      for (int i = 0; i < next.length; i++) {
        if (!identical(next[i], _items[i])) {
          same = false;
          break;
        }
      }
      if (same) return;
    }
    final int total = _total + next.length - _items.length;
    _items = next;
    _total = total < 0 ? 0 : total;
    _notify();
  }

  /// 按判据移除条目（[setItems] 的常用包装）。
  void removeWhere(bool Function(T item) test) {
    setItems(<T>[
      for (final T item in _items)
        if (!test(item)) item,
    ]);
  }

  /// 重取首页（刷新键 / 下拉刷新共用）。
  Future<void> refresh() => load();

  /// 追加下一页。
  Future<void> loadMore() => load(append: true);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++; // 让在途请求的结果失效
    super.dispose();
  }
}
