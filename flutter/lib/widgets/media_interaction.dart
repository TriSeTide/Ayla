/// 视频与滚动交互族（`SignedVideo.tsx` / `PullToRefresh.tsx` /
/// `overlay/OverlayScrollbar.tsx`）。
///
/// 三者都是**交互/媒体**类组件，事实源见各段落注释。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../core/media/media_signer.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import 'loading.dart';

// ======================= SignedVideo =======================

/// 签名 URL 直连的视频（`SignedVideo.tsx`）。
///
/// ## 事实源（tsx 1–78 + `api/media.ts`）
/// - **契约（tsx 注释 7–11）**：`MediaDescriptor.thumbnail` 是**派生封面对象路径**
///   （`/api/v1/media/{id}/thumbnail`，JPEG 静帧，图片缩略图与视频海报帧共用），
///   **绝不能作为 `<video src>`** —— 此前帖子卡把该路径塞给 video 导致无源可播
///   （黑块）。本组件**按 media_id 签发 original 视频 URL**。
/// - 定位：**无海报帧视频**（存量/抽帧失败）的首帧预览降级路径；有海报帧的走
///   `PostVideoCover`（`<img>` 秒出，不挂 video 元素）。
/// - 加载态：skeleton（`role=status` aria「视频加载中」）
/// - 失败态：`.resource-image-failed-wrap` + 按钮「视频加载失败，点击重试」
///   （重试 = `invalidateSignedMediaUrl` + 重新签发）
/// - 播放参数：`preload="metadata"`、`playsInline`、**`muted={!controls}`**
///   （卡片预览静音、详情页内联有控制条）、src 追加 **`#t=0.1`**（跳过首帧黑场）
///
/// ## Flutter 侧说明
/// `video_player` 依赖尚未引入（属媒体批次）。本组件先提供**接口与状态机**
/// （签发 → 加载/失败/重试骨架），播放器接入时替换 `_buildPlayer` 即可。
class SignedVideo extends StatefulWidget {
  const SignedVideo({
    super.key,
    required this.mediaId,
    this.controls = false,
    this.ariaLabel,
    this.aspectRatio = 16 / 9,
  });

  /// 媒体 id（用于签发 original 视频 URL）。
  final String mediaId;

  /// 是否显示控制条（详情页 true；卡片首帧预览 false）。
  final bool controls;

  /// 无障碍标签。
  final String? ariaLabel;

  /// 占位宽高比（视频未就绪时）。
  final double aspectRatio;

  @override
  State<SignedVideo> createState() => _SignedVideoState();
}

enum _VideoState { loading, ready, failed }

class _SignedVideoState extends State<SignedVideo> {
  _VideoState _state = _VideoState.loading;
  String? _src;

  @override
  void initState() {
    super.initState();
    _sign();
  }

  @override
  void didUpdateWidget(covariant SignedVideo old) {
    super.didUpdateWidget(old);
    if (old.mediaId != widget.mediaId) _sign();
  }

