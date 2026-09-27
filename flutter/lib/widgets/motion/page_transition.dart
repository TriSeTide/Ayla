/// 路由转场（`AylaPageTransition` + `AylaPageSwap`）—— web `components/motion/PageTransition.tsx`
/// 117 行 + `layout/AppShell.tsx:113` 的 `AnimatePresence(mode="sync")`。
///
/// ## 事实源
/// ```
/// tsx 84–93   初始态：普通路由 {opacity 0, y +20, scale .95}；搜索页 y −20；
///             群页 / reduced-motion 只 {opacity 0}（无位移无缩放）；panelOwned 全终值
/// tsx 94–102  进入：{opacity 1, y 0, scale 1}，500ms，ease cubic-bezier(0,0,.58,1)
/// tsx 103     退出：{opacity 0}，300ms，ease cubic-bezier(.42,0,.58,1)
/// tsx 20–67   resolvePageKey 的 5 条归一规则 + matchGroupId
/// shell.css 34–44  .page-transition { position absolute; inset 0 }（撑满内容区，不占布局）
/// ```
/// 参数同源 `auroraquaMotion.ts`：distance 20 / fadeScale .95 / fadeDuration .5 / easeOut [0,0,.58,1] /
/// easeInOut [.42,0,.58,1] —— 库内已有同值曲线 `AylaCurves.auroraquaEaseOut` / `auroraquaEaseInOut`。
///
/// ## 机制差异（登记）
/// - web 的 **`exit` 由宿主驱动**（`AnimatePresence mode="sync"`：新页挂载后保留旧页 300ms）⇒
///   Flutter 无等价物，本文件提供 **[AylaPageSwap]** 作配套宿主（按 key 保旧页 + 淡出），
///   与 [AylaPageTransition]（只负责进入）成对交付，**不依赖路由基座**。
/// - `.page-transition` 的 `position: absolute; inset: 0` 由**宿主**表达（内容区给 bounded 约束；
///   叠放用 `Stack` + `Positioned.fill`）⇒ 本件不自带定位。
/// - `resolvePageKey` / `matchGroupId` 是 react-router `matchPath` 的移植 ⇒ 落在顶层纯函数
///   [aylaResolvePageKey] / [aylaMatchGroupId]（可单测，不引路由依赖）。
///
/// ## 公开面
/// `AylaPageTransition` · `AylaPageSwap` · `aylaResolvePageKey` · `aylaMatchGroupId` · `kAylaGroupPatterns`
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// 群页路由模式（web `GROUP_PATTERNS`；与 `shellConfig.isGroupScene` 同源，返回 groupId 供 key 归一化）。
const List<String> kAylaGroupPatterns = <String>[
  '/group/:id',
  '/group/:id/:scene',
  '/group/:id/posts/:postId',
  '/group/:id/voice/:voiceChannelId',
  '/group/:id/live/:liveChannelId',
];

/// 单条模式匹配（等价 react-router `matchPath({ path, end: true })`）：返回 `:name` 段；不匹配 ⇒ null。
Map<String, String>? _matchPath(String pattern, String pathname) {
  final List<String> p = pattern.split('/');
  final List<String> a = pathname.split('/');
  if (p.length != a.length) return null;
  final Map<String, String> params = <String, String>{};
  for (int i = 0; i < p.length; i++) {
    if (p[i].startsWith(':')) {
      if (a[i].isEmpty) return null;
      params[p[i].substring(1)] = a[i];
    } else if (p[i] != a[i]) {
      return null;
    }
  }
  return params;
}

/// 群页的 groupId（非群页 ⇒ null）。web `matchGroupId`（tsx 29–35）。
String? aylaMatchGroupId(String pathname) {
  for (final String pattern in kAylaGroupPatterns) {
    final String? id = _matchPath(pattern, pathname)?['id'];
    if (id != null) return id;
  }
  return null;
}

/// 转场 key 归一化（web `resolvePageKey`，tsx 56–67）：
/// - 群页所有变体 → `/group/:id`（宽屏群壳 → `wide-group-shell`）——避免群内场景切换触发整页重挂载；
/// - 宽屏私聊详情 → `wide-private-chat-shell`（会话列表保持挂载，右侧交给 ConversationTransition）；
/// - 直播间详情 → `/live/room`、开播台 → `/live/start`（避免切台/切频道触发整页重挂载与旧页 cleanup）；
/// - 其余用原始 pathname。
String aylaResolvePageKey(String pathname, {bool wideGroupShell = false}) {
  if (aylaMatchGroupId(pathname) != null) {
    return wideGroupShell ? 'wide-group-shell' : '/group/${aylaMatchGroupId(pathname)}';
  }
  if (wideGroupShell && _matchPath('/chat/:conversationId', pathname) != null) {
    return 'wide-private-chat-shell';
  }
  final String? liveId = _matchPath('/live/:id', pathname)?['id'];
  if (liveId != null && liveId != 'start') return '/live/room';
  if (_matchPath('/live/start/:channelId', pathname) != null) return '/live/start';
  return pathname;
}

