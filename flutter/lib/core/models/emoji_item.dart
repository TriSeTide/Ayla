/// 表情项（`Ayla/web/src/api/types.ts:165–170` `EmojiItem` 的 Dart 对应）。
///
/// 群表情包面板（`EmojiPackPanel.tsx`）的列表项：`media` 是完整 descriptor
/// （缺失 = 未展开/已删，按 null 处理，不造占位描述符）。
library;

import 'post.dart' show AylaMediaDescriptor;

/// 表情项（`EmojiItemSerializer`）。
class AylaEmojiItem {
  const AylaEmojiItem({
    required this.id,
    this.media,
    this.tag = '',
    this.createdAt,
  });

  final String id;

  /// 媒体 descriptor（null = 不可用，渲染时跳过本体）。
  final AylaMediaDescriptor? media;

  /// 分类标签（群表情包当前不分组，保留后端原值）。
  final String tag;

  final String? createdAt;

  /// 解析；缺 `id` 视为非法 → null。
  static AylaEmojiItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    if (id == null) return null;
    return AylaEmojiItem(
      id: id.toString(),
      media: AylaMediaDescriptor.fromJson(raw['media']),
      tag: (raw['tag'] as String?) ?? '',
      createdAt: raw['created_at'] as String?,
    );
  }

  static List<AylaEmojiItem> listFromJson(Object? raw) {
    if (raw is! List) return const <AylaEmojiItem>[];
    return raw
        .map(AylaEmojiItem.fromJson)
        .whereType<AylaEmojiItem>()
        .toList(growable: false);
  }
}
