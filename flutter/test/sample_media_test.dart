/// 预览示例图（自写 PNG 编码器）的定向测试：字节合法 + 可被 Flutter 解码。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/sample_media.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PNG 头与 IHDR 正确', () {
    final Uint8List bytes = aylaSampleImageBytes(seed: 0, width: 16, height: 12);
    expect(
      bytes.sublist(0, 8),
      <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
      reason: 'PNG signature',
    );
    // IHDR 数据：宽 16 / 高 12 / bitDepth 8 / colorType 6
    expect(bytes.sublist(16, 20), <int>[0, 0, 0, 16]);
    expect(bytes.sublist(20, 24), <int>[0, 0, 0, 12]);
    expect(bytes.sublist(24, 29), <int>[8, 6, 0, 0, 0]);
  });

  test('可被 Flutter 解码，且尺寸/像素符合预期', () async {
    final Uint8List bytes = aylaSampleImageBytes(seed: 1, width: 24, height: 16);
    final ui.Codec codec = await ui.instantiateImageCodec(bytes);
    final ui.FrameInfo frame = await codec.getNextFrame();
    expect(frame.image.width, 24);
    expect(frame.image.height, 16);
    final ByteData? pixels = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    expect(pixels, isNotNull);
    // 不透明（alpha 通道全部 255）—— 示例图不应带透明
    for (int i = 3; i < pixels!.lengthInBytes; i += 4) {
      expect(pixels.getUint8(i), 255);
    }
  });

  test('同一 seed + 尺寸命中缓存（同对象）', () {
    final Uint8List a = aylaSampleImageBytes(seed: 2, width: 8, height: 8);
    final Uint8List b = aylaSampleImageBytes(seed: 2, width: 8, height: 8);
    expect(identical(a, b), isTrue);
  });

  test('不同 seed 产出不同图案', () {
    final Uint8List a = aylaSampleImageBytes(seed: 3, width: 12, height: 12);
    final Uint8List b = aylaSampleImageBytes(seed: 4, width: 12, height: 12);
    expect(a, isNot(equals(b)));
  });
}
