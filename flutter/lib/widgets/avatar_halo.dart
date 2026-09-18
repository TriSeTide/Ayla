/// 在线光环（Presence Halo）—— Ayla 的签名元素（app.css 281–380 行 / d:§6）。
///
/// 事实源：
/// - `.avatar-halo`：padding 2.5px + `--ring-online` 背景
///   = `conic-gradient(from 210deg, #9DBFE6, #F9B0FF, #F796FF, #9DBFE6)`
///   （t:--ring-online；Flutter 无 conic-gradient → SweepGradient，
///   换算：CSS 角 = Flutter 角 + 90°，起点 210° → Flutter 120°）
/// - `.avatar-halo.is-offline`：光环褪为 `--ice-100` 灰环
/// - `.avatar-halo.is-elysia`：`halo-breathe` 3.2s ease-in-out 无限
///   （base.css：0/100% = 0 0 8px rgba(247,150,255,.5)；
///   50% = 0 0 8px .9 + 0 0 16px .45）
/// - `.avatar-core-user`：135deg ice-500→ice-300 渐变 + indigo-700 字
/// - `.avatar-core-elysia`：135deg sakura-100→sakura-300 + grape-700 字
///   （爱莉专属，不可复用于普通用户；d:§2/§6）
/// - reduced-motion：静态 `0 0 8px rgba(247,150,255,.5)`（base.css 375–380 行）
///
/// 在线状态 = 光环 + 文字标签双通道（d:§10），光环只表达运行事实。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../theme/css_gradient.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';

/// 头像形状。
enum AvatarCore {
  /// 普通用户：ice 渐变底 + indigo 字
  user,

  /// 爱莉：sakura 渐变底 + grape 字 + 呼吸辉光（全应用唯一）
  elysia,
}

/// 在线光环头像。
///
/// [size] 为**头像本体直径**（光环外径 = size + 2.5×2，即环宽 2.5px 在
/// 头像外圈）；[online] 为运行事实（false = 离线灰环）；[core] 决定底色字色。
class AvatarHalo extends StatefulWidget {
  const AvatarHalo({
    super.key,
    required this.label,
    this.size = 40,
    this.online = false,
    this.core = AvatarCore.user,
    this.resourceUrl,
    this.onTap,
    this.semanticLabel,
  });

  /// 头像内容文字（无图时的首字/名字；有图时作语义标签）。
  final String label;

  /// 头像本体直径（web CSS px；Windows 125% 下 1:1 逻辑 px）。
  final double size;

  /// 在线状态（false = --ice-100 灰环）。
  final bool online;

  /// 底色/字色形态（爱莉专属 [AvatarCore.elysia]）。
  final AvatarCore core;

  /// 头像图片 URL（带签名媒体需走 ResourceImage，暂用网络图；null = 文字首字）。
  final String? resourceUrl;

  /// 点击回调（.avatar-halo-btn：可点击头像，hover brightness 1.06）。
  final VoidCallback? onTap;

  /// 可访问性标签（默认 [label] 后附在线状态，双通道语义）。
  final String? semanticLabel;

  static const double haloWidth = 2.5;

  @override
  State<AvatarHalo> createState() => _AvatarHaloState();
}

