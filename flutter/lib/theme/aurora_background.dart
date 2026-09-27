/// 全局流体极光背景 —— `base.css` 50–314「流体极光背景」区块的一比一复刻。
///
/// ## 事实源归属（2026-09-25 全仓 grep 复核）
/// 背景的**层 / 关键帧 / reduced-motion 分支**全部在 **`base.css`**（token 定义在
/// `tokens.css` 28–63）；**`auroraqua.css` 不含任何背景层** —— 它只有交互材质与入场
/// 关键帧。页面级「aurora 变体」也不存在：全仓 `--bg-aurora` 只有两处消费点 ——
/// `html` 静态兜底（base.css:25）与 `html::before` 流层（base.css:68）。
///
/// ## 五层结构（z 从低到高，base.css 50–128；`#root` 内容 z-index:1 在最上，44–48）
/// ① `html` 静态兜底：`--bg-aurora` 九层 radial（tokens.css 28–36），铺满视口
/// ② `html::before` 渐变流层：150vmax 正方形居中 + 96px 网格 + 九层 radial，
///    `filter: blur(40px)`，`fluid-gradient-spin` 20s ease-in-out -8s infinite（57–80）
/// ③ `html::after` 湍流层：`inset: -25%` + feTurbulence 纹理 480px 平铺，
///    `opacity: .08`（tokens.css:63）+ `blur(60px)`，`fluid-turbulence-drift`
///    15s ease-in-out -5s infinite alternate（82–95）
/// ④⑤ `body::before/::after` 双色光斑：40vw 圆 + `blur(40px)` + radial 70% 截止，
///    `fluid-blob-drift-a/b` 10s ease-in-out infinite alternate（99–128）
///
/// 窄屏档（`@media (max-width: 768px)`，211–246）：光斑改上下分区（冰蓝 80vw /
/// 樱粉 70vw、alpha .7、`-m` 关键帧），渐变层换 `fluid-gradient-spin-m` 且时长 ×1.4
/// （28s）、湍流 ×1.4（21s）。`prefers-reduced-motion: reduce`（305–314）：四层
/// `display:none` ⇒ 只剩 ① 静态九层（**网格属于 ② 层，降级时一并消失**）。
///
/// ## ⚠️ 性能口径（两层硬约束，别退回）
/// **1. 滤镜结果一次性烘焙成纹理。** web 的 `filter: blur()` 由浏览器合成器缓存成
/// 纹理，每帧只做纹理变换；Flutter 的 `ImageFiltered` 是 layer 属性 —— **每帧合成都
/// 重新执行模糊**。2026-09-25 用户实测首版（四层各自 `ImageFiltered`、150vmax 层
/// 1:1）：「太卡了完全没法正常看，debug 模式也是直接闪退」+ 爆显存黑屏 ——
/// 渐变层一张 3600×3600（51.8 MB）+ 湍流层 3600×2025（29.2 MB），五层峰值 200 MB+
/// 且逐帧重算，触发 D3D 设备丢失。现在每层都走 [AylaAuroraBakedLayer]：
/// 录制 Picture → `saveLayer(imageFilter:)` 施加模糊 → `Picture.toImage()` 烘焙，
/// 之后每帧只 `drawImage` + 变换。
/// **2. 低频层按预算降采样**（[AylaFluidAurora.bakePixelBudget]）。blur 之后的内容
/// 没有高频细节，0.5× 分辨率肉眼无差，显存按面积下降；三端（Windows/Android/iOS）
/// 都吃这条。像素总量由测试锁定，防止回归。
///
/// ## 尺寸口径
/// - `vw / vmax` 按**组件盒子尺寸**换算（真实运行时盒子 = 视口 ⇒ 与 web 1:1）；
///   宽 / 窄档与 web 媒体查询同源，读 `MediaQuery` 宽度。
/// - `filter: blur(Npx)` 的参数是高斯标准差（CSS 与 `ImageFilter.blur` 同语义）⇒ 照抄。
/// - 数值一律照抄 web CSS px：项目口径是「Flutter 逻辑像素 ↔ 浏览器 CSS px 在
///   Windows 125% 缩放下等价」（库内 `AylaGlass.blurCard = 24` 即此口径）。
///
/// ## 公开面
/// `AylaAuroraBackground` · `AylaAuroraKeys` · `AylaFluidAurora` · `AylaFluidFrame`
/// · `AylaFluidPose` · `aylaFluidPoseAt` · `aylaFarthestCornerRadius`
/// · `aylaAuroraBackgroundSamples`

library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'aurora_baked_layer.dart';
import 'aurora_turbulence.dart';
import 'tokens.dart';

/// 图层 key（画布 / 测试定位用；不影响渲染）。
///
/// ⚠️ 必须用 [ObjectKey] 而**不是** «ValueKey&lt;String&gt;»：库内既有测试里有宽谓词
/// «w.key is ValueKey&lt;String&gt;»（如 «danmaku_overlay_test» 用它数弹幕条数）——
/// 背景只要挂一个 «ValueKey&lt;String&gt;» 就会让那些计数整体 +1（2026-09-25 实测：
/// 7 个弹幕用例集体失败）。新组件也别在全局层用 «ValueKey&lt;String&gt;»。
abstract final class AylaAuroraKeys {
  static const Key staticLayer = ObjectKey('aurora-static');
  static const Key gradient = ObjectKey('aurora-gradient');
  static const Key turbulence = ObjectKey('aurora-turbulence');
  static const Key blobIce = ObjectKey('aurora-blob-ice');
  static const Key blobSakura = ObjectKey('aurora-blob-sakura');
  static const List<Key> flowLayers = <Key>[gradient, turbulence, blobIce, blobSakura];
}

/// CSS `radial-gradient(circle …)` 的默认 ending shape 是 **farthest-corner**
/// （半径 = 圆心到最远角的距离）；Flutter 的 `RadialGradient.radius` 以**短边**为
/// 基准（`painting/gradient.dart:757` 的 `radius * rect.shortestSide`）
/// ⇒ 必须按盒子尺寸动态换算，不能写死。
double aylaFarthestCornerRadius(Size size, Alignment center) {
  if (size.isEmpty) return 1;
  final double cx = (center.x + 1) / 2 * size.width;
  final double cy = (center.y + 1) / 2 * size.height;
  final double dx = math.max(cx, size.width - cx);
  final double dy = math.max(cy, size.height - cy);
  return math.sqrt(dx * dx + dy * dy) / size.shortestSide;
}

