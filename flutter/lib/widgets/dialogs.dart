/// 通用确认对话框 + 异步状态占位（`ConfirmDialog.tsx` / `AsyncState.tsx`）。
///
/// ## ConfirmDialog（`components/ConfirmDialog.tsx` + `private.css` 185–292）
///
/// **容器复用通用弹层**（`.create-sheet-overlay` / `.create-sheet-card`）：
/// ```
/// .create-sheet-overlay { position:fixed; inset:0; z-index:70; center;
///   padding: var(--sp-4); background: rgba(70,91,146,.25); }   ← --overlay-dim
/// .create-sheet-card    { width: min(480px,100%); max-height:80vh; overflow-y:auto;
///   padding: var(--sp-4); background: var(--glass-bg-strong);
///   backdrop-filter: var(--glass-filter); border: 1px solid var(--glass-border);
///   border-radius: var(--radius-panel); box-shadow: var(--glass-shadow-modal); }
/// 窄屏(≤768): overlay align-items:flex-end + padding 0;
///   card width 100% + radius 24 24 0 0 + 去掉左右下边框
///   + padding-bottom calc(sp4 + safe-area) + animation create-sheet-slide-in 250ms
/// ```
/// **内容**：`.create-sheet-head`（标题 Fredoka 18/600 + 关闭 icon-btn-40）、
/// `.confirm-dialog-message`（14px / lh 1.6 / `white-space: pre-line`）、
/// `.confirm-dialog-actions`（右对齐、gap sp3、ghost 取消 + destructive 确认）。
///
/// **行为**：ESC 关闭（busy 时不关）、点遮罩关闭、**焦点陷阱**（Tab/Shift+Tab 循环）、
/// **挂载自动聚焦「取消」**（危险操作防回车误触）、busy 时禁用全部关闭路径、
/// 确认按钮 busy 文案「处理中…」。
///
/// ## AsyncState（`components/AsyncState.tsx` + base.css 690–709）
/// ```
/// .async-state-loading/-error/-empty { flex; center; gap: sp3; min-height: 96px;
///   padding: sp4; color: --text-secondary; text-align: center; }
/// .async-state-error { flex-direction: column; color: var(--destructive); }
/// .async-state-skeleton { width:100%; min-height: 72px; }
/// ```
/// 四态：`loading`（骨架）/ `error`（文案 + 「重试」ghost 按钮）/ `empty` / `content`。
library;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, LogicalKeyboardKey;

import '../theme/app_theme.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'loading.dart';

// ======================= ConfirmDialog =======================

/// 通用确认对话框（对应 `ConfirmDialog.tsx`）。
class ConfirmDialog extends StatefulWidget {
  const ConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    this.confirmLabel = '删除',
    this.cancelLabel = '取消',
    this.busy = false,
    required this.onConfirm,
    required this.onClose,
  });

  /// 标题（`.create-sheet-title`）。
  final String title;

  /// 描述文案（支持多行：white-space: pre-line）。
  final String message;

  /// 确认按钮文案（默认「删除」）。
  final String confirmLabel;

  /// 取消按钮文案（默认「取消」）。
  final String cancelLabel;

  /// 执行中：禁用按钮与全部关闭路径（调用方管理）。
  final bool busy;

  /// 确认回调。
  final VoidCallback onConfirm;

  /// 关闭回调（取消 / ESC / 遮罩 / 关闭按钮）。
  final VoidCallback onClose;

  @override
  State<ConfirmDialog> createState() => _ConfirmDialogState();
}

