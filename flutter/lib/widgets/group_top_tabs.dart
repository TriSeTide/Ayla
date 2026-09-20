/// 窄屏群场景顶部导航条 —— web `components/group/GroupTopTabs.tsx` 1–125
/// + `styles/group.css` 21–91 + `auroraqua.css` 237/246/253/255/448/669（含覆盖关系）。
///
/// ## 与 [AylaBottomTabs] 同构的部分
/// 五槽 + `has-auroraqua-highlight` 共享胶囊（**跨槽 300ms 迁移**）+ 导航组 `:active .98`、
/// hover 不放大 + blur18 saturate1.4 玻璃容器。
///
/// ## 差异（逐条核对，别再照搬底栏）
/// | 项 | BottomTabs | GroupTopTabs（本件） |
/// |---|---|---|
/// | 中央槽 | 主页圆盘 48 + `margin-top:-8` + `--surface`+边+`--card-shadow` | **群头像 48 + `margin-top:-6`**（[AvatarHalo]，无背板）|
/// | 图标 | 24 | **22**（`<Icon width={22}>`）|
/// | 容器边 | `border-top`（shell.css:86） | **`border-bottom`**（group.css:30）|
/// | 容器圆角 | 顶层 `20 20 0 0` → 窄屏 `0` | 顶层 **`0 0 20 20`**（auroraqua 253）→ 窄屏 **`0`**（448 同时覆写两者）|
/// | 容器阴影 | `--glass-shadow` | **`--glass-shadow-compact`**（253）|
/// | 按钮 | `flex:1` 撑满槽 + `margin 4px 2px` | **`inline-flex` 按内容宽**（居中）+ 无 margin；auroraqua 255 给 `padding: 6px 12px` + `radius-input` |
/// | 文字 | `.bottom-tab-label`（display 11 **/500** /ls .8）| `.group-top-btn` 自身（display 11 / **未声明字重**（继承 400）/ls .8）|
/// | 红点 | **无**（F1 恒空） | **帖子 tab 有**：8px `--pink-500` 圆点，`top:6px; right: calc(50% - 18px)` |
///
/// ## 动画（用户要求「动画也要做」）
/// - **组件内**：共享胶囊跨槽迁移 300ms `[0,0,.58,1]`（`AuroraquaNavHighlight` 的 `layoutId` 语义）；
/// - **父级注入**（本件只暴露挂载点，不自己演）：`GroupPage.tsx:439–457` 把整条
///   `translate` 到 `calc(100dvh - 64px - safe-area)`（= 正好落在底栏位置），`entered` 后归零，
///   过渡 `translate 300ms --auroraqua-ease-out` → 视觉上「从底栏位置连续升至顶部」；
///   下拉回主页时父级用 `pullOffset` 驱动同一 `translate`（reduced-motion 时全部归零）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/buttons.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'avatar_halo.dart';
import 'bottom_tabs.dart'; // 样张里演示「回主页后壳层渲染底栏」
import 'primitives.dart' show AylaNavHighlight;

/// 群内子场景（web `stores/group` 的 `GroupScene` 去掉聊天：聊天居中于五槽之间的内容区，
/// 不在顶栏 tab 里）。
/// ⚠️ [chat] **不在顶栏四 tab 里**：四槽是 语音|直播|帖子|桌游，中央是群头像；
/// 点群头像是「两级语义」（`GroupPage.tsx:318–324`）：已在聊天 → 打开群信息，否则 → 切回聊天。
/// 组件把该语义留给父级（`onAvatarClick`），但枚举必须含 chat，父级才能表达「回聊天」。
enum AylaGroupScene {
  chat,
  voice,
  live,
  posts,
  games;

  /// tab 文案（`GroupTopTabs.tsx:21–26` `TABS`）。
  String get label => switch (this) {
        AylaGroupScene.chat => '聊天',
        AylaGroupScene.voice => '语音',
        AylaGroupScene.live => '直播',
        AylaGroupScene.posts => '帖子',
        AylaGroupScene.games => '桌游',
      };

  /// 图标名。
  String get iconName => switch (this) {
        AylaGroupScene.chat => 'iconMessage',
        AylaGroupScene.voice => 'iconMic',
        AylaGroupScene.live => 'iconVideo',
        AylaGroupScene.posts => 'iconPost',
        AylaGroupScene.games => 'iconGame',
      };
}

