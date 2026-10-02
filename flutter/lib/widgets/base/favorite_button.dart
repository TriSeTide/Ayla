/// favorite button（自 `directory_controls.dart` 拆出：一文件一件）。
///
/// 事实源与逐条对照见 `docs/flutter/17-组件文件头归档（整理前原文）.md` 的 `directory_controls.dart` 一节
/// 与各件的 `///` 头注。
///
/// ## 公开面
/// `AylaFavoriteState` · `AylaFavoriteButton`

library;

import 'package:flutter/material.dart';
import '../../theme/app_icons.dart';
import '../../theme/app_theme.dart';
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
/// ## 行为（tsx）
/// - 点击 **stopPropagation**（不触发卡片自身的打开动作）
/// - `busy || loading` 时忽略点击；`unknown && !error` 时按钮 disabled
/// - **状态未知或出错时点击 = 重新拉取状态**（不是收藏）
/// - 请求中 busy；失败显示 `actionError`（`role=alert`）
/// - `aria-pressed = unknown ? undefined : active`
class AylaFavoriteButton extends StatefulWidget {
  const AylaFavoriteButton({
    super.key,
    required this.state,
    this.compact = false,
    this.busy = false,
    this.actionError,
    this.onToggle,
    this.onRetryStatus,
    this.onPressedInsideCard,
  });

  /// 收藏状态。
  final AylaFavoriteState state;

  /// 紧凑形态（`.is-compact`：32×32、无文字、图标 16）。
  final bool compact;

  /// 请求进行中（禁用）。
  final bool busy;

  /// 操作失败文案（`role=alert`）。
  final String? actionError;

  /// 切换收藏（传入目标状态：true = 收藏）。
  final ValueChanged<bool>? onToggle;

  /// 状态未知/出错时点击 → 重新拉取状态。
  final VoidCallback? onRetryStatus;

  /// 点击前的拦截（卡片内使用时用于 stopPropagation）。
  final VoidCallback? onPressedInsideCard;

  @override
  State<AylaFavoriteButton> createState() => _AylaFavoriteButtonState();
}

class _AylaFavoriteButtonState extends State<AylaFavoriteButton> {
  bool _hovered = false;
  bool _focused = false;

  bool get _active => widget.state == AylaFavoriteState.favorited;

  /// `favoriteId === undefined`（状态未知）。
  bool get _unknown =>
      widget.state == AylaFavoriteState.unknown || widget.state == AylaFavoriteState.error;

  /// tsx 69 行：`disabled={busy || state.loading || (unknown && !state.error)}`
  ///
  /// **关键**：**error 态不 disabled** —— 正是为了「点击重试拉取状态」
  /// （tsx 35–38：`if (state.error || state.favoriteId === undefined)
  ///  { loadFavoriteStatuses(...); return; }`）。
  /// 只有「加载中（unknown 且无 error）」才禁用。
  bool get _disabled =>
      widget.busy || (widget.state == AylaFavoriteState.unknown);

  /// tsx `label`（aria）：error → 「收藏状态加载失败，点击重试」；
  /// unknown → 「正在加载收藏状态」；active → 「取消收藏」；else → 「收藏」。
  String get _ariaLabel {
    switch (widget.state) {
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
    switch (widget.state) {
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
    // tsx 34：`if (busy || state.loading) return`
    if (widget.busy || widget.state == AylaFavoriteState.unknown) return;
    // tsx 35–38：error 或 favoriteId===undefined → 重新拉取状态（不是收藏）
    if (_unknown) {
      widget.onRetryStatus?.call();
      return;
    }
    widget.onToggle?.call(!_active);
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool highlight = _hovered || _focused || _active;

    // `.favorite-toggle`（app.css:3317–3324 声明 cursor: pointer）是 <button>
    // ⇒ 全局 pointer；禁用态归 not-allowed（base.css:343）。
    final Widget button = MouseRegion(
      cursor: _disabled
          ? SystemMouseCursors.forbidden
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _disabled ? null : _handleTap,
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

    Widget result = AylaTooltip(
      // web `title={actionError ?? state.error ?? label}`（FavoriteButton.tsx:72）。
      // ⚠️ Flutter 侧 `AylaFavoriteState` 是枚举、**不带 error 文案字段** ⇒ 取 [actionError] 与
      // [_ariaLabel]（后者在 error 档已给「收藏状态加载失败，点击重试」，与 web 的 label 同源）。
      message: widget.actionError ?? _ariaLabel,
      child: Semantics(
        button: true,
        enabled: !_disabled,
        label: _ariaLabel,
        // aria-pressed = unknown ? undefined : active
        selected: _unknown ? null : _active,
        child: Opacity(
          // :disabled { opacity: .7 }
          opacity: _disabled && widget.busy ? 0.7 : 1,
          child: withGlow,
        ),
      ),
    );

    if (widget.actionError != null) {
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
                widget.actionError!,
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