class _ConfirmDialogState extends State<ConfirmDialog> {
  /// 挂载自动聚焦「取消」：危险操作默认焦点给取消，回车不会误触确认。
  final FocusNode _cancelFocus = FocusNode(debugLabel: 'confirm-cancel');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _cancelFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _cancelFocus.dispose();
    super.dispose();
  }

  /// ESC 关闭（busy 时不关）——tsx 在卡片 onKeyDown 上处理。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      if (!widget.busy) widget.onClose();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    // `.create-sheet-card`（复用组件库 [AylaModalCard]：窄屏底部上滑面板）
    final Widget card = AylaModalCard(
      maxHeight: MediaQuery.of(context).size.height * 0.8, // max-height: 80vh
      // `.create-sheet-card { padding: var(--sp-4) }`
      // 窄屏 padding-bottom: calc(sp4 + safe-area)
      padding: EdgeInsets.fromLTRB(
        AylaSpacing.sp4,
        AylaSpacing.sp4,
        AylaSpacing.sp4,
        AylaSpacing.sp4 + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // ---------- .create-sheet-head ----------
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        widget.title,
                        style: t.cardTitle.copyWith(
                          fontFamily: AylaFonts.display, // --font-display
                          fontSize: 18, // font-size: 18px
                          fontWeight: FontWeight.w600, // font-weight: 600
                          color: AylaColors.textPrimary,
                        ),
                      ),
                    ),
                    // 关闭按钮（`.icon-btn-40`）
                    Semantics(
                      button: true,
                      label: '关闭',
                      child: GestureDetector(
                        onTap: widget.busy ? null : widget.onClose,
                        child: Opacity(
                          opacity: widget.busy ? 0.5 : 1.0,
                          child: SizedBox(
                            width: 40, // .icon-btn-40 = 40×40
                            height: 40,
                            child: Icon(
                              Icons.close,
                              size: 18,
                              color: AylaColors.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AylaSpacing.sp3), // margin-bottom: sp3
                // ---------- .confirm-dialog-message ----------
                Text(
                  widget.message,
                  // white-space: pre-line → 保留换行、折叠多余空白
                  style: t.body.copyWith(
                    fontSize: 14,
                    height: 1.6, // line-height: 1.6
                    color: AylaColors.textPrimary,
                  ),
                ),
                const SizedBox(height: AylaSpacing.sp4), // margin-bottom: sp4
                // ---------- .confirm-dialog-actions ----------
                Row(
                  mainAxisAlignment: MainAxisAlignment.end, // justify-content: flex-end
                  spacing: AylaSpacing.sp3, // gap: sp3
                  children: <Widget>[
                    // 取消（`.btn.btn-ghost`）→ 复用 GlassButton
                    // （focusNode/_onKey 保留：ESC 关闭 + 自动聚焦「取消」）
                    _CancelButton(
                      label: widget.cancelLabel,
                      focusNode: _cancelFocus,
                      onKeyEvent: _onKey,
                      onTap: widget.busy ? null : widget.onClose,
                    ),
                    // 确认（`.btn.btn-destructive`）→ 复用 GlassButton
                    GlassButton(
                      label: widget.busy ? '处理中…' : widget.confirmLabel,
                      variant: GlassButtonVariant.destructive,
                      onPressed: widget.busy ? null : widget.onConfirm,
                    ),
                  ],
                ),
              ],
            ),
    );

    // `.create-sheet-overlay`（复用组件库 [AylaModalOverlay]）
    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      child: AylaModalOverlay(
        // 点遮罩关闭（busy 时禁用）
        onDismiss: widget.busy ? null : widget.onClose,
        padding: AylaSpacing.sp4, // `.create-sheet-overlay { padding: var(--sp-4) }`
        child: Focus(
          onKeyEvent: _onKey,
          child: card,
        ),
      ),
    );
  }
}

/// 取消键（`.btn.btn-ghost`）—— **复用 [GlassButton]**，本类只补两件事：
/// 1. `focusNode`（挂载自动聚焦「取消」：危险操作防回车误触）；
/// 2. `onKeyEvent`（ESC 关闭，busy 时不关）。
///
/// 视觉/交互（玻璃底、亮边、hover、200ms、按压 .98）全部来自组件库。
class _CancelButton extends StatelessWidget {
  const _CancelButton({
    required this.label,
    required this.focusNode,
    required this.onKeyEvent,
    required this.onTap,
  });

  final String label;
  final FocusNode focusNode;
  final KeyEventResult Function(FocusNode, KeyEvent) onKeyEvent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      onKeyEvent: onKeyEvent,
      child: GlassButton(
        label: label,
        variant: GlassButtonVariant.ghost,
        onPressed: onTap,
      ),
    );
  }
}

// ======================= AsyncState =======================

/// 异步区域四态（对应 `AsyncState.tsx`）。
enum AsyncStatus { loading, error, empty, content }

/// 异步状态占位（加载 / 错误 / 空 / 内容）。
class AylaAsyncState extends StatelessWidget {
  const AylaAsyncState({
    super.key,
    required this.status,
    this.child,
    this.error,
    this.empty,
    this.onRetry,
  });

  /// 当前状态。
  final AsyncStatus status;

  /// `content` 时渲染的内容。
  final Widget? child;

