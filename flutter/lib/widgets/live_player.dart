/// live 域最后一批（B2-6）之一：播放器区域三态渲染（`LivePlayer.tsx` 420 行）。
///
/// ## 事实源（逐条对应 web，禁自由发挥）
/// ```
/// app.css 3517–3525   .live-player：relative · width 100% · **aspect-ratio 16/9** ·
///                     background rgba(70,91,146,.12) · radius-card · overflow hidden · 1px --glass-border
/// app.css 3528–3533   .live-player-video：100%×100% · object-fit contain · background #000
/// app.css 3535–3553   .live-player-placeholder：absolute inset 0 · column · center · gap sp3 ·
///                     --text-secondary；`.live-player-degraded` → --warning；`.live-player-error` → --destructive
/// app.css 3557–3615   .live-player-controls（absolute inset 0 · z 5 · opacity 0 → is-visible 1 ·
///                     transition --dur-fast；隐藏时整层 pointer-events 穿透）·
///                     .live-player-btn（32×32 · pill · rgba(70,91,146,.32) · 1px rgba(255,255,255,.28) ·
///                     #fff · blur(8px) saturate(1.2) · hover .52 · focus-visible --focus-ring）·
///                     .live-player-refresh（left sp2 / bottom sp2）· .live-player-corner（right sp2 /
///                     bottom sp2 / gap sp2）
/// app.css 3618–3636   .live-player-refresh.is-spinning svg → live-refresh-spin 0.6s --ease-out；
///                     prefers-reduced-motion → animation none
/// live.css 939–1005   .live-player-fs-input（absolute · left 50% · bottom sp2 · translateX(-50%) ·
///                     gap sp2 · **width min(320px, 100% - 120px)** · min-height 50 · padding 4 4 4 12 ·
///                     radius-input · --glass-bg · 1px 亮边 · **--glass-filter（blur24 sat1.4）** ·
///                     默认穿透，容器可见时才可交互）+ input（flex 1 · **min-height 40** · 透明 ·
///                     14px · ::placeholder --slate-500）+ `.live-player-fs-send`（**40×40** · `.btn-primary`）
/// live.css 961–980    .live-player-fs-error（输入框上方 · 玻璃 · 12px/1.5 · 居中 · 可换行）
/// tsx 24              `AUTO_HIDE_MS = 3000`（显示后 3s 无操作自动隐藏）
/// tsx 186–363         三态：`srsStatus === null` → 「正在查询直播状态…」/ degraded →
///                     「直播服务状态未知，请稍后再试」/ idle → 「等待推流信号…」（optimistic live）
///                     或「主播未开播」/ live + playerError → 「播放失败」+ `btn.btn-glow`「重试」
/// tsx 365–418         根 div 的 onMouseEnter/onMouseMove/onClick → showControls、onMouseLeave → hideControls
/// tsx 74–139          全屏弹幕输入（独立 owner：revision 守卫 + busy 守卫 + Enter 发送 + 200 上限）
/// ```
///
/// ## 与 web 的装配差异（组件不写页面）
/// - **video 元素在 web 由 runtime 持有并在大窗/小窗之间原子迁移**；Flutter 侧由页面把
///   `HlsPlaybackController.videoView`（PoC-B 封装层）作为 [AylaLivePlayer.videoView] 注入，
///   组件只负责摆位与显隐（控制器生命周期属页面）；
/// - **画中画按钮不实现**：web 走浏览器 PiP API（`requestPictureInPicture` /
///   `webkitSetPresentationMode`），Flutter 端无等价物；窄屏本来就 `hidePipButton`，
///   手机端小窗由 [AylaLiveMiniPlayer] 承担 ⇒ 本件不渲染 PiP 键（登记为有意偏离）；
/// - **全屏**：web 用 `requestFullscreen()` 让容器进 top layer；Flutter 侧改为**插 root Overlay**
///   的全屏呈现（同一控制器、视图在 overlay 里重挂；inline 侧在全屏期间不再挂视频，
///   避免平台视图被同时 attach 两次）+ 移动端锁横屏（退出时解锁）。桌面/Web 忽略锁屏。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show DeviceOrientation, LogicalKeyboardKey, SystemChrome;
import 'package:flutter/widget_previews.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'live_hall.dart' show AylaLiveStatus;
import 'overlays.dart';

/// SRS 直播服务状态（web `LiveSrsStatus`；null = 尚未查到）。
enum AylaLiveSrsStatus { degraded, idle, live }

