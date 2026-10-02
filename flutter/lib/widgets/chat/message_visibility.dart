/// 消息可见性探针 —— web `components/chat/MessageList.tsx:896–922` 的
/// `IntersectionObserver({root: scrollRef.current, threshold: 0.6})` 等价物。
///
/// ## 事实源
///
/// | 本文件 | web |
/// |---|---|
/// | [kAylaMessageReadVisibleRatio] = `0.6` | tsx 904（`intersectionRatio < 0.6` ⇒ continue）、912（`threshold: 0.6`） |
/// | [AylaMessageVisibilityProbe.onVisible] 触发时机 | tsx 902–910：**跨越阈值**才回调一次（IO 语义），本件实现「从 < 0.6 变为 ≥ 0.6」的上升沿 |
/// | 观察对象 = **外层消息 wrapper** | tsx 915–920（`findMessageNode(element, message.id)` ⇒ `data-message-id` 节点，即 tsx 1030–1035 / 1048–1053 那个含时间分隔的 wrapper） |
/// | 观察集合的条件过滤 | tsx 916（`!read_by_me && sender_id !== currentUserId && type !== "poke"`）+ tsx 907（in-flight 去重）—— **由调用方** `AylaMessageList._onMessageVisible` 施加，本件不判定业务条件 |
///
/// ## 为什么不能用 `NotificationListener<ScrollNotification>`
///
/// 滚动通知只从 `Scrollable` **向上**冒泡；本件位于 `Scrollable` 的**子树**里，收不到。
/// web 的 `IntersectionObserver` 是全局观察、不受此限 ⇒ 这里直接监听最近的祖先
/// [ScrollPosition]（`ViewportOffset extends ChangeNotifier`），手法照抄库内既有先例
/// `widgets/group/group_card.dart:259–305`（轮播「进视口才启动」的可见性绑定）
/// 与 `widgets/shell/fab.dart:295–305`。
///
/// ## 视口口径（**不能用 `MediaQuery.size`**）
///
/// 交集的「视口」= [RenderAbstractViewport.maybeOf] 找到的 viewport 渲染盒的全局矩形。
/// 它就是 web 的 `root`（`.message-scroll` 元素，`app.css:810–816`）——
/// **不是屏幕尺寸**：`MediaQuery.size` 在「卡片/消息在屏幕内但滚到列表视口外」时会误判为可见
/// （`group_card.dart:285–305` 的旧实现即用 `MediaQuery`，本件改用真视口）。
/// 该 API 对 `ListView`（`RenderViewport`）与 `SingleChildScrollView`
/// （`RenderShrinkWrappingViewport`）都成立。
///
/// ## 公开面
/// `AylaMessageVisibilityProbe` · `aylaMessageVisibleRatio` · `kAylaMessageReadVisibleRatio`

library;

import 'package:flutter/material.dart';
// `RenderAbstractViewport` 不在 material/widgets 的导出面里（实测 analyze 报
// undefined_identifier）⇒ 显式引 rendering。
import 'package:flutter/rendering.dart' show RenderAbstractViewport;

/// 「屏幕中看到即已读」的可见比例阈值（web `threshold: 0.6`，tsx 904/912）。
///
/// 自身矩形与视口的交集面积 ÷ 自身面积 ≥ 本值才算「真的看到了」。
const double kAylaMessageReadVisibleRatio = 0.6;

/// 自身矩形 [self] 在视口 [viewport] 内的露出比例 —— web
/// `IntersectionObserverEntry.intersectionRatio`（= 交集面积 / 目标自身面积）。
///
/// - [viewport] 为 null（没有祖先 viewport，例如被挂到非滚动宿主上）⇒ 0（不触发）；
/// - 自身面积为 0（零尺寸节点）⇒ 0（web 对零尺寸目标的 ratio 恒为 0，不越过阈值）；
/// - 完全不相交 ⇒ 0。
double aylaMessageVisibleRatio(Rect self, Rect? viewport) {
  if (viewport == null) return 0;
  final double own = self.width * self.height;
  if (own <= 0) return 0;
  final Rect overlap = self.intersect(viewport);
  if (overlap.width <= 0 || overlap.height <= 0) return 0;
  return (overlap.width * overlap.height) / own;
}

