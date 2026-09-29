/// 媒体/记录游标页 —— web `api/mediaPagination.ts` 的 `MediaPage<T>` 等价物。
///
/// 与 `directory_page.dart`（目录专用，多 `total` / `total_member_count`）分开：
/// 本类对应 `{results, next_cursor, has_more}` 的**通用游标页**，被三处消费：
/// 语音房内聊天历史（`/voice/channels/<id>/messages/`）、直播弹幕历史
/// （`/live/channels/<id>/danmaku/`）、语音成员可见分页
/// （`/voice/channels/<id>/members/`）。
///
/// 纪律（沿用目录页口径）：`has_more=true` 但 `next_cursor` 缺失/未推进 ⇒
/// **显式失败**（返回 null 由调用方报「分页响应缺少有效的继续位置」），
/// 不把游标跳到尾部伪装连续（AGENTS.md §5.1）。
library;

/// 通用游标页。
class AylaMediaCursorPage<T> {
  const AylaMediaCursorPage({
    required this.results,
    this.nextCursor,
    this.hasMore = false,
    this.total = 0,
  });

  final List<T> results;

  /// 继续位置（`next_cursor`；null = 无）。
  final String? nextCursor;

  /// 还有更多。
  final bool hasMore;

  /// 总数（`total`；web `MediaPage<T>.total`，成员面板的「N 人」用它）。
  final int total;

  /// 解析响应；结构非法（非 Map / results 非 List）⇒ null。
  static AylaMediaCursorPage<T>? parse<T>(
    Object? raw,
    T? Function(Object? item) itemFromJson,
  ) {
    if (raw is! Map) return null;
    final Object? results = raw['results'];
    if (results is! List) return null;
    return AylaMediaCursorPage<T>(
      results: <T>[
        for (final Object? item in results)
          if (itemFromJson(item) case final T parsed) parsed,
      ],
      nextCursor: raw['next_cursor']?.toString(),
      hasMore: raw['has_more'] == true,
      total: (raw['total'] as num?)?.toInt() ?? 0,
    );
  }
}
