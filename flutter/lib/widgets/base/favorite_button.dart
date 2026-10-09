/// favorite button（自 `directory_controls.dart` 拆出：一文件一件）。
///
/// 事实源与逐条对照见 `docs/flutter/17-组件文件头归档（整理前原文）.md` 的 `directory_controls.dart` 一节
/// 与各件的 `///` 头注。
///
/// ## 公开面
/// `AylaFavoriteState` · `AylaFavoriteButton`

library;

import 'dart:async';

import 'package:flutter/material.dart';
import '../../state/favorite_status.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_theme.dart';
import '../../theme/buttons.dart';
import '../../theme/glass.dart';
import '../../theme/tokens.dart';
import 'tooltip.dart';

/// 收藏三态（对应 tsx 的 `state.favoriteId`：undefined / null / 数字）。
enum AylaFavoriteState {
  /// 状态未知（加载中）→ 禁用 + 「加载中…」
  unknown,

  /// 未收藏 → 「收藏」
  notFavorited,

  /// 已收藏 → 「已收藏」
  favorited,

  /// 状态加载失败 → 「重试收藏状态」（点击重新拉取）
  error,
}

/// 收藏按钮（`FavoriteButton.tsx` + app.css 3312–3341）。
///
/// ## 事实源
/// ```
/// .favorite-toggle { inline-flex; center; gap: var(--sp-1);
///   min-height: 36px; padding: 0 var(--sp-2);
///   border: 1px solid var(--glass-border); border-radius: var(--radius-pill);
///   background: var(--glass-bg-strong); color: var(--text-secondary); }
/// :hover, :focus-visible, .is-active {
///   color: var(--pink-500); border-color: var(--pink-500);
///   box-shadow: var(--glow-shadow); }
/// .is-compact { min-width:32px; min-height:32px; padding: 0 var(--sp-1) }
/// :disabled { cursor: wait; opacity: .7 }
/// ```
/// **图标**：`IconHeart`，compact 时 16、否则 18；**已收藏时 `fill=currentColor`**
/// （实心），未收藏 `fill=none`（线框）。
/// **文案**：`!compact` 才显示文字（error→「重试收藏状态」/unknown→「加载中…」
/// /active→「已收藏」/else→「收藏」）。
///
/// ## 两种模式（2026-10-08）
///
/// | | 注入档（既有） | **自给自足档（新增，web 架构）** |
/// |---|---|---|
/// | 入参 | `state` / `busy` / `actionError` / `onToggle` / `onRetryStatus` | `targetType` + `targetId`（+`controller` 可选） |
/// | 状态来源 | 调用方传 | **组件自己**（对齐 web `FavoriteButton.tsx:22–63`） |
/// | 加载时机 | 调用方负责 | **挂载即 retain + load**、卸载 release（`useFavoriteStatuses.ts:12–16`） |
///
/// ⇒ 传了 `targetType`+`targetId` 之后**页面漏接线也不会坏**：
/// 这正是 web 里「任何地方放一个收藏键都自动工作」的原因（`LiveRoomBody.tsx:260/328`、
/// `PostCard.tsx:145`、VoiceRoomBody.tsx:278` 等调用点都**只给 targetType/targetId**）。
///
/// 不传 `controller` ⇒ 组件自建**私有**控制器（自己 dispose）；
/// 传了 ⇒ 组件只 retain/release，**由调用方负责 dispose**。
///
/// ## ⚠️ 注入档仍可用，但**不自动加载**（2026-10-09 明确）
/// 注入档（只给 `state:`）的状态与加载全在调用方：调用方若没在挂载时调
/// `AylaFavoriteStatusController.load(...)`，该键会**永远停在 `unknown`**
/// —— 禁用 + 「正在加载收藏状态」，正是用户实报的现象。
/// web 侧**不存在**这个档（`FavoriteButton.tsx` 只接受 `targetType`/`targetId`）
/// ⇒ 凡是从 web 的 `FavoriteButton` 转写来的调用点都应走自给自足档。
///
/// ## 行为（tsx）
/// - 点击 **stopPropagation**（不触发卡片自身的打开动作）
/// - `busy || state.loading` 时忽略点击；`unknown && !error` 时按钮 disabled
/// - **状态未知或出错时点击 = 重新拉取状态**（不是收藏）
/// - 请求中 busy；失败显示 `actionError`（`role=alert`）
/// - `aria-pressed = unknown ? undefined : active`
/// - **hover 1.02 / 按下 .98 / focus ring** 与分享键同源（`auroraqua.css:54–94`
///   把 `.favorite-toggle` 与 `.icon-btn-40` 写在同一个 `:is()` 组）
class AylaFavoriteButton extends StatefulWidget {
  const AylaFavoriteButton({
    super.key,
    this.state,
    this.compact = false,
    this.busy = false,
    this.actionError,
    this.onToggle,
    this.onRetryStatus,
    this.onPressedInsideCard,
    this.targetType,
    this.targetId,
    this.controller,
  });

