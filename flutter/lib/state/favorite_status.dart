/// 收藏状态机 —— web `stores/favoriteStatus.ts` 131 行的 Flutter 等价物（精简：
/// 按类型批量查询 + 60s 新鲜期 + 动作）。
///
/// ## 逐条对应的 web 语义
/// - 键 = `"<type>:<id>"`（`favoriteStatus.ts:18`）；
/// - **状态未知 ≠ 未收藏**：`favoriteId === undefined` 是「没查过/查询中」，
///   `null` 才是「未收藏」（`favoriteStatus.ts:1–2` 的注释，是这套状态机的核心不变量）；
/// - 单次查询上限 100 个 id（`favoriteStatus.ts:86` 的 `slice(0, 100)` 与
///   `api/favorites.ts:25` 的硬上限）；
/// - 60s 内不重复查询（`favoriteStatus.ts:121`）；
/// - 响应必须覆盖请求的每个 id，否则视为**不完整**并报错（`favoriteStatus.ts:93`）；
/// - 点按钮时若状态未知/出错 ⇒ 点击 = **重新拉取状态**（不是收藏）
///   （`FavoriteButton.tsx:35–38`）——本类把这条做成 [toggle] 内的分支。
///
/// ## 未实现（登记）
/// web 的 drain 队列（并发 2、跨组件合并同类型请求）与 1024 条 LRU 淘汰未复刻：
/// 本轮页面每次只 retain 当前可见页的 id，且逐页调用 [load]；WS 的
/// `favorite.changed` 增量（`applyFavoriteStatus`）随 WS 接线批次补。
library;

import 'package:flutter/foundation.dart';

import '../core/api/favorites_api.dart';
import '../widgets/base/favorite_button.dart' show AylaFavoriteState;

/// 单个目标的收藏状态。
class AylaFavoriteEntryStatus {
  const AylaFavoriteEntryStatus({
    this.known = false,
    this.favoriteId,
    this.loading = false,
    this.error,
    this.updatedAt = 0,
  });

  /// 是否已查到过状态（web `favoriteId !== undefined`）。
  final bool known;

  /// 收藏 id（[known] 为 true 时：null = 未收藏，数字 = 已收藏）。
  final int? favoriteId;

  final bool loading;
  final String? error;

  /// 写入时间（ms epoch；60s 新鲜期判定用）。
  final int updatedAt;
}

/// 状态查询（注入以便纯逻辑测试）。
typedef AylaFavoriteStatusFetcher = Future<AylaFavoriteStatuses> Function(
  String targetType,
  List<String> targetIds,
);

/// 收藏 / 取消收藏（注入以便纯逻辑测试）。
typedef AylaFavoriteAdd = Future<int> Function(
  String targetType,
  String targetId,
);
typedef AylaFavoriteRemove = Future<void> Function(int favoriteId);

/// 收藏状态 Notifier：三域卡片 / 搜索结果 / 收藏页共用。
class AylaFavoriteStatusController extends ChangeNotifier {
  AylaFavoriteStatusController({
    AylaFavoriteStatusFetcher? fetcher,
    AylaFavoriteAdd? add,
    AylaFavoriteRemove? remove,
  })  : _fetch = fetcher ?? AylaFavoritesApi.getFavoriteStatuses,
        _add = add ?? AylaFavoritesApi.addFavorite,
        _remove = remove ?? AylaFavoritesApi.removeFavorite;

  final AylaFavoriteStatusFetcher _fetch;
  final AylaFavoriteAdd _add;
  final AylaFavoriteRemove _remove;

  /// 状态新鲜期（web 60_000ms）。
  static const Duration freshFor = Duration(seconds: 60);

  /// 单次批量查询上限（web `slice(0, 100)`）。
  static const int batchLimit = 100;

  final Map<String, AylaFavoriteEntryStatus> _entries =
      <String, AylaFavoriteEntryStatus>{};
  final Map<String, String?> _actionErrors = <String, String?>{};
  final Set<String> _busy = <String>{};
  int _revision = 0;
  bool _disposed = false;

  /// 状态键（web `favoriteStatusKey`）。
  static String keyOf(String targetType, String targetId) =>
      '$targetType:$targetId';

  /// 按钮三态（+ 错误态）。
  AylaFavoriteState stateOf(String targetType, String targetId) {
    final AylaFavoriteEntryStatus? entry = _entries[keyOf(targetType, targetId)];
    if (entry == null) return AylaFavoriteState.unknown;
    if (entry.error != null && entry.known == false) {
      return AylaFavoriteState.error;
    }
    if (entry.loading && entry.known == false) return AylaFavoriteState.unknown;
    if (!entry.known) return AylaFavoriteState.unknown;
    return entry.favoriteId != null
        ? AylaFavoriteState.favorited
        : AylaFavoriteState.notFavorited;
  }

  /// 收藏 id（未查到 → null；已查到未收藏 → null）。用于收藏页的跳转/联动。
  int? favoriteIdOf(String targetType, String targetId) =>
      _entries[keyOf(targetType, targetId)]?.favoriteId;

