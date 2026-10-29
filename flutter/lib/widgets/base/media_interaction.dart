/// 视频与滚动交互族（`AylaSignedVideo.tsx` / `PullToRefresh.tsx` /
/// `overlay/OverlayScrollbar.tsx`）。
///
/// 三者都是**交互/媒体**类组件，事实源见各段落注释。
///
/// ## 公开面
/// `AylaSignedVideo` · `AylaPullStatus` · `AylaPullTracker` · `AylaPullToRefresh` · `AylaRefreshDot`

library;

import 'dart:async';
import 'dart:io' show File;
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/media/media_cache.dart';
import '../../core/media/media_download_queue.dart';
import '../../core/media/media_signer.dart';
import '../../player/vod_player.dart' show AylaVodVideo;
import '../../core/models/media_kind.dart';
import '../../theme/glass.dart';
import '../../theme/svg_path.dart';
import '../../theme/tokens.dart';
import 'fit_content.dart' show AylaInlineNaturalSize;
import 'loading.dart';

// ======================= AylaSignedVideo =======================

/// 签名 URL 直连的视频（`AylaSignedVideo.tsx`）。
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
class AylaSignedVideo extends StatefulWidget {
  const AylaSignedVideo({
    super.key,
    required this.mediaId,
    this.controls = false,
    this.ariaLabel,
    this.aspectRatio = 16 / 9,
    this.cacheable = false,
    this.mimeType,
  });

  /// 媒体 MIME（可选，决定落盘扩展名；视频通常是 `video/mp4`）。
  final String? mimeType;

  /// 媒体 id（用于签发 original 视频 URL）。
  final String mediaId;

  /// 是否显示控制条（详情页 true；卡片首帧预览 false）。
  final bool controls;

  /// 无障碍标签。
  final String? ariaLabel;

  /// 占位宽高比（视频未就绪时）。
  final double aspectRatio;

  /// 组件挂载后是否**落盘视频本体**（默认 **false**）。
  ///
  /// **用户裁决 2026-10-23**：「视频改成『点击播放才存』」。
  /// 本件的 initState 就签 original 并挂播放器 => 它被创建即等于「用户要看/要播」：
  /// - **查看器里播放**（image_viewer.dart 的 _ViewerVideo）=> 传 true：
  ///   用户已经点开大图要看了，落盘合理（下次直接本地播放，云端过期也能看）。
  /// - **列表/卡片里的首帧预览**（post_card.dart 的 AylaPostVideoCover 降级分支）
  ///   => 保持默认 false：那只是「在信息流里看一眼封面」，不是播放意图。
  ///
  /// 注意：真正的「视频本体不因进视口而落盘」靠的是**气泡内不再自动
  /// fetchAndStore**（media_content.dart 的 _VideoFrameState）；
  /// 本开关只决定「播放器被创建时要不要顺手落盘」。
  final bool cacheable;

  @override
  State<AylaSignedVideo> createState() => _SignedVideoState();
}

enum _VideoState { loading, ready, failed }

class _SignedVideoState extends State<AylaSignedVideo> {
  _VideoState _state = _VideoState.loading;
  String? _src;

  @override
  void initState() {
    super.initState();
    _sign();
  }

  @override
  void didUpdateWidget(covariant AylaSignedVideo old) {
    super.didUpdateWidget(old);
    if (old.mediaId != widget.mediaId) _sign();
  }

