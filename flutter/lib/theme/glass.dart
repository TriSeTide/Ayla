/// 玻璃基类：GlassSurface / GlassCard / GlassButton / GlassInput（全站单材料 owner）。
///
/// 事实源（逐条对应 web CSS，禁自由发挥）：
/// - 材料：`tokens.css` `--glass-bg`(.55) / `--glass-bg-strong`(.78) /
///   `--glass-border`(白 .65) / `--glass-filter`(blur 24px saturate 1.4) /
///   `--glass-shadow`(0 8px 32px .2) / `--glass-inset`(顶沿内高光 .5)
/// - 卡：`app.css .glass-card` + auroraqua.css 卡片族
///   （hover 上浮 2px + 阴影 12/40、active scale .99，300ms/200ms）
/// - 按钮：`app.css .btn/.btn-primary/.btn-glow/.btn-ghost`
///   + auroraqua.css（.btn-ghost 覆写、hover 1.02 / press .98、600ms 扫光）
/// - 输入：`app.css .field` + auroraqua.css 统一 owner
///   （`--glass-inset` 内阴影 + `--glass-filter`）与 focus 辉光边
///
/// 纪律（05 §4）：
/// - **单材料 owner**：一张卡只保留一个材料层，内部布局块不再叠玻璃/blur；
/// - **禁裸色值**：一切颜色走 [AylaColors]；
/// - **reduced-motion**（`MediaQuery.disableAnimations`）：关闭上浮/缩放/扫光，
///   保留焦点与状态反馈；手势路径不依赖动画。
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInputFormatter;
import 'package:flutter/services.dart'
    show KeyDownEvent, LogicalKeyboardKey;
import 'package:flutter/widget_previews.dart';

import 'app_theme.dart';
import 'css_gradient.dart';
import 'preview_theme.dart';
import 'tokens.dart';

/// 毛玻璃运行期配置（性能降级链，05 坑 1 / d:§9）。
///
/// web 端降级条件是「浏览器不支持 `backdrop-filter`」（app.css @supports →
/// `rgba(255,250,251,0.92)` 实底），Flutter 侧对应「平台/设备不适合逐帧
/// 离屏模糊」——统一用 .92 不透明实底兜底，保住可读性且不再付模糊代价。
abstract final class GlassConfig {
  /// 为 true 时全站玻璃卡改用不透明实底（低端设备/性能告警时手动开启）。
  static bool useOpaqueFallback = false;

  /// 依据当前环境解析材料底色（默认 .55 / strong .78；降级 .92）。
  static Color resolveBackground({required bool strong}) {
    if (useOpaqueFallback) return AylaColors.glassOpaqueFallback;
    return strong ? AylaColors.glassBgStrong : AylaColors.glassBg;
  }

  /// `backdrop-filter: blur(Npx) saturate(1.4)` 的 Flutter 等价物。
  ///
  /// CSS 里凡带模糊的玻璃材质**都同时带 saturate(1.4)**（tokens.css
  /// `--glass-filter`、shell.css `.corner-fab`/`.message-fab` 的
  /// `blur(18px) saturate(1.4)`、按钮的 `blur(8px)` 三档）。
  /// `ColorFilter implements ImageFilter` ⇒ 可用 `ImageFilter.compose`
  /// 组合；顺序必须是 `outer: saturate`、`inner: blur`（= 先模糊后饱和，
  /// 与 CSS 一致）。**只做 blur 会丢失玻璃的通透鲜艳感**（此前实测）。
  static ImageFilter backdropFilter({required double sigma}) {
    return ImageFilter.compose(
      outer: const ColorFilter.matrix(kSaturation14), // saturate(1.4)
      inner: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
    );
  }

  /// 只模糊、不饱和（用于 CSS 中确实没写 saturate 的场合）。
  static ImageFilter blurOnly({required double sigma}) {
    return ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
  }
}

