/// 跨页面媒体会话悬浮球控制组 —— `layout/SessionActivityIndicator.tsx`（181 行）
/// + `styles/shell.css:458–575`（组件全部样式）/ `:651–660`（窄屏）
/// + `auroraqua.css:54–94`（按钮组）/ `:655–677`（reduced-motion）。
///
/// ## 是什么
/// 语音球 + 直播球 + 收起把手三个按钮。点击把手 → 整组右移贴住屏幕右缘、两球滑出淡隐；
/// 再点把手恢复展开。把手支持**上下拖动**（位移超过阈值即判为拖动），整组 top 随之改变
/// 并 clamp 在视口内；拖动结束要抑制随后的合成 click，避免误触收起/展开。
///
/// ## 事实源（逐条对应 web，禁自由发挥）
/// ```
/// .session-activity-group              shell.css:459–471  fixed right 24 / top 80 / z-index 55；
///                                      flex row · align-items center · gap sp2 = 8；
///                                      translateX(0) + transform 200ms --ease-out
/// .is-collapsed                        475–480          translateX(24px)；pointer-events: none
///                                      651–660（≤768）  top calc(56 + safe-top + 48) / right 16 /
///                                                        translateX(16px)
/// .session-activity-ball               482–497          44×44 / radius 50% / 1px --glass-border /
///                                      --glass-bg-strong / blur(18px) saturate(1.4) /
///                                      0 2px 12px rgba(70,91,146,.12) /
///                                      transform·box-shadow 150ms --ease-out + opacity 200ms
/// .is-voice / .is-live                 519–527          grape-700 字 + sakura-100 底 /
///                                                        indigo-700 字 + ice-300 底（**不透明**底）
/// .is-collapsed .ball                  500–506          translateX(64px) + opacity 0 +
///                                      visibility hidden（延迟 200ms；flex 占位保留）
/// .ball:hover / :focus-visible         513–517          scale(1.08) + --glow-shadow
///                                      （本组件窄屏段**没有**辉光降档规则 → 窄屏仍用满强度）
/// .session-activity-toggle             529–548          28×44 / radius pill / 1px --glass-border /
///                                      --glass-bg-strong / blur(18px) saturate(1.4) /
///                                      同一个 .12 影 / color --text-secondary / touch-action none
/// .toggle:hover / :focus-visible       550–554          background var(--glass-bg-hover)、
///                                                        color --text-primary
/// .session-activity-toggle-icon        556–567          `›` 字符 / font-size 16 / font-weight 500 /
///                                      line-height 1 / transform 200ms --ease-out；
///                                      .is-collapsed → rotate(180deg)
/// reduced-motion          shell 569–575 / auroraqua 667  transition: none；按钮组缩放取消
/// tsx 常量                     9–13                    DRAG_THRESHOLD 5 / GROUP_HEIGHT 44 /
///                                                        DRAG_MARGIN 8；仅鼠标主键可拖（tsx 87）
/// ```
///
/// ## 层叠（已逐条确认，勿凭印象改）
/// - `auroraqua.css:62/80/92` 把 **`.session-activity-toggle`** 纳入按钮组 ⇒ 它的过渡是
///   **200ms `--auroraqua-ease`**（覆盖 shell.css 的 `background 150ms --ease-out`）、
///   `:hover { scale: 1.02 }`、`:active { scale: .98 }` → 由 [AylaPressScale] 承载；
/// - 该组**不含 `.session-activity-ball`** ⇒ 球没有 1.02/.98，只有自己的 `scale(1.08)`（150ms）。
///
/// ## 与 web 的装配差异（组件不写页面）
/// web 自取 `useAuthStore` / `useSessionActivityStore` / `useLocation` 判定显示与目标路由；
/// Flutter 侧没有全局 store 与路由，按既有「展示型 + 注入」模式改为**参数注入**：
/// [voice] / [live] 是已经解析好的会话投影（null = 不渲染该球），[onOpenSession] 回传目标会话。
///
/// **页面层接线项**（本件不做，与 A4 同口径）：
/// - roomId → 会话匹配（`stored.sessionId === String(roomId)`；不匹配时回落
///   `title` = 语音房/直播间 + `sourceRoute` = `/voice/:id`、`/live/start/:id`，tsx 41–68）；
/// - `onVoiceRoom` / `onLiveConsole` 的 pathname 判定（tsx 71–82）；
/// - 层序 `z-index: 55`（页面内容之上、直播小窗 60 / 弹层 70–80 之下）；
/// - `design.md:485` 的「小窗激活时隐藏直播球」在 tsx **未实现** → 同样留待页面层。
///
/// 本组件返回 [Positioned]（web 是 `position: fixed`，与 A4 的 `bottomLeft` / `narrow` 档同约定）
/// ⇒ 调用方必须把它放在页面最外层 `Stack` 的**直接子级**。
///
/// ## 三处已拍板的判断（2026-09-21 用户确认；请勿"照 CSS 字面"改回去）
/// 1. **把手 hover 底色 = 透明**：`var(--glass-bg-hover)` 在 web **全历史从未定义**
///    （`git log -S'--glass-bg-hover:'` 零命中，`dist/assets/index-*.css` 里也只有 4 处引用）
///    ⇒ 按 CSS 变量规范属「invalid at computed-value time」，`background` 简写整体回落到
///    初始值 = **完全透明**（1px 亮边 / blur / 阴影保留，字色转 `--text-primary`）
///    → 一比一复刻**实渲染结果**（不是复刻意图）；
/// 2. **球不加背板模糊**：球的底色是不透明的 `--sakura-100` / `--ice-300`，CSS 声明的
///    `blur(18px) saturate(1.4)` 被自身底色完全盖住、视觉恒为零 ⇒ 不加（省一次离屏模糊）；
///    把手是 `.78` 半透明玻璃 ⇒ **必须**保留 `blur(18px) saturate(1.4)`；
/// 3. **焦点环沿用 [AylaPressScale]**（库内统一做法）：它把 `:focus-visible` 的
///    `outline: 2px --glow-500; outline-offset: 2px` 实现为内嵌 `Container(padding 2 + border 2)`
///    ⇒ 键盘聚焦时元素会**长大 4px**（web 的 outline 不占布局）——已知库内差异，本轮记录不改。
///
/// ## 未完成项（登记，交用户裁决）
/// 两球的 `title={session.title}`（浏览器原生 tooltip）属全库 `Tooltip` 统一项
/// （`13-工作进度与待办.md` §4.2：一次补齐、别只给单个组件加）→ 本件不加。
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../theme/app_icons.dart';
import '../theme/buttons.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';

