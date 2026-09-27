/// capsule tag（自 `primitives.dart` 拆出：一文件一件）。
///
/// 事实源与逐条对照见 `docs/flutter/17-组件文件头归档（整理前原文）.md` 的 `primitives.dart` 一节
/// 与各件的 `///` 头注。
///
/// ## 公开面
/// `AylaCapsuleTone` · `AylaSourceTag` · `AylaCapsuleTag`

library;

import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';

/// 胶囊标签（design.md §4 Tags/Badges + §12.9.1 Micro Tag）。
///
/// 默认（Micro Tag）：`--sakura-300` 底 + `--grape-700` 字 + Fredoka 11/500
/// + ls .8 + padding 6/14 + radius-pill（d:§3 Micro Tag / auth.css 203–212
/// 的特性胶囊同规格）。[tone] 提供其余语义色板（ice / glow / pink / surface）。
enum AylaCapsuleTone {
  /// sakura-300 底 + grape-700 字（默认，Micro Tag）
  sakura,

  /// ice-100 底 + text-primary 字（历史搜索 chips）
  ice,

  /// glass-bg 底 + text-primary 字（玻璃胶囊）
  glass,

  /// pink-500 底 + surface 字（LIVE 徽标）
  pink,

  /// indigo-700 底 + surface 字（实底强调）
  indigo,
}

/// 来源标签（可见性标签）——**语音 / 直播 / 帖子三域统一复用**的胶囊。
///
/// 裁决：
/// > 「这个标签……语音、直播、帖子都应该统一复用这个，统一为 web 界面的粉色，
/// > web 界面的帖子标签灰色视为错误。」
///
/// 事实源（统一后的度量取 **live 徽章档**）：
/// ```
/// app.css 3371–3377   .live-badge { display: inline-block; padding: 2px var(--sp-2);
///                     border-radius: var(--radius-pill); font-size: 12px; font-family: --font-utility }
/// live.css 486–493    .live-badge-source { background: --sakura-300; color: --grape-700;
///                     max-width: 12ch; overflow: hidden; text-overflow: ellipsis; white-space: nowrap }
/// ```
/// 两处都**不声明 font-weight / letter-spacing / line-height** ⇒ 全部继承 body
/// （400 / 0 / 1.55）。
///
/// ⚠️ 被本件取代的三份旧实现（三域规格原本各不相同，统一后不再使用）：
/// - `.voice-source-tag`（voice.css 471–485）：Fredoka 11 / ls .8 / padding 0×8；
/// - `.post-card-tag`（posts.css 68–76）：utility 11 / w600 / **ice-100 灰底 + `--ice-600`**
///   —— `--ice-600` 在 tokens.css **零定义**（同 `--glass-bg-hover` 那类），该声明整条作废、
///   字色继承 ⇒ 实渲染就是灰底。用户判为错误，**不复刻**；
/// - `.live-badge.live-badge-source`：本身就是本档（保持）。
///
/// 容器由调用方决定（web 亦然）：live 卡 / 语音卡走 [AylaScrollingTags] 横向滚动，
/// 帖子卡走 `flex-wrap` 换行平铺（posts.css 62–66）——**只统一 chip，不统一容器**。
class AylaSourceTag extends StatelessWidget {
  const AylaSourceTag(
    this.label, {
    super.key,
    this.maxWidth,
    this.semanticLabel,
  });

  /// 标签文案（「公开」「好友」、白名单群名…，见 `getVisibilityLabels`）。
  final String label;

  /// 宽度上限（web 默认 `12ch`；各头部上下文另有 10ch/8ch 覆写）。null = 用默认 12ch。
  final double? maxWidth;

  /// 可访问性标签（默认同文案）。
  final String? semanticLabel;

  /// `.live-badge` 的字级（12px / utility）下 `1ch` 的实测宽度。
  static double chWidth(AylaTextStyles style) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: '0',
        style: TextStyle(
          fontFamily: AylaFonts.utility,
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: 12,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return painter.width;
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth ?? chWidth(t) * 12),
      child: AylaCapsuleTag(
        label,
        tone: AylaCapsuleTone.sakura, // sakura-300 底 + grape-700 字
        padding: const EdgeInsets.symmetric(
          horizontal: AylaSpacing.sp2, // padding: 2px var(--sp-2)
          vertical: 2,
        ),
        fontFamily: AylaFonts.utility, // --font-utility
        fontSize: 12,
        fontWeight: FontWeight.w400, // 未声明 ⇒ 继承 body
        letterSpacing: 0, // 未声明 ⇒ 0
        textHeight: t.body.height, // 未声明 ⇒ 继承 body 行高（1.55）
        semanticLabel: semanticLabel,
      ),
    );
  }
}

