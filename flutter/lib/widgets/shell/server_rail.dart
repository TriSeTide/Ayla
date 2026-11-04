/// ServerRail —— 宽屏服务器栏（design.md §12.3，布局文档 §3.2）。
///
/// ## 事实源
/// - layout/ServerRail.tsx（184 行）：DOM 结构、hover 面板锚点算法、关闭延迟、
///   置顶动作与未读求和；
/// - group.css 484–678：.server-rail / -list / -item / -avatar /
///   -badge / -pin / .server-pop* / -foot / .server-create-btn；
/// - auroraqua.css **4 条覆写**（最后加载，必须生效）：
///   ① 216 .server-item.has-auroraqua-highlight.is-active::before { content:none }
///      ⇒ group.css 549–559 那条 ::before 指示条**永不显示**，真正的指示条是
///      子元素 .auroraqua-nav-highlight--rail（217–229）；
///   ② 270 .server-rail { margin-right: 0 } ⇒ 外距 12 / 0 / 12 / 12；
///   ③ 311–313（min-width:769px）.server-rail { animation: none }
///      ⇒ 入场由 Framer 负责（panelVariants(reduced,'left')）；
///   ④ 125–138 把 .server-create-btn 并入按钮族 ⇒ 材质 --glass-bg +
///      blur(8px)（**无 saturate**）+ --glass-shadow-button，hover 换
///      -button-hover（0,3,0 特异性胜过 group.css 675 的 glow）；
/// - home.css 560–588（.avatar-status-badge*）、302–333（.group-badge*）；
/// - components/motion/auroraquaMotion.ts 37–51（左入 −20px + 300ms easeInOut）。
///
/// ## 与 web 的三处显式等价（写在代码里，避免后续 agent「复刻回去」）
/// 1. **1px 内边距补位**：CSS 的 border 占布局（内容区 70），Flutter 的
///    BoxDecoration(border:) 不占位 ⇒ 用 AylaGlassSurface(padding: 1px) 补齐，
///    否则行宽 72≠70、浮层锚点整体偏 1px；
/// 2. **面板走 Overlay**：Flutter 的溢出子元素**画得出来但收不到指针**
///    （RenderBox.hitTest 先判断命中点在自己 bounds 内）⇒ web 的 absolute 溢出
///    只能用 Overlay 等价实现（库内范本 conversation_more_menu / top_nav）；
/// 3. **面板锚点取「行」而非「头像」**：ServerRail.tsx:105–114 的 e.currentTarget
///    是 li.server-item（整行 100% 宽），注释写「头像右侧」与实现不符 —— 以实现为准。
///
/// ## 公开面
/// `AylaServerRailGroup` · `AylaServerRail` · 样张 `aylaServerRailSamples()`

library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_icons.dart';
import '../../theme/app_theme.dart';
import '../../theme/buttons.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import '../base/avatar_halo.dart';
import '../base/avatar_status_badges.dart';
import '../base/directory_controls.dart';
import '../base/menu_item.dart';
import '../base/overlays.dart';
import '../base/primitives.dart';
import '../base/reveal.dart';
import '../base/tab_badge.dart';

/// ServerRail 的群条目（视图模型；对应 ConversationSummary 中被本组件用到的字段）。
class AylaServerRailGroup {
  const AylaServerRailGroup({
    required this.id,
    required this.title,
    this.avatarUrl,
    this.isPinned = false,
    this.unreadCount = 0,
    this.postUnreadCount = 0,
    this.presence = const AylaAvatarStatus(),
  });

  /// 群 id（切群/选中判定）。
  final String id;

  /// 群名（头像首字 + 面板标题 + 无障碍）。
  final String title;

  /// 群头像 URL（空串在 web 侧等价 null，见 tsx 129 g.avatar || null）。
  final String? avatarUrl;

  /// 是否置顶（is_pinned）→ 头像左上角 45° 粉 pin。
  final bool isPinned;

  /// 消息未读数（unread_count）。
  final int unreadCount;

  /// 群内未读帖子数（post_unread_count ?? 0）。
  final int postUnreadCount;

  /// 直播/语音/桌游存在状态（useGroupPresenceMap() 的投影）。
  final AylaAvatarStatus presence;

  /// 群头像红点数 = 消息未读 + 群内未读帖子数（ServerRail.tsx:138）。
  int get totalUnread => unreadCount + postUnreadCount;
}

/// 宽屏群服务器列（72px 玻璃列）。
///
/// **高度由父约束**（宽屏三列 shell 的一行拉伸；web 同为 flex 行内 flex:none），
/// 内部列表自持滚动。GroupPage.tsx:409–414 是 web 的装配点。
///
/// ## 入场 owner：**页面（GroupPage）**，不是本件
///
/// 见 [AylaServerRail.animateEntrance] 的文档 —— 本件只负责「按传入的开关播/不播」，
/// 「什么时候该播」由持有宽屏三列 shell 的页面决定。
class AylaServerRail extends StatefulWidget {
  const AylaServerRail({
    super.key,
    required this.groups,
    required this.currentGroupId,
    required this.onSelectGroup,
    required this.onCreateGroup,
    required this.loadMore,
    required this.refresh,
    this.onTogglePin,
    this.loading = false,
    this.error,
    this.hasMore = false,
    this.invalidated = false,
    this.animateEntrance = true,
    this.previewHoveredGroupId,
  });