/// `box-shadow: 0 2px 12px rgba(70,91,146,0.12)`（shell.css 490 球 / 537 把手）。
///
/// ⚠️ 这**不是** `--card-shadow`（那个是 `.08`），也不是 `.corner-fab:hover` 的 `.18`
/// —— 是 shell.css 本组件专用的一档，故就地声明。
const List<BoxShadow> _kActivityShadow = <BoxShadow>[
  BoxShadow(
    color: Color(0x1F465B92), // rgba(70,91,146,.12)
    blurRadius: 12,
    offset: Offset(0, 2),
  ),
];

/// 活动态会话投影 —— web `stores/sessionActivity.ts` 的 `ActivitySession` 中
/// **本组件真正消费**的三个字段（`kind` / `owner` / `status` / `lastError` / `updatedAt`
/// 不参与本组件渲染，故不进签名）。
class AylaActivitySession {
  const AylaActivitySession({
    required this.sessionId,
    required this.sourceRoute,
    required this.title,
  });

  /// 会话 id（web `sessionId`）——供调用方识别是哪个会话（本组件自身不读）。
  final String sessionId;

  /// 点击悬浮球要回到的路由（web `sourceRoute`；兜底 `/voice/:id`、`/live/start/:id`）。
  final String sourceRoute;

  /// 球的 `title`（浏览器原生提示；Flutter 侧见文件头「未完成项」）。
  final String title;
}

/// 跨页面媒体会话悬浮球控制组（`layout/SessionActivityIndicator.tsx` 全文）。
class AylaSessionActivityIndicator extends StatefulWidget {
  const AylaSessionActivityIndicator({
    super.key,
    this.voice,
    this.live,
    this.onOpenSession,
  });

  /// 进行中的语音会话；**null = 不渲染语音球**（等价 web `showVoice === false`）。
  final AylaActivitySession? voice;

  /// 进行中的直播会话；**null = 不渲染直播球**（等价 web `showLive === false`）。
  final AylaActivitySession? live;

  /// 点击悬浮球：回传该会话（等价 web `navigate(session.sourceRoute)`，路由由页面层决定）。
  final ValueChanged<AylaActivitySession>? onOpenSession;

  /// tsx `const DRAG_THRESHOLD = 5`：pointer 位移超过该值视为拖动而非点击（px）。
  static const double dragThreshold = 5;

  /// tsx `const GROUP_HEIGHT = 44`：球/把手均为 44px，用于 clamp 底部边界。
  static const double groupHeight = 44;

  /// tsx `const DRAG_MARGIN = 8`：组可拖到的视口边缘最小间距（px）。
  static const double dragMargin = 8;

  /// `.session-activity-group { right: 24px; top: 80px }`（shell.css 461–462）。
  static const double wideRight = 24;
  static const double wideTop = 80;

  /// `@media (max-width: 768px)`：`right: 16px`、`top: calc(56px + safe-top + 48px)`
  /// （shell.css 652–655）——56 是窄屏顶栏高，48 是顶栏之下的间距。
  static const double narrowRight = 16;
  static const double narrowTopBase = 56 + 48;