  /// 操作失败文案（web 按钮内的 `actionError`）。
  String? actionErrorOf(String targetType, String targetId) =>
      _actionErrors[keyOf(targetType, targetId)];

  /// 是否正在切换收藏（web 按钮内的 `busy`）。
  bool busyOf(String targetType, String targetId) =>
      _busy.contains(keyOf(targetType, targetId));

  /// 查询状态。[force] = 忽略新鲜期与在途标记（web `loadFavoriteStatuses(..., true)`）。
  Future<void> load(
    String targetType,
    List<String> targetIds, {
    bool force = false,
  }) async {
    if (_disposed) return;
    final int now = DateTime.now().millisecondsSinceEpoch;
    final List<String> pending = <String>[];
    for (final String id in targetIds.toSet()) {
      final String key = keyOf(targetType, id);
      final AylaFavoriteEntryStatus current =
          _entries[key] ?? const AylaFavoriteEntryStatus();
      if (current.loading) continue;
      if (!force &&
          current.known &&
          current.error == null &&
          now - current.updatedAt < freshFor.inMilliseconds) {
        continue;
      }
      _entries[key] = AylaFavoriteEntryStatus(
        known: current.known,
        favoriteId: current.favoriteId,
        loading: true,
        updatedAt: current.updatedAt,
      );
      pending.add(id);
    }
    if (pending.isEmpty) return;
    _notify();
    for (int start = 0; start < pending.length; start += batchLimit) {
      final List<String> slice = pending.sublist(
        start,
        (start + batchLimit).clamp(0, pending.length),
      );
      final int revision = ++_revision;
      final Map<String, int> expected = <String, int>{
        for (final String id in slice)
          id: (_entries[keyOf(targetType, id)] ?? const AylaFavoriteEntryStatus())
              .updatedAt,
      };
      try {
        final AylaFavoriteStatuses response = await _fetch(targetType, slice);
        if (_disposed || revision > _revision) continue;
        final bool incomplete = response.targetType != targetType ||
            slice.any((String id) => !response.statuses.containsKey(id));
        if (incomplete) throw StateError('收藏状态响应不完整，请重试');
        for (final String id in slice) {
          final String key = keyOf(targetType, id);
          final AylaFavoriteEntryStatus current =
              _entries[key] ?? const AylaFavoriteEntryStatus();
          if (current.updatedAt != expected[id]) continue; // 已被更新的写入覆盖
          _entries[key] = AylaFavoriteEntryStatus(
            known: true,
            favoriteId: response.statuses[id],
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          );
        }
      } catch (err) {
        if (_disposed || revision > _revision) continue;
        for (final String id in slice) {
          final String key = keyOf(targetType, id);
          final AylaFavoriteEntryStatus current =
              _entries[key] ?? const AylaFavoriteEntryStatus();
          if (current.updatedAt != expected[id]) continue;
          _entries[key] = AylaFavoriteEntryStatus(
            known: current.known,
            favoriteId: current.favoriteId,
            error: err is Exception ? _messageOf(err) : '收藏状态加载失败',
            updatedAt: current.updatedAt,
          );
        }
      }
    }
    _notify();
  }

  /// 切换收藏。状态未知/出错时退化为**重新拉取状态**（web 行为），不发收藏请求。
  Future<void> toggle(String targetType, String targetId) async {
    if (_disposed) return;
    final String key = keyOf(targetType, targetId);
    final AylaFavoriteEntryStatus current =
        _entries[key] ?? const AylaFavoriteEntryStatus();
    if (current.error != null || !current.known) {
      await load(targetType, <String>[targetId], force: true);
      return;
    }
    if (_busy.contains(key)) return;
    final int revision = _revision;
    _busy.add(key);
    _actionErrors[key] = null;
    _notify();
    try {
      final int? favoriteId = current.favoriteId;
      int? next;
      if (favoriteId != null) {
        await _remove(favoriteId);
        next = null;
      } else {
        next = await _add(targetType, targetId);
      }
      if (_disposed || revision > _revision) return;
      _entries[key] = AylaFavoriteEntryStatus(
        known: true,
        favoriteId: next,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
    } catch (err) {
      if (_disposed || revision > _revision) return;
      _actionErrors[key] =
          err is Exception ? _messageOf(err) : '收藏操作失败，请重试';
    } finally {
      if (!_disposed) {
        _busy.remove(key);
        _notify();
      }
    }
  }

  /// 直接写入状态（WS `favorite.changed` / 收藏页本地删除后对账用）。
  void apply(String targetType, String targetId, int? favoriteId) {
    _entries[keyOf(targetType, targetId)] = AylaFavoriteEntryStatus(
      known: true,
      favoriteId: favoriteId,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _actionErrors.remove(keyOf(targetType, targetId));
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  static String _messageOf(Object err) {
    final String text = err.toString();
    // ApiException.toString() = "ApiException(<status>, <message>)" —— 取可读消息。
    final RegExpMatch? m =
        RegExp(r'^[A-Za-z]+((d+), (.*))$').firstMatch(text);
    return m == null ? text : m.group(2)!;
  }
}