  /// 我的群（web 传 sortedGroups）。
  final List<AylaServerRailGroup> groups;

  /// 当前群 id（null = 无选中，不画指示条）。
  final String? currentGroupId;

  /// 点头像切换群。
  final ValueChanged<String> onSelectGroup;

  /// 底部加号：打开建群对话框。
  final VoidCallback onCreateGroup;

  /// 目录「加载更多」（对应 useSocialPage 的 loadMore）。
  final Future<void> Function() loadMore;

  /// 目录「重新拉取」（invalidated 时 [AylaDirectoryLoadMore] 自动调用）。
  final Future<void> Function() refresh;

  /// 悬停面板的置顶开关（(groupId, nextIsPinned)）；null = 动作点击无副作用。
  final Future<void> Function(String groupId, bool pinned)? onTogglePin;

  /// 目录分页三态（透传 [AylaDirectoryLoadMore]）。
  final bool loading;

  /// 目录错误文案（非 null 时页脚不渲染）。
  final String? error;

  /// 是否还有更多。
  final bool hasMore;

  /// 加载中数据被更新（触发自动刷新）。
  final bool invalidated;

  /// 本次是否播**入场**（web `panelVariants(reduced,'left')`）。
  ///
  /// 语义是 **replay 开关**（不是「只给首帧用」）：从 false 翻到 true 的那一刻播一次，
  /// 之后保持 true 不重播；由 false 变回 false 不动作。
  ///
  /// ## 为什么由页面传、本件不自持状态（2026-11-02 用户实报「每次进主页都滑入」）
  ///
  /// web 事实源（`auroraqua.css:293` 的 `@media (min-width:769px)` 内 `310–313`）：
  ///
  /// ```css
  /// /* 宽屏进入/切群由React motion按各自owner编排，避免叠加CSS整列入场。 */
  /// .server-rail, .channel-sidebar, .wide-messages-sidebar { animation: none; }
  /// ```
  ///
  /// ⇒ 入场**不是 CSS 的「挂载即播」**，而是 `ServerRail.tsx:90–99` 的 `motion.nav`
  /// 按 `initial={reduced ? false : "enter"} animate="center"` 播一次。
  /// 这个 owner 的生命周期边界 = **宽屏群工作区外壳**：
  /// `PageTransition.tsx:56–60` 把 `/group/*` 归一成 `wide-group-shell` 作 page key
  /// ⇒ 只有**首次进入主页**（或离开主页后再进来）才会挂载这个 owner；
  /// 主页内**切群 / 切场景**只换 prop，owner 不重挂 ⇒ 第一列**不该滑入**（design.md §12.3
  /// 原话：「首次进入主页的左移入场与同一主页内切群须由不同生命周期边界控制，
  /// 避免第一列反复滑入」）。
  ///
  /// Flutter 侧的等价边界见 `pages/group_page.dart` 的 `kAylaGroupPageEntered`：
  /// 判定在 **GroupPage 的 State 生命周期**上做（挂载=进主页 ⇒ 播；切群/切场景=复用 State ⇒ 不播），
  /// 本件只按传入值渲染。**不要**改回「本件自己记一个模块级标记」——
  /// 那样「离开主页再回来」也不会播了（web 那里是会播的，因为外壳被重新挂载）。
  final bool animateEntrance;

  /// **只用于预览/画布样张**：强制显示某个群的悬停面板（无鼠标事件）。
  final String? previewHoveredGroupId;

  /// 列宽（width: 72px，group.css 488）。
  static const double railWidth = 72;

  /// 列圆角（border-radius: var(--radius-card)，group.css 500）。
  static const double railRadius = AylaRadii.rCard;

  /// 头像直径（`<Avatar label size={48} online/>`，tsx 129）。
  static const double avatarSize = 48;

  /// 头像外框（含 2.5px 光环）= 48 + 2.5×2 = 53 —— web .server-item-avatar
  /// 的 inline-flex 尺寸同值，也是选中放大 scale(52 / 48) 的作用对象。
  ///
  /// **必须显式给尺寸**：AylaAvatarStatusBadges 的内部 Stack 全是 positioned
  /// 子（自身无固有尺寸），若外层 Stack 收到无界约束就会断言 size.isFinite。
  static const double avatarFrameSize = avatarSize + AylaAvatarHalo.haloWidth * 2;

  /// 列表顶部内边距（calc(var(--sp-4) + var(--sp-1))，group.css 516）。
  static const double listPaddingTop = 20;

  /// 列表底部内边距 77（53 加号 + 8 间隙 + 16 底距，group.css 514/516）。
  static const double listPaddingBottom = 77;

  /// 头像间距（gap: var(--sp-3)，group.css 511）。
  static const double itemGap = AylaSpacing.sp3;

  /// 选中头像放大（transform: scale(52 / 48)，group.css 545–546）。
  static const double activeAvatarScale = 52 / 48;

  /// 头像缩放过渡（transition: transform var(--dur-fast) var(--ease-out)，542）。
  static const Duration avatarScaleDuration = AylaDurations.fast;

  /// 指示条宽（width: 3px，auroraqua.css 222）。
  static const double indicatorWidth = 3;

  /// 指示条高（height: 32px，auroraqua.css 223）。
  static const double indicatorHeight = 32;

