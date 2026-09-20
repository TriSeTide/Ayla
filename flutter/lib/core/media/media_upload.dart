/// 受控媒体上传（三步）—— 对齐 web `Ayla/web/src/api/media.ts` 的 `uploadMediaFile`（394–456）
/// 与后端 `Ayla/backend/apps/media/views.py`。
///
/// ## 三步（与 web 相同）
/// 1. `POST /media/uploads` `{kind, expected_size, mime_type}`（`media.ts:405–409`）
///    → `{upload_id, kind, max_bytes, expires_at, presigned_url}`；
/// 2. 二进制上传；
/// 3. `POST /media/uploads/{upload_id}:complete`（`media.ts:435–437`）
///    → `{media_id, descriptor}`（web 在此补上 `upload_id` 一并返回）。
///
/// 取消清理：`DELETE /media/uploads/{upload_id}`（后端幂等，`UploadBinaryView.delete`），
/// web 在 abort 时 fire-and-forget 调用（`media.ts:383–387`）。
///
/// ## 与 web 的唯一实质差异：第 2 步的传输路径
/// web 把二进制 PUT 到 `presigned_url`（浏览器直打对象存储，并把绝对 URL 换成
/// `/minio` 走 Vite 反代）。Flutter 侧**没有**这条反代（后端 `apps/media/urls.py`
/// 没有 `/minio` 路由，也没有 Vite dev server），因此走后端**专门提供**的
/// `PUT /api/v1/media/uploads/{upload_id}`：`UploadBinaryView`（views.py:91–133）以
/// `request.stream` 流式分块写临时文件、边写边校验累计大小、超限即 413，最后
/// `put_stream` 到对象存储。该端点**需要 Authorization**（与预签名直传相反），
/// 由 DioClient 的鉴权拦截器自动附带。
///
/// ⚠️ ASGI（daphne）**不解析 chunked 请求体** → 上传必须带确定的 Content-Length。
/// 本实现以 `Uint8List` 作请求体（dio 自动写 Content-Length）；若要改流式上传，
/// 必须显式设置 `content-length` 头，否则后端会读不到 body。
///
/// ## 视频海报（web `captureVideoPoster` / `uploadPoster`，`media.ts:458–518`）
/// web 用浏览器 `<video>` + `<canvas>` 抓 0.1s 帧（宽边压到 640、JPEG q85）后
/// `POST /media/{id}:poster`（`Content-Type: image/jpeg`，失败静默不影响视频本体）。
/// Flutter 没有等价的 DOM 画布：抓帧依赖平台视频解码，**本层不抓帧**，只提供
/// [AylaMediaUploader.uploadPoster] 供调用方注入 JPEG 字节；抓帧归属待定。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/media_kind.dart';
import '../models/post.dart' show AylaMediaDescriptor;
import '../net/dio_client.dart';
import 'media_validation.dart';

/// 上传会话（`POST /media/uploads` 响应；web `UploadSession`）。
class AylaUploadSession {
  const AylaUploadSession({
    required this.uploadId,
    this.kind,
    this.maxBytes,
    this.expiresAt,
    this.presignedUrl,
  });

  /// 从响应 JSON 解析；`upload_id` 缺失即视为无效（抛 [AylaUploadException]）。
  factory AylaUploadSession.fromJson(Map<String, dynamic> json) {
    final Object? id = json['upload_id'];
    if (id is! String || id.isEmpty) {
      throw const AylaUploadException('后端未返回 upload_id');
    }
    return AylaUploadSession(
      uploadId: id,
      kind: AylaMediaKind.parse(json['kind'] as String?),
      maxBytes: (json['max_bytes'] as num?)?.toInt(),
      expiresAt: json['expires_at'] as String?,
      presignedUrl: json['presigned_url'] as String?,
    );
  }

  /// 上传会话 id（清理临时对象时要它）。
  final String uploadId;

  /// 会话的媒体种类（未知 = null）。
  final AylaMediaKind? kind;

  /// 该 kind 的大小上限（字节）；null = 该类别不设上限（图片/语音默认放开）。
  final int? maxBytes;

  /// 会话过期时间（ISO 字符串，原样保留，不猜格式）。
  final String? expiresAt;

  /// 预签名直传地址。Flutter 走后端中转，**不使用**该地址；保留字段仅作审计与对照。
  final String? presignedUrl;
}

/// 上传完成结果（web `UploadCompleteResult`）。
class AylaUploadResult {
  const AylaUploadResult({
    required this.mediaId,
    required this.uploadId,
    this.descriptor,
  });

  /// 媒体 id。
  final String mediaId;

  /// 上传会话 id（移除媒体时可调 `DELETE /media/uploads/{id}` 清理对象存储）。
  final String uploadId;

  /// 媒体描述符（解析失败 = null，**不伪造**）。
  final AylaMediaDescriptor? descriptor;
}

/// 上传进度（web `UploadProgress`；total 可能为 0 或不精确）。
class AylaUploadProgress {
  const AylaUploadProgress({required this.loaded, required this.total});

  /// 已发送字节。
  final int loaded;

  /// 总字节（0 = 未知）。
  final int total;

  /// 0..1 进度；total ≤ 0 时返回 null（**不伪造** 0 或 1）。
  double? get fraction {
    if (total <= 0) return null;
    final double value = loaded / total;
    if (value < 0) return 0;
    if (value > 1) return 1;
    return value;
  }
}

/// 上传失败（可直接展示的文案；web 用 `Error` / `ApiError`）。
class AylaUploadException implements Exception {
  const AylaUploadException(this.message, {this.cause});

  /// 展示文案。
  final String message;