  /// `.session-activity-ball { width/height: 44px }`。
  static const double ballSize = 44;

  /// `.session-activity-toggle { width: 28px; height: 44px }`。
  static const double toggleWidth = 28;
  static const double toggleHeight = 44;

  /// `.session-activity-group { gap: var(--sp-2) }` = 8。
  static const double gap = AylaSpacing.sp2;

  /// 收起态整组右移量 = `right` 偏移（宽屏 24 / 窄屏 16，把手正好贴住屏幕右缘）。
  static const double collapsedShiftWide = wideRight;
  static const double collapsedShiftNarrow = narrowRight;

  /// `.is-collapsed .session-activity-ball { transform: translateX(64px) }`（shell.css 501）。
  static const double ballCollapseShift = 64;

  /// `.session-activity-ball` 的过渡（`transform`/`box-shadow` **150ms**）——注意是 150ms，
  /// 既不是 `--dur-fast` 180ms 也不是按钮组的 200ms（shell.css 495–496；球不在按钮组内，无覆写）。
  static const Duration ballTransition = Duration(milliseconds: 150);

  @override
  State<AylaSessionActivityIndicator> createState() =>
      _AylaSessionActivityIndicatorState();
}

class _AylaSessionActivityIndicatorState
    extends State<AylaSessionActivityIndicator> {
  /// 收起态（tsx 25 `const [collapsed, setCollapsed] = useState(false)`）。
  bool _collapsed = false;

  /// 拖动后的绝对 top（px）；**null = 未拖动**，走 CSS 默认（宽屏 80 / 窄屏 calc）。
  double? _topPx;

  // ---- 拖动会话（tsx 30 `dragRef`）----
  bool _dragActive = false;
  bool _dragMoved = false;
  double _dragStartY = 0;
  double _dragStartTop = 0;

  /// 拖动结束后置 true，让随后触发的合成 click 只消费标记、不切换收起态（tsx 32）。
  bool _suppressClick = false;

  bool _isNarrow(BuildContext context) =>
      Breakpoint.isNarrow(MediaQuery.sizeOf(context).width);

  /// CSS 侧由浏览器算出的默认 top（`top: 80px` / `calc(56px + env(safe-area-inset-top) + 48px)`）。
  ///
  /// web 在 pointerdown 时读 `group.getBoundingClientRect().top` 作为拖动起点；
  /// Flutter 用 [Positioned] 的 `top` 定位，渲染 top 与该值**恒等**，故直接取计算值
  /// （等价且无首帧未布局的问题）。
  double _defaultTop(BuildContext context) {
    if (_isNarrow(context)) {
      // env(safe-area-inset-top) → MediaQuery.padding.top
      return AylaSessionActivityIndicator.narrowTopBase +
          MediaQuery.paddingOf(context).top;
    }
    return AylaSessionActivityIndicator.wideTop;
  }

  void _onPointerDown(PointerDownEvent event) {
    // tsx 87：仅主按键触发拖拽（鼠标左键）；触摸/触控笔无 button 概念，直接通过
    if (event.kind == PointerDeviceKind.mouse &&
        event.buttons != kPrimaryButton) {
      return;
    }
    // 新的交互开始 ⇒ 上一次的抑制标记作废。
    // （web 里合成 click 必然到达、标记必然被消费；Flutter 的 tap 在位移超过
    //  kTouchSlop 时**不会**触发，若不清零会把标记留给下一次真实点击。）
    _suppressClick = false;
    _dragActive = true;
    _dragMoved = false;
    _dragStartY = event.position.dy;
    _dragStartTop = _topPx ?? _defaultTop(context);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_dragActive) return;
    final double dy = event.position.dy - _dragStartY;
    // tsx 107：未超阈值前不判定为拖动，也不移动（保留点击语义）
    if (!_dragMoved && dy.abs() < AylaSessionActivityIndicator.dragThreshold) {
      return;
    }
    _dragMoved = true;
    // tsx 109–110：maxTop = max(8, innerHeight - 44 - 8)；clamp(startTop + dy, 8, maxTop)
    final double viewportHeight = MediaQuery.sizeOf(context).height;
    final double maxTop = math.max(
      AylaSessionActivityIndicator.dragMargin,
      viewportHeight -
          AylaSessionActivityIndicator.groupHeight -
          AylaSessionActivityIndicator.dragMargin,
    );
    final double nextTop = (_dragStartTop + dy).clamp(
      AylaSessionActivityIndicator.dragMargin,
      maxTop,
    );
    setState(() => _topPx = nextTop);
  }

  void _onPointerUp() {
    if (!_dragActive) return;
    _dragActive = false;
    // tsx 119：若本次是拖动（位移超阈值），抑制随后的合成 click
    _suppressClick = _dragMoved;
  }

  void _onToggleClick() {
    // tsx 127–131：拖动结束后的合成 click：仅消费抑制标记，不切换收起态
    if (_suppressClick) {
      _suppressClick = false;
      return;
    }
    setState(() => _collapsed = !_collapsed);
  }

  @override
  Widget build(BuildContext context) {
    final AylaActivitySession? voice = widget.voice;
    final AylaActivitySession? live = widget.live;
    // tsx 135：没有任何活动态时不渲染（Flutter 用 0×0 的 SizedBox 表达"零渲染"）
    if (voice == null && live == null) return const SizedBox.shrink();

    final bool narrow = _isNarrow(context);
    // shell.css 569–575：reduced-motion 下 group / 图标 / 球的 transition 全部关闭
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    final Duration groupDuration =
        reduceMotion ? Duration.zero : AylaDurations.button; // 200ms

    final Widget group = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center, // align-items: center
      spacing: AylaSessionActivityIndicator.gap, // gap: var(--sp-2)
      children: <Widget>[
        // JSX 顺序（tsx 144–178）：语音球 → 直播球 → 把手
        if (voice != null)
          _ActivityBall(
            kind: _ActivityBallKind.voice,
            collapsed: _collapsed,
            reduceMotion: reduceMotion,
            onPressed: () => widget.onOpenSession?.call(voice),
          ),
        if (live != null)
          _ActivityBall(
            kind: _ActivityBallKind.live,
            collapsed: _collapsed,
            reduceMotion: reduceMotion,
            onPressed: () => widget.onOpenSession?.call(live),
          ),
        _ActivityToggle(
          collapsed: _collapsed,
          reduceMotion: reduceMotion,
          onPressed: _onToggleClick,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
        ),
      ],
    );

    return Positioned(
      right: narrow
          ? AylaSessionActivityIndicator.narrowRight
          : AylaSessionActivityIndicator.wideRight,
      // tsx 142：`topPx != null` 时才写内联 top，否则由 CSS 决定
      top: _topPx ?? _defaultTop(context),
      child: TweenAnimationBuilder<double>(
        // 只给 end：首帧即落在当前状态，之后（收起/展开）才做过渡
        tween: Tween<double>(end: _collapsed ? 1 : 0),
        duration: groupDuration,
        // `.session-activity-group { transition: transform 200ms var(--ease-out) }`
        curve: AylaCurves.easeOut,
        builder: (BuildContext context, double v, Widget? child) =>
            Transform.translate(
          // 位移 = right 偏移（宽屏 24 / 窄屏 16）⇒ 收起时把手右缘贴住屏幕右缘
          offset: Offset(
            (narrow
                    ? AylaSessionActivityIndicator.collapsedShiftNarrow
                    : AylaSessionActivityIndicator.collapsedShiftWide) *
                v,
            0,
          ),
          child: child,
        ),
        child: group,
      ),
    );
  }
}

