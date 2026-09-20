/// 「选文件 → 上传 → 抓帧海报」组合动作的定向测试（后端/上传/抓帧全部注入替身）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ValueChanged;
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/media/media_actions.dart';
import '../lib/core/media/media_picker.dart';
import '../lib/core/media/media_upload.dart';
import '../lib/core/media/video_poster.dart';
import '../lib/core/models/post.dart';
import '../lib/core/net/dio_client.dart';

/// 立即成功的传输层（记录请求）。
class _OkAdapter implements HttpClientAdapter {
  final List<String> requests = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add('${options.method} ${options.path}');
    if (requestStream != null) await requestStream.drain<void>();
    return ResponseBody.fromString(
      '{"detail":"ok"}',
      200,
      headers: const <String, List<String>>{
        'content-type': <String>['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FakeClient implements DioClient {
  _FakeClient(this.adapter);

  final _OkAdapter adapter;
  final List<String> posts = <String>[];
  final Set<String> failPosts = <String>{};
  /// 为 true 时第二次建会话失败（测「多张里失败一张」）。
  bool failSecondSession = false;
  int _sessions = 0;
  int _seq = 0;

  @override
  late final Dio dio = Dio(BaseOptions(baseUrl: 'http://test.local/api/v1'))
    ..httpClientAdapter = adapter;

  @override
  Future<T> post<T>(String path, {Object? body, Map<String, dynamic>? query}) async {
    posts.add(path);
    if (failPosts.contains(path)) throw const ApiException(500, 'boom');
    if (path == '/media/uploads') {
      _sessions++;
      if (failSecondSession && _sessions == 2) {
        throw const ApiException(500, 'boom');
      }
      return <String, dynamic>{
        'upload_id': 'u${++_seq}',
        'kind': 'image',
        'max_bytes': null,
        'expires_at': '2026-09-20T23:59:00Z',
        'presigned_url': 'http://minio/x',
      } as T;
    }
    if (path.endsWith(':complete')) {
      return <String, dynamic>{
        'media_id': 'm${_seq}',
        'descriptor': <String, dynamic>{'media_id': 'm${_seq}', 'kind': 'image'},
      } as T;
    }
    return <String, dynamic>{} as T;
  }

  @override
  Future<T> delete<T>(String path) async {
    adapter.requests.add('DELETE $path'); // 与 PUT 记录同一处，便于统一断言
    if (failPosts.contains(path)) throw const ApiException(500, 'boom');
    return null as T;
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakePicker implements AylaPickerBackend {
  _FakePicker(this.files, {this.error});
  List<AylaPickedFile> files;
  String? error;
  @override
  Future<List<AylaPickedFile>> pick({
    required AylaPickKind kind,
    bool multiple = false,
  }) async {
    // 校验由 AylaMediaPicker 负责：这里用真实 picker 的组合逻辑不便注入错误，
    // 故把「校验失败」建模成后端返回空 + 由测试直接构造 error 场景。
    return files;
  }
}

class _FakePoster implements AylaPosterCaptureBackend {
  final List<String> paths = <String>[];
  @override
  Future<Uint8List?> captureFrame(String path, Duration at, Duration timeout) async {
    paths.add(path);
    return Uint8List.fromList(<int>[7, 7]);
  }
}

AylaPickedFile file(String name, {int size = 1024, String? path}) => AylaPickedFile(
      name: name,
      size: size,
      mimeType: aylaMimeFromName(name),
      path: path,
      readBytes: () async => Uint8List(size),
    );

void main() {
  late _OkAdapter adapter;
  late _FakeClient client;

  setUp(() {
    adapter = _OkAdapter();
    client = _FakeClient(adapter);
    AylaMediaUploader.instance
      ..detach()
      ..attach(client);
  });

  tearDown(() {
    AylaMediaUploader.instance.detach();
    AylaMediaPicker.backend = const AylaFilePickerBackend();
    AylaVideoPoster.backend = const AylaMediaKitPosterCapture();
  });

  test('选图片并上传：产出草稿（mediaId/descriptor/localPath/uploadId）+ 进度以 null 结束', () async {
    AylaMediaPicker.backend = _FakePicker(<AylaPickedFile>[
      file('a.png', path: '/tmp/a.png'),
    ]);
    final List<double?> progress = <double?>[];
    final AylaMediaPickResult result = await AylaMediaActions.pickImages(
      remaining: 4,
      onProgress: (double? p) => progress.add(p),
    );
    expect(result.failed, 0);
    expect(result.overLimit, 0);
    expect(result.drafts.length, 1);
    expect(result.drafts.single.mediaId, 'm1');
    expect(result.drafts.single.localPath, '/tmp/a.png');
    expect(result.drafts.single.uploadId, 'u1');
    expect(progress.isNotEmpty, isTrue);
    expect(progress.last, isNull, reason: '结束后收起进度');
    expect(
      adapter.requests.map((String r) => r).toList(),
      contains('PUT /media/uploads/u1'),
    );
  });

  test('用户取消（未选文件）→ 空结果且不抛', () async {
    AylaMediaPicker.backend = _FakePicker(<AylaPickedFile>[]);
    final AylaMediaPickResult result = await AylaMediaActions.pickImages(
      remaining: 4,
    );
    expect(result.drafts, isEmpty);
    expect(result.failed, 0);
    expect(result.overLimit, 0);
  });

  test('单张上传失败 → 计入 failed，其余继续', () async {
    AylaMediaPicker.backend = _FakePicker(<AylaPickedFile>[
      file('a.png'),
      file('b.png'),
    ]);
    client.failSecondSession = true; // 第二张在建会话阶段失败
    final AylaMediaPickResult result = await AylaMediaActions.pickImages(
      remaining: 4,
    );
    expect(result.drafts.length, 1, reason: '第一张成功');
    expect(result.failed, 1, reason: '第二张失败计数交回组件');
  });

  test('超出 remaining → overLimit；remaining<=0 → 直接 overLimit=1', () async {
    AylaMediaPicker.backend = _FakePicker(<AylaPickedFile>[
      file('a.png'),
      file('b.png'),
      file('c.png'),
    ]);
    final AylaMediaPickResult result = await AylaMediaActions.pickImages(
      remaining: 2,
    );
    expect(result.drafts.length, 2);
    expect(result.overLimit, 1);

    final AylaMediaPickResult none = await AylaMediaActions.pickImages(
      remaining: 0,
    );
    expect(none.overLimit, 1);
  });

  test('视频：上传后自动抓帧上传海报（本地路径存在时）', () async {
    final _FakePoster poster = _FakePoster();
    AylaVideoPoster.backend = poster;
    AylaMediaPicker.backend = _FakePicker(<AylaPickedFile>[
      file('clip.mp4', path: '/tmp/clip.mp4'),
    ]);
    final AylaMediaPickResult result = await AylaMediaActions.pickVideo(
      remaining: 9,
    );
    expect(result.drafts.length, 1);
    expect(poster.paths, <String>['/tmp/clip.mp4']);
  });

  test('removeDraft：DELETE /media/{id}', () async {
    const AylaPostMediaDraft draft = AylaPostMediaDraft(
      mediaId: 'm9',
      descriptor: AylaMediaDescriptor(mediaId: 'm9'),
    );
    await AylaMediaActions.removeDraft(draft);
    expect(
      adapter.requests.map((String r) => r).toList(),
      contains('DELETE /media/m9'),
    );
  });
}
