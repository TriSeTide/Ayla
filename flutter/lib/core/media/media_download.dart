/// 媒体文件下载（web `MediaContent.tsx` `FileMedia` 的 `<a href download>` 等价）。
///
/// ## 事实源
/// - web：`<a className="file-download" href={signedUrl} download={name}>` —— 浏览器原生
///   下载（签名 URL + `download` 属性，数据面同源）；
/// - Flutter 侧没有原生下载 UI ⇒ 用 dio 带鉴权拉 `/media/{id}/content` 落到**下载目录**
///   （移动端落应用文档目录），返回落盘路径交给调用方提示。
///
/// 纪律：失败必须抛错（不伪造成功），由 UI 显示「附件加载失败」+ 重试。
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../net/dio_client.dart';

/// 媒体文件下载器。
abstract final class AylaMediaDownload {
  /// 下载并落盘，返回保存路径。
  ///
  /// [onProgress]：`(已接收字节, 总字节)`；总字节未知时传 null。
  static Future<String> save({
    required String mediaId,
    required String fileName,
    void Function(int received, int? total)? onProgress,
  }) async {
    final Directory dir = await _targetDirectory();
    final String safeName = _safeFileName(fileName);
    final String target = '${dir.path}${Platform.pathSeparator}$safeName';
    try {
      await DioClient.instance.dio.download(
        '/media/${Uri.encodeComponent(mediaId)}/content',
        target,
        onReceiveProgress: onProgress,
      );
      return target;
    } on DioException catch (e) {
      throw ApiException(
        e.response?.statusCode ?? 0,
        '附件下载失败（${e.response?.statusCode ?? e.type.name}）',
      );
    }
  }

  /// 下载目录：桌面 = 系统下载目录；移动端 = 应用文档目录
  /// （Android 上写系统下载目录需要额外权限与 MediaStore 流程，属页面层接线项）。
  static Future<Directory> _targetDirectory() async {
    if (Platform.isAndroid || Platform.isIOS) {
      return getApplicationDocumentsDirectory();
    }
    final Directory? downloads = await getDownloadsDirectory();
    return downloads ?? await getApplicationDocumentsDirectory();
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