  Future<void> _sign() async {
    setState(() {
      _state = _VideoState.loading;
      _src = null;
    });
    try {
      // ⓪ 本地漫游缓存优先（用户目标 §5：「如果资产未过期但已保存，也要走本地
      //    文件查看，省流」）。命中则**连签名都不发**，云端过期也不影响播放。
      //
      // ⚠️ 只在缓存布局**已解析**时查询：
      //   · 生产：`main.dart` 启动即 `unawaited(ensureReady())`，首帧前通常已就绪；
      //   · widget 测试：没有 path_provider 平台实现，`ensureReady()` 的 Future
      //     永远不会完成 —— 若无条件 await，状态机会**永久停在 loading**，
      //     失败/重试分支全部不可达（2026-10-29 实测踩到）。
      //   跳过只影响「冷启动后第一条视频」是否走本地，后续均命中缓存。
      if (AylaMediaCache.instance.layout != null) {
        final File? cached = await AylaMediaCache.instance.lookup(
          widget.mediaId,
          kind: AylaMediaKind.video,
        );
        if (!mounted) return;
        if (cached != null) {
          setState(() {
            _src = cached.path; // 本地文件路径，不带 `#t=0.1` 片段
            _state = _VideoState.ready;
          });
          return;
        }
      }
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
      // 落盘视频本体（**用户裁决 2026-10-23**：视频「点击播放才存」）。
      //
      // [cacheable] 只有「用户已点开查看器要播」的调用点才传 true（见字段文档）；
      // 列表里的首帧预览保持 false —— 那只是看一眼封面，不是播放意图。
      //
      // 不 await、不提示：缓存是增强项，失败不影响播放。
      if (widget.cacheable && !r.originalExpired) {
        // 走**持久下载队列**（2026-10-29 用户拍板）：视频本体 7 天就过期，
        // 用户点开查看器即视为「要留一份」，失败最多重试 3 次、被杀后启动续跑。
        unawaited(
          AylaMediaDownloadQueue.instance
              .enqueue(
                mediaId: widget.mediaId,
                kind: AylaMediaKind.video,
                mimeType: widget.mimeType,
              )
              .catchError((Object _) {}),
        );
      }
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

  /// 真实播放器（2026-10-29 接通）。
  ///
  /// 此前这里是**占位实现**（只渲染一行「视频源已签发」文案），导致：
  /// · 查看器里的视频根本播不了；
  /// · 「点开视频自动存视频」的落盘点挂在 [AylaSignedVideo.cacheable] 上，
  ///   而它从不播放 ⇒ 用户看不到任何反馈，等同于功能缺失。
  ///
  /// 现改为复用库内既有播放面 [AylaVodVideo]（Windows = media_kit/mpv，
  /// Android/iOS = video_player），**不另造第二条视频路径**。
  ///
  /// 播放源：本地漫游缓存命中优先（见 [_sign] 的 [_localFile]）；否则用签名 URL。
  Widget _buildPlayer(String src) {
    return AspectRatio(
      aspectRatio: widget.aspectRatio,
      // `#t=0.1` 只对 <video> 元素生效（跳过首帧黑场），本地文件路径不要带
      // 片段标识符，否则部分内核会解析失败。
      child: AylaVodVideo(
        key: ValueKey<String>(src),
        src: src,
        controls: widget.controls,
        autoPlay: widget.controls,
        muted: !widget.controls,
        fit: BoxFit.contain,
        semanticLabel: widget.ariaLabel,
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
        // 重试键在 web 是 <button>（ResourceImage.tsx:156 同族）⇒ base.css:340 全局 pointer。
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
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
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 11,
                color: AylaColors.textSecondary,
              ),
            ),
          ),
          ),
        ),
      ),
    );
  }
}

// ======================= PullToRefresh =======================

