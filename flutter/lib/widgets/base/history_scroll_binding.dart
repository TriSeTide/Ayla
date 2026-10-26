/// 历史窗口 ↔ 滚动控制器的绑定 —— web `hooks/useCursorHistory.ts` 自带的
/// `listRef` + `useLayoutEffect` 的 Flutter 等价物。
///
/// ## 为什么需要它（2026-10-26 实报「语音房聊天 / 直播间弹幕新消息不自动滚底」）
///
/// web 的 `useCursorHistory` **同时持有数据与滚动容器**：
/// ```ts
/// // useCursorHistory.ts:54
/// const listRef = useRef<HTMLDivElement | null>(null);
/// // useCursorHistory.ts:67–78 —— items 一变就在 layout 阶段贴底
/// useLayoutEffect(() => {
///   const restore = pendingScroll.current; const list = listRef.current;
///   if (!restore || !list || restore.owner !== owner) return;
///   pendingScroll.current = null;
///   if (restore.anchor === "bottom") { list.scrollTop = list.scrollHeight; return; }
///   ... // 上翻续读的 anchor 恢复（两侧调用点都只有「贴底跟随」档，不实现）
/// }, [state.items, owner]);
/// // useCursorHistory.ts:159–164 —— 滚动时维护 following
/// const handleScroll = () => { following.current =
///   list.scrollHeight - list.scrollTop - list.clientHeight < 40 && !stateRef.current.hasNewer; };
/// ```
///
/// Flutter 侧 [AylaCursorHistory] 只负责数据（`pendingScrollToBottom` 只置位），
/// 消费端历史上由**每个页面各自实现**，于是出现三种偏差：
/// 1. 语音房（`voice_room_body.dart`）**完全没有消费方** ⇒ 新消息进入窗口但列表原地不动；
/// 2. 直播间（`live_support.dart:pumpScroll`）**先** `consumeScrollToBottom()` **再**判
///    `hasClients` ⇒ 列表尚未挂载时请求被**吞掉**，之后没有任何东西再触发；
/// 3. 三处消费都挂在「页面 build 的 post-frame」上 ⇒ 页面不重建就没有下一次；
///    且 `returnLatest()` 返回时本帧布局仍是**旧高度**，立刻 `jumpTo(max)` 跳的是旧 max。
///
/// 本类把这段语义**收敛成唯一 owner**：谁持有历史窗口就绑一个，页面不再各写一份。
///
/// ## 机制差异（登记）
/// web 的 `useLayoutEffect` 在**同一次提交、绘制之前**执行；Flutter 没有等价的 layout
/// 阶段回调，只有 `addPostFrameCallback`（layout/paint 之后）⇒ 本件在本帧之后贴底，
/// 视觉等价（都是「本帧已经排好版，然后落到底」）。
///
/// 「items 已替换、但本帧高度还是旧值」的窗口（`returnLatest()` / `loadOlder()`
/// 在同一个同步段里返回）用**有限跟帧**覆盖（[kAylaHistorySettleFrames]）：
/// 只在 `maxScrollExtent` 变化时才补跳 —— 等价于 web 每次 items 提交都重跑一次
/// layout effect，同时**不会**跟用户抢滚动条（用户上翻即放弃）。
///
/// 「列表晚于数据挂载」用**有界重试**覆盖（[kAylaHistoryAttachRetryFrames]）：
/// 挂载 `ScrollController` 不会发通知，所以列表未挂载时**保留** pending 并隔帧重试，
/// 直到挂上或预算耗尽（下一次历史变更会重置预算）。
///
/// ## 公开面
/// `AylaHistoryScrollBinding` · `kAylaHistoryBottomSlack` · 样张不需要（纯逻辑件）
library;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../state/cursor_history.dart';

/// 「仍在底部」的容差（web `useCursorHistory.ts:161`：
/// `scrollHeight - scrollTop - clientHeight < 40`）。
const double kAylaHistoryBottomSlack = 40;

