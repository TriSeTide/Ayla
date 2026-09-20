/// 媒体签名链路（`web/src/api/media.ts` 的 Flutter 等价）。
///
/// ## 事实源（`api/media.ts` 逐条对照）
///
/// ```
/// getSignedMediaUrlState(mediaId, variant?)
///   · 缓存 key = variant ? `${mediaId}|${variant}` : mediaId
///   · 命中且 `expiresAt - 60 > now` → 直接返回（**到期前 60s 主动重签**）
///   · 同一 key 有 inflight → 复用同一 Promise（**并发只签发一次**）
///   · POST `/media/<id>:sign`（body: {variant} 或空）
///   · 响应 `{ url, expires_at }` → url 经 `toSameOriginMinio()` 转 `/minio` 同源代理
///   · **410 分级降级**：
///       - variant=thumb 收到 410 → 完全过期 → 抛 MediaExpiredError
///       - variant=original 收到 410 → 原图已删（阶段 1）→ **自动改签 thumb**，
///         返回缩略图 url 且 `originalExpired = true`
///       - thumb 再 410/404 → 完全过期 → MediaExpiredError
///   · 其它错误 → 清缓存（允许下次重试）并抛出
/// invalidateSignedMediaUrl(mediaId)  → 清 `mediaId` 与其所有 `|variant` 条目
/// ```
///
/// ## 使用（`ResourceImage`）
/// 由 [MediaSigner] 统一签发；失败清缓存后下次进入会重签，因此 UI 侧
/// 「点重试」= `invalidate` + 重建即可。
library;

import 'dart:async';

import '../net/dio_client.dart';

/// 签名结果（`SignedMediaResult`）。
class SignedMediaResult {
  const SignedMediaResult({required this.url, required this.originalExpired});

  /// 可直接用于 `<img src>` / `<video src>` 的短时签名 URL。
  final String url;

  /// `original` 已过期（图片阶段 1，7 天）：[url] 已自动降级为缩略图签名，
  /// 调用方应显示「原图已过期」角标。
  final bool originalExpired;
}

/// 媒体已完全过期（`MediaExpiredError`）：对象已删除，UI 显示「已过期」占位，
/// **不重试**（重试无意义）。
class MediaExpiredError implements Exception {
  const MediaExpiredError();

  @override
  String toString() => 'MediaExpiredError: media_expired';
}

/// 媒体变体（`variant`）：`thumb` = 气泡缩略图；null = original（查看器/保存）。
enum MediaVariant { thumb }

class _CacheEntry {
  _CacheEntry({required this.url, required this.expiresAt, this.originalExpired = false, this.inflight});

  String url;

  /// 过期时间戳（秒）。
  double expiresAt;

  bool originalExpired;

  Future<SignedMediaResult>? inflight;
}

/// 签名服务（模块级缓存，页面生命周期内复用；对应 media.ts 的 `signedUrlCache`）。
class MediaSigner {
  MediaSigner._();

  /// 单例（web 是模块级 Map，等价于进程级唯一）。
  static final MediaSigner instance = MediaSigner._();

  /// 到期前主动重签的提前量（media.ts：`expiresAt - 60 > now`）。
  static const double renewAheadSeconds = 60;

  final Map<String, _CacheEntry> _cache = <String, _CacheEntry>{};

  DioClient? _client;

  /// 注入 API 客户端（app 启动或测试时设置）。
  void attach(DioClient client) => _client = client;

  /// 解除注入并清空缓存（登出、测试隔离）。
  ///
  /// 登出时必须调用：缓存里的签名 URL 属上一个会话，继续复用会 403。
  void detach() {
    _client = null;
    _cache.clear();
  }