// ======================= 悬浮球 =======================

/// 球的两种身份（web `.is-voice` / `.is-live`）。
enum _ActivityBallKind { voice, live }

/// `.session-activity-ball` —— 44px 圆形悬浮球（`shell.css:482–527`）。
///
/// 与 [AylaCornerFab] 的差别（故**不**复用那件，四项都不同）：底色是**不透明**的
/// `--sakura-100` / `--ice-300`（不是 `--glass-bg`）、hover 是 `scale(1.08)` + 辉光
/// （不是 1.02 + 换底色）、过渡 **150ms**（不是 200ms）、且**不在** auroraqua 按钮组内
/// （无 `:active .98`）。结构照库内同类范本 `image_viewer.dart:709–811` 的
/// `_ViewerCircleButton`（圆形钮 + hover/focus 辉光）。
///
/// 本件只吃 [kind]：web 球上还有 `title={session.title}`，但那是全库 `Tooltip` 统一项
/// （文件头「未完成项」）—— 接线时在这里加 `title` 参数并把 `session.title` 传进来即可。
class _ActivityBall extends StatefulWidget {
  const _ActivityBall({
    required this.kind,
    required this.collapsed,
    required this.reduceMotion,
    this.onPressed,
  });

  final _ActivityBallKind kind;
  final bool collapsed;
  final bool reduceMotion;
  final VoidCallback? onPressed;

  @override
  State<_ActivityBall> createState() => _ActivityBallState();
}

class _ActivityBallState extends State<_ActivityBall> {
  bool _hovered = false;
  bool _focused = false;

  /// `.session-activity-ball:hover, .session-activity-ball:focus-visible` 共用一组规则
  /// （shell.css 513–517：`transform: scale(1.08); box-shadow: var(--glow-shadow)`）。
  bool get _active => _hovered || _focused;

