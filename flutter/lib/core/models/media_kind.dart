/// 媒体种类（`Ayla/web/src/api/types.ts:186`）—— 后端 `MediaKind` 的 Dart 对应。
///
/// 从 `core/models/post.dart` 抽出（2026-09-20）：媒体上传/校验与帖子无关，
/// 不应让 `core/media/*` 依赖帖子模型。`post.dart` 仍 `export` 本文件，
/// 既有调用点不受影响。
library;

/// 媒体种类（`types.ts:186`：image / voice / file / emoji / video）。
enum AylaMediaKind {
  image,
  voice,
  file,
  emoji,
  video;

  /// 后端字段值（`kind`）。
  String get wire => name;

  /// 未知种类返回 null（**不 fallback 成 image**）。
  static AylaMediaKind? parse(String? raw) => switch (raw) {
        'image' => AylaMediaKind.image,
        'voice' => AylaMediaKind.voice,
        'file' => AylaMediaKind.file,
        'emoji' => AylaMediaKind.emoji,
        'video' => AylaMediaKind.video,
        _ => null,
      };
}
