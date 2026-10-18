/// 更新包下载 + SHA-256 校验（不含解包/安装）。
///
/// 工程约束：
/// - 目标文件只能落在应用缓存/支持目录下的 `updates/`，目录名与文件名都经过路径净化；
/// - 下载先写 `.part`，校验通过后才原子改名为正式文件；任何一步失败都删除临时文件；
/// - 校验两个事实：字节数与清单一致 + SHA-256 与清单一致；不一致抛错，绝不把
///   损坏包交给解包/安装路径；
/// - 下载 URL 使用**独立 Dio**（不带 Authorization）：发布包由 nginx 公共 `/releases/`
///   提供，避免把用户 JWT 发到静态资源路径。
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import 'update_api.dart';

/// 下载进度（字节）。
class AylaUpdateProgress {
  const AylaUpdateProgress({required this.received, required this.total});

  final int received;

  /// 清单里的总字节（0 = 未知）。
  final int total;

  double? get fraction {
    if (total <= 0) return null;
    final double value = received / total;
    if (value < 0) return 0;
    if (value > 1) return 1;
    return value;
  }
}

/// 已下载并校验完成的更新包。
class AylaPreparedUpdate {
  const AylaPreparedUpdate({
    required this.download,
    required this.filePath,
    required this.bytes,
    required this.stagingDir,
  });

  final AylaUpdateDownload download;

  /// 已校验的更新包路径（zip/apk）。
  final String filePath;

  /// 实际字节数（应与 [AylaUpdateDownload.size] 相同）。
  final int bytes;

  /// 本次更新专用的临时目录（解包/脚本都在这里）。
  final String stagingDir;
}

/// 下载器错误（可直接展示给用户；不包含 URL 或本地绝对路径之外的敏感信息）。
class AylaUpdateDownloadException implements Exception {
  const AylaUpdateDownloadException(this.message);

  final String message;

  @override
  String toString() => 'AylaUpdateDownloadException: $message';
}

/// 更新包下载器。
class AylaUpdateDownloader {
  AylaUpdateDownloader({Dio? dio}) : _dio = dio;

  final Dio? _dio;

  /// 单包上限：2 GiB（超过直接拒绝，避免磁盘/内存被异常清单拖垮）。
  static const int maxPackageBytes = 2 * 1024 * 1024 * 1024;

  /// 下载并校验；返回可直接交给 [AylaUpdateApplier] 的产物。
  Future<AylaPreparedUpdate> download(
    AylaUpdateDownload download, {
    void Function(AylaUpdateProgress progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    if (download.size <= 0 || download.size > maxPackageBytes) {
      throw const AylaUpdateDownloadException('更新包大小不合法');
    }
    final String safeName = sanitizeUpdateFileName(download.fileName);
    final Directory root = await _updatesRoot();
    final Directory staging = Directory(
      '${root.path}${Platform.pathSeparator}${_safeDirName(download.sha256)}',
    );
    if (await staging.exists()) {
      await staging.delete(recursive: true);
    }
    await staging.create(recursive: true);
    final String partPath =
        '${staging.path}${Platform.pathSeparator}$safeName.part';
    final String finalPath =
        '${staging.path}${Platform.pathSeparator}$safeName';
    final Dio dio =
        _dio ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 20),
            receiveTimeout: const Duration(minutes: 15),
            followRedirects: true,
            maxRedirects: 5,
          ),
        );
    try {
      await dio.download(
        download.url,
        partPath,
        cancelToken: cancelToken,
        deleteOnError: true,
        onReceiveProgress: (int received, int total) {
          final int expected = total > 0 ? total : download.size;
          onProgress?.call(
            AylaUpdateProgress(received: received, total: expected),
          );
        },
        options: Options(headers: <String, String>{'Accept': '*/*'}),
      );
      final File part = File(partPath);
      final int bytes = await part.length();
      if (bytes != download.size) {
        throw AylaUpdateDownloadException(
          '更新包大小不一致（期望 ${download.size}，实际 $bytes）',
        );
      }
      final String digest = await sha256OfFile(part);
      if (digest != download.sha256) {
        throw const AylaUpdateDownloadException('更新包 SHA-256 校验失败');
      }
      await part.rename(finalPath);
      return AylaPreparedUpdate(
        download: download,
        filePath: finalPath,
        bytes: bytes,
        stagingDir: staging.path,
      );
    } on DioException catch (error) {
      throw AylaUpdateDownloadException(
        '下载失败（${error.response?.statusCode ?? error.type.name}）',
      );
    } on AylaUpdateDownloadException {
      await _deleteQuietly(partPath);
      rethrow;
    } catch (error) {
      await _deleteQuietly(partPath);
      throw AylaUpdateDownloadException('下载失败：$error');
    }
  }

  Future<Directory> _updatesRoot() async {
    final Directory base = Platform.isAndroid || Platform.isIOS
        ? await getTemporaryDirectory()
        : await getApplicationSupportDirectory();
    final Directory root = Directory(
      '${base.path}${Platform.pathSeparator}updates',
    );
    if (!await root.exists()) await root.create(recursive: true);
    return root;
  }
}

/// 更新包文件名净化：只保留最后一段，去掉 Windows/Unix 非法字符与控制字符。
String sanitizeUpdateFileName(String raw) {
  final List<String> parts = raw
      .replaceAll(r'\', '/')
      .split('/')
      .where((String part) => part.isNotEmpty)
      .toList(growable: false);
  final String last = parts.isEmpty ? '' : parts.last;
  final String cleaned = last
      .replaceAll(RegExp(r'[\/:*?"<>|\x00-\x1f]'), '_')
      .trim();
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
    return 'ayla-update.bin';
  }
  return cleaned.length > 180
      ? cleaned.substring(cleaned.length - 180)
      : cleaned;
}

String _safeDirName(String value) {
  final String cleaned = value.replaceAll(RegExp(r'[^0-9a-zA-Z._-]'), '_');
  return cleaned.isEmpty ? 'update' : cleaned;
}

/// 计算文件 SHA-256（流式，不把整包读入内存）。
Future<String> sha256OfFile(File file) async {
  final _DigestSink sink = _DigestSink();
  final Sink<List<int>> input = sha256.startChunkedConversion(sink);
  await for (final List<int> chunk in file.openRead()) {
    input.add(chunk);
  }
  input.close();
  final Digest? digest = sink.value;
  if (digest == null) {
    throw const AylaUpdateDownloadException('无法计算更新包摘要');
  }
  return digest.toString();
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

Future<void> _deleteQuietly(String path) async {
  try {
    final File file = File(path);
    if (await file.exists()) await file.delete();
  } catch (_) {
    // 清理失败不掩盖原始异常（临时目录会在下次更新时整体删除）
  }
}
