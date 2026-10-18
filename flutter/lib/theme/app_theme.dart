/// Ayla 主题：九级排版阶梯 + 主题装配。
///
/// 事实源：`Ayla/docs/design.md` §3 Hierarchy（大小/字重/行高/字距逐条对应）
/// 与 `tokens.css` `--font-*`。CJK 一律走 [AylaFonts.cjkFallback] 回退链
/// （Fredoka/Nunito 只覆盖拉丁与数字，中文由系统圆体承接）。
///
/// ## 公开面
/// `AylaTextStyles`

library;

import 'package:flutter/material.dart';

import 'page_transitions.dart' show AylaPageTransitionsBuilder;
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
    // ⚠️ **必须显式应用字体族**（2026-10-18 用户实报「字体错误的不止一处」的根因）：
    // 此前这里只 `apply` 了**颜色**（bodyColor/displayColor），没给字体族 ——
    // 于是所有**未显式写 `fontFamily`** 的 `Text`（如 `TextButton` 内的裸 `Text('加载更早消息')`）
    // 全部落到 Material 默认的 Roboto / 平台字体，且**不带 CJK 回退链**，
    // 视觉上与本库另一套 Fredoka/Nunito 完全不同（用户截图：历史加载按钮、分享卡标题等）。
    //
    // 修法 = 与 web 的 `body { font-family: var(--font-body) }` 对齐：把 body 族 + CJK 回退
    // 写进 **全局 textTheme 的每一个样式**，这样任何"忘了写字体"的 Text 也会继承到正字。
    // 仍推荐显式用 `AylaTextStyles.of(context)`（字号/字重逐级不同），此处只兜底字体族。
    textTheme: base.textTheme
        .apply(
          bodyColor: AylaColors.textPrimary,
          displayColor: AylaColors.textPrimary,
          fontFamily: AylaFonts.body,
          fontFamilyFallback: AylaFonts.cjkFallback,
        ),
    // ⚠️ **必须显式设置 `iconTheme`**：SDK 的 `ThemeData` 在缺省时会兜底注入
    // `IconThemeData(color: kDefaultIconDarkColor)`（= `Color(0xDD000000)`，肉眼即纯黑，
    // theme_data.dart:526），而 `Theme` 会把它注入整棵树（theme.dart:147）。
    // `AylaIcon` 的颜色解析顺序是「显式 color → 祖先 IconTheme → textPrimary」
    // （app_icons.dart:77–79），于是**所有未显式传色的图标**都会停在第 2 级、取到黑色，
    // `textPrimary` 永远轮不到 —— 2026-09-20 用户发现「分享图标是纯黑」，违反 design。
    // web 侧 SVG 用 `currentColor` 继承 `body { color: var(--text-primary) }`，此处对齐。
    iconTheme: const IconThemeData(color: AylaColors.textPrimary),
    extensions: <ThemeExtension<AylaTextStyles>>[AylaTextStyles.light],
    // ⚠️ **当前：路由切换一律「直通」—— 不做任何页面切换动画**
    // （2026-09-28 用户裁决：「先把所有页面切换动画都删掉，目前只有个人主页页面有动画」）。
    //
    // 两条理由，都实测过：
    // 1. 平台默认转场（Windows/Linux = `FadeUpwardsPageTransitionsBuilder`）会与任何自研转场
    //    **叠加** ⇒ 位移与白屏时间翻倍；web 侧 React Router 本身不做转场（唯一 owner 是
    //    `PageTransition.tsx`），所以平台默认必须先让位；
    // 2. web 的 `AnimatePresence mode="sync"` 语义是「**新旧页并存、各播各的**」⇒ 换页时
    //    能看见两页内容叠几帧。（2026-10-17 订正：此前写「当前页面绝大多数还是占位页
    //    PendingPage」已过时 —— 24 条路由全是真实页面。）用户当时要求先全删。
    //
    // 📌 **web 侧通用转场的真实覆盖范围**（逐行核对 `AppShell.tsx:61–74` 的 `panelOwned`）：
    //    22 条路由里**只有 `/group` 与 `/posts/mine` 两条**会播整页转场；其余全部 `panelOwned`
    //    （`initial` 即终值 + `duration: 0`）—— 动画由**页面内部**承担（群场景侧栏/面板、
    //    `/profile` 两列、消息中心的 ConversationTransition…）。详表见 `page_transitions.dart` 文件头。
    //    （2026-10-17 订正：此前写「这两条在 Flutter 侧都还是占位页」已过时 —— /group 与
    //    /posts/mine 均已交付真实页面；但换页动画 owner 仍按用户裁决留在页面自己。）
    //
    // ⇒ **换页动画的 owner 交回「页面自己」**：需要入场编排的页面自行挂
    //    `AylaRevealItem`（范本 = `ProfilePage` / `UserProfilePage` 的两列面板入场，
    //    事实源 `auroraqua.css:323–332`：`.profile-side` 左入 −20 / `.profile-main` 右入 +20）。
    //
    // 📌 **将来要恢复路由级转场时**（页面做齐、且确实需要整页过渡）：
    //    `theme/page_transitions.dart` 里的 `AylaPageTransitionsBuilder` 已经写好了 web 的
    //    全部分档（panelOwned / 群页 / 搜索页 / `/login` `/register` 无转场 / reduced），
    //    把上面六个平台的 builder 换成它即可；注意它必须取代平台默认、不能与之并存。
    //    影响面：全库 `Navigator.push` / `MaterialPageRoute` **零命中**，弹层一律走 Overlay
    //    ⇒ 只作用于 go_router 的 Page。
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.android: AylaPageTransitionsBuilder(),
        TargetPlatform.iOS: AylaPageTransitionsBuilder(),
        TargetPlatform.macOS: AylaPageTransitionsBuilder(),
        TargetPlatform.windows: AylaPageTransitionsBuilder(),
        TargetPlatform.linux: AylaPageTransitionsBuilder(),
        TargetPlatform.fuchsia: AylaPageTransitionsBuilder(),
      },
    ),
    // 全局 focus 环（d:§10：辉光式 focus ring，禁无替代 outline:none）
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    focusColor: Colors.transparent,
  );
}