  /// 获取短时签名 URL 与降级状态（`getSignedMediaUrlState`）。
  ///
  /// [variant] 为 null 表示 original。
  Future<SignedMediaResult> sign(String mediaId, {MediaVariant? variant}) {
    final String cacheKey = variant == null ? mediaId : '$mediaId|thumb';
    final double now = DateTime.now().millisecondsSinceEpoch / 1000;

    final _CacheEntry? cached = _cache[cacheKey];
    if (cached != null && cached.expiresAt - renewAheadSeconds > now) {
      return Future<SignedMediaResult>.value(
        SignedMediaResult(
          url: cached.url,
          originalExpired: cached.originalExpired,
        ),
      );
    }
    // 同一媒体+变体并发请求只签发一次
    if (cached?.inflight != null) return cached!.inflight!;

    final Future<SignedMediaResult> inflight = _sign(mediaId, cacheKey, variant);
    _cache[cacheKey] = _CacheEntry(
      url: '',
      expiresAt: now,
      inflight: inflight,
    );
    return inflight;
  }

  Future<SignedMediaResult> _sign(
    String mediaId,
    String cacheKey,
    MediaVariant? variant,
  ) async {
    final DioClient? client = _client;
    if (client == null) {
      _cache.remove(cacheKey);
      throw StateError('MediaSigner 未注入 DioClient（启动时调 attach）');
    }
    try {
      final Map<String, dynamic> r = await client.post<Map<String, dynamic>>(
        '/media/${Uri.encodeComponent(mediaId)}:sign',
        body: variant == null ? null : <String, dynamic>{'variant': 'thumb'},
      );
      final String url = _toSameOriginMinio(r['url'] as String);
      final double expires = (r['expires_at'] as num).toDouble();
      _cache[cacheKey] = _CacheEntry(url: url, expiresAt: expires);
      return SignedMediaResult(url: url, originalExpired: false);
    } on ApiException catch (e) {
      if (e.status == 410) {
        if (variant != null) {
          // thumb 410 = 完全过期（阶段 2 / 单级媒体）
          _cache.remove(cacheKey);
          throw const MediaExpiredError();
        }
        // original 410 = 原图已删（阶段 1）→ 自动降级 thumb，避免无效签名往返
        try {
          final Map<String, dynamic> thumb = await client
              .post<Map<String, dynamic>>(
            '/media/${Uri.encodeComponent(mediaId)}:sign',
            body: <String, dynamic>{'variant': 'thumb'},
          );
          final String url = _toSameOriginMinio(thumb['url'] as String);
          final double expires = (thumb['expires_at'] as num).toDouble();
          _cache['$mediaId|thumb'] =
              _CacheEntry(url: url, expiresAt: expires);
          _cache[cacheKey] = _CacheEntry(
            url: url,
            expiresAt: expires,
            originalExpired: true,
          );
          return SignedMediaResult(url: url, originalExpired: true);
        } on ApiException catch (thumbErr) {
          // thumb 410 = 完全过期；404 = 无缩略图（文件/语音等）
          _cache.remove(cacheKey);
          if (thumbErr.status == 410 || thumbErr.status == 404) {
            throw const MediaExpiredError();
          }
          rethrow;
        }
      }
      // 失败清缓存允许下次重试
      _cache.remove(cacheKey);
      rethrow;
    } catch (_) {
      _cache.remove(cacheKey);
      rethrow;
    }
  }

  /// 失效缓存（401 / 加载失败时调用，下次重签）。**只清该 mediaId 及其变体**。
  void invalidate(String mediaId) {
    _cache.removeWhere(
      (String k, _) => k == mediaId || k.startsWith('$mediaId|'),
    );
  }

  /// 预签名绝对 URL → 同源代理路径（`toSameOriginMinio`）。
  ///
  /// web 把 `https://<minio-host>/...` 替换为 `/minio/...`，由反代统一转发
  /// （数据面同源，规避浏览器跨源限制）。签名基于 Host 计算，代理保持 Host
  /// 一致故校验不受影响。Flutter 侧同样走同源（桌面直连后端）。
  static String _toSameOriginMinio(String presignedUrl) {
    return presignedUrl.replaceFirst(
      RegExp(r'^https?://[^/]+', caseSensitive: false),
      '/minio',
    );
  }
}