  /// `error` 时的错误文案（默认「加载失败，请稍后重试」）。
  final String? error;

  /// `empty` 时的自定义占位（默认「这里还没有内容」）。
  final Widget? empty;

  /// `error` 时的重试回调（有则显示「重试」按钮）。
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);

    switch (status) {
      case AsyncStatus.loading:
        // role=status aria-label="正在加载" + `.async-state-skeleton`
        return Semantics(
          label: '正在加载',
          child: Container(
            constraints: const BoxConstraints(minHeight: 96), // min-height: 96px
            padding: const EdgeInsets.all(AylaSpacing.sp4),
            alignment: Alignment.center,
            child: const AylaSkeleton(height: 72), // min-height: 72px
          ),
        );

      case AsyncStatus.error:
        // role=alert + --destructive + 重试按钮
        return Semantics(
          liveRegion: true,
          child: Container(
            constraints: const BoxConstraints(minHeight: 96),
            padding: const EdgeInsets.all(AylaSpacing.sp4),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: AylaSpacing.sp3, // gap: sp3
              children: <Widget>[
                Text(
                  error ?? '加载失败，请稍后重试',
                  textAlign: TextAlign.center,
                  style: t.body.copyWith(
                    color: AylaColors.destructive, // color: var(--destructive)
                  ),
                ),
                if (onRetry != null)
                  TextButton(
                    onPressed: onRetry,
                    child: Text('重试', style: t.label),
                  ),
              ],
            ),
          ),
        );

      case AsyncStatus.empty:
        // role=status
        return Semantics(
          label: '空',
          child: Container(
            constraints: const BoxConstraints(minHeight: 96),
            padding: const EdgeInsets.all(AylaSpacing.sp4),
            alignment: Alignment.center,
            child: empty ??
                Text(
                  '这里还没有内容',
                  textAlign: TextAlign.center,
                  style: t.body.copyWith(color: AylaColors.textSecondary),
                ),
          ),
        );

      case AsyncStatus.content:
        return child ?? const SizedBox.shrink();
    }
  }
}

// ======================= 弹层卡（共享容器） =======================

/// 弹层卡容器（`.create-sheet-card` / `.privacy-sheet-card` 共用）。
///
/// **为什么要抽**：两者规格同源，只有少量参数差异；重复实现会导致
/// 材质/圆角/阴影在两处各自漂移（本项目已发生过：卡片发黑、圆角不一致）。
///
/// ## 事实源（两处对照）
/// ```
/// 共同：width min(480px,100%) · --glass-bg-strong · blur(24) saturate(1.4)
///       1px --glass-border · radius --radius-panel(20) · --glass-shadow-modal
///
/// .create-sheet-card                  | .privacy-sheet-card
/// ----------------------------------- | -----------------------------------
/// max-height: 80vh                    | max-height: min(80vh, 720px)
/// overflow-y: auto（内容整体滚）       | overflow: hidden（head 固定，body 滚）
/// padding: sp4                        | 无（head/body 各自带 sp4）
/// 窄屏：width 100% · radius 24 24 0 0 | 窄屏：height 60dvh · radius 20 20 0 0
///       去左右下边框 · padding-bottom |       去左右下边框 · padding-bottom
///         calc(sp4 + safe-area)       |         safe-area
///       animation create-sheet-       |
///         slide-in 250ms --ease-out   |
/// ```
///
/// [narrowHeightFactor] 非 null 时按视口高度比例取高（PrivacySheet 的 60dvh）；
/// null 则宽屏/窄屏都用 `maxHeight`（create-sheet 的 80vh）。
class AylaModalCard extends StatefulWidget {
  const AylaModalCard({
    super.key,
    required this.child,
    this.maxHeight,
    this.narrowHeightFactor,
    this.padding,
    this.narrowRadius = 24,
    this.scrollable = true,
  });

  /// 内容。
  final Widget child;

  /// 宽屏最大高度（默认 80vh）。
  final double? maxHeight;

  /// 窄屏高度占视口比例（如 0.6 = 60dvh）；null = 用 [maxHeight]。
  final double? narrowHeightFactor;

  /// 外部内边距（`.create-sheet-card { padding: sp4 }`；
  /// PrivacySheet 传 null，由 head/body 各自带）。
  final EdgeInsets? padding;

  /// 窄屏顶部圆角（create-sheet 24；privacy-sheet 用 radius-panel 20）。
  final double narrowRadius;

