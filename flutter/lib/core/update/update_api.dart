/// 客户端更新检查 API（GET /updates/check/）。
///
/// 后端契约见 `Ayla/backend/apps/releases/views.py`：
///
/// ```
/// GET /api/v1/updates/check/?channel=stable&platform=windows&arch=x64
///                          &version=1.0.0&build=1
/// 200 {
///   update_available, mandatory, degraded, reason,
///   current: {version, build},
///   latest: {release_id, version, build, published_at, notes, min_supported_build} | null,
///   download: {kind, url, file_name, size, sha256, install_url} | null
/// }
/// ```
///
/// ## 失败语义（工程硬约束：不伪装）
/// - degraded=true / reason=manifest_unavailable：服务端没有可用清单 ⇒ 调用方
///   **不弹窗**、不报错打扰用户（这是部署态，不是用户故障）；同时不得把它说成「已是最新」。
/// - 其它 HTTP 错误 / 网络错误：抛 AylaUpdateException，由调用方决定是否静默。
/// - 解析失败（缺字段/类型不对）：抛异常，**不构造默认 latest**。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

import '../net/api_endpoint.dart';
import '../net/dio_client.dart';
import 'app_version.dart';

/// 平台标识（与后端 ALLOWED_PLATFORMS 对齐）。
String aylaUpdatePlatform() {
  if (kIsWeb) return 'web';
  if (Platform.isWindows) return 'windows';
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isLinux) return 'linux';
  return 'unknown';
}

/// 架构标识（后端按 arch 匹配产物）。
///
/// Android 侧发布脚本只产出 universal APK（签名/渠道在后续版本再拆 ABI），
/// 故这里返回空串，由后端按 universal 规则匹配。
String aylaUpdateArch() {
  if (kIsWeb) return '';
  if (Platform.isAndroid) return '';
  final String raw = Platform.version.toLowerCase();
  if (raw.contains('arm64') || raw.contains('aarch64')) return 'arm64';
  if (raw.contains('arm')) return 'armv7';
  return 'x64';
}

/// 下载描述。
class AylaUpdateDownload {
  const AylaUpdateDownload({
    required this.kind,
    required this.url,
    required this.fileName,
    required this.size,
    required this.sha256,
    this.installUrl,
  });

  /// 产物类型（zip / apk / ipa / msix …）。
  final String kind;

  /// 下载地址（已转成绝对地址；后端返回相对 /releases/... 时由这里补 origin）。
  final String url;

  /// 文件名（落盘用；调用方仍需净化路径字符）。
  final String fileName;

  /// 字节数。
  final int size;

  /// 小写 hex sha256。
  final String sha256;

  /// 平台安装页（iOS itms-services；其余通常为 null）。
  final String? installUrl;

  factory AylaUpdateDownload.fromJson(Object? value) {
    if (value is! Map) {
      throw const AylaUpdateException('download 字段缺失');
    }
    final Map<String, dynamic> json = value.cast<String, dynamic>();
    final String kind = _requireString(json, 'kind');
    final String rawUrl = _requireString(json, 'url');
    final String fileName = _requireString(json, 'file_name');
    final Object? size = json['size'];
    final Object? sha = json['sha256'];
    if (size is! int || size <= 0) {
      throw const AylaUpdateException('download.size 不合法');
    }
    if (sha is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha.toLowerCase())) {
      throw const AylaUpdateException('download.sha256 不合法');
    }
    final Object? install = json['install_url'];
    final String? installUrl =
        install == null || (install is String && install.isEmpty)
        ? null
        : install is String
        ? install
        : throw const AylaUpdateException('download.install_url 不合法');
    return AylaUpdateDownload(
      kind: kind,
      url: _absoluteUrl(rawUrl),
      fileName: fileName,
      size: size,
      sha256: sha.toLowerCase(),
      installUrl: installUrl,
    );
  }
}

/// 最新发布信息。
class AylaUpdateRelease {
  const AylaUpdateRelease({
    required this.releaseId,
    required this.version,
    required this.build,
    required this.publishedAt,
    required this.notes,
    required this.minSupportedBuild,
  });

  final String releaseId;
  final String version;
  final int build;
  final String publishedAt;
  final String notes;
  final int minSupportedBuild;

  String get display => build > 0 ? '$version+$build' : version;

  factory AylaUpdateRelease.fromJson(Object? value) {
    if (value is! Map) {
      throw const AylaUpdateException('latest 字段缺失');
    }
    final Map<String, dynamic> json = value.cast<String, dynamic>();
    final Object? build = json['build'];
    if (build is! int || build <= 0) {
      throw const AylaUpdateException('latest.build 不合法');
    }
    return AylaUpdateRelease(
      releaseId: _requireString(json, 'release_id'),
      version: _requireString(json, 'version'),
      build: build,
      publishedAt: (json['published_at'] ?? '').toString(),
      notes: (json['notes'] ?? '').toString(),
      minSupportedBuild: json['min_supported_build'] is int
          ? json['min_supported_build'] as int
          : 0,
    );
  }
}