/// 玻璃材料的通用绘制（底色 + 模糊 + 亮边 + 宽软阴影 + 顶沿内高光）。
///
/// 只做一层离屏模糊（每处 `BackdropFilter` = 一次离屏模糊，全站用量必须
/// 收敛到本基类；d:§4 单材料 owner）。
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.radius = AylaRadii.rCard,
    this.blur = AylaGlass.blurCard,
    this.strong = false,
    this.shadow = AylaShadows.glass,
    this.border = true,
    this.padding,
    this.radiusOverride,
    this.borderOverride,
    this.shadowTransition = Duration.zero,
  });

  /// 内容。
  final Widget child;

  /// 圆角。
  final double radius;

  /// 模糊半径（卡片 24 / 导航 18 / 按钮 8）。
  final double blur;

  /// 是否使用强玻璃底（.78，弹层）。
  final bool strong;

  /// 外阴影。
  final List<BoxShadow> shadow;

  /// 是否绘制 1px 亮边。
  final bool border;

  /// 圆角覆盖（用于「无圆角顶栏」：`BorderRadius.zero`；以及只做顶部圆角）。
  ///
  /// 传了就优先于 [radius]（后者只能表达均匀圆角）。
  final BorderRadius? radiusOverride;

  /// 边框覆盖（用于「只有下边框」的顶栏：`Border(bottom: ...)`）。
  ///
  /// 传了就优先于 [border]（后者只能表达「四边都有 / 都没有」）。
  final BoxBorder? borderOverride;

  /// 内边距。
  final EdgeInsetsGeometry? padding;

  /// 外阴影过渡时长（对应 CSS `transition: box-shadow <dur>`）。
  ///
  /// [Duration.zero]（默认）= 阴影瞬时切换；非零时用 `BoxShadow.lerpList`
  /// 在两份阴影之间插值（auroraqua.css 卡片族为 300ms、按钮族为 200ms）。
  /// 插值在 ring painter 内完成 → 即便某帧 blur 为 0 也只画形状之外，
  /// 不会出现「实心矩形闪现」。
  final Duration shadowTransition;

  @override
  Widget build(BuildContext context) {
    final bool opaque = GlassConfig.useOpaqueFallback;
    final bool reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    // 卡面（底色 + 亮边 + 顶沿内高光）。**不含外阴影**——阴影必须在裁剪
    // 之外绘制，否则会被 ClipRRect 连同圆角裁掉（web box-shadow 在元素外侧）。
    // 圆角/边框优先用 override（支持「无圆角顶栏」与「只下边框」）
    final BorderRadius radiusValue =
        radiusOverride ?? BorderRadius.circular(radius);
    final BoxBorder? borderValue = borderOverride ??
        (border ? Border.all(color: AylaColors.glassBorder) : null);
    final Widget face = DecoratedBox(
      decoration: BoxDecoration(
        color: GlassConfig.resolveBackground(strong: strong),
        borderRadius: radiusValue,
        border: borderValue,
      ),
      child: Stack(
        children: <Widget>[
          // 顶沿内高光：`--glass-inset` = `inset 0 1px 0 rgba(255,255,255,.5)`。
          // Flutter 的 BoxShadow 无 inset 变体，且「非均匀 Border + borderRadius」
          // 会被断言拒绝，故用 `AylaInset.topHighlight(height)`——它按实际高度
          // 取 stops = 1/height，视觉上恰为 1px（固定比例近似会被拉成一条带）。
          Positioned.fill(
            child: IgnorePointer(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints c) {
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: radiusValue,
                      gradient: AylaInset.topHighlight(c.maxHeight),
                    ),
                  );
                },
              ),
            ),
          ),
          Padding(padding: padding ?? EdgeInsets.zero, child: child),
        ],
      ),
    );

    // 玻璃层结构（对齐 CSS `backdrop-filter: blur(24px) saturate(1.4)`）：
    //   Stack[
    //     ① BackdropFilter(blur+saturate) ← 只作用于卡背后的页面内容
    //     ② 阴影环（只画在卡外；在模糊层之上，避免被模糊采样）
    //     ③ face（.55 半透明白底 + 亮边 + 内高光）
    //   ]
    //
    // 两个 Flutter 与 CSS 的关键差异（必须这样处理，否则卡内发黑）：
    //  a) CSS 的 backdrop-filter **不含元素自身 box-shadow**，而 Flutter 的
    //     BackdropFilter 会把它所在离屏层内已绘制的内容一并模糊 → 阴影画在
    //     模糊层**之上**；
    //  b) CSS 的 box-shadow **只在 border-box 之外绘制**，Flutter 的 BoxShadow
    //     会铺满整个形状（含内部）→ 用 CustomPainter 把内部挖空。
    final Widget glassBody = opaque
        ? face
        : Stack(
            fit: StackFit.passthrough,
            clipBehavior: Clip.none,
            children: <Widget>[
              // ① 模糊 + 饱和层：CSS `backdrop-filter: blur(24px) saturate(1.4)`
              //    的完整等价实现。
              //
              //    关键 API（dart:ui）：`ColorFilter implements ImageFilter`
              //    → 可作 BackdropFilter 的 filter；配合
              //    `ImageFilter.compose(outer:, inner:)` 组合两个滤镜，
              //    即 result = outer(inner(source))。
              //    compose 已在多端可用（sky_engine painting.dart:4406）。
              // blur <= 0 → 不建滤镜层：sigma 0 只是白白多一个 saveLayer，
              // 且嵌入式场景（如组件画布里的查看器样张）会采样宿主页面造成糊页。
              if (blur > 0)
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: radiusValue,
                  child: BackdropFilter(
                    filter: ImageFilter.compose(
                      // 外层：饱和度 1.4（在模糊结果上做，等价 CSS 顺序）
                      outer: const ColorFilter.matrix(kSaturation14),
                      // 内层：blur(24px)（t:--glass-filter）
                      inner: ImageFilter.blur(
                        sigmaX: blur,
                        sigmaY: blur,
                      ),
                    ),
                    // child 必须是纯透明内容：只贡献滤镜层，不携带颜色
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              // ② 阴影环（在模糊层之上、卡面之下；只画形状之外）
              if (shadow.isNotEmpty)
                Positioned.fill(
                  child: IgnorePointer(
                    child: shadowTransition == Duration.zero || reduceMotion
                        ? CustomPaint(
                            painter: _OuterShadowPainter(
                              radius: radiusValue,
                              shadows: shadow,
                            ),
                          )
                        : TweenAnimationBuilder<List<BoxShadow>>(
                            tween: _ShadowListTween(end: shadow),
                            duration: shadowTransition,
                            curve: AylaCurves.auroraqua,
                            builder: (BuildContext context,
                                List<BoxShadow> value, Widget? _) {
                              return CustomPaint(
                                painter: _OuterShadowPainter(
                                  radius: radiusValue,
                                  shadows: value,
                                ),
                              );
                            },
                          ),
                  ),
                ),
              // ③ 卡面
              face,
            ],
          );

    return glassBody;
  }
}

/// `box-shadow` 的「只画形状之外」工具（等价 CSS 的 border-box 裁剪）。
///
/// **为什么需要**：CSS 规范规定 `box-shadow` **不在 border-box 内部绘制**
/// （outer shadow is clipped inside the border-box）；而 Flutter 的
/// [BoxShadow] / `BoxDecoration(boxShadow:)` **会铺满整个形状含内部**：
/// - 半透明卡面 → 阴影透过卡面被看见，卡内发灰暗；
/// - 悬停时给按钮加 `--glass-shadow-nav`（`0 0 8px rgba(157,191,230,.3)`）
///   → 冰蓝阴影染进按钮内部，**悬停瞬间闪一下蓝色**。
///
/// 本项目此前只在 [GlassSurface] 内部（私有 `_OuterShadowPainter`）处理过，
/// 导致其他组件各自裸用 `BoxShadow` 时重现同一问题 → 提升为公共 API。
abstract final class AylaGlassShadow {
  /// 外阴影层：铺满父级，但**只在形状之外**绘制 [shadows]。
  ///
  /// 用法（叠在面层**之下**）：
  /// ```dart
  /// Stack(children: <Widget>[
  ///   Positioned.fill(child: AylaGlassShadow.ring(
  ///     radius: BorderRadius.circular(12), shadows: AylaShadows.nav)),
  ///   face,
  /// ])
  /// ```
  static Widget ring({
    required BorderRadius radius,
    required List<BoxShadow> shadows,
  }) {
    if (shadows.isEmpty) return const SizedBox.shrink();
    return CustomPaint(painter: _OuterShadowPainter(radius: radius, shadows: shadows));
  }

  /// 在 [child] 之下叠一层**只画形状之外**的外阴影（形状尺寸取 child 的）。
  ///
  /// [shadows] 变化时按 CSS `transition: box-shadow` 语义插值；
  /// 两侧都有阴影时不会出现「blur 从 0 起步」的硬边（形状内部始终被挖空）。
  /// [shadows] 为空 = 不画（web 未声明 box-shadow 的构件）。
  ///
  /// [curve] 是插值缓动：CSS 里各构件的 `transition` 缓动**不统一**——按钮组用
  /// `--auroraqua-ease`（= `ease`，本参数默认值，既有调用点全部不变），
  /// 而 `.session-activity-ball` 用的是 `--ease-out`（`shell.css:495–496`，150ms）
  /// ⇒ 该处显式传 [AylaCurves.easeOut]。
  static Widget animatedRing({
    required Widget child,
    required BorderRadius radius,
    required List<BoxShadow> shadows,
    Duration duration = AylaDurations.auroraqua,
    Cubic curve = AylaCurves.auroraqua,
  }) {
    if (shadows.isEmpty) return child;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned.fill(
          child: IgnorePointer(
            child: _AnimatedShadowRing(
              radius: radius,
              shadows: shadows,
              duration: duration,
              curve: curve,
            ),
          ),
        ),
        child,
      ],
    );
  }

  /// 在 [child] 之下叠一层**淡入淡出**的外阴影环（用于「无 → 有」的场景：
  /// hover/focus 才出现的光晕）。
  ///
  /// 为什么不用 [animatedRing]：从「无阴影」插值时 `BoxShadow.lerp` 会把
  /// blurRadius 从 0 拉起，头几帧是**硬边**（实测会闪一下）；淡入固定阴影
  /// 既无硬边，也与 CSS 观感一致。
  static Widget fadeRing({
    required Widget child,
    required BorderRadius radius,
    required List<BoxShadow> shadows,
    required bool visible,
    Duration duration = AylaDurations.button,
  }) {
    if (shadows.isEmpty) return child;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              duration: duration,
              curve: AylaCurves.auroraqua,
              opacity: visible ? 1.0 : 0.0,
              child: CustomPaint(
                painter: _OuterShadowPainter(radius: radius, shadows: shadows),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// [AylaGlassShadow.animatedRing] 的插值实现（reduced-motion 时不做过渡）。
class _AnimatedShadowRing extends StatelessWidget {
  const _AnimatedShadowRing({
    required this.radius,
    required this.shadows,
    required this.duration,
    this.curve = AylaCurves.auroraqua,
  });

  final BorderRadius radius;
  final List<BoxShadow> shadows;
  final Duration duration;
  final Cubic curve;

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      return CustomPaint(
        painter: _OuterShadowPainter(radius: radius, shadows: shadows),
      );
    }
    return TweenAnimationBuilder<List<BoxShadow>>(
      tween: _ShadowListTween(end: shadows),
      duration: duration,
      curve: curve,
      builder: (BuildContext context, List<BoxShadow> value, Widget? _) {
        return CustomPaint(
          painter: _OuterShadowPainter(radius: radius, shadows: value),
        );
      },
    );
  }
}

