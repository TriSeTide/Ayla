/// nav highlight（自 `primitives.dart` 拆出：一文件一件）。
///
/// 事实源与逐条对照见 `docs/flutter/17-组件文件头归档（整理前原文）.md` 的 `primitives.dart` 一节
/// 与各件的 `///` 头注。
///
/// ## 公开面
/// `AylaNavHighlightVariant` · `AylaNavHighlight` · `AylaNavHighlightState`

library;

import 'package:flutter/material.dart';
import '../../theme/css_gradient.dart';
import '../../theme/tokens.dart';

/// 共享高亮的造型档位。
///
/// web 用「同一个组件 + 变体类」表达两种造型：
/// - [nav] = `.auroraqua-nav-highlight`（auroraqua.css 175–185）：`inset: 0`、
///   `--nav-active-bg` 冰蓝渐变底 + `--glass-shadow-nav` + 1px `--glass-border`；
///   尺寸由宿主按钮决定，跨项迁移 300ms；
/// - [rail] = `.auroraqua-nav-highlight--rail`（auroraqua.css 217–229）：ServerRail
///   的**竖条指示条**——`inset: auto; left:0; top:50%; margin-top:-16px;`
///   `width:3px; height:32px; border-radius:2px; background: var(--glow-500);`
///   `border: 0; box-shadow: none;` 且 `::after { display: none }`（**无扫光**）。
///   尺寸/位置**由调用方给定**（3×32 + 垂直居中于所在行）。
enum AylaNavHighlightVariant {
  /// 常规选项卡/导航选中胶囊（`--nav-active-bg` 渐变 + 亮边 + 可选扫光）。
  nav,

  /// ServerRail 竖条指示条（`--glow-500` 纯色，无边框/无阴影/无扫光）。
  rail,
}

/// `auroraqua.css .auroraqua-nav-highlight` 175–191：
/// `inset: 0`、`z-index: -1`（内容之下）、`border-radius: inherit`、
/// `background: var(--nav-active-bg)`（135deg ice .35 → ice .18）、
/// `box-shadow: var(--glass-shadow-nav)`、`border: 1px solid --glass-border`。
class AylaNavHighlight extends StatefulWidget {
  const AylaNavHighlight({
    super.key,
    this.pill = false,
    this.sweep = false,
    this.sweepActive = false,
    this.radiusValue,
    this.showBorder = true,
    this.variant = AylaNavHighlightVariant.nav,
  });

  /// 造型档位（[AylaNavHighlightVariant.nav] 默认 = 全库既有 6 处调用；
  /// [AylaNavHighlightVariant.rail] = ServerRail 竖条指示条）。
  final AylaNavHighlightVariant variant;

  /// [AylaNavHighlightVariant.rail] 的默认圆角（auroraqua.css 225 `border-radius: 2px`）。
  static const double railRadius = 2;

  /// 外部（父级 tab/按钮）的 hover 状态——web 的选择器是
  /// `.has-auroraqua-highlight:hover > .auroraqua-nav-highlight::after`：
  /// **hover 判定在父元素上，作用于子级胶囊的伪元素**。
  /// 胶囊自身不接收指针（`pointer-events: none`），因此必须由父级驱动。
  final bool sweepActive;

  /// 覆盖圆角（不传则按 [pill] 推导）。
  final BorderRadius? radiusValue;

  /// 是否绘制 1px 亮边（`--glass-border`）。
  ///
  /// **默认 true**（对齐 `.auroraqua-nav-highlight { border: 1px solid ... }`）。
  /// 当**宿主按钮自己也画了同色 1px 边框**时（如 `.directory-filter.is-active {
  /// border-color: var(--glass-border) }`），两层 border 会**精确重叠**成
  /// 「双线」（实测：按钮层 (230,236,248) + 胶囊层 (248,251,253) 各 1px）。
  /// web 靠 `z-index: -1` 让胶囊退到按钮之下、视觉合一；Flutter 侧显式
  /// 只保留按钮那一层更稳定 → 此场景传 `false`。
  final bool showBorder;

  /// 圆角是否为 pill（`.layout-switch-btn` / `.favorites-filter` /
  /// `.group-chat-subgroup-tab` 覆写为 radius-pill，auroraqua.css 190–192）。
  final bool pill;

  /// 是否启用选中项 hover 扫光。
  ///
  /// 事实源 auroraqua.css 149–166 + 187：`.auroraqua-nav-highlight::after`
  /// 是一条 `linear-gradient(90deg, transparent, --glass-border, transparent)`
  /// 光带，`opacity .5`、`translateX(-120%)`、**700ms**
  /// （`.auroraqua-nav-highlight::after { transition-duration: 700ms }`）；
  /// 父级 `.has-auroraqua-highlight:hover` 时 → `translateX(120%)`。
  final bool sweep;

