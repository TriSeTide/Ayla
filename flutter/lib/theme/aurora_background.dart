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
/// - 数值一律照抄 web CSS px：**Flutter 逻辑像素 == 浏览器 CSS 像素**。
///   实测口径（2026-09-27，本机 Windows 125%）：浏览器窗口 1908×910 物理像素、
///   DPR 1.25 ⇒ **CSS 视口 1526×728**；Flutter 同窗口、DPR 1.25 ⇒ 逻辑视口 1526×728。
///   两者在**逻辑单位**上完全相同，「×1.25」只出现在「物理像素截图」这一侧的对账换算里
///   —— 别把 1.25 乘进代码（库内 `AylaGlass.blurCard = 24` 即此口径）。
///
/// ## ★ 2026-09-27 逐像素对账与三处修正（用户实报「中间一大片白、看不到四色在转、
/// 看不到樱粉」）
/// 对账方法：Playwright 只加载 `tokens.css` + `base.css` + `auroraqua.css` 渲染同一视口，
/// 用 `document.getAnimations()` 定位到与本地同一相位（`currentTime` 语义 = 负延迟后的
/// 活动时间 ⇒ 页面加载瞬间即 `-8s`/`-5s` 相位）；两侧都按**设备像素**出图（web：窗口
/// 1908×910 / DPR 1.25 的截图；本地：逻辑 1526×728 + DPR 1.25 ⇒ 1908×910）后逐像素比对。
/// 定位到的三处偏差（都可指到 web 行号）：
///  1. [AylaFluidAurora.gradientVmax] 曾写成 **165**（web `base.css:62` 是 `150vmax`）
///     ⇒ 四角四色被推离视口，视口内只剩中心暖白 = 「中间一大片白」；
///  2. `--bg-aurora-grid`（tokens.css 39–40）的 `0–1px` **常量段**被漏掉、且 `0deg`
///     的相位起点写成了顶边（CSS 的 `0deg` 起点在**底边**）；
///  3. 湍流纹理落盘成了**非预乘**，与 `decodeImageFromPixels` 的 premul 语义不符
///     ⇒ 整层以未预乘亮度参与合成，全屏均匀发白（Δ≈13/255，t>0 时最明显）。
/// 修正后三档全部收敛（平均绝对差，255 制）：宽屏 4 个相位 0.46–0.63、窄屏 0.68–1.06、
/// reduced-motion 0.67；回归锁见 `test/aurora_pixels_test.dart` 的两个「组件级对账」用例。
///
/// ## 公开面
/// `AylaAuroraBackground` · `AylaAuroraKeys` · `AylaFluidAurora` · `AylaFluidFrame`
/// · `AylaFluidPose` · `aylaFluidPoseAt` · `aylaFarthestCornerRadius`
/// · `aylaAuroraBackgroundSamples`

library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'aurora_baked_layer.dart';
import 'aurora_turbulence.dart';
import 'glass.dart';
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
  /// 当前实际挂载的流层（受 [kAylaGradientLayerEnabled] / [kAylaBlobLayersEnabled] 控制）。
  static List<Key> get flowLayers => <Key>[
    if (kAylaGradientLayerEnabled) gradient,
    if (kAylaTurbulenceLayerEnabled) turbulence,
    if (kAylaBlobLayersEnabled) ...<Key>[blobIce, blobSakura],
  ];
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

/// **背景层开关**（默认全开 = web 的形态；诊断期曾逐个停用，2026-09-27 已全部恢复）。
///
/// 与 web 的对应：`html::before` = [kAylaGradientLayerEnabled]（渐变流层，20s spin）、
/// `html::after` = [kAylaTurbulenceLayerEnabled]（湍流层，15s drift）、
/// `body::before/after` = [kAylaBlobLayersEnabled]（双光斑，10s drift）。
/// ⚠️ 这三层**都是动的**；web 里静止的只有 `html` 自己的九层背景（base.css:24-27，
/// 无 animation），而它平时被 `html::before` 覆盖 —— 只有 reduced-motion 才露出来。
/// ⛔ **这两层当前判定为「实现有误」，保持停用**（2026-09-27 用户实机验证：
/// 去掉这两层后静态背景才露出来，之前是「一个莫名其妙的白色不透明背景挡在静态背景前面」）。
/// 修好之前不要打开。
const bool kAylaStaticLayerEnabled = true;
const bool kAylaGradientLayerEnabled = true;
const bool kAylaTurbulenceLayerEnabled = true;
const bool kAylaBlobLayersEnabled = true;