/// 只绘制「形状之外」的外阴影（等价 CSS `box-shadow` 的 border-box 裁剪）。
///
/// Flutter 的 `BoxShadow` 会把阴影铺满整个形状（含内部），在半透明卡面下
/// 透出灰暗；本 painter 用 `Path.combine(difference, 外框, 形状)` 挖空内部。
class _OuterShadowPainter extends CustomPainter {
  const _OuterShadowPainter({required this.radius, required this.shadows});

  final BorderRadius radius;
  final List<BoxShadow> shadows;

  @override
  void paint(Canvas canvas, Size size) {
    final Path hole = Path()..addRRect(radius.toRRect(Offset.zero & size));
    // 外框足够大以容纳 blur 扩散与 offset
    final Path frame = Path()
      ..addRect(Rect.fromLTWH(
        -size.width * 2,
        -size.height * 2,
        size.width * 5,
        size.height * 5,
      ));
    final Path ring = Path.combine(PathOperation.difference, frame, hole);

    canvas.save();
    canvas.clipPath(ring);
    for (final BoxShadow s in shadows) {
      final Paint paint = s.toPaint();
      final Rect r = (Offset.zero & size).shift(s.offset);
      canvas.drawRRect(radius.toRRect(r), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _OuterShadowPainter old) =>
      old.radius != radius || old.shadows != shadows;
}

/// 两组阴影之间的插值（等价 CSS `transition: box-shadow`）。
///
/// `BoxShadow.lerpList` 按索引逐项插值（长度不等时短的一方按「无阴影」补齐），
/// 语义与浏览器一致：color / offset / blur / spread 各自线性插值。
class _ShadowListTween extends Tween<List<BoxShadow>> {
  _ShadowListTween({super.end});

  @override
  List<BoxShadow> lerp(double t) =>
      BoxShadow.lerpList(begin, end, t) ?? const <BoxShadow>[];
}

/// 模糊半径归一（--glass-filter blur(24px)；导航 18 / 按钮 8 有各自覆写）。
abstract final class AylaGlass {
  /// blur(24px) saturate(1.4)（t:--glass-filter）——卡片/侧栏/弹层/输入框
  static const double blurCard = 24;
  /// blur(18px)——底栏/顶栏/搜索面板/FAB
  static const double blurNav = 18;
  /// blur(8px)——ghost 按钮/工具钮
  static const double blurButton = 8;
}

/// `--glass-inset` 的组合工具（把顶沿 1px 内高光铺到任意形状上）。
///
/// web 的每个玻璃材质都由**四层**组成：半透明底 + 1px 亮边 + 外阴影 +
/// **顶沿内高光 `--glass-inset`**；Flutter 的 `BoxShadow` 无 inset 变体，
/// 故内高光用 `AylaInset.topHighlight` 单独叠一层。
abstract final class AylaGlassInset {
  /// 在 [child] 之上叠一层「形状内顶沿 1px 白色高光」。
  ///
  /// [radius] 必须与 [child] 的形状圆角一致，否则高光会溢出/被裁。
  static Widget over({
    required Widget child,
    required BorderRadius radius,
  }) {
    return Stack(
      children: <Widget>[
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) {
                return DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    gradient: AylaInset.topHighlight(c.maxHeight),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// GlassCard —— 全站卡面材料（app.css .glass-card / d:§4 Cards）。
///
/// [interactive] 为 true 时启用「可交互卡」行为（hover 上浮 2px + 阴影升
/// 12/40、按下 scale .99）；非交互卡保持稳定位置（d:§4「仅可交互列表卡抬升」）。
///
/// 2026-09-20 组件库审查 R6：交互动效本体收敛到公共件 [AylaCardInteraction]，
/// 与卡片族（群卡 / 群列表行）共用同一份实现（此前 GlassCard 与 group_card
/// 各写一份，是同一 CSS 配方两套代码）。
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding,
    this.radius = AylaRadii.rCard,
    this.blur = AylaGlass.blurCard,
    this.strong = false,
    this.shadow,
    this.interactive = false,
    this.onTap,
    this.semanticLabel,
  });

  /// 内容。
  final Widget child;

  /// 内边距（默认 16px，d:§12.8 帖子卡 padding 16；调用方可覆盖）。
  final EdgeInsetsGeometry? padding;

  /// 圆角（.glass-card = --radius-card 16）。
  final double radius;

  /// 模糊半径。
  final double blur;

  /// 强玻璃（弹层用 .78，d:§4 Panels）。
  final bool strong;

  /// 覆盖阴影（默认静止 `--glass-shadow`、hover `--glass-shadow-hover`）。
  final List<BoxShadow>? shadow;

  /// 可交互（hover 抬升 + 按下缩放）。
  final bool interactive;

  /// 点击回调（传入即渲染为可点击卡）。
  final VoidCallback? onTap;

  /// 可访问性标签。
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return AylaCardInteraction(
      interactive: interactive,
      onTap: onTap,
      semanticLabel: semanticLabel,
      builder: (BuildContext context, bool hovered) => GlassSurface(
        radius: radius,
        blur: blur,
        strong: strong,
        // hover → `--glass-shadow-hover`（12/40）；静止 → `--glass-shadow`（8/32）。
        // box-shadow 300ms 过渡由 GlassSurface.shadowTransition 表达（卡片族）。
        shadow:
            shadow ?? (hovered ? AylaShadows.glassHover : AylaShadows.glass),
        shadowTransition: AylaDurations.auroraqua,
        padding: padding ?? const EdgeInsets.all(AylaSpacing.sp4),
        child: child,
      ),
    );
  }
}

/// 卡片族交互动效（auroraqua.css 29–52 卡片族；与按钮族 55–94 区分）。
///
/// 事实源：
/// ```
/// transition: translate 300ms var(--auroraqua-ease), scale 200ms var(--auroraqua-ease);
/// :hover  → translate: 0 -2px; box-shadow: var(--glass-shadow-hover);
/// :active → translate: 0 0;    scale: 0.99;
/// ```
/// 与 [AylaPressScale]（按钮族 hover 1.02 / active .98）区分：
/// 卡片是「上浮 2px + 轻微缩小 .99」，按钮是「放大 1.02 / 缩小 .98」。
///
/// [interactive] == false 时完全不挂指针层（静态卡）；有 [onTap] 时仍可点击。
class AylaCardInteraction extends StatefulWidget {
  const AylaCardInteraction({
    super.key,
    required this.builder,
    this.onTap,
    this.semanticLabel,
    this.interactive = true,
    this.focusRingColor,
    this.focusRingRadius = const BorderRadius.all(Radius.circular(AylaRadii.rCard)),
  });

  /// 内容构建器（`hovered` 用于切换阴影与其它 hover 态）。
  final Widget Function(BuildContext context, bool hovered) builder;

  /// 点击回调（null 则不响应；交互动效仍保留）。
  final VoidCallback? onTap;

  /// 可访问性标签。
  final String? semanticLabel;

  /// 是否参与卡片族交互动效（hover 上浮 2px / 按下 scale .99）。
  final bool interactive;

  /// `:focus-visible` 环色；**null = 不画、也不进 tab 序列**（保持既有组件现状）。
  ///
  /// 事实源：卡片族的焦点环是**逐域声明**的，且都用 **`--ice-500`** ——
  /// `voice.css:547`（`.voice-hub .voice-channel-card`）、`voice.css:718`
  /// （`.group-voice`）、`typed-result-cards.css:68`；
  /// `outline: 2px solid var(--ice-500); outline-offset: 2px`（环跟随卡片自身 radius 16）。
  ///
  /// ⚠️ 环画在**形状之外**（`left/top/right/bottom: -4` 的 2px 描边 = offset 2 + width 2），
  /// **不参与布局** —— 库内 `AylaPressScale` 的环是内嵌 Container，会让元素长大 4px，
  /// 卡片上会明显撑大（`13-*` §6.21 已记录该差异）。
  ///
  /// 传了环色即表示**该卡参与键盘可达性**：`tab` 可聚焦 + `Enter` / `Space` 触发 [onTap]
  /// （web 卡片是 `role="button" tabIndex={0}` + `onKeyDown` 同语义，如
  /// `VoiceChannelCard.tsx:21–24`）。
  final Color? focusRingColor;

  /// 环的内侧圆角（默认 `--radius-card` 16；环自身半径 = 该值 + 2）。
  final BorderRadius focusRingRadius;

  @override
  State<AylaCardInteraction> createState() => _AylaCardInteractionState();
}

class _AylaCardInteractionState extends State<AylaCardInteraction> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  /// `outline` 环层：画在形状之外、不吃指针（等价 CSS outline）。
  Widget _focusRing() {
    final Color? ring = widget.focusRingColor;
    if (ring == null || !_focused) return const SizedBox.shrink();
    return Positioned(
      left: -4,
      top: -4,
      right: -4,
      bottom: -4,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: ring, width: 2), // outline: 2px
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(widget.focusRingRadius.topLeft.x + 2),
              topRight: Radius.circular(widget.focusRingRadius.topRight.x + 2),
              bottomLeft:
                  Radius.circular(widget.focusRingRadius.bottomLeft.x + 2),
              bottomRight:
                  Radius.circular(widget.focusRingRadius.bottomRight.x + 2),
            ),
          ),
        ),
      ),
    );
  }

  /// 键盘可达（`tab` + `Enter` / `Space`）与焦点环；未传环色时原样返回。
  Widget _withFocus(Widget child) {
    if (widget.focusRingColor == null) return child;
    return Focus(
      onFocusChange: (bool has) => setState(() => _focused = has),
      onKeyEvent: (FocusNode node, KeyEvent event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final bool activate = event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.space;
        if (!activate || widget.onTap == null) return KeyEventResult.ignored;
        widget.onTap!();
        return KeyEventResult.handled;
      },
      child: Stack(
        clipBehavior: Clip.none, // 环画在卡片之外，不能被裁
        children: <Widget>[_focusRing(), child],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);

    // 非交互卡：不挂 hover/按压动效；有 onTap 时保持可点击（对齐原 GlassCard
    // interactive=false 的行为）。
    if (!widget.interactive) {
      if (widget.onTap == null) return widget.builder(context, false);
      return Semantics(
        button: true,
        label: widget.semanticLabel,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: widget.builder(context, false),
        ),
      );
    }

    // translate：hover → -2px；按下复位 0（CSS `:active { translate: 0 0 }`）
    final double dy = reduceMotion
        ? 0
        : (_pressed
              ? 0
              : (_hovered ? -2 : 0));
    // scale：按下 .99（200ms）
    final double scale = reduceMotion || !_pressed ? 1.0 : 0.99;

    // CSS `translate` 是**像素位移**（不影响布局、不改变自身坐标系原点），
    // 故用 Transform.translate 而非 AnimatedSlide（后者 offset 是尺寸百分比）。
    Widget content = TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: dy),
      duration: reduceMotion
          ? Duration.zero
          : AylaDurations.auroraqua, // translate / box-shadow 300ms
      curve: AylaCurves.auroraqua,
      builder: (BuildContext context, double v, Widget? child) {
        return Transform.translate(offset: Offset(0, v), child: child);
      },
      child: AnimatedScale(
        duration: reduceMotion
            ? Duration.zero
            : AylaDurations.button, // scale 200ms
        curve: AylaCurves.auroraqua,
        scale: scale,
        child: widget.builder(context, _hovered),
      ),
    );

    if (widget.semanticLabel != null) {
      content = Semantics(
        button: widget.onTap != null,
        label: widget.semanticLabel,
        child: content,
      );
    }

    return _withFocus(
      MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: Listener(
          onPointerDown: (_) => setState(() => _pressed = true),
          onPointerUp: (_) => setState(() => _pressed = false),
          onPointerCancel: (_) => setState(() => _pressed = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: content,
          ),
        ),
      ),
    );
  }
}

