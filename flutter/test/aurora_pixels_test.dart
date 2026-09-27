/// 背景**像素对账**：把各层真实光栅化后采样，与 **web 线上页面的实测像素**逐点比较
/// —— 「看起来像」不算数，要能对账。
///
/// web 实测方法（2026-09-27，1908×910 / dpr 1）：Playwright 打开线上登录页 → 注入
/// 「只保留静态兜底」/「只隐藏 html::before/after」的 style → 截图 → 逐字节解码 PNG 采样。
///   · 纯静态：左上 (189,212,233) · 右上 (158,192,230) · 上中 (239,241,247)
///             · 左下 (243,216,252) · 右下 (233,174,209) · 中 (254,249,251)
///   · 静态+双光斑（光斑 transform = matrix(1,0,0,1,0,0) = 关键帧 0%，与本地初相位同条件）：
///     左上 (189,212,233) · 右上 (158,192,230) · 上中 (219,229,243) · 左下 (243,216,252)。
///     **页面底色是白**（body 无背景）—— 本地也要铺白底，否则右下角对不上。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/aurora_background.dart';
import '../lib/theme/tokens.dart';

/// 一个 sRGB 三元组。
class _Px {
  const _Px(this.r, this.g, this.b);
  final double r;
  final double g;
  final double b;

  @override
  String toString() =>
      '(' + r.toStringAsFixed(1) + ', ' + g.toStringAsFixed(1) + ', ' + b.toStringAsFixed(1) + ')';
}

/// 把一段绘制录成图并返回 RGBA 字节。
Future<Uint8List> _rasterize(
  WidgetTester tester, {
  required Size size,
  required void Function(Canvas canvas, Size size) paint,
}) async {
  late Uint8List pixels;
  await tester.runAsync(() async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    paint(canvas, size);
    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(
      size.width.round(),
      size.height.round(),
    );
    final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    pixels = data!.buffer.asUint8List();
    image.dispose();
    picture.dispose();
  });
  return pixels;
}

void main() {
  const double vw = 1908;
  const double vh = 910;
  const Size vp = Size(vw, vh);

  _Px at(Uint8List pixels, double x, double y) {
    final int i = ((y.round() * vw.round()) + x.round()) * 4;
    return _Px(
      pixels[i].toDouble(),
      pixels[i + 1].toDouble(),
      pixels[i + 2].toDouble(),
    );
  }

  /// 与 web 实测逐点比对（容差 12/255：sRGB 量化 + 抗锯齿 + 浏览器色彩管理）。
  void near(_Px mine, int wr, int wg, int wb, String label) {
    expect((mine.r - wr).abs(), lessThan(12.0), reason: label + ' R ' + mine.toString());
    expect((mine.g - wg).abs(), lessThan(12.0), reason: label + ' G ' + mine.toString());
    expect((mine.b - wb).abs(), lessThan(12.0), reason: label + ' B ' + mine.toString());
  }

  testWidgets('静态九层：对账 web 线上实测像素', (WidgetTester tester) async {
    final Uint8List px = await _rasterize(
      tester,
      size: vp,
      paint: (Canvas canvas, Size size) => aylaPaintAuroraRadials(canvas, size),
    );
    debugPrint('纯静态 左上 = ' + at(px, 2, 2).toString());
    debugPrint('纯静态 右上 = ' + at(px, vw - 3, 2).toString());
    debugPrint('纯静态 上中 = ' + at(px, vw / 2, 2).toString());
    debugPrint('纯静态 左下 = ' + at(px, 2, vh - 3).toString());
    debugPrint('纯静态 中   = ' + at(px, vw / 2, vh / 2).toString());
    near(at(px, 2, 2), 189, 212, 233, '左上');
    near(at(px, vw - 3, 2), 158, 192, 230, '右上');
    near(at(px, vw / 2, 2), 239, 241, 247, '上中');
    near(at(px, 2, vh - 3), 243, 216, 252, '左下');
    near(at(px, vw / 2, vh / 2), 254, 249, 251, '中心');
  });

  testWidgets('静态 + 双光斑（相位 0）：对账 web 线上实测像素', (WidgetTester tester) async {
    const double d = 0.4 * vw; // 40vw
    final Uint8List px = await _rasterize(
      tester,
      size: vp,
      paint: (Canvas canvas, Size size) {
        // 浏览器页面底是白（body 无背景）—— 本地也要铺白底。
        canvas.drawRect(
          Offset.zero & size,
          Paint()..color = const Color(0xFFFFFFFF),
        );
        aylaPaintAuroraRadials(canvas, size);
        canvas.save();
        canvas.translate(vw * 0.25, -vh * 0.1); // 冰蓝：left 25% / top -10%
        aylaPaintBlob(canvas, Size(d, d), AylaColors.ice500, 0.65);
        canvas.restore();
        canvas.save();
        canvas.translate(vw * 0.75 - d, vh * 1.1 - d); // 亮粉：right 25% / bottom -10%
        aylaPaintBlob(canvas, Size(d, d), AylaColors.sakura300, 0.65);
        canvas.restore();
      },
    );
    debugPrint('静态+光斑 左上   = ' + at(px, 2, 2).toString());
    debugPrint('静态+光斑 上中   = ' + at(px, vw / 2, 2).toString());
    debugPrint('静态+光斑 左下   = ' + at(px, 2, vh - 3).toString());
    debugPrint('静态+光斑 中偏左 = ' + at(px, 800, 455).toString());
    near(at(px, 2, 2), 189, 212, 233, '左上');
    near(at(px, vw - 3, 2), 158, 192, 230, '右上');
    near(at(px, vw / 2, 2), 219, 229, 243, '上中');
    near(at(px, 2, vh - 3), 243, 216, 252, '左下');
    near(at(px, vw - 3, vh - 3), 233, 174, 209, '右下');
    near(at(px, vw / 2, vh - 3), 253, 230, 247, '下中');
    near(at(px, 800, 455), 222, 221, 243, '中偏左');
  });
}