  @override
  Widget build(BuildContext context) {
    final bool voice = widget.kind == _ActivityBallKind.voice;
    // shell.css 519–527：`.is-voice { color: --grape-700; background: --sakura-100 }`
    //                     `.is-live  { color: --indigo-700; background: --ice-300 }`
    final Color background = voice ? AylaColors.sakura100 : AylaColors.ice300;
    final Color foreground = voice ? AylaColors.grape700 : AylaColors.indigo700;
    final String label = voice ? '返回语音房' : '返回直播间'; // tsx 149 / 160 aria-label

    Widget box = DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: AylaRadii.pill, // border-radius: 50%（正方形即正圆）
        border: Border.all(color: AylaColors.glassBorder),
      ),
      child: SizedBox(
        width: AylaSessionActivityIndicator.ballSize,
        height: AylaSessionActivityIndicator.ballSize,
        child: Center(
          child: AylaIcon(
            aylaIconByName(voice ? 'iconMic' : 'iconVideo')!,
            size: 20, // tsx 152 / 163：`<IconMic width={20} height={20} />`
            color: foreground,
          ),
        ),
      ),
    );
    // 外阴影只画形状之外：常驻 `.12` 卡影，hover/focus → `--glow-shadow`；
    // `transition: box-shadow 150ms var(--ease-out)`（shell.css 495–496）
    box = AylaGlassShadow.animatedRing(
      radius: AylaRadii.pill,
      shadows: _active ? AylaShadows.glow : _kActivityShadow,
      duration:
          widget.reduceMotion ? Duration.zero : AylaSessionActivityIndicator.ballTransition,
      curve: AylaCurves.easeOut,
      child: box,
    );

    // 收起：`translateX(64px)` + `opacity 0`。
    //
    // ⚠️ 两条过渡的**时长不同**（shell.css 495–496 是基础规则、500–506 是 `.is-collapsed` 规则，
    //    两条都带 `transition` ⇒ 按方向取不同值）：
    //    · 收起（`.is-collapsed` 生效）→ `transform 200ms --ease-out`
    //    · 展开（基础规则生效）      → `transform **150ms** --ease-out`
    //    · `opacity` 两个方向都是 200ms
    //    ⇒ 位移与透明度必须**分开**两个动画宿主，不能合成一条。
    //
    // ⚠️⚠️ 这一段的 Element 必须**跨收起/展开保持稳定**：早前把
    //    `ExcludeFocus/ExcludeSemantics/IgnorePointer` 写成「collapsed 时才包一层」，
    //    根 widget 类型一变 ⇒ Flutter 重建整棵子树 ⇒ `TweenAnimationBuilder` 在 `initState`
    //    里把 `begin` 设成 `end`（= 立即到位）⇒ 球**瞬间**跳到收起位、没有任何滑出/淡隐
    //    （用户实测报出；探针中间帧：组有中间帧、球在 t=50ms 已到终值）。
    //    ⇒ 三个包装器恒在，只翻转它们的标志位（见下方 return）。
    Widget animated = AnimatedOpacity(
      opacity: widget.collapsed ? 0 : 1,
      duration: widget.reduceMotion ? Duration.zero : AylaDurations.button, // 两向都 200ms
      curve: AylaCurves.easeOut, // opacity 200ms var(--ease-out)
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: widget.collapsed ? 1 : 0),
        duration: widget.reduceMotion
            ? Duration.zero
            : (widget.collapsed
                ? AylaDurations.button // 收起：transform 200ms
                : AylaSessionActivityIndicator.ballTransition), // 展开：transform 150ms
        curve: AylaCurves.easeOut,
        builder: (BuildContext context, double v, Widget? child) =>
            Transform.translate(
          offset: Offset(
            AylaSessionActivityIndicator.ballCollapseShift * v,
            0,
          ),
          child: child,
        ),
        child: box,
      ),
    );

    // hover / focus → `scale(1.08)`（150ms --ease-out）。
    // 放在 [AylaPressScale] 之外 ⇒ 连焦点环一起缩放（web 的 outline 跟随元素 transform）。
    animated = AnimatedScale(
      scale: widget.reduceMotion || !_active ? 1.0 : 1.08,
      duration:
          widget.reduceMotion ? Duration.zero : AylaSessionActivityIndicator.ballTransition,
      curve: AylaCurves.easeOut,
      child: animated,
    );

    final Widget ball = Focus(
      // 本体不参与 tab 遍历（焦点环由 AylaPressScale 的节点承担）；
      // 但要**监听**焦点：`hasFocus` 对后代持有主焦点时为 true ⇒ 可驱动 hover/focus 同款辉光。
      canRequestFocus: false,
      onFocusChange: (bool has) => setState(() => _focused = has),
      child: AylaPressScale(
        // auroraqua.css:62/80/92 的按钮组 `:is()` **不含** `.session-activity-ball`
        // ⇒ 没有 hover 1.02 / active .98，缩放全部交给上面的 1.08
        hoverScale: false,
        pressScale: false,
        onTap: widget.onPressed,
        semanticLabel: label,
        child: MouseRegion(
          // cursor: pointer 由 AylaPressScale 自己给（enabled 时 click）
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: animated,
        ),
      ),
    );

    // 收起态：球不可点、不进语义、也不在 tab 序列（web：`pointer-events: none`
    // + 200ms 后 `visibility: hidden`）。
    // ⚠️ 三个包装器**恒在**（只翻转标志）——否则根类型变化会重建子树、吃掉上面的动画。
    return ExcludeFocus(
      excluding: widget.collapsed,
      child: ExcludeSemantics(
        excluding: widget.collapsed,
        child: IgnorePointer(
          ignoring: widget.collapsed,
          child: ball,
        ),
      ),
    );
  }
}

