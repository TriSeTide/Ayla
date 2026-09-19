/// Ayla 设计 token —— 「千禧冰樱 / Y2K Frost」唯一落盘处（web 端对应
/// `Ayla/web/src/styles/tokens.css`，本文所有值逐条从该文件与
/// `Ayla/docs/design.md` §2/§3/§5/§6 推导，禁裸色值、禁自由发挥）。
///
/// 来源标注约定：`t:xxx`=tokens.css 变量、`d:§x`=design.md 章节。
/// 组件内一律引用本文件，禁止散落 hex。
library;

import 'package:flutter/animation.dart' show Cubic;
import 'package:flutter/painting.dart';

/// =================== Core 色板（t:root / d:§2） ===================
abstract final class AylaColors {
  /// --ice-100：冷灰白，次级表面、离线环、分割线底色
  static const Color ice100 = Color(0xFFECF0F2);
  /// --ice-300：冰蓝，渐变起点、选中态底、spinner 轨道
  static const Color ice300 = Color(0xFFBDD4E9);
  /// --ice-500：冰蓝加深，hover 底、弱强调、头像底色
  static const Color ice500 = Color(0xFF9DBFE6);
  /// --slate-500：灰蓝，仅 ≥14px 次要文字/图标（对比度 ~2.9:1）
  static const Color slate500 = Color(0xFF7E95BD);

  /// `.conv-more-btn` 的静息图标色 `#a9b8d4`（app.css 633）。
  ///
  /// web 未把它提为 token（仅此一处裸值），Flutter 侧按"组件内禁裸色值"纪律
  /// 落盘于此并标注来源；hover/展开态切到 [textPrimary]。
  static const Color convMoreIdle = Color(0xFFA9B8D4);
  /// --indigo-700：主文字 + 主交互色（对 #FFFAFB 对比度 ~6.4:1）
  static const Color indigo700 = Color(0xFF465B92);
  /// --sakura-100：淡樱粉，渐变终点、爱莉气泡底
  static const Color sakura100 = Color(0xFFFCD8FF);
  /// --sakura-300：亮樱粉，辉光内层、tag/芯片底
  static const Color sakura300 = Color(0xFFF9B0FF);
  /// --glow-500：hot pink 辉光，阴影/外发光专用，不作文字色
  static const Color glow500 = Color(0xFFF796FF);
  /// --pink-500：樱花粉，强调图形、徽标底（文字必须配深底）
  static const Color pink500 = Color(0xFFF17EB3);
  /// --grape-700：深紫，粉底文字（对 #FCD8FF 对比度 ~6.6:1）、爱莉专属强调
  static const Color grape700 = Color(0xFF722E88);
  /// --surface：暖白，不支持玻璃的降级表面
  static const Color surface = Color(0xFFFFFAFB);

  /// =================== Functional（d:§2） ===================

  /// --text-primary：正文、标题
  static const Color textPrimary = indigo700;
  /// --text-secondary：次要信息（≥14px 才可用）
  static const Color textSecondary = slate500;
  /// --text-on-pink：粉底上的文字
  static const Color textOnPink = grape700;
  /// 玻璃卡底 rgba(255,250,251,.55)（t:--glass-bg）
  static const Color glassBg = Color(0x8CFFFAFB);
  /// 弹层/模态磨砂底 .78（t:--glass-bg-strong）
  static const Color glassBgStrong = Color(0xC7FFFAFB);
  /// 玻璃 1px 高光描边 rgba(255,255,255,.65)（t:--glass-border）
  static const Color glassBorder = Color(0xA6FFFFFF);
  /// backdrop-filter 不支持时的降级实底 .92（app.css @supports / d:§9）
  static const Color glassOpaqueFallback = Color(0xEBFFFAFB);
  /// 他人气泡玻璃底 rgba(255,250,251,.72)（t:--bubble-other）
  static const Color bubbleOther = Color(0xB8FFFAFB);
  /// 认证卡字段描边 rgba(70,91,146,.3)（d:§5 auth.css 覆写）
  static const Color fieldBorderOnGlass = Color(0x4D465B92);

