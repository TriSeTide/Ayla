/// B5 媒体上传与本地校验定向测试（对齐 web `api/media.ts` + 后端 views.py 契约）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/media/media_upload.dart';
import '../lib/core/media/media_validation.dart';
import '../lib/core/models/media_kind.dart';
import '../lib/core/net/dio_client.dart';

/// 录制型传输层：记录每个请求的方法/路径/头/体，并按路径返回预设响应。
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter({this.createStatus = 201});

  /// 建会话的返回状态（413 用于测超限文案）。
  final int createStatus;

  final List<RequestOptions> requests = <RequestOptions>[];
  final List<List<int>?> bodies = <List<int>?>[];

  /// 对 PUT 抛取消（模拟调用方中断）。
  bool cancelOnPut = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    List<int>? body;
    if (requestStream != null) {
      body = <int>[];
      await for (final Uint8List chunk in requestStream) {
        body.addAll(chunk);
      }
    }
    bodies.add(body);

    final String path = options.path;
    if (options.method == 'PUT') {
      if (cancelOnPut) {
        throw DioException(requestOptions: options, type: DioExceptionType.cancel);
      }
      return ResponseBody.fromString('{"detail":"ok"}', 200, headers: _jsonHeaders);
    }
    if (options.method == 'DELETE') {
      return ResponseBody.fromString('', 204);
    }
    if (path.endsWith(':complete')) {
      return ResponseBody.fromString(
        jsonEncode(<String, Object?>{
          'media_id': 'm1',
          'descriptor': <String, Object?>{
            'media_id': 'm1',
            'kind': 'image',
            'mime_type': 'image/png',
            'size': 3,
          },
        }),
        201,
        headers: _jsonHeaders,
      );
    }
    if (path.endsWith(':poster')) {
      return ResponseBody.fromString('{"detail":"ok"}', 200, headers: _jsonHeaders);
    }
    // POST /media/uploads（建会话）
    if (createStatus != 201) {
      return ResponseBody.fromString(
        '{"detail":"payload_too_large"}',
        createStatus,
        headers: _jsonHeaders,
      );
    }
    return ResponseBody.fromString(
      jsonEncode(<String, Object?>{
        'upload_id': 'u1',
        'kind': 'image',
        'max_bytes': null,
        'expires_at': '2026-09-20T22:00:00Z',
        'presigned_url': 'http://minio.local/bucket/tmp/u1?signature=x',
      }),
      201,
      headers: _jsonHeaders,
    );
  }

  @override
  void close({bool force = false}) {}

  static const Map<String, List<String>> _jsonHeaders = <String, List<String>>{
    'content-type': <String>['application/json'],
  };
}

/// 假客户端：真 Dio + 录制 adapter + 鉴权拦截器（等价 DioClient 的注入效果）。
class _FakeDio implements DioClient {
  _FakeDio(this.dio);

  @override
  final Dio dio;

  // ⚠️ 与 `DioClient._request` 的转换保持一致：DioException → ApiException
  // （否则 413 这类状态码在测试里表现为 DioException，与真实客户端行为不符）。
  @override
  Future<T> post<T>(String path, {Object? body, Map<String, dynamic>? query}) async {
    try {
      final Response<dynamic> response = await dio.post<dynamic>(path, data: body);
      return response.data as T;
    } on DioException catch (error) {
      throw ApiException(
        error.response?.statusCode ?? 0,
        '${error.response?.statusCode ?? error.type.name}',
      );
    }
  }

  @override
  Future<T> delete<T>(String path) async {
    try {
      final Response<dynamic> response = await dio.delete<dynamic>(path);
      return response.data as T;
    } on DioException catch (error) {
      throw ApiException(
        error.response?.statusCode ?? 0,
        '${error.response?.statusCode ?? error.type.name}',
      );
    }
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

const List<int> _pngBytes = <int>[1, 2, 3];

void main() {
  late _RecordingAdapter adapter;
  late Dio dio;
  late _FakeDio client;

  setUp(() {
    adapter = _RecordingAdapter();
    dio = Dio(BaseOptions(baseUrl: 'http://test.local/api/v1'))
      ..httpClientAdapter = adapter;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (RequestOptions options, RequestInterceptorHandler handler) {
          options.headers['Authorization'] = 'Bearer test-token';
          handler.next(options);
        },
      ),
    );
    client = _FakeDio(dio);
    AylaMediaUploader.instance
      ..detach()
      ..attach(client);
  });

