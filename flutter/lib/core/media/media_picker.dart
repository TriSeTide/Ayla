/// 选择本地媒体文件（选择阶段）—— 对齐 web 的 `<input type="file">` 流程。
///
/// web 侧：`validateMediaFile(file)` 在 onChange 里本地校验 → `uploadMediaFile` 三步上传。
/// Flutter 侧把两步分开：本模块负责「选文件 + 本地校验」，上传交给
/// [AylaMediaUploader]（便于「选择 → 预览 → 发送」的交互，也便于测试）。
///
/// 平台实现走 `file_picker`（用户 2026-09-20 选定）；后端可注入（测试替身）。
library;

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../models/media_kind.dart';
import 'media_validation.dart';

/// 选中的本地文件（web `File` 的投影）。
///
/// 数据读取以 [readBytes] 回调暴露：桌面/移动走文件读取、web 走内存，
/// 由后端实现决定；测试可注入任意实现（不必碰平台通道）。
class AylaPickedFile {
  const AylaPickedFile({
    required this.name,
    required this.size,
    required this.mimeType,
    required this.readBytes,
    this.path,
  });

  /// 文件名（含扩展名）。
  final String name;

  /// 字节数（平台未报告时为 0 → 校验按「内容为空」拦截，**不猜测**）。
  final int size;

  /// MIME（由扩展名推断；未知 = `application/octet-stream`）。
  final String mimeType;

  /// 读取全部字节（上传用）。
  final Future<Uint8List> Function() readBytes;

  /// 本地路径（桌面/移动端；null = 无本地路径，如 web blob）。
  final String? path;
}

/// 选择类型（对应 web 三条 input 的 `accept`）。
enum AylaPickKind {
  /// 图片（`image/*`，白名单与 [aylaImageTypes] 一致）。
  image,

  /// 视频（`video/*`）。
  video,

  /// 任意文件（除可执行文档，见 [aylaFileBlockedMimes]）。
  file,
}

/// 选择结果：文件列表 + 错误文案（**取消选择不是错误**，也不伪造文件）。
class AylaPickResult {
  const AylaPickResult({this.files = const <AylaPickedFile>[], this.error});

  /// 通过本地校验的文件（可能为空 = 用户取消）。
  final List<AylaPickedFile> files;

  /// 校验失败文案（交调用方展示；null = 无错误）。
  final String? error;

  /// 是否有可用文件。
  bool get ok => error == null && files.isNotEmpty;
}

/// 选文件后端（默认 [AylaFilePickerBackend]；测试注入替身，避免平台通道）。
abstract interface class AylaPickerBackend {
  /// 打开系统选择器；用户取消返回空列表。
  Future<List<AylaPickedFile>> pick({
    required AylaPickKind kind,
    bool multiple = false,
  });
}

/// 生产后端：`file_picker`。
class AylaFilePickerBackend implements AylaPickerBackend {
  const AylaFilePickerBackend();

  static const List<String> _imageExtensions = <String>[
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'avif', 'heic', 'heif',
    'bmp', 'tiff', 'ico', 'svg',
  ];
  static const List<String> _videoExtensions = <String>[
    'mp4', 'webm', 'mov', 'm4v', 'mkv', '3gp', '3gpp',
  ];

  @override
  Future<List<AylaPickedFile>> pick({
    required AylaPickKind kind,
    bool multiple = false,
  }) async {
    // file_picker 13：`pickFiles` 恒返回列表（空 = 取消），`pickFile` 返回单个或 null。
    final List<PlatformFile> picked;
    if (multiple) {
      picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: _extensionsFor(kind),
      );
    } else {
      final PlatformFile? single = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: _extensionsFor(kind),
      );
      picked = single == null ? const <PlatformFile>[] : <PlatformFile>[single];
    }

    final List<AylaPickedFile> out = <AylaPickedFile>[];
    for (final PlatformFile file in picked) {
      final int? known = file.lengthSync() ?? await file.length();
      out.add(
        AylaPickedFile(
          name: file.name,
          size: known ?? 0,
          mimeType: aylaMimeFromName(file.name),
          path: file.path,
          readBytes: file.readAsBytes,
        ),
      );
    }
    return out;
  }

  /// 白名单扩展名（与 [aylaImageTypes] / [aylaVideoTypes] 同源）；
  /// 任意文件不给扩展名过滤（`FileType.custom` 需非空 → 用 `FileType.any`）。
  List<String>? _extensionsFor(AylaPickKind kind) => switch (kind) {
        AylaPickKind.image => _imageExtensions,
        AylaPickKind.video => _videoExtensions,
        AylaPickKind.file => null,
      };
}

