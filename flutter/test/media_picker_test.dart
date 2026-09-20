/// 选文件 + 本地校验组合的定向测试（后端注入，不触碰平台通道）。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/media/media_picker.dart';
import '../lib/core/media/media_validation.dart';

/// 假后端：记录调用参数并返回预设文件。
class _FakeBackend implements AylaPickerBackend {
  _FakeBackend(this.files);

  final List<AylaPickedFile> files;
  AylaPickKind? lastKind;
  bool? lastMultiple;

  @override
  Future<List<AylaPickedFile>> pick({
    required AylaPickKind kind,
    bool multiple = false,
  }) async {
    lastKind = kind;
    lastMultiple = multiple;
    return files;
  }
}

AylaPickedFile picked(String name, int size) => AylaPickedFile(
      name: name,
      size: size,
      mimeType: aylaMimeFromName(name),
      readBytes: () async => Uint8List(size),
    );

void main() {
  tearDown(() => AylaMediaPicker.backend = const AylaFilePickerBackend());

  group('aylaMimeFromName', () {
    test('常见扩展名 → MIME；大小写无关；未知 → octet-stream', () {
      expect(aylaMimeFromName('a.png'), 'image/png');
      expect(aylaMimeFromName('a.JPG'), 'image/jpeg');
      expect(aylaMimeFromName('a.mp4'), 'video/mp4');
      expect(aylaMimeFromName('a.pdf'), 'application/pdf');
      expect(aylaMimeFromName('noext'), 'application/octet-stream');
      expect(aylaMimeFromName('trailing.'), 'application/octet-stream');
      expect(aylaMimeFromName('a.unknownext'), 'application/octet-stream');
    });
  });

  group('AylaMediaPicker 选择 + 校验', () {
    test('用户取消：无文件、无错误（取消不是失败）', () async {
      AylaMediaPicker.backend = _FakeBackend(<AylaPickedFile>[]);
      final AylaPickResult result = await AylaMediaPicker.pickImages();
      expect(result.files, isEmpty);
      expect(result.error, isNull);
      expect(result.ok, isFalse);
    });

    test('图片：白名单通过；非图片与空文件被拦', () async {
      AylaMediaPicker.backend = _FakeBackend(<AylaPickedFile>[picked('a.png', 1024)]);
      expect((await AylaMediaPicker.pickImages()).ok, isTrue);

      AylaMediaPicker.backend = _FakeBackend(<AylaPickedFile>[picked('a.pdf', 1024)]);
      expect(
        (await AylaMediaPicker.pickImages()).error,
        aylaImageUnsupportedMessage,
      );

      AylaMediaPicker.backend = _FakeBackend(<AylaPickedFile>[picked('a.png', 0)]);
      expect((await AylaMediaPicker.pickImages()).error, '图片内容为空');
    });

    test('视频：mp4 通过；图片文件按不支持拦截', () async {
      AylaMediaPicker.backend = _FakeBackend(<AylaPickedFile>[picked('a.mp4', 2048)]);
      expect((await AylaMediaPicker.pickVideo()).ok, isTrue);

      AylaMediaPicker.backend = _FakeBackend(<AylaPickedFile>[picked('a.png', 2048)]);
      expect(
        (await AylaMediaPicker.pickVideo()).error,
        aylaVideoUnsupportedMessage,
      );
    });

    test('文件：超限与禁执行文档被拦；普通文档通过', () async {
      AylaMediaPicker.backend =
          _FakeBackend(<AylaPickedFile>[picked('a.pdf', aylaFileMaxBytes + 1)]);
      expect((await AylaMediaPicker.pickFile()).error, aylaFileTooLargeMessage);

      AylaMediaPicker.backend = _FakeBackend(<AylaPickedFile>[picked('a.html', 512)]);
      expect((await AylaMediaPicker.pickFile()).error, aylaFileUnsafeMessage);

      AylaMediaPicker.backend = _FakeBackend(<AylaPickedFile>[picked('a.zip', 512)]);
      expect((await AylaMediaPicker.pickFile()).ok, isTrue);
    });

    test('多选：任一张非法即整体拦截（已通过项保留在结果里）', () async {
      AylaMediaPicker.backend = _FakeBackend(<AylaPickedFile>[
        picked('ok.png', 100),
        picked('bad.pdf', 100),
      ]);
      final AylaPickResult result = await AylaMediaPicker.pickImages();
      expect(result.error, aylaImageUnsupportedMessage);
      expect(result.files.length, 1);
      expect(result.files.single.name, 'ok.png');
    });

    test('后端调用参数：图片多选 / 视频单选 / 文件单选', () async {
      final _FakeBackend backend = _FakeBackend(<AylaPickedFile>[]);
      AylaMediaPicker.backend = backend;
      await AylaMediaPicker.pickImages();
      expect(backend.lastKind, AylaPickKind.image);
      expect(backend.lastMultiple, isTrue);
      await AylaMediaPicker.pickVideo();
      expect(backend.lastKind, AylaPickKind.video);
      expect(backend.lastMultiple, isFalse);
      await AylaMediaPicker.pickFile();
      expect(backend.lastKind, AylaPickKind.file);
    });
  });
}