/// 按钮类型（.btn-primary / .btn-glow / .btn-ghost）。
enum GlassButtonVariant {
  /// .btn-primary：indigo 实底 + 白字 + compact 阴影；hover 换 glow 阴影
  primary,

  /// .btn-glow：sakura→glow 135deg 渐变 + grape 字 + 常驻辉光；hover brightness(1.06)
  glow,

  /// .btn-ghost：玻璃底 + 亮边 + blur(8px) + button 阴影；hover 换 ice 蓝底
  ghost,

  /// .btn-destructive（app.css 2764–2770）：`--destructive` 实底 + `#fffafb` 字；
  /// `:hover:not(:disabled) → filter: brightness(1.06)`。
  /// 用于确认删除等危险操作（ConfirmDialog 的确认键、群管理类操作）。
  destructive,

  /// `.voice-leave-btn`（app.css 3108–3112）：**透明底 + `--destructive` 字 +
  /// 1px `--destructive` 边**，无阴影（`.btn` 基础块本身不声明 background/box-shadow）。
  /// 与 [destructive]（红**实底**）不是一档；2026-09-21 由 voice 域第一批按
  /// 「先加档位、不新造」补入。
  outlineDestructive,
}

/// GlassButton —— 严格照 web CSS 实现的三类按钮。
///
/// **事实源（app.css + auroraqua.css，逐条对应，无自由发挥）**：
///
/// `.btn`（盒模型）：inline-flex / gap 8 / min-height 40 / padding 0 24
///   / radius 12 / 14px / 700 / ls .2
/// `.btn-primary`：background --indigo-700 / #fffafb / box-shadow compact；
///   :hover → box-shadow glow-shadow
/// `.btn-glow`：background 135deg #f9b0ff→#f796ff / color grape-700 /
///   box-shadow glow-shadow（常驻）；:hover → filter brightness(1.06)
/// `.btn-ghost`（base）：transparent / 1px rgba(70,91,146,.35) / indigo-700；
///   :hover → rgba(157,191,230,.18)。auroraqua.css 覆写：glass-bg /
///   glass-border / glass-shadow-button / blur(8px)；:hover → button-hover
///
/// auroraqua.css 交互：200ms transition 组；hover scale 1.02、active
///   scale .98（独立 scale 属性）；600ms 扫光（::after：90deg transparent→
///   glass-border→transparent，opacity .5，translateX(-120%→120%)）。
/// base.css button:disabled：opacity .55。
/// 窄屏（≤768）：辉光降 30%（0 0 11px rgba(247,150,255,.32)）。
class GlassButton extends StatefulWidget {
  const GlassButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = GlassButtonVariant.primary,
    this.icon,
    this.minHeight = 40,
    this.minWidth,
    this.padding = const EdgeInsets.symmetric(horizontal: AylaSpacing.sp6),
    this.fontSize = 14,
    this.expand = false,
    this.semanticLabel,
    this.glowHover = false,
  });

  /// hover 态改走 **glow 边 + 粉辉光**（web `.post-editor-image-btn:hover
  /// { border-color: var(--glow-500); box-shadow: var(--glow-shadow) }`，
  /// posts.css 410–414）：与 ghost 默认的「冰蓝底 + button-hover 阴影」不同，
  /// 供帖子编辑器「图片/视频」等媒体选择钮使用。
  final bool glowHover;

  /// 文案。
  final String label;

  /// 点击回调；null = disabled（对应 :disabled，opacity .55）。
  final VoidCallback? onPressed;

  /// 变体。
  final GlassButtonVariant variant;

  /// 前置图标（.btn 的 gap 8 作用在图标与文字之间）。
  final Widget? icon;

  /// `.btn { min-height: 40px }`；认证页传 44（auth.css .auth-submit）。
  final double minHeight;

  /// `min-width`（.auth-switch-link 72 / .auth-code-btn 104）；null = 内容决定。
  final double? minWidth;

  /// `.btn { padding: 0 24px }`；认证页可传 padding-inline 16。
  final EdgeInsetsGeometry padding;

  /// `.btn { font-size: 14px }`。
  ///
  /// 逐处覆写的档位：`.voice-join-btn` **13**、`.voice-rejoin-btn` **12**
  /// （app.css 623–628 区的 `voice.css` 覆写 / app.css 3114–3118）。
  final double fontSize;

  /// `.auth-submit { width: 100% }`。
  final bool expand;

  /// 可访问性标签（默认 [label]）。
  final String? semanticLabel;

  @override
  State<GlassButton> createState() => _GlassButtonState();
}