/// 一层 `--bg-aurora` radial 的规格（tokens.css 28–36 逐层对应）。
class AylaAuroraRadialSpec {
  const AylaAuroraRadialSpec(this.alignment, this.colors, this.stops);

  final Alignment alignment;
  final List<Color> colors;
  final List<double> stops;
}

/// CSS `@keyframes` 的一帧：`at` 为进度，其余为 `transform` 分量。
///
/// `dx/dy` 是相对**元素自身尺寸**的比例（CSS `translate(20%, -15%)` 的百分比基准
/// 就是元素 border-box），用时乘元素宽高。
class AylaFluidFrame {
  const AylaFluidFrame(
    this.at, {
    this.rotateDeg = 0,
    this.dx = 0,
    this.dy = 0,
    this.scale = 1,
  });

  final double at;
  final double rotateDeg;
  final double dx;
  final double dy;
  final double scale;
}

/// 采样结果（同 [AylaFluidFrame] 的分量语义）。
class AylaFluidPose {
  const AylaFluidPose({
    required this.rotateDeg,
    required this.dx,
    required this.dy,
    required this.scale,
  });

  final double rotateDeg;
  final double dx;
  final double dy;
  final double scale;
}

/// 采样 CSS 关键帧：`animation-timing-function` **对每个关键帧区间逐段生效**
/// （不是对整条动画），各层用的 `ease-in-out` = `cubic-bezier(.42,0,.58,1)`
/// = [AylaCurves.auroraquaEaseInOut]（tokens.css:139 同值）。
AylaFluidPose aylaFluidPoseAt(List<AylaFluidFrame> frames, double t) {
  assert(frames.length >= 2, '关键帧至少两帧');
  final double clamped = t.clamp(0.0, 1.0);
  if (clamped <= frames.first.at) return _poseOf(frames.first);
  for (int i = 1; i < frames.length; i++) {
    final AylaFluidFrame b = frames[i];
    if (clamped <= b.at) {
      final AylaFluidFrame a = frames[i - 1];
      final double span = b.at - a.at;
      final double raw = span <= 0 ? 1 : (clamped - a.at) / span;
      final double k = AylaCurves.auroraquaEaseInOut.transform(raw);
      return AylaFluidPose(
        rotateDeg: ui.lerpDouble(a.rotateDeg, b.rotateDeg, k)!,
        dx: ui.lerpDouble(a.dx, b.dx, k)!,
        dy: ui.lerpDouble(a.dy, b.dy, k)!,
        scale: ui.lerpDouble(a.scale, b.scale, k)!,
      );
    }
  }
  return _poseOf(frames.last);
}

AylaFluidPose _poseOf(AylaFluidFrame f) => AylaFluidPose(
  rotateDeg: f.rotateDeg,
  dx: f.dx,
  dy: f.dy,
  scale: f.scale,
);

/// 流体极光背景的全部参数（每个数值都能指到 web 的 `文件:行`）。
abstract final class AylaFluidAurora {
  /// 宽 / 窄档分界：`@media (max-width: 768px)`（base.css:211）。
  static const double narrowBreakpoint = 768;

  // ------------------------------------------------------------------
  // 烘焙预算（性能硬约束；见库注释「性能口径」）
  // ------------------------------------------------------------------

  /// 每层烘焙纹理的**最长边像素上限**：低频内容降采样，显存按面积下降。
  static const double bakeStaticMaxSide = 1440;
  static const double bakeGradientMaxSide = 1440;
  static const double bakeTurbulenceMaxSide = 1024;
  static const double bakeBlobMaxSide = 512;

  /// 流层渲染帧间隔：**默认满帧**（[kAuroraFrameInterval] = [Duration.zero]）。
  /// 只作低端设备/省电预留档；见 [AylaAuroraClock]。
  static const Duration frameInterval = kAuroraFrameInterval;

  /// 模糊扩散预留（= 3 × blur σ）：CSS 的 filter 有 filter region（模糊可超出元素盒），
  /// 而 saveLayer 会把扩散裁在 bounds 内 ⇒ 不预留就露出**硬直边**（用户实报
  /// 「背景总是出现裁切边旋转露出来」）。层尺寸 +2×overscan、位置 -overscan，中心不变。
  static const double gradientOverscan = gradientBlur * 3;
  static const double turbulenceOverscan = turbulenceBlur * 3;

  /// 五层烘焙像素总量上限（RGBA 4 字节/像素 ⇒ 6M ≈ 24 MB）。
  /// 由定向测试锁定 —— 谁把层改回 1:1 大纹理，测试就红。
  static const int bakePixelBudget = 6 * 1000 * 1000;

  // ------------------------------------------------------------------
  // ① 静态兜底：`html { background: var(--bg-aurora) fixed }`（base.css:25）
  // ------------------------------------------------------------------

