/// Ayla 主题：九级排版阶梯 + 主题装配。
///
/// 事实源：`Ayla/docs/design.md` §3 Hierarchy（大小/字重/行高/字距逐条对应）
/// 与 `tokens.css` `--font-*`。CJK 一律走 [AylaFonts.cjkFallback] 回退链
/// （Fredoka/Nunito 只覆盖拉丁与数字，中文由系统圆体承接）。
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Ayla 九级排版（d:§3）。
///
/// 用法：`AylaTextStyles.of(context)`（主题内取）或 `AylaTextStyles.light`
/// （无 BuildContext 的预览宿主等场景）。
@immutable
class AylaTextStyles extends ThemeExtension<AylaTextStyles> {
  const AylaTextStyles({
    required this.displayHero,
    required this.pageTitle,
    required this.cardTitle,
    required this.body,
    required this.bodyStrong,
    required this.label,
    required this.caption,
    required this.timestamp,
    required this.microTag,
  });

  /// Display Hero：Fredoka 40/600，lh 1.15，ls -0.5
  final TextStyle displayHero;
  /// Page Title：Fredoka 28/600，lh 1.2，ls -0.3
  final TextStyle pageTitle;
  /// Card / Section Title：Fredoka 20/500，lh 1.25
  final TextStyle cardTitle;
  /// Bubble / Body：Nunito 15/400，lh 1.55
  final TextStyle body;
  /// Body Strong：Nunito 15/700，lh 1.55
  final TextStyle bodyStrong;
  /// Label / Button：Nunito 14/700，lh 1.3，ls .2
  final TextStyle label;
  /// Caption：Nunito 13/400，lh 1.45
  final TextStyle caption;
  /// Timestamp / Data：Space Grotesk 12/400，lh 1.4，ls .3
  final TextStyle timestamp;
  /// Micro Tag：Fredoka 11/500，lh 1.2，ls .8
  final TextStyle microTag;

  static final AylaTextStyles light = _build(
    colorScheme: const ColorScheme.light(),
  );

  /// 从 [BuildContext] 取当前主题内的 Ayla 排版。
  static AylaTextStyles of(BuildContext context) =>
      Theme.of(context).extension<AylaTextStyles>() ?? light;

  static AylaTextStyles _build({required ColorScheme colorScheme}) {
    const TextStyle displayBase = TextStyle(
      fontFamily: AylaFonts.display,
      fontFamilyFallback: AylaFonts.cjkFallback,
    );
    const TextStyle bodyBase = TextStyle(
      fontFamily: AylaFonts.body,
      fontFamilyFallback: AylaFonts.cjkFallback,
    );
    const TextStyle utilityBase = TextStyle(
      fontFamily: AylaFonts.utility,
      fontFamilyFallback: AylaFonts.cjkFallback,
    );

    final Color primary = colorScheme.brightness == Brightness.dark
        ? Colors.white
        : AylaColors.textPrimary;

    return AylaTextStyles(
      displayHero: displayBase.copyWith(
        fontSize: 40,
        fontWeight: FontWeight.w600,
        height: 1.15,
        letterSpacing: -0.5,
        color: primary,
      ),
      pageTitle: displayBase.copyWith(
        fontSize: 28,
        fontWeight: FontWeight.w600,
        height: 1.2,
        letterSpacing: -0.3,
        color: primary,
      ),
      cardTitle: displayBase.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w500,
        height: 1.25,
        color: primary,
      ),
      body: bodyBase.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        height: 1.55,
        color: primary,
      ),
      bodyStrong: bodyBase.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w700,
        height: 1.55,
        color: primary,
      ),
      label: bodyBase.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        height: 1.3,
        letterSpacing: 0.2,
        color: primary,
      ),
      caption: bodyBase.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        height: 1.45,
        color: primary,
      ),
      timestamp: utilityBase.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        height: 1.4,
        letterSpacing: 0.3,
        color: primary,
      ),
      microTag: displayBase.copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        height: 1.2,
        letterSpacing: 0.8,
        color: primary,
      ),
    );
  }

  @override
  AylaTextStyles copyWith({
    TextStyle? displayHero,
    TextStyle? pageTitle,
    TextStyle? cardTitle,
    TextStyle? body,
    TextStyle? bodyStrong,
    TextStyle? label,
    TextStyle? caption,
    TextStyle? timestamp,
    TextStyle? microTag,
  }) {
    return AylaTextStyles(
      displayHero: displayHero ?? this.displayHero,
      pageTitle: pageTitle ?? this.pageTitle,
      cardTitle: cardTitle ?? this.cardTitle,
      body: body ?? this.body,
      bodyStrong: bodyStrong ?? this.bodyStrong,
      label: label ?? this.label,
      caption: caption ?? this.caption,
      timestamp: timestamp ?? this.timestamp,
      microTag: microTag ?? this.microTag,
    );
  }

  @override
  AylaTextStyles lerp(covariant AylaTextStyles? other, double t) {
    if (other == null) return this;
    return AylaTextStyles(
      displayHero: TextStyle.lerp(displayHero, other.displayHero, t)!,
      pageTitle: TextStyle.lerp(pageTitle, other.pageTitle, t)!,
      cardTitle: TextStyle.lerp(cardTitle, other.cardTitle, t)!,
      body: TextStyle.lerp(body, other.body, t)!,
      bodyStrong: TextStyle.lerp(bodyStrong, other.bodyStrong, t)!,
      label: TextStyle.lerp(label, other.label, t)!,
      caption: TextStyle.lerp(caption, other.caption, t)!,
      timestamp: TextStyle.lerp(timestamp, other.timestamp, t)!,
      microTag: TextStyle.lerp(microTag, other.microTag, t)!,
    );
  }
}

/// 装配 Ayla 主题（浅色玻璃极光语境，全站唯一）。
///
/// 关键决策（来源见各字段注释）：
/// - 文字色：正文/标题一律 [AylaColors.textPrimary]（indigo-700，d:§2）；
/// - 选中项胶囊底：`--nav-active-bg`（[AylaGradients.navActive]，d:§4 Nav）；
/// - 焦点环：2px [AylaColors.glow500] + 2px offset（t:--focus-ring，d:§10）；
/// - 触达目标：组件层保证 ≥40px（推荐 44，d:§10）。
ThemeData buildAylaTheme() {
  const ColorScheme scheme = ColorScheme.light(
    primary: AylaColors.indigo700,
    onPrimary: AylaColors.surface,
    secondary: AylaColors.sakura300,
    onSecondary: AylaColors.grape700,
    error: AylaColors.destructive,
    surface: AylaColors.surface,
    onSurface: AylaColors.textPrimary,
  );

  final ThemeData base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Colors.transparent,
  );

  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: AylaColors.textPrimary,
      displayColor: AylaColors.textPrimary,
    ),
    extensions: <ThemeExtension<AylaTextStyles>>[AylaTextStyles.light],
    // 全局 focus 环（d:§10：辉光式 focus ring，禁无替代 outline:none）
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    focusColor: Colors.transparent,
  );
}