/// 悬浮按钮无操作自动隐藏时长（tsx 24 `AUTO_HIDE_MS = 3000`）。
const Duration kLivePlayerAutoHide = Duration(milliseconds: 3000);

/// 刷新键旋转时长（app.css 3619 `live-refresh-spin 0.6s`；tsx 328 的复位计时 650ms）。
const Duration kLivePlayerSpin = Duration(milliseconds: 600);
const Duration kLivePlayerSpinReset = Duration(milliseconds: 650);

/// 播放器区域三态渲染（`LivePlayer.tsx`）。
class AylaLivePlayer extends StatefulWidget {
  const AylaLivePlayer({
    super.key,
    this.srsStatus,
    this.optimisticStatus,
    this.playerError,
    this.videoView,
    this.onRetry,
    this.onRefresh,
    this.onSendDanmaku,
    this.danmakuOwner,
    this.danmakuError,
    this.children,
    this.overlayHostBuilder,
    this.onFullscreenChanged,
    this.flat = false,
  });

  /// SRS 状态；**null = 正在查询**（tsx 332）。
  final AylaLiveSrsStatus? srsStatus;

  /// 频道乐观状态（idle 占位文案区分「等待推流信号」用，tsx 344）。
  final AylaLiveStatus? optimisticStatus;

  /// 播放致命错误（live 但播放失败 → 「播放失败 + 重试」，tsx 352）。
  final String? playerError;

  /// 视频视图（页面注入 `HlsPlaybackController.videoView`；null = 无画面）。
  final Widget? videoView;

  /// 重试（tsx 356）。
  final VoidCallback? onRetry;

  /// 跳到直播最新画面（左下刷新键，tsx 325）。
  final VoidCallback? onRefresh;

  /// 全屏发弹幕（tsx 171）；null = 不渲染全屏输入框。
  final Future<bool> Function(String content)? onSendDanmaku;

  /// 全屏草稿的归属（换人不复用草稿，tsx 173）。
  final String? danmakuOwner;

  /// 全屏发送错误文案（tsx 174）。
  final String? danmakuError;

  /// 画面叠加层（飘弹幕层等；渲染时机由调用方控制，tsx 376）。
  final Widget? children;

  /// 全屏呈现的宿主（默认插 root Overlay；测试可注入替身）。
  final OverlayEntry Function(Widget child)? overlayHostBuilder;

  /// 全屏状态变化（web 由 `document.fullscreenchange` 通知 `LiveRoomBody` 冻结 isNarrow，
  /// 防锁横屏导致窄↔宽切换、播放器重建黑屏 —— tsx 96–111）。
  final ValueChanged<bool>? onFullscreenChanged;

  /// **扁平档**：圆角与边框交给外层 stage 裁剪（web `.live-room-swipe-item .live-player
  /// { border-radius: 0; border: none }`，live.css 747–751）——窄屏沉浸式用，
  /// 由 `.live-room-stage` 统一收 `--radius-input` 圆角（live.css 825–828）。
  final bool flat;

  @override
  State<AylaLivePlayer> createState() => _AylaLivePlayerState();
}

class _AylaLivePlayerState extends State<AylaLivePlayer> {
  bool _controlsVisible = false;
  bool _spinning = false;
  bool _fullscreen = false;
  Timer? _hideTimer;
  Timer? _spinTimer;
  OverlayEntry? _fsEntry;

  bool get _showVideo =>
      widget.srsStatus == AylaLiveSrsStatus.live && widget.playerError == null;

  @override
  void dispose() {
    _hideTimer?.cancel();
    _spinTimer?.cancel();
    _fsEntry?.remove();
    _fsEntry = null;
    _unlockOrientation();
    super.dispose();
  }

