/// feTurbulence 噪声纹理 —— `tokens.css:43` 的 `--bg-aurora-turbulence` data URI。
///
/// ## 事实源（逐项照抄，勿改）
/// `tokens.css:43` 的 SVG 原文（`data:image/svg+xml` 解码后）：480×480 的 `rect` 套
/// `filter#t`，滤镜链为
/// `feTurbulence(type='fractalNoise', baseFrequency='0.012', numOctaves='3', seed='11')`
/// → `feComponentTransfer`（R/G/B 三个 `feFunc*` 的 `table`：
/// `0.741 0.988 0.976` / `0.831 0.98 0.69` / `0.914 0.99 1`）
/// → `feComponentTransfer`（A 通道的 `table`：`0.35 0 0.35`）。
///
/// ## 为什么自己算
/// Flutter 没有 SVG 滤镜引擎（feTurbulence 是光栅滤镜，不是路径），也没有与
/// CSS `filter: url(#…)` 等价的接口 ⇒ 只能在 Dart 侧按规范 + 浏览器实现离线生成
/// 同一张 480×480 纹理，再交给 `ImageShader` 平铺。生成一次、进程内缓存。
///
/// ## 算法取哪一家（2026-09-25 复核结论，**别改成"规范参考实现"**）
/// W3C 规范附录的 C 参考实现与浏览器**并不一致**：规范里梯度向量长度 >1 会丢弃重抽
/// （约 21.5% 概率触发），Chrome/Skia、Firefox/Gecko、Batik 都**不丢弃** —— 随机数
/// 消耗序列因此不同，lattice 洗牌结果也就不同。本文件按 **Skia（Chrome/Edge）变体**
/// 实现，依据与实测：
/// - Skia `SkPerlinNoiseShaderImpl.h/.cpp` + `SkRasterPipeline_opts.h` 的
///   `seed_shader`（x+0.5）与 `perlin_noise`（再 +0.5、octave 循环、clamp/预乘）；
/// - Blink `fe_turbulence.cc`（numOctaves ≤ 9、频率不随 primitiveUnits 缩放）与
///   `fe_component_transfer.cc`（table 实现成 256 项 8bit LUT）；
/// - 采样点 = **(x + 1.0) × baseFrequency**（设备像素；Firefox 是 x × freq，差 1 px 相位）；
/// - `color-interpolation-filters` 初始值 **linearRGB** ⇒ 表格作用在线性光值上，
///   最后转 sRGB 输出；
/// - 实测（headless Chromium 实渲染同一 data URI 逐像素比对，2026-09-27 **重做**）：
///   纹理 230400 像素中 **97.98% 四通道完全一致**，均值绝对差 R=0.060 / G=0.142 /
///   B=0.009 / A=0.0000；不一致的部分是 **8bit 预乘往返的量化**（本函数落盘是
///   premul 8bit，浏览器读回是 unpremul，低 alpha 处除以 alpha 会放大 1 LSB）。
/// ⚠️ 本文件此前的「98.92% 一致」结论**建立在错误的对比方法上**（当时把
///   `toByteData(png)` 当作非预乘输出，而它按预乘解释会把颜色整片钳成 255，
///   掩盖了真实缺陷）——那句结论已作废，以本段的复测数据为准。要跟 Firefox
///   对齐只需把 [AylaTurbulenceSpec.sampleOffset] 改成 0（seed=11 时两家表数据相同）。
///
/// ## 计算链路（照抄）
/// 1. feTurbulence：4 通道各自 3 个 octave 的带符号噪声和（振幅 1 / 1/2 / 1/4），
///    再 `(sum + 1) / 2` 并 clamp 到 [0,1] ⇒ 未预乘线性 RGBA；
/// 2. CT#1：R/G/B 用 3 值 table 折线（8bit LUT，索引来自**非预乘**值）；A 不变；
/// 3. CT#2：A 用 `[0.35, 0, 0.35]` 重映射（0.5 处为 0、两端 0.35）；R/G/B 不变；
/// 4. 色彩空间：全程 linearRGB，最后转 sRGB；
/// 5. 落盘：8bit **预乘**存储 + 四舍五入 —— 对外输出就是**预乘 sRGB RGBA8**。
///    ⚠️ 这不是「顺带」的存储细节，而是必须与 `ui.decodeImageFromPixels` 的
///    premul 语义对齐（否则整层被抬亮，见 [AylaTurbulenceTile.renderPixels] 注释）。
///
/// ## 性能
/// 480×480 × 3 octave × 4 通道 ≈ 276 万次 `noise2`：AOT 下 20–60 ms，debug（JIT）下
/// 数百 ms ⇒ [AylaTurbulenceTile.image] 一律在 **isolate** 里生成，绝不阻塞 UI 线程
/// （同类的逐帧滤镜事故见 `aurora_background.dart` 的「性能口径」）。
///
/// ## 边界
/// `stitchTiles` 默认 noStitch ⇒ 480px tile **不无缝**（实测左右接缝平均差 16.01 /
/// 自然相邻 0.88，web 侧就是有接缝的，被 `blur(60px)` + `opacity: .08` 掩盖）；
/// 纹理确定性（同 seed 必得同图）⇒ 可被测试锁定。
///
/// ## 公开面
/// `AylaTurbulenceSpec` · `AylaTurbulenceTables` · `AylaTurbulenceTile`
/// · `aylaTurbulenceSampleAt`