  /// 原始异常（诊断用）。
  final Object? cause;

  @override
  String toString() => message;
}

/// 三步受控上传客户端（对齐 web `uploadMediaFile`；失败抛异常由调用方保留原输入，
/// **不伪造消息发送成功**）。
class AylaMediaUploader {
  AylaMediaUploader._();

  /// 单例（与 [MediaSigner] 同模式：进程内唯一 + 显式 attach/detach）。
  static final AylaMediaUploader instance = AylaMediaUploader._();

  /// 建会话返回 413 时的文案（web `media.ts:411–413`）。
  static const String tooLargeMessage = '文件超过允许的大小上限';

  DioClient? _client;

  /// 注入 API 客户端（app 启动或测试时设置）。
  void attach(DioClient client) => _client = client;

  /// 解除注入（登出、测试隔离）。
  void detach() => _client = null;

  DioClient _requireClient() {
    final DioClient? client = _client;
    if (client == null) {
      throw StateError('AylaMediaUploader 未注入 DioClient（attach 未调用）');
    }
    return client;
  }

  /// 三步上传：建会话 → 上传二进制 → complete。
  ///
  /// [mimeType] 会按 `;` 取主类型（`media.ts:402`）。
  /// [cancelToken] 取消时抛 [DioExceptionType.cancel]，并 fire-and-forget 清理会话。
  Future<AylaUploadResult> uploadBytes({
    required Uint8List bytes,
    required AylaMediaKind kind,
    required String mimeType,
    void Function(AylaUploadProgress progress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final DioClient client = _requireClient();
    final String rawMime = mimeType.trim();
    final String mime = (rawMime.isEmpty ? 'application/octet-stream' : rawMime)
        .split(';')
        .first
        .trim();

    final AylaUploadSession session;
    try {
      final Map<String, dynamic> created = await client.post<Map<String, dynamic>>(
        '/media/uploads',
        body: <String, Object?>{
          'kind': kind.wire,
          'expected_size': bytes.length,
          'mime_type': mime,
        },
      );
      session = AylaUploadSession.fromJson(created);
    } on ApiException catch (error) {
      if (error.status == 413) {
        throw AylaUploadException(tooLargeMessage, cause: error);
      }
      rethrow;
    }

    // max_bytes != null 时提前拦截并展示具体数值（`media.ts:424–427`）
    final int? maxBytes = session.maxBytes;
    if (maxBytes != null && bytes.length > maxBytes) {
      throw AylaUploadException('文件超过大小上限（${aylaFormatBytes(maxBytes)}）');
    }

    try {
      await client.dio.put<void>(
        '/media/uploads/${session.uploadId}',
        data: bytes,
        options: Options(
          contentType: mime,
          headers: <String, Object?>{'Content-Type': mime},
        ),
        onSendProgress: (int sent, int total) {
          onProgress?.call(AylaUploadProgress(loaded: sent, total: total));
        },
        cancelToken: cancelToken,
      );
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) {
        // 取消 → 清理服务端临时对象与会话（幂等，不阻塞异常抛出；`media.ts:380–387`）
        unawaited(deleteUpload(session.uploadId));
      }
      rethrow;
    }

    final Map<String, dynamic> completed = await client.post<Map<String, dynamic>>(
      '/media/uploads/${session.uploadId}:complete',
    );
    final Object? mediaId = completed['media_id'];
    if (mediaId is! String || mediaId.isEmpty) {
      throw const AylaUploadException('后端未返回 media_id');
    }
    return AylaUploadResult(
      mediaId: mediaId,
      uploadId: session.uploadId,
      descriptor: AylaMediaDescriptor.fromJson(completed['descriptor']),
    );
  }

  /// 删除自己上传的媒体（`DELETE /media/{id}`：对象存储 original/thumbnail + 记录；
  /// web `deleteMedia`，`media.ts:188–190`）。异常透传给调用方（移除失败要报错，
  /// 不能静默把「还在服务端」当成删掉了）。
  Future<void> deleteMedia(String mediaId) async {
    final DioClient client = _requireClient();
    await client.delete<void>('/media/$mediaId');
  }

  /// 取消上传后清理临时对象与会话（幂等；失败静默 —— 与 web `catch(() => {})` 同义）。
  ///
  /// 这是**资源清理路径**：拿不到会话/已删除/非本人，后端都安全返回 204，
  /// 调用方不该因为清理失败而阻断用户操作，故此处吞掉异常。
  Future<void> deleteUpload(String uploadId) async {
    final DioClient? client = _client;
    if (client == null) return;
    try {
      await client.delete<void>('/media/uploads/$uploadId');
    } catch (_) {
      // 清理失败不抛：会话到期后由后端回收（Web 侧同样 fire-and-forget）
    }
  }

  /// 上传视频海报帧（`POST /media/{id}:poster`，JPEG ≤2MB，仅上传者本人）。
  ///
  /// 抓帧不由本层负责（见文件头「视频海报」段）；调用方传入 JPEG 字节。
  /// web 侧海报失败**静默**（不影响视频本体）——保持同一语义，异常交调用方决定。
  Future<void> uploadPoster(
    String mediaId,
    Uint8List jpeg, {
    CancelToken? cancelToken,
  }) async {
    final DioClient client = _requireClient();
    try {
      await client.dio.post<void>(
        '/media/$mediaId:poster',
        data: jpeg,
        options: Options(contentType: 'image/jpeg'),
        cancelToken: cancelToken,
      );
    } on DioException catch (error) {
      throw AylaUploadException(
        '海报上传失败（${error.response?.statusCode ?? '网络错误'}）',
        cause: error,
      );
    }
  }
}