/// 一次贴底之后**再跟几帧**（覆盖「items 已换、本帧布局还是旧高度」的窗口）。
const int kAylaHistorySettleFrames = 3;

/// 「列表还没挂载」时最多重试几帧（约 2 秒；供路由切换 / 展开动画用）。
const int kAylaHistoryAttachRetryFrames = 120;

/// 历史窗口与滚动控制器的绑定（web `useCursorHistory` 的 `listRef` +
/// `pendingScroll` + `handleScroll` 三件）。
///
/// 用法（页面层）：
/// ```dart
/// _binding = AylaHistoryScrollBinding<AylaDanmaku>(history: _history, controller: _scroll)..bind();
/// // 「有新消息 ↓」/「返回最新消息」：
/// _binding.jumpToBottom();
/// // dispose:
/// _binding.dispose();
/// ```
///
/// 绑定后**页面不需要**再在 build 里手动 post-frame 贴底 —— 历史窗口一 notify，
/// 本件自己排帧消费 [AylaCursorHistory.pendingScrollToBottom]。
class AylaHistoryScrollBinding<T> {
  AylaHistoryScrollBinding({
    required this.history,
    required this.controller,
    this.bottomSlack = kAylaHistoryBottomSlack,
  });

  /// 数据侧（web `useCursorHistory` 的 state 部分）。
  final AylaCursorHistory<T> history;

  /// 滚动容器（web 的 `listRef`；列表侧用同一个 `ScrollController`）。
  final ScrollController controller;

  /// 距底容差（web 40px）。
  final double bottomSlack;

  bool _bound = false;
  bool _disposed = false;

  /// 已排帧待消费（去重，一帧内多次 notify 只排一个回调）。
  bool _consumeQueued = false;

  /// 贴底之后还要跟几帧（见 [kAylaHistorySettleFrames]）。
  int _settleFrames = 0;

  /// 「列表还没挂载」的重试预算（见 [kAylaHistoryAttachRetryFrames]）。
  int _attachRetryLeft = 0;

  /// 是否已绑定。
  bool get bound => _bound;

  /// 列表是否**当前**贴底（web `scrollHeight - scrollTop - clientHeight < 40`）。
  ///
  /// 列表尚未挂载 / 尚未布局 ⇒ `false`（**不伪造**贴底态）。
  bool get isAtBottom {
    final double? distance = distanceToBottom;
    return distance != null && distance < bottomSlack;
  }

  /// 列表当前距底距离；未挂载 ⇒ `null`（不伪造）。
  double? get distanceToBottom {
    final ScrollPosition? p = _position;
    if (p == null || !p.hasPixels || !p.hasViewportDimension) return null;
    return p.maxScrollExtent - p.pixels;
  }

  ScrollPosition? get _position =>
      controller.hasClients && controller.positions.isNotEmpty
          ? controller.position
          : null;

  /// 绑定：挂历史窗口与滚动控制器监听，并排一次首帧消费
  /// （进房首屏的 `reset()` 会先置 pending，绑定晚于它也能补上）。幂等。
  void bind() {
    if (_bound || _disposed) return;
    _bound = true;
    _attachRetryLeft = kAylaHistoryAttachRetryFrames;
    history.addListener(_onHistoryChanged);
    controller.addListener(_onScroll);
    _scheduleConsume();
  }

  void _onHistoryChanged() {
    // 历史变了 ⇒ 重新给「等列表挂载」一次机会（路由切换 / 展开动画后列表可能还没建）。
    _attachRetryLeft = kAylaHistoryAttachRetryFrames;
    _scheduleConsume();
  }

  /// web `handleScroll`（`useCursorHistory.ts:160–164`）：距底 < [bottomSlack] 才继续跟随。
  void _onScroll() {
    if (_disposed) return;
    final double? distance = distanceToBottom;
    if (distance == null) return;
    // 用户在「跟帧」里主动上翻 ⇒ 放弃这次跟随（web 没有这个窗口，等价保护）。
    if (_settleFrames > 0 && distance > bottomSlack) {
      _settleFrames = 0;
    }
    history.setFollowing(distance < bottomSlack);
  }

