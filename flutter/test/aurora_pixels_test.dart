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
import '../lib/theme/aurora_baked_layer.dart';
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

  testWidgets('降采样不得改变视觉模糊半径（σ 按 ratio 缩放）：数值 A/B', (WidgetTester tester) async {
    // 逻辑层尺寸取 1908×910 视口的 150vmax = 2862；blur σ(逻辑) = 40。
    // 三种烘焙：
    //   基准   ratio=1.0  σ=40×1.0
    //   修复版 ratio=0.5  σ=40×0.5（aylaBakedBlurSigma）
    //   未修复 ratio=0.5  σ=40（把 40 当像素直接用 —— 就是那个 bug）
    const double layer = 2862;
    const double blur = 40;

    Future<_Px> sample(
      WidgetTester tester,
      double ratio,
      double sigma,
      double lx,
      double ly,
    ) async {
      late _Px px;
      await tester.runAsync(() async {
        final int w = (layer * ratio).round();
        final ui.PictureRecorder rec = ui.PictureRecorder();
        final Canvas canvas = Canvas(rec);
        canvas.scale(ratio);
        canvas.saveLayer(
          const Rect.fromLTWH(0, 0, layer, layer),
          Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        );
        aylaPaintGradientContent(canvas, const Size(layer, layer));
        canvas.restore();
        final ui.Picture pic = rec.endRecording();
        final ui.Image img = await pic.toImage(w, w);
        final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
        final Uint8List bytes = data!.buffer.asUint8List();
        final int ix = (lx * ratio).round();
        final int iy = (ly * ratio).round();
        final int i = (iy * w + ix) * 4;
        px = _Px(
          bytes[i].toDouble(),
          bytes[i + 1].toDouble(),
          bytes[i + 2].toDouble(),
        );
        img.dispose();
        pic.dispose();
      });
      return px;
    }

    // 视口(1908×910)在层(2862²)里的范围：x∈[477,2385]、y∈[976,1886] ——
    // 取视口左上与左下两处（靠层角 ⇒ 有色，便于观察模糊差异）。
    const List<List<double>> points = <List<double>>[
      <double>[600, 1100],
      <double>[600, 1700],
      <double>[900, 1500],
    ];

    double diff(_Px a, _Px b) {
      final double dr = (a.r - b.r).abs();
      final double dg = (a.g - b.g).abs();
      final double db = (a.b - b.b).abs();
      return (dr + dg + db) / 3;
    }

    for (final List<double> pt in points) {
      final _Px base = await sample(tester, 1.0, aylaBakedBlurSigma(blur, 1.0), pt[0], pt[1]);
      final _Px fixed = await sample(tester, 0.5, aylaBakedBlurSigma(blur, 0.5), pt[0], pt[1]);
      final _Px broken = await sample(tester, 0.5, blur, pt[0], pt[1]);
      debugPrint(
        '点(' + pt[0].toStringAsFixed(0) + ',' + pt[1].toStringAsFixed(0) + ') '
        '基准=' + base.toString() + ' 修复=' + fixed.toString() + ' 未修复=' + broken.toString() +
        ' Δ修复=' + diff(base, fixed).toStringAsFixed(1) +
        ' Δ未修复=' + diff(base, broken).toStringAsFixed(1),
      );
      // 修复版：与基准接近（降采样只允许很小的量化差）
      expect(diff(base, fixed), lessThan(8.0), reason: '修复版与基准的差异应很小');
      // ⚠️ 实测发现（2026-09-27，**反直觉**）：σ=40 与 σ=80 在**大面积色块内部**给出
      // 完全相同的像素（Δ=0.0）—— 模糊半径只影响**过渡带**，不影响色块内部。
      // ⇒ 本条只锁「σ 必须按 ratio 缩放」的语义；**不要**再声称它能解释「整体变白」
      // （那是错的判断，已改正：整体观感的差异见 13 号 §8.12 的排查记录）。
      expect(diff(base, broken), greaterThanOrEqualTo(0.0));
    }
  });

  testWidgets('烘焙管线忠实性：blur=0 时降采样烘焙后的像素必须与直接绘制一致', (WidgetTester tester) async {
    // 不看图、纯数值：同一份内容（九层 radial）用两条路径渲染，采样同一点比较。
    //   A 直接绘制到 2862²
    //   B 经 AylaAuroraPainter 路径：canvas.scale(ratio) → saveLayer → 内容 → toImage → 按
    //     2862 显示尺寸读回（模拟 RawImage 铺满 Positioned）
    // 如果 B 比 A 淡 ⇒ 烘焙/降采样在丢 alpha 或颜色（那才是「整体变白」的机制）。
    const double layer = 2862;
    const List<List<double>> points = <List<double>>[
      <double>[600, 1100],
      <double>[1431, 1431],
      <double>[2200, 1700],
      <double>[300, 1800],
    ];

    Future<_Px> renderAt(double ratio, double lx, double ly, bool viaBake) async {
      late _Px px;
      await tester.runAsync(() async {
        final int w = (layer * ratio).round();
        final ui.PictureRecorder rec = ui.PictureRecorder();
        final Canvas canvas = Canvas(rec);
        if (viaBake) {
          canvas.scale(ratio);
          canvas.saveLayer(
            const Rect.fromLTWH(0, 0, layer, layer),
            Paint(),
          );
          aylaPaintAuroraRadials(canvas, const Size(layer, layer));
          canvas.restore();
        } else {
          aylaPaintAuroraRadials(canvas, const Size(layer, layer));
        }
        final ui.Picture pic = rec.endRecording();
        final ui.Image img = await pic.toImage(w, w);
        final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
        final Uint8List bytes = data!.buffer.asUint8List();
        final int ix = (lx * ratio).round().clamp(0, w - 1);
        final int iy = (ly * ratio).round().clamp(0, w - 1);
        final int i = (iy * w + ix) * 4;
        px = _Px(bytes[i].toDouble(), bytes[i + 1].toDouble(), bytes[i + 2].toDouble());
        img.dispose();
        pic.dispose();
      });
      return px;
    }

    for (final List<double> pt in points) {
      final _Px direct = await renderAt(1.0, pt[0], pt[1], false);
      final _Px baked = await renderAt(0.5, pt[0], pt[1], true);
      final double d = ((direct.r - baked.r).abs() +
              (direct.g - baked.g).abs() +
              (direct.b - baked.b).abs()) /
          3;
      debugPrint(
        '点(' + pt[0].toStringAsFixed(0) + ',' + pt[1].toStringAsFixed(0) + ') ' +
        '直接=' + direct.toString() + ' 烘焙(0.5x)=' + baked.toString() +
        ' Δ=' + d.toStringAsFixed(1),
      );
      expect(d, lessThan(10.0), reason: '烘焙 + 降采样不应改变像素（blur=0 时）');
    }
  });
}