  tearDown(() => AylaMediaUploader.instance.detach());

  group('本地校验与格式化（media.ts 202–330 对照）', () {
    test('formatBytes：B / KB / MB 三档，负数空串', () {
      expect(aylaFormatBytes(0), '0 B');
      expect(aylaFormatBytes(512), '512 B');
      expect(aylaFormatBytes(2048), '2.0 KB');
      expect(aylaFormatBytes(5 * 1024 * 1024), '5.0 MB');
      expect(aylaFormatBytes(-1), '');
      expect(aylaFormatBytes(aylaFileMaxBytes), '50.0 MB');
    });

    test('formatDuration：m:ss，null/负值/非有限值', () {
      expect(aylaFormatDuration(0), '0:00');
      expect(aylaFormatDuration(65.4), '1:05');
      expect(aylaFormatDuration(59.6), '1:00');
      expect(aylaFormatDuration(null), '');
      expect(aylaFormatDuration(double.nan), '');
      expect(aylaFormatDuration(-3), '0:00');
    });

    test('validateMediaFile：图片/视频/文件三分类 + 空文件 + 超限 + 禁执行文档', () {
      final AylaMediaValidation img =
          aylaValidateMediaFile(mime: 'image/png', size: 10);
      expect(img.ok, isTrue);
      expect(img.kind, AylaMediaKind.image);

      // 带 codec 参数 → 取主类型（media.ts:302）
      expect(
        aylaValidateMediaFile(mime: 'image/png;codecs=x', size: 10).kind,
        AylaMediaKind.image,
      );
      expect(
        aylaValidateMediaFile(mime: 'video/mp4', size: 10).kind,
        AylaMediaKind.video,
      );
      expect(
        aylaValidateMediaFile(mime: 'application/pdf', size: 10).kind,
        AylaMediaKind.file,
      );

      expect(
        aylaValidateMediaFile(mime: 'image/png', size: 0).error,
        '文件内容为空',
      );
      expect(
        aylaValidateMediaFile(mime: 'application/pdf', size: 0).error,
        '文件内容为空',
      );
      expect(
        aylaValidateMediaFile(mime: 'application/pdf', size: aylaFileMaxBytes + 1)
            .error,
        aylaFileTooLargeMessage,
      );
      expect(
        aylaValidateMediaFile(mime: 'text/html', size: 10).error,
        aylaFileUnsafeMessage,
      );
      // 未知 mime（空串）→ 归为 file，不伪造 image
      final AylaMediaValidation unknown =
          aylaValidateMediaFile(mime: '', size: 10);
      expect(unknown.ok, isTrue);
      expect(unknown.kind, AylaMediaKind.file);
    });

    test('validateImageFile：不剥离 codec 参数（web 原文如此）', () {
      expect(aylaValidateImageFile(mime: 'image/png', size: 10), isNull);
      expect(
        aylaValidateImageFile(mime: 'image/png;codecs=x', size: 10),
        aylaImageUnsupportedMessage,
      );
      expect(aylaValidateImageFile(mime: 'image/png', size: 0), '图片内容为空');
      expect(
        aylaValidateImageFile(mime: 'application/pdf', size: 10),
        aylaImageUnsupportedMessage,
      );
    });
  });