  // ---- 悬浮按钮显隐 + 3s 无操作自动隐藏（tsx 243–261）----
  void _clearHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  void _armHideTimer() {
    _clearHideTimer();
    _hideTimer = Timer(kLivePlayerAutoHide, () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _showControls() {
    setState(() => _controlsVisible = true);
    _armHideTimer();
  }

  void _hideControls() {
    if (!mounted) return;
    setState(() => _controlsVisible = false);
    _clearHideTimer();
  }

  // ---- 刷新（tsx 321–329：0.65s 后复位；用计时器保证 reduced-motion 下也能复位）----
  void _handleRefresh() {
    _armHideTimer();
    if (_spinning) return;
    setState(() => _spinning = true);
    widget.onRefresh?.call();
    _spinTimer?.cancel();
    _spinTimer = Timer(kLivePlayerSpinReset, () {
      if (mounted) setState(() => _spinning = false);
    });
  }

  // ---- 全屏（web：容器 requestFullscreen；Flutter：root Overlay + 移动端锁横屏）----
  void _lockLandscape() {
    // 桌面/Web 忽略（web 侧同样静默失败，tsx 46–57）
    if (Theme.of(context).platform == TargetPlatform.android ||
        Theme.of(context).platform == TargetPlatform.iOS) {
      unawaited(
        SystemChrome.setPreferredOrientations(<DeviceOrientation>[
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]),
      );
    }
  }

  void _unlockOrientation() {
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
  }

  void _toggleFullscreen() {
    _armHideTimer();
    if (_fullscreen) {
      _exitFullscreen();
      return;
    }
    setState(() => _fullscreen = true);
    widget.onFullscreenChanged?.call(true);
    _lockLandscape();
    final OverlayEntry entry = (widget.overlayHostBuilder ?? aylaOverlayEntry)(
      _buildFullscreen(),
    );
    _fsEntry = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
  }

  void _exitFullscreen() {
    _fsEntry?.remove();
    _fsEntry = null;
    _unlockOrientation();
    widget.onFullscreenChanged?.call(false);
    if (mounted) setState(() => _fullscreen = false);
  }

  /// 全屏呈现：铺满窗口的黑底 + 同一画面 + 同一悬浮控件（含全屏弹幕输入）。
  Widget _buildFullscreen() {
    return _LivePlayerFullscreenHost(
      onExit: _exitFullscreen,
      child: Builder(
        // 全屏里的播放器内容与 inline 共用同一构建函数（同一控制器）
        builder: (BuildContext ctx) => _content(fullscreen: true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => _showControls(),
      onHover: (_) => _showControls(), // onMouseMove 等价（tsx 370）
      onExit: (_) => _hideControls(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _showControls, // `onClick={showControls}`（触屏点击视频显示）
        child: _content(fullscreen: false),
      ),
    );
  }

  /// 播放器内容（inline 与全屏共用；全屏时外层是黑底铺满）。
  Widget _content({required bool fullscreen}) {
    return AspectRatio(
      // `.live-player { aspect-ratio: 16 / 9 }`（全屏时由宿主铺满，不再受 16:9 限制）
      aspectRatio: fullscreen ? 1 : 16 / 9,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0x1F465B92), // rgba(70,91,146,.12)
          borderRadius: (fullscreen || widget.flat)
              ? BorderRadius.zero
              : BorderRadius.circular(AylaRadii.rCard),
          border: (fullscreen || widget.flat)
              ? null
              : Border.all(color: AylaColors.glassBorder),
        ),
        child: ClipRRect(
          borderRadius: (fullscreen || widget.flat)
              ? BorderRadius.zero
              : BorderRadius.circular(AylaRadii.rCard),
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              // 视频（`.live-player-video`：contain + #000 底）；全屏期间 inline 不再挂视频
              if (_showVideo && (!fullscreen || _fullscreen == fullscreen))
                ColoredBox(
                  color: Colors.black,
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: widget.videoView ??
                        const SizedBox(width: 160, height: 90),
                  ),
                ),
              // 调用方的叠加层（飘弹幕）
              if (widget.children != null) widget.children!,
              if (_showVideo) _controls(fullscreen: fullscreen),
              if (!_showVideo) _overlay(),
            ],
          ),
        ),
      ),
    );
  }

  /// `.live-player-controls`（opacity 0/1 + 隐藏时整层穿透）。
  Widget _controls({required bool fullscreen}) {
    return IgnorePointer(
      ignoring: !_controlsVisible,
      child: AnimatedOpacity(
        opacity: _controlsVisible ? 1 : 0,
        duration: AylaDurations.fast, // transition: opacity var(--dur-fast)
        curve: AylaCurves.easeOut,
        child: Stack(
          children: <Widget>[
            Positioned(
              left: AylaSpacing.sp2,
              bottom: AylaSpacing.sp2,
              child: _btn(
                icon: aylaIconByName('iconRefresh')!,
                label: '跳到最新画面',
                onPressed: _handleRefresh,
                spinning: _spinning,
              ),
            ),
            Positioned(
              right: AylaSpacing.sp2,
              bottom: AylaSpacing.sp2,
              child: Row(
                spacing: AylaSpacing.sp2, // `.live-player-corner { gap: var(--sp-2) }`
                children: <Widget>[
                  // ⚠️ 画中画键不实现（浏览器 PiP 无 Flutter 等价物；窄屏 web 本来就隐藏）
                  _btn(
                    icon: aylaIconByName('iconFullscreen')!,
                    label: '全屏',
                    onPressed: _toggleFullscreen,
                  ),
                ],
              ),
            ),
            if (fullscreen && widget.onSendDanmaku != null)
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: AylaSpacing.sp2),
                  child: _FullscreenDanmakuInput(
                    key: ValueKey<String?>(widget.danmakuOwner),
                    onSend: widget.onSendDanmaku!,
                    serverError: widget.danmakuError,
                    onFocus: _clearHideTimer,
                    onBlur: _armHideTimer,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// `.live-player-btn`（32×32 玻璃圆钮 + 白图标）。
  Widget _btn({
    required AylaIconData icon,
    required String label,
    required VoidCallback onPressed,
    bool spinning = false,
  }) {
    return _PlayerButton(
      icon: icon,
      label: label,
      onPressed: onPressed,
      spinning: spinning,
    );
  }

  /// 占位层（tsx 331–363 的三态 + 播放失败）。
  Widget _overlay() {
    final AylaLiveSrsStatus? status = widget.srsStatus;
    if (status == null) {
      return _placeholder('正在查询直播状态…');
    }
    if (status == AylaLiveSrsStatus.degraded) {
      // `.live-player-degraded { color: var(--warning) }`
      return _placeholder('直播服务状态未知，请稍后再试', color: AylaColors.warning);
    }
    if (status == AylaLiveSrsStatus.idle) {
      final bool waiting = widget.optimisticStatus == AylaLiveStatus.live;
      return _placeholder(waiting ? '等待推流信号…' : '主播未开播');
    }
    // live + playerError
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: AylaSpacing.sp3, // gap: var(--sp-3)
        children: <Widget>[
          Text(
            '播放失败',
            style: AylaTextStyles.of(context).body.copyWith(
              color: AylaColors.destructive, // `.live-player-error`
            ),
          ),
          GlassButton(
            label: '重试',
            variant: GlassButtonVariant.glow, // `.btn.btn-glow`
            onPressed: widget.onRetry,
          ),
        ],
      ),
    );
  }

  Widget _placeholder(String text, {Color? color}) {
    return Center(
      child: Text(
        text,
        style: AylaTextStyles.of(context).body.copyWith(
          color: color ?? AylaColors.textSecondary,
        ),
      ),
    );
  }
}

/// `.live-player-btn`：32×32 圆钮（indigo 半透明底 + 白图标 + blur8 sat1.2）。
class _PlayerButton extends StatefulWidget {
  const _PlayerButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.spinning = false,
  });

  final AylaIconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool spinning;

  @override
  State<_PlayerButton> createState() => _PlayerButtonState();
}