/// 页面**进入**转场（web `PageTransition`）：初始态按场景选，500ms `auroraquaEaseOut` 到终态。
///
/// 退出由 [AylaPageSwap] 驱动（web 同：variants 里的 exit 由 AnimatePresence 触发）。
class AylaPageTransition extends StatefulWidget {
  const AylaPageTransition({
    super.key,
    required this.child,
    this.panelOwned = false,
    this.groupScene = false,
    this.searchScene = false,
  });

  /// 页面内容。
  final Widget child;

  /// 面板自编排路由（群场景 / 消息中心 / 各详情页…）：**整页不动**（避免覆盖内部滑入动画）。
  final bool panelOwned;

  /// 群页：只淡入（web `isGroup`）。
  final bool groupScene;

  /// 搜索页：自顶栏下方向下滑出（`y: -20`）。
  final bool searchScene;

  /// 位移量（web `AURORAQUA_MOTION.distance`）。
  static const double distance = 20;

  /// 初始缩放（web `fadeScale`）。
  static const double fadeScale = 0.95;

  /// 进入时长（web `fadeDuration` = 0.5s）。
  static const Duration fadeDuration = Duration(milliseconds: 500);

  /// 退出时长（web `auroraquaRouteTransition` = 0.3s）。
  static const Duration exitDuration = Duration(milliseconds: 300);

  @override
  State<AylaPageTransition> createState() => _AylaPageTransitionState();
}

class _AylaPageTransitionState extends State<AylaPageTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final CurvedAnimation _t;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: AylaPageTransition.fadeDuration,
    );
    _t = CurvedAnimation(parent: _c, curve: AylaCurves.auroraquaEaseOut);
    if (widget.panelOwned) {
      _c.value = 1; // web：initial 即终值 + transition duration 0
    } else {
      _c.forward();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // reduced-motion：无过渡、直接到终值（web reduced 分支 duration 0）
    if (!widget.panelOwned &&
        MediaQuery.disableAnimationsOf(context) &&
        _c.value != 1) {
      _c.value = 1;
    }
  }

  @override
  void dispose() {
    _t.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool reduced = MediaQuery.disableAnimationsOf(context);
    // 位移与缩放只在「普通路由且未 reduced」时存在（群页只淡入）
    final bool displacement =
        !widget.panelOwned && !reduced && !widget.groupScene;
    final double fromY = displacement
        ? (widget.searchScene
              ? -AylaPageTransition.distance
              : AylaPageTransition.distance)
        : 0;
    final double fromScale = displacement ? AylaPageTransition.fadeScale : 1;
    return AnimatedBuilder(
      animation: _t,
      builder: (BuildContext context, Widget? child) {
        final double v = widget.panelOwned ? 1 : _t.value;
        return Opacity(
          opacity: v,
          child: Transform.translate(
            offset: Offset(0, fromY * (1 - v)),
            child: Transform.scale(
              scale: fromScale + (1 - fromScale) * v,
              child: child,
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// 页面互换宿主（`AppShell.tsx:113` 的 `AnimatePresence mode="sync"` 等价物）。
///
/// [pageKey] 变化：**新页立即挂载**（进入动画由 [AylaPageTransition] 负责），**旧页保留 300ms 淡出**
/// 后卸载 —— 与 web「sync + `.page-transition` absolute（手动 popLayout）」同语义：新旧页重叠转场。
class AylaPageSwap extends StatefulWidget {
  const AylaPageSwap({
    super.key,
    required this.pageKey,
    required this.builder,
    this.duration = AylaPageTransition.exitDuration,
  });

  /// 页面身份（建议传 [aylaResolvePageKey] 的结果）；变化即换页。
  final Object pageKey;

  /// 页面构建器（返回 [AylaPageTransition] / `AylaPrimaryNavPage` 等）。
  final WidgetBuilder builder;

  /// 旧页淡出时长（web 退出 300ms）。
  final Duration duration;

  @override
  State<AylaPageSwap> createState() => _AylaPageSwapState();
}

class _AylaPageSwapState extends State<AylaPageSwap>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  /// 正在退出的旧页（淡出结束后置 null 卸载）。
  Widget? _leaving;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: widget.duration, value: 1)
      ..addStatusListener((AnimationStatus status) {
        if (status == AnimationStatus.dismissed && mounted) {
          setState(() => _leaving = null);
        }
      });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // reduced-motion：旧页立即卸载（web reduced 分支 duration 0）
    _c.duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : widget.duration;
  }

  @override
  void didUpdateWidget(AylaPageSwap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageKey == widget.pageKey) return;
    setState(() {
      // 旧页定格：用**上一帧的 builder** 重建（元素按 key 复用 ⇒ 淡出期间状态不丢）
      _leaving = KeyedSubtree(
        key: ValueKey<Object?>(oldWidget.pageKey),
        child: Builder(builder: oldWidget.builder),
      );
    });
    _c
      ..value = 1
      ..reverse();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget current = KeyedSubtree(
      key: ValueKey<Object?>(widget.pageKey),
      child: Builder(builder: widget.builder),
    );
    final Widget? leaving = _leaving;
    if (leaving == null) return current;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        // 旧页在下（淡出）、新页在上：两页重叠转场（web 同）
        FadeTransition(opacity: _c, child: leaving),
        current,
      ],
    );
  }
}