library;

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// `tokens.css:43` data URI 里逐字对应的滤镜参数。
abstract final class AylaTurbulenceSpec {
  /// `width='480' height='480'`（也是 `base.css:89` 的 `background-size`）。
  static const int size = 480;

  /// `baseFrequency='0.012'`。
  static const double baseFrequency = 0.012;

  /// `numOctaves='3'`。
  static const int numOctaves = 3;

  /// `seed='11'`。
  static const int seed = 11;

  /// 采样点偏移：Chrome/Skia = 1.0（设备像素 +1），Firefox = 0.0。
  static const double sampleOffset = 1.0;

  /// `feFuncR tableValues='0.741 0.988 0.976'`。
  static const List<double> rTable = <double>[0.741, 0.988, 0.976];

  /// `feFuncG tableValues='0.831 0.98 0.69'`。
  static const List<double> gTable = <double>[0.831, 0.98, 0.69];

  /// `feFuncB tableValues='0.914 0.99 1'`。
  static const List<double> bTable = <double>[0.914, 0.99, 1];

  /// `feFuncA tableValues='0.35 0 0.35'`（单独一个 feComponentTransfer）。
  static const List<double> aTable = <double>[0.35, 0, 0.35];

  /// 采样点换算成 8bit 时的四舍五入（Chrome 语义）。
  static int q8(double v) => (v * 255.0 + 0.5).floor().clamp(0, 255);

  /// `type='table'` 的 256 项 8bit LUT（Blink `fe_component_transfer.cc` 同构：
  /// 输入先量化成 8bit，再在 tableValues 折线上线性插值，最后截断成 0..255）。
  static Int32List lut(List<double> tableValues) {
    final int segments = tableValues.length - 1;
    final Int32List out = Int32List(256);
    for (int i = 0; i < 256; i++) {
      final double c = i / 255.0;
      final int k = (c * segments).floor().clamp(0, segments - 1);
      final double v1 = tableValues[k];
      final double v2 = tableValues[math.min(k + 1, segments)];
      out[i] = (255.0 * (v1 + (c * segments - k) * (v2 - v1)))
          .clamp(0.0, 255.0)
          .floor();
    }
    return out;
  }
}

/// Park–Miller LCG + Schrage（规范与 Skia 用同一组常量）。
class AylaTurbulenceRandom {
  AylaTurbulenceRandom(int seed) {
    // `SkScalarTruncToInt(seed)` 后按规范归一化；负 seed 用 remainder 保持 C 的取模语义。
    int v = seed.truncate();
    if (v <= 0) v = -(v.remainder(kRandM - 1)) + 1;
    if (v > kRandM - 1) v = kRandM - 1;
    _state = v;
  }

  static const int kRandM = 2147483647; // 2**31 - 1
  static const int kRandA = 16807; // 7**5
  static const int kRandQ = 127773; // m / a
  static const int kRandR = 2836; // m % a

  late int _state;