  /// =================== Semantic（t:root / d:§2） ===================

  /// --success #3FA97C（青绿，避开粉蓝系歧义）
  static const Color success = Color(0xFF3FA97C);
  /// --warning #E8A33D
  static const Color warning = Color(0xFFE8A33D);
  /// --destructive #D64D6E（玫红，与樱粉同族但足够深，白字对比 ✓）
  static const Color destructive = Color(0xFFD64D6E);
  /// --warning-soft-bg rgba(232,163,61,.12)（警告类提示条半透明底）
  static const Color warningSoftBg = Color(0x1FE8A33D);
  /// --warning-soft-border rgba(232,163,61,.4)
  static const Color warningSoftBorder = Color(0x66E8A33D);
  /// --overlay-dim rgba(70,91,146,.25)（普通弹窗遮罩）
  static const Color overlayDim = Color(0x40465B92);
  /// --overlay-dim-strong rgba(70,91,146,.45)（图片查看器等 lightbox）
  static const Color overlayDimStrong = Color(0x73465B92);
  /// 认证卡内 `.avatar`:ice 渐变底上的 indigo 字（app.css .avatar）
  static const Color onAvatar = indigo700;
  /// 玻璃卡顶沿内高光 rgba(255,255,255,.5)（t:--glass-inset）
  static const Color glassInsetHighlight = Color(0x80FFFFFF);

  // ---- 爱莉专属（d:§2 bubble / §6 光环；全应用唯一，不可复用于他人） ----
  /// 爱莉气泡 1px 描边 rgba(247,150,255,.5)（d:§4 Chat Bubbles）
  static const Color elysiaBubbleBorder = Color(0x80F796FF);
  /// 爱莉光环呼吸辉光 8px .5（base.css halo-breathe 0%/100%）
  static const Color haloBreathSoft = Color(0x80F796FF);
  /// 爱莉光环呼吸辉光 16px .45（base.css halo-breathe 50% 外层）
  static const Color haloBreathOuter = Color(0x73F796FF);
}

/// =================== 渐变（t:root / d:§2 / app.css，CSS 角度 → Flutter） ===================
abstract final class AylaGradients {
  /// --bubble-self：自己消息气泡 linear-gradient(135deg, #9DBFE6, #BDD4E9)
  static const List<Color> bubbleSelf = <Color>[
    AylaColors.ice500,
    AylaColors.ice300,
  ];

  /// --bubble-elysia：爱莉气泡 linear-gradient(135deg, #FCD8FF, #F9B0FF)
  static const List<Color> bubbleElysia = <Color>[
    AylaColors.sakura100,
    AylaColors.sakura300,
  ];

  /// .btn-glow：linear-gradient(135deg, #F9B0FF, #F796FF) 渐变底
  static const List<Color> btnGlow = <Color>[
    AylaColors.sakura300,
    AylaColors.glow500,
  ];

  /// .avatar-core-user：linear-gradient(135deg, ice-500, ice-300)
  static const List<Color> avatarCoreUser = <Color>[
    AylaColors.ice500,
    AylaColors.ice300,
  ];

  /// .avatar-core-elysia：linear-gradient(135deg, sakura-100, sakura-300)
  static const List<Color> avatarCoreElysia = <Color>[
    AylaColors.sakura100,
    AylaColors.sakura300,
  ];

  /// --nav-active-bg：linear-gradient(135deg, rgba(157,191,230,.35), rgba(157,191,230,.18))
  static const List<Color> navActive = <Color>[
    Color(0x599DBFE6),
    Color(0x2E9DBFE6),
  ];

  /// 品牌渐变字 linear-gradient(120deg, indigo-700, grape-700)
  /// （base.css .fullscreen-loader-brand / d:§5 auth-brand 同款）
  static const List<Color> brand = <Color>[
    AylaColors.indigo700,
    AylaColors.grape700,
  ];