class _GlassButtonState extends State<GlassButton>
    with SingleTickerProviderStateMixin {
  /// 扫光位置：0 = translateX(-120%)，1 = translateX(+120%)（::after）。
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: AylaDurations.sweep, // 600ms
  );

  /// ::after 的 `transition: transform 600ms var(--auroraqua-ease)` 是
  /// **ease 曲线**（先快后慢），不是 linear——直接用 controller 的线性值
  /// 会让扫光匀速掠过，与 web 手感不一致（实测）。
  late final Animation<double> _sweepEased = CurvedAnimation(
    parent: _sweep,
    curve: AylaCurves.auroraqua,
  );

  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  bool get _enabled => widget.onPressed != null;

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles text = AylaTextStyles.of(context);
    final bool narrow = Breakpoint.isNarrow(MediaQuery.sizeOf(context).width);
    final bool animate = _enabled && !_reduceMotion;
    final bool hovered = _hovered && animate;

    // ---- 三类材质 ----
    late final Color background;
    late final Color foreground;
    late final Color? borderColor;
    final List<BoxShadow> shadow;
    late final LinearGradient? gradient;

    switch (widget.variant) {
      case GlassButtonVariant.primary:
        background = AylaColors.indigo700;
        foreground = AylaColors.surface;
        borderColor = null;
        gradient = null;
        shadow = hovered ? AylaShadows.glow : AylaShadows.compact;
      case GlassButtonVariant.glow:
        background = AylaColors.sakura300; // 渐变盖其上，底色兜底
        foreground = AylaColors.grape700;
        borderColor = null;
        // 135deg #f9b0ff → #f796ff（app.css .btn-glow）
        gradient = cssLinearGradient(
          angleDeg: 135,
          colors: AylaGradients.btnGlow,
        );
        // 常驻辉光；窄屏（≤768）强度降 30%
        shadow = narrow ? AylaShadows.glowNarrow : AylaShadows.glow;
      case GlassButtonVariant.ghost:
        // auroraqua 覆写：glass-bg + glass-border + button 阴影 + blur(8px)
        // glowHover（.post-editor-image-btn）：hover 不改底色，只换 glow 边 + 粉辉光
        background = (hovered && !widget.glowHover)
            ? AylaColors.ice500.withValues(alpha: 0.18) // :hover rgba(157,191,230,.18)
            : GlassConfig.resolveBackground(strong: false);
        foreground = AylaColors.indigo700;
        borderColor = (hovered && widget.glowHover)
            ? AylaColors.glow500 // :hover border-color: var(--glow-500)
            : AylaColors.glassBorder; // auroraqua 覆写 --glass-border
        gradient = null;
        shadow = (hovered && widget.glowHover)
            ? AylaShadows.glow
            : (hovered ? AylaShadows.buttonHover : AylaShadows.button);
      case GlassButtonVariant.destructive:
        // `.btn-destructive { background: var(--destructive); color: #fffafb }`
        // 无边框、无阴影（web 未声明）；hover 走下方 brightness(1.06) 滤镜分支
        background = AylaColors.destructive;
        foreground = AylaColors.surface;
        borderColor = null;
        gradient = null;
        shadow = const <BoxShadow>[]; // 空 = 无阴影（web 未声明 box-shadow）
      case GlassButtonVariant.outlineDestructive:
        // `.voice-leave-btn { background: transparent; color: var(--destructive);
        //  border: 1px solid var(--destructive) }`（app.css 3108–3112）
        // ⚠️ web 的 `transparent` 就是 `rgba(0,0,0,0)`，且本档**没有** hover 换底
        //    （`.voice-leave-btn` 不声明 :hover）⇒ 不存在「透明黑插值闪灰」问题，
        //    故按字面写 Colors.transparent（不是同色相近似）。
        background = Colors.transparent;
        foreground = AylaColors.destructive;
        borderColor = AylaColors.destructive;
        gradient = null;
        shadow = const <BoxShadow>[]; // `.btn` 基础块未声明 box-shadow
    }

    final BorderRadius rInput =
        BorderRadius.all(Radius.circular(AylaRadii.rInput));

    // ---- 卡面：底色/渐变 + 描边 + 圆角裁剪（.btn 盒模型与材质）----
    // 注意：padding 必须放在 Stack **内部**（内容 Row 外包 Padding）——
    // CSS `.btn::after { inset: 0 }` 的扫光是相对 padding box（含左右
    // 24px），若 padding 留在外层面板，Positioned.fill 扫光层只能覆盖
    // 内容区，光条会比按钮窄、扫不过按钮两端。
    //
    // 渐变角度换算需要**真实宽高比**（CSS 渐变线长 = |W sinθ|+|H cosθ|，
    // 而 Flutter Alignment 端点在归一化空间插值 → 只有正方形时等价；
    // 宽扁按钮上 135deg 斜向渐变会整体错位，实测偏差可达 0.58）。
    // 故这里用 LayoutBuilder 拿到实际尺寸再生成渐变；非渐变变体直接复用。
    Widget buildFace(double aspectRatio) {
      final Gradient? g = switch (widget.variant) {
        GlassButtonVariant.glow => cssLinearGradient(
            angleDeg: 135, // 135deg #f9b0ff → #f796ff（app.css .btn-glow）
            colors: AylaGradients.btnGlow,
            aspectRatio: aspectRatio,
          ),
        _ => gradient,
      };
      return AnimatedContainer(
      duration: _reduceMotion ? Duration.zero : AylaDurations.fast,
      curve: AylaCurves.easeOut,
      constraints: BoxConstraints(
        minHeight: widget.minHeight,
        minWidth: widget.minWidth ?? 0,
      ),
      decoration: BoxDecoration(
        color: background,
        gradient: g,
        borderRadius: rInput,
        border: borderColor == null ? null : Border.all(color: borderColor),
      ),
      // ::after 在圆角内裁剪（.btn { overflow: hidden; isolation: isolate }）
      child: ClipRRect(
        borderRadius: rInput,
        clipBehavior: Clip.hardEdge,
        child: Stack(
          fit: StackFit.passthrough,
          alignment: Alignment.center,
          children: <Widget>[
            // .btn::after 扫光：覆盖整个 padding box；opacity .5，
            // -120% → +120%（600ms）
            if (animate)
              Positioned.fill(
                child: IgnorePointer(
                  child: Opacity(
                    opacity: 0.5,
                    child: AnimatedBuilder(
                      animation: _sweepEased,
                      builder: (BuildContext context, Widget? child) {
                        return FractionalTranslation(
                          translation: Offset(-1.2 + _sweepEased.value * 2.4, 0),
                          child: child,
                        );
                      },
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: cssLinearGradient(
                            angleDeg: 90, // linear-gradient(90deg, …)
                            colors: AylaGradients.sweep,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            // 内容：gap 8px；14px/700/ls .2（padding 在 Stack 内部）
            Padding(
              padding: widget.padding,
              child: Row(
                mainAxisSize:
                    widget.expand ? MainAxisSize.max : MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  if (widget.icon != null) ...<Widget>[
                    IconTheme(
                      data: IconThemeData(color: foreground, size: 18),
                      child: widget.icon!,
                    ),
                    const SizedBox(width: AylaSpacing.sp2), // gap: var(--sp-2)
                  ],
                  // 文字：外层 Flexible(loose) 承接超长省略，内层 Center 保证
                  // 文字自身居中——不用 tight flex（会吃掉主轴空间把字推到左侧，
                  // expand 满宽时可见，实测）。
                  Flexible(
                    fit: FlexFit.loose,
                    child: Center(
                      widthFactor: 1,
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: text.label.copyWith(
                          color: foreground,
                          fontSize: widget.fontSize,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    } // end buildFace
    // 用 LayoutBuilder 取真实尺寸 → 生成含正确宽高比的 face
    final Widget face = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double h = c.maxHeight.isFinite && c.maxHeight > 0
            ? c.maxHeight
            : widget.minHeight;
        final double w = c.maxWidth.isFinite && c.maxWidth > 0
            ? c.maxWidth
            : (widget.minWidth ?? h);
        return buildFace(w / h);
      },
    );

    // ---- 外阴影：不参与裁剪（box-shadow 在元素外侧）----
    Widget decorated = Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        // 外阴影**只画形状之外**（2026-09-20 审查 R2：原裸 boxShadow 会把
        // `--glass-shadow-*` 的 indigo 铺进 ghost 的 .55 玻璃面内部）
        // + `transition: box-shadow 200ms`（auroraqua.css 55–70）。
        Positioned.fill(
          child: IgnorePointer(
            child: _AnimatedShadowRing(
              radius: rInput,
              shadows: shadow,
              duration: AylaDurations.button,
            ),
          ),
        ),
        face,
        // --glass-inset（顶沿 1px 内高光）：`.btn-primary` 的
        // `--glass-shadow-compact`、`.btn-ghost` 的 `--glass-shadow-button[-hover]`
        // 两个 token 都含 `var(--glass-inset)`（tokens.css 126–128）。
        // `.btn-glow` 用的是 `--glow-shadow`（不含 inset），故不叠加；
        // 新档 `outlineDestructive` 的 `.btn` 基础块**没有任何 box-shadow**
        // ⇒ 也不该有内高光（`--glass-inset` 只随阴影 token 出现）。
        if (widget.variant != GlassButtonVariant.glow &&
            widget.variant != GlassButtonVariant.outlineDestructive)
          Positioned.fill(
            child: IgnorePointer(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints c) {
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: rInput,
                      gradient: AylaInset.topHighlight(c.maxHeight),
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );

    // `.btn-glow:hover:not(:disabled) { filter: brightness(1.06) }`
    // `.btn-destructive:hover:not(:disabled) { filter: brightness(1.06) }`
    // CSS filter 是通道乘法（×1.06 后钳位）→ ColorFilter.matrix 等价。
    if ((widget.variant == GlassButtonVariant.glow ||
            widget.variant == GlassButtonVariant.destructive) &&
        hovered) {
      decorated = ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          1.06, 0, 0, 0, 0, //
          0, 1.06, 0, 0, 0, //
          0, 0, 1.06, 0, 0, //
          0, 0, 0, 1, 0,
        ]),
        child: decorated,
      );
    }

    // .btn-ghost { backdrop-filter: blur(8px) }（auroraqua.css）
    if (widget.variant == GlassButtonVariant.ghost &&
        !GlassConfig.useOpaqueFallback) {
      decorated = Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: ClipRRect(
              borderRadius: rInput,
              child: BackdropFilter(
                // auroraqua.css 100–101（`.btn-ghost`）：`backdrop-filter: blur(8px)`
                // ——**无 saturate**（8px 档三处均为纯 blur；18px/24px 档才带 1.4）。
                filter: GlassConfig.blurOnly(sigma: AylaGlass.blurButton),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          decorated,
        ],
      );
    }

    // :hover { scale: 1.02 } / :active { scale: .98 }（独立 scale，200ms）
    //
    // 优先级：CSS 中 :active 规则写在 :hover 之后且同等特异性 → 按下时 .98
    // 胜出；因此这里必须让 pressed 覆盖 hovered（此前写成
    // `hovered ? 1.02 : pressScale`，鼠标按下时 hovered 恒为 true，
    // 0.98 永远显示不出来 = 「没有按压动画」，实测）。
    final double scaleTarget = _reduceMotion
        ? 1.0
        : (!_enabled
            ? 1.0
            : (_pressed
                ? 0.98
                : (_hovered ? 1.02 : 1.0)));
    final Widget body = AnimatedScale(
      scale: scaleTarget,
      // auroraqua.css 按钮组统一 200ms（覆盖 app.css .btn 的 180ms）
      duration: _reduceMotion ? Duration.zero : AylaDurations.button,
      curve: AylaCurves.auroraqua,
      child: decorated,
    );

    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.semanticLabel ?? widget.label,
      child: Focus(
        // base.css `:focus-visible { outline: 2px solid #F796FF; outline-offset: 2px }`
        onFocusChange: (bool has) => setState(() => _focused = has),
        child: MouseRegion(
          cursor:
              _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onEnter: (_) {
            setState(() => _hovered = true);
            if (animate) _sweep.forward(); // ::after → translateX(120%)
          },
          onExit: (_) {
            setState(() {
              _hovered = false;
              _pressed = false;
            });
            if (animate) _sweep.reverse(); // 移出时 600ms 扫回
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            onTapDown:
                _enabled ? (_) => setState(() => _pressed = true) : null,
            onTapCancel:
                _enabled ? () => setState(() => _pressed = false) : null,
            onTapUp:
                _enabled ? (_) => setState(() => _pressed = false) : null,
            // base.css button:disabled { opacity: .55 }
            child: Opacity(
              opacity: _enabled ? 1 : 0.55,
              child: _focused && _enabled
                  // focus ring：2px 辉光边 + 2px offset（outline-offset）
                  ? Container(
                      decoration: BoxDecoration(
                        borderRadius:
                            BorderRadius.circular(AylaRadii.rInput + 2 + 2),
                        border: Border.all(
                          color: AylaColors.glow500,
                          width: 2,
                        ),
                      ),
                      padding: const EdgeInsets.all(2),
                      child: body,
                    )
                  : body,
            ),
          ),
        ),
      ),
    );
  }
}

/// GlassInput —— 文本输入基类（.field + auroraqua 统一 owner）。
///
/// 材料（app.css .field + auroraqua.css 统一 owner）：
/// 底 `--glass-bg`(.55) + 1px `--glass-border` + 12px 圆角 +
/// `--glass-inset` 内阴影 + `--glass-filter`(blur 24px)；内边距 12×16。
/// focus：边框转 `--glow-500` + `--glow-shadow`（180ms）。
/// placeholder：`--slate-500`。
///
/// 认证上下文（d:§5）：字段描边覆写为 rgba(70,91,146,.3)
/// （白边在浅玻璃上不可见）、min-height 44px。[onGlassBorder] 控制前者。
class GlassInput extends StatefulWidget {
  const GlassInput({
    super.key,
    required this.controller,
    this.hintText,
    this.obscureText = false,
    this.onSubmitted,
    this.autofocus = false,
    this.enabled = true,
    this.minHeight = 44,
    this.textInputAction,
    this.autofillHints,
    this.onGlassBorder = false,
    this.textStyle,
    this.semanticLabel,
    this.focusNode,
    this.invalid = false,
    this.padding,
    this.keyboardType,
    this.inputFormatters,
    this.maxLength,
    this.onChanged,
    this.minLines,
    this.maxLines,
  });

  /// 文本控制器。
  final TextEditingController controller;

  /// 占位文案（--slate-500）。
  final String? hintText;
  /// 密码输入。
  final bool obscureText;

  /// 回车提交。
  final ValueChanged<String>? onSubmitted;

  /// 自动聚焦（web 登录页 userName 字段 autoFocus）。
  final bool autofocus;

  /// 是否可编辑。
  final bool enabled;

  /// 最小高度（认证字段 44px）。
  final double minHeight;

  /// 键盘动作。
  final TextInputAction? textInputAction;

  /// 自动填充提示（web autoComplete="username"）。
  final Iterable<String>? autofillHints;

  /// 是否使用认证卡内描边 rgba(70,91,146,.3)。
  final bool onGlassBorder;

  /// 覆盖文字样式（认证字段继承 .auth-field 的 14px）。
  final TextStyle? textStyle;

  /// 可访问性标签。
  final String? semanticLabel;

  /// 焦点节点。
  final FocusNode? focusNode;

  /// 校验失败态：`.auth-field .field[aria-invalid="true"] { border-color:
  /// var(--destructive) }`（auth.css 74）。
  final bool invalid;

  /// 内部内边距；null = `.field` 基类 `padding: 12px 16px`（app.css 70–73）。
  ///
  /// 覆写场景：`.visibility-selector-groups .field { padding-block: var(--sp-2);
  /// min-height: 40px }`（app.css 186–189）等按位置改内沿的字段。
  final EdgeInsetsGeometry? padding;

  /// 键盘类型（验证码/邮箱等场景，web 用 `inputMode` 表达）。
  final TextInputType? keyboardType;

  /// 输入格式化（例：验证码 `FilteringTextInputFormatter.digitsOnly`
  /// 对应 web 的 `e.target.value.replace(/\D/g, "")`）。
  final List<TextInputFormatter>? inputFormatters;

  /// 最大长度（tsx `maxLength`）。
  final int? maxLength;

  /// 输入变化回调（供调用方按内容启用/禁用提交按钮）。
  final ValueChanged<String>? onChanged;

  /// 文本域最小行数（web `<textarea rows>`；null = 单行输入框）。
  final int? minLines;

  /// 文本域最大行数（web `rows` + `resize: vertical`；null = 单行、>1 可换行）。

  final int? maxLines;

  @override
  State<GlassInput> createState() => _GlassInputState();
}

class _GlassInputState extends State<GlassInput> {
  FocusNode? _ownedFocus;
  bool _focused = false;

  FocusNode get _focus => widget.focusNode ?? (_ownedFocus ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (!mounted) return;
    setState(() => _focused = _focus.hasFocus);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _ownedFocus?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles text = AylaTextStyles.of(context);
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final bool opaque = GlassConfig.useOpaqueFallback;

    // ── `.field` 材料统一 owner：app.css 70–88 + **auroraqua.css 502–510 覆写** ──
    //   :is(.field, .voice-create-input, …) {
    //     background: var(--glass-bg);
    //     background-image: none;               ← 清除背景图（单一材料 owner）
    //     border: 1px solid var(--glass-border);
    //     border-radius: var(--radius-input);
    //     box-shadow: var(--glass-inset);       ← 顶沿 1px 内高光
    //     backdrop-filter: var(--glass-filter); ← **blur(24px) saturate(1.4)**
    //   }
    //   :focus → border-color: --glow-500; box-shadow: --glow-shadow
    //   auth.css 73–78：认证上下文 min-height 44 / 描边 rgba(70,91,146,.3) /
    //     focus 仍走辉光边；auth.css 74：`[aria-invalid="true"]` → --destructive
    final Color border = widget.invalid
        // auth.css 74：`[aria-invalid="true"]` → --destructive
        ? AylaColors.destructive
        : (_focused
            ? AylaColors.glow500
            : (widget.onGlassBorder
                ? AylaColors.fieldBorderOnGlass
                : AylaColors.glassBorder));

    final BorderRadius rInput =
        BorderRadius.all(Radius.circular(AylaRadii.rInput));

    // 卡面（底 + 边 + 圆角）。**不含阴影/内高光**——它们按 CSS 语义分层。
    final Widget face = AnimatedContainer(
      duration: reduceMotion ? Duration.zero : AylaDurations.fast,
      curve: AylaCurves.easeOut,
      constraints: BoxConstraints(minHeight: widget.minHeight),
      padding: widget.padding ??
          const EdgeInsets.symmetric(
            horizontal: AylaSpacing.sp4, // .field: padding 12px 16px
            vertical: AylaSpacing.sp3,
          ),
      decoration: BoxDecoration(
        // background: var(--glass-bg)（降级时 --surface，auroraqua 526–531）
        color: GlassConfig.resolveBackground(strong: false),
        // background-image: none —— 不叠任何渐变（清除背景图语义）
        borderRadius: rInput,
        border: Border.all(color: border),
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: _focus,
        enabled: widget.enabled,
        obscureText: widget.obscureText,
        autofocus: widget.autofocus,
        textInputAction: widget.textInputAction,
        autofillHints: widget.autofillHints,
        onSubmitted: widget.onSubmitted,
        // 新增能力（供验证码/邮箱等场景；web 用 inputMode + maxLength +
        // `replace(/\D/g,"")` 表达）
        keyboardType: widget.keyboardType,
        inputFormatters: widget.inputFormatters,
        maxLength: widget.maxLength,
        onChanged: widget.onChanged,
        minLines: widget.minLines,
        // ⚠️ TextField 的 maxLines 语义：**null = 不限行数**（不是默认单行）——
        // 直接透传 null 会把所有单行字段变成多行（实测：隐私设置校验/画布冒烟全崩）。
        // 故未显式传时统一回落 1（= TextField 默认单行）。
        maxLines: widget.maxLines ?? 1,
        cursorColor: AylaColors.indigo700,
        style: widget.textStyle ??
            text.body.copyWith(color: AylaColors.textPrimary),
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          contentPadding: EdgeInsets.zero,
          hintText: widget.hintText,
          hintStyle: text.body.copyWith(color: AylaColors.textSecondary),
        ),
      ),
    );

    // 层序（对齐 CSS）：
    //   ① backdrop-filter（blur 24 + saturate 1.4）——只模糊字段背后的内容
    //   ② --glass-inset 顶沿 1px 内高光（不参与裁剪）
    //   ③ face（半透明底 + 亮边）
    Widget field = Stack(
      children: <Widget>[
        if (!opaque)
          Positioned.fill(
            child: ClipRRect(
              borderRadius: rInput,
              child: BackdropFilter(
                // auroraqua.css 507：`.field { backdrop-filter: var(--glass-filter) }`
                // = `blur(24px) saturate(1.4)`（tokens.css 76）
                filter: GlassConfig.backdropFilter(sigma: AylaGlass.blurCard),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        // `:focus → box-shadow: var(--glow-shadow)`（auroraqua.css 513–518）——
        // 只画形状之外 + 200ms 淡入淡出；2026-09-20 审查 R2：原裸 boxShadow 会把
        // `.45` 粉辉光铺进 `.55` 玻璃内部（聚焦时输入框内部发粉）。
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              duration: AylaDurations.button,
              curve: AylaCurves.auroraqua,
              opacity: _focused ? 1.0 : 0.0,
              child: AylaGlassShadow.ring(
                radius: rInput,
                shadows: AylaShadows.glow,
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) {
                return DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: rInput,
                    gradient: AylaInset.topHighlight(c.maxHeight),
                  ),
                );
              },
            ),
          ),
        ),
        face,
      ],
    );

    return Semantics(
      textField: true,
      label: widget.semanticLabel ?? widget.hintText,
      child: field,
    );
  }
}

// ======================= 预览 =======================

/// GlassCard 静态 + 可交互。
@Preview(
  group: 'Glass',
  name: 'GlassCard 静态 + 可交互',
  size: Size(420, 240),
  wrapper: previewTheme,
)
Widget glassCardPreview() {
  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp6),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        GlassCard(
          child: Text('静态玻璃卡', style: AylaTextStyles.light.cardTitle),
        ),
        const SizedBox(height: AylaSpacing.sp4),
        GlassCard(
          interactive: true,
          onTap: () {},
          child: Text('可交互（hover 上浮 2px）', style: AylaTextStyles.light.body),
        ),
      ],
    ),
  );
}