/// 检查结果（update_available=false 时 download/latest 可为 null）。
class AylaUpdateCheck {
  const AylaUpdateCheck({
    required this.channel,
    required this.updateAvailable,
    required this.mandatory,
    required this.degraded,
    required this.reason,
    required this.latest,
    required this.download,
    required this.currentVersion,
    required this.currentBuild,
  });

  final String channel;
  final bool updateAvailable;
  final bool mandatory;

  /// 服务端清单不可用（部署态）。**不是**「没有更新」。
  final bool degraded;

  /// update_available / up_to_date / no_release_for_platform / manifest_unavailable。
  final String reason;

  final AylaUpdateRelease? latest;
  final AylaUpdateDownload? download;
  final String currentVersion;
  final int currentBuild;

  /// 本次检查是否有用户可见的更新。
  bool get hasVisibleUpdate =>
      updateAvailable && latest != null && download != null;

  factory AylaUpdateCheck.fromJson(Map<String, dynamic> json) {
    final Object? available = json['update_available'];
    final Object? mandatory = json['mandatory'];
    final Object? degraded = json['degraded'];
    if (available is! bool || mandatory is! bool || degraded is! bool) {
      throw const AylaUpdateException(
        'update_available/mandatory/degraded 字段缺失',
      );
    }
    final Object? current = json['current'];
    final Map<String, dynamic> currentJson = current is Map
        ? current.cast<String, dynamic>()
        : const <String, dynamic>{};
    final AylaUpdateRelease? latest = json['latest'] == null
        ? (available ? AylaUpdateRelease.fromJson(null) : null)
        : AylaUpdateRelease.fromJson(json['latest']);
    final AylaUpdateDownload? download = json['download'] == null
        ? (available ? AylaUpdateDownload.fromJson(null) : null)
        : AylaUpdateDownload.fromJson(json['download']);
    return AylaUpdateCheck(
      channel: (json['channel'] ?? 'stable').toString(),
      updateAvailable: available,
      mandatory: mandatory,
      degraded: degraded,
      reason: (json['reason'] ?? '').toString(),
      latest: latest,
      download: download,
      currentVersion: (currentJson['version'] ?? '').toString(),
      currentBuild: currentJson['build'] is int
          ? currentJson['build'] as int
          : 0,
    );
  }
}

/// 更新链路错误（可直接作为诊断文案；UI 侧另有本地化提示）。
class AylaUpdateException implements Exception {
  const AylaUpdateException(this.message, {this.status});

  final String message;
  final int? status;

  @override
  String toString() => 'AylaUpdateException(${status ?? '-'}): $message';
}

/// 更新检查客户端（无状态；单例语义由调用方持有）。
class AylaUpdateApi {
  const AylaUpdateApi();

  /// 默认渠道。构建脚本通过 --dart-define=AYLA_UPDATE_CHANNEL 覆盖。
  static const String defaultChannel = String.fromEnvironment(
    'AYLA_UPDATE_CHANNEL',
    defaultValue: 'stable',
  );

  Future<AylaUpdateCheck> check({
    required AylaAppVersion version,
    String channel = defaultChannel,
    String? platform,
    String? arch,
  }) async {
    final Map<String, dynamic> response;
    try {
      response = await DioClient.instance.get<Map<String, dynamic>>(
        '/updates/check/',
        query: <String, dynamic>{
          'channel': channel,
          'platform': platform ?? aylaUpdatePlatform(),
          'arch': arch ?? aylaUpdateArch(),
          ...version.query,
        },
      );
    } on ApiException catch (error) {
      throw AylaUpdateException(error.message, status: error.status);
    }
    try {
      return AylaUpdateCheck.fromJson(response);
    } catch (error) {
      if (error is AylaUpdateException) rethrow;
      throw AylaUpdateException('更新响应解析失败：$error');
    }
  }
}

String _requireString(Map<String, dynamic> json, String key) {
  final Object? value = json[key];
  if (value is String && value.trim().isNotEmpty) return value.trim();
  throw AylaUpdateException('$key 字段缺失');
}

String _absoluteUrl(String value) {
  final Uri? uri = Uri.tryParse(value);
  if (uri == null) throw const AylaUpdateException('download.url 不合法');
  if (uri.hasScheme) {
    final String scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      throw const AylaUpdateException('download.url scheme 不合法');
    }
    return uri.toString();
  }
  if (!value.startsWith('/')) {
    throw const AylaUpdateException('download.url 必须是绝对地址或以 / 开头');
  }
  return '${aylaApiBase()}$value';
}
