/// dio 客户端（对齐 `Ayla/web/src/api/client.ts` 语义）。
///
/// 职责（逐条对应 web 端）：
/// - baseUrl：Android 模拟器 10.0.2.2:8100 / 桌面 127.0.0.1:8100（同 PoC 平台区分；
///   真机需可配置局域网地址，M1 会话恢复再做配置化）
/// - 自动携带 `Authorization: Bearer <access>`
/// - 401（非 refresh / 非认证端点）静默刷新并重放一次原请求；并发 401 只刷新一次（互斥锁）
/// - 刷新失败 → 清空认证 + 通知登出（跳 /login?next=）
/// - 错误归一：`{detail}` / `{field: [msg]}` → 可读文案（normalizeErrorBody 照 web 翻译）
/// - 登出清态：token 存取走注入的 AuthStore 回调，单一真源
///
/// 防 chunked（POC 坑 1）：daphne 不解析 chunked 请求体（裸 dart:io HttpClient 才会
/// 发送 chunked）。dio 5 的 IO adapter 对普通 body 显式设置 contentLength——
/// 2026-09-17 实测：POST /auth/login/（JSON body）status=200 access 到手，
/// 无 chunked 问题。若未来 dio 大版本回归，症状是登录 400「字段必填」，届时
/// 换自定义 HttpClientAdapter 显式 `request.contentLength = bytes.length`。
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// 统一 API 根路径（后端挂载在 /api/v1/，同 web API_PREFIX）。
const String kApiPrefix = '/api/v1';

/// API 错误（web ApiError 等价物：status + 归一化后的可读消息 + 原始 body）。
class ApiException implements Exception {
  final int status;
  final String message;
  final Map<String, dynamic>? body;

  const ApiException(this.status, this.message, [this.body]);

  @override
  String toString() => 'ApiException($status): $message';
}

/// 归一化后端错误：`{detail}` / `{field: [msg]}` / `{field: msg}` → 可读文案。
/// 照 `web/src/api/client.ts` normalizeErrorBody 翻译。
String normalizeErrorBody(Map<String, dynamic>? body, String fallback) {
  if (body == null) return fallback;
  final Object? detail = body['detail'];
  if (detail is String && detail.isNotEmpty) return detail;
  if (detail != null) return detail.toString();
  for (final MapEntry<String, dynamic> entry in body.entries) {
    final Object? v = entry.value;
    if (v != null) {
      if (v is List && v.isNotEmpty) return v.first.toString();
      return v.toString();
    }
  }
  return fallback;
}

/// 令牌存取契约（由 AuthStore 注入，DioClient 不持有认证状态）。
abstract interface class AuthTokenStore {
  String? get accessToken;
  String? get refreshToken;
  void setTokens(String access, String? refresh);
  void clear();
}

/// dio 客户端单例。
///
/// 初始化：`DioClient.instance.init(tokenStore: ..., onSessionExpired: ...)`，
/// 在 app 启动（main）时 wiring 一次。
class DioClient {
  DioClient._();

  static final DioClient instance = DioClient._();

  late final Dio dio;

  AuthTokenStore? _tokens;
  VoidCallback? _onSessionExpired;

  /// 刷新互斥锁（web refreshPromise 等价物）：并发 401 只触发一次刷新
  Future<bool>? _refreshPromise;

  /// 是否已 init（幂等保护）
  bool _inited = false;