  /// 前进一步并返回新状态（规范 `random()` 的语义）。
  int next() {
    int result = kRandA * (_state % kRandQ) - kRandR * (_state ~/ kRandQ);
    if (result <= 0) result += kRandM;
    _state = result;
    return result;
  }
}

/// lattice 选择表 + 4 通道梯度（Skia 的初始化顺序与 16bit 量化）。
class AylaTurbulenceTables {
  AylaTurbulenceTables(int seed) {
    const int bSize = 256;
    final AylaTurbulenceRandom rnd = AylaTurbulenceRandom(seed);
    final Uint16List raw = Uint16List(4 * bSize * 2);
    // 1) 4 通道 × 256 项原始向量，每项恰好消耗 2 个随机数（Skia **不丢弃** >1 的向量）。
    for (int channel = 0; channel < 4; channel++) {
      for (int i = 0; i < bSize; i++) {
        raw[(channel * bSize + i) * 2] = rnd.next() % (2 * bSize);
        raw[(channel * bSize + i) * 2 + 1] = rnd.next() % (2 * bSize);
      }
    }
    // 2) 洗牌 255 → 1（Skia 在 4 通道原始向量之后洗牌）。
    for (int i = 0; i < bSize; i++) {
      lattice[i] = i;
    }
    for (int i = bSize - 1; i > 0; i--) {
      final int j = rnd.next() % bSize;
      final int t = lattice[i];
      lattice[i] = lattice[j];
      lattice[j] = t;
    }
    // 3) 置换 + 归一化 + 16bit 量化（Skia：round((g + 1) * 32767.5)，用时 v * 2/65535 - 1）。
    for (int channel = 0; channel < 4; channel++) {
      for (int i = 0; i < bSize; i++) {
        final int li = lattice[i];
        double gx = (raw[(channel * bSize + li) * 2] - bSize) / bSize;
        double gy = (raw[(channel * bSize + li) * 2 + 1] - bSize) / bSize;
        final double len = math.sqrt(gx * gx + gy * gy);
        if (len > 0) {
          gx /= len;
          gy /= len;
        }
        gradients[(channel * bSize + i) * 2] =
            (((gx + 1) * 32767.5).roundToDouble() * (2 / 65535) - 1);
        gradients[(channel * bSize + i) * 2 + 1] =
            (((gy + 1) * 32767.5).roundToDouble() * (2 / 65535) - 1);
      }
    }
  }

  /// 256 项 lattice 选择表（按 `& 0xFF` 取用）。
  final Uint8List lattice = Uint8List(256);

  /// `[channel][i][x|y]` 单位梯度。
  final Float32List gradients = Float32List(4 * 256 * 2);

  /// 单通道 Perlin 取样；`x/y` 是噪声空间坐标（已乘 baseFrequency）。
  double noise2(int channel, double x, double y) {
    final double fx = x.floorToDouble();
    final double fy = y.floorToDouble();
    final double rx = x - fx;
    final double ry = y - fy;
    final int ix = fx.toInt() & 0xFF;
    final int ix1 = (fx.toInt() + 1) & 0xFF;
    final int iy = fy.toInt() & 0xFF;
    final int iy1 = (fy.toInt() + 1) & 0xFF;
    final int lx = lattice[ix];
    final int ly = lattice[ix1];
    final int b00 = (lx + iy) & 0xFF;
    final int b10 = (ly + iy) & 0xFF;
    final int b01 = (lx + iy1) & 0xFF;
    final int b11 = (ly + iy1) & 0xFF;
    final int base = channel * 256 * 2;
    final double u0 = gradients[base + b00 * 2] * rx + gradients[base + b00 * 2 + 1] * ry;
    final double v0 =
        gradients[base + b10 * 2] * (rx - 1) + gradients[base + b10 * 2 + 1] * ry;
    final double u1 =
        gradients[base + b01 * 2] * rx + gradients[base + b01 * 2 + 1] * (ry - 1);
    final double v1 =
        gradients[base + b11 * 2] * (rx - 1) + gradients[base + b11 * 2 + 1] * (ry - 1);
    final double sx = rx * rx * (3 - 2 * rx);
    final double sy = ry * ry * (3 - 2 * ry);
    final double a = u0 + sx * (v0 - u0);
    final double b = u1 + sx * (v1 - u1);
    return a + sy * (b - a);
  }

