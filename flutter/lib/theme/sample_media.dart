/// 预览/画布专用示例图片 —— **程序生成，不依赖外网与后端**。
///
/// 背景（2026-09-20 用户指定）：媒体存储链路（MinIO 签名）暂不落地，
/// 且本机外网受限 —— 原先样张里的 `https://picsum.photos/...` 这类外链示例图
/// **显示不出来**，所有图片位都是空的。本文件提供同步生成的示例位图，
/// 让画布与 `@Preview` 能真实看到图片渲染效果（布局/圆角/裁切/角标）。
///
/// 纪律：
/// - **只用于预览与画布样张**，生产调用点不得使用（示例数据不是真实媒体）；
/// - 生成过程完全本地（纯像素计算 + 自写 PNG 编码），无网络、无缓存文件、无第三方包；
/// - 生成的图带可辨识的几何图案（渐变 + 圆 + 斜纹），便于肉眼判断裁切与比例。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// 示例图缓存（同一 seed + 尺寸只生成一次）。
final Map<String, Uint8List> _cache = <String, Uint8List>{};

/// 生成一张示例 PNG 的字节（同步）。
///
/// [seed] 决定配色与图案（不同 seed = 肉眼可区分的一张图）。
Uint8List aylaSampleImageBytes({
  int seed = 0,
  int width = 480,
  int height = 360,
}) {
  final String key = '$seed|$width|$height';
  final Uint8List? cached = _cache[key];
  if (cached != null) return cached;

  final Uint8List rgba = Uint8List(width * height * 4);
  final _SamplePalette palette = _SamplePalette.of(seed);
  final double cx = width * (0.3 + (seed % 3) * 0.2);
  final double cy = height * (0.35 + (seed % 2) * 0.25);
  final double radius = (width < height ? width : height) * 0.28;
  final double stripeWidth = 18 + (seed % 4) * 6;

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final double t = (x / width) * 0.55 + (y / height) * 0.45;
      int r = _lerpChannel(palette.fromR, palette.toR, t);
      int g = _lerpChannel(palette.fromG, palette.toG, t);
      int b = _lerpChannel(palette.fromB, palette.toB, t);
      // 斜纹（每 stripeWidth 一条，方向随 seed）
      final double stripe = (x + y * (seed.isEven ? 1 : -1)) % (stripeWidth * 2);
      if (stripe < stripeWidth) {
        r = _shade(r, 12);
        g = _shade(g, 12);
        b = _shade(b, 12);
      }
      // 圆心高光（可辨识几何）
      final double dx = x - cx;
      final double dy = y - cy;
      final double dist = (dx * dx + dy * dy) / (radius * radius);
      if (dist <= 1) {
        final double k = 1 - dist;
        r = _blend(r, palette.accentR, k * 0.75);
        g = _blend(g, palette.accentG, k * 0.75);
        b = _blend(b, palette.accentB, k * 0.75);
      }
      final int offset = (y * width + x) * 4;
      rgba[offset] = r;
      rgba[offset + 1] = g;
      rgba[offset + 2] = b;
      rgba[offset + 3] = 255;
    }
  }

  final Uint8List png = _pngEncode(width, height, rgba);
  _cache[key] = png;
  return png;
}

/// 示例图 `ImageProvider`（`MemoryImage`，可直接给 [Image]/[ImageProvider] 用）。
ImageProvider aylaSampleImage({
  int seed = 0,
  int width = 480,
  int height = 360,
}) =>
    MemoryImage(aylaSampleImageBytes(seed: seed, width: width, height: height));

int _lerpChannel(int from, int to, double t) {
  final double v = from + (to - from) * t;
  return v < 0 ? 0 : (v > 255 ? 255 : v.round());
}

int _shade(int channel, int delta) {
  final int v = channel - delta;
  return v < 0 ? 0 : v;
}

int _blend(int channel, int accent, double k) {
  final double v = channel + (accent - channel) * k;
  return v < 0 ? 0 : (v > 255 ? 255 : v.round());
}

/// 示例图配色（取自品牌 token：ice-300 / sakura-300 / glow-500 / indigo-700）。
class _SamplePalette {
  const _SamplePalette({
    required this.fromR,
    required this.fromG,
    required this.fromB,
    required this.toR,
    required this.toG,
    required this.toB,
    required this.accentR,
    required this.accentG,
    required this.accentB,
  });

  factory _SamplePalette.of(int seed) => _palettes[seed.abs() % _palettes.length];

  final int fromR;
  final int fromG;
  final int fromB;
  final int toR;
  final int toG;
  final int toB;
  final int accentR;
  final int accentG;
  final int accentB;