  @override
  State<AylaNavHighlight> createState() => AylaNavHighlightState();
}

class AylaNavHighlightState extends State<AylaNavHighlight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700), // 700ms（导航选中项）
  );
  late final Animation<double> _sweepEased = CurvedAnimation(
    parent: _sweep,
    curve: AylaCurves.auroraqua, // var(--auroraqua-ease)
  );

  /// **直接驱动扫光**（供宿主在指针进入时立即调用）。
  ///
  /// 为什么要这个入口：web 的 `:hover` 由浏览器合成器**原生响应（0 帧）**；
  /// 而「子级通知父级 → 父级 setState → rebuild → 子级才 forward()」需要
  /// **2 帧**（实测 32ms 才见位移），手感明显滞后于 web。
  /// 让命中指针的那个 tab 直达这里启动动画，可省掉 1 帧。
  /// 扫光当前进度（0 = 起点 −120%、1 = 终点 +120%）。
  ///
  /// 仅供测试断言「挂载即命中」（点击后必须**立刻**在终点，而不是重播一次
  /// 从左往右）—— 生产代码不读它。
  double get sweepProgress => _sweep.value;

  void setSweep(bool active, {bool jump = false}) {
    if (!widget.sweep || MediaQuery.disableAnimationsOf(context)) return;
    if (active) {
      if (jump) {
        // **挂载即命中**：web 上胶囊被挂载到「鼠标已在上面」的 tab 时，
        // 元素首次绘制的 computed style 就已经是 `translateX(120%)`
        // （`:hover` 从第一帧就匹配）→ **没有 transition**（无"前值"可过渡）。
        // 之后鼠标移走 → `120% → -120%` → transition 跑出**完整的一次
        // 从右往左扫**。这正是用户看到的效果。
        // 反之若此处启动 forward()，行程会被提前消耗（16ms 只走 3%），
        // 移走时的回程几乎为零 → 看不到扫光（实测 dx 恒 ≈ -1.17）。
        _sweep.value = 1.0;
      } else if (!_sweep.isAnimating && _sweep.value < 1.0) {
        // 普通 hover 进入已挂载的胶囊：-120% → 120%，从左往右扫
        _sweep.forward();
      }
    } else {
      // `:hover` 消失 → 目标变回 -120%；从**当前值**过渡（CSS transition 语义）
      if (_sweep.isAnimating || _sweep.value > 0) _sweep.reverse();
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool rail = widget.variant == AylaNavHighlightVariant.rail;
    final BorderRadius radius = widget.radiusValue ??
        (rail
            ? BorderRadius.circular(AylaNavHighlight.railRadius)
            : (widget.pill
                ? AylaRadii.pill
                : BorderRadius.circular(AylaRadii.rInput)));
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);

    // 扫光由**父级 hover**驱动（web: `.has-auroraqua-highlight:hover >
    // .auroraqua-nav-highlight::after`）。胶囊自身不接收指针事件
    // （web 的 `pointer-events: none`），所以这里不挂 MouseRegion。
    // rail 档另有 `::after { display: none }`（auroraqua.css 229）→ 永不扫光。
    final bool shouldSweep = widget.sweep && !reduceMotion && !rail;
    if (shouldSweep) {
      if (widget.sweepActive) {
        if (!_sweep.isAnimating && _sweep.value < 1.0) _sweep.forward();
      } else if (_sweep.isAnimating || _sweep.value > 0) {
        // 同 setSweep：单用 `value > 0` 会在「刚 forward 未 tick」时失效
        // （value 还是 0 → 不 reverse → 扫光卡在起点）
        _sweep.reverse();
      }
    }

    // ── 严格照抄 auroraqua.css 175–185 ──
    //   position: absolute; inset: 0;      → 尺寸 = 调用方给定
    //   border-radius: inherit;            → radius（继承父元素圆角）
    //   overflow: hidden;                  → **只裁内部扫光**
    //   background: var(--nav-active-bg);  → 135deg 冰蓝渐变
    //   box-shadow: var(--glass-shadow-nav);→ 0 0 8px rgba(157,191,230,.3)
    //   border: 1px solid var(--glass-border);
    //
    // **分层纪律**（此前三处做错）：
    //  ① **边框必须与渐变分层**：Flutter 的 `BoxDecoration` 同时设 `gradient` 与
    //     `border` 时，**渐变填充会盖住 1px 边框**（实测：胶囊单独渲染时
    //     y=18 起直接进渐变底色，白边完全不可见）。web 的 `background` 与
    //     `border` 是分离绘制、两者都可见。故这里拆成
    //     「底色+阴影层」→「边框层」→「扫光层」。
    //  ② 圆角必须在**画边框的那一层**给出（否则边框沿矩形绘制 → 圆被切）；
    //  ③ `overflow: hidden` 只包**扫光层**——若包住含 boxShadow 的整层，
    //     Flutter 的 ClipRRect 会把阴影一起裁掉（CSS 的 overflow 不裁自身阴影）
    //     → 胶囊看起来"上下左右被切"。
    // ⚠️ **阴影不能挂 `BoxDecoration(boxShadow:)`**：CSS 规定 `box-shadow`
    // **不在 border-box 内部绘制**；Flutter 的 `BoxShadow` 会**铺满形状含内部**。
    // `--glass-shadow-nav` = `0 0 8px rgba(157,191,230,.3)` → 把整个胶囊内部
    // 再染一层冰蓝。
    //
    // 实测证据（卡片底 #FFFAFB + ice-500 渐变）：
    //   web 胶囊内部应为 **(229,234,245)**（纯 `--nav-active-bg`）
    //   挂 boxShadow 后是  **(205,220,240)**
    //   ≈ 在 web 值上再叠 `.3` 冰蓝 → **(207,221,240)**（差仅 (2,1,0)）
    //   ⇒ 证实内部被多画一层阴影 → 高亮块偏暗偏蓝。
    //
    // **当前决定：胶囊不画外阴影**（已移除 `boxShadow`，暂不补 ring 层）。
    // 验收 release 后确认「正常」，故维持现状。
    // 若日后要补齐 `--glass-shadow-nav` 的 8px 冰蓝外发光，请用
    // [AylaGlassShadow.ring]（只画形状之外）—— **不要**改回 `boxShadow`。
    final Widget surface = DecoratedBox(
      decoration: BoxDecoration(
        // rail 档 = `background: var(--glow-500)`（auroraqua.css 226）**纯色**；
        // nav 档 = `--nav-active-bg` 的 135deg 冰蓝渐变（同文件 182）。
        gradient: rail
            ? null
            : cssLinearGradient(
                angleDeg: 135, // --nav-active-bg: linear-gradient(135deg, …)
                colors: AylaGradients.navActive,
              ),
        color: rail ? AylaColors.glow500 : null,
        borderRadius: radius,
      ),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // --glass-inset（顶沿 1px 内高光）也在此层内绘制
          if (shouldSweep)
            ClipRRect(
              // overflow: hidden 只作用于扫光
              borderRadius: radius,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  AnimatedBuilder(
                    animation: _sweepEased,
                    builder: (BuildContext context, Widget? child) {
                      return FractionalTranslation(
                        translation: Offset(-1.2 + _sweepEased.value * 2.4, 0),
                        child: child,
                      );
                    },
                    // ::after { opacity: .5 } 已乘进渐变色（性能 2026-09-27
                    // §8.17：单层渐变无重叠 ⇒ 等价且省一次 saveLayer）。
                    child: const _SweepBand(),
                  ),
                ],
              ),
            ),
        ],
      ),
    );

    // --glass-inset 的等价层（形状内顶沿 1px 白高光）+ 1px 亮边，叠在 surface 之上。
    //
    // **为什么边框单独一层**：Flutter 的 `BoxDecoration` 同时设 `gradient` 与
    // `border` 时，**渐变填充会盖住 1px 边框**（实测：胶囊单独渲染时从内容起点
    // 直接进渐变底色，白边完全不可见）。web 的 `background` 与 `border` 分离
    // 绘制、两者都可见 → 这里同样拆层。
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) {
          return Stack(
            children: <Widget>[
              surface,
              // --glass-inset：形状内顶沿 1px 白高光。
              // rail 档是 3px 宽的纯色竖条，web 未给它（也没有基础类的 inset）
              // → 不画，否则 `--glow-500` 会被白色高光冲淡。
              if (!rail)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: radius,
                      gradient: AylaInset.topHighlight(c.maxHeight),
                    ),
                  ),
                ),
              ),
              // 1px 亮边（`--glass-border`）。宿主按钮已画同色边时传
              // showBorder=false 以避免两层重叠（见 showBorder 文档）。
              // rail 档 `border: 0`（auroraqua.css 224）→ 无亮边。
              if (widget.showBorder && !rail)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: radius,
                        border: Border.all(color: AylaColors.glassBorder),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// 扫光带（`linear-gradient(90deg, transparent, --glass-border, transparent)`）。
class _SweepBand extends StatelessWidget {
  const _SweepBand();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: cssLinearGradient(
          angleDeg: 90,
          colors: AylaGradients.sweepHalf, // opacity .5 已在色里
        ),
      ),
    );
  }
}