  /// 加号边长（.server-create-btn width/height: 53px，group.css 663–664）。
  static const double createButtonSize = 53;

  /// 加号距底（.server-rail-foot bottom: var(--sp-4)，group.css 651）。
  static const double footBottom = AylaSpacing.sp4;

  /// 悬停面板关闭延迟（tsx 29 POP_CLOSE_DELAY_MS = 180）。
  static const Duration popCloseDelay = Duration(milliseconds: 180);

  /// 面板最小宽（.server-pop min-width: 136px，group.css 600）。
  static const double popMinWidth = 136;

  /// 面板最大宽（.server-pop max-width: 200px，group.css 601）。
  static const double popMaxWidth = 200;

  /// 面板左缘与行的间距（tsx 113 rect.right - railRect.left + 2）。
  static const double popGap = 2;

  /// 列表顶部渐隐高度（mask-image 的 #000 20px，group.css 522）。
  static const double listFadeTop = 20;

  /// 列表底部渐隐高度（mask-image 的 calc(100% - 16px)，group.css 523）。
  static const double listFadeBottom = 16;

  /// 外距（margin: var(--sidebar-gutter)，group.css 501）被 auroraqua.css 270
  /// 覆写 margin-right: 0 ⇒ **右 0**。
  static const EdgeInsets wideMargin = EdgeInsets.fromLTRB(12, 12, 0, 12);

  /// 玻璃列 1px 边框宽（border: 1px solid var(--glass-border)，group.css 499）；
  /// 面板定位的 padding-box 换算用，也是列表 1px 内边距补位值。
  static const double railBorderWidth = 1;

  @override
  State<AylaServerRail> createState() => _AylaServerRailState();
}

class _AylaServerRailState extends State<AylaServerRail> {
  /// 列表内容 Stack（滚动内容坐标系；指示条与行的共同父级）。
  final GlobalKey _contentKey = GlobalKey();

  /// 每行一个 key（指示条位置与面板锚点实测用，几何不靠推算）。
  final Map<String, GlobalKey> _itemKeys = <String, GlobalKey>{};

  /// 指针所在行 id（web 是 :hover 谓词；Flutter 侧记录后由 build 求值）。
  String? _hoveredId;

  /// 悬停面板锚点（相对**根 Overlay** 的绝对坐标）。
  Offset? _popAnchor;

  /// 关闭延迟计时器（tsx scheduleClose / cancelClose）。
  Timer? _closeTimer;

  /// 悬停面板的 Overlay entry。
  ///
  /// **必须走 Overlay**：Flutter 的 RenderBox.hitTest 先判断命中点是否落在
  /// 自己 bounds 内 —— 溢出父级边界的子元素**画得出来却收不到指针**（实测：
  /// 面板可见但点不动）。web 的 position:absolute 溢出仍可交互，等价实现只有
  /// Overlay（库内范本：conversation_more_menu / top_nav 浮层）。
  OverlayEntry? _popEntry;

  /// 置顶请求中的群 id（busyId；期间动作项 :disabled）。
  String? _busyId;

  /// 指示条在列表内容坐标系的 top（null = 无选中）。
  double? _indicatorTop;

  /// 已测量的选中 id（避免重复 setState）。
  String? _indicatorId;

  /// 入场动画的**重播代号**（每次该播入场就 +1）。
  ///
  /// ## 为什么需要「代号」而不是一个 bool（2026-11-02 用户实报）
  ///
  /// `AylaRevealItem` 只在自己**被新建**时才播入场（`initState` → `_startEntry`）；
  /// 同一个 widget 实例被复用时它不会再播。而这里「该不该播」是**页面传下来的开合位**
  /// （[AylaServerRail.animateEntrance]），它可能在**本件 State 已经存在**的同一时刻
  /// 由 false 翻成 true（例：主页外壳被复用、但工作区被要求重播入场）。
  /// ⇒ 光靠 bool 无法把「请再播一次」表达给已经存在的 `AylaRevealItem`
  /// ⇒ 用 `ValueKey(代号)` 换掉它（**只重挂入场层，不重挂列本身**：
  /// 列表滚动位置、悬停面板、指示条测量全在 [State] 上，不受影响）。
  int _enterTick = 0;

  /// 是否已按当前 [AylaServerRail.animateEntrance] 播过（防每帧重播）。
  bool _enterPlayed = false;

  @override
  void initState() {
    super.initState();
    _syncEnter();
    _syncKeys();
    _scheduleLayoutSync();
  }

  /// 依据 [AylaServerRail.animateEntrance] 决定是否（重新）播入场。
  ///
  /// 语义见该参数的文档：**false → true 的那一刻播一次**，true 期间不重播。
  void _syncEnter() {
    if (!widget.animateEntrance) {
      _enterPlayed = false; // 复位：下一次翻 true 时再播
      return;
    }
    if (_enterPlayed) return;
    _enterPlayed = true;
    _enterTick += 1;
    // 无需 setState：`_syncEnter()` 由 `initState` / `didUpdateWidget` 调用，
    // 而 `Element.update` 在 `didUpdateWidget` 之后**紧接着**就会跑本件 build
    // ⇒ 本帧读到的一定是推进后的 [_enterPlayed] / [_enterTick]。
  }