  void _scheduleConsume() {
    if (_disposed || _consumeQueued) return;
    _consumeQueued = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _consumeQueued = false;
      if (!_disposed) _consume();
    });
    // `addPostFrameCallback` 本身不排帧；历史窗口的 notify 通常伴随 setState（已有帧在排），
    // 但 `bind()` 首次调用可能发生在没有待排帧的时机 ⇒ 兜一次。
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _scheduleNextFrame(VoidCallback cb) {
    if (_disposed) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) cb();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _consume() {
    final ScrollPosition? p = _position;
    if (p == null) {
      // ⚠️ **不要在这里消费 pending**：列表还没挂上（路由切换 / 展开动画 / 窄宽切换）。
      // 老实现（`live_support.dart:pumpScroll`）先消费再判 hasClients ⇒ 请求被吞，
      // 这是「一直不滚底」的直接成因。保留 pending 并**隔帧重试**（挂载控制器不发通知，
      // 只能靠重试等到它）；预算耗尽后保留 pending，等下一次历史变更再给机会。
      if (history.pendingScrollToBottom && _attachRetryLeft > 0) {
        _attachRetryLeft -= 1;
        _scheduleNextFrame(_consume);
      }
      return;
    }
    if (history.pendingScrollToBottom) {
      history.consumeScrollToBottom();
      _settle(p);
      return;
    }
    if (_settleFrames > 0) {
      _settle(p);
    }
  }

  /// 贴底一次；需要时继续跟帧（见 [kAylaHistorySettleFrames]）。
  ///
  /// ⚠️ **这里不能按 `distanceToBottom > slack` 放弃**：刚挂载 / 刚 append 时列表
  /// 本来就在顶部（距底 = 整个高度），那不是「用户滚开了」，正是**要贴底的对象**。
  /// 「用户上翻就放弃」由 [_onScroll] 负责（它会把 [_settleFrames] 清零）——
  /// 那才是 web `atBottomRef` 的真实语义（只在滚动事件里更新）。
  void _settle(ScrollPosition p) {
    if (_settleFrames <= 0) _settleFrames = kAylaHistorySettleFrames;
    _jump(p);
    _settleFrames -= 1;
    if (_settleFrames > 0) _scheduleNextFrame(_consume);
  }

  void _jump(ScrollPosition p) {
    if (!p.hasContentDimensions) return;
    final double target = p.maxScrollExtent;
    if (!target.isFinite) return;
    if ((p.pixels - target).abs() < 0.5) return;
    p.jumpTo(target);
  }

  /// 立刻贴底并恢复跟随（web `useDanmaku.scrollToBottom` 的「未脱挂」档 /
  /// `MessageList.handleJumpToBottom`）。
  ///
  /// ⚠️ 窗口已脱挂（`history.hasNewer`）时应先 `returnLatest()` ——
  /// 本方法只贴底、不重读最新页（与 web 一致：脱挂时 `scrollToBottom` 走 `returnLatest`）。
  void jumpToBottom() {
    if (_disposed) return;
    history.consumeScrollToBottom();
    history.setFollowing(true);
    final ScrollPosition? p = _position;
    if (p == null) {
      // 列表还没挂载：保留一次重试预算，挂上后立刻贴底。
      _attachRetryLeft = kAylaHistoryAttachRetryFrames;
      _scheduleConsume();
      return;
    }
    _settleFrames = kAylaHistorySettleFrames;
    _settle(p);
  }

  /// 解绑（幂等）。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_bound) {
      history.removeListener(_onHistoryChanged);
      controller.removeListener(_onScroll);
      _bound = false;
    }
    _settleFrames = 0;
    _attachRetryLeft = 0;
  }
}