  /// .btn/自包含按钮扫光 linear-gradient(90deg, transparent, glass-border, transparent)
  /// （auroraqua.css ::after，opacity .5）
  static const List<Color> sweep = <Color>[
    Color(0x00FFFFFF),
    AylaColors.glassBorder,
    Color(0x00FFFFFF),
  ];
}

/// 毛玻璃滤镜参数（t:--glass-filter = `blur(24px) saturate(1.4)`）。
///
/// Flutter 无 CSS 那样的 `saturate()` 关键字，但 `dart:ui` 的
/// `ColorFilter implements ImageFilter`，配合 `ImageFilter.compose` 可组合出
/// 「先模糊、后饱和」的等价效果（见 [kSaturation14] 与 GlassSurface 用法）。

/// 饱和度 1.4 的颜色矩阵（20 元素，行主序 RGB 通道 + 偏移）。
///
/// 公式（标准饱和度矩阵）：`M = (1-s)·L + s·I`，其中 s = 1.4，
/// L 为亮度权重行（sRGB 权重 0.2126 / 0.7152 / 0.0722）。
/// 展开后每行：`r = 0.2126(1-s)+s`, `g = 0.7152(1-s)`, `b = 0.0722(1-s)`。
const List<double> kSaturation14 = <double>[
  1.27604, -0.28608, -0.02888, 0, 0, //
  -0.08992, 1.11392, -0.02888, 0, 0, //
  -0.08992, -0.28608, 1.38632, 0, 0, //
  0, 0, 0, 1, 0,
];

/// =================== 排版（d:§3 / t:--font-*） ===================
abstract final class AylaFonts {
  /// --font-display：Fredoka（标题/品牌/大数字）
  static const String display = 'Fredoka';
  /// --font-body：Nunito（正文/界面）
  static const String body = 'Nunito';
  /// --font-utility：Space Grotesk（时间戳/数据/ID）
  static const String utility = 'Space Grotesk';

  /// CJK 回退链（Fredoka/Nunito 只覆盖拉丁与数字，中文由系统圆体承接）
  static const List<String> cjkFallback = <String>[
    'PingFang SC',
    'Hiragino Sans GB',
    'Noto Sans SC',
    'Microsoft YaHei',
  ];
}

/// =================== 间距刻度（t:--sp-* / d:§5） ===================
/// 4 / 8 / 12 / 16 / 24 / 32 / 48；聊天密度场景以 8/12/16 为主
abstract final class AylaSpacing {
  static const double sp1 = 4;
  static const double sp2 = 8;
  static const double sp3 = 12;
  static const double sp4 = 16;
  static const double sp6 = 24;
  static const double sp8 = 32;
  static const double sp12 = 48;

  /// --sidebar-gutter：侧栏/分区外沿间隔 12px（t:root）
  static const double sidebarGutter = 12;
}

/// =================== 圆角刻度（t:--radius-* / d:§5） ===================
abstract final class AylaRadii {
  /// --radius-sm 8px：小件/骨架/九宫格图
  static const double rSm = 8;
  /// --radius-input 12px：按钮/输入/导航项/工具钮
  static const double rInput = 12;
  /// --radius-card 16px：卡片/侧栏
  static const double rCard = 16;
  /// --radius-panel 20px：弹窗面板/抽屉上沿
  static const double rPanel = 20;
  /// --radius-bubble 18px：消息气泡
  static const double rBubble = 18;
  /// --radius-pill 999px：胶囊/头像
  static const double rPill = 999;

  static const BorderRadius pill = BorderRadius.all(Radius.circular(rPill));
}

/// =================== 阴影（t:root Auroraqua 几何，RGB 全为 indigo） ===================
abstract final class AylaShadows {
  /// --glass-shadow：0 8px 32px rgba(70,91,146,.2) + 顶沿内高光（玻璃卡常规）
  static const List<BoxShadow> glass = <BoxShadow>[
    BoxShadow(
      color: Color(0x33465B92),
      blurRadius: 32,
      offset: Offset(0, 8),
    ),
  ];