/// 选择入口：选文件 + 本地校验（错误文案交回调用方，**不伪造成功**）。
class AylaMediaPicker {
  AylaMediaPicker._();

  /// 当前后端（测试可替换；生产用 [AylaFilePickerBackend]）。
  static AylaPickerBackend backend = const AylaFilePickerBackend();

  /// 选图片（默认多选；逐张走 `validateImageFile`）。
  static Future<AylaPickResult> pickImages({bool multiple = true}) =>
      _pick(AylaPickKind.image, multiple: multiple);

  /// 选视频（单选；走 `validateMediaFile` 的 video 分支）。
  static Future<AylaPickResult> pickVideo() =>
      _pick(AylaPickKind.video, multiple: false);

  /// 选任意文件（单选；走 `validateMediaFile` 的 file 分支）。
  static Future<AylaPickResult> pickFile() =>
      _pick(AylaPickKind.file, multiple: false);

  static Future<AylaPickResult> _pick(
    AylaPickKind kind, {
    required bool multiple,
  }) async {
    final List<AylaPickedFile> picked = await backend.pick(
      kind: kind,
      multiple: multiple,
    );
    if (picked.isEmpty) return const AylaPickResult(); // 用户取消：非错误

    final List<AylaPickedFile> accepted = <AylaPickedFile>[];
    for (final AylaPickedFile file in picked) {
      final String? error = _validate(kind, file);
      if (error != null) return AylaPickResult(files: accepted, error: error);
      accepted.add(file);
    }
    return AylaPickResult(files: accepted);
  }

  /// 按选择类型走对应的本地校验（与 web 同源：图片走 validateImageFile，
  /// 视频/文件走 validateMediaFile）。
  static String? _validate(AylaPickKind kind, AylaPickedFile file) {
    switch (kind) {
      case AylaPickKind.image:
        return aylaValidateImageFile(mime: file.mimeType, size: file.size);
      case AylaPickKind.video:
        final AylaMediaValidation v = aylaValidateMediaFile(
          mime: file.mimeType,
          size: file.size,
        );
        return v.kind == AylaMediaKind.video ? v.error : aylaVideoUnsupportedMessage;
      case AylaPickKind.file:
        final AylaMediaValidation v = aylaValidateMediaFile(
          mime: file.mimeType,
          size: file.size,
        );
        // 文件选择一律按 file 处理（与 web `validateMediaFile` 的兜底分支一致）
        return v.kind == AylaMediaKind.file ? v.error : null;
    }
  }
}

/// 由文件名扩展名推断 MIME（`file_picker` 不提供 MIME；web 有 `file.type`）。
///
/// 只覆盖白名单与常见类型；未知 → `application/octet-stream`
/// （`validateMediaFile` 会把它归为 file，与 web 的未知 `file.type` 同义）。
String aylaMimeFromName(String name) {
  final int dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return _octetStream;
  final String ext = name.substring(dot + 1).toLowerCase();
  return _mimeByExtension[ext] ?? _octetStream;
}

const String _octetStream = 'application/octet-stream';

const Map<String, String> _mimeByExtension = <String, String>{
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'avif': 'image/avif',
  'heic': 'image/heic',
  'heif': 'image/heif',
  'bmp': 'image/bmp',
  'tif': 'image/tiff',
  'tiff': 'image/tiff',
  'ico': 'image/vnd.microsoft.icon',
  'svg': 'image/svg+xml',
  'mp4': 'video/mp4',
  'webm': 'video/webm',
  'mov': 'video/quicktime',
  'm4v': 'video/x-m4v',
  'mkv': 'video/x-matroska',
  '3gp': 'video/3gpp',
  '3gpp': 'video/3gpp2',
  'pdf': 'application/pdf',
  'zip': 'application/zip',
  'txt': 'text/plain',
  'html': 'text/html',
  'xml': 'application/xml',
  'js': 'application/javascript',
  'json': 'application/json',
};