/// 流体极光背景的全部参数（每个数值都能指到 web 的 `文件:行`）。
abstract final class AylaFluidAurora {
  /// 宽 / 窄档分界：`@media (max-width: 768px)`（base.css:211）。
  static const double narrowBreakpoint = 768;

  // ------------------------------------------------------------------
  // 烘焙预算（性能硬约束；见库注释「性能口径」）
  // ------------------------------------------------------------------

  /// 每层烘焙纹理的**最长边像素上限**：低频内容降采样，显存按面积下降。
  /// 2026-09-27 上调（用户报「组件库里的背景比 app 好看」）：两个宿主的**视口尺寸**不同，
  /// 而 cap 是绝对像素 —— 画布样张 560×315（流层 840）根本不触发降采样，app 1400×800
  /// （流层 2100）却被砍到 ratio≈0.69、湍流 0.49 ⇒ 同一套参数在大窗口下细节更糊。
  /// 现在流层/光斑提到 2048/1024：1080p 下流层 ratio≈0.71、光斑 1:1；4K 下流层仍是 2048。
  /// 代价：1080p 五层合计 ≈7.8M 像素（≈31 MB），4K ≈8.1M —— 由 [bakePixelBudget] 锁定。
  static const double bakeStaticMaxSide = 1440;
  static const double bakeGradientMaxSide = 2048;
  static const double bakeTurbulenceMaxSide = 1024;
  static const double bakeBlobMaxSide = 1024;

  /// 流层渲染帧间隔：**默认满帧**（[kAuroraFrameInterval] = [Duration.zero]）。
  /// 只作低端设备/省电预留档；见 [AylaAuroraClock]。
  static const Duration frameInterval = kAuroraFrameInterval;

  /// 模糊扩散预留（= 3 × blur σ）：CSS 的 filter 有 filter region（模糊可超出元素盒），
  /// 而 saveLayer 会把扩散裁在 bounds 内 ⇒ 不预留就露出**硬直边**（用户实报
  /// 「背景总是出现裁切边旋转露出来」）。层尺寸 +2×overscan、位置 -overscan，中心不变。
  static const double gradientOverscan = gradientBlur * 3;
  static const double turbulenceOverscan = turbulenceBlur * 3;

  /// 光斑也要预留（2026-09-27 **更正**）：此前的理由是「radial 70% 截止 ⇒ 圆外已透明 ⇒
  /// 不需要」——**那是错的**：blur(40) 会把圆内的颜色向外扩散，而 saveLayer 把扩散裁在
  /// 元素盒内 ⇒ 圆边界被硬切，观感从 web 的「弥漫大片光」变成「一个圆斑」（用户看图第一眼
  /// 就说「少了一层的感觉」）。补上后与 web 的 filter region 语义一致。
  static const double blobOverscan = blobBlur * 3;

  /// 五层烘焙像素总量上限（RGBA 4 字节/像素 ⇒ 10M ≈ 40 MB）。
  /// 2026-09-27 由 6M 上调到 10M 配合 cap 提高（1080p 实测 ≈7.8M，4K ≈8.1M）。
  /// 由定向测试锁定 —— 谁把层改回 1:1 大纹理，测试就红。
  static const int bakePixelBudget = 10 * 1000 * 1000;

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