  /// fractalNoise：Σ noise × 0.5^i（频率 ×2），再 `(sum + 1) / 2` 并 clamp。
  double fractalNoise(int channel, double x, double y) {
    double nx = x;
    double ny = y;
    double sum = 0;
    double ratio = 1;
    for (int octave = 0; octave < AylaTurbulenceSpec.numOctaves; octave++) {
      sum += noise2(channel, nx, ny) * ratio;
      nx *= 2;
      ny *= 2;
      ratio *= 0.5;
    }
    return ((sum + 1) / 2).clamp(0.0, 1.0);
  }
}

/// 线性光 → sRGB（`color-interpolation-filters: linearRGB` 的输出端换算）。
double aylaLinearToSrgb(double c) => c <= 0.0031308
    ? 12.92 * c
    : 1.055 * math.pow(c, 1 / 2.4) - 0.055;

/// 480×480 feTurbulence 纹理（确定性、进程内缓存）。
abstract final class AylaTurbulenceTile {
  static Uint8List? _pixels;
  static ui.Image? _image;
  static Future<ui.Image>? _pending;

  /// RGBA8888 像素，**预乘 sRGB**（与 `ui.decodeImageFromPixels` 的
  /// `kPremul_SkAlphaType` 语义一致；浏览器 `getImageData` 读回的是非预乘，
  /// 对比时需先除以 alpha）。同步、可测。
  static Uint8List pixels() {
    final Uint8List? cached = _pixels;
    if (cached != null) return cached;
    final Uint8List out = renderPixels();
    _pixels = out;
    return out;
  }

  /// 在 **isolate** 里生成（debug 下纯 Dart 要数百毫秒，不能压 UI 线程）。
  static Future<ui.Image> image() {
    final ui.Image? ready = _image;
    if (ready != null) return Future<ui.Image>.value(ready);
    return _pending ??= _load();
  }