  /// 内容是否整体可滚（create-sheet true；privacy-sheet false → head 固定）。
  final bool scrollable;

  /// 宽（`width: min(480px, 100%)`）。
  static const double maxWidth = 480;

  /// 宽屏圆角（`--radius-panel`）。
  static const double panelRadius = AylaRadii.rPanel;

  @override
  State<AylaModalCard> createState() => _AylaModalCardState();
}

class _AylaModalCardState extends State<AylaModalCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250), // create-sheet-slide-in 250ms
  );

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // 不能在 initState 读 MediaQuery（会抛依赖未就绪断言）
    if (MediaQuery.of(context).disableAnimations) {
      _slide.value = 1;
    } else {
      _slide.forward(); // translateY(100% → 0)，250ms --ease-out
    }
  }

  @override
  void dispose() {
    _slide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Size vp = MediaQuery.of(context).size;
    final bool narrow = vp.width <= 768;

    // 圆角：宽屏 --radius-panel 20；窄屏顶部圆角（create-sheet 24 / privacy 20）
    final BorderRadius radius = narrow
        ? BorderRadius.vertical(top: Radius.circular(widget.narrowRadius))
        : BorderRadius.circular(AylaModalCard.panelRadius);

    // 高度：窄屏按 factor（60dvh）或 maxHeight；宽屏 maxHeight（默认 80vh）
    final double maxH = narrow
        ? (widget.narrowHeightFactor != null
            ? vp.height * widget.narrowHeightFactor!
            : (widget.maxHeight ?? vp.height * 0.8))
        : (widget.maxHeight ?? vp.height * 0.8);

    // 窄屏贴底固定高（60dvh）；宽屏按需收缩
    final double? fixedH = narrow && widget.narrowHeightFactor != null
        ? vp.height * widget.narrowHeightFactor!
        : null;

    final bool opaque = GlassConfig.useOpaqueFallback;

    Widget body = widget.child;
    if (widget.padding != null) {
      body = Padding(padding: widget.padding!, child: body);
    }
    if (widget.scrollable) {
      body = SingleChildScrollView(child: body); // overflow-y: auto
    }

    Widget face = DecoratedBox(
      decoration: BoxDecoration(
        // `background: var(--glass-bg-strong)`
        color: GlassConfig.resolveBackground(strong: true),
        borderRadius: radius,
        // 窄屏：去左右下边框（只留上边框）
        border: narrow
            ? const Border(top: BorderSide(color: AylaColors.glassBorder))
            : Border.all(color: AylaColors.glassBorder),
      ),
      child: ClipRRect(
        // privacy-sheet `overflow: hidden`；create-sheet 由 SingleChildScrollView
        // 自带裁剪，这里统一包一层以对齐圆角
        borderRadius: radius,
        child: body,
      ),
    );
    if (!opaque) {
      face = Stack(
        children: <Widget>[
          Positioned.fill(
            child: ClipRRect(
              borderRadius: radius,
              child: BackdropFilter(
                // `backdrop-filter: blur(24px) saturate(1.4)`
                filter: GlassConfig.backdropFilter(sigma: AylaGlass.blurCard),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          face,
        ],
      );
    }

    final Widget card = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: AylaModalCard.maxWidth, // min(480px, 100%)
        maxHeight: maxH,
        minHeight: fixedH ?? 0,
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          // `box-shadow: var(--glass-shadow-modal)`（20/60 + --glass-inset）——
          // 只画形状之外（2026-09-20 审查 R2：裸 boxShadow 会染进 .78 玻璃内部）
          Positioned.fill(
            child: IgnorePointer(
              child: AylaGlassShadow.ring(
                radius: radius,
                shadows: AylaShadows.modal,
              ),
            ),
          ),
          face,
        ],
      ),
    );

    // 窄屏上滑入场（`@keyframes create-sheet-slide-in`：translateY(100% → 0)）；
    // 宽屏无位移（PrivacySheet 用 -12px 下落，由调用方自行处理）
    if (!narrow) return card;
    return AnimatedBuilder(
      animation: _slide,
      builder: (BuildContext context, Widget? child) {
        final double v = AylaCurves.easeOut.transform(_slide.value);
        return Transform.translate(
          offset: Offset(0, (1 - v) * 40), // 近似 100%（视口高）用 40px 表达
          child: child,
        );
      },
      child: card,
    );
  }
}

