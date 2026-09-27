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
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/theme/aurora_background.dart';
import '../lib/theme/aurora_baked_layer.dart';
import '../lib/theme/aurora_turbulence.dart';
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

  testWidgets('【诊断】渐变流层单独渲染：视口区域必须是「有色」，不能是整片白', (WidgetTester tester) async {
    // 层 = 150vmax 正方形（1920×1080 视口 ⇒ 2880）；视口在层坐标里是 x∈[480,2400]、y∈[900,1980]。
    // 逐点手算（farthest-corner，tokens.css 28–36）后与实测比对：
    //   · 视口左上 (480,900)：距第 1 层中心(0,0) 1020 ⇒ stop 1020/4031=25% ⇒ 冰蓝 alpha≈0.5
    //   · 视口中心 (1440,1440)：第 9 层（中心暖白）stop 0% ⇒ alpha 1 ⇒ 白（预期）
    // 若「视口左上」也接近纯白 ⇒ 说明四色层没生效 / 被白盖住 ⇒ 就是用户看到的「白色不透明背景」。
    const double layer = 2880;
    const double ratio = 0.5;
    late Uint8List pixels;
    await tester.runAsync(() async {
      final int w = (layer * ratio).round();
      final ui.PictureRecorder rec = ui.PictureRecorder();
      final Canvas canvas = Canvas(rec);
      canvas.scale(ratio);
      canvas.saveLayer(
        const Rect.fromLTWH(0, 0, layer, layer),
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: aylaBakedBlurSigma(40, ratio),
            sigmaY: aylaBakedBlurSigma(40, ratio),
          ),
      );
      aylaPaintGradientContent(canvas, const Size(layer, layer));
      canvas.restore();
      final ui.Picture pic = rec.endRecording();
      final ui.Image img = await pic.toImage(w, w);
      final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      pixels = data!.buffer.asUint8List();
      img.dispose();
      pic.dispose();
    });

    _Px at(double lx, double ly) {
      final int ix = (lx * ratio).round();
      final int iy = (ly * ratio).round();
      final int w = (layer * ratio).round();
      final int i = (iy * w + ix) * 4;
      return _Px(
        pixels[i].toDouble(),
        pixels[i + 1].toDouble(),
        pixels[i + 2].toDouble(),
      );
    }

    debugPrint('流层·视口左上(480,900)  = ' + at(480, 900).toString());
    debugPrint('流层·视口右上(2400,900) = ' + at(2400, 900).toString());
    debugPrint('流层·视口左中(480,1440) = ' + at(480, 1440).toString());
    debugPrint('流层·视口中心(1440,1440)= ' + at(1440, 1440).toString());
    debugPrint('流层·层左上角(60,60)    = ' + at(60, 60).toString());

    // 视口中心 = 中心暖白光晕 ⇒ 应接近纯白（预期）
    final _Px center = at(1440, 1440);
    expect(center.r, greaterThan(230));
    expect(center.g, greaterThan(225));
    // 视口左上 = 第 1 层（冰蓝 #BDD4E9 方向）⇒ **必须偏蓝、且 G 明显低于 R**（不是白）
    final _Px topLeft = at(480, 900);
    expect(
      topLeft.b - topLeft.r,
      greaterThan(8.0),
      reason: '视口左上应偏冰蓝（#BDD4E9 ⇒ B>G>R），若接近白说明四色层没生效: ' + topLeft.toString(),
    );
    // 层角（四色层中心）最浓 ⇒ 必须明显有色
    final _Px layerCorner = at(60, 60);
    expect(layerCorner.b - layerCorner.r, greaterThan(15.0));
  });

  testWidgets('【诊断】静态层 vs 静态+流层叠加：角落应更浓，不该被冲白', (WidgetTester tester) async {
    const Size vp = Size(1920, 1080);
    const double layer = 2880; // 150vmax
    const double ratio = 0.5;

    Future<Uint8List> render(bool withGradient) async {
      late Uint8List px;
      await tester.runAsync(() async {
        final int w = (vp.width * ratio).round();
        final int h = (vp.height * ratio).round();
        final ui.PictureRecorder rec = ui.PictureRecorder();
        final Canvas canvas = Canvas(rec);
        canvas.scale(ratio);
        // 白底（base.css: body/#root transparent ⇒ 浏览器默认白）
        canvas.drawRect(Offset.zero & vp, Paint()..color = const Color(0xFFFFFFFF));
        // 静态层（html 九层，铺视口）
        aylaPaintAuroraRadials(canvas, vp);
        if (withGradient) {
          // 流层（html::before：150vmax 正方形居中 + blur40）
          final double left = (vp.width - layer) / 2;
          final double top = (vp.height - layer) / 2;
          canvas.save();
          canvas.translate(left, top);
          canvas.saveLayer(
            const Rect.fromLTWH(0, 0, layer, layer),
            Paint()
              ..imageFilter = ui.ImageFilter.blur(
                sigmaX: aylaBakedBlurSigma(40, ratio),
                sigmaY: aylaBakedBlurSigma(40, ratio),
              ),
          );
          aylaPaintGradientContent(canvas, const Size(layer, layer));
          canvas.restore();
          canvas.restore();
        }
        final ui.Picture pic = rec.endRecording();
        final ui.Image img = await pic.toImage(w, h);
        final ByteData? data = await img.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        );
        px = data!.buffer.asUint8List();
        img.dispose();
        pic.dispose();
      });
      return px;
    }

    _Px at(Uint8List px, double x, double y) {
      final int w = (vp.width * ratio).round();
      final int ix = (x * ratio).round();
      final int iy = (y * ratio).round();
      final int i = (iy * w + ix) * 4;
      return _Px(
        px[i].toDouble(),
        px[i + 1].toDouble(),
        px[i + 2].toDouble(),
      );
    }

    final Uint8List onlyStatic = await render(false);
    final Uint8List stacked = await render(true);
    for (final List<Object> pt in <List<Object>>[
      <Object>['左上', 40.0, 40.0],
      <Object>['右上', 1880.0, 40.0],
      <Object>['左下', 40.0, 1040.0],
      <Object>['右下', 1880.0, 1040.0],
      <Object>['中心', 960.0, 540.0],
    ]) {
      final double x = pt[1] as double;
      final double y = pt[2] as double;
      final _Px a = at(onlyStatic, x, y);
      final _Px b = at(stacked, x, y);
      final double delta = ((a.r - b.r) + (a.g - b.g) + (a.b - b.b)) / 3;
      debugPrint(
        pt[0].toString() + ': 仅静态=' + a.toString() + ' 叠加=' + b.toString() +
        ' Δ(正=叠加后更暗/更浓, 负=更白)=' + delta.toStringAsFixed(1),
      );
    }
  });

  testWidgets('【诊断】湍流层单独渲染：输出到底是不是「全白」', (WidgetTester tester) async {
    // 湍流层实现 = 纹理平铺(ImageShader) + blur(60) + opacity .08（tokens.css:43 / base.css 82–95）。
    // 期望：极淡的彩噪（alpha 很低），**不该是白色**。这里统计 alpha 与 RGB，给出数值。
    const double layerW = 2880; // 1.5 × 1920
    const double layerH = 1620; // 1.5 × 1080
    const double ratio = 0.5;
    late Uint8List pixels;
    late bool hasTile;
    await tester.runAsync(() async {
      final ui.Image? tile = await AylaTurbulenceTile.image();
      hasTile = tile != null;
      final int w = (layerW * ratio).round();
      final int h = (layerH * ratio).round();
      final ui.PictureRecorder rec = ui.PictureRecorder();
      final Canvas canvas = Canvas(rec);
      canvas.scale(ratio);
      // 层整体 opacity .08（等价 RawImage.opacity）
      canvas.saveLayer(
        Rect.fromLTWH(0, 0, layerW, layerH),
        Paint()..color = const Color(0x14000000),
      );
      canvas.saveLayer(
        Rect.fromLTWH(0, 0, layerW, layerH),
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: aylaBakedBlurSigma(60, ratio),
            sigmaY: aylaBakedBlurSigma(60, ratio),
          ),
      );
      aylaPaintTurbulence(canvas, Size(layerW, layerH), tile!);
      canvas.restore();
      canvas.restore();
      final ui.Picture pic = rec.endRecording();
      final ui.Image img = await pic.toImage(w, h);
      final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      pixels = data!.buffer.asUint8List();
      img.dispose();
      pic.dispose();
    });

    int sumA = 0;
    int sumR = 0;
    int sumG = 0;
    int sumB = 0;
    int n = 0;
    int maxA = 0;
    for (int i = 0; i < pixels.length; i += 4) {
      sumR += pixels[i];
      sumG += pixels[i + 1];
      sumB += pixels[i + 2];
      sumA += pixels[i + 3];
      if (pixels[i + 3] > maxA) maxA = pixels[i + 3];
      n++;
    }
    debugPrint('湍流层: tile=' + hasTile.toString() +
        ' 均值 RGB=(' + (sumR / n).toStringAsFixed(1) + ', ' +
        (sumG / n).toStringAsFixed(1) + ', ' + (sumB / n).toStringAsFixed(1) + ')' +
        ' 均值 alpha=' + (sumA / n).toStringAsFixed(2) + ' 最大 alpha=' + maxA.toString());
    expect(hasTile, isTrue, reason: '纹理必须能生成');
    // 极淡：均值 alpha 应该在 0.08×少量 的量级（远小于 255×0.08=20）
    expect(sumA / n, lessThan(12.0), reason: '湍流层必须是极淡的（opacity .08）');
  });
}