class _PlayerButtonState extends State<_PlayerButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final Widget icon = AylaIcon(widget.icon, size: 16, color: Colors.white);
    return Semantics(
      button: true,
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Focus(
          onFocusChange: (bool has) => setState(() => _focused = has),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: _hovered
                    ? const Color(0x85465B92) // hover rgba(70,91,146,.52)
                    : const Color(0x52465B92), // rgba(70,91,146,.32)
                borderRadius: AylaRadii.pill,
                border: Border.all(
                  // `:focus-visible { outline: var(--focus-ring) }` = 2px glow-500；
                  // Flutter 侧按「边色换 glow」表达（32px 圆钮上加外环会顶破 8px 边距）
                  color: _focused
                      ? AylaColors.glow500
                      : const Color(0x47FFFFFF), // rgba(255,255,255,.28)
                  width: _focused ? 2 : 1,
                ),
              ),
              alignment: Alignment.center,
              child: widget.spinning
                  // `live-refresh-spin 0.6s`（reduced-motion → 不转，仅复位计时照跑）
                  ? TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0, end: 1),
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : kLivePlayerSpin,
                      curve: AylaCurves.easeOut,
                      builder:
                          (BuildContext context, double t, Widget? child) =>
                              Transform.rotate(
                                angle: t * 2 * 3.141592653589793,
                                child: child,
                              ),
                      child: icon,
                    )
                  : icon,
            ),
          ),
        ),
      ),
    );
  }
}