  /// `width/height: 150vmax`（base.css 62–63 逐字：`width: 150vmax; height: 150vmax`）。
  ///
  /// ⚠️ 2026-09-27 更正：本常量一度写成 **165**（无 web 依据的自由发挥，连注释都自称
  /// 「150vmax」）。放大 10% 的后果是**两处同时偏**：
  ///  1. 四角四色被推离视口 ⇒ 视口内只剩第 9 层（中心暖白）与 5–8 层（边中点白）
  ///     ⇒ 用户实报的「中间一大片白、看不到四色、看不到樱粉」；
  ///  2. `@keyframes` 里 `translate3d(±4%)` 的百分比基准 = **元素自身尺寸**
  ///     ⇒ 漂移幅度同步放大 10%。
  /// 而 web 自己在 base.css 73–77 就论证过 150vmax 不露边：「150vmax 正方形在
  /// scale(0.8) + 漂移 5% 的极端组合下内切圆 60vmax − 7.5vmax = 52.5vmax ≥ 视口边缘
  /// 50vmax，旋转任意角度均不露边」⇒ 不存在「放大以防露边」的理由。
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
      pixelsOf(
        Size(blobSide, blobSide),
        AylaFluidAurora.bakeBlobMaxSide,
        AylaFluidAurora.blobOverscan,
      ) *
      2;
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
///
/// CSS 原文（两层 `repeating-linear-gradient`，逐字）：
/// ```css
/// repeating-linear-gradient(0deg,  rgba(157,191,230,.015) 0 1px, rgba(157,191,230,.008) 3px, transparent 4px 96px),
/// repeating-linear-gradient(90deg, rgba(157,191,230,.015) 0 1px, rgba(157,191,230,.008) 3px, transparent 4px 96px)
/// ```
/// 逐条语义（**照抄，别简化**）：
///  · 周期 96px，每周期四段：`0–1px` 恒为 .015（**常量段**，不是渐变）、
///    `1–3px` 线性 .015→.008、`3–4px` 线性 .008→0、`4–96px` 恒为 0；
///  · `0deg` = **向上** ⇒ 渐变线起点在**底边**，图案相位从底边起算
///    （写成「从顶边向下」会整体错相 96px 的非整数倍）；
///  · `90deg` = 向右 ⇒ 起点在左边，相位从左边起算；
///  · `transparent` = `rgba(0,0,0,0)`（**黑色**透明，不是同色透明）—— 预乘插值下
///    这是有意义的差异，不能写成 `ice500` 的 0 alpha。
void aylaPaintAuroraGrid(Canvas canvas, Size size) {
  const double period = 96;
  // 一个周期内的 stop（相对 96px）：0 → 亮 / 1px → 仍亮 / 3px → 半亮 / 4px → 0 / 96px → 0
  const List<double> stops = <double>[0, 1 / period, 3 / period, 4 / period, 1];
  final List<Color> ramp = <Color>[
    AylaColors.ice500.withValues(alpha: 0.015), // rgba(157,191,230,.015)
    AylaColors.ice500.withValues(alpha: 0.015), //   0–1px 常量段
    AylaColors.ice500.withValues(alpha: 0.008), // rgba(157,191,230,.008) @3px
    const Color(0x00000000), // transparent @4px
    const Color(0x00000000), // transparent @96px
  ];

  // 横线（0deg，从底边向上重复）
  canvas.drawRect(
    Offset.zero & size,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, size.height),
        Offset(0, size.height - period),
        ramp,
        stops,
        TileMode.repeated,
      ),
  );
  // 竖线（90deg，从左边向右重复）
  canvas.drawRect(
    Offset.zero & size,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        const Offset(period, 0),
        ramp,
        stops,
        TileMode.repeated,
      ),
  );
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
    // 模糊扩散预留（见 [AylaFluidAurora.blobOverscan]）：中心不变，Transform 的位移基准
    // 仍是 diameter（CSS 的百分比基准 = 元素自身尺寸）。
    final double overscan = AylaFluidAurora.blobOverscan;
    return Positioned(
      left: left - overscan,
      top: top - overscan,
      width: diameter + overscan * 2,
      height: diameter + overscan * 2,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: controller,
          child: AylaAuroraBakedLayer(
            size: Size(diameter, diameter),
            blurSigma: AylaFluidAurora.blobBlur,
            blurOverscan: overscan,
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

  /// 上次请求烘焙「预模糊快照」的视口尺寸（null = 还没烘过）。
  Size? _snapshotFor;

  /// 预模糊档专用：把「白底 + 静态九层」烘焙成一张低频小图、登记给玻璃件
  /// （[AylaBackdropSnapshot]，见 13 号 §8.17）。
  ///
  /// **只在 [AylaGlassConfig.preblurEnabled] 时跑** —— 默认的真玻璃档下这里
  /// 直接 return，一分钱都不花；静态九层本身是低频渐变，256 长边足够。
  void _maybeBakeBackdropSnapshot(Size viewport) {
    if (!AylaGlassConfig.preblurEnabled) return;
    if (viewport.isEmpty) return;
    if (_snapshotFor == viewport && AylaBackdropSnapshot.image != null) return;
    _snapshotFor = viewport;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      unawaited(_bakeBackdropSnapshot(viewport));
    });
  }

  Future<void> _bakeBackdropSnapshot(Size viewport) async {
    try {
      final double longest = math.max(viewport.width, viewport.height);
      if (longest <= 0) return;
      final double ratio =
          math.min(1.0, AylaBackdropSnapshot.maxSide / longest);
      final int width = math.max(1, (viewport.width * ratio).round());
      final int height = math.max(1, (viewport.height * ratio).round());
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(
        recorder,
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      );
      canvas
        ..scale(ratio)
        ..drawRect(
          Offset.zero & viewport,
          Paint()..color = AylaFluidAurora.backdrop,
        );
      aylaPaintAuroraRadials(canvas, viewport);
      final ui.Picture picture = recorder.endRecording();
      ui.Image image;
      try {
        image = await picture.toImage(width, height);
      } finally {
        picture.dispose();
      }
      if (!mounted) {
        image.dispose();
        return;
      }
      final RenderObject? ro = context.findRenderObject();
      final Offset origin = ro is RenderBox && ro.hasSize
          ? ro.localToGlobal(Offset.zero)
          : Offset.zero;
      AylaBackdropSnapshot.register(
        image: image,
        viewport: viewport,
        origin: origin,
      );
    } catch (_) {
      // 快照只是预模糊档的采样源：失败退化为「不画背后内容」，绝不让背景崩
      // （同 §8.14 的降级纪律）。下次 build 会重试。
      _snapshotFor = null;
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
          // 预模糊档：把静态九层烘成低频快照登记给玻璃件（默认档下是空操作）。
          _maybeBakeBackdropSnapshot(viewport);
          return DecoratedBox(
            decoration: const BoxDecoration(color: AylaFluidAurora.backdrop),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                // ① html 静态兜底（base.css:25）—— reduced-motion 下唯一可见层。
                // ⏸ 受 [kAylaStaticLayerEnabled] 控制（2026-09-27 诊断：用户要求先停掉）。
                // ⚠️ 停用后 reduced-motion 就没有兜底层了（那本是 web 唯一的兜底目标）。
                if (kAylaStaticLayerEnabled)
                  _StaticAuroraLayer(
                    key: AylaAuroraKeys.staticLayer,
                    viewport: viewport,
                  ),
                // ②③④⑤ 四层流层（base.css 305–314 在 reduced-motion 下整体隐藏）。
                if (flow) ...<Widget>[
                  // ⏸ 渐变流层受 [kAylaGradientLayerEnabled] 控制（2026-09-27 诊断）。
                  if (kAylaGradientLayerEnabled)
                    _FluidGradientLayer(
                      key: AylaAuroraKeys.gradient,
                      viewport: viewport,
                      controller: _gradientClock,
                      narrow: narrow,
                    ),
                  // ⏸ 湍流层受 [kAylaTurbulenceLayerEnabled] 控制（2026-09-27 诊断）。
                  if (kAylaTurbulenceLayerEnabled)
                    _TurbulenceLayer(
                      key: AylaAuroraKeys.turbulence,
                      viewport: viewport,
                      controller: _turbulenceClock,
                      narrow: narrow,
                    ),
                  // ⏸ 2026-09-27 用户要求「暂时把光斑层注释掉」做诊断 —— 由
                  // [kAylaBlobLayersEnabled] 控制（代码保留，改回 true 即恢复）。
                  if (kAylaBlobLayersEnabled) ...<Widget>[
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

/// 冰蓝光斑的单层绘制（层分解样张用）。
void _iceBlobPaint(Canvas canvas, Size size) =>
    aylaPaintBlob(canvas, size, AylaColors.ice500, AylaFluidAurora.blobWideAlpha);

/// 樱粉光斑的单层绘制（层分解样张用）。
void _sakuraBlobPaint(Canvas canvas, Size size) =>
    aylaPaintBlob(canvas, size, AylaColors.sakura300, AylaFluidAurora.blobWideAlpha);

/// 单层诊断舞台：只渲染一层（走与 app 相同的 [AylaAuroraBakedLayer] 烘焙管线）。
class _AuroraLayerStage extends StatelessWidget {
  const _AuroraLayerStage({
    required this.label,
    required this.draw,
    this.blur = 0,
    this.bakeMaxSide,
  });

  final String label;
  final AylaAuroraPaint draw;
  final double blur;
  final double? bakeMaxSide;

  @override
  Widget build(BuildContext context) {
    const Size stage = Size(360, 216);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          width: stage.width,
          height: stage.height,
          child: ClipRect(
            child: DecoratedBox(
              // 白底 = app 的兜底底色（base.css 的 body/#root transparent ⇒ 浏览器默认白）
              decoration: const BoxDecoration(color: Color(0xFFFFFFFF)),
              child: AylaAuroraBakedLayer(
                size: stage,
                draw: draw,
                blurSigma: blur,
                blurOverscan: blur * 3,
                bakeMaxSide: bakeMaxSide,
              ),
            ),
          ),
        ),
        const SizedBox(height: AylaSpacing.sp2),
        SizedBox(
          width: stage.width,
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
        // ---------- 层分解（诊断用：一眼看出「哪一层没显示」） ----------
        // 2026-09-27 用户反复报「app 背景比 web 白很多，像是有一层没显示」。
        // 逐层单独渲染成小舞台，配合左侧完整合成档即可定位缺的是哪一层。
        const _AuroraLayerStage(
          label: '① 静态兜底（九层 radial）—— app 的 html 背景',
          draw: aylaPaintAuroraRadials,
        ),
        const _AuroraLayerStage(
          label: '② 渐变流层（九层 + 96px 网格 + blur40 + 旋转）',
          draw: aylaPaintGradientContent,
          blur: AylaFluidAurora.gradientBlur,
          bakeMaxSide: AylaFluidAurora.bakeGradientMaxSide,
        ),
        const _AuroraLayerStage(
          label: '③ 冰蓝光斑（40vw 圆 + blur40 + radial 70%）',
          draw: _iceBlobPaint,
          blur: AylaFluidAurora.blobBlur,
          bakeMaxSide: AylaFluidAurora.bakeBlobMaxSide,
        ),
        const _AuroraLayerStage(
          label: '④ 樱粉光斑（40vw 圆 + blur40 + radial 70%）',
          draw: _sakuraBlobPaint,
          blur: AylaFluidAurora.blobBlur,
          bakeMaxSide: AylaFluidAurora.bakeBlobMaxSide,
        ),
        // ⚠️ 舞台取**真实视口尺度**（1440×810）：早先用 560×315 的小舞台 ⇒ 流层只有 840、
        // 根本不触发 bakeMaxSide 降采样，而 app 在 1400×800 下流层是 2100、ratio≈0.69
        // —— 同一套参数在两个尺度下的观感必然不同（用户报「组件库里的背景比 app 好看」）。
        // 样张必须如实反映 app 的尺度，否则审核画布会给人错误的安全感。
        const _AuroraStage(
          viewport: Size(1440, 810),
          label: '默认 · 真实视口尺度（宽屏档：渐变流层 · 湍流层 · 双光斑 · 静态兜底）',
          child: AylaAuroraBackground(),
        ),
        const _AuroraStage(
          viewport: Size(1440, 810),
          reduceMotion: true,
          label: '静态降级 · 真实视口尺度（reduced-motion：四层隐藏，只剩静态九层）',
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