  /// --glass-shadow-hover：0 12px 40px rgba(70,91,146,.2)（可交互卡 hover）
  static const List<BoxShadow> glassHover = <BoxShadow>[
    BoxShadow(
      color: Color(0x33465B92),
      blurRadius: 40,
      offset: Offset(0, 12),
    ),
  ];

  /// --glass-shadow-compact：0 4px 16px rgba(70,91,146,.1)（密集小行卡）
  static const List<BoxShadow> compact = <BoxShadow>[
    BoxShadow(
      color: Color(0x1A465B92),
      blurRadius: 16,
      offset: Offset(0, 4),
    ),
  ];

  /// --glass-shadow-button：0 2px 8px rgba(70,91,146,.1)（按钮/工具钮）
  static const List<BoxShadow> button = <BoxShadow>[
    BoxShadow(
      color: Color(0x1A465B92),
      blurRadius: 8,
      offset: Offset(0, 2),
    ),
  ];

  /// --glass-shadow-button-hover：0 4px 16px rgba(70,91,146,.15)
  static const List<BoxShadow> buttonHover = <BoxShadow>[
    BoxShadow(
      color: Color(0x26465B92),
      blurRadius: 16,
      offset: Offset(0, 4),
    ),
  ];

  /// --glass-shadow-modal：0 20px 60px rgba(70,91,146,.3)（弹窗）
  static const List<BoxShadow> modal = <BoxShadow>[
    BoxShadow(
      color: Color(0x4D465B92),
      blurRadius: 60,
      offset: Offset(0, 20),
    ),
  ];

  /// --glass-shadow-nav：0 0 8px rgba(157,191,230,.3)（导航选中柔光）
  static const List<BoxShadow> nav = <BoxShadow>[
    BoxShadow(
      color: Color(0x4D9DBFE6),
      blurRadius: 8,
    ),
  ];

  /// --glow-shadow：0 0 16px rgba(247,150,255,.45)（辉光，全屏 ≤3 处）
  static const List<BoxShadow> glow = <BoxShadow>[
    BoxShadow(
      color: Color(0x73F796FF),
      blurRadius: 16,
    ),
  ];

  /// 窄屏辉光降 30%：0 0 11px rgba(247,150,255,.32)（app.css @media ≤768）
  static const List<BoxShadow> glowNarrow = <BoxShadow>[
    BoxShadow(
      color: Color(0x52F796FF),
      blurRadius: 11,
    ),
  ];

  /// --card-shadow：0 2px 12px rgba(70,91,146,.08)（CreateFAB 浅投影/实心卡）
  static const List<BoxShadow> card = <BoxShadow>[
    BoxShadow(
      color: Color(0x14465B92),
      blurRadius: 12,
      offset: Offset(0, 2),
    ),
  ];

  /// CreateFAB 常驻投影：0 2px 12px rgba(70,91,146,.18)（d:§12.5）
  static const List<BoxShadow> fab = <BoxShadow>[
    BoxShadow(
      color: Color(0x2E465B92),
      blurRadius: 12,
      offset: Offset(0, 2),
    ),
  ];
}

/// =================== 时长（t:--dur-* / --auroraqua-* / d:§7） ===================
abstract final class AylaDurations {
  /// --dur-fast 180ms：字段过渡（app.css .field）
  static const Duration fast = Duration(milliseconds: 180);
  /// auroraqua.css 按钮组统一 200ms（覆盖 app.css .btn 的 180ms）
  static const Duration button = Duration(milliseconds: 200);
  /// --dur-panel 240ms：面板
  static const Duration panel = Duration(milliseconds: 240);
  /// --auroraqua-duration 300ms：卡片 hover/切换/分区
  static const Duration auroraqua = Duration(milliseconds: 300);
  /// --auroraqua-duration-enter 500ms：普通页面显现/未分区侧栏进入
  static const Duration enter = Duration(milliseconds: 500);
  /// .btn ::after 扫光 600ms（auroraqua.css）
  static const Duration sweep = Duration(milliseconds: 600);
  /// .auroraqua-nav-highlight 扫光 700ms（auroraqua.css）
  static const Duration navSweep = Duration(milliseconds: 700);
  /// --loading-spin-duration 800ms（base.css）
  static const Duration spin = Duration(milliseconds: 800);
  /// --loading-pulse-duration 1600ms（base.css frost-pulse）
  static const Duration pulse = Duration(milliseconds: 1600);
  /// halo-breathe 3.2s（base.css §6 唯一常驻环境动画）
  static const Duration breathe = Duration(milliseconds: 3200);
}