  @override
  void didUpdateWidget(covariant AylaServerRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncEnter();
    _syncKeys();
    // ⚠️ **必须按 id 序列比较，不能只比长度**（2026-10-02 用户实报：
    // 「重新排序后那个导航条没跟上去，还停留在原位置」）。
    //
    // 原先的判据是「currentGroupId 变 || groups.length 变」。而**热更新排序**恰好
    // 两者都不变（还是同一批群、当前群也没变，只是**顺序**变了）
    // ⇒ 不重测 ⇒ 指示条的 `top` 停留在重排前的旧值 ⇒ 视觉上「条留在原位、
    // 行已经移走」。
    //
    // web 侧不存在这个问题：framer 的 `layoutId`（`AuroraquaNavHighlight` 走
    // `motion.li layout`）是**按 DOM 实测位置每帧自动迁移**的，不依赖调用方判断
    // 「是否需要重测」。Flutter 用 `AnimatedPositioned` 手动驱动 ⇒ 必须自己补上
    // 「顺序变化」这一条。
    if (widget.currentGroupId != oldWidget.currentGroupId ||
        !_sameOrder(widget.groups, oldWidget.groups)) {
      _scheduleLayoutSync();
    }
  }

  /// 两组群列表的 **id 序列**是否相同（顺序敏感）。
  ///
  /// 用于判定「是否需要重测指示条位置」：长度相同但顺序不同的重排也必须重测。
  static bool _sameOrder(
    List<AylaServerRailGroup> a,
    List<AylaServerRailGroup> b,
  ) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i += 1) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _closeTimer?.cancel();
    _popEntry?.remove();
    _popEntry = null;
    super.dispose();
  }

  /// 列表变化时同步 key 集合（删掉的群不再持有 GlobalKey）。
  void _syncKeys() {
    final Set<String> ids = widget.groups
        .map((AylaServerRailGroup g) => g.id)
        .toSet();
    _itemKeys.removeWhere((String id, GlobalKey key) => !ids.contains(id));
    for (final AylaServerRailGroup g in widget.groups) {
      _itemKeys.putIfAbsent(g.id, () => GlobalKey());
    }
  }

  /// 布局完成后测量（首帧、切群、列表长度变化）。
  void _scheduleLayoutSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _measureIndicator();
      final String? popId = _activePopId;
      if (popId != null && _popAnchor == null) {
        _measurePopAnchor(popId);
      }
    });
  }

  /// 当前应展开面板的群 id（真实 hover 优先；预览注入兜底）。
  String? get _activePopId => _hoveredId ?? widget.previewHoveredGroupId;

  RenderBox? _boxOf(GlobalKey key) =>
      key.currentContext?.findRenderObject() as RenderBox?;

  /// 指示条位置 = 选中行的垂直中心 − 16（web top:50%; margin-top:-16px 相对 li，
  /// auroraqua.css 220–221）。
  void _measureIndicator() {
    final String? id = widget.currentGroupId;
    if (id == null) {
      if (_indicatorTop != null || _indicatorId != null) {
        setState(() {
          _indicatorTop = null;
          _indicatorId = null;
        });
      }
      return;
    }
    final GlobalKey? itemKey = _itemKeys[id];
    if (itemKey == null) return;
    final RenderBox? item = _boxOf(itemKey);
    final RenderBox? content = _boxOf(_contentKey);
    if (item == null || content == null) return;
    final Offset offset = item.localToGlobal(Offset.zero, ancestor: content);
    final double top =
        offset.dy + (item.size.height - AylaServerRail.indicatorHeight) / 2;
    if (_indicatorTop == top && _indicatorId == id) return;
    setState(() {
      _indicatorTop = top;
      _indicatorId = id;
    });
  }

  /// 面板锚点（tsx 107–114）：
  ///
  ///     top  = rect.top  - railRect.top  + rect.height / 2   // li 的垂直中心
  ///     left = rect.right - railRect.left + 2                // li 右缘 + 2
  ///
  /// 这两个值当作 CSS left/top 使用 → 包含块是 rail 的 **padding box**，而
  /// getBoundingClientRect 相减得到的是 **border box** 距离 ⇒ 实际渲染位置
  /// = 该值 + 1px 边框。这里直接换算成**浮层所在那个 Overlay 的绝对坐标**：
  ///
  ///     left = 行右缘 + popGap(2) + 1px 边框
  ///     top  = 行中心 + 1px 边框（随后由 translateY(-50%) 上移半个自身高度）
  void _measurePopAnchor(String id) {
    final GlobalKey? itemKey = _itemKeys[id];
    if (itemKey == null) return;
    final RenderBox? item = _boxOf(itemKey);
    // ⚠️ 与 [_syncPopOverlay] 的插入点**必须是同一个 Overlay**（下面取它的
    // RenderBox 做坐标换算）：画布/测试宿主（`theme/preview_theme.dart:55`）没有
    // Navigator ⇒ `rootOverlay: true` 找不到 Overlay 会返回 null，本方法直接
    // return ⇒ 悬停面板在画布里永远不弹（2026-10-02 同一处修复）。真实 app 里
    // 最近的 Overlay 就是 MaterialApp Navigator 的那个（= root）⇒ 等价。
    final OverlayState? overlay = Overlay.maybeOf(context);
    final RenderBox? overlayBox =
        overlay?.context.findRenderObject() as RenderBox?;
    if (item == null || overlayBox == null) return;
    final Offset topLeft = item.localToGlobal(
      Offset.zero,
      ancestor: overlayBox,
    );
    final Offset bottomRight = item.localToGlobal(
      item.size.bottomRight(Offset.zero),
      ancestor: overlayBox,
    );
    final Offset anchor = Offset(
      bottomRight.dx + AylaServerRail.popGap + AylaServerRail.railBorderWidth,
      (topLeft.dy + bottomRight.dy) / 2 + AylaServerRail.railBorderWidth,
    );
    setState(() {
      _hoveredId = id;
      _popAnchor = anchor;
    });
    _syncPopOverlay();
  }

  void _cancelClose() {
    _closeTimer?.cancel();
    _closeTimer = null;
  }

  /// 鼠标离开行/面板 → 180ms 后收起（在途会被行/面板的进入取消）。
  void _scheduleClose() {
    if (_hoveredId == null) return;
    _cancelClose();
    _closeTimer = Timer(AylaServerRail.popCloseDelay, () {
      if (!mounted) return;
      setState(() {
        _hoveredId = null;
        _popAnchor = null;
      });
      _syncPopOverlay(); // 移除浮层 entry
    });
  }

  Future<void> _togglePin(AylaServerRailGroup g) async {
    final Future<void> Function(String, bool)? callback = widget.onTogglePin;
    if (callback == null) return;
    setState(() => _busyId = g.id);
    try {
      await callback(g.id, !g.isPinned);
    } catch (_) {
      // ServerRail.tsx:80–84：置顶失败**静默**（不弹错、不回滚——store 只在
      // .then 里更新）。此处保持同一语义，同时避免未处理异常冒泡到框架。
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  /// reduced-motion（web `usePrefersReducedMotion`）：`initial={reduced ? false : "enter"}`
  /// ⇒ 直接到终态、**不挂**入场层。
  bool get _reduceMotion => MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  @override
  Widget build(BuildContext context) {
    Widget rail = Padding(
      padding: AylaServerRail.wideMargin,
      child: SizedBox(
        width: AylaServerRail.railWidth,
        child: Stack(
          // 底部加号与指示条都在列内；悬停面板改走 Overlay（见 [_popEntry]）。
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned.fill(child: _glassColumn()),
            _createButton(),
          ],
        ),
      ),
    );

    // 入场**开关由调用方给**（[AylaServerRail.animateEntrance] 的长注释说明了 owner 边界）。
    // ⚠️ key 必须带 [_enterTick]：`AylaRevealItem` 只在**新建**时播入场，
    // 复用同一实例时「再播一次」的请求会被它静默忽略（见 [_enterTick] 的注释）。
    if (_enterPlayed && !_reduceMotion) {
      // panelVariants(reduced, "left")（auroraquaMotion.ts 37–51）：
      // x −20 → 0 + opacity 0 → 1，duration 0.3 easeInOut。
      rail = AylaRevealItem(
        key: ValueKey<int>(_enterTick),
        fadeGlass: false,
        offset: const Offset(-AylaRevealMotion.distance, 0),
        duration: AylaDurations.auroraqua,
        curve: AylaCurves.auroraquaEaseInOut,
        child: rail,
      );
    }
    return rail;
  }

  /// 玻璃列本体：--glass-bg + --glass-filter(blur24 sat1.4) + 1px --glass-border
  /// + --glass-shadow + radius 16（group.css 491–500）。
  ///
  /// **1px 内边距是必须的**：CSS 的 border 占布局（box-sizing: border-box 下
  /// 内容区 = 72 − 2×1 = 70），而 Flutter 的 BoxDecoration(border:) **不占位**
  /// → 列表会宽 2px、行右缘与 web 差 1px，浮层锚点随之偏移（实测差 1px）。
  /// 补这 1px 后行宽 70、行右缘 = 71（相对 rail 外框），与 web 完全一致。
  Widget _glassColumn() {
    return AylaGlassSurface(
      radius: AylaServerRail.railRadius,
      padding: const EdgeInsets.all(AylaServerRail.railBorderWidth),
      child: Column(children: <Widget>[Expanded(child: _listArea())]),
    );
  }

  /// 滚动列表区（clip-path + mask-image + overflow-y: auto）。
  Widget _listArea() {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double h = c.maxHeight.isFinite ? c.maxHeight : 0;
        return ClipRRect(
          // clip-path: inset(0 round calc(var(--radius-card) - 1px))（group.css 521）
          borderRadius: BorderRadius.circular(AylaServerRail.railRadius - 1),
          child: ShaderMask(
            // mask-image: linear-gradient(to bottom, transparent 0, #000 20px,
            // #000 calc(100% - 16px), transparent 100%)（group.css 522–523）——
            // 上 20px / 下 16px 渐隐。stops 按**实际视口高度**换算，不能写死比例。
            blendMode: BlendMode.dstIn,
            shaderCallback: (Rect bounds) {
              double stopTop = h > 0 ? AylaServerRail.listFadeTop / h : 0.0;
              double stopBottom = h > 0
                  ? (h - AylaServerRail.listFadeBottom) / h
                  : 1.0;
              stopTop = stopTop.clamp(0.0, 1.0);
              stopBottom = stopBottom.clamp(0.0, 1.0);
              if (stopBottom < stopTop) stopBottom = stopTop;
              return LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: const <Color>[
                  Color(0x00000000), // transparent
                  Color(0xFF000000), // #000
                  Color(0xFF000000), // #000
                  Color(0x00000000), // transparent
                ],
                stops: <double>[0, stopTop, stopBottom, 1],
              ).createShader(bounds);
            },
            // overflow-y: auto; overflow-x: hidden（group.css 517–518）。
            // 滚动条：web **全局隐藏**原生滚动条（base.css 372–383），自绘覆盖层条
            // 由 OverlayScrollbar 组件承担（13 号 §B6 待做）。Flutter 桌面端默认给
            // 可滚动组件挂 Scrollbar → 会占宽并引起布局跳动，与 web 不符 ⇒ 关掉。
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(scrollbars: false),
              child: SingleChildScrollView(child: _listContent()),
            ),
          ),
        );
      },
    );
  }

  /// 列表内容：顶部 20 / 底部 77 padding + 行间距 12 + 末尾「加载更多」项
  /// （group.css 511–516；tsx 100–148）。
  Widget _listContent() {
    return Stack(
      key: _contentKey,
      clipBehavior: Clip.none,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(
            top: AylaServerRail.listPaddingTop,
            bottom: AylaServerRail.listPaddingBottom,
          ),
          child: Column(
            spacing: AylaServerRail.itemGap,
            children: <Widget>[
              for (final AylaServerRailGroup g in widget.groups) _item(g),
              // <li><DirectoryLoadMore {...groupPage} retainCompletedSpace={false}/></li>
              // （tsx 147）—— 该 li 恒存在（空页脚也占一个 gap）。
              AylaDirectoryLoadMore(
                loading: widget.loading,
                error: widget.error,
                hasMore: widget.hasMore,
                invalidated: widget.invalidated,
                loadMore: widget.loadMore,
                refresh: widget.refresh,
                retainCompletedSpace: false,
              ),
            ],
          ),
        ),
        // 容器级共享指示条：与行同坐标系 → 随列表滚动一起移动（web 里它是 li 的
        // 子元素，语义相同）。
        if (_indicatorTop != null && _indicatorId != null)
          AnimatedPositioned(
            // framer layoutId 的迁移节奏（auroraquaIndicatorTransition
            // = 300ms [0,0,.58,1]）。
            duration: AylaDurations.auroraqua,
            curve: AylaCurves.auroraquaEaseOut,
            left: 0,
            top: _indicatorTop!,
            width: AylaServerRail.indicatorWidth,
            height: AylaServerRail.indicatorHeight,
            child: const AylaNavHighlight(
              variant: AylaNavHighlightVariant.rail,
            ),
          ),
      ],
    );
  }

  /// .server-item（group.css 526–531）+ .server-item-btn（tsx 121–127）。
  ///
  /// 该行**不在** auroraqua 的按钮组/导航组 :is() 列表内 ⇒ 无 hover 1.02、
  /// 无 :active .98 缩放；Avatar 也没有 onClick ⇒ 无 .avatar-halo-btn 提亮。
  Widget _item(AylaServerRailGroup g) {
    final bool active = g.id == widget.currentGroupId;
    return MouseRegion(
      // `.server-item-btn`（group.css:533–537）在 web 是 <button>（ServerRail.tsx）
      // ⇒ base.css:340 全局 pointer；hover 判定仍在**整行**（onMouseEnter 挂 li.server-item）。
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _handleItemEnter(g),
      onExit: (_) => _scheduleClose(),
      child: SizedBox(
        key: _itemKeys[g.id],
        width: double.infinity, // width: 100%
        child: Row(
          mainAxisAlignment:
              MainAxisAlignment.center, // justify-content: center
          children: <Widget>[
            // **可点区域 = 头像本身**：web 的 .server-item-btn 是 inline-flex，
            // 只包住 53×53 的头像；行两侧空白只有 hover 语义、点不中（如实复刻）。
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onSelectGroup(g.id),
              child: _avatar(g, active),
            ),
          ],
        ),
      ),
    );
  }

  void _handleItemEnter(AylaServerRailGroup g) {
    _cancelClose();
    _measurePopAnchor(g.id);
  }

  Widget _avatar(AylaServerRailGroup g, bool active) {
    return AnimatedScale(
      // .server-item.is-active .server-item-avatar { transform: scale(52 / 48) }
      // + transition: transform var(--dur-fast) var(--ease-out)（group.css 542–547）
      scale: active ? AylaServerRail.activeAvatarScale : 1.0,
      duration: AylaServerRail.avatarScaleDuration,
      curve: AylaCurves.easeOut,
      child: SizedBox(
        width: AylaServerRail.avatarFrameSize,
        height: AylaServerRail.avatarFrameSize,
        child: Stack(
          // 角标 right:-3、pin top:-4 left:-6、未读徽标 left:-3 bottom:-3 都越过
          // 头像边缘（含光环外框 48 + 2.5×2）。
          clipBehavior: Clip.none,
          children: <Widget>[
            AylaAvatarHalo(
              label: g.title,
              size: AylaServerRail.avatarSize,
              online:
                  true, // <Avatar label size={48} online imageUrl/>（tsx 129）
              resourceUrl: g.avatarUrl,
            ),
            // 直播/语音/桌游角标：右下 → 右 → 右上，live > voice > game
            // （AvatarStatusBadges.tsx + badges.ts）。
            AylaAvatarStatusBadges(status: g.presence),
            if (g.isPinned)
              Positioned(
                // .server-item-pin { top:-4; left:-6; z-index:5; rotate(-45deg);
                // pointer-events:none }（group.css 578–587）
                top: -4,
                left: -6,
                child: IgnorePointer(
                  child: Transform.rotate(
                    angle: -math.pi / 4, // rotate(-45deg)
                    child: AylaIcon(
                      aylaIconByName('iconPinFilled')!,
                      size: 16, // <IconPinFilled width={16} height={16}/>
                      color: AylaColors.pink500, // color: var(--pink-500)
                    ),
                  ),
                ),
              ),
            if (g.totalUnread > 0)
              Positioned(
                // .server-item-badge { left:-3; bottom:-3 }（group.css 561–564）——
                // 未读在头像**左下角**（右下/右/右上归状态角标，d:§12.3）
                left: -3,
                bottom: -3,
                child: IgnorePointer(
                  child: AylaTabBadge(
                    count: g.totalUnread,
                    max: 99, // totalUnread > 99 ? "99+" : totalUnread（tsx 140）
                    metrics: AylaTabBadgeMetrics.serverItem,
                    placement: AylaTabBadgePlacement.inline,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// .server-rail-foot + .server-create-btn（group.css 645–678 + auroraqua 125–138）。
  Widget _createButton() {
    return Positioned(
      // .server-rail-foot { position:absolute; left:0; right:0;
      // bottom: var(--sp-4); display:flex; justify-content:center;
      // pointer-events:none }（647–656）—— 空白处放行指针事件到列表，只有加号
      // 本身可交互。Flutter 的 Center/Row 默认不吸收命中（hitTestSelf == false），
      // 语义与 pointer-events:none 一致。
      left: 0,
      right: 0,
      bottom: AylaServerRail.footBottom,
      child: Center(
        child: AylaIconButton(
          // 53×53 pill + --glass-bg + blur(8px)（无 saturate）+ --glass-shadow-button
          // → hover -button-hover + 底 rgba(157,191,230,.18) + scale 1.02/.98：
          // AylaIconButton(size: 53) 逐值对应。
          size: AylaServerRail.createButtonSize,
          icon: AylaIcon(
            aylaIconByName('iconPlus')!,
            size: 22, // <IconPlus width={22} height={22}/>
          ),
          semanticLabel: '创建群聊',
          onPressed: widget.onCreateGroup,
        ),
      ),
    );
  }

  /// .server-pop（group.css 594–643；tsx 160–181）。
  ///
  /// **走 Overlay 的原因**见 [_popEntry]。
  Widget _buildPopPanel(AylaServerRailGroup g) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool busy = _busyId == g.id;
    return MouseRegion(
      // 移入面板取消收起（tsx 166–167）
      onEnter: (_) => _cancelClose(),
      onExit: (_) => _scheduleClose(),
      child: IntrinsicWidth(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: AylaServerRail.popMinWidth, // min-width: 136px
            maxWidth: AylaServerRail.popMaxWidth, // max-width: 200px
          ),
          // `.server-pop { background: var(--glass-bg-strong);
          // backdrop-filter: var(--glass-filter) }`（group.css:594–613）—— 只命中
          // app.css:252–270 的 `.92` 降级段（不在 auroraqua.css:527–551 清单里）
          // ⇒ 实底档用软值 `.92`。
          child: AylaGlassSurface(
            opaqueSoft: true,
            strong: true, // --glass-bg-strong（607）
            radius: AylaRadii.rCard, // --radius-card（606）
            child: Padding(
              // padding: var(--sp-1)
              padding: const EdgeInsets.all(AylaSpacing.sp1),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 2, // gap: 2px（605）
                children: <Widget>[
                  Padding(
                    // .server-pop-name { padding: 4px 8px; font-size:12px;
                    // font-weight:700; white-space:nowrap; ellipsis }（614–622）
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Text(
                      g.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.label.copyWith(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AylaColors.textPrimary,
                      ),
                    ),
                  ),
                  AylaMenuItem(
                    // .server-pop-action（624–643）= AylaMenuItem 的 rail 档
                    // （34 / padding 0 8 / radius 8 / 13px 600 / gap 6 / icon 14）。
                    metrics: AylaMenuItemMetrics.rail,
                    icon: AylaIcon(aylaIconByName('iconPin')!, size: 14),
                    label: g.isPinned ? '取消置顶' : '置顶',
                    disabled: busy, // :disabled { opacity: .5 }（tsx 174）
                    onTap: () => _togglePin(g),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Overlay entry 内容：position: absolute 的 left/top（group.css 595–598）
  /// + transform: translateY(-50%)（598）。
  Widget _buildPopOverlay() {
    final String? id = _activePopId;
    final Offset? anchor = _popAnchor;
    if (id == null || anchor == null) return const SizedBox.shrink();
    for (final AylaServerRailGroup g in widget.groups) {
      if (g.id == id) {
        return Positioned(
          top: anchor.dy,
          left: anchor.dx,
          child: FractionalTranslation(
            translation: const Offset(0, -0.5),
            child: _buildPopPanel(g),
          ),
        );
      }
    }
    return const SizedBox.shrink();
  }

  /// 同步浮层 entry 与当前状态（插入 / 刷新 / 移除）。
  void _syncPopOverlay() {
    final bool show = _activePopId != null && _popAnchor != null;
    if (!show) {
      _popEntry?.remove();
      _popEntry = null;
      return;
    }
    if (_popEntry == null) {
      _popEntry = aylaOverlayEntry(
        builder: (BuildContext context) => _buildPopOverlay(),
      );
      Overlay.of(context).insert(_popEntry!);
    } else {
      _popEntry!.markNeedsBuild();
    }
  }
}

// ======================= 样张 =======================

/// 画布样张（供 lib/preview/component_gallery.dart 引用，与 AylaTopNav 的
/// aylaTopNavSamples() 同一约定）。
///
/// **可交互**（画布审核用）：点任一头像切换当前群 → 3×32 指示条 300ms 迁移 +
/// 头像 48→52 放大。列表给了 9 个群、总高超出列高 → 可滚动，用于验收
/// mask-image 的上 20 / 下 16 渐隐与「底部 77 让位悬浮加号」。
Widget aylaServerRailSamples() => const _ServerRailDemo();

class _ServerRailDemo extends StatefulWidget {
  const _ServerRailDemo();

  @override
  State<_ServerRailDemo> createState() => _ServerRailDemoState();
}

class _ServerRailDemoState extends State<_ServerRailDemo> {
  /// 9 个群：置顶 / 未读（含 180→99+）/ 直播 / 语音 各态都覆盖，总高超出列高。
  static const List<AylaServerRailGroup> _groups = <AylaServerRailGroup>[
    AylaServerRailGroup(
      id: 'g1',
      title: '技术群',
      unreadCount: 12,
      postUnreadCount: 3,
      isPinned: true,
      presence: AylaAvatarStatus(live: true, voice: true),
    ),
    AylaServerRailGroup(
      id: 'g2',
      title: '摸鱼群',
      presence: AylaAvatarStatus(voice: true),
    ),
    AylaServerRailGroup(
      id: 'g3',
      title: '爱莉的客厅',
      unreadCount: 180,
      presence: AylaAvatarStatus(live: true),
    ),
    AylaServerRailGroup(
      id: 'g4',
      title: '星海观测站',
      presence: AylaAvatarStatus(live: true),
    ),
    AylaServerRailGroup(id: 'g5', title: '作业互助', unreadCount: 5),
    AylaServerRailGroup(
      id: 'g6',
      title: '深夜电台',
      presence: AylaAvatarStatus(live: true, voice: true),
    ),
    AylaServerRailGroup(id: 'g7', title: '周末去哪儿'),
    AylaServerRailGroup(id: 'g8', title: '新番同步看', unreadCount: 42),
    AylaServerRailGroup(
      id: 'g9',
      title: '空状态群',
      isPinned: true,
      presence: AylaAvatarStatus(voice: true),
    ),
  ];

  /// 当前群（点行切换 → 指示条迁移；两个样张共享同一状态，便于左右对照）。
  String _currentId = 'g1';

  /// 第一列的入场开关（`AylaServerRail.animateEntrance` 是 **replay 开关**：
  /// false → true 的那一刻播一次）。样张里由「重播入场」按钮驱动，
  /// 复刻真实页面的两种时机：进入主页（播）／切群（不播）。
  bool _entrance = false;

  /// 重播一次入场：先落回 false 复位，下一帧再抬 true ⇒ 本件换 key 重挂入场层。
  void _replayEntrance() {
    setState(() => _entrance = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _entrance = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _rail(
          '常态（点行切群 · 滚动看上下渐隐）',
          entrance: _entrance,
          onReplay: _replayEntrance,
        ),
        const SizedBox(width: AylaSpacing.sp8),
        _rail('悬停面板形态（静态注入 .server-pop）', hovered: 'g3'),
      ],
    );
  }

  Widget _rail(
    String label, {
    String? hovered,
    bool entrance = false,
    VoidCallback? onReplay,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          height: 480,
          child: AylaServerRail(
            groups: _groups,
            currentGroupId: _currentId,
            // 点行 → 切群（画布审核用；真实回调由页面层接）。
            // ⚠️ 切群**不重播**入场 = web 语义（第一列是选项卡，motion owner 不重挂），
            // 所以这里只动 `_currentId`，不碰 `_entrance`。
            onSelectGroup: (String id) => setState(() => _currentId = id),
            onCreateGroup: _createNoop,
            loadMore: _loadNoop,
            refresh: _loadNoop,
            animateEntrance: entrance,
            previewHoveredGroupId: hovered,
          ),
        ),
        const SizedBox(height: AylaSpacing.sp2),
        SizedBox(
          width: 220,
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: AylaTextStyles.light.timestamp.copyWith(
              color: AylaColors.textSecondary,
            ),
          ),
        ),
        if (onReplay != null) ...<Widget>[
          const SizedBox(height: AylaSpacing.sp2),
          AylaGlassButton(label: '重播入场', minHeight: 32, onPressed: onReplay),
        ],
      ],
    );
  }
}


/// 预览用空实现（生产调用点由页面层提供）。
void _createNoop() {}

Future<void> _loadNoop() async {}