/// 窄屏群场景顶栏（展示型；路由/手势由父级）。
class AylaGroupTopTabs extends StatefulWidget {
  const AylaGroupTopTabs({
    super.key,
    required this.groupName,
    required this.activeScene,
    this.avatarUrl,
    this.onSelectScene,
    this.onAvatarClick,
    this.postUnread = 0,
    this.offset = Offset.zero,
  });

  /// 群名（头像文字回退 + `aria-label`）。
  final String groupName;

  /// 当前子场景。
  final AylaGroupScene activeScene;

  /// 群头像（媒体 content URL；null = 文字首字）。
  final String? avatarUrl;

  /// 切场景（null = 不可点）。
  final ValueChanged<AylaGroupScene>? onSelectScene;

  /// 群头像点击（两级语义由父级分支，组件不判断，`GroupTopTabs.tsx:6`）。
  final VoidCallback? onAvatarClick;

  /// 未读帖子数（>0 时帖子 tab 显示 8px 红点）。
  final int postUnread;

  /// 父级驱动的位移（入场「从底栏升起」/ 下拉跟手）；本件不自演动画。
  final Offset offset;

  /// 条高（`group.css:36` `.group-top-nav { height: 64px }`）。
  static const double barHeight = 64;

  /// 导航条左右内边距（`group.css:37` `padding: 0 var(--sp-2)`）。
  static const double navPadding = AylaSpacing.sp2;

  /// 图标尺寸（`GroupTopTabs.tsx:77/108` `width={22}`）。
  static const double iconSize = 22;

  /// 头像槽尺寸与上浮（`group.css:83–91`：48px、`margin-top: -6px`）。
  static const double avatarSize = 48;
  static const double avatarOffset = 6;

  @override
  State<AylaGroupTopTabs> createState() => _AylaGroupTopTabsState();
}

class _AylaGroupTopTabsState extends State<AylaGroupTopTabs> {
  /// 各槽按钮的实测矩形（相对导航条 Stack）——按钮是 `inline-flex`（宽度 = 内容），
  /// 胶囊 `inset:0` 落在按钮内，因此**必须实测**而非按等分推算（与底栏不同）。
  /// 只有**四个 tab** 有槽位（中央是头像槽，不是 tab）。
  /// `chat`（头像槽对应场景）不在其中 —— 当前场景为 chat 时胶囊必须清空，
  /// 否则会残留上一次的高亮（2026-09-20 用户实测：切到聊天后其它 tab 高亮没去掉）。
  final Map<AylaGroupScene, GlobalKey> _slotKeys = <AylaGroupScene, GlobalKey>{
    AylaGroupScene.voice: GlobalKey(),
    AylaGroupScene.live: GlobalKey(),
    AylaGroupScene.posts: GlobalKey(),
    AylaGroupScene.games: GlobalKey(),
  };
  final GlobalKey _stackKey = GlobalKey();
  Rect? _capsuleRect;

  /// 指针所在 tab（-1/ null = 无）。web 用 `:hover` 谓词 → 记录后在 build 时求值。
  AylaGroupScene? _hoveredScene;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  @override
  void didUpdateWidget(covariant AylaGroupTopTabs old) {
    super.didUpdateWidget(old);
    if (old.activeScene != widget.activeScene ||
        old.groupName != widget.groupName) {
      _measure();
    }
  }