  /// `--bg-aurora` 九层（tokens.css 28–36）。层序 = CSS background 列表序，
  /// **后写的在下** ⇒ 逐层绘制时按此顺序即可得到同一叠加结果。
  static const List<AylaAuroraRadialSpec> staticLayers = <AylaAuroraRadialSpec>[
    // 1–4 四角四色螺旋（tokens.css 28–31，各 50% 半径弥散）
    AylaAuroraRadialSpec(
      Alignment(-1, -1),
      <Color>[AylaColors.ice300, Color(0x00BDD4E9)],
      <double>[0, 0.5],
    ),
    AylaAuroraRadialSpec(
      Alignment(1, -1),
      <Color>[AylaColors.ice500, Color(0x009DBFE6)],
      <double>[0, 0.5],
    ),
    AylaAuroraRadialSpec(
      Alignment(1, 1),
      <Color>[Color(0xA6F17EB3), Color(0x00F17EB3)],
      <double>[0, 0.5],
    ),
    AylaAuroraRadialSpec(
      Alignment(-1, 1),
      <Color>[AylaColors.sakura100, Color(0x00FCD8FF)],
      <double>[0, 0.5],
    ),
    // 5–8 四边中点白色光斑隔离蓝粉（tokens.css 32–35，45%）
    AylaAuroraRadialSpec(
      Alignment(0, -1),
      <Color>[AylaColors.surface, Color(0x00FFFAFB)],
      <double>[0, 0.45],
    ),
    AylaAuroraRadialSpec(
      Alignment(1, 0),
      <Color>[AylaColors.surface, Color(0x00FFFAFB)],
      <double>[0, 0.45],
    ),
    AylaAuroraRadialSpec(
      Alignment(0, 1),
      <Color>[AylaColors.surface, Color(0x00FFFAFB)],
      <double>[0, 0.45],
    ),
    AylaAuroraRadialSpec(
      Alignment(-1, 0),
      <Color>[AylaColors.surface, Color(0x00FFFAFB)],
      <double>[0, 0.45],
    ),
    // 9 中心暖白光晕（tokens.css 36：`#fffafb 0%, .5 33%, .15 52%, 0 63%`）
    AylaAuroraRadialSpec(
      Alignment(0, 0),
      <Color>[
        Color(0xFFFFFAFB), // 0%  rgba(255,250,251,1)
        Color(0x80FFFAFB), // 33% .5
        Color(0x26FFFAFB), // 52% .15
        Color(0x00FFFAFB), // 63% 0
      ],
      <double>[0, 0.33, 0.52, 0.63],
    ),
  ];

  /// 兜底底色 = **白**。
  ///
  /// 依据（base.css 29–48 逐条）：`html { background: var(--bg-aurora) fixed }`、
  /// `body { background: transparent }`、`#root { background: transparent }`
  /// —— 九层 radial 之下**没有任何实底**，最终落在浏览器的**默认白底**上。
  ///
  /// ⚠️ 2026-09-27 纠正：本常量一度被我写成 `--ice-100`（#ECF0F2 冷灰）——那是**没有代码
  /// 依据的推断**（「九层之上仍可透出的色」），后果是整片背景偏灰偏暗、比 web 闷。
  /// 像素对账暴露了它：不铺底时右下角 (191,117,152) 与 web 实测 (233,174,209) 对不上，
  /// **铺白底后一致**。教训：兜底色要**回读 CSS 里有没有实底**，没有就是浏览器默认白。
  static const Color backdrop = Color(0xFFFFFFFF);

  /// 九层的**绘制顺序**：CSS background 列表第一项在最上 ⇒ canvas 里要**倒序**画
  /// （先画列表最后一项 = 最底层）。见 [aylaPaintAuroraRadials]。
  static List<AylaAuroraRadialSpec> get paintOrder =>
      staticLayers.reversed.toList(growable: false);

  // ------------------------------------------------------------------
  // ② 渐变流层（base.css 57–80）
  // ------------------------------------------------------------------

  /// `width/height: 150vmax`（base.css:62–63）。
  static const double gradientVmax = 150;

  /// `filter: blur(40px)`（base.css:72）。
  static const double gradientBlur = 40;

  /// `animation: fluid-gradient-spin calc(var(--fluid-gradient-speed) * 2) …`，
  /// `--fluid-gradient-speed: 10s`（tokens.css:47）⇒ 单圈 20s（base.css:78）。
  static const Duration gradientPeriod = Duration(seconds: 20);

  /// 负延迟 `-8s`（base.css:78）⇒ 起始相位 = 8 / 20。
  static const double gradientPhase = 8 / 20;

  /// `@keyframes fluid-gradient-spin`（base.css 170–186）。
  static const List<AylaFluidFrame> gradientFrames = <AylaFluidFrame>[
    AylaFluidFrame(0, rotateDeg: 0, dx: 0, dy: 0, scale: 1),
    AylaFluidFrame(0.25, rotateDeg: 115, dx: 0.04, dy: -0.03, scale: 1.22),
    AylaFluidFrame(0.5, rotateDeg: 220, dx: -0.04, dy: 0.03, scale: 0.78),
    AylaFluidFrame(0.75, rotateDeg: 315, dx: 0.03, dy: 0.03, scale: 1.12),
    AylaFluidFrame(1, rotateDeg: 360, dx: 0, dy: 0, scale: 1),
  ];

  /// 窄屏：`animation-name: fluid-gradient-spin-m` +
  /// `animation-duration: calc(10s * 2 * 1.4)` = 28s（base.css 239–242）。
  static const Duration gradientPeriodNarrow = Duration(seconds: 28);

  /// 窄屏负延迟仍是 `-8s`（只覆写了 name/duration）⇒ 相位 = 8 / 28。
  static const double gradientPhaseNarrow = 8 / 28;

  /// `@keyframes fluid-gradient-spin-m`（base.css 287–303）。
  static const List<AylaFluidFrame> gradientFramesNarrow = <AylaFluidFrame>[
    AylaFluidFrame(0, rotateDeg: 0, scale: 1),
    AylaFluidFrame(0.2, rotateDeg: 80, scale: 1.08),
    AylaFluidFrame(0.45, rotateDeg: 180, scale: 0.94),
    AylaFluidFrame(0.7, rotateDeg: 270, scale: 1.05),
    AylaFluidFrame(1, rotateDeg: 360, scale: 1),
  ];

  // ------------------------------------------------------------------
  // ③ 湍流层（base.css 82–95）
  // ------------------------------------------------------------------

  /// `inset: -25%`（base.css:85）⇒ 层尺寸 = 视口 ×1.5，位置 -25%。
  static const double turbulenceInset = 0.25;

  /// `background-size: 480px 480px`（base.css:89）+ SVG 画布 480×480（tokens.css:43）。
  static const double turbulenceTile = 480;

  /// `opacity: var(--fluid-turbulence-opacity)` = 0.08（tokens.css:63）。
  static const double turbulenceOpacity = 0.08;

  /// `filter: blur(60px)`（base.css:92）。
  static const double turbulenceBlur = 60;