  Future<void> _sign() async {
    setState(() {
      _state = _VideoState.loading;
      _src = null;
    });
    try {
      // 必须签发 **original**（不是 thumbnail）：thumbnail 是 JPEG 静帧，
      // 作为 video src 会导致无源可播（tsx 注释 7–11 明确警告）。
      final SignedMediaResult r =
          await MediaSigner.instance.sign(widget.mediaId);
      if (!mounted) return;
      setState(() {
        // src 追加 `#t=0.1`：跳过首帧黑场（tsx 79 行 `src={`${src}#t=0.1`}`）
        _src = '${r.url}#t=0.1';
        _state = _VideoState.ready;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = _VideoState.failed);
    }
  }

  void _retry() {
    MediaSigner.instance.invalidate(widget.mediaId); // 失效缓存后重签
    _sign();
  }

  @override
  Widget build(BuildContext context) {
    switch (_state) {
      case _VideoState.loading:
        // `<span class="skeleton" role=status aria-label="视频加载中">`
        return Semantics(
          label: '视频加载中',
          child: AspectRatio(
            aspectRatio: widget.aspectRatio,
            child: const AylaSkeleton(),
          ),
        );

      case _VideoState.failed:
        // `.resource-image-fallback` 按钮「视频加载失败，点击重试」
        return _VideoFailed(onRetry: _retry);

      case _VideoState.ready:
        return _buildPlayer(_src!);
    }
  }

  /// 播放器（video_player 接入点）。
  ///
  /// 当前未引依赖 → 渲染带 `#t=0.1` 的源信息占位，保证**状态机与契约可验证**。
  Widget _buildPlayer(String src) {
    return AspectRatio(
      aspectRatio: widget.aspectRatio,
      child: Semantics(
        label: widget.ariaLabel,
        child: ColoredBox(
          color: AylaColors.ice100, // 未播放时的中性底
          child: Center(
            child: Text(
              '视频源已签发\nmuted=${!widget.controls}  controls=${widget.controls}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: AylaFonts.utility,
                fontSize: 11,
                color: AylaColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 视频失败占位（`.resource-image-failed-wrap` + 「点击重试」）。
class _VideoFailed extends StatelessWidget {
  const _VideoFailed({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Semantics(
        button: true,
        label: '视频加载失败，重试',
        child: GestureDetector(
          onTap: onRetry,
          child: Container(
            // `.resource-image-fallback { min-width:40; min-height:32;
            //   padding: 4px 8px; radius-sm 8 }`
            constraints: const BoxConstraints(minWidth: 40, minHeight: 32),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AylaColors.glassBg,
              borderRadius: BorderRadius.circular(AylaRadii.rSm),
            ),
            child: const Text(
              '视频加载失败，点击重试',
              style: TextStyle(
                fontFamily: AylaFonts.body,
                fontSize: 11,
                color: AylaColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ======================= PullToRefresh =======================

/// 下拉刷新状态（`PullStatus`）。
enum PullStatus { idle, pulling, refreshing, done }

/// 视觉阻尼（`dampPull`，tsx 46–49）：
/// `maxPull * (1 - exp(-dy / dampFactor))` —— 手指位移越大、视觉增速越慢，
/// 渐近逼近 `maxPull`。**阈值判定仍用原始 dy**（手指真拉过 threshold 才触发）。
double dampPull(double dy, {double maxPull = 96, double dampFactor = 90}) {
  if (dy <= 0) return 0;
  return maxPull * (1 - math.exp(-dy / dampFactor));
}

/// 下拉手势跟踪器（`createPullTracker`，tsx 57–100 的纯函数等价）。
///
/// 与 React 版同构：只有 `canPull()` 为真（滚动容器在顶部）才开始跟踪；
/// 移动中若不再满足则放弃本次下拉；`end` 用**原始 dy** 判阈值。
class PullTracker {
  PullTracker({
    required this.threshold,
    required this.canPull,
    required this.onOffsetChange,
    required this.onPullEnd,
    required this.onPullCancel,
  });

  /// 触发刷新的手指下拉阈值（px）。
  final double threshold;

  /// 滚动容器是否在顶部（允许开始下拉）。
  final bool Function() canPull;

  /// 视觉位移变化（阻尼后）。
  final ValueChanged<double> onOffsetChange;

  /// 松手：`shouldRefresh` 表示是否达阈值。
  final ValueChanged<bool> onPullEnd;

  /// 手势被取消。
  final VoidCallback onPullCancel;

  double _startY = 0;
  bool _tracking = false;
  double _offset = 0;

  /// 是否正在跟踪一次下拉。
  bool get isTracking => _tracking;

  /// 最近一次阻尼后的视觉位移。
  double get lastOffset => _offset;

  void _setOffset(double v) {
    _offset = v;
    onOffsetChange(v);
  }

  void start(double clientY) {
    if (!canPull()) return;
    _startY = clientY;
    _tracking = true;
    _setOffset(0);
  }

  void move(double clientY) {
    if (!_tracking) return;
    final double dy = clientY - _startY;
    if (dy <= 0) {
      _setOffset(0);
      return;
    }
    // 已开始下拉但此刻容器不在顶部（快速甩动/内容回弹）→ 放弃本次
    if (!canPull()) {
      _setOffset(0);
      return;
    }
    _setOffset(dampPull(dy));
  }

  void end(double clientY) {
    if (!_tracking) return;
    _tracking = false;
    final double dy = clientY - _startY;
    onPullEnd(dy >= threshold); // 阈值用原始 dy
  }

  void cancel() {
    if (!_tracking) return;
    _tracking = false;
    onPullCancel();
  }
}

/// 下拉刷新容器（`PullToRefresh.tsx` + app.css 4008–4071）。
///
/// ```
/// .pull-to-refresh   { position:relative; min-height:0 }
/// .pull-refresh-content { position:relative }
/// .pull-refresh-indicator { position:absolute; top:0; left:0; right:0; height:52px;
///   center; pointer-events:none; z-index:1; opacity:0;
///   transition: opacity 150ms var(--ease-out) }
/// .is-pulling/.is-refreshing/.is-done → indicator opacity:1
/// .pull-refresh-dot { 36×36 圆; --glass-bg-strong; blur(18px) saturate(1.4);
///   1px --glass-border; --card-shadow; color --indigo-700 }
/// .pull-refresh-check → color: var(--success)
/// ```
/// 常量：`INDICATOR_SPACE = 52`、`REFRESH_OFFSET = 52`、`MAX_PULL = 96`、
/// 收起动画 200ms `--ease-out`；`done` 停留 300ms 后收起；
/// reduced-motion 直接置位、无动画。
class AylaPullToRefresh extends StatefulWidget {
  const AylaPullToRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
    this.isAtTop,
    this.threshold = 64,
    this.disabled = false,
  });

  /// 刷新回调（完成后收起）。
  final Future<void> Function() onRefresh;

  /// 内容（通常是列表）。
  final Widget child;

  /// 滚动容器是否在顶部；缺省视为始终可下拉。
  final bool Function()? isAtTop;

  /// 触发刷新的手指下拉阈值（px）。
  final double threshold;

  /// 禁用（如非窄屏 / 非列表场景）。
  final bool disabled;

  /// 指示器展开高度 / 刷新停留位移（`INDICATOR_SPACE` / `REFRESH_OFFSET`）。
  static const double indicatorSpace = 52;
  static const double refreshOffset = 52;

  @override
  State<AylaPullToRefresh> createState() => _AylaPullToRefreshState();
}

class _AylaPullToRefreshState extends State<AylaPullToRefresh>
    with SingleTickerProviderStateMixin {
  late final PullTracker _tracker;
  PullStatus _status = PullStatus.idle;
  bool _refreshing = false;

  /// 视觉位移（阻尼后），驱动内容与指示器。
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200), // 收起动画 200ms
  );
  double _offset = 0;
  double _animFrom = 0;
  double _animTo = 0;

  @override
  void initState() {
    super.initState();
    _tracker = PullTracker(
      threshold: widget.threshold,
      canPull: () =>
          !widget.disabled && (widget.isAtTop?.call() ?? true),
      onOffsetChange: (double o) {
        setState(() {
          _offset = o;
          if (_status == PullStatus.idle) _status = PullStatus.pulling;
        });
      },
      onPullEnd: (bool shouldRefresh) {
        if (shouldRefresh) {
          _doRefresh();
        } else {
          _reset();
        }
      },
      onPullCancel: _reset,
    );
    _anim.addListener(() {
      setState(() {
        _offset = _animFrom + (_animTo - _animFrom) * _anim.value;
      });
    });
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  /// 动画到目标位移（reduced-motion 直接置位）。
  void _animateTo(double target) {
    if (MediaQuery.of(context).disableAnimations) {
      setState(() => _offset = target);
      return;
    }
    _animFrom = _offset;
    _animTo = target;
    _anim.forward(from: 0);
  }

  void _reset() {
    _animateTo(0);
    setState(() => _status = PullStatus.idle);
  }

  Future<void> _doRefresh() async {
    if (_refreshing) return;
    _refreshing = true;
    setState(() => _status = PullStatus.refreshing);
    _animateTo(AylaPullToRefresh.refreshOffset);
    // 注意：`return` 不能写在 finally 里（会吞掉异常）；用 try/catch + 收尾分离
    Object? error;
    try {
      await widget.onRefresh();
    } catch (e) {
      error = e;
    }
    _refreshing = false;
    if (!mounted) {
      if (error != null) throw error;
      return;
    }
    setState(() => _status = PullStatus.done);
    if (MediaQuery.of(context).disableAnimations) {
      setState(() {
        _offset = 0;
        _status = PullStatus.idle;
      });
    } else {
      // done 短暂停留后收起（让用户看到反馈）
      Future<void>.delayed(const Duration(milliseconds: 300), () {
        if (!mounted) return;
        _animateTo(0);
        setState(() => _status = PullStatus.idle);
      });
    }
    // 刷新失败必须向上传播（不伪造成功）；UI 已复位后重新抛出
    if (error != null) throw error;
  }

  @override
  Widget build(BuildContext context) {
    final bool showIndicator = _status != PullStatus.idle;

    return Listener(
      // 触摸手势（对应 tsx 的 onTouchStart/Move/End/Cancel）
      onPointerDown: (PointerDownEvent e) {
        if (_refreshing) return;
        _tracker.start(e.position.dy);
      },
      onPointerMove: (PointerMoveEvent e) => _tracker.move(e.position.dy),
      onPointerUp: (PointerUpEvent e) => _tracker.end(e.position.dy),
      onPointerCancel: (_) => _tracker.cancel(),
      child: Stack(
        children: <Widget>[
          // 内容（随下拉位移；`.pull-refresh-content { position:relative }`）
          Positioned.fill(
            child: Transform.translate(
              offset: Offset(0, _offset),
              child: widget.child,
            ),
          ),
          // 指示器（绝对定位于顶部，随下拉滑入；idle 时 opacity 0）
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: AylaPullToRefresh.indicatorSpace, // height: 52px
            child: IgnorePointer(
              child: AnimatedOpacity(
                // transition: opacity 150ms var(--ease-out)
                duration: MediaQuery.of(context).disableAnimations
                    ? Duration.zero
                    : const Duration(milliseconds: 150),
                curve: AylaCurves.easeOut,
                // 注意：必须写 1.0/0.0 —— 条件表达式的 int 不会自动提升为 double
                opacity: showIndicator ? 1.0 : 0.0, // .is-* → opacity:1
                child: Center(
                  child: _RefreshDot(status: _status),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `.pull-refresh-dot` —— 36×36 玻璃圆点；内含 arrow / spinner / check 三态。
class _RefreshDot extends StatelessWidget {
  const _RefreshDot({required this.status});

  final PullStatus status;

  @override
  Widget build(BuildContext context) {
    final BorderRadius r = BorderRadius.circular(18); // border-radius: 50%
    final bool opaque = GlassConfig.useOpaqueFallback;

    Widget face = Container(
      width: 36, // width: 36px
      height: 36, // height: 36px
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: GlassConfig.resolveBackground(strong: true), // --glass-bg-strong
        borderRadius: r,
        border: Border.all(color: AylaColors.glassBorder), // 1px --glass-border
      ),
      child: switch (status) {
        // refreshing → spinner（loading-spinner--md = 18px）
        PullStatus.refreshing => const LoadingSpinner(size: 18),
        // done → 对勾（`--success`）
        PullStatus.done => Icon(
            Icons.check,
            size: 16,
            color: AylaColors.success, // color: var(--success)
          ),
        // idle / pulling → 下箭头（--indigo-700）
        _ => Icon(
            Icons.keyboard_arrow_down,
            size: 14,
            color: AylaColors.indigo700, // color: var(--indigo-700)
          ),
      },
    );

    // blur(18px) saturate(1.4) + --card-shadow（不参与裁剪）
    Widget layered = face;
    if (!opaque) {
      layered = Stack(
        children: <Widget>[
          Positioned.fill(
            child: ClipRRect(
              borderRadius: r,
              child: BackdropFilter(
                filter: GlassConfig.backdropFilter(sigma: AylaGlass.blurNav),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          face,
        ],
      );
    }
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        // --card-shadow（不含 --glass-inset，见 tokens.css 75）
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: r,
              boxShadow: AylaShadows.card,
            ),
          ),
        ),
        layered,
      ],
    );
  }
}

// ======================= 预览 =======================

/// PullToRefresh（静止态；下拉/刷新/完成三态需实时手势，见 widget test）。
@Preview(
  group: 'Widgets',
  name: 'PullToRefresh（idle 玻璃圆点 + 列表）',
  size: Size(420, 460),
  wrapper: previewTheme,
)
Widget previewPullToRefresh() {
  return SizedBox(
    width: 375,
    height: 420,
    child: AylaPullToRefresh(
      isAtTop: () => true,
      onRefresh: () async {
        await Future<void>.delayed(const Duration(milliseconds: 600));
      },
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AylaSpacing.sp3),
        children: <Widget>[
          for (int i = 0; i < 8; i++)
            Container(
              margin: const EdgeInsets.only(bottom: AylaSpacing.sp2),
              height: 56,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp3),
              decoration: BoxDecoration(
                color: AylaColors.glassBg,
                borderRadius: BorderRadius.circular(AylaRadii.rInput),
                border: Border.all(color: AylaColors.glassBorder),
              ),
              child: Text('列表项 ${i + 1}（下拉可刷新）'),
            ),
        ],
      ),
    ),
  );
}

/// 指示器三态对照（idle 箭头 / refreshing spinner / done 对勾）。
@Preview(
  group: 'Widgets',
  name: 'PullToRefresh 指示器三态（36 玻璃圆点）',
  size: Size(420, 160),
  wrapper: previewTheme,
)
Widget previewRefreshDotStates() {
  Widget cell(String label, PullStatus s) => Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 直接复用指示器本体（_RefreshDot 是私有类，用 AylaPullToRefresh 的
          // 状态无法静态摆出三态 → 这里用同规格自绘对照）
          _RefreshDotPreview(status: s),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      );

  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp4),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: <Widget>[
        cell('idle / pulling → 箭头', PullStatus.idle),
        cell('refreshing → spinner', PullStatus.refreshing),
        cell('done → 对勾', PullStatus.done),
      ],
    ),
  );
}

/// 指示器预览替身（与 `_RefreshDot` 同规格；私有类无法直接引用）。
class _RefreshDotPreview extends StatelessWidget {
  const _RefreshDotPreview({required this.status});

  final PullStatus status;

  @override
  Widget build(BuildContext context) {
    final BorderRadius r = BorderRadius.circular(18);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: GlassConfig.resolveBackground(strong: true),
        borderRadius: r,
        border: Border.all(color: AylaColors.glassBorder),
        boxShadow: AylaShadows.card,
      ),
      child: SizedBox(
        width: 36,
        height: 36,
        child: Center(
          child: switch (status) {
            PullStatus.refreshing => const LoadingSpinner(size: 18),
            PullStatus.done =>
              const Icon(Icons.check, size: 16, color: AylaColors.success),
            _ => const Icon(Icons.keyboard_arrow_down,
                size: 14, color: AylaColors.indigo700),
          },
        ),
      ),
    );
  }
}

/// SignedVideo 三态（loading / failed / ready；真实播放属媒体批次）。
@Preview(
  group: 'Widgets',
  name: 'SignedVideo（loading/failed/ready 契约态）',
  size: Size(720, 260),
  wrapper: previewTheme,
)
Widget previewSignedVideo() {
  Widget cell(String label, Widget child) => SizedBox(
        width: 220,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            child,
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
        // 未注入 client → 失败态（这也是当前默认，签名链路需 app 启动时 attach）
        cell('failed（点击重试）', const SignedVideo(mediaId: 'demo-1')),
        const SizedBox(width: AylaSpacing.sp4),
        cell(
          'controls=true（详情页内联）',
          const SignedVideo(mediaId: 'demo-2', controls: true),
        ),
        const SizedBox(width: AylaSpacing.sp4),
        cell(
          '4:3 卡片预览（muted）',
          const SignedVideo(mediaId: 'demo-3', aspectRatio: 4 / 3),
        ),
      ],
    ),
  );
}