  /// 布局后实测选中槽按钮矩形（相对 Stack 坐标系）。
  void _measure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 当前场景没有 tab 槽位（如 chat = 头像槽场景）→ 清空胶囊（不高亮任何 tab）
      if (!_slotKeys.containsKey(widget.activeScene)) {
        if (_capsuleRect != null) setState(() => _capsuleRect = null);
        return;
      }
      final RenderBox? stack =
          _stackKey.currentContext?.findRenderObject() as RenderBox?;
      final RenderBox? slot = _slotKeys[widget.activeScene]
              ?.currentContext
              ?.findRenderObject() as RenderBox?;
      if (stack == null || slot == null || !stack.hasSize || !slot.hasSize) {
        return;
      }
      final Offset topLeft =
          slot.localToGlobal(Offset.zero, ancestor: stack);
      final Rect rect = topLeft & slot.size;
      if (rect != _capsuleRect) setState(() => _capsuleRect = rect);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: widget.offset, // 入场/下拉位移由父级驱动（见文件头「动画」）
      child: GlassSurface(
        blur: AylaGlass.blurNav, // blur(18px) saturate(1.4)（group.css:28）
        // auroraqua 253：`--glass-shadow-compact`（比底栏的 --glass-shadow 更轻）
        shadow: AylaShadows.compact,
        // auroraqua 448（@media max-width:768px）：底栏与群顶栏圆角同样清零 → **方角**
        radiusOverride: BorderRadius.zero,
        // group.css:30：`border-bottom: 1px solid --glass-border`
        borderOverride:
            const Border(bottom: BorderSide(color: AylaColors.glassBorder)),
        padding: EdgeInsets.zero,
        child: SizedBox(
          height: AylaGroupTopTabs.barHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AylaGroupTopTabs.navPadding,
            ),
            child: Stack(
              key: _stackKey,
              children: <Widget>[
                // 共享胶囊：画在**按钮内**（`inset: 0`）→ 用实测矩形定位，跨槽 300ms 迁移
                if (_capsuleRect case final Rect rect)
                  AnimatedPositioned(
                    duration: AylaDurations.auroraqua, // 300ms
                    curve: AylaCurves.auroraquaEaseOut, // [0,0,.58,1]
                    left: rect.left,
                    top: rect.top,
                    width: rect.width,
                    height: rect.height,
                    child: AylaNavHighlight(
                      radiusValue: const BorderRadius.all(
                        Radius.circular(AylaRadii.rInput), // auroraqua 255
                      ),
                      // 白边走库内默认（showBorder: true，auroraqua.css:186）
                      sweep: true,
                      // 扫光是**父级 hover** 触发（auroraqua 161–166）：只有 hover 到当前选中槽时才播
                      sweepActive: _hoveredScene == widget.activeScene,
                    ),
                  ),
                Row(
                  children: <Widget>[
                    // 顺序（R-G3）：语音 | 直播 | 群头像（居中）| 帖子 | 桌游
                    Expanded(child: Center(child: _tab(AylaGroupScene.voice))),
                    Expanded(child: Center(child: _tab(AylaGroupScene.live))),
                    Expanded(child: Center(child: _avatar())),
                    Expanded(child: Center(child: _tab(AylaGroupScene.posts))),
                    Expanded(child: Center(child: _tab(AylaGroupScene.games))),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 中央群头像槽（`group.css:83–91` + `GroupTopTabs.tsx:85–94`）。
  Widget _avatar() {
    return SizedBox(
      // `margin-top: -6px` = 上浮 6 且占位 48→42（同底栏圆盘的手法）
      width: AylaGroupTopTabs.avatarSize,
      height: AylaGroupTopTabs.avatarSize - AylaGroupTopTabs.avatarOffset,
      child: OverflowBox(
        alignment: Alignment.bottomCenter,
        maxWidth: AylaGroupTopTabs.avatarSize,
        maxHeight: AylaGroupTopTabs.avatarSize,
        child: AvatarHalo(
          label: widget.groupName,
          size: AylaGroupTopTabs.avatarSize,
          online: true, // `GroupTopTabs.tsx:92` 固定 online
          resourceUrl: widget.avatarUrl,
          onTap: widget.onAvatarClick,
          semanticLabel: '群头像：${widget.groupName}',
        ),
      ),
    );
  }

  Widget _tab(AylaGroupScene scene) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool active = widget.activeScene == scene;
    final Color idle = AylaColors.textSecondary;
    final Color selected = AylaColors.textPrimary;
    final bool enabled = widget.onSelectScene != null;

    // 帖子 tab 未读红点：8px `--pink-500` 圆点，`top:6px; right: calc(50% - 18px)`
    // （`group.css:72–80`）→ 即「距按钮中心向右 18px、距顶 6px」。
    final Widget? dot = scene == AylaGroupScene.posts && widget.postUnread > 0
        ? Positioned(
            top: 6,
            left: 0,
            right: 0,
            child: Center(
              child: Transform.translate(
                offset: const Offset(18, 0),
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: AylaColors.pink500,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          )
        : null;

    final Widget button = Stack(
      key: _slotKeys[scene],
      clipBehavior: Clip.none,
      children: <Widget>[
        Padding(
          // auroraqua 255（顶层）：`padding: 6px 12px` 覆写 group.css 的 `padding: 0 sp2`
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 2, // `.group-top-btn { gap: 2px }`（group.css:58）
            children: <Widget>[
              TweenAnimationBuilder<double>(
                // `transition: color …`（`.group-top-btn` 无声明时长 → 走 auroraqua 组 200ms；
                // 与底栏的 150ms 不同，见 auroraqua.css:236–242 的导航组过渡）
                duration: AylaDurations.button,
                curve: AylaCurves.auroraqua,
                tween: Tween<double>(begin: active ? 0 : 1, end: active ? 1 : 0),
                builder: (BuildContext context, double v, Widget? child) =>
                    IconTheme(
                  data: IconThemeData(color: Color.lerp(idle, selected, v)),
                  child: child!,
                ),
                child: AylaIcon(
                  aylaIconByName(scene.iconName)!,
                  size: AylaGroupTopTabs.iconSize,
                  color: active ? selected : idle,
                ),
              ),
              TweenAnimationBuilder<double>(
                duration: AylaDurations.button,
                curve: AylaCurves.auroraqua,
                tween: Tween<double>(begin: active ? 0 : 1, end: active ? 1 : 0),
                builder: (BuildContext context, double v, Widget? child) =>
                    DefaultTextStyle(
                  style: t.microTag.copyWith(
                    color: Color.lerp(idle, selected, v),
                    fontWeight: FontWeight.w400, // `.group-top-btn` 未声明字重（继承 400）
                  ),
                  child: child!,
                ),
                child: Text(scene.label),
              ),
            ],
          ),
        ),
        if (dot != null) dot,
      ],
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredScene = scene),
      onExit: (_) => setState(() => _hoveredScene = null),
      child: AylaPressScale(
        onTap: enabled ? () => widget.onSelectScene!(scene) : null,
        semanticLabel: scene.label,
        hoverScale: false, // 导航组：只 :active scale .98（auroraqua 245–249）
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48), // `min-height: 48px`
          child: button,
        ),
      ),
    );
  }
}

// ======================= 画布样张（可交互） =======================

/// 画布/预览用**可交互**样张：点四个 tab 切换场景，观察共享胶囊跨槽迁移。
Widget aylaGroupTopTabsSamples() => const _GroupTopTabsDemo();

class _GroupTopTabsDemo extends StatefulWidget {
  const _GroupTopTabsDemo();

  @override
  State<_GroupTopTabsDemo> createState() => _GroupTopTabsDemoState();
}

class _GroupTopTabsDemoState extends State<_GroupTopTabsDemo> {
  AylaGroupScene _scene = AylaGroupScene.chat;
  bool _infoOpen = false;
  int _postUnread = 3;

  /// 顶栏位移（web `pullOffset` → `tabsTransform`）：跟手 + 退场归零。
  double _pullOffset = 0;

  /// 内容区位移（web `pullY`）与不透明度（web `pullOpacity = 1 - 0.4 × 进度`）。
  double _pullY = 0;
  double _pullOpacity = 1;

  bool _dragging = false;

  /// 退场中（web `leaving`）。
  bool _leaving = false;

  /// 已回主页（web `setTimeout(() => navigate("/group"), 250)` 之后：那里有底栏）。
  bool _home = false;

  /// 顶栏位移的时长/曲线（web `tabsTransition`）：退场 250ms --ease-in（:445）；
  /// 回弹 200ms --ease-out（:451）；入场升顶 300ms --auroraqua-ease-out（:457）。
  Duration _tabsDuration = const Duration(milliseconds: 200);
  Curve _tabsCurve = AylaCurves.easeOut;

  /// `PULL_DOWN_EXIT_THRESHOLD = 80`（GroupPage.tsx:64）与 `EXIT_TRANSITION_MS = 250`（:65）。
  static const double _threshold = 80;
  static const Duration _exitMs = Duration(milliseconds: 250);

  /// 样张行程：web 是 `100dvh - 64px - safe-area`，画布里用等效可见行程。
  static const double _riseDistance = 150;

  void _onAvatarTap() {
    setState(() {
      if (_scene == AylaGroupScene.chat) {
        _infoOpen = !_infoOpen; // 已在聊天 → 打开群信息（GroupPage.tsx:319–320）
      } else {
        _scene = AylaGroupScene.chat; // 否则 → 切回聊天（:322）
        _infoOpen = false;
      }
    });
  }

  /// web `onMove`：只在**下拉**（dy > 0）跟手；顶栏与内容 1:1 位移，内容按进度淡出。
  void _onDragUpdate(DragUpdateDetails d) {
    if (_leaving) return;
    if (d.delta.dy <= 0 && _pullY <= 0) return; // web: dy <= 0 直接 return
    setState(() {
      _dragging = true;
      _pullY = (_pullY + d.delta.dy).clamp(0.0, _riseDistance).toDouble();
      _pullOffset = _pullY;
      final double progress = (_pullY / _threshold).clamp(0.0, 1.0);
      _pullOpacity = 1 - 0.4 * progress;
    });
  }

  /// web `onEnd`：向下且 dy ≥ 80 → `pullToHome()`；否则 200ms --ease-out 回弹。
  void _onDragEnd(DragEndDetails d) {
    if (_leaving) return;
    setState(() {
      _dragging = false;
      if (_pullY >= _threshold) {
        _exitToHome();
      } else {
        _tabsDuration = const Duration(milliseconds: 200);
        _tabsCurve = AylaCurves.easeOut;
        _pullOffset = 0;
        _pullY = 0;
        _pullOpacity = 1;
      }
    });
  }

  /// ≥80px 的落点：**顶栏与内容一起继续向下滑出**（250ms `--ease-in`）→ 250ms 后回主页。
  ///
  /// ⚠️ **偏离 web 的调整**（2026-09-20 用户要求）：web `pullToHome()`（`GroupPage.tsx:120–135`）
  /// 写的是 `setPullOffset(0)` —— 顶栏回到原位、内容继续下滑出屏，两者方向相反，
  /// 观感上顶栏会先往上弹一段。用户要求 ≥80px 时不要回弹，改为一起向下滑出。
  /// `<80px` 的回弹（200ms `--ease-out`）保持不变，见 `_onDragEnd`。
  void _exitToHome() {
    _leaving = true;
    _tabsDuration = _exitMs;
    _tabsCurve = AylaCurves.easeIn;
    // 滑到**贴底即停**（顶栏落到底栏位置），不滑出屏幕（2026-09-20 用户要求）
    const double exitDistance = _riseDistance;
    _pullOffset = exitDistance; // 顶栏继续向下直到贴底（不再归零）
    _pullY = exitDistance; // 内容同步滑到同一位置
    _pullOpacity = 0;
    Future<void>.delayed(_exitMs, () {
      if (!mounted) return;
      setState(() => _home = true); // = navigate("/group")：主页（壳层有底栏）
    });
  }

  /// 重新进群：顶栏**首帧在原底栏位置可见**，次帧升起
  /// （web `useEnterGroupAnimation` 的双 rAF + 300ms --auroraqua-ease-out）。
  void _reenter() {
    setState(() {
      _home = false;
      _leaving = false;
      _pullY = 0;
      _pullOpacity = 1;
      _pullOffset = _riseDistance; // 首帧：底栏位置
      _tabsDuration = const Duration(milliseconds: 300);
      _tabsCurve = AylaCurves.auroraquaEaseOut;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _pullOffset = 0); // 次帧：升到顶部
    });
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    const double stageHeight = AylaGroupTopTabs.barHeight + _riseDistance;

    if (_home) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 375,
            height: stageHeight,
            child: Stack(
              children: <Widget>[
                // 内容区：**只有它参与页面转场** ——
                // web `PageTransition.tsx:1–10` 的 FadeInCard（新页 0.95→1 + 淡入 500ms --ease-out、
                // 旧页 300ms --ease-in-out 淡出），且 `AppShell.tsx` 的 `AnimatePresence` 只包 `<main>` 里的 outlet。
                Positioned.fill(
                  bottom: AylaGroupTopTabs.barHeight, // 内容位于底栏之上
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 500),
                    curve: AylaCurves.easeOut,
                    builder: (
                      BuildContext context,
                      double v,
                      Widget? child,
                    ) =>
                        Opacity(
                      opacity: v,
                      child: Transform.scale(
                        scale: 0.95 + 0.05 * v,
                        child: child,
                      ),
                    ),
                    child: const DecoratedBox(
                      decoration: BoxDecoration(color: Color(0x1AFFFAFB)),
                      child: Center(child: Text('主页内容（群列表）')),
                    ),
                  ),
                ),
                // 底栏：**壳层常驻元素，不参与页面转场** ——
                // `AppShell.tsx` 里 `<BottomTabs>` 在 `<main>` 之外，转场动画只管 outlet。
                const Align(
                  alignment: Alignment.bottomCenter,
                  child: AylaBottomTabs(module: AylaPrimaryModule.home),
                ),
              ],
            ),
          ),
            const SizedBox(height: AylaSpacing.sp2),
            Text(
              '已回主页（web navigate("/group") → 页面转场：新页 0.95→1 / 500ms easeOut）',
              style: t.caption.copyWith(color: AylaColors.textSecondary),
            ),
            const SizedBox(height: AylaSpacing.sp2),
            GlassButton(
              label: '重新进群（顶栏从底栏位置升起 300ms）',
              variant: GlassButtonVariant.ghost,
              onPressed: _reenter,
            ),
          ],
        );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          width: 375,
          // ★ 舞台高 = 条高 + 行程：下移满行程时顶栏正好贴底（= web 的
          // `translate: 0 calc(100dvh - 64px - env(safe-area-inset-bottom))` 那一帧）
          height: stageHeight,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: _onDragUpdate,
            onVerticalDragEnd: _onDragEnd,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AylaColors.glassBg.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(AylaRadii.rInput),
              ),
              child: Stack(
                children: <Widget>[
                  // 内容区（web `pullY` + `pullOpacity` 协同层）：让「下滑出屏」可见
                  Positioned.fill(
                    top: AylaGroupTopTabs.barHeight,
                    child: Opacity(
                      opacity: _pullOpacity,
                      child: Transform.translate(
                        offset: Offset(0, _pullY),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: AylaColors.surface.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(AylaRadii.rCard),
                          ),
                          child: Center(
                            child: Text(
                              '群聊内容（下拉 ≥80px 回主页）',
                              style: t.caption.copyWith(
                                color: AylaColors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 顶栏（web `tabsTransform = translateY(pullOffset)`）
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: _riseDistance, end: _pullOffset),
                    duration: _dragging ? Duration.zero : _tabsDuration,
                    curve: _tabsCurve,
                    builder: (
                      BuildContext context,
                      double dy,
                      Widget? child,
                    ) =>
                        Transform.translate(
                      offset: Offset(0, dy),
                      child: child,
                    ),
                    child: AylaGroupTopTabs(
                      groupName: '深夜电台',
                      activeScene: _scene,
                      postUnread: _postUnread,
                      onSelectScene: (AylaGroupScene next) => setState(() {
                        _scene = next;
                        _infoOpen = false;
                        if (next == AylaGroupScene.posts) _postUnread = 0;
                      }),
                      onAvatarClick: _onAvatarTap,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: AylaSpacing.sp2),
        Text(
          '场景：${_scene.label}${_infoOpen ? '（群信息已打开）' : ''}'
          ' · 下拉 ${_pullY.round()}px（阈值 80）· 内容 opacity ${_pullOpacity.toStringAsFixed(2)}',
          style: t.caption.copyWith(color: AylaColors.textSecondary),
        ),
        const SizedBox(height: AylaSpacing.sp2),
        Wrap(
          spacing: AylaSpacing.sp2,
          children: <Widget>[
            GlassButton(
              label: '回聊天（点头像）',
              variant: GlassButtonVariant.ghost,
              onPressed: _onAvatarTap,
            ),
            GlassButton(
              label: '直接回主页（等价下拉 ≥80px）',
              variant: GlassButtonVariant.ghost,
              onPressed: () => setState(_exitToHome),
            ),
          ],
        ),
      ],
    );
  }
}
// ======================= 预览 =======================

/// 窄屏群内顶栏（可交互：点 tab 看胶囊迁移；帖子 tab 有未读红点）。
@Preview(
  group: 'Widgets',
  name: 'GroupTopTabs 窄屏（可交互：切场景 / 点头像回聊天 / 重播入场）',
  size: Size(375, 360),
  wrapper: previewTheme,
)
Widget aylaGroupTopTabsPreview() => aylaGroupTopTabsSamples();

/// 入场位移形态：父级注入 offset（`translate: 0 calc(100dvh - 64px - safe)` → `0 0`）的起点。
@Preview(
  group: 'Widgets',
  name: 'GroupTopTabs 入场起点（父级 offset）',
  size: Size(375, 220),
  wrapper: previewTheme,
)
Widget aylaGroupTopTabsOffsetPreview() {
  return const Padding(
    padding: EdgeInsets.all(AylaSpacing.sp4),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          width: 375,
          child: AylaGroupTopTabs(
            groupName: '深夜电台',
            activeScene: AylaGroupScene.live,
            offset: Offset(0, 40), // 父级驱动中的中间帧示例
          ),
        ),
      ],
    ),
  );
}
