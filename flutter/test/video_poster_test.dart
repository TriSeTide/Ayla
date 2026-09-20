/// 视频海报抓帧的定向测试（后端与上传均注入替身，不依赖真实视频/平台解码）。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/media/video_poster.dart';

class _FakeCapture implements AylaPosterCaptureBackend {
  _FakeCapture({this.bytes, this.fail = false});

  final Uint8List? bytes;
  final bool fail;
  String? lastPath;
  Duration? lastAt;
  Duration? lastTimeout;

  @override
  Future<Uint8List?> captureFrame(
    String path,
    Duration at,
    Duration timeout,
  ) async {
    lastPath = path;
    lastAt = at;
    lastTimeout = timeout;
    if (fail) throw TimeoutException('capture timeout');
    return bytes;
  }
}

void main() {
  tearDown(() => AylaVideoPoster.backend = const AylaMediaKitPosterCapture());

  test('抓帧参数：0.1s 处、15s 超时（对齐 media.ts:479/487）', () async {
    final _FakeCapture capture = _FakeCapture(bytes: Uint8List.fromList(<int>[1]));
    AylaVideoPoster.backend = capture;
    await AylaVideoPoster.capture('/tmp/v.mp4');
    expect(capture.lastPath, '/tmp/v.mp4');
    expect(capture.lastAt, const Duration(milliseconds: 100));
    expect(capture.lastTimeout, const Duration(seconds: 15));
  });

  test('抓帧 + 上传成功 → true，且字节原样交给上传', () async {
    final Uint8List jpeg = Uint8List.fromList(<int>[9, 8, 7]);
    AylaVideoPoster.backend = _FakeCapture(bytes: jpeg);
    String? uploadedId;
    Uint8List? uploadedBytes;
    final bool ok = await AylaVideoPoster.captureAndUpload(
      mediaId: 'm1',
      path: '/tmp/v.mp4',
      upload: (String id, Uint8List bytes) async {
        uploadedId = id;
        uploadedBytes = bytes;
      },
    );
    expect(ok, isTrue);
    expect(uploadedId, 'm1');
    expect(uploadedBytes, jpeg);
  });

  test('抓帧返回 null / 空字节 → 不上传、返回 false（静默）', () async {
    bool uploaded = false;
    Future<void> upload(String id, Uint8List bytes) async {
      uploaded = true;
    }

    AylaVideoPoster.backend = _FakeCapture();
    expect(
      await AylaVideoPoster.captureAndUpload(
        mediaId: 'm1',
        path: '/tmp/v.mp4',
        upload: upload,
      ),
      isFalse,
    );

    AylaVideoPoster.backend = _FakeCapture(bytes: Uint8List(0));
    expect(
      await AylaVideoPoster.captureAndUpload(
        mediaId: 'm1',
        path: '/tmp/v.mp4',
        upload: upload,
      ),
      isFalse,
    );
    expect(uploaded, isFalse, reason: '无帧时不得调用上传');
  });

  test('上传失败 / 抓帧失败 → 返回 false 且不抛（海报失败静默）', () async {
    AylaVideoPoster.backend =
        _FakeCapture(bytes: Uint8List.fromList(<int>[1, 2]));
    expect(
      await AylaVideoPoster.captureAndUpload(
        mediaId: 'm1',
        path: '/tmp/v.mp4',
        upload: (String id, Uint8List bytes) async {
          throw Exception('poster upload failed');
        },
      ),
      isFalse,
    );

    AylaVideoPoster.backend = _FakeCapture(fail: true);
    expect(
      await AylaVideoPoster.captureAndUpload(
        mediaId: 'm1',
        path: '/tmp/v.mp4',
        upload: (String id, Uint8List bytes) async {},
      ),
      isFalse,
    );
  });
}