/// =================== 缓动（t:--ease-* / --auroraqua-*） ===================
abstract final class AylaCurves {
  /// --ease-out cubic-bezier(0.22, 0.61, 0.36, 1)
  static const Cubic easeOut = Cubic(0.22, 0.61, 0.36, 1);
  /// --ease-in cubic-bezier(0.4, 0, 1, 1)
  static const Cubic easeIn = Cubic(0.4, 0, 1, 1);
  /// --auroraqua-ease ease（线性）
  static const Cubic auroraqua = Cubic(0.25, 0.1, 0.25, 1);
  /// --auroraqua-ease-out cubic-bezier(0, 0, 0.58, 1)
  static const Cubic auroraquaEaseOut = Cubic(0, 0, 0.58, 1);
  /// --auroraqua-ease-in-out cubic-bezier(0.42, 0, 0.58, 1)
  static const Cubic auroraquaEaseInOut = Cubic(0.42, 0, 0.58, 1);
}

/// =================== 断点（d:§9：480 / 768 / 1024 / 1440） ===================
enum AylaBreakpoint {
  /// <480 xs
  xs,
  /// 480–767 sm
  sm,
  /// 768–1023 md
  md,
  /// 1024–1439 lg
  lg,
  /// ≥1440 xl
  xl,
}

/// 断点判定（CSS px 口径；Flutter 逻辑 px 在 Windows 125% 下 1:1 对应）。
abstract final class Breakpoint {
  static const double xs = 480;
  static const double sm = 768;
  static const double md = 1024;
  static const double lg = 1440;

  static AylaBreakpoint of(double width) {
    if (width < xs) return AylaBreakpoint.xs;
    if (width < sm) return AylaBreakpoint.sm;
    if (width < md) return AylaBreakpoint.md;
    if (width < lg) return AylaBreakpoint.lg;
    return AylaBreakpoint.xl;
  }

  /// 形态判定只有两态：≤768 窄屏（BottomTabs 系）/ >768 宽屏（TopNav 系）
  static bool isNarrow(double width) => width <= sm;

  /// ≥1024 帖子流双列瀑布（d:§12.18）
  static bool isWideMasonry(double width) => width >= md;
}

/// `--glass-inset`（`inset 0 1px 0 rgba(255,255,255,.5)`）的 Flutter 等价物。
///
/// **为什么需要**：web 的每个阴影 token 都拼了 `var(--glass-inset)`
/// （tokens.css 124–130）——`--glass-shadow` / `-hover` / `-compact` /
/// `-button` / `-button-hover` / `-modal` / `-nav` 共 7 个全部带顶沿 1px
/// 内高光，玻璃材质"亮起来"的观感就靠它；Flutter 的 `BoxShadow` 没有
/// inset 变体，必须单独绘制。
///
/// **1px 必须按高度换算**：stops 取 `1/height`，否则高盒子上高光会被拉成
/// 一大条（固定比例近似法的坑）。
abstract final class AylaInset {
  /// 把 `--glass-inset` 铺到一个形状上（实现见 `glass.dart` 的 `AylaGlassInset.over`）。
  ///
  /// 放在 glass.dart 是因为 tokens.dart 保持纯 token（不依赖 widgets 库）。
  static LinearGradient topHighlight(double height) {
    final double stop = height > 0 ? (1 / height).clamp(0.0, 0.5) : 0.1;
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: const <Color>[
        Color(0x80FFFFFF), // rgba(255,255,255,.5)
        Color(0x00FFFFFF),
      ],
      stops: <double>[0, stop],
    );
  }
}