class _AvatarHaloState extends State<AvatarHalo>
    with SingleTickerProviderStateMixin {
  /// 爱莉呼吸（3.2s ease-in-out 循环）：0 ↔ π 正弦驱动两层辉光。
  late final AnimationController _breathe = AnimationController(
    vsync: this,
    duration: AylaDurations.breathe,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery 依赖只能在 didChangeDependencies 之后读取（initState 里
    // 读取会触发 framework 断言）。
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final bool shouldBreathe = widget.online &&
        widget.core == AvatarCore.elysia &&
        !reduceMotion;
    if (shouldBreathe && !_breathe.isAnimating) {
      _breathe.repeat();
    } else if (!shouldBreathe && _breathe.isAnimating) {
      _breathe.stop();
      _breathe.value = 0;
    }
  }

  @override
  void didUpdateWidget(covariant AvatarHalo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.online != oldWidget.online ||
        widget.core != oldWidget.core) {
      didChangeDependencies();
    }
  }

  @override
  void dispose() {
    _breathe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double size = widget.size;
    // 光环底色：CSS `conic-gradient(from 210deg, #9DBFE6, #F9B0FF,
    // #F796FF, #9DBFE6)`（t:--ring-online）的 Flutter 等价。
    //
    // 关键：SweepGradient 的采样角被归一化到 [0, 2π)，若渐变区间不从 0
    // 开始（如 startAngle=120°），落在区间外的角度会 clamp 成纯色，与
    // 渐变区末端在物理某处硬切（实测：3 点方向 glow↔ice 突变）。
    // 正确做法：区间 = [0, 2π) 全覆盖 + **首尾同色** 闭合，并把相位换算
    // 对齐 CSS（Flutter 角 = CSS 角 − 90°，0° 在 3 点方向）：
    //   CSS:  ice@210°(7点)  sakura@330°(11点)  glow@90°(3点)  ice@210°
    //   Fla:  glow@0°(3点)   ice@120°(7点)      sakura@240°(11点)
    // → colors = [glow, ice, sakura, glow]（首尾同色，环闭合无缝）。
    final Gradient ringGradient = widget.online
        ? const SweepGradient(
            startAngle: 0,
            endAngle: math.pi * 2,
            colors: <Color>[
              AylaColors.glow500,
              AylaColors.ice500,
              AylaColors.sakura300,
              AylaColors.glow500,
            ],
          )
        : const LinearGradient(colors: <Color>[
            AylaColors.ice100,
            AylaColors.ice100,
          ]);

    // 头像本体：core 渐变底 + Fredoka 500 字（app.css .avatar-core-*）
    final List<Color> coreColors;
    final Color coreColor;
    switch (widget.core) {
      case AvatarCore.user:
        coreColors = AylaGradients.avatarCoreUser;
        coreColor = AylaColors.indigo700;
      case AvatarCore.elysia:
        coreColors = AylaGradients.avatarCoreElysia;
        coreColor = AylaColors.grape700;
    }

    final Widget core = ClipOval(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: cssLinearGradient(angleDeg: 135, colors: coreColors),
        ),
        child: Center(
          child: Text(
            // 无图时取名字首字（web Avatar 组件同语义）
            widget.resourceUrl == null && widget.label.isNotEmpty
                ? widget.label.characters.first
                : '',
            style: TextStyle(
              fontFamily: AylaFonts.display,
              fontFamilyFallback: AylaFonts.cjkFallback,
              fontWeight: FontWeight.w500,
              fontSize: size * 0.42,
              color: coreColor,
            ),
          ),
        ),
      ),
    );

    // 无图时 core 撑满本体；有图时图在上、字在下（语义层）
    final Widget coreLayer = widget.resourceUrl == null
        ? core
        : Stack(
            fit: StackFit.expand,
            children: <Widget>[
              // 图片加载失败回退文字首字
              ClipOval(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient:
                        cssLinearGradient(angleDeg: 135, colors: coreColors),
                  ),
                  child: Image.network(
                    widget.resourceUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Center(
                      child: Text(
                        widget.label.isEmpty ? '?' : widget.label.characters.first,
                        style: TextStyle(
                          fontFamily: AylaFonts.display,
                          fontFamilyFallback: AylaFonts.cjkFallback,
                          fontWeight: FontWeight.w500,
                          fontSize: size * 0.42,
                          color: coreColor,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );

    // 外层：2.5px 光环 +（爱莉在线时）呼吸辉光
    Widget halo = Padding(
      padding: const EdgeInsets.all(AvatarHalo.haloWidth),
      child: SizedBox(
        width: size,
        height: size,
        child: coreLayer,
      ),
    );

    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final bool breathe = widget.online &&
        widget.core == AvatarCore.elysia &&
        !reduceMotion;

    if (breathe) {
      halo = AnimatedBuilder(
        animation: _breathe,
        builder: (BuildContext context, Widget? child) {
          // sin(π·t)：0→0.5 上升、0.5→1 回落，与 CSS 0/100↔50 同构
          final double wave =
              math.sin(math.pi * _breathe.value).clamp(0.0, 1.0).toDouble();
          return DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: AylaColors.haloBreathSoft
                      .withValues(alpha: 0.5 + 0.4 * wave),
                  blurRadius: 8,
                ),
                BoxShadow(
                  color: AylaColors.haloBreathOuter
                      .withValues(alpha: 0.45 * wave),
                  blurRadius: 16,
                ),
              ],
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: ringGradient,
              ),
              child: child,
            ),
          );
        },
        child: halo,
      );
    } else {
      halo = DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: ringGradient,
          // reduced-motion：静态 0 0 8px rgba(247,150,255,.5)
          boxShadow: widget.online &&
                  widget.core == AvatarCore.elysia
              ? const <BoxShadow>[
                  BoxShadow(
                    color: AylaColors.haloBreathSoft,
                    blurRadius: 8,
                  ),
                ]
              : null,
        ),
        child: halo,
      );
    }

    final String stateLabel = widget.online ? '在线' : '离线';
    final Widget result = Semantics(
      image: true,
      label:
          '${widget.semanticLabel ?? widget.label}，$stateLabel', // 光环+文字双通道
      child: halo,
    );

    if (widget.onTap == null) return result;

    // .avatar-halo-btn：可点击头像，hover brightness(1.06)、focus-visible 辉光环
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: _hovered
            ? ColorFiltered(
                colorFilter: const ColorFilter.matrix(<double>[
                  1.06, 0, 0, 0, 0, //
                  0, 1.06, 0, 0, 0, //
                  0, 0, 1.06, 0, 0, //
                  0, 0, 0, 1, 0,
                ]),
                child: result,
              )
            : result,
      ),
    );
  }

  bool _hovered = false;
}

// ======================= 预览 =======================

/// AvatarHalo 在线/离线/爱莉（呼吸）。
@Preview(
  group: 'Widgets',
  name: 'AvatarHalo 在线/离线/爱莉',
  size: Size(420, 200),
  wrapper: previewTheme,
)
Widget avatarHaloPreview() {
  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp6),
    child: Wrap(
      spacing: AylaSpacing.sp6,
      runSpacing: AylaSpacing.sp6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        const AvatarHalo(label: '爱莉', size: 40, online: true, core: AvatarCore.elysia),
        const AvatarHalo(label: '在线', size: 40, online: true),
        const AvatarHalo(label: '离线', size: 40),
        const AvatarHalo(label: '群', size: 24, online: true),
      ],
    ),
  );
}
