/// 游标分页响应 —— web `api/directory.ts:1–9` 的 `DirectoryPage<T>` 等价物。
///
/// 服务端拥有游标顺序；本类只承载一页的可见结果与继续位置：
/// `results` / `next_cursor` / `has_more` / `total` / `total_member_count?`。
///
/// - `total` 是**截断前的匹配总数**（服务端权威），不是 `results.length`；
/// - `totalMemberCount` 仅语音目录返回（侧栏「Y 人在聊」用，`directory.ts:7`）；
/// - 缺字段即缺：`total` 缺省 0、`totalMemberCount` 缺省 null（不伪造在线人数）。
///
/// 纪律（对齐 web 的防御性检查）：`has_more=true` 但 `next_cursor` 缺失/未推进时，
/// 调用方按「游标无效」静默降级（`stores/directory.ts:295–299`），不把它当成成功页。
library;

/// 泛型游标页。
class AylaDirectoryPage<T> {
  const AylaDirectoryPage({
    this.results = const <Never>[],
    this.nextCursor,
    this.hasMore = false,
    this.total = 0,
    this.totalMemberCount,
  });

  /// 本页结果（已按 itemParser 过滤掉非法项）。
  final List<T> results;

  /// 继续位置的游标（null = 没有下一页）。
  final String? nextCursor;

  /// 是否还有更多。
  final bool hasMore;

  /// 服务端截断前的匹配总数。
  final int total;

  /// 语音目录专属：过滤后的成员总数（null = 后端未给）。
  final int? totalMemberCount;

  /// 解析一页；非 Map → 空页（不抛错：空页是合法响应）。
  static AylaDirectoryPage<T> fromJson<T>(
    Object? raw,
    T? Function(Object? raw) parseItem,
  ) {
    if (raw is! Map) return AylaDirectoryPage<T>();
    return AylaDirectoryPage<T>(
      results: <T>[
        for (final Object? item
            in (raw['results'] as List<Object?>? ?? const <Object?>[]))
          if (parseItem(item) case final T parsed) parsed,
      ],
      nextCursor: raw['next_cursor']?.toString(),
      hasMore: raw['has_more'] == true,
      total: (raw['total'] as num?)?.toInt() ?? 0,
      totalMemberCount: (raw['total_member_count'] as num?)?.toInt(),
    );
  }
}