  /// `animation: fluid-turbulence-drift var(--fluid-turbulence-speed) ease-in-out
  /// -5s infinite alternate`，`--fluid-turbulence-speed: 15s`（tokens.css:62）。
  static const Duration turbulencePeriod = Duration(seconds: 15);

  /// 负延迟 `-5s`（base.css:93）⇒ 起始相位 = 5 / 15。
  static const double turbulencePhase = 5 / 15;

  /// `@keyframes fluid-turbulence-drift`（base.css 189–208）：无 scale，只有
  /// `translate3d`（±8%）与 `rotate`（±18°）。
  static const List<AylaFluidFrame> turbulenceFrames = <AylaFluidFrame>[
    AylaFluidFrame(0, dx: 0, dy: 0, rotateDeg: 0),
    AylaFluidFrame(0.2, dx: 0.08, dy: -0.05, rotateDeg: 16),
    AylaFluidFrame(0.4, dx: -0.06, dy: 0.06, rotateDeg: -13),
    AylaFluidFrame(0.6, dx: 0.05, dy: 0.04, rotateDeg: 10),
    AylaFluidFrame(0.8, dx: -0.08, dy: -0.04, rotateDeg: -18),
    AylaFluidFrame(1, dx: 0.04, dy: -0.03, rotateDeg: 8),
  ];

  /// 窄屏：`animation-duration: calc(15s * 1.4)` = 21s（base.css 243–245）。
  static const Duration turbulencePeriodNarrow = Duration(seconds: 21);

  /// 窄屏负延迟仍是 `-5s` ⇒ 相位 = 5 / 21。
  static const double turbulencePhaseNarrow = 5 / 21;

  // ------------------------------------------------------------------
  // ④⑤ 双色光斑（base.css 99–128 宽屏 / 211–246 窄屏）
  // ------------------------------------------------------------------

  /// `animation: fluid-blob-drift-a/b 10s ease-in-out infinite alternate`
  /// （base.css 117 / 127）；A、B **同周期同相** ⇒ 共用一条时间轴。
  static const Duration blobPeriod = Duration(seconds: 10);

  /// `filter: blur(40px)`（base.css:106）。
  static const double blobBlur = 40;

  /// 宽屏 `width/height: 40vw`（base.css 113 / 122）。
  static const double blobWideDiameter = 0.4;

  /// 宽屏 `rgba(..., 0.65)`（base.css 116 / 126）。
  static const double blobWideAlpha = 0.65;

  /// 窄屏 `width/height: 80vw`（冰蓝，base.css:213）。
  static const double blobNarrowIceDiameter = 0.8;

  /// 窄屏 `width/height: 70vw`（樱粉，base.css:226）。
  static const double blobNarrowSakuraDiameter = 0.7;

  /// 窄屏 `rgba(..., 0.7)`（base.css 218 / 231，「提亮」）。
  static const double blobNarrowAlpha = 0.7;

  /// `@keyframes fluid-blob-drift-a`（base.css 131–147）。
  static const List<AylaFluidFrame> blobIceFrames = <AylaFluidFrame>[
    AylaFluidFrame(0, scale: 1),
    AylaFluidFrame(0.15, scale: 1.35, dx: 0.2, dy: -0.15),
    AylaFluidFrame(0.3, scale: 0.65, dx: -0.1, dy: 0.12),
    AylaFluidFrame(0.5, scale: 0.65, dx: 0.8, dy: 0.12),
    AylaFluidFrame(1, scale: 1.2, dx: 0.8, dy: 0),
  ];

  /// `@keyframes fluid-blob-drift-b`（base.css 150–166）。
  static const List<AylaFluidFrame> blobSakuraFrames = <AylaFluidFrame>[
    AylaFluidFrame(0, scale: 1),
    AylaFluidFrame(0.15, scale: 0.65, dx: -0.2, dy: 0.15),
    AylaFluidFrame(0.3, scale: 1.35, dx: 0.1, dy: -0.12),
    AylaFluidFrame(0.5, scale: 0.65, dx: -0.9, dy: -0.12),
    AylaFluidFrame(1, scale: 1.2, dx: -0.9, dy: 0),
  ];

  /// `@keyframes fluid-blob-drift-a-m`（窄屏，base.css 249–265）。
  static const List<AylaFluidFrame> blobIceFramesNarrow = <AylaFluidFrame>[
    AylaFluidFrame(0, scale: 1),
    AylaFluidFrame(0.15, scale: 1.35, dx: -0.15, dy: 0.12),
    AylaFluidFrame(0.3, scale: 0.65, dx: 0.1, dy: -0.1),
    AylaFluidFrame(0.5, scale: 0.65, dx: 0.15, dy: 0.5),
    AylaFluidFrame(1, scale: 1.2, dx: 0, dy: 0.5),
  ];

  /// `@keyframes fluid-blob-drift-b-m`（窄屏，base.css 268–284）。
  static const List<AylaFluidFrame> blobSakuraFramesNarrow = <AylaFluidFrame>[
    AylaFluidFrame(0, scale: 1),
    AylaFluidFrame(0.15, scale: 0.65, dx: 0.15, dy: -0.12),
    AylaFluidFrame(0.3, scale: 1.35, dx: -0.1, dy: 0.1),
    AylaFluidFrame(0.5, scale: 0.65, dx: -0.15, dy: -0.6),
    AylaFluidFrame(1, scale: 1.2, dx: 0, dy: -0.6),
  ];

  /// 光斑 radial 的 70% 截止（base.css 116 / 126：`… 0%, rgba(…, 0) 70%`）。
  /// 元素是正方形 ⇒ farthest-corner 半径 = 边长 / √2（见 [aylaFarthestCornerRadius]）。
  static const double blobStop = 0.7;
}