  /// 初始化并 wiring token 存取与登出回调（main 中调用一次）。
  void init({
    required AuthTokenStore tokenStore,
    required VoidCallback onSessionExpired,
  }) {
    _tokens = tokenStore;
    _onSessionExpired = onSessionExpired;
    if (_inited) return;
    _inited = true;
    dio = Dio(
      BaseOptions(
        baseUrl: '$_baseUrl$kApiPrefix',
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 20),
        // M0 冒烟：后端为明文 HTTP（Android cleartext 已在 Manifest 放行）
        contentType: Headers.jsonContentType,
      ),
    );
    dio.interceptors.add(_authInterceptor);
  }

  /// 测试注入点：覆盖平台默认 baseUrl（widget test 的本地 mock server 用）。
  /// 生产路径不设置——仅测试设置；@visibleForTesting 约束。
  @visibleForTesting
  String debugBaseUrlOverride = '';

  String get _baseUrl {
    if (debugBaseUrlOverride.isNotEmpty) return debugBaseUrlOverride;
    if (kIsWeb) return 'http://127.0.0.1:8100';
    if (Platform.isAndroid) return 'http://10.0.2.2:8100';
    return 'http://127.0.0.1:8100';
  }

  /// 401 静默刷新 + 重放一次拦截器（web api/client.ts 语义）。
  late final Interceptor _authInterceptor = InterceptorsWrapper(
    onRequest: (options, handler) {
      final String? access = _tokens?.accessToken;
      if (access != null && access.isNotEmpty && options.extra['skipAuth'] != true) {
        options.headers['Authorization'] = 'Bearer $access';
      }
      handler.next(options);
    },
    onError: (DioException err, handler) async {
      final bool is401 = err.response?.statusCode == 401;
      final bool isRefresh = err.requestOptions.extra['isRefresh'] == true;
      final bool noRetry = err.requestOptions.extra['noRetry401'] == true;
      final bool retried = err.requestOptions.extra['retried'] == true;
      if (is401 && !isRefresh && !noRetry && !retried) {
        final bool ok = await refreshAccessToken();
        if (ok) {
          // 重放一次：标记 retried，重放再 401 时不再刷新（直接失败）
          err.requestOptions.extra['retried'] = true;
          try {
            final Response<dynamic> resp = await dio.fetch<dynamic>(err.requestOptions);
            handler.resolve(resp);
            return;
          } on DioException catch (replayErr) {
            handler.next(replayErr);
            return;
          }
        }
        // 刷新失败：清 token + 登出（web handleSessionExpired）
        _tokens?.clear();
        _onSessionExpired?.call();
        handler.reject(
          DioException(
            requestOptions: err.requestOptions,
            error: const ApiException(401, '登录已过期，请重新登录'),
          ),
        );
        return;
      }
      handler.next(err);
    },
  );

  /// 当前 access token（只读）。
  ///
  /// 用途：**不经 dio 拦截器**的媒体读取（`media_kit` / `video_player` 直接拉
  /// `/api/v1/media/{id}/content` 时不会自带 `Authorization`，web 侧靠
  /// `apiRequestBlob` 走拦截器解决，Flutter 侧由播放内核带 header ⇒ 需要在此读同一个
  /// token）。null/空 = 未登录。
  String? get accessToken => _tokens?.accessToken;

  /// 静默续期 access token（互斥锁 + 轮换）。
  ///
  /// 供 401 拦截器与 WS 重连前共用（web refreshAccessToken 语义：
  /// WS 重连前令牌临期先 refresh 再连，防 WSREJECT 循环）。
  Future<bool> refreshAccessToken() {
    final Future<bool>? current = _refreshPromise;
    if (current != null) return current;
    final Future<bool> p = _doRefresh();
    _refreshPromise = p;
    return p.whenComplete(() {
      if (identical(_refreshPromise, p)) _refreshPromise = null;
    });
  }

  Future<bool> _doRefresh() async {
    final String? refresh = _tokens?.refreshToken;
    if (refresh == null || refresh.isEmpty) return false;
    try {
      final Response<dynamic> res = await dio.post<dynamic>(
        '/auth/refresh/',
        data: <String, String>{'refresh': refresh},
        options: Options(extra: <String, dynamic>{'isRefresh': true, 'skipAuth': true}),
      );
      final Map<String, dynamic> data = (res.data as Map<dynamic, dynamic>).cast<String, dynamic>();
      final String? newAccess = data['access'] as String?;
      if (newAccess == null || newAccess.isEmpty) return false;
      // ROTATE_REFRESH_TOKENS=True：refresh 也轮换，缺省沿用旧 refresh
      final String? newRefresh = data['refresh'] as String?;
      _tokens?.setTokens(newAccess, newRefresh ?? refresh);
      return true;
    } on DioException catch (e) {
      // 失败必须可观测（工程纪律：不留静默失败路径）
      debugPrint('DioClient.refresh 失败: status=${e.response?.statusCode} '
          'body=${e.response?.data} type=${e.type}');
      return false;
    } catch (e) {
      debugPrint('DioClient.refresh 异常: $e');
      return false;
    }
  }

  // ---- 通用请求封装（body 自动 JSON 序列化，错误归一为 ApiException）----

  Future<T> get<T>(String path, {Map<String, dynamic>? query}) =>
      _request<T>('GET', path, query: query);

  Future<T> post<T>(String path, {Object? body, Map<String, dynamic>? query}) =>
      _request<T>('POST', path, body: body, query: query);

  Future<T> put<T>(String path, {Object? body, Map<String, dynamic>? query}) =>
      _request<T>('PUT', path, body: body, query: query);

  Future<T> patch<T>(String path, {Object? body, Map<String, dynamic>? query}) =>
      _request<T>('PATCH', path, body: body, query: query);

  Future<T> delete<T>(String path) => _request<T>('DELETE', path);

  Future<T> _request<T>(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    try {
      final Response<dynamic> resp = await dio.request<dynamic>(
        path,
        data: body,
        queryParameters: query,
        options: Options(method: method),
      );
      return resp.data as T;
    } on DioException catch (e) {
      throw _toApiException(e);
    }
  }

  /// 把 DioException 归一处理由 ApiException（非 401 分支的响应错误）。
  ApiException _toApiException(DioException e) {
    // 拦截器 reject 时已构造 ApiException（如刷新失败「登录已过期」），优先透传
    final Object? carried = e.error;
    if (carried is ApiException) return carried;
    final Response<dynamic>? resp = e.response;
    if (resp == null) {
      return ApiException(
        e.response?.statusCode ?? 0,
        '网络请求失败（${e.type.name}）',
      );
    }
    Map<String, dynamic>? body;
    if (resp.data is Map) {
      body = (resp.data as Map).cast<String, dynamic>();
    }
    final String message =
        normalizeErrorBody(body, '请求失败（${resp.statusCode}）');
    return ApiException(resp.statusCode ?? 0, message, body);
  }
}

/// 便捷：抛出 DioException 时统一转 ApiException（供 API 层使用）。
ApiException apiErrorOf(DioException e) => DioClient.instance._toApiException(e);