/// 单条消息行的可见性探针（无视觉、不改变布局）。
///
/// 挂在消息行**外层 wrapper**上（web 的 `[data-message-id]` 节点口径）：
/// 该 wrapper 含时间分隔（tsx 1054–1058），与 web 的观察节点完全一致。
///
/// 上报时机（= IO 的「跨越阈值」语义）：
/// 1. 首帧布局后量一次 —— 对应 IO `observe()` 后立刻投递的初始 entry；
/// 2. 祖先 [ScrollPosition] 每次 notify（滚动 / 滚动物理 / 视口尺寸变化）后量一次；
/// 3. 仅当露出比例**由 < [kAylaMessageReadVisibleRatio] 变为 ≥ 该值**时调用
///    [onVisible]；持续可见不会重复上报（IO 只在跨越阈值时回调）。
///
/// 同一帧内的多次通知合并为一次测量。
class AylaMessageVisibilityProbe extends StatefulWidget {
  const AylaMessageVisibilityProbe({
    super.key,
    required this.messageId,
    required this.child,
    this.onVisible,
  });

  /// 所探针的消息 id（仅作标识与测试定位；判定逻辑不读它）。
  final String messageId;

  /// 露出比例跨越阈值（进入可见）时回调一次。
  final VoidCallback? onVisible;

  /// 被探针的行（原样透传，不参与布局）。
  final Widget child;

  @override
  State<AylaMessageVisibilityProbe> createState() =>
      _AylaMessageVisibilityProbeState();
}

class _AylaMessageVisibilityProbeState
    extends State<AylaMessageVisibilityProbe> {
  /// 测量用的锚点（渲染盒即整行 wrapper）。
  final GlobalKey _anchor = GlobalKey();

  /// 最近祖先 [ScrollPosition]（`ViewportOffset extends ChangeNotifier`）。
  ScrollPosition? _position;

  /// 本帧是否已排测量（同一帧多次通知只量一次）。
  bool _queued = false;

  /// 上一次测量的「是否达标」（上升沿判定；初始 false ⇒ 首帧可见即上报）。
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    // 首帧：此时 widget 尚未 build，祖先链要等 didChangeDependencies。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _bind();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind();
  }

  @override
  void dispose() {
    _position?.removeListener(_schedule);
    super.dispose();
  }

  /// 绑定最近的祖先滚动位置（首次进树 / 依赖变化时；幂等）。
  void _bind() {
    if (!mounted) return;
    ScrollPosition? found;
    context.visitAncestorElements((Element element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        found = (element.state as ScrollableState).position;
        return false; // 取最近的一个即停
      }
      return true;
    });
    if (!identical(found, _position)) {
      _position?.removeListener(_schedule);
      _position = found;
      _position?.addListener(_schedule);
      // 换了滚动祖先 ⇒ 上一次的可见态不再可信，重新判定。
      _visible = false;
    }
    _schedule();
  }

  /// 排到本帧末测量（`_queued` 去重；post-frame 回调跑在 layout 之后 ⇒ 矩形可用）。
  void _schedule() {
    if (_queued) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (mounted) _measure();
    });
  }

  void _measure() {
    final BuildContext? ctx = _anchor.currentContext;
    if (ctx == null) return;
    final RenderObject? object = ctx.findRenderObject();
    if (object is! RenderBox || !object.hasSize) return;

    final Rect self = object.localToGlobal(Offset.zero) & object.size;
    final RenderObject? viewport = RenderAbstractViewport.maybeOf(object);
    final Rect? viewportRect = viewport is RenderBox && viewport.hasSize
        ? viewport.localToGlobal(Offset.zero) & viewport.size
        : null;
    final double ratio = aylaMessageVisibleRatio(self, viewportRect);
    final bool visible = ratio >= kAylaMessageReadVisibleRatio;
    if (visible == _visible) return;
    _visible = visible;
    if (visible) widget.onVisible?.call();
  }

  @override
  Widget build(BuildContext context) =>
      KeyedSubtree(key: _anchor, child: widget.child);
}