/// 一套背景（五层）在给定视口 / DPR 下的**烘焙像素总量** —— 性能预算的可测口径。
///
/// 与 [AylaAuroraBakedLayer] 的换算同式（逻辑尺寸 × min(DPR, cap / 最长边)），
/// 供测试锁定「别把低频层改回 1:1 大纹理」；宽屏档取「宽屏光斑」尺寸
/// （窄屏 80vw/70vw 的层更小，不会更差）。
int aylaAuroraBakePixels(Size viewport, double dpr) {
  int pixelsOf(Size logical, double cap, [double overscan = 0]) {
    final Size outer = Size(
      logical.width + overscan * 2,
      logical.height + overscan * 2,
    );
    final double longest = math.max(outer.width, outer.height);
    final double ratio = math.min(dpr, cap / longest);
    final int w = math.max(1, (outer.width * ratio).round());
    final int h = math.max(1, (outer.height * ratio).round());
    return w * h;
  }

  final double maxSide = math.max(viewport.width, viewport.height);
  final double gradientSide = AylaFluidAurora.gradientVmax / 100 * maxSide;
  final double blobSide = AylaFluidAurora.blobWideDiameter * viewport.width;
  return pixelsOf(viewport, AylaFluidAurora.bakeStaticMaxSide) +
      pixelsOf(
        Size(gradientSide, gradientSide),
        AylaFluidAurora.bakeGradientMaxSide,
        AylaFluidAurora.gradientOverscan,
      ) +
      pixelsOf(
        Size(
          viewport.width * (1 + AylaFluidAurora.turbulenceInset * 2),
          viewport.height * (1 + AylaFluidAurora.turbulenceInset * 2),
        ),
        AylaFluidAurora.bakeTurbulenceMaxSide,
        AylaFluidAurora.turbulenceOverscan,
      ) +
      pixelsOf(Size(blobSide, blobSide), AylaFluidAurora.bakeBlobMaxSide) * 2;
}

// ======================= 绘制原语（供烘焙管线调用） =======================

/// 九层 `--bg-aurora` radial（tokens.css 28–36，半径按 farthest-corner 动态算）。
///
/// ⚠️ **必须按 [AylaFluidAurora.paintOrder] 倒序绘制**：CSS 的 background 列表
/// **第一项在最上层**，而 canvas 是「后画的盖住先画的」—— 正序画会把第 9 层（中心暖白
/// 光晕）与 5–8 层（四边隔离白光斑）压到四角四色之上，整片发白
/// （2026-09-25 用户截图实报：「你是不是给光斑层加了一层全白遮罩」）。
void aylaPaintAuroraRadials(Canvas canvas, Size size) {
  for (final AylaAuroraRadialSpec spec in AylaFluidAurora.paintOrder) {
    final Offset center = Offset(
      (spec.alignment.x + 1) / 2 * size.width,
      (spec.alignment.y + 1) / 2 * size.height,
    );
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.radial(
          center,
          aylaFarthestCornerRadius(size, spec.alignment) * size.shortestSide,
          spec.colors,
          spec.stops,
        ),
    );
  }
}

/// 极淡 96px 周期网格（`--bg-aurora-grid`，tokens.css 39–40）。
void aylaPaintAuroraGrid(Canvas canvas, Size size) {
  // `--bg-aurora-grid` 是两层 repeating-linear-gradient：
  //   repeating-linear-gradient(0deg,                  // 横线
  //     rgba(157,191,230,.015) 0 1px,                  //  0–1px  全亮
  //     rgba(157,191,230,.008) 3px,                    //  1→3px 渐隐到半亮
  //     transparent 4px 96px)                          //  4–96px 透明（周期 96）
  //   … 另一层为 90deg 竖线，参数相同。
  // **不是 1px 实线**：0→1px 全亮、1→3px 线性衰减到 .008、3→4px 再衰减到 0，
  // 4px 之后到底透明（每 96px 重复）。1px 实线会让网格偏硬、出现摩尔纹。
  const double period = 96;
  const double fadeEnd = 3; // 半亮位置（1→3px 线性衰减到 .008）
  const double zeroEnd = 4; // 完全透明位置（3→4px 衰减到 0）

  // stop 比例：0 → .015；1/4 → .008；3/4 → 0（4px 内完成整段渐隐）
  const List<double> stops = <double>[0, 1 / zeroEnd, fadeEnd / zeroEnd];
  final List<Color> ramp = <Color>[
    AylaColors.ice500.withValues(alpha: 0.015),
    AylaColors.ice500.withValues(alpha: 0.008),
    AylaColors.ice500.withValues(alpha: 0.0),
  ];

  for (double y = 0; y <= size.height; y += period) {
    // 横线（0deg）：从 y 向下 4px 渐隐
    canvas.drawRect(
      Rect.fromLTWH(0, y, size.width, zeroEnd),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, y),
          Offset(0, y + zeroEnd),
          ramp,
          stops,
        ),
    );
  }
  for (double x = 0; x <= size.width; x += period) {
    // 竖线（90deg）：从 x 向右 4px 渐隐
    canvas.drawRect(
      Rect.fromLTWH(x, 0, zeroEnd, size.height),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(x, 0),
          Offset(x + zeroEnd, 0),
          ramp,
          stops,
        ),
    );
  }
}

/// 渐变流层内容 = 九层 radial + 网格（CSS 里网格写在 background 列表**前面** ⇒
/// 画在 radial 之上，base.css:68）。
void aylaPaintGradientContent(Canvas canvas, Size size) {
  aylaPaintAuroraRadials(canvas, size);
  aylaPaintAuroraGrid(canvas, size);
}

/// 单色光斑（`border-radius: 50%` 的圆 + radial 70% 截止；圆外颜色已归零 ⇒
/// 不需要额外的圆裁剪）。
void aylaPaintBlob(Canvas canvas, Size size, Color color, double alpha) {
  canvas.drawRect(
    Offset.zero & size,
    Paint()
      ..shader = ui.Gradient.radial(
        Offset(size.width / 2, size.height / 2),
        size.shortestSide / math.sqrt2,
        <Color>[color.withValues(alpha: alpha), color.withValues(alpha: 0)],
        const <double>[0, AylaFluidAurora.blobStop],
      ),
  );
}