/// GlassButton 三类 + disabled。
@Preview(
  group: 'Glass',
  name: 'GlassButton primary/glow/ghost/disabled',
  size: Size(420, 300),
  wrapper: previewTheme,
)
Widget glassButtonPreview() {
  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp6),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        GlassButton(label: '登录', onPressed: () {}),
        const SizedBox(height: AylaSpacing.sp3),
        GlassButton(
          label: '登录',
          variant: GlassButtonVariant.glow,
          onPressed: () {},
        ),
        const SizedBox(height: AylaSpacing.sp3),
        GlassButton(
          label: '注册',
          variant: GlassButtonVariant.ghost,
          minHeight: 44,
          onPressed: () {},
        ),
        const SizedBox(height: AylaSpacing.sp3),
        GlassButton(label: '登录中…', onPressed: null),
      ],
    ),
  );
}

/// GlassInput 常态 / focus。
@Preview(
  group: 'Glass',
  name: 'GlassInput 常态 + focus',
  size: Size(420, 260),
  wrapper: previewTheme,
)
Widget glassInputPreview() => const _GlassInputSample();

class _GlassInputSample extends StatefulWidget {
  const _GlassInputSample();

  @override
  State<_GlassInputSample> createState() => _GlassInputSampleState();
}

class _GlassInputSampleState extends State<_GlassInputSample> {
  final TextEditingController _a = TextEditingController();
  final TextEditingController _b = TextEditingController(text: '123');

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AylaSpacing.sp6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          GlassInput(controller: _a, hintText: 'hint = slate-500'),
          const SizedBox(height: AylaSpacing.sp4),
          GlassInput(controller: _b, autofocus: true),
        ],
      ),
    );
  }
}