/// 全屏宿主：黑底铺满窗口（web `:fullscreen` 的等价），点空白/按 ESC 退出。
class _LivePlayerFullscreenHost extends StatelessWidget {
  const _LivePlayerFullscreenHost({required this.child, required this.onExit});

  final Widget child;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (DismissIntent intent) {
              onExit();
              return null;
            },
          ),
        },
        child: FocusScope(
          autofocus: true,
          child: ColoredBox(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                child,
                // 退出键（右上，与悬浮控件同风格；全屏里也要能退出）
                Positioned(
                  top: AylaSpacing.sp2,
                  right: AylaSpacing.sp2,
                  child: _PlayerButton(
                    icon: aylaIconByName('iconClose')!,
                    label: '退出全屏',
                    onPressed: onExit,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 全屏弹幕输入（tsx 74–139 + live.css 939–1005）。
class _FullscreenDanmakuInput extends StatefulWidget {
  const _FullscreenDanmakuInput({
    super.key,
    required this.onSend,
    this.serverError,
    this.onFocus,
    this.onBlur,
  });

  final Future<bool> Function(String content) onSend;
  final String? serverError;
  final VoidCallback? onFocus;
  final VoidCallback? onBlur;

  @override
  State<_FullscreenDanmakuInput> createState() =>
      _FullscreenDanmakuInputState();
}

class _FullscreenDanmakuInputState extends State<_FullscreenDanmakuInput> {
  final TextEditingController _draft = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _sending = false;
  String? _failed;
  int _revision = 0; // 提交期间用户改过草稿 ⇒ 成功后不清空（tsx 105–108）

  @override
  void dispose() {
    _draft.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String content = _draft.text.trim();
    if (content.isEmpty || _sending) return;
    final int submitted = _revision;
    setState(() {
      _sending = true;
      _failed = null;
    });
    try {
      final bool ok = await widget.onSend(content);
      if (!mounted) return;
      if (ok) {
        if (_revision == submitted) {
          _revision += 1;
          _draft.clear();
        }
        _focus.requestFocus();
      } else {
        setState(() => _failed = '发送失败，请重试');
      }
    } on Object {
      if (mounted) setState(() => _failed = '发送失败，请重试');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return ConstrainedBox(
      // `width: min(320px, calc(100% - 120px))` + `min-height: 50px`
      constraints: const BoxConstraints(maxWidth: 320, minHeight: 50),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_failed != null || widget.serverError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AylaSpacing.sp2),
              child: DecoratedBox(
                // `.live-player-fs-error`：玻璃小片 + 12px 居中
                decoration: BoxDecoration(
                  color: AylaColors.glassBg,
                  borderRadius: BorderRadius.circular(AylaRadii.rSm),
                  border: Border.all(color: AylaColors.glassBorder),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Text(
                    widget.serverError ?? _failed!,
                    textAlign: TextAlign.center,
                    style: t.body.copyWith(fontSize: 12, height: 1.5),
                  ),
                ),
              ),
            ),
          Container(
            // `.live-player-fs-input`：玻璃外框持有背景，内 input 透明
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            decoration: BoxDecoration(
              color: AylaColors.glassBg,
              borderRadius: BorderRadius.circular(AylaRadii.rInput),
              border: Border.all(color: AylaColors.glassBorder),
            ),
            child: Row(
              spacing: AylaSpacing.sp2,
              children: <Widget>[
                Expanded(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 40),
                    child: TextField(
                      controller: _draft,
                      focusNode: _focus,
                      maxLength: 200,
                      onChanged: (_) => _revision += 1,
                      onSubmitted: (_) => unawaited(_submit()),
                      onTap: widget.onFocus,
                      onTapOutside: (_) => widget.onBlur?.call(),
                      style: t.body.copyWith(
                        fontSize: 14,
                        color: AylaColors.textPrimary,
                      ),
                      cursorColor: AylaColors.glow500,
                      decoration: InputDecoration(
                        isDense: true,
                        counterText: '',
                        border: InputBorder.none,
                        hintText: '发条弹幕吧', // tsx 129
                        hintStyle: t.body.copyWith(color: AylaColors.slate500),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                ),
                GlassButton(
                  // `.live-player-fs-send`：40×40 · `.btn-primary`
                  label: '',
                  icon: AylaIcon(
                    aylaIconByName('iconSend')!,
                    size: 16,
                    color: AylaColors.surface,
                  ),
                  variant: GlassButtonVariant.primary,
                  minWidth: 40,
                  minHeight: 40,
                  padding: EdgeInsets.zero,
                  semanticLabel: '发送弹幕', // tsx 134
                  onPressed: _sending || _draft.text.trim().isEmpty
                      ? null
                      : () => unawaited(_submit()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ======================= 预览样张 =======================

/// 播放器三态 + 悬浮控件 + 全屏样张（可交互：悬停/点击显示控件、3s 自动隐藏、刷新旋转、全屏）。
Widget aylaLivePlayerSamples() {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      _Stage(
        viewport: const Size(640, 360),
        label:
            '播放器 · live（`.live-player` 16:9 / rgba(70,91,146,.12) / radius 16 / 1px 亮边）· 可交互：**悬停或点击**显示悬浮键（左下刷新 / 右下全屏），显示后 **3s 无操作自动隐藏**；点刷新看 0.6s 旋转',
        child: _PlayerDemo(
          srsStatus: AylaLiveSrsStatus.live,
          video: true,
        ),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(640, 640),
        label:
            '四态占位 · 正在查询（`srsStatus == null`）/ degraded（`--warning`）/ idle（`主播未开播`）/ idle+乐观已开播（`等待推流信号…`）· 播放失败 = `播放失败`（destructive）+ `.btn-glow`「重试」',
        child: const _PlayerStatesDemo(),
      ),
    ],
  );
}

class _PlayerDemo extends StatelessWidget {
  const _PlayerDemo({required this.srsStatus, this.video = false});

  final AylaLiveSrsStatus? srsStatus;
  final bool video;

  @override
  Widget build(BuildContext context) {
    return AylaLivePlayer(
      srsStatus: srsStatus,
      optimisticStatus: AylaLiveStatus.live,
      videoView: video ? const _FakeVideo() : null,
      onRefresh: () {},
      onRetry: () {},
      onSendDanmaku: (String content) async => true,
    );
  }
}

/// 样张用的假画面（真实视频由页面的 `HlsPlaybackController.videoView` 注入）。
class _FakeVideo extends StatelessWidget {
  const _FakeVideo();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF2A3550),
      child: Center(
        child: Text(
          'HLS videoView（页面注入）',
          style: AylaTextStyles.of(context).body.copyWith(
            color: Colors.white70,
          ),
        ),
      ),
    );
  }
}

class _PlayerStatesDemo extends StatelessWidget {
  const _PlayerStatesDemo();

  @override
  Widget build(BuildContext context) {
    Widget cell(Widget child) => Expanded(child: AspectRatio(aspectRatio: 16 / 9, child: child));
    return Column(
      mainAxisSize: MainAxisSize.min,
      spacing: AylaSpacing.sp2,
      children: <Widget>[
        Row(
          spacing: AylaSpacing.sp2,
          children: <Widget>[
            cell(const AylaLivePlayer()),
            cell(
              const AylaLivePlayer(srsStatus: AylaLiveSrsStatus.degraded),
            ),
          ],
        ),
        Row(
          spacing: AylaSpacing.sp2,
          children: <Widget>[
            cell(const AylaLivePlayer(srsStatus: AylaLiveSrsStatus.idle)),
            cell(
              const AylaLivePlayer(
                srsStatus: AylaLiveSrsStatus.idle,
                optimisticStatus: AylaLiveStatus.live,
              ),
            ),
          ],
        ),
        Row(
          spacing: AylaSpacing.sp2,
          children: <Widget>[
            cell(
              const AylaLivePlayer(
                srsStatus: AylaLiveSrsStatus.live,
                playerError: '播放失败',
              ),
            ),
            const Spacer(),
          ],
        ),
      ],
    );
  }
}

/// 固定视口的样张舞台。
class _Stage extends StatelessWidget {
  const _Stage({
    required this.viewport,
    required this.label,
    required this.child,
  });

  final Size viewport;
  final String label;
  final Widget child;

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
              child: child,
            ),
          ),
        ),
        const SizedBox(height: AylaSpacing.sp1),
        SizedBox(
          width: viewport.width,
          child: Text(label, style: const TextStyle(fontSize: 11)),
        ),
      ],
    );
  }
}

/// 播放器区域三态渲染。
@Preview(
  group: 'Widgets',
  name: '直播播放器',
  size: Size(700, 1200),
  wrapper: previewTheme,
)
Widget aylaLivePlayerPreview() => aylaLivePlayerSamples();