/// 胶囊标签（尺寸/圆角/字级按 [AylaCapsuleTone] 与调用方给定）。
///
/// ⚠️ **事实源边界（2026-09-19 审查）**：web 里**没有统一的胶囊基类**，
/// 各处胶囊是各自独立的类，规格并不一致：
///
/// | tone | web 真实来源 | 底 / 字 | 盒模型 |
/// |---|---|---|---|
/// | [AylaCapsuleTone.sakura] | `auth.css 203–212` `.auth-intro-feature` | sakura-300 / grape-700 | padding 6×14、12px/500、ls .4 |
/// | [AylaCapsuleTone.ice] | `search.css 19–25` `.search-chip` | ice-100 / text-primary | padding **4×12**、**13px** |
/// | [AylaCapsuleTone.pink] | `live.css 811–814` `.live-badge-live` | pink-500 / surface | 随 `.live-badge` 基类 |
/// | [AylaCapsuleTone.glass] | **暂无精确对应**（就近：`--glass-bg` + `--glass-border`） | — | — |
/// | [AylaCapsuleTone.indigo] | **暂无精确对应**（就近：`--indigo-700` 实底） | — | — |
///
/// 本组件**当前实现的是 [AylaCapsuleTone.sakura] 的规格**；其余 tone 仅共享色板，
/// **盒模型与字级需在各组件落地时按各自 CSS 覆写**，不要用本组件的固定值套用
/// （否则 ice chip 偏大、live badge 偏离）。
class AylaCapsuleTag extends StatelessWidget {
  const AylaCapsuleTag(
    this.label, {
    super.key,
    this.tone = AylaCapsuleTone.sakura,
    this.icon,
    this.semanticLabel,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
    this.fontFamily = AylaFonts.display,
    this.fontSize = 12,
    this.fontWeight = FontWeight.w500,
    this.letterSpacing = 0.4,
    this.textHeight,
  });

  /// 文案。
  final String label;

  /// 色板。
  final AylaCapsuleTone tone;

  /// 可选前置图标（12–14px 线性图标）。
  final Widget? icon;

  /// 可访问性标签。
  final String? semanticLabel;

  /// 内边距（默认 sakura 档 14×6；其他站点按各自 CSS 覆写）。
  final EdgeInsetsGeometry padding;

  /// 字体族（默认 Fredoka；`.post-card-tag` 用 Space Grotesk）。
  final String fontFamily;

  /// 字号（默认 12；`.post-card-tag` 11、`.search-chip` 13）。
  final double fontSize;

  /// 字重（默认 w500；`.post-card-tag` 600）。
  final FontWeight fontWeight;

  /// 字距（默认 0.4；`.post-card-tag` 未声明 → 0）。
  final double letterSpacing;

  /// 行高倍数（null = 字体默认；`.post-card-tag` 继承 body 的 1.55）。
  final double? textHeight;

  @override
  Widget build(BuildContext context) {
    late final Color bg;
    late final Color fg;
    late final Border? border;
    switch (tone) {
      case AylaCapsuleTone.sakura:
        bg = AylaColors.sakura300;
        fg = AylaColors.grape700;
        border = null;
      case AylaCapsuleTone.ice:
        bg = AylaColors.ice100; // 历史搜索 chips
        fg = AylaColors.textPrimary;
        border = null;
      case AylaCapsuleTone.glass:
        bg = AylaGlassConfig.resolveBackground(strong: false);
        fg = AylaColors.textPrimary;
        border = Border.all(color: AylaColors.glassBorder);
      case AylaCapsuleTone.pink:
        bg = AylaColors.pink500; // LIVE 徽标
        fg = AylaColors.surface;
        border = null;
      case AylaCapsuleTone.indigo:
        bg = AylaColors.indigo700;
        fg = AylaColors.surface;
        border = null;
    }

    return Semantics(
      label: semanticLabel ?? label,
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: AylaRadii.pill,
          border: border,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              IconTheme(data: IconThemeData(color: fg, size: 12), child: icon!),
              const SizedBox(width: AylaSpacing.sp1),
            ],
            // ⚠️ 必须用 Flexible 包住：胶囊放进窄容器（Wrap 的某一列 / 卡片右组）时，
            // 裸 Text 会以固有宽度撑破内层 Row（实测 `RenderFlex overflowed by 12px`）。
            // web 的胶囊是 inline 元素、由容器决定换行/裁剪，这里等价表达为「收缩 + 省略号」。
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: fontFamily,
                  fontFamilyFallback: AylaFonts.cjkFallback,
                  fontSize: fontSize,
                  fontWeight: fontWeight,
                  letterSpacing: letterSpacing,
                  height: textHeight,
                  color: fg,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