  group('AylaMediaUploader 三步上传契约', () {
    test('三步顺序 + PUT 头/体 + 结果解析', () async {
      final List<AylaUploadProgress> progress = <AylaUploadProgress>[];
      final AylaUploadResult result = await AylaMediaUploader.instance.uploadBytes(
        bytes: Uint8List.fromList(_pngBytes),
        kind: AylaMediaKind.image,
        mimeType: 'image/png',
        onProgress: progress.add,
      );

      expect(
        adapter.requests.map((RequestOptions r) => '${r.method} ${r.path}').toList(),
        <String>[
          'POST /media/uploads',
          'PUT /media/uploads/u1',
          'POST /media/uploads/u1:complete',
        ],
      );

      final RequestOptions create = adapter.requests[0];
      expect(
        adapter.bodies[0] == null ? null : jsonDecode(utf8.decode(adapter.bodies[0]!)),
        <String, Object?>{
          'kind': 'image',
          'expected_size': 3,
          'mime_type': 'image/png',
        },
      );
      expect(create.headers['Authorization'], 'Bearer test-token');

      final RequestOptions put = adapter.requests[1];
      expect(adapter.bodies[1], _pngBytes);
      expect(put.headers['Content-Type'], 'image/png');
      expect(put.headers['Authorization'], 'Bearer test-token');
      // daphne 不解析 chunked：必须有确定的 Content-Length
      expect(put.headers['content-length'], isNotNull);

      expect(adapter.requests[2].headers['Authorization'], 'Bearer test-token');

      expect(result.mediaId, 'm1');
      expect(result.uploadId, 'u1');
      expect(result.descriptor?.kind, AylaMediaKind.image);
      expect(result.descriptor?.mimeType, 'image/png');
      expect(progress.isNotEmpty, isTrue, reason: 'onSendProgress 应至少回调一次');
      expect(progress.last.loaded, 3);
    });

    test('建会话 413 → 超限文案（不进入上传）', () async {
      adapter = _RecordingAdapter(createStatus: 413);
      dio.httpClientAdapter = adapter;
      await expectLater(
        AylaMediaUploader.instance.uploadBytes(
          bytes: Uint8List.fromList(_pngBytes),
          kind: AylaMediaKind.image,
          mimeType: 'image/png',
        ),
        throwsA(
          isA<AylaUploadException>().having(
            (AylaUploadException e) => e.message,
            'message',
            AylaMediaUploader.tooLargeMessage,
          ),
        ),
      );
      expect(adapter.requests.length, 1, reason: '超限后不应继续 PUT/complete');
    });

    test('PUT 取消 → 抛 cancel 并清理会话（DELETE 幂等）', () async {
      adapter.cancelOnPut = true;
      await expectLater(
        AylaMediaUploader.instance.uploadBytes(
          bytes: Uint8List.fromList(_pngBytes),
          kind: AylaMediaKind.image,
          mimeType: 'image/png',
        ),
        throwsA(isA<DioException>()),
      );
      // 取消清理是 fire-and-forget：把事件队列跑空再断言
      await pumpEventQueue();
      expect(
        adapter.requests.map((RequestOptions r) => '${r.method} ${r.path}').toList(),
        contains('DELETE /media/uploads/u1'),
      );
    });

    test('uploadPoster：JPEG 直传 :poster（带鉴权）', () async {
      await AylaMediaUploader.instance.uploadPoster(
        'm1',
        Uint8List.fromList(<int>[9, 9, 9, 9]),
      );
      expect(adapter.requests.length, 1);
      final RequestOptions poster = adapter.requests.single;
      expect(poster.method, 'POST');
      expect(poster.path, '/media/m1:poster');
      expect(poster.headers['Content-Type'], 'image/jpeg');
      expect(poster.headers['Authorization'], 'Bearer test-token');
      expect(adapter.bodies.single, <int>[9, 9, 9, 9]);
    });

    test('mime 规范化：带 codec 参数取主类型', () async {
      await AylaMediaUploader.instance.uploadBytes(
        bytes: Uint8List.fromList(_pngBytes),
        kind: AylaMediaKind.video,
        mimeType: 'video/mp4;codecs=avc1',
      );
      final Object? body = adapter.bodies[0] == null
          ? null
          : jsonDecode(utf8.decode(adapter.bodies[0]!));
      expect((body as Map<String, Object?>)['mime_type'], 'video/mp4');
      expect(adapter.requests[1].headers['Content-Type'], 'video/mp4');
    });
  });
}