  /// ice-300 #BDD4E9 → sakura-300 #F9B0FF，点缀 glow-500 #F796FF
  static const List<_SamplePalette> _palettes = <_SamplePalette>[
    _SamplePalette(
      fromR: 0xBD,
      fromG: 0xD4,
      fromB: 0xE9,
      toR: 0xF9,
      toG: 0xB0,
      toB: 0xFF,
      accentR: 0xF7,
      accentG: 0x96,
      accentB: 0xFF,
    ),
    _SamplePalette(
      fromR: 0xF9,
      fromG: 0xB0,
      fromB: 0xFF,
      toR: 0xBD,
      toG: 0xD4,
      toB: 0xE9,
      accentR: 0x46,
      accentG: 0x5B,
      accentB: 0x92,
    ),
    _SamplePalette(
      fromR: 0xEC,
      fromG: 0xF0,
      fromB: 0xF2,
      toR: 0x9D,
      toG: 0xBF,
      toB: 0xE6,
      accentR: 0xF7,
      accentG: 0x96,
      accentB: 0xFF,
    ),
  ];
}

// ======================= 最小 PNG 编码器（stored deflate，无第三方依赖） =======================

/// RGBA 像素 → PNG 字节。
///
/// 只用 **stored（未压缩）deflate 块**，因此不需要 zlib/flate 实现：
/// zlib 头 + 分块 stored 块 + adler32，chunk 按 PNG 规范带 CRC32。
/// 体积略大（示例图尺寸小，可接受），但完全同步、无依赖、跨平台一致。
Uint8List _pngEncode(int width, int height, Uint8List rgba) {
  final BytesBuilder raw = BytesBuilder();
  for (int y = 0; y < height; y++) {
    raw.addByte(0); // filter type 0（None）
    raw.add(Uint8List.sublistView(rgba, y * width * 4, (y + 1) * width * 4));
  }
  final Uint8List filtered = raw.takeBytes();

  final BytesBuilder zlib = BytesBuilder();
  zlib.addByte(0x78); // CMF: deflate, 32K window
  zlib.addByte(0x01); // FLG
  const int maxBlock = 65535;
  for (int offset = 0; offset < filtered.length; offset += maxBlock) {
    final int end = (offset + maxBlock < filtered.length)
        ? offset + maxBlock
        : filtered.length;
    final int len = end - offset;
    zlib.addByte(offset + maxBlock >= filtered.length ? 1 : 0); // BFINAL + BTYPE=00
    zlib.addByte(len & 0xFF);
    zlib.addByte((len >> 8) & 0xFF);
    final int nlen = (~len) & 0xFFFF;
    zlib.addByte(nlen & 0xFF);
    zlib.addByte((nlen >> 8) & 0xFF);
    zlib.add(Uint8List.sublistView(filtered, offset, end));
  }
  zlib.add(_adler32Bytes(filtered));

  final BytesBuilder out = BytesBuilder();
  out.add(const <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]); // signature
  final BytesBuilder ihdr = BytesBuilder();
  ihdr.add(_u32(width));
  ihdr.add(_u32(height));
  ihdr.add(<int>[8, 6, 0, 0, 0]); // bit depth 8 / color type 6 (RGBA)
  out.add(_chunk('IHDR', ihdr.takeBytes()));
  out.add(_chunk('IDAT', zlib.takeBytes()));
  out.add(_chunk('IEND', Uint8List(0)));
  return out.takeBytes();
}

Uint8List _chunk(String type, Uint8List data) {
  final BytesBuilder body = BytesBuilder();
  body.add(ascii.encode(type));
  body.add(data);
  final Uint8List bodyBytes = body.takeBytes();
  final BytesBuilder out = BytesBuilder();
  out.add(_u32(data.length));
  out.add(bodyBytes);
  out.add(_u32(_crc32(bodyBytes)));
  return out.takeBytes();
}

Uint8List _u32(int value) => Uint8List(4)
  ..[0] = (value >> 24) & 0xFF
  ..[1] = (value >> 16) & 0xFF
  ..[2] = (value >> 8) & 0xFF
  ..[3] = value & 0xFF;

Uint8List _adler32Bytes(Uint8List data) {
  int a = 1;
  int b = 0;
  for (final int byte in data) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  return _u32((b << 16) | a);
}

int _crc32(Uint8List data) {
  int crc = 0xFFFFFFFF;
  for (final int byte in data) {
    crc ^= byte;
    for (int i = 0; i < 8; i++) {
      crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

// ======================= 预览示例图总开关 =======================

bool _sampleMediaEnabled = false;

/// 预览示例图是否启用（默认 **false** = 生产语义：图片走真实签名/网络链路）。
bool get aylaSampleMediaEnabled => _sampleMediaEnabled;

/// 启用示例媒体（**只在预览/画布样张调用**）。
void aylaEnableSampleMedia() {
  _sampleMediaEnabled = true;
}

/// 关闭示例媒体（生产默认；测试隔离用）。
void aylaDisableSampleMedia() {
  _sampleMediaEnabled = false;
}

/// 由媒体地址派生一张稳定的示例图（同一 src → 同一张图）。
///
/// 只用于预览：`ResourceImage` 在开关打开且未显式注入时用它替代签名链路。
ImageProvider aylaSampleImageFor(String src) {
  int seed = 0;
  for (final int unit in src.codeUnits) {
    seed = (seed * 31 + unit) & 0x7FFFFFFF;
  }
  return aylaSampleImage(seed: seed, width: 480, height: 360);
}