/// 平铺 feTurbulence 纹理（480×480 tile，从层左上角开始；web 的 `stitchTiles`
/// 默认 noStitch ⇒ 接缝同样存在，被 `blur(60px)` 掩盖）。
void aylaPaintTurbulence(Canvas canvas, Size size, ui.Image tile) {
  canvas.drawRect(
    Offset.zero & size,
    Paint()
      ..shader = ImageShader(
        tile,
        TileMode.repeated,
        TileMode.repeated,
        Matrix4.identity().storage,
      ),
  );
}

// ======================= 五层 =======================

/// ① `html` 静态兜底（base.css:25）：九层 radial 铺满视口、无滤镜、无动画。
class _StaticAuroraLayer extends StatelessWidget {
  const _StaticAuroraLayer({super.key, required this.viewport});

  final Size viewport;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      top: 0,
      width: viewport.width,
      height: viewport.height,
      child: IgnorePointer(
        child: AylaAuroraBakedLayer(
          size: viewport,
          bakeMaxSide: AylaFluidAurora.bakeStaticMaxSide,
          draw: aylaPaintAuroraRadials,
        ),
      ),
    );
  }
}

/// ② `html::before`（base.css 57–80）：150vmax 正方形居中 + 旋转 / 漂移 / 缩放。
class _FluidGradientLayer extends StatelessWidget {
  const _FluidGradientLayer({
    super.key,
    required this.viewport,
    required this.controller,
    required this.narrow,
  });

  final Size viewport;
  final AylaAuroraClock controller;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final double side =
        AylaFluidAurora.gradientVmax / 100 * math.max(viewport.width, viewport.height);
    final List<AylaFluidFrame> frames = narrow
        ? AylaFluidAurora.gradientFramesNarrow
        : AylaFluidAurora.gradientFrames;
    // 模糊扩散预留（见 [AylaFluidAurora.gradientOverscan]）：层尺寸 +2×overscan、
    // 位置 -overscan，**中心不变** ⇒ 旋转/缩放的基准点不受影响。
    final double overscan = AylaFluidAurora.gradientOverscan;
    return Positioned(
      // `left/top: 50%` + 负 margin 半尺寸（base.css 61–65）⇒ 层中心恒等于视口中心。
      left: (viewport.width - side) / 2 - overscan,
      top: (viewport.height - side) / 2 - overscan,
      width: side + overscan * 2,
      height: side + overscan * 2,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: controller,
          // child 传进去：每帧只重建 Transform，烘焙层不参与重建。
          child: AylaAuroraBakedLayer(
            size: Size(side, side),
            blurSigma: AylaFluidAurora.gradientBlur,
            blurOverscan: overscan,
            bakeMaxSide: AylaFluidAurora.bakeGradientMaxSide,
            draw: aylaPaintGradientContent,
          ),
          builder: (BuildContext context, Widget? child) {
            final AylaFluidPose pose = aylaFluidPoseAt(frames, controller.value);
            // CSS `transform: rotate(θ) translate3d(dx,dy,0) scale(s)`：矩阵左乘序
            // ⇒ Flutter 用右乘链 `R · T · S` 表达同一结果，原点 = 元素中心。
            return Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..rotateZ(pose.rotateDeg * math.pi / 180)
                ..translateByDouble(pose.dx * side, pose.dy * side, 0, 1)
                ..scaleByDouble(pose.scale, pose.scale, 1, 1),
              child: child,
            );
          },
        ),
      ),
    );
  }
}

/// ③ `html::after`（base.css 82–95）：feTurbulence 纹理平铺 + `blur(60px)` + `.08`。
class _TurbulenceLayer extends StatefulWidget {
  const _TurbulenceLayer({
    super.key,
    required this.viewport,
    required this.controller,
    required this.narrow,
  });

  final Size viewport;
  final AylaAuroraClock controller;
  final bool narrow;

  @override
  State<_TurbulenceLayer> createState() => _TurbulenceLayerState();
}

class _TurbulenceLayerState extends State<_TurbulenceLayer> {
  ui.Image? _tile;

  @override
  void initState() {
    super.initState();
    // 纹理生成不阻塞 UI（算法在 isolate 里跑，见 aurora_turbulence.dart）；
    // 就绪前层壳先建出来（测试与布局都依赖它存在），web 侧同样是栅格化后才可见。
    AylaTurbulenceTile.image().then((ui.Image image) {
      if (mounted) setState(() => _tile = image);
    });
  }

  @override
  Widget build(BuildContext context) {
    final double dx = AylaFluidAurora.turbulenceInset * widget.viewport.width;
    final double dy = AylaFluidAurora.turbulenceInset * widget.viewport.height;
    final double width = widget.viewport.width + dx * 2;
    final double height = widget.viewport.height + dy * 2;
    final ui.Image? tile = _tile;
    // 同渐变层：预留模糊扩散，否则湍流层的直边会露在视口里。
    final double overscan = AylaFluidAurora.turbulenceOverscan;
    return Positioned(
      // `inset: -25%`（base.css:85）—— 百分比基准是包含块（视口）。
      left: -dx - overscan,
      top: -dy - overscan,
      width: width + overscan * 2,
      height: height + overscan * 2,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: widget.controller,
          child: AylaAuroraBakedLayer(
            size: Size(width, height),
            blurSigma: AylaFluidAurora.turbulenceBlur,
            blurOverscan: overscan,
            opacity: AylaFluidAurora.turbulenceOpacity,
            bakeMaxSide: AylaFluidAurora.bakeTurbulenceMaxSide,
            revision: tile,
            draw: (Canvas canvas, Size size) {
              if (tile != null) aylaPaintTurbulence(canvas, size, tile);
            },
          ),
          builder: (BuildContext context, Widget? child) {
            final AylaFluidPose pose =
                aylaFluidPoseAt(AylaFluidAurora.turbulenceFrames, widget.controller.value);
            // CSS `transform: translate3d(dx,dy,0) rotate(θ)` ⇒ `T · R`
            // （位移不受旋转影响）；位移百分比基准 = 层自身尺寸。
            return Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..translateByDouble(pose.dx * width, pose.dy * height, 0, 1)
                ..rotateZ(pose.rotateDeg * math.pi / 180),
              child: child,
            );
          },
        ),
      ),
    );
  }
}