  /// 收藏状态（**注入模式**）。
  ///
  /// 传了 [targetType]+[targetId] 时**不必传**（组件自己算）；
  /// 两种模式二选一，见类头「自给自足」。
  final AylaFavoriteState? state;

  /// 紧凑形态（`.is-compact`：32×32、无文字、图标 16）。
  final bool compact;

  /// 请求进行中（禁用）。自给自足模式由组件自己维护（web `busy`）。
  final bool busy;

  /// 操作失败文案（`role=alert`）。
  final String? actionError;

  /// 切换收藏（传入目标状态：true = 收藏）。**注入模式下才被调用**。
  final ValueChanged<bool>? onToggle;

  /// 状态未知/出错时点击 → 重新拉取状态。**注入模式下才被调用**。
  final VoidCallback? onRetryStatus;

  /// 点击前的拦截（卡片内使用时用于 stopPropagation）。
  final VoidCallback? onPressedInsideCard;

  // ---- 自给自足模式（对齐 web `FavoriteButton` 的 targetType/targetId）----

  /// 目标类型（web `targetType`：post / live / voice / game / message）。
  ///
  /// 与 [targetId] 同时给出 ⇒ 组件**自己加载、自己切换、自己维护 busy/error**，
  /// 调用方无需任何接线（web `FavoriteButton.tsx:20–60`）。
  final String? targetType;

  /// 目标 id（web `targetId`；字符串化后作键）。
  final String? targetId;

  /// 状态控制器（web 是模块级 store 单例）。
  ///
  /// 不传 ⇒ 用库内**共享单例** [aylaSharedFavoriteStatusController]
  /// （= web `favoriteStatus.ts:17` 的模块级 `useFavoriteStatusStore`：
  /// 一屏 N 个键合并成有界批量请求、任一处写入广播给全部挂载键）。
  /// 传共享控制器时**由调用方负责其 dispose**（组件只 release，不销毁）。
  final AylaFavoriteStatusController? controller;

  /// 是否处于自给自足模式（[targetType] 与 [targetId] 都给了）。
  bool get selfLoading => targetType != null && targetId != null;

  @override
  State<AylaFavoriteButton> createState() => _AylaFavoriteButtonState();
}

class _AylaFavoriteButtonState extends State<AylaFavoriteButton> {
  bool _hovered = false;
  bool _focused = false;

  /// 本次挂载占用的 release 回调（`initState` retain，`dispose` release）。
  void Function()? _release;

  AylaFavoriteStatusController get _controller =>
      widget.controller ?? aylaSharedFavoriteStatusController;

  bool get _selfLoading => widget.selfLoading;