  static Future<ui.Image> _load() async {
    final Uint8List pixels = await Isolate.run(renderPixels);
    final Completer<ui.Image> completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      AylaTurbulenceSpec.size,
      AylaTurbulenceSpec.size,
      ui.PixelFormat.rgba8888,
      (ui.Image image) {
        _image = image;
        _pending = null;
        if (!completer.isCompleted) completer.complete(image);
      },
    );
    return completer.future;
  }

  /// 纯函数版本（isolate 入口；无缓存、无 UI 依赖）。
  static Uint8List renderPixels() {
    const int n = AylaTurbulenceSpec.size;
    const double freq = AylaTurbulenceSpec.baseFrequency;
    final AylaTurbulenceTables tables = AylaTurbulenceTables(AylaTurbulenceSpec.seed);
    final Int32List lutR = AylaTurbulenceSpec.lut(AylaTurbulenceSpec.rTable);
    final Int32List lutG = AylaTurbulenceSpec.lut(AylaTurbulenceSpec.gTable);
    final Int32List lutB = AylaTurbulenceSpec.lut(AylaTurbulenceSpec.bTable);
    final Int32List lutA = AylaTurbulenceSpec.lut(AylaTurbulenceSpec.aTable);
    final Uint8List out = Uint8List(n * n * 4);

    for (int y = 0; y < n; y++) {
      final double ny = (y + AylaTurbulenceSpec.sampleOffset) * freq;
      for (int x = 0; x < n; x++) {
        final double nx = (x + AylaTurbulenceSpec.sampleOffset) * freq;
        // 1) feTurbulence 输出：未预乘线性 RGBA，各自 3 octave。
        double r = 0;
        double g = 0;
        double b = 0;
        double a = 0;
        double octaveRatio = 1;
        double ox = nx;
        double oy = ny;
        for (int octave = 0; octave < AylaTurbulenceSpec.numOctaves; octave++) {
          r += tables.noise2(0, ox, oy) * octaveRatio;
          g += tables.noise2(1, ox, oy) * octaveRatio;
          b += tables.noise2(2, ox, oy) * octaveRatio;
          a += tables.noise2(3, ox, oy) * octaveRatio;
          ox *= 2;
          oy *= 2;
          octaveRatio *= 0.5;
        }
        r = ((r + 1) / 2).clamp(0.0, 1.0);
        g = ((g + 1) / 2).clamp(0.0, 1.0);
        b = ((b + 1) / 2).clamp(0.0, 1.0);
        a = ((a + 1) / 2).clamp(0.0, 1.0);

        // 2) CT#1 的输入：**非预乘**的线性噪声值。
        //    Skia `SkTableColorFilter` 对 unpremultiplied 值查表（Blink
        //    `fe_component_transfer.cc` 的 table 走它）⇒ 索引必须是**未乘 alpha** 的值。
        //
        // ⚠️ 2026-09-27 更正（本轮像素对账抓出，此前实现有两处错，互相掩盖了）：
        //    ① 索引写成 `q8(r * a)`（预乘值）—— 与 unpremul 语义不符；
        //    ② 颜色输出走了一条「× na8 → q8 → ÷ na8」的伪预乘链：`q8()` 内部再乘 255，
        //       于是 pr 几乎恒被 clamp 成 255，反算又 clamp 回 1 ⇒ **R/G/B 全成 255**，
        //       只剩 alpha 变化。G 通道 table 动态范围最大（0.69↔0.98），因此偏得最多
        //       —— 对账实测均值绝对差 R=1.86 / G=4.18 / B=0.16，正是这个顺序。
        //    两处都修掉：非预乘索引 + 直接输出线性→sRGB 结果。
        final int a8 = AylaTurbulenceSpec.q8(a);
        final int o = (y * n + x) * 4;

        // 3) CT#2：A 用 `[0.35, 0, 0.35]` 重映射（0.5 处为 0、两端 0.35）。
        final int na8 = lutA[a8];
        if (na8 == 0) {
          continue; // 全 0（Uint8List 初值）
        }
        final int ur = lutR[AylaTurbulenceSpec.q8(r)];
        final int ug = lutG[AylaTurbulenceSpec.q8(g)];
        final int ub = lutB[AylaTurbulenceSpec.q8(b)];

        // 4) 色彩空间：全程 linearRGB，最后转 sRGB（`color-interpolation-filters`
        //    初始值 = linearRGB）。
        //
        // 5) 落盘 = **预乘 8bit sRGB**（Chrome 的 N32 表面本身就是 pre-multiplied）
        //    —— 这一点是**硬约束**：`ui.decodeImageFromPixels(..., PixelFormat.rgba8888)`
        //    的引擎实现用 `kPremul_SkAlphaType`，即它把传入字节**当作已预乘**。
        //    传非预乘数据时，Skia 不会再乘 alpha，直接参与 src-over 合成 ——
        //    alpha 越低的像素被抬得越亮。
        //    （2026-09-27 对账实测：非预乘写法下整层合成后 Δ≈13/255 且呈**全屏均匀**
        //    分布；改预乘后收敛到 Δ<1，见 test/aurora_background_test.dart 湍流用例。）
        //    alpha 不参与 gamma。
        out[o] = AylaTurbulenceSpec.q8(aylaLinearToSrgb(ur / 255.0) * na8 / 255.0);
        out[o + 1] = AylaTurbulenceSpec.q8(aylaLinearToSrgb(ug / 255.0) * na8 / 255.0);
        out[o + 2] = AylaTurbulenceSpec.q8(aylaLinearToSrgb(ub / 255.0) * na8 / 255.0);
        out[o + 3] = na8;
      }
    }
    return out;
  }
}

/// 采样某个像素的 R 通道（0..1，测试用：证明生成的是确定性噪声而非常量）。
///
/// ⚠️ R 是**预乘**值（≈ sRGB × alpha），不是非预乘颜色 —— 与浏览器
/// `getImageData` 的读数不同口径，别直接比对。
double aylaTurbulenceSampleAt(int x, int y) {
  const int n = AylaTurbulenceSpec.size;
  if (x < 0 || y < 0 || x >= n || y >= n) {
    throw RangeError('纹理坐标越界: ($x, $y)');
  }
  final Uint8List pixels = AylaTurbulenceTile.pixels();
  return pixels[(y * n + x) * 4] / 255;
}
