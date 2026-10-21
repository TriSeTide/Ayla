/// 媒体文件下载（web `MediaContent.tsx` `FileMedia` 的 `<a href download>` 等价）。
///
/// ## 事实源
/// - web：`<a className="file-download" href={signedUrl} download={name}>` —— 浏览器
///   负责「弹保存位置 + 写盘」；
/// - Flutter 侧没有浏览器，等价能力是 `FilePicker.saveFile`：
///   桌面弹**系统保存对话框**、移动端走 SAF / 文件 App（无需额外权限）。
///
/// ## 取字节顺序（与图片查看器一致）
/// 1. 本地漫游缓存命中 → 直接读本地文件（云端过期也能保存）；
/// 2. 未命中 → 带 Bearer 的 `/media/{id}/content`（附件不走预签名直连，
///    与 web 的 `apiRequestBlob(mediaContentUrl(id))` 同路径）。
///
/// 纪律：失败必须抛错（不伪造成功），由 UI 显示「附件加载失败」+ 重试。
library;

import 'dart:io';
import 'dart:typed_data' show Uint8List;

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart' show FilePicker;

import '../models/media_kind.dart' show AylaMediaKind;
import '../net/dio_client.dart' show ApiException, DioClient, kApiPrefix;
import 'media_cache.dart' show AylaMediaCache;

/// 媒体文件下载器。
abstract final class AylaMediaDownload {
  /// 下载并**保存到用户选择的位置**。
  ///
  /// 返回保存路径；用户取消对话框返回 null。
  static Future<String?> save({
    required String mediaId,
    required String fileName,
    void Function(int received, int? total)? onProgress,
  }) async {
    final Uint8List bytes = await readBytes(mediaId, onProgress: onProgress);
    if (bytes.isEmpty) {
      throw ApiException(0, '附件下载失败（内容为空）');
    }
    final Uri? saved = await FilePicker.saveFile(
      fileName: _safeFileName(fileName),
      bytes: bytes,
      dialogTitle: '保存文件',
    );
    return saved?.toFilePath();
  }

  /// 读取媒体原始字节（缓存优先，未命中走鉴权 content 端点）。
  static Future<Uint8List> readBytes(
    String mediaId, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final File? cached = await AylaMediaCache.instance.lookup(
      mediaId,
      kind: AylaMediaKind.file,
    );
    if (cached != null) return cached.readAsBytes();
    try {
      final Response<List<int>> resp =
          await DioClient.instance.dio.get<List<int>>(
        '$kApiPrefix/media/${Uri.encodeComponent(mediaId)}/content',
        options: Options(responseType: ResponseType.bytes),
        onReceiveProgress: onProgress,
      );
      final List<int>? data = resp.data;
      return data == null ? Uint8List(0) : Uint8List.fromList(data);
    } on DioException catch (e) {
      throw ApiException(
        e.response?.statusCode ?? 0,
        '附件下载失败（${e.response?.statusCode ?? e.type.name}）',
      );
    }
  }

  /// 文件名净化（去掉路径分隔符与 Windows 非法字符，防路径穿越）。
  static String _safeFileName(String fileName) {
    final String cleaned =
        fileName.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    if (cleaned.isEmpty) return 'attachment';
    if (cleaned == '.' || cleaned == '..') return 'attachment';
    return cleaned;
  }
}