/// ④⑤ `body::before` / `body::after`（base.css 99–128 宽屏 / 211–246 窄屏）。
class _BlobLayer extends StatelessWidget {
  const _BlobLayer({
    super.key,
    required this.viewport,
    required this.controller,
    required this.narrow,
    required this.ice,
  });

  final Size viewport;
  final AylaAuroraClock controller;
  final bool narrow;

  /// 冰蓝（`body::before`）/ 亮粉（`body::after`）。
  final bool ice;

  @override
  Widget build(BuildContext context) {
    final double ratio = narrow
        ? (ice
              ? AylaFluidAurora.blobNarrowIceDiameter
              : AylaFluidAurora.blobNarrowSakuraDiameter)
        : AylaFluidAurora.blobWideDiameter;
    final double diameter = ratio * viewport.width;
    final double alpha = narrow
        ? AylaFluidAurora.blobNarrowAlpha
        : AylaFluidAurora.blobWideAlpha;
    final List<AylaFluidFrame> frames = narrow
        ? (ice
              ? AylaFluidAurora.blobIceFramesNarrow
              : AylaFluidAurora.blobSakuraFramesNarrow)
        : (ice
              ? AylaFluidAurora.blobIceFrames
              : AylaFluidAurora.blobSakuraFrames);

    // 定位（百分比基准 = 包含块）：
    //  · 宽屏 A `top: -10%; left: 25%`（113–117）/ B `bottom: -10%; right: 25%`（122–127）
    //  · 窄屏 A `top: 25%; left: 50%` + `margin-left: -40vw`（213–219），
    //    B `bottom: 25%; right: 50%` + `margin-right: -35vw`（226–232）
    //    —— 两者都等于「水平居中」（margin 恰好是自身半宽）⇒ 同一个公式。
    final double left = narrow
        ? viewport.width * 0.5 - diameter / 2
        : (ice ? viewport.width * 0.25 : viewport.width * 0.75 - diameter);
    final double top = narrow
        ? (ice ? viewport.height * 0.25 : viewport.height * 0.75 - diameter)
        : (ice ? -viewport.height * 0.1 : viewport.height * 1.1 - diameter);

    final Color color = ice ? AylaColors.ice500 : AylaColors.sakura300;
    return Positioned(
      left: left,
      top: top,
      width: diameter,
      height: diameter,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: controller,
          child: AylaAuroraBakedLayer(
            size: Size(diameter, diameter),
            blurSigma: AylaFluidAurora.blobBlur,
            bakeMaxSide: AylaFluidAurora.bakeBlobMaxSide,
            draw: (Canvas canvas, Size size) => aylaPaintBlob(canvas, size, color, alpha),
          ),
          builder: (BuildContext context, Widget? child) {
            final AylaFluidPose pose = aylaFluidPoseAt(frames, controller.value);
            // CSS `transform: scale(s) translate(dx,dy)` ⇒ `S · T`：位移会被缩放放大
            // （与渐变层的 `R·T·S` 不同，逐层照抄，别统一）。
            return Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..scaleByDouble(pose.scale, pose.scale, 1, 1)
                ..translateByDouble(
                  pose.dx * diameter,
                  pose.dy * diameter,
                  0,
                  1,
                ),
              child: child,
            );
          },
        ),
      ),
    );
  }
}

/// 全局流体极光背景（五层同构；铺满宿主盒子，内容置于最上）。
///
/// 用法：作为页面根 `Scaffold` 的底层 / `Overlay` 的全屏底。
class AylaAuroraBackground extends StatefulWidget {
  const AylaAuroraBackground({super.key, this.child, this.animate = true});

  const AylaAuroraBackground.fill({super.key})
    : child = null,
      animate = true;

  /// 可选内容（置于背景之上，z 最高）。
  final Widget? child;

  /// 流层动画开关（渐变 / 湍流 / 双光斑四层）。
  ///
  /// 默认 `true` = 真实运行（`main.dart` 的全局底与画布宿主）。
  /// [previewTheme]（widget test 宿主）传 `false`：**无限循环动画会让
  /// `pumpAndSettle()` 永不 settle**（框架语义，不是视觉偏离）。
  final bool animate;

  @override
  State<AylaAuroraBackground> createState() => _AylaAuroraBackgroundState();
}

