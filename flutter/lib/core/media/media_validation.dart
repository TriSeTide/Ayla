/// 媒体选择阶段的本地校验与格式化 —— 对齐 web `Ayla/web/src/api/media.ts`（逐条同源）。
///
/// | 本文件 | web |
/// |---|---|
/// | [aylaImageTypes] / [aylaImageUnsupportedMessage] | `media.ts:239–260` |
/// | [aylaVideoTypes] / [aylaVideoUnsupportedMessage] | `media.ts:266–276` |
/// | [aylaFileMaxBytes] / [aylaFileTooLargeMessage] / [aylaFileBlockedMimes] / [aylaFileUnsafeMessage] | `media.ts:279–293` |
/// | [aylaValidateMediaFile] | `media.ts:301–314`（**先按 `;` 去掉 codec 参数**） |
/// | [aylaValidateImageFile] | `media.ts:320–324`（**不去 codec 参数**，web 原文如此） |
/// | [aylaFormatBytes] / [aylaFormatDuration] | `media.ts:202–213` |
///
/// 纪律：这些只做「选择阶段」本地拦截，**服务端三步上传仍会二次校验**（与 web 注释一致）；
/// 本地校验失败不得伪造上传成功或静默丢弃文件，必须把文案交回调用方展示。
library;

import '../models/media_kind.dart';

/// 允许的图片类型（与后端 `media/services` 的 `ALLOWED_MIME['image']` 对齐）。
///
/// 覆盖常见位图 + 现代格式（AVIF/HEIC/HEIF）+ 传统格式（BMP/TIFF/ICO/SVG），
/// 以及系统/浏览器可能上报的别名（`image/jpg`、`image/pjpeg`）。
const Set<String> aylaImageTypes = <String>{
  'image/png',
  'image/jpeg',
  'image/jpg',
  'image/pjpeg',
  'image/gif',
  'image/webp',
  'image/avif',
  'image/heic',
  'image/heif',
  'image/heix',
  'image/bmp',
  'image/x-ms-bmp',
  'image/tiff',
  'image/x-icon',
  'image/vnd.microsoft.icon',
  'image/svg+xml',
};

/// 图片不支持时的文案（web `IMAGE_UNSUPPORTED_MESSAGE`）。
const String aylaImageUnsupportedMessage =
    '仅支持图片文件（PNG/JPEG/GIF/WebP/AVIF/HEIC/BMP/TIFF/ICO/SVG）';

/// 允许的视频类型（与后端 `ALLOWED_MIME['video']` 对齐）：MP4/WebM/MOV/M4V/MKV/3GP。
const Set<String> aylaVideoTypes = <String>{
  'video/mp4',
  'video/webm',
  'video/quicktime',
  'video/x-m4v',
  'video/x-matroska',
  'video/3gpp',
  'video/3gpp2',
};

/// 视频不支持时的文案。
const String aylaVideoUnsupportedMessage = '仅支持视频文件（MP4/WebM/MOV/M4V/MKV/3GP）';

/// 文件类型大小上限（字节）：与后端 `MEDIA_MAX_FILE_BYTES=50MB` 对齐。
const int aylaFileMaxBytes = 50 * 1024 * 1024;

/// 文件超限文案（web 是模板字符串，随 [aylaFormatBytes] 变化）。
final String aylaFileTooLargeMessage =
    '文件超过大小上限（${aylaFormatBytes(aylaFileMaxBytes)}）';

/// 禁用的可执行文档 MIME（与后端 `_FILE_BLOCKED_MIMES` 对齐）：
/// 防止上传后浏览器直接打开执行脚本。
const Set<String> aylaFileBlockedMimes = <String>{
  'text/html',
  'application/xhtml+xml',
  'image/svg+xml',
  'application/javascript',
  'text/javascript',
  'application/x-javascript',
  'application/xml',
  'text/xml',
};

/// 网页/脚本类文件的文案。
const String aylaFileUnsafeMessage = '不支持发送网页/脚本类文件（HTML/SVG/XML/JS）';

/// `validateMediaFile` 的结果：错误文案（合法 = null）+ 可上传的媒体种类。
class AylaMediaValidation {
  const AylaMediaValidation({required this.error, required this.kind});

  /// 不合法时的展示文案；null = 通过。
  final String? error;

  /// 分流用的媒体种类（image / video / file）。
  final AylaMediaKind kind;

  /// 是否通过。
  bool get ok => error == null;
}

/// 选择阶段本地校验（web `validateMediaFile`）：
///
/// - image / video：白名单 + 非空；
/// - 其余格式 → file（任意格式，除可执行文档；大小上限 50MB）。
///
/// ⚠️ MIME 取 `;` 前的主类型（录音/录像输出可能带 codec 参数，如
/// `audio/webm;codecs=opus`，后端 allowlist 只匹配基础类型）。
AylaMediaValidation aylaValidateMediaFile({String? mime, required int size}) {
  final String normalized = (mime ?? '').split(';').first.trim();
  if (aylaImageTypes.contains(normalized)) {
    return AylaMediaValidation(
      error: size <= 0 ? '文件内容为空' : null,
      kind: AylaMediaKind.image,
    );
  }
  if (aylaVideoTypes.contains(normalized)) {
    return AylaMediaValidation(
      error: size <= 0 ? '文件内容为空' : null,
      kind: AylaMediaKind.video,
    );
  }
  // 其余格式 → 文件消息（任意格式，除可执行文档；大小上限 50MB）
  if (size <= 0) {
    return const AylaMediaValidation(
      error: '文件内容为空',
      kind: AylaMediaKind.file,
    );
  }
  if (size > aylaFileMaxBytes) {
    return AylaMediaValidation(
      error: aylaFileTooLargeMessage,
      kind: AylaMediaKind.file,
    );
  }
  if (aylaFileBlockedMimes.contains(normalized)) {
    return const AylaMediaValidation(
      error: aylaFileUnsafeMessage,
      kind: AylaMediaKind.file,
    );
  }
  return const AylaMediaValidation(error: null, kind: AylaMediaKind.file);
}

/// 图片专用本地校验（web `validateImageFile`）：白名单 + 非空；**不限制大小**。
///
/// ⚠️ web 此处**不剥离** codec 参数（直接用原始 `file.type`），
/// 与 [aylaValidateMediaFile] 的归一化不同 —— 忠实保留这一差异。
String? aylaValidateImageFile({String? mime, required int size}) {
  if (!aylaImageTypes.contains(mime)) return aylaImageUnsupportedMessage;
  if (size <= 0) return '图片内容为空';
  return null;
}

/// 字节数 → 展示文案（web `formatBytes`；负数/非有限值返回空串）。
String aylaFormatBytes(int size) {
  if (size < 0) return '';
  if (size < 1024) return '$size B';
  if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
  return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// 秒数 → `m:ss`（web `formatDuration`；null/非有限值返回空串，负值归零）。
String aylaFormatDuration(double? seconds) {
  if (seconds == null || !seconds.isFinite) return '';
  final int total = seconds.round() < 0 ? 0 : seconds.round();
  final String minutes = (total ~/ 60).toString();
  final String rest = (total % 60).toString().padLeft(2, '0');
  return '$minutes:$rest';
}