/// 下拉刷新状态（`AylaPullStatus`）。
enum AylaPullStatus { idle, pulling, refreshing, done }

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
class AylaPullTracker {
  AylaPullTracker({
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
  late final AylaPullTracker _tracker;
  AylaPullStatus _status = AylaPullStatus.idle;
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
    _tracker = AylaPullTracker(
      threshold: widget.threshold,
      canPull: () =>
          !widget.disabled && (widget.isAtTop?.call() ?? true),
      onOffsetChange: (double o) {
        setState(() {
          _offset = o;
          if (_status == AylaPullStatus.idle) _status = AylaPullStatus.pulling;
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
    setState(() => _status = AylaPullStatus.idle);
  }

  Future<void> _doRefresh() async {
    if (_refreshing) return;
    _refreshing = true;
    setState(() => _status = AylaPullStatus.refreshing);
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
    setState(() => _status = AylaPullStatus.done);
    if (MediaQuery.of(context).disableAnimations) {
      setState(() {
        _offset = 0;
        _status = AylaPullStatus.idle;
      });
    } else {
      // done 短暂停留后收起（让用户看到反馈）
      Future<void>.delayed(const Duration(milliseconds: 300), () {
        if (!mounted) return;
        _animateTo(0);
        setState(() => _status = AylaPullStatus.idle);
      });
    }
    // 刷新失败必须向上传播（不伪造成功）；UI 已复位后重新抛出
    if (error != null) throw error;
  }

  @override
  Widget build(BuildContext context) {
    final bool showIndicator = _status != AylaPullStatus.idle;

    return Listener(
      // 触摸手势（对应 tsx 的 onTouchStart/Move/End/Cancel）
      //
      // web `.pull-to-refresh` 是普通块级 `<div>`：`pointer-events` 默认 auto ⇒
      // 命中区 = **整个盒子矩形**（含内容未覆盖的透明处，tsx 256–259 的事件就挂在它上面）。
      // Flutter 的 `deferToChild`（默认）把命中缩到内容实际覆盖处 ⇒ 显式 `opaque`
      // 复刻同一命中矩形（内容比盒子窄时仍可下拉，与 web 一致）。
      behavior: HitTestBehavior.opaque,
      onPointerDown: (PointerDownEvent e) {
        if (_refreshing) return;
        _tracker.start(e.position.dy);
      },
      onPointerMove: (PointerMoveEvent e) => _tracker.move(e.position.dy),
      onPointerUp: (PointerUpEvent e) => _tracker.end(e.position.dy),
      onPointerCancel: (_) => _tracker.cancel(),
      child: Stack(
        // `.pull-to-refresh`（app.css:4010–4013）**没有 overflow 声明** ⇒ 下拉/位移期间
        // 内容与指示器溢出照常绘制（同文件 4019–4021 注释：「不依赖滚动容器 overflow
        // 裁剪」，可见性由状态类 + opacity 控制）⇒ Flutter 的 Stack 默认
        // `Clip.hardEdge` 必须显式关掉才与 web 一致。
        clipBehavior: Clip.none,
        // 尺寸来源回到 web 语义：`.pull-refresh-content { position: relative }`
        // （app.css:4015–4017）**在流内** ⇒ 容器尺寸由内容决定；只有指示器是 absolute
        // （4022–4035）不参与尺寸。Flutter 等价 = 内容必须是 Stack 的**非 Positioned
        // 子级**（JSX 253–279 的顺序同样是 indicator 在前、content 在后）。
        // ⚠️ 事故（2026-09-29 P0）：此前内容也写成 `Positioned.fill` ⇒ 两个直接子级
        // 全是 Positioned ⇒ `RenderStack` 取 `constraints.biggest`；而六个目录页都把
        // 本件放进 `SingleChildScrollView`（滚动视口给子级的主轴高度无界）⇒
        // `'size.isFinite'` 断言 ⇒ 布局中断 ⇒ 帖子/直播/语音/桌游四厅 + 收藏 + 搜索
        // 的内容区全空（render tree 大片 NEEDS-LAYOUT）。
        // `loose`（默认，显式写出）：Stack 只做尺寸容器，约束交给下面的块级子级决定。
        fit: StackFit.loose,
        children: <Widget>[
          // 内容（在流内，承担容器尺寸；随下拉位移；`.pull-refresh-content`）。
          //
          // ## 宽度语义（2026-10-20 订正 —— 上一版注释写错了）
          //
          // ⚠️ **订正**：上一版此处写「`Align(widthFactor: null, heightFactor: 1.0)` =
          // 块级子元素的 Flutter 等价：**宽度撑满父可用宽**」—— **实测不成立**。
          // 源码依据：`Align` → `RenderPositionedBox._layoutChild` 只把约束**透传并放宽**
          // 给子级（`child!.layout(constraints.loosen(), parentUsesSize: true)`），
          // 自身尺寸走 `constraints.constrain(Size(
          //   shrinkWrapWidth ? child.width * widthFactor : double.infinity, …))`，
          // 而 `shrinkWrapWidth = _widthFactor != null || constraints.maxWidth == Infinity`
          // （`flutter/lib/src/rendering/shifted_box.dart:461–473`）。
          // ⇒ 父宽**有界**且 `widthFactor: null` 时，**Align 自身**撑满父宽，但子级拿到的
          // 是 `loosen()`（`minWidth: 0`）⇒ 内容若不自撑就**只占内容宽并贴左**。
          // 真发现场（400 宽视口 / 群内帖子空态）：占位壳宽 245.8、标题中心 x=138.875，
          // 而屏幕中心是 200 —— 用户实报「群内无帖子左右不居中」。
          // web 无此问题：`.pull-refresh-content { position: relative }`
          // （app.css:4015–4017）是**块级 div**，`width: auto` 在块级格式化上下文里吃掉
          // 父宽（CSS 2.1 §10.3.3），子级拿到的不是 `loosen()`。
          //
          // ⇒ 正确的 Flutter 等价 = `AylaInlineNaturalSize`
          // （`widgets/base/fit_content.dart`，即 CSS 块级 `width:auto` / `flex:1` 的两趟语义）：
          //   · 宽度**有界** ⇒ **tight** 宽 = `constraints.maxWidth`（块级 fill-available）；
          //   · 宽度**无界**（横向滚动容器内）⇒ 用无界主轴布局一次、取子级自然宽
          //     （= CSS intrinsic 趟的 max-content；不会把 `infinity` 传给子级）。
          //
          // 外层 `Align(heightFactor: 1.0)` **保留**：它给出「高度由内容决定」的语义
          // （`shrinkWrapHeight = heightFactor != null` ⇒ 高度取子级自然高，绝不落
          // `constraints.biggest`）—— 这是 2026-09-29 P0（滚动视口内 `size.isFinite`
          // 断言 ⇒ 六个目录页内容区全空）的修复，**不可回退**。
          Align(
            alignment: Alignment.topLeft,
            heightFactor: 1.0,
            child: Transform.translate(
              offset: Offset(0, _offset),
              // 块级宽度语义（有界撑满 / 无界取自然宽）；高度方向原样透传约束。
              child: AylaInlineNaturalSize(child: widget.child),
            ),
          ),
          // 指示器（绝对定位覆盖层，不参与尺寸；随下拉滑入；idle 时 opacity 0）
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
                  child: AylaRefreshDot(status: _status),
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
class AylaRefreshDot extends StatelessWidget {
  const AylaRefreshDot({super.key, required this.status});

  final AylaPullStatus status;

  @override
  Widget build(BuildContext context) {
    final BorderRadius r = BorderRadius.circular(18); // border-radius: 50%
    final bool opaque = AylaGlassConfig.useOpaqueFallback;

    Widget face = Container(
      width: 36, // width: 36px
      height: 36, // height: 36px
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AylaGlassConfig.resolveBackground(strong: true), // --glass-bg-strong
        borderRadius: r,
        border: Border.all(color: AylaColors.glassBorder), // 1px --glass-border
      ),
      child: switch (status) {
        // refreshing → spinner（loading-spinner--md = 18px）
        AylaPullStatus.refreshing => const AylaLoadingSpinner(size: 18),
        // done → 对勾（web 内联 `<svg viewBox="0 0 16 16">`：`M3 8.5l3.2 3.2L13 5`，stroke 2 / round）
        AylaPullStatus.done => const AylaSvgGlyph(
            d: 'M3 8.5l3.2 3.2L13 5',
            size: 16,
            viewBox: 16,
            color: AylaColors.success, // color: var(--success)
          ),
        // idle / pulling → 下箭头（web 内联：`M3.5 6l4.5 4.5L12.5 6`，14×14 / stroke 2 / round）
        _ => const AylaSvgGlyph(
            d: 'M3.5 6l4.5 4.5L12.5 6',
            size: 14,
            viewBox: 16,
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
            // 背后内容层统一走 AylaGlassBackdrop（质量档 owner，§8.17）。
            child: AylaGlassBackdrop(
              radius: r,
              filter: AylaGlassConfig.backdropFilter(sigma: AylaGlass.blurNav),
            ),
          ),
          face,
        ],
      );
    }
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        // --card-shadow（不含 --glass-inset，见 tokens.css 75）——只画形状之外
        // （2026-09-20 审查 R2：裸 boxShadow 会染进 .78 玻璃内部）
        Positioned.fill(
          child: IgnorePointer(
            child: AylaGlassShadow.ring(radius: r, shadows: AylaShadows.card),
          ),
        ),
        layered,
      ],
    );
  }
}

// ======================= 样张 =======================