class _AylaAuroraBackgroundState extends State<AylaAuroraBackground>
    with TickerProviderStateMixin {
  late final AnimationController _gradient = AnimationController(
    vsync: this,
    duration: AylaFluidAurora.gradientPeriod,
    value: AylaFluidAurora.gradientPhase,
  );
  late final AnimationController _turbulence = AnimationController(
    vsync: this,
    duration: AylaFluidAurora.turbulencePeriod,
    value: AylaFluidAurora.turbulencePhase,
  );
  late final AnimationController _blob = AnimationController(
    vsync: this,
    duration: AylaFluidAurora.blobPeriod,
  );

  // 三条节流时钟（≈30fps）：层只在这些时钟上重建；控制器本身仍按真实时间轴跑，
  // 时长 / 相位 / 关键帧与 web 完全一致。见 [AylaAuroraClock]。
  late final AylaAuroraClock _gradientClock = AylaAuroraClock(_gradient);
  late final AylaAuroraClock _turbulenceClock = AylaAuroraClock(_turbulence);
  late final AylaAuroraClock _blobClock = AylaAuroraClock(_blob);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery 只能在 didChangeDependencies 之后读（initState 读会断言）。
    _syncControllers(narrow: _narrow);
  }

  @override
  void didUpdateWidget(covariant AylaAuroraBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate != oldWidget.animate) _syncControllers(narrow: _narrow);
  }

  bool get _narrow =>
      MediaQuery.sizeOf(context).width <= AylaFluidAurora.narrowBreakpoint;

  void _syncControllers({required bool narrow}) {
    final bool run = widget.animate && !MediaQuery.disableAnimationsOf(context);
    _apply(
      controller: _gradient,
      run: run,
      period: narrow
          ? AylaFluidAurora.gradientPeriodNarrow
          : AylaFluidAurora.gradientPeriod,
      phase: narrow
          ? AylaFluidAurora.gradientPhaseNarrow
          : AylaFluidAurora.gradientPhase,
      alternate: false,
    );
    _apply(
      controller: _turbulence,
      run: run,
      period: narrow
          ? AylaFluidAurora.turbulencePeriodNarrow
          : AylaFluidAurora.turbulencePeriod,
      phase: narrow
          ? AylaFluidAurora.turbulencePhaseNarrow
          : AylaFluidAurora.turbulencePhase,
      alternate: true,
    );
    // 光斑宽 / 窄档同周期（10s，base.css 117 / 127 与 220 / 233）⇒ 相位恒为 0。
    _apply(
      controller: _blob,
      run: run,
      period: AylaFluidAurora.blobPeriod,
      phase: 0,
      alternate: true,
    );
  }

  /// 启动 / 停止一条 CSS 等价时间轴。
  ///
  /// - CSS 负延迟 ⇒ [phase] 作为 `AnimationController` 初值（`repeat()` 内部是
  ///   `_RepeatingSimulation(_value, …)`，初值即相位，`animation_controller.dart:740`）；
  /// - 渐变是 `infinite`（单向），湍流与光斑是 `alternate`（往返）⇒
  ///   [alternate] 决定 `repeat(reverse:)`。
  void _apply({
    required AnimationController controller,
    required bool run,
    required Duration period,
    required double phase,
    required bool alternate,
  }) {
    if (!run) {
      controller.stop();
      controller.value = phase;
      return;
    }
    if (controller.duration != period) {
      controller.duration = period;
      controller.value = phase;
      controller.repeat(reverse: alternate);
      return;
    }
    if (!controller.isAnimating) {
      controller.value = phase;
      controller.repeat(reverse: alternate);
    }
  }

  @override
  void dispose() {
    _gradientClock.dispose();
    _turbulenceClock.dispose();
    _blobClock.dispose();
    _gradient.dispose();
    _turbulence.dispose();
    _blob.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool narrow = _narrow;
    final bool flow = widget.animate && !MediaQuery.disableAnimationsOf(context);
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Size viewport = Size(
            constraints.hasBoundedWidth
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width,
            constraints.hasBoundedHeight
                ? constraints.maxHeight
                : MediaQuery.sizeOf(context).height,
          );
          return DecoratedBox(
            decoration: const BoxDecoration(color: AylaFluidAurora.backdrop),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                // ① html 静态兜底（base.css:25）—— reduced-motion 下唯一可见层。
                _StaticAuroraLayer(
                  key: AylaAuroraKeys.staticLayer,
                  viewport: viewport,
                ),
                // ②③④⑤ 四层流层（base.css 305–314 在 reduced-motion 下整体隐藏）。
                if (flow) ...<Widget>[
                  _FluidGradientLayer(
                    key: AylaAuroraKeys.gradient,
                    viewport: viewport,
                    controller: _gradientClock,
                    narrow: narrow,
                  ),
                  _TurbulenceLayer(
                    key: AylaAuroraKeys.turbulence,
                    viewport: viewport,
                    controller: _turbulenceClock,
                    narrow: narrow,
                  ),
                  _BlobLayer(
                    key: AylaAuroraKeys.blobIce,
                    viewport: viewport,
                    controller: _blobClock,
                    narrow: narrow,
                    ice: true,
                  ),
                  _BlobLayer(
                    key: AylaAuroraKeys.blobSakura,
                    viewport: viewport,
                    controller: _blobClock,
                    narrow: narrow,
                    ice: false,
                  ),
                ],
                if (widget.child != null) widget.child!,
              ],
            ),
          );
        },
      ),
    );
  }
}

// ======================= 样张 =======================

/// 背景样张（画布「AylaAuroraBackground」节）。
///
/// 三档都是**同一个组件**在不同 MediaQuery 下的真实渲染：
/// - 默认档 = 真实运行形态（四层流层在跑：渐变 20s 单圈、湍流 15s 往返、光斑 10s 往返）；
/// - 静态降级档 = `prefers-reduced-motion: reduce`（base.css 305–314）；
/// - 窄屏档 = `@media (max-width: 768px)` 的光斑上下分区与放慢 1.4×（211–246）。
///
/// ⚠️ 舞台不是视口 ⇒ 覆写 `MediaQuery.size`；`vw / vmax` 仍按舞台盒子换算，
/// 所以 40vw/80vw 这些比例在样张里与真机同构。
Widget aylaAuroraBackgroundSamples() => const _AuroraBackgroundDemo();

class _AuroraBackgroundDemo extends StatelessWidget {
  const _AuroraBackgroundDemo();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AylaSpacing.sp6,
      runSpacing: AylaSpacing.sp6,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        const _AuroraStage(
          viewport: Size(560, 315),
          label: '默认（宽屏档：渐变流层 · 湍流层 · 双光斑 · 静态兜底）',
          child: AylaAuroraBackground(),
        ),
        const _AuroraStage(
          viewport: Size(560, 315),
          reduceMotion: true,
          label: '静态降级（reduced-motion：四层隐藏，只剩静态九层）',
          child: AylaAuroraBackground(),
        ),
        const _AuroraStage(
          viewport: Size(375, 240),
          label: '窄屏档（≤768：光斑上下分区 80vw / 70vw，渐变与湍流放慢 1.4×）',
          child: AylaAuroraBackground(),
        ),
      ],
    );
  }
}

/// 样张舞台：显式覆写视口（宽 / 窄档与 reduced-motion 都按它判定）。
class _AuroraStage extends StatelessWidget {
  const _AuroraStage({
    required this.viewport,
    required this.label,
    required this.child,
    this.reduceMotion = false,
  });

  final Size viewport;
  final String label;
  final Widget child;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        MediaQuery(
          data: MediaQuery.of(context).copyWith(
            size: viewport,
            disableAnimations: reduceMotion,
          ),
          child: SizedBox(
            width: viewport.width,
            height: viewport.height,
            child: ClipRect(child: child),
          ),
        ),
        const SizedBox(height: AylaSpacing.sp2),
        SizedBox(
          width: viewport.width,
          child: Text(
            label,
            style: AylaTextStyles.light.timestamp.copyWith(
              color: AylaColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}