  // ---- 自给自足模式：initState retain + load，dispose release（web useFavoriteStatuses）----

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant AylaFavoriteButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // targetType / targetId / controller 变化 ⇒ 重新绑定（web `useEffect` 依赖
    // `[type, ids, account]`，useFavoriteStatuses.ts:16）。
    final bool changed = oldWidget.targetType != widget.targetType ||
        oldWidget.targetId != widget.targetId ||
        oldWidget.controller != widget.controller;
    if (!changed) return;
    _unbind();
    _bind();
  }

  /// 本次挂载的绑定代际（post-frame 加载落地前的失效判定）。
  int _bindGeneration = 0;

  /// 本次绑定时的账号作用域代际（web `FavoriteButton.tsx:31` 的 `[targetType, key, account]`
  /// 依赖里的 `account`）。
  ///
  /// web 的 `account` 一变，`useEffect` 就重跑 ⇒ 旧 cleanup 递增 `owner` 并丢弃在途结果，
  /// 新 effect 重新 `retain + load`（`useFavoriteStatuses.ts:16`）。
  /// 登录/登出（[aylaFavoriteResetScope] 接线点）之后，同一棵子树里的收藏键必须重新查一次
  /// —— 否则会拿旧账号的 `unknown` 一直禁用到用户手动重试。
  int _boundScope = aylaFavoriteScopeEpoch();

  /// 代际变化 → 重绑（web 的 store 订阅：`favoriteStatus.ts:41` 的
  /// `setState({ entries: new Map() })` 会让所有挂载的 `FavoriteButton` 立即重渲染）。
  ///
  /// ⚠️ 只在自给自足档注册（注入档的状态归调用方）。
  void _onScopeChanged() {
    if (!mounted || !_selfLoading) return;
    if (aylaFavoriteScopeEpoch() == _boundScope) return;
    _boundScope = aylaFavoriteScopeEpoch();
    _unbind();
    _bind();
  }

  /// 账号作用域（登录/登出）变化 ⇒ 重绑（web `account` 依赖，`FavoriteButton.tsx:31`）。
  ///
  /// ⚠️ 只做 retain/listen（不发通知）；加载落在帧后 —— 在 build 期同步 `load`
  /// 会走 `notifyListeners` ⇒ 持有同一控制器的页面报 “setState() called during build”。
  void _ensureScopeBound() {
    if (!_selfLoading) return;
    final int scope = aylaFavoriteScopeEpoch();
    if (scope == _boundScope) return;
    _boundScope = scope;
    _unbind();
    _bind();
  }

  void _bind() {
    if (!_selfLoading) return;
    // ⚠️ 不建私有控制器：不传 `controller` 时用**共享单例**
    // （web 的模块级 store，`favoriteStatus.ts:17`）⇒ 一屏 N 个键合并成
    // 有界批量请求（drain），且任一处写入对所有挂载键可见。
    _controller.addListener(_onStatusChanged);
    // web 的 store 订阅（`favoriteStatus.ts:43–46` 装一次 `useAuthStore.subscribe`）：
    // 账号代际一变**当帧**重绑，不等下一次外部 rebuild。
    aylaFavoriteScopeListenable.addListener(_onScopeChanged);
    // web `useFavoriteStatuses.ts:13–14`：`const release = retainFavoriteStatus(type, ids);
    // loadFavoriteStatuses(type, ids);` —— **挂载即加载**，这是「页面漏接线也不坏」的根。
    _release = _controller.retain(widget.targetType!, <String>[widget.targetId!]);
    // ⚠️ `retain` 不发通知（可以同步）；`load` 会**同步 notify** 一次（把状态置 loading）。
    // React 的 `useEffect` 在**提交之后**运行，而 Flutter 的 `initState` /
    // `didUpdateWidget` 都在**构建期**内 —— 同步 load 会让持有同一控制器的页面
    // （其 listener 里 setState）报 “setState() called during build”（实测 page_ws_scroll_share_test）。
    // ⇒ 对齐 `useEffect` 的时序：首帧之后再发起加载。
    final int generation = ++_bindGeneration;
    final String type = widget.targetType!;
    final String id = widget.targetId!;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _bindGeneration) return;
      if (!_selfLoading || widget.targetType != type || widget.targetId != id) {
        return;
      }
      unawaited(_controller.load(type, <String>[id]));
    });
  }

  void _unbind() {
    // ⚠️ 判别条件只能看**本实例自己的状态**（`_release`），不能看 `_selfLoading`:
    // `didUpdateWidget` 里 `widget` 已被替换成新值 —— 若从「自给自足」切到「注入档」
    // （新 `targetType` 为 null），`_selfLoading` 已是 false，用它会提前 return
    // ⇒ **监听器不解绑**（实测由本件的切换用例锁定）。
    if (_release == null) return;
    aylaFavoriteScopeListenable.removeListener(_onScopeChanged);
    _controller.removeListener(_onStatusChanged);
    // web `useFavoriteStatuses.ts:15` 的 `return release`（卸载即释放）。
    _release?.call();
    _release = null;
  }

  void _onStatusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _unbind();
    super.dispose();
  }

  // ---- 三态来源：自给自足 ⇒ 控制器；注入 ⇒ widget ----

  /// 当前状态（web `state`）。
  AylaFavoriteState get _state => _selfLoading
      ? _controller.stateOf(widget.targetType!, widget.targetId!)
      : (widget.state ?? AylaFavoriteState.unknown);

  /// 请求进行中（web `busy`；自给自足模式由控制器持）。
  bool get _busy => _selfLoading
      ? _controller.busyOf(widget.targetType!, widget.targetId!)
      : widget.busy;

  /// 操作失败文案（web `actionError`）。
  String? get _actionError => _selfLoading
      ? _controller.actionErrorOf(widget.targetType!, widget.targetId!)
      : widget.actionError;

  /// 是否在**重新查询中**（web `state.loading`，`FavoriteButton.tsx:69` 的第二个条件）。
  ///
  /// ⚠️ 2026-10-09 用户裁决后**不再参与禁用判定**（禁用只剩 `busy`）；
  /// 保留为公开只读口，供调用方/测试观察「请求在途」这一事实。
  bool get loading => _selfLoading
      ? _controller.loadingOf(widget.targetType!, widget.targetId!)
      : false;

  bool get _active => _state == AylaFavoriteState.favorited;

  /// `favoriteId === undefined`（状态未知）。
  bool get _unknown =>
      _state == AylaFavoriteState.unknown || _state == AylaFavoriteState.error;

  /// tsx 69 行：`disabled={busy || state.loading || (unknown && !state.error)}`
  ///
  /// ## ⚠️ 用户裁决（2026-10-09）：「收藏键非得要有个禁用态？删掉得了」
  /// web 的 `disabled` 只在**请求真的在途**时有意义（`busy || loading`）；
  /// `unknown && !state.error` 那一档是为了「还没查过」时的视觉一致性，
  /// 但代价是：**任何没被接线的调用点都会永久禁用**（用户实报群内桌游、
  /// 直播/帖子/桌游卡片），而且用户无法自愈（点不动 ⇒ 永远查不出来）。
  ///
  /// ⇒ 本件改为：**永远可点**。
  /// - `unknown`（没查过 / 查询中）⇒ 点击 = **拉取状态**（tsx 35–38 已有的语义，
  ///   原本被 disabled 挡住，现在真正生效）；
  /// - `error` ⇒ 点击 = 重新拉取（原有语义不变）；
  /// - `favorited` / `notFavorited` ⇒ 点击 = 切换（原有语义不变）。
  ///
  /// 只有 `busy`（一次切换正在进行）保持禁用 —— 那是**已经能点、正在执行**的短暂态，
  /// 不是「不知道能不能点」的死锁态。视觉上 unknown 档不再变灰，
  /// 用户可随时点一下把状态拉出来（自愈）。
  bool get _disabled => _busy;

  /// 视觉上的「加载中」档（unknown 无 error）：图标温和降透明度，
  /// 但**不阻止点击**（点一下就拉取）。
  ///
  /// `unknown` 有两种来源：① 从未查过（controller 无条目）；② 请求在途
  /// （[loading]）。两者对用户都是「还没拿到状态」，视觉同档、都可点。
  bool get _pendingLook => _state == AylaFavoriteState.unknown;

  /// tsx `label`（aria）：error → 「收藏状态加载失败，点击重试」；
  /// unknown → 「正在加载收藏状态」；active → 「取消收藏」；else → 「收藏」。
  String get _ariaLabel {
    switch (_state) {
      case AylaFavoriteState.error:
        return '收藏状态加载失败，点击重试';
      case AylaFavoriteState.unknown:
        return '正在加载收藏状态';
      case AylaFavoriteState.favorited:
        return '取消收藏';
      case AylaFavoriteState.notFavorited:
        return '收藏';
    }
  }

  /// `!compact` 时显示的文案。
  String get _text {
    switch (_state) {
      case AylaFavoriteState.error:
        return '重试收藏状态';
      case AylaFavoriteState.unknown:
        return '加载中…';
      case AylaFavoriteState.favorited:
        return '已收藏';
      case AylaFavoriteState.notFavorited:
        return '收藏';
    }
  }

  void _handleTap() {
    widget.onPressedInsideCard?.call(); // stopPropagation 等价
    // tsx 34：`if (busy || state.loading) return` —— 只剩 busy 挡点击
    // （2026-10-09 用户裁决：unknown 档也不再禁用，改由「点击 = 拉取」处理）。
    if (_disabled) return;
    // tsx 35–38：error 或 favoriteId===undefined → 重新拉取状态（不是收藏）。
    // ⚠️ unknown 档**必须走 [load]**（而不是 [toggle]）：Flutter 控制器把这条
    // 写在 [toggle] 内部，但注入档没有控制器 ⇒ 只能靠回调。
    if (_unknown) {
      if (_selfLoading) {
        // tsx 36：`loadFavoriteStatuses(targetType, [key], true)`（force）
        unawaited(_controller.load(
          widget.targetType!,
          <String>[widget.targetId!],
          force: true,
        ));
      } else {
        // 注入档：调用方接线了就用它；**万一没接线**（页面漏传）也不静默 ——
        // 这种情况本身是接线缺陷，但不该再把用户困在「点了没反应」。
        widget.onRetryStatus?.call();
      }
      return;
    }
    if (_selfLoading) {
      // tsx 32–60 的 `toggle`：加/取消收藏全由控制器落地。
      unawaited(_controller.toggle(widget.targetType!, widget.targetId!));
      return;
    }
    widget.onToggle?.call(!_active);
  }

  @override
  Widget build(BuildContext context) {
    // 账号作用域（登录/登出）变化 ⇒ 先重绑再渲染（web `account` 依赖，
    // `FavoriteButton.tsx:31`）。只做 retain/listen（不发通知），加载落在帧后。
    _ensureScopeBound();
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool highlight = _hovered || _focused || _active;

    // `.favorite-toggle`（app.css:3317–3324 声明 cursor: pointer）是 <button>
    // ⇒ 全局 pointer；禁用态归 not-allowed（base.css:343）。
    // hover/focus/active 三档决定描边、字色与辉光（app.css:3326–3332）。
    // ⚠️ 这里**不再自声明 cursor**：`AylaPressScale` 已按 base.css:333–346 提供
    // pointer / not-allowed 兜底，重复声明会遮蔽外层（本项目 cursor 测试的已知语义）。
    final Widget button = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
          onFocusChange: (bool f) => setState(() => _focused = f),
          child: AnimatedContainer(
            duration: AylaDurations.fast, // --dur-fast 180ms
            curve: AylaCurves.easeOut,
            // `.favorite-toggle { min-height: 36px }`；`.is-compact { min-width:32;
            //   min-height:32; padding: 0 var(--sp-1) }`
            // compact 给**固定宽 32**（而非仅 minWidth）：否则内部
            // `MainAxisSize.max` 会撑满父级可用宽度（实测 800）。
            width: widget.compact ? 32 : null,
            constraints: BoxConstraints(
              minHeight: widget.compact ? 32 : 36,
              minWidth: widget.compact ? 32 : 0,
            ),
            padding: EdgeInsets.symmetric(
              horizontal: widget.compact ? AylaSpacing.sp1 : AylaSpacing.sp2,
            ),
            decoration: BoxDecoration(
              color: AylaGlassConfig.resolveBackground(strong: true), // .78
              borderRadius: AylaRadii.pill,
              border: Border.all(
                // hover/focus/active → --pink-500；否则 --glass-border
                color: highlight ? AylaColors.pink500 : AylaColors.glassBorder,
              ),
            ),
            child: Row(
              // compact 时容器被 `minWidth: 32` 撑开、而内容只有 16 图标 + padding，
              // 若用 MainAxisSize.min + 默认 start 对齐，图标会**贴左偏 3px**
              // （实测：图标中心 397 vs 容器中心 400）。
              // web 是 inline-flex + **justify-content:center** → 内容始终居中。
              mainAxisSize:
                  widget.compact ? MainAxisSize.max : MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: AylaSpacing.sp1, // gap: var(--sp-1)
              children: <Widget>[
                AylaIcon(
                  aylaIconByName('iconHeart')!,
                  // compact 16、否则 18
                  size: widget.compact ? 16 : 18,
                  color: highlight
                      ? AylaColors.pink500 // color: var(--pink-500)
                      : AylaColors.textSecondary,
                  // fill={active ? "currentColor" : "none"} → 已收藏实心
                  filled: _active,
                ),
                if (!widget.compact)
                  Text(
                    _text,
                    style: t.label.copyWith(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: highlight
                          ? AylaColors.pink500
                          : AylaColors.textSecondary,
                    ),
                  ),
              ],
            ),
      ),
    ),
    );

    // hover/focus/active → --glow-shadow：只画形状之外 + 180ms 淡入淡出
    // （2026-09-20 审查 R2：原裸 boxShadow 会把 .45 粉辉光染进 .78 强玻璃内部）
    final Widget withGlow = AylaGlassShadow.fadeRing(
      radius: AylaRadii.pill,
      shadows: AylaShadows.glow,
      visible: highlight,
      duration: AylaDurations.fast,
      child: button,
    );

    // ⚠️ 交互壳放**最外层**（与分享键 `AylaIconButton` 的层位逐字一致）：
    // web 的 `scale` 是 transform，会连同 box-shadow 一起缩放；Flutter 侧阴影由
    // `AylaGlassShadow.fadeRing` 单独画 ⇒ 缩放必须包在它外面才能得到同一观感。
    // 这也是「样式统一」的实现要点 —— web 把 `.favorite-toggle` 与 `.icon-btn-40`
    // 写在**同一个 `:is()` 组**里（hover 档 `auroraqua.css:73–82`、active 档 `:85–94`），
    // 两键的 200ms hover 1.02 / 按下 .98 与 focus ring 必须逐帧同源；
    // 此前收藏键把这套全丢了（用户实报「样式与分享键不统一」）。
    // `prefers-reduced-motion` ⇒ 取消（`auroraqua.css:655–674`，AylaPressScale 已处理）。
    //
    // 2026-10-09 用户裁决：**unknown 档也可点**（点击 = 拉取状态，即 tsx 35–38 的语义）
    // ⇒ 交互壳只在 `busy`（一次切换进行中）时关闭。
    final Widget interactive = AylaPressScale(
      onTap: _disabled ? null : _handleTap,
      enabled: !_disabled,
      // 语义（button/label/selected）由下方外层 Semantics 统一承担，
      // 此处只借交互壳的运动、指针兜底与 focus ring。
      isButton: false,
      child: withGlow,
    );

    Widget result = AylaTooltip(
      // web `title={actionError ?? state.error ?? label}`（FavoriteButton.tsx:72）。
      // ⚠️ Flutter 侧 `AylaFavoriteState` 是枚举、**不带 error 文案字段** ⇒ 取 [actionError] 与
      // [_ariaLabel]（后者在 error 档已给「收藏状态加载失败，点击重试」，与 web 的 label 同源）。
      message: _actionError ?? _ariaLabel,
      child: Semantics(
        button: true,
        enabled: !_disabled,
        label: _ariaLabel,
        // aria-pressed = unknown ? undefined : active
        selected: _unknown ? null : _active,
        child: Opacity(
          // `:disabled { opacity: .7 }` —— 只剩 busy 档（切换进行中）。
          // unknown 档给一个**很轻**的 .85：提示「还在查」，但**不灰到像禁用**
          // （用户实报的正是「看起来是禁用的死键」）。
          opacity: _disabled && _busy ? 0.7 : (_pendingLook ? 0.85 : 1),
          child: interactive,
        ),
      ),
    );

    if (_actionError != null) {
      result = Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          result,
          Positioned(
            left: 0,
            right: 0,
            top: 40,
            child: Semantics(
              liveRegion: true, // role=alert
              child: Text(
                _actionError!,
                style: t.caption.copyWith(color: AylaColors.destructive),
              ),
            ),
          ),
        ],
      );
    }
    return result;
  }
}

// ======================= 内部：ghost 按钮 =======================

// ======================= 样张 =======================


// ======================= VisibilitySelector =======================