// ======================= 收起把手 =======================

/// `.session-activity-toggle` —— 28×44 玻璃把手（`shell.css:529–567`）。
class _ActivityToggle extends StatefulWidget {
  const _ActivityToggle({
    required this.collapsed,
    required this.reduceMotion,
    required this.onPressed,
    required this.onPointerDown,
    required this.onPointerMove,
    required this.onPointerUp,
  });

  final bool collapsed;
  final bool reduceMotion;

  /// 点击（已含「拖动后抑制」逻辑，见 [_AylaSessionActivityIndicatorState._onToggleClick]）。
  final VoidCallback onPressed;

  /// 原始指针事件（把手拖动）。
  final ValueChanged<PointerDownEvent> onPointerDown;
  final ValueChanged<PointerMoveEvent> onPointerMove;
  final VoidCallback onPointerUp;

  @override
  State<_ActivityToggle> createState() => _ActivityToggleState();
}

class _ActivityToggleState extends State<_ActivityToggle> {
  bool _hovered = false;
  bool _focused = false;

  /// `.session-activity-toggle:hover, .session-activity-toggle:focus-visible` 共用一组规则
  /// （shell.css 550–554：换底色 + 字色转 `--text-primary`）。
  bool get _active => _hovered || _focused;

  @override
  Widget build(BuildContext context) {
    // shell.css 550–554：`:hover, :focus-visible { background: var(--glass-bg-hover);
    // color: var(--text-primary) }`。
    //
    // ⚠️ `--glass-bg-hover` 在 web **全历史从未定义**（`git log -S` 零命中；dist 构建
    //    产物里也只有 4 处引用）⇒ 按 CSS 变量规范「invalid at computed-value time」，
    //    `background` 简写整体回落到初始值 = **完全透明**（1px 亮边 / blur / 阴影都保留）。
    //    这里一比一复刻**实渲染结果**（用户 2026-09-21 拍板）；零透明写**同色相**
    //    以免 Flutter 的逐通道 `Color.lerp` 在中途闪中灰（`13-*` §6.13）。
    final Color background = _active
        ? AylaColors.glassBgStrong.withValues(alpha: 0)
        : AylaColors.glassBgStrong;

    final BorderRadius radius = AylaRadii.pill;
    // 图标：tsx 177 `<span className="session-activity-toggle-icon">›</span>`
    // shell.css 556–562：font-size 16 / font-weight 500 / line-height 1 / 继承 button 字族
    //（base.css 333–335 `button { font-family/size: inherit }` ⇒ body 的 --font-body）
    Widget glyph = AnimatedDefaultTextStyle(
      // `.session-activity-toggle { transition: … color 200ms --auroraqua-ease }`（auroraqua 组）。
      // ⚠️ reduced-motion 下**不关**：shell.css 569–575 的关闭名单是
      // `.session-activity-group` / `-toggle-icon` / `-ball`，**不含** `.session-activity-toggle`
      // 本体；auroraqua 的 reduced-motion 段只清 translate/scale ⇒ 底色与字色照旧 200ms。
      duration: AylaDurations.button,
      curve: AylaCurves.auroraqua,
      style: TextStyle(
        fontFamily: AylaFonts.body,
        fontFamilyFallback: AylaFonts.cjkFallback,
        fontSize: 16,
        fontWeight: FontWeight.w500,
        height: 1, // line-height: 1
        color: _active ? AylaColors.textPrimary : AylaColors.textSecondary,
      ),
      child: const Text('›'),
    );
    // shell.css 556–567：图标过渡 200ms --ease-out；收起后 rotate(180deg)（指向左）
    glyph = AnimatedRotation(
      turns: widget.collapsed ? 0.5 : 0,
      duration: widget.reduceMotion ? Duration.zero : AylaDurations.button,
      curve: AylaCurves.easeOut,
      child: glyph,
    );
    // `›` 是纯装饰字形：web 里 `aria-label` 会**覆盖**按钮内容作为可访问名
    // （tsx 174 + shell.css 的 span 无 aria）⇒ 这里排除它的语义，否则节点名会变成
    // 「收起媒体控制\n›」（Flutter 会把子 Text 的标签拼到祖先标签上）。
    glyph = ExcludeSemantics(child: glyph);

    Widget box = AnimatedContainer(
      // auroraqua.css:62 把本类纳入按钮组 ⇒ 过渡为 200ms `--auroraqua-ease`
      //（覆盖 shell.css:543 的 `background 150ms --ease-out`）。
      // ⚠️ reduced-motion 下**不关**：shell.css 569–575 的关闭名单**不含** `.session-activity-toggle`
      // 本体（只有 `-group` / `-toggle-icon` / `-ball`），auroraqua 的 reduced-motion 段也只清
      // translate/scale ⇒ 底色与字色照旧 200ms；被关掉的只是缩放（由 AylaPressScale 处理）。
      duration: AylaDurations.button,
      curve: AylaCurves.auroraqua,
      width: AylaSessionActivityIndicator.toggleWidth,
      height: AylaSessionActivityIndicator.toggleHeight,
      decoration: BoxDecoration(
        color: background,
        borderRadius: radius,
        border: Border.all(color: AylaColors.glassBorder),
      ),
      child: Center(child: glyph),
    );
    // 同一个 `0 2px 12px rgba(70,91,146,.12)`（shell.css 537）。本件 hover **不换**阴影
    // （auroraqua 只加 scale、shell.css 只换背景/字色）⇒ 静态 ring，无需插值。
    box = Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned.fill(
          child: AylaGlassShadow.ring(
            radius: radius,
            shadows: _kActivityShadow,
          ),
        ),
        box,
      ],
    );

    // 玻璃：`--glass-bg-strong`（.78 **半透明**）+ `blur(18px) saturate(1.4)`
    // （shell.css 534–536）——与球不同，把手必须保留背板模糊，否则通透感丢失。
    if (!GlassConfig.useOpaqueFallback) {
      box = Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: ClipRRect(
              borderRadius: radius,
              child: BackdropFilter(
                filter: GlassConfig.backdropFilter(sigma: AylaGlass.blurNav),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          box,
        ],
      );
    }

    return Semantics(
      // tsx 175：`aria-expanded={!collapsed}`
      expanded: !widget.collapsed,
      child: Focus(
        // 本体不参与 tab 遍历（焦点环由 AylaPressScale 的节点承担）；
        // 但要**监听**焦点：`hasFocus` 在后代持有主焦点时为 true ⇒ 供
        // `:focus-visible` 的底色/字色切换（shell.css 550–554）使用。
        canRequestFocus: false,
        onFocusChange: (bool has) => setState(() => _focused = has),
        child: Listener(
          // 拖动几何走原始指针事件：web 的阈值是 **5px**，而 Flutter 的手势识别器
          // 要等 `kTouchSlop`（18px）才回调 ⇒ 用识别器会多出 13px 死区。
          onPointerDown: widget.onPointerDown,
          onPointerMove: widget.onPointerMove,
          onPointerUp: (_) => widget.onPointerUp(),
          onPointerCancel: (_) => widget.onPointerUp(),
          child: GestureDetector(
            // web `.session-activity-toggle { touch-action: none }`：拖把手时页面**不滚动**。
            // Flutter 没有 touch-action，等价做法是让同轴 drag recognizer 参与竞技场并赢下它
            // （回调刻意留空：几何仍由上面的原始指针事件按 5px 阈值处理）。
            onVerticalDragStart: (_) {},
            onVerticalDragUpdate: (_) {},
            onVerticalDragEnd: (_) {},
            child: AylaPressScale(
              // 在 auroraqua 按钮组内 ⇒ 200ms + hover 1.02 + active .98 + 焦点环
              onTap: widget.onPressed,
              // tsx 174：aria-label 随收起态切换
              semanticLabel: widget.collapsed ? '展开媒体控制' : '收起媒体控制',
              child: MouseRegion(
                onEnter: (_) => setState(() => _hovered = true),
                onExit: (_) => setState(() => _hovered = false),
                child: box,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ======================= 预览 =======================

/// 悬浮球控制组样张（画布与 @Preview 共用；**可交互**）。
///
/// - 两个舞台（宽屏 / 窄屏）各自是一块「模拟页面」+ 本组件；
///   点把手 → 看整组右移贴边、两球滑出淡隐；再点把手恢复；按住把手上下拖可移动整组 top；
/// - 右侧两个开关模拟「语音 / 直播会话进出」→ 看 `null` 时零渲染（web `showVoice/showLive`）；
/// - 点球 → 计数 + 显示回传的 `sourceRoute`（页面层接线前用回调代替 `navigate`）。
Widget aylaSessionActivitySamples() => const _SessionActivityDemo();

class _SessionActivityDemo extends StatefulWidget {
  const _SessionActivityDemo();

  @override
  State<_SessionActivityDemo> createState() => _SessionActivityDemoState();
}

class _SessionActivityDemoState extends State<_SessionActivityDemo> {
  bool _voiceOn = true;
  bool _liveOn = true;
  int _openCount = 0;
  String _lastRoute = '—';

  static const AylaActivitySession _voice = AylaActivitySession(
    sessionId: '5',
    sourceRoute: '/voice/5',
    title: '语音房', // tsx 49：store 无匹配时的兜底 title
  );
  static const AylaActivitySession _live = AylaActivitySession(
    sessionId: '9',
    sourceRoute: '/live/start/9',
    title: '直播间', // tsx 63
  );

  Widget _indicator() => AylaSessionActivityIndicator(
        voice: _voiceOn ? _voice : null,
        live: _liveOn ? _live : null,
        onOpenSession: (AylaActivitySession s) => setState(() {
          _openCount++;
          _lastRoute = s.sourceRoute;
        }),
      );

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AylaSpacing.sp6,
      runSpacing: AylaSpacing.sp6,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        _Stage(
          viewport: const Size(560, 360),
          label: '宽屏 >768：right 24 / top 80（未拖动）· 点把手收起 → 把手贴右缘、两球滑出淡隐 '
              '· 按住把手上下拖可改 top（clamp 8 … 视口高-52）',
          children: <Widget>[_indicator()],
        ),
        _Stage(
          viewport: const Size(375, 360),
          label: '窄屏 ≤768：right 16 / top calc(56 + safe-top + 48) = 104、收起位移 16',
          children: <Widget>[_indicator()],
        ),
        SizedBox(
          width: 320,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            spacing: AylaSpacing.sp3,
            children: <Widget>[
              GlassButton(
                label: _voiceOn ? '模拟：语音会话 进行中' : '模拟：语音会话 已结束',
                variant: GlassButtonVariant.ghost,
                minHeight: 36,
                onPressed: () => setState(() => _voiceOn = !_voiceOn),
              ),
              GlassButton(
                label: _liveOn ? '模拟：直播会话 进行中' : '模拟：直播会话 已结束',
                variant: GlassButtonVariant.ghost,
                minHeight: 36,
                onPressed: () => setState(() => _liveOn = !_liveOn),
              ),
              Text(
                '点球回调 $_openCount 次 · 目标路由 $_lastRoute',
                style: const TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 固定视口的样张舞台（与 A4 样张同纪律）。
///
/// 本组件的定位与判定都读 `MediaQuery` 视口（断点 / `innerHeight` / `safe-area`）
/// ⇒ 必须用 `MediaQuery.copyWith(size:)` **覆写局部视口**，否则会按预览宿主窗口走。
/// [children] 里允许直接放本组件（它返回 [Positioned]，需要 `Stack` 宿主）。
class _Stage extends StatelessWidget {
  const _Stage({
    required this.viewport,
    required this.label,
    required this.children,
  });

  final Size viewport;
  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          width: viewport.width,
          height: viewport.height,
          child: Builder(
            builder: (BuildContext inner) => MediaQuery(
              data: MediaQuery.of(inner).copyWith(size: viewport),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AylaRadii.rCard),
                child: DecoratedBox(
                  // 模拟页面底（浅玻璃面，供球/把手的材质与阴影对账）
                  decoration: BoxDecoration(
                    color: AylaColors.surface.withValues(alpha: 0.55),
                  ),
                  child: Stack(
                    children: <Widget>[
                      // 一点页面内容，避免"悬空按钮"看不出材质
                      const Padding(
                        padding: EdgeInsets.all(AylaSpacing.sp4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          spacing: AylaSpacing.sp2,
                          children: <Widget>[
                            Text('模拟页面内容', style: TextStyle(fontSize: 13)),
                            Text('跨页面活动态：离开语音房 / 直播间后由悬浮球返回',
                                style: TextStyle(fontSize: 12)),
                            Text('滚动、切页、进弹层时都常驻（层序 55）',
                                style: TextStyle(fontSize: 12)),
                          ],
                        ),
                      ),
                      ...children,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: AylaSpacing.sp1),
        // 画布纪律：长文本必须限宽，否则会把 Row 撑出画布（`13-*` §6.9）
        SizedBox(
          width: viewport.width,
          child: Text(label, style: const TextStyle(fontSize: 11)),
        ),
      ],
    );
  }
}

/// 悬浮球控制组（宽屏 / 窄屏 / 无活动态 / 收起 / 拖动）—— 可交互。
@Preview(
  group: 'Widgets',
  name: '会话活动悬浮球控制组（语音球 + 直播球 + 可拖动把手）',
  size: Size(1000, 620),
  wrapper: previewTheme,
)
Widget aylaSessionActivityPreview() => aylaSessionActivitySamples();