/// 弹层遮罩（`.create-sheet-overlay` / `.privacy-sheet-overlay` 共用）。
///
/// ```
/// position: fixed; inset: 0; z-index (create 70 / privacy 120);
/// background: var(--overlay-dim);  /* rgba(70,91,146,.25) */
/// display:flex; 宽屏 center + padding 24（create 用 sp4）/ privacy 24；
/// 窄屏 align-items: flex-end + padding 0
/// ```
/// 点遮罩关闭（由 [onDismiss] 处理，busy 时调用方传 null）。
class AylaModalOverlay extends StatelessWidget {
  const AylaModalOverlay({
    super.key,
    required this.child,
    this.onDismiss,
    this.padding = 24,
  });

  /// 内容（通常是 [AylaModalCard]）。
  final Widget child;

  /// 点遮罩回调；null = 不可关闭。
  final VoidCallback? onDismiss;

  /// 宽屏四周留白（create-sheet sp4 / privacy 24）。
  final double padding;

  @override
  Widget build(BuildContext context) {
    final bool narrow = MediaQuery.of(context).size.width <= 768;
    return Stack(
      children: <Widget>[
        // 遮罩（`background: var(--overlay-dim)`）
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
            child: const ColoredBox(color: Color(0x40465B92)), // rgba(70,91,146,.25)
          ),
        ),
        // 定位：窄屏贴底（padding 0）；宽屏居中
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.all(narrow ? 0 : padding),
            child: Align(
              alignment: narrow ? Alignment.bottomCenter : Alignment.center,
              child: GestureDetector(
                onTap: () {}, // 卡内点击不冒泡到遮罩
                child: child,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ======================= 预览 =======================

/// ConfirmDialog 全状态（默认 / busy / 长文案多行）。
@Preview(
  group: 'Widgets',
  name: 'ConfirmDialog（默认/busy/多行文案）',
  size: Size(960, 420),
  wrapper: previewTheme,
)
Widget previewConfirmDialog() {
  Widget frame(String label, Widget child) => SizedBox(
        width: 300,
        height: 380,
        child: Stack(
          children: <Widget>[
            child,
            Positioned(
              left: 0,
              bottom: 0,
              child: Text(label, style: const TextStyle(fontSize: 11)),
            ),
          ],
        ),
      );

  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        frame(
          '默认（自动聚焦「取消」）',
          ConfirmDialog(
            title: '删除会话',
            message: '删除会话「小樱」？\n消息记录会保留，对方再发消息时会话将重新出现。',
            onConfirm: () {},
            onClose: () {},
          ),
        ),
        const SizedBox(width: AylaSpacing.sp4),
        frame(
          'busy（按钮禁用 + 「处理中…」）',
          ConfirmDialog(
            title: '删除会话',
            message: '删除会话「小樱」？',
            busy: true,
            onConfirm: () {},
            onClose: () {},
          ),
        ),
        const SizedBox(width: AylaSpacing.sp4),
        frame(
          '自定义按钮文案',
          ConfirmDialog(
            title: '退出群聊',
            message: '退出后需要重新申请才能加入。',
            confirmLabel: '退出',
            cancelLabel: '再想想',
            onConfirm: () {},
            onClose: () {},
          ),
        ),
      ],
    ),
  );
}

/// AsyncState 四态。
@Preview(
  group: 'Widgets',
  name: 'AsyncState（loading/error/empty/content）',
  size: Size(880, 260),
  wrapper: previewTheme,
)
Widget previewAsyncState() {
  Widget cell(String label, Widget child) => SizedBox(
        width: 200,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(height: 130, child: child),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(fontSize: 11)),
          ],
        ),
      );

  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        cell('loading（骨架 96 高）', const AylaAsyncState(status: AsyncStatus.loading)),
        const SizedBox(width: AylaSpacing.sp3),
        cell(
          'error（文案 + 重试）',
          AylaAsyncState(
            status: AsyncStatus.error,
            error: '网络连接失败，请检查网络后重试',
            onRetry: () {},
          ),
        ),
        const SizedBox(width: AylaSpacing.sp3),
        cell('empty（默认文案）', const AylaAsyncState(status: AsyncStatus.empty)),
        const SizedBox(width: AylaSpacing.sp3),
        cell(
          'content（渲染子项）',
          const AylaAsyncState(
            status: AsyncStatus.content,
            child: Center(child: Text('真实内容列表')),
          ),
        ),
      ],
    ),
  );
}
