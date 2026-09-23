/// live 域第一批（B2-1）：弹幕族 —— 列表 / 输入 / 画面飘弹幕层。
///
/// ## 事实源（逐条对应 web，禁自由发挥）
/// ```
/// components/live/DanmakuList.tsx     25–85 行条目 / 87–139 列表 + 空态 + 新弹幕提示 + 查看器
/// components/live/DanmakuInput.tsx    1–180（草稿 revision 守卫 / 上传 / 重试 / 计数 / 状态行）
/// components/live/DanmakuOverlay.tsx  1–213（基线只飘新弹幕 / 轨道 / 上限 / 关键帧）
/// components/live/danmakuTracks.ts    12–55 → 本库 danmaku_tracks.dart（纯函数 1:1）
/// app.css 3671–3762   .danmaku-wrap/-list/-empty/-item/-sender/-content/-image-open/
///                     -image-skeleton/-image/-new-hint（**全库唯一命中**，不在任何 @media 内）
/// app.css 3764–3827   .danmaku-input-area/-input-row/-image-btn/-input-status/-input/-input-meta/-counter
/// app.css 21–67 / 1324–1366 / 3473–3477   .btn 族 / .msg-action-btn / .live-form-error
/// auroraqua.css 54–94 · 96–102 · 134–139 · 142–166   按钮组：200ms + hover 1.02 + active .98 + 扫光 600ms
/// auroraqua.css 347–359 · 378–383 · 390（**≥769**）  .danmaku-input-area 浮动卡 / .danmaku-image-btn 材质
/// auroraqua.css 502–523（顶层）                      .danmaku-input 字段族材质 + focus 转辉光边
/// auroraqua.css 555–567 · 569–581                    studio side 内透明档
/// live.css 756–764 · 830–838                         滑动单元内 .danmaku-wrap 材质 / ≤768 透明覆盖
/// live.css 768–772 · 777–784                         窄屏输入卡底 / min-width 0 / 图片钮 40 / 发送钮 min-width 72
/// live.css 860–930 · 1006–1018                       飘弹幕层 / 头像 / 图片 / 关键帧
/// base.css 333–346 · 564–578                         button 重置（字体继承）/ .skeleton
/// ```
///
/// ## 与 web 的装配差异（组件不写页面）
/// web 三个组件各自直连 `useLiveStore` / `useAuthStore` / `matchMedia` /
/// `ResizeObserver` / `uploadMediaFile`；Flutter 侧按库内既有「展示型 + 注入」：
/// - 弹幕数据、在线态、历史分页由页面装进 [AylaDanmakuEntry] / [AylaHistoryControlsData]；
/// - 图片三层（选文件 / 上传 / 发送）由 [AylaDanmakuInput] 的三个回调注入
///   （`AylaMediaActions.pickImage` / `.uploadImage` 即一行实现）——
///   组件持有 attempt（文件 + mediaId），重试语义与 web 一致；
/// - 弹幕列表的 listRef（web 用于跳底）→ 页面注入 `ScrollController`。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter, TextInputFormatter;
import 'package:flutter/widget_previews.dart';

import '../core/models/media_kind.dart';
import '../core/models/post.dart' show AylaMediaDescriptor;
import '../core/media/media_picker.dart' show AylaPickedFile;
import '../core/media/media_signer.dart';
import '../core/media/media_upload.dart' show AylaUploadException;
import '../core/net/dio_client.dart' show ApiException;
import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/buttons.dart';
import '../theme/css_gradient.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/sample_media.dart' show aylaEnableSampleMedia;
import '../theme/tokens.dart';
import 'avatar_halo.dart';
import 'danmaku_tracks.dart';
import 'directory_controls.dart';
import 'image_viewer.dart';
import 'loading.dart';
import 'overlays.dart';
import 'resource_image.dart';

// ======================= 数据投影 =======================

/// 一条弹幕（web `DanmakuItem`：`api/types.ts` 1088–1099 的投影）。
///
/// 只带三个组件真正读取的字段：身份（id）/ 发送者（昵称、头像、id）/ 内容 /
/// 媒体。在线态是 **Presence 运行事实**（web `presenceOnline(...)`，页面层从
/// presence store 计算后注入），不由组件推断。
class AylaDanmakuEntry {
  const AylaDanmakuEntry({
    required this.id,
    required this.senderNickname,
    this.senderUserId = '',
    this.senderAvatarUrl = '',
    this.senderOnline = false,
    this.content = '',
    this.mediaId,
    this.media,
  });

  /// 弹幕 id（全局唯一，可作 key）。
  final String id;

  /// 发送者昵称（列表行与 `：` 前缀）。
  final String senderNickname;

  /// 发送者 user_id（点头像跳个人主页用）。
  final String senderUserId;

  /// 发送者头像 URL（空串 = 无头像）。
  final String senderAvatarUrl;

  /// 是否在线（页面注入的运行事实；隐身用户由页面强制离线）。
  final bool senderOnline;

  /// 文本内容（媒体弹幕的后端占位文案是「图片」）。
  final String content;

  /// 媒体 id（媒体弹幕必有）。
  final String? mediaId;

  /// 媒体描述（缩略图路径等）。
  final AylaMediaDescriptor? media;
}

/// `resolveMediaPath`（web `api/media.ts` 192–196）：只接受后端媒体路径前缀，
/// 其余（外部 URL / 非法路径）一律 null。
String? aylaResolveMediaPath(String? path) =>
    (path != null && path.startsWith(kMediaPathPrefix)) ? path : null;

/// 列表图源 = `resolveMediaPath(media.thumbnail) ?? mediaContentUrl(media_id)`
/// （tsx 73）。
String? _listImageSrc(AylaDanmakuEntry item) {
  final String? path = aylaResolveMediaPath(item.media?.thumbnail);
  if (path != null) return path;
  final String? id = item.mediaId;
  return id == null ? null : mediaContentUrl(id);
}

/// 飘弹幕**只飘缩略图**（tsx 68–71）：无缩略图整条不飘。
String? _thumbSrc(AylaDanmakuEntry item) =>
    aylaResolveMediaPath(item.media?.thumbnail);

/// 媒体弹幕在列表里的 alt（tsx 67）：`item.content || "弹幕图片"`。
String _mediaAlt(AylaDanmakuEntry item) =>
    item.content.isEmpty ? '弹幕图片' : item.content;

// ======================= 弹幕图片查看器宿主 =======================

/// 弹幕图片的查看器宿主。
///
/// web 把 `<ImageViewer>` 直接渲染在组件内，而它是 `position: fixed; inset: 0`
/// （app.css 1459+）⇒ **全屏且不被祖先 `overflow: hidden` 裁剪**。
/// Flutter 没有 portal，组件又常被嵌进播放器/列表卡内：直接渲染会被宿主裁掉
/// ⇒ 一律插到 **root Overlay**（库内统一入口 [aylaOverlayEntry]，理由同
/// `widgets/overlays.dart` 的文本作用域）。
class _DanmakuViewerHost {
  OverlayEntry? _entry;

  /// 打开查看器（重复打开先关旧的）。
  void open(BuildContext context, AylaMediaDescriptor media, String alt) {
    close();
    final OverlayEntry entry = aylaOverlayEntry(
      builder: (BuildContext ctx) => AylaImageViewer(
        media: media,
        alt: alt,
        onClose: close,
      ),
    );
    _entry = entry;
    // 库内统一写法（conversation_more_menu / server_rail）：root overlay 直插
    Overlay.of(context, rootOverlay: true).insert(entry);
  }

  /// 关闭（幂等）。
  void close() {
    _entry?.remove();
    _entry = null;
  }
}

// ======================= 弹幕列表 =======================

/// 弹幕列表（`DanmakuList.tsx` 139 行）。
///
/// 结构 = `.danmaku-wrap`（此组件根）→ `.danmaku-list`（滚动容器 = 历史控件 +
/// 条目 + 空态）→ `.danmaku-new-hint`（绝对定位浮层，`bottom: sp3` 水平居中）。
/// 图片点击打开全屏查看器（见 [_DanmakuViewerHost]）。
///
/// ## 材质：**组件自身永远不持材质**（用户 2026-09-22 裁决「就是卡片而已」）
///
/// 事实链（已逐条回读）：
/// - `.danmaku-wrap` 自身只有布局（app.css 3671–3676：`position: relative` /
///   `flex: 1` / `min-height: 0` / `display: flex`）——**无底、无边、无模糊**；
/// - 唯一给它材质的规则是 live.css 756–764（`.live-room-swipe-item .danmaku-wrap`：
///   `border-top` + `--glass-bg-strong` + blur18 sat1.4 + `radius 0 0 12 12`），
///   而 **`.live-room-swipe-item` 只在窄屏分支渲染**（`LiveRoomBody.tsx` 441/468），
///   紧接着 live.css **818–839 的 `@media (max-width: 768px)` 又把同一元素的
///   `border-top` / `background` / `backdrop-filter` / `border-radius` 全部清零**
///   ⇒ 那条玻璃规则**没有任何渲染面**（此前我按它造过一档，是造轮子，已删）；
/// - 宽屏（含开播控制台）弹幕列表在 `<aside className="live-room-side">` 里
///   （tsx 531–534）⇒ **材质归那张卡片**（auroraqua.css 392–400：`margin 12` /
///   1px 边 / `radius 16` / `--glass-shadow` / blur24 sat1.4）。
///
/// 所以 Flutter 侧：窄屏把本组件裸放（`minHeight: 96` 见 [minHeight]），
/// 宽屏由调用方用**库内卡片件**（`GlassCard` / `GlassSurface`）包一层 —— 别自己拼材质。
class AylaDanmakuList extends StatefulWidget {
  const AylaDanmakuList({
    super.key,
    required this.items,
    this.minHeight,
    this.controller,
    this.hasNewBelow = false,
    this.onScrollToBottom,
    this.onUserScroll,
    this.history,
    this.onOpenSenderProfile,
  });

  /// 可见窗口内的弹幕（web `useDanmaku` 的有界历史窗口）。
  final List<AylaDanmakuEntry> items;

  /// 最小高度（live.css 758/830 共有的 `min-height: 96px`：窄屏滑动单元里
  /// 「群内被压缩保直播完整、群外贴满视频下方」）；null = 不约束。
  ///
  /// `flex: 1` 由调用方 `Expanded` 表达（web 的 `.danmaku-wrap { flex: 1 }`）。
  final double? minHeight;

  /// 页面持有的滚动控制器（web `listRef` 的等价物：自动滚底 / 跳底由页面做）。
  final ScrollController? controller;

  /// 有未读新弹幕（用户上翻时）→ 显示「有新弹幕 ↓」。
  final bool hasNewBelow;

  /// 点「有新弹幕 ↓」。
  final VoidCallback? onScrollToBottom;

  /// 滚动上报（web `onScroll={onUserScroll}`：由元素自身上报，勿在页面自挂监听）。
  final VoidCallback? onUserScroll;

  /// 历史分页投影（null = 不渲染历史控件，对应 web 的可选 `history`）。
  final AylaHistoryControlsData? history;

  /// 点发送者头像（web `goUserProfile(null, user_id)`；null = 头像不可点）。
  final ValueChanged<String>? onOpenSenderProfile;

  @override
  State<AylaDanmakuList> createState() => _AylaDanmakuListState();
}

class _AylaDanmakuListState extends State<AylaDanmakuList> {
  final _DanmakuViewerHost _viewer = _DanmakuViewerHost();

  @override
  void dispose() {
    _viewer.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget list = SingleChildScrollView(
      controller: widget.controller,
      // `.danmaku-list { padding: var(--sp-3) }`
      padding: const EdgeInsets.all(AylaSpacing.sp3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, // flex column 的 stretch
        spacing: AylaSpacing.sp2, // gap: var(--sp-2)
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (widget.history case final AylaHistoryControlsData history)
            history.toControls(),
          if (widget.items.isEmpty)
            const _DanmakuEmpty()
          else
            for (final AylaDanmakuEntry item in widget.items)
              _DanmakuRow(
                key: ValueKey<String>(item.id), // tsx 51 `data-history-id`
                item: item,
                onOpenSenderProfile: widget.onOpenSenderProfile,
                onOpenImage: _openImage,
              ),
        ],
      ),
    );

    final Widget wrap = Stack(
      children: <Widget>[
        Positioned.fill(
          child: NotificationListener<ScrollNotification>(
            onNotification: (ScrollNotification notification) {
              // web 的 scroll 事件对「用户滚动」与「程序滚动」都触发 ⇒ 这里不做来源区分
              widget.onUserScroll?.call();
              return false;
            },
            child: list,
          ),
        ),
        if (widget.hasNewBelow)
          Positioned(
            left: 0,
            right: 0,
            bottom: AylaSpacing.sp3, // bottom: var(--sp-3)
            child: Center(child: _NewDanmakuHint(onTap: widget.onScrollToBottom)),
          ),
      ],
    );

    // 组件根**不持材质**（见类注释）：只有布局；`min-height: 96` 由调用方按上下文给。
    final double? minHeight = widget.minHeight;
    if (minHeight == null) return wrap;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: wrap,
    );
  }

  void _openImage(AylaMediaDescriptor media, String alt) {
    _viewer.open(context, media, alt);
  }
}

/// `.danmaku-empty`（app.css 3687–3692 + tsx 110）。
class _DanmakuEmpty extends StatelessWidget {
  const _DanmakuEmpty();

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AylaSpacing.sp6),
      child: Text(
        '还没有弹幕，来说点什么吧',
        textAlign: TextAlign.center,
        style: t.body.copyWith(
          fontSize: 13,
          color: AylaColors.textSecondary,
        ),
      ),
    );
  }
}

/// 一条弹幕行（`.danmaku-item`，app.css 3694–3701）。
class _DanmakuRow extends StatelessWidget {
  const _DanmakuRow({
    super.key,
    required this.item,
    required this.onOpenSenderProfile,
    required this.onOpenImage,
  });

  final AylaDanmakuEntry item;
  final ValueChanged<String>? onOpenSenderProfile;
  final void Function(AylaMediaDescriptor media, String alt) onOpenImage;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool hasMedia = item.mediaId != null && item.media != null;
    // tsx 81：后端用「图片」当媒体弹幕的占位文案，渲染时不再重复
    final bool showText = item.content.isNotEmpty && item.content != '图片';
    final String? imageSrc = hasMedia ? _listImageSrc(item) : null;
    final ValueChanged<String>? openProfile = onOpenSenderProfile;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start, // align-items: flex-start
      spacing: AylaSpacing.sp1, // gap: var(--sp-1)
      children: <Widget>[
        AvatarHalo(
          label: item.senderNickname,
          size: 20, // tsx 54 `size={20}`（光环外径 = 20 + 2.5×2）
          online: item.senderOnline,
          resourceUrl: item.senderAvatarUrl.isEmpty ? null : item.senderAvatarUrl,
          semanticLabel: '查看 ${item.senderNickname} 的个人主页', // tsx 58 aria-label
          onTap: openProfile == null
              ? null
              : () => openProfile(item.senderUserId),
        ),
        Padding(
          // `.danmaku-sender { padding-top: 2px; flex: none }`
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            '${item.senderNickname}：', // tsx 60
            style: TextStyle(
              // `.danmaku-sender`：--text-secondary / --font-utility / 12px
              // （不声明字重 ⇒ 继承 body 的常规字重）
              fontFamily: AylaFonts.utility,
              fontFamilyFallback: AylaFonts.cjkFallback,
              fontSize: 12,
              color: AylaColors.textSecondary,
            ),
          ),
        ),
        // `.danmaku-item` 的字号/行高（14 / 1.5）由内容列继承；`flex: none` 的昵称不收缩
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (imageSrc != null)
                Padding(
                  // `.danmaku-image-open { margin-top: var(--sp-1) }`
                  padding: const EdgeInsets.only(top: AylaSpacing.sp1),
                  child: _DanmakuImageButton(
                    src: imageSrc,
                    mediaId: item.mediaId,
                    alt: _mediaAlt(item),
                    onOpen: () => onOpenImage(item.media!, _mediaAlt(item)),
                  ),
                ),
              if (showText)
                Text(
                  item.content,
                  style: t.body.copyWith(
                    fontSize: 14,
                    height: 1.5, // line-height: 1.5
                    color: AylaColors.textPrimary, // `.danmaku-content`
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 弹幕图片钮（`.danmaku-image-open` + `.danmaku-image*`，app.css 3715–3747）。
///
/// **失败态照实渲染**（用户 2026-09-22 拍板）：web 的失败态由
/// `ResourceImage` 的 `fallback`（`.skeleton.danmaku-image-skeleton`，100%×100%）
/// 铺满 96×64，其后的「图片加载失败，点击重试」芯片被按钮的 `overflow: hidden`
/// 裁掉不可见；同时 `ResourceImage.tsx` 96–115 的 `enclosingControl` 把按钮的
/// click 抢过来重试 ⇒ **点击 = 重试，而不是打开查看器**。Flutter 没有事件捕获，
/// 故用 [ResourceImage.onStateChanged] 判态并自行路由点击。
class _DanmakuImageButton extends StatefulWidget {
  const _DanmakuImageButton({
    required this.src,
    required this.mediaId,
    required this.alt,
    required this.onOpen,
  });

  final String src;
  final String? mediaId;
  final String alt;
  final VoidCallback onOpen;

  @override
  State<_DanmakuImageButton> createState() => _DanmakuImageButtonState();
}

class _DanmakuImageButtonState extends State<_DanmakuImageButton> {
  AylaResourceImageState _state = AylaResourceImageState.loading;
  bool _hovered = false;
  int _retry = 0;

  /// 失败态点击 = 重试（web `retryImage`：失效缓存 + 重建 `<img>`）。
  void _retryLoad() {
    final String? mediaId = widget.mediaId ?? extractMediaId(widget.src);
    if (mediaId != null) MediaSigner.instance.invalidate(mediaId);
    setState(() {
      _retry += 1;
      _state = AylaResourceImageState.loading;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool failed = _state == AylaResourceImageState.failed;
    // `.danmaku-image-open:hover .danmaku-image { filter: brightness(1.06) }`
    // （只作用于 `<img>`：失败/加载中时不存在该元素，故只在 ready 时提亮）
    final bool brighten = _hovered && _state == AylaResourceImageState.ready;

    Widget image = ResourceImage(
      key: ValueKey<String>('danmaku-image:$_retry'),
      src: widget.src,
      alt: widget.alt,
      fit: BoxFit.cover, // `.danmaku-image { object-fit: cover }`
      // 加载骨架由本组件按 web 的 `fallback` 画（见类注释）；失败芯片保持被裁
      reserveSpaceWhileLoading: false,
      fallback: const AylaSkeleton(width: 96, height: 64),
      onStateChanged: (AylaResourceImageState state) {
        if (mounted) setState(() => _state = state);
      },
    );
    if (brighten) {
      image = ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          1.06, 0, 0, 0, 0, //
          0, 1.06, 0, 0, 0, //
          0, 0, 1.06, 0, 0, //
          0, 0, 0, 1, 0,
        ]),
        child: image,
      );
    }

    return Semantics(
      button: true,
      label: failed ? '${widget.alt}：图片加载失败，重试' : '查看弹幕图片', // tsx 69
      child: MouseRegion(
        cursor: SystemMouseCursors.zoomIn, // `cursor: zoom-in`
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          // web 的 `<button>` 整块可点（含骨架/失败态）——Flutter 的空装饰盒不参与
          // 命中测试，非 opaque 时加载态与失败态的点击会穿透到列表（实测）
          behavior: HitTestBehavior.opaque,
          onTap: failed ? _retryLoad : widget.onOpen,
          child: SizedBox(
            // `.danmaku-image-open { width: 96px; height: 64px; overflow: hidden }`
            width: 96,
            height: 64,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AylaRadii.rSm), // --radius-sm
              child: Stack(
                children: <Widget>[
                  // CSS 的静默裁剪在 Flutter 是 RenderFlex overflow ⇒ 显式
                  // `ClipRect + OverflowBox`（本项目已记录的等价技法）
                  Positioned.fill(
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.topLeft,
                        maxHeight: double.infinity,
                        child: image,
                      ),
                    ),
                  ),
                  // 加载中：web 的 `.resource-image-loading` 里渲染的就是 `fallback`
                  // 骨架（.skeleton = glass-bg + 1px 亮边 + frost-pulse），Flutter 的
                  // 内建加载占位是平底块 ⇒ 这里按 web 画。
                  if (_state == AylaResourceImageState.loading)
                    const Positioned.fill(
                      child: AylaSkeleton(width: 96, height: 64),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.danmaku-new-hint`（app.css 3749–3762 + tsx 121–129）。
///
/// 无 hover 态、无过渡（web 只声明静态样式）；底色是**爱莉气泡渐变**
/// （`--bubble-elysia` 135deg）+ `--text-on-pink` 字 + 常驻 `--glow-shadow`。
class _NewDanmakuHint extends StatelessWidget {
  const _NewDanmakuHint({this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    return Semantics(
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click, // base.css button { cursor: pointer }
        child: GestureDetector(
          onTap: onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: cssLinearGradient(
                angleDeg: 135,
                colors: AylaGradients.bubbleElysia,
              ),
              borderRadius: AylaRadii.pill, // --radius-pill
              boxShadow: AylaShadows.glow, // box-shadow: var(--glow-shadow)
            ),
            child: Padding(
              // padding: var(--sp-1) var(--sp-3)
              padding: const EdgeInsets.symmetric(
                horizontal: AylaSpacing.sp3,
                vertical: AylaSpacing.sp1,
              ),
              child: Text(
                '有新弹幕 ↓',
                style: t.body.copyWith(
                  fontSize: 12,
                  color: AylaColors.textOnPink, // --text-on-pink
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ======================= 弹幕输入 =======================

/// `.danmaku-input-area` 的上下文档位（web 由 `@media` + 祖先链共同决定，已逐条核验）。
enum AylaDanmakuInputMaterial {
  /// 窄屏沉浸态（`.live-room-body.is-narrow > .live-room-input`）：**玻璃底在本档自身**。
  ///
  /// 事实源：web 把这份材质放在**包装层** `.live-room-input`
  /// （`LiveRoomBody.tsx` 370–380；`live.css` 768–772：`background: var(--glass-bg)` +
  /// `backdrop-filter: blur(18px) saturate(1.4)`，**无边、无阴影、无圆角**）；
  /// 该元素没有 `.live-room-side` 祖先 ⇒ auroraqua 347–359（≥769）不适用，
  /// 内部区域保留 app.css 3764–3767 的 `padding sp3` + 上边框。
  /// Flutter 侧把包装层并入组件根，免得页面为一行包装再抄一遍 live.css。
  ///
  /// ⚠️ 2026-09-22 用户实测报「窄屏这个输入框又没加底」：当时只给了 base ⇒ 整条浮在极光底上。
  narrowCard,

  /// 宽屏（`≥769`）在 `.live-room-side` 卡片内 —— **用户截图的形态**。
  ///
  /// 层叠实算（三段）：
  /// - auroraqua 347–359（`:is(…, .danmaku-input-area)`，0-1-0）：`margin 12` /
  ///   `padding sp2` / `--glass-bg` / 1px 全边 / `radius 16` / `--glass-shadow` / blur24；
  /// - auroraqua 555–562（`.live-room-body .live-room-side > .live-room-input >
  ///   .danmaku-input-area`，0-4-0）：`background: transparent` / `box-shadow: none` /
  ///   `backdrop-filter: none`；
  /// - auroraqua 563–567（同选择器）:`border-color: transparent` /
  ///   `border-top-color: --glass-border` / `border-radius: 0`。
  ///
  /// ⇒ 实渲染 = **margin 12 + padding 8 + 透明底 + 仅上边框（卡内分隔线）+ 方角**；
  /// 347–359 的玻璃材质在这条链路上**永不生效**（我上一轮照它实现过 `floatingCard`，已删）。
  sideCard,

  /// 只画 `.danmaku-input-area` 自身（app.css 3764–3767：`padding sp3` + 上边框，透明）。
  ///
  /// 用于「材质由调用方持有 / 侧栏卡本身透明」的场合：studio 窄屏
  /// （`auroraqua` 569–581 把 `.live-room-side` 与弹幕区一起置透明，555–567 再收掉
  /// 输入区的底与圆角，且 ≥769 组不适用 ⇒ 无 margin、保留 `padding sp3`）。
  /// **实渲染与「sideCard 减去 margin/padding 覆写」等价 ⇒ 不另设档**。
  base,
}

/// 图片发送的中间态（web `ImageAttempt`：草稿快照 + 文件 + 可选 mediaId）。
class _DanmakuImageAttempt {
  const _DanmakuImageAttempt({
    required this.file,
    required this.content,
    required this.revision,
    this.mediaId,
  });

  final AylaPickedFile file;
  final String content;
  final int revision;
  final String? mediaId;

  _DanmakuImageAttempt withMediaId(String id) => _DanmakuImageAttempt(
    file: file,
    content: content,
    revision: revision,
    mediaId: id,
  );
}

/// 忙碌档（web `working: "uploading" | "sending" | null`）。
enum _DanmakuWork { uploading, sending }

/// 弹幕输入条（`DanmakuInput.tsx` 180 行）。
///
/// 三段结构：状态行（仅上传中 / 有失败图片时出现）→ 输入行（图片钮 + 输入框 +
/// 发送钮）→ 元行（错误文案或字数计数）。
class AylaDanmakuInput extends StatefulWidget {
  const AylaDanmakuInput({
    super.key,
    required this.onSend,
    this.onPickImage,
    this.onUploadImage,
    this.sending = false,
    this.error,
    this.material = AylaDanmakuInputMaterial.base,
    this.ownerKey,
    this.maxLength = 200, // web `DANMAKU_MAX_LENGTH`（useDanmaku.ts 19）
  });

  /// 发送（页面注入：`sendDanmaku`）。成功返回 true → 组件按 revision 守卫清空草稿。
  final Future<bool> Function(String content, String? mediaId) onSend;

  /// 选单张图片（页面注入：`AylaMediaActions.pickImage`）；null = 图片钮无动作。
  final Future<AylaPickedFile?> Function()? onPickImage;

  /// 上传单张图片 → `media_id`（页面注入：`AylaMediaActions.uploadImage`）。
  final Future<String> Function(
    AylaPickedFile file,
    ValueChanged<double?> onProgress,
  )?
  onUploadImage;

  /// 外部发送中（web `sending`，来自 useDanmaku）。
  final bool sending;

  /// 外部错误文案（web `error`；与本地错误取前者优先显示）。
  final String? error;

  /// 上下文材质档（见 [AylaDanmakuInputMaterial]）。
  final AylaDanmakuInputMaterial material;

  /// 归属键（web `key={`${accountId}:${channelId}`}`）：变化即重置草稿与重试态。
  final Object? ownerKey;

  /// 每账号/频道的草稿上限（web `DANMAKU_MAX_LENGTH` = 200）。
  final int maxLength;

  @override
  State<AylaDanmakuInput> createState() => _AylaDanmakuInputState();
}

class _AylaDanmakuInputState extends State<AylaDanmakuInput> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();

  /// 草稿修订号（web `revision` ref）：发送成功时只有「没再编辑过」才清空。
  int _revision = 0;

  /// 同步忙锁（web `busy` ref：同 tick 重复 Enter / 上传期间 Enter）。
  bool _busy = false;

  _DanmakuWork? _working;
  _DanmakuImageAttempt? _failedImage;
  String? _localError;

  bool get _disabled => widget.sending || _working != null;

  String? get _visibleError => _localError ?? widget.error;

  @override
  void didUpdateWidget(covariant AylaDanmakuInput old) {
    super.didUpdateWidget(old);
    if (old.ownerKey != widget.ownerKey) {
      // web 用 `key` 换实例：新 owner 拿到全新草稿，旧实例的迟到上传也改不了新状态
      _text.clear();
      _revision = 0;
      _busy = false;
      _working = null;
      _failedImage = null;
      _localError = null;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 错误文案（web `e instanceof Error ? e.message : "发送失败"`）。
  String _message(Object error) => switch (error) {
    AylaUploadException(:final String message) => message,
    ApiException(:final String message) => message,
    _ => '发送失败',
  };

  Future<bool> _sendSnapshot(
    String content, {
    required int revision,
    String? mediaId,
  }) async {
    if (!mounted) return false;
    final bool ok = await widget.onSend(content, mediaId);
    if (!mounted) return false;
    if (ok) {
      if (_revision == revision) {
        _revision += 1;
        _text.clear();
      }
      // 发送成功保持输入焦点（连续发弹幕不打断；点发送钮时焦点在钮上，还回输入框）
      _focus.requestFocus();
    }
    return ok;
  }

  Future<void> _submit() async {
    if (widget.sending || _busy || !mounted) return;
    _busy = true;
    setState(() {
      _working = _DanmakuWork.sending;
      _localError = null;
    });
    try {
      await _sendSnapshot(_text.text, revision: _revision);
    } catch (error) {
      if (mounted) setState(() => _localError = _message(error));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _working = null;
        });
      }
    }
  }

  /// 选图 →（上传）→ 发送。上传与发送**分成两步**，失败各自保留重试依据。
  Future<void> _sendImage(_DanmakuImageAttempt? original) async {
    final Future<String> Function(AylaPickedFile, ValueChanged<double?>)?
    upload = widget.onUploadImage;
    if (upload == null || widget.sending || _busy || !mounted) return;
    final _DanmakuImageAttempt attempt = original!;
    _busy = true;
    setState(() {
      _failedImage = null;
      _localError = null;
      _working = attempt.mediaId == null
          ? _DanmakuWork.uploading
          : _DanmakuWork.sending;
    });
    _DanmakuImageAttempt current = attempt;
    try {
      if (current.mediaId == null) {
        final String mediaId = await upload(current.file, (_) {});
        if (!mounted) return;
        current = current.withMediaId(mediaId);
      }
      setState(() => _working = _DanmakuWork.sending);
      final bool ok = await _sendSnapshot(
        current.content,
        revision: current.revision,
        mediaId: current.mediaId,
      );
      if (mounted && !ok) setState(() => _failedImage = current);
    } catch (_) {
      // web：上传或发送抛错都落到「有失败图片」状态（保留文件与已拿到的 mediaId）
      if (mounted) setState(() => _failedImage = current);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _working = null;
        });
      }
    }
  }

  Future<void> _pickImage() async {
    final Future<AylaPickedFile?> Function()? pick = widget.onPickImage;
    if (pick == null || _disabled || _busy || !mounted) return;
    final AylaPickedFile? file;
    try {
      file = await pick();
    } catch (error) {
      // 本地校验失败：文案交回界面（不伪造成功、不进入失败图片态）
      if (mounted) setState(() => _localError = _message(error));
      return;
    }
    if (!mounted || file == null) return; // 取消选择：非错误
    await _sendImage(
      _DanmakuImageAttempt(
        file: file,
        content: _text.text, // 快照：上传期间继续输入不影响这条弹幕
        revision: _revision,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final bool showStatus =
        _working == _DanmakuWork.uploading || _failedImage != null;

    final Widget area = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (showStatus) _buildStatus(t),
        Row(
          spacing: AylaSpacing.sp2, // `.danmaku-input-row { gap: var(--sp-2) }`
          children: <Widget>[
            GlassButton(
              // `button.btn.btn-ghost.danmaku-image-btn`：40×40、padding 0、
              // hover/focus 只换 glow 边（其余按 ghost）——见 glass.dart 的档位注释
              label: '',
              icon: AylaIcon(aylaIconByName('iconImage')!, size: 17), // tsx 130
              variant: GlassButtonVariant.ghost,
              glowBorderOnHover: true,
              minHeight: 40,
              minWidth: 40,
              padding: EdgeInsets.zero,
              semanticLabel: '发送弹幕图片', // tsx 128 aria-label
              onPressed: _disabled ? null : () => unawaited(_pickImage()),
            ),
            Expanded(
              child: GlassInput(
                controller: _text,
                hintText: '发条弹幕吧', // tsx 148
                minHeight: 40, // 行内 stretch（`.btn { min-height: 40px }` 决定行高）
                minLines: 1,
                maxLines: 1,
                padding: const EdgeInsets.symmetric(
                  horizontal: AylaSpacing.sp3, // padding: var(--sp-2) var(--sp-3)
                  vertical: AylaSpacing.sp2,
                ),
                textStyle: t.body.copyWith(fontSize: 14),
                // tsx 150：`maxLength = DANMAKU_MAX_LENGTH * 2`
                inputFormatters: <TextInputFormatter>[
                  LengthLimitingTextInputFormatter(widget.maxLength * 2),
                ],
                // tsx 151：**发送中不禁用输入框**（disabled 会强制失焦，破坏连续发弹幕）
                enabled: true,
                focusNode: _focus,
                semanticLabel: '弹幕内容',
                textInputAction: TextInputAction.send,
                onChanged: (_) => setState(() => _revision += 1),
                onSubmitted: (_) => unawaited(_submit()),
              ),
            ),
            GlassButton(
              // `button.btn.btn-primary.danmaku-send-btn`：min-width 72 + nowrap
              label: '',
              icon: AylaIcon(aylaIconByName('iconSend')!, size: 16), // tsx 166
              variant: GlassButtonVariant.primary,
              minHeight: 40,
              minWidth: 72,
              semanticLabel: '发送弹幕', // tsx 163 aria-label
              onPressed: (_disabled || _text.text.trim().isEmpty)
                  ? null
                  : () => unawaited(_submit()),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: AylaSpacing.sp1), // margin-top: sp1
          child: Align(
            alignment: Alignment.centerRight, // justify-content: flex-end
            child: switch (_visibleError) {
              // `.live-form-error`：--destructive 13px + margin-top sp2
              final String message => Padding(
                padding: const EdgeInsets.only(top: AylaSpacing.sp2),
                child: Text(
                  message,
                  style: t.body.copyWith(
                    fontSize: 13,
                    color: AylaColors.destructive,
                  ),
                ),
              ),
              // `.danmaku-counter`：--text-secondary / --font-utility / 12px
              _ => Text(
                '${_text.text.trim().length}/${widget.maxLength}',
                style: TextStyle(
                  fontFamily: AylaFonts.utility,
                  fontFamilyFallback: AylaFonts.cjkFallback,
                  fontSize: 12,
                  color: AylaColors.textSecondary,
                ),
              ),
            },
          ),
        ),
      ],
    );

    return _areaMaterial(area);
  }

  /// `.danmaku-input-status`（app.css 3793–3800 + tsx 111–125）。
  Widget _buildStatus(AylaTextStyles t) {
    final _DanmakuImageAttempt? failed = _failedImage;
    final String label = _working == _DanmakuWork.uploading
        ? '图片上传中…'
        : (failed?.mediaId != null ? '图片发送失败' : '图片上传失败');
    return Padding(
      padding: const EdgeInsets.only(bottom: AylaSpacing.sp2), // margin-bottom
      child: Semantics(
        liveRegion: true, // role=status（上传中）/ alert（失败）
        child: Row(
          spacing: AylaSpacing.sp2,
          children: <Widget>[
            Text(
              label,
              style: t.body.copyWith(
                fontSize: 12,
                color: AylaColors.textSecondary,
              ),
            ),
            if (failed != null)
              AylaMsgActionButton(
                label: '重试图片', // tsx 122
                onPressed: _disabled
                    ? null
                    : () => unawaited(_sendImage(failed)),
              ),
          ],
        ),
      ),
    );
  }

  /// `.danmaku-input-area` 的三档（web 由 `@media` 与祖先上下文共同决定）。
  Widget _areaMaterial(Widget child) {
    switch (widget.material) {
      case AylaDanmakuInputMaterial.base:
        return _bareArea(child);
      case AylaDanmakuInputMaterial.narrowCard:
        // 窄屏：玻璃底在**包装层** `.live-room-input`（live.css 768–772）——
        // `--glass-bg` + blur(18px) saturate(1.4)，**无边、无阴影、无圆角**
        return GlassSurface(
          radiusOverride: BorderRadius.zero,
          blur: AylaGlass.blurNav,
          border: false,
          shadow: const <BoxShadow>[],
          child: _bareArea(child),
        );
      case AylaDanmakuInputMaterial.sideCard:
        // 宽屏侧栏卡内：347–359 的玻璃材质被 auroraqua 555–567 清零，
        // 只剩 `margin 12` + `padding sp2` + 上边框（卡内分隔线）
        return Padding(
          padding: const EdgeInsets.all(AylaSpacing.sidebarGutter), // margin: 12
          child: _bareArea(child, padding: const EdgeInsets.all(AylaSpacing.sp2)),
        );
    }
  }

  /// `.danmaku-input-area` 自身（app.css 3764–3767：**透明 + 上边框 1px**）。
  ///
  /// 三档共用它：材质（玻璃底）只在 [AylaDanmakuInputMaterial.narrowCard] 里由包装层给；
  /// [padding] 是 `.danmaku-input-area` 的 `padding` —— 基础档 `sp3`（app.css），
  /// 宽屏侧栏档被 auroraqua 347–359 覆写为 `sp2`。
  Widget _bareArea(
    Widget child, {
    EdgeInsets padding = const EdgeInsets.all(AylaSpacing.sp3),
  }) {
    return Container(
      padding: padding,
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: AylaColors.glassBorder), // border-top: 1px
        ),
      ),
      child: child,
    );
  }
}

// ======================= 画面飘弹幕层 =======================

/// 画面内同时飘的弹幕上限（tsx 35：防长直播 DOM 堆积；超限丢弃最旧的）。
const int kDanmakuMaxFlying = 80;

/// 顶部第一条弹幕的起始偏移（tsx 37），轨道内再按行高递增。
const double kDanmakuOverlayTopPad = 8;

/// 一条正在飘的弹幕（web `FlyingEntry`，tsx 39–54）。
class _FlyingEntry {
  const _FlyingEntry({
    required this.key,
    required this.text,
    required this.mediaUrl,
    required this.media,
    required this.avatar,
    required this.track,
    required this.durMs,
    required this.fromX,
    required this.top,
    required this.delayMs,
  });

  /// 弹幕 id（store 按 id 去重，可直接作 key）。
  final String key;

  /// 纯文本内容（媒体弹幕的占位文案「图片」不飘文字，只飘图）。
  final String text;

  /// 媒体缩略图路径（ResourceImage 内部签名加载）；null = 无图。
  final String? mediaUrl;

  /// 媒体描述（点击放大用）；null = 无媒体。
  final AylaMediaDescriptor? media;

  /// 发送者头像 URL；空串 = 无头像（不渲染）。
  final String avatar;

  final int track;
  final int durMs;

  /// 动画起点（= 容器宽，注入 `--fly-from`）。
  final double fromX;

  /// 该轨道内的竖直位置。
  final double top;

  /// 起始延迟（同轨道最小间距保证；web 由 `startAt` 表达）。
  final int delayMs;
}

/// 直播画面飘弹幕层（`DanmakuOverlay.tsx` 213 行 + `danmakuTracks.ts`）。
///
/// 与弹幕列表**同一数据的另一种展示形态**：只飘「新出现」的弹幕——
/// 挂载与切台的基线快照（进房历史 / 重连对账）不重放（tsx 99–149）。
///
/// **层级（web `z-index: 4`）**：视频（static）之上、悬浮控件（z5）之下 ⇒
/// Flutter 侧由调用方在同一个 `Stack` 里的**次序**表达（放在视频层之后、
/// 控制条之前）；[AylaDanmakuOverlay] 自身不参与指针（等价 `pointer-events: none`，
/// 只有图片钮可点，见 [_FlyImageButton]），也不进无障碍树（tsx 159 `aria-hidden`）。
class AylaDanmakuOverlay extends StatefulWidget {
  const AylaDanmakuOverlay({
    super.key,
    required this.items,
    this.channelKey,
  });

  /// 当前频道的弹幕窗口（页面注入的 store 投影）。
  final List<AylaDanmakuEntry> items;

  /// 频道身份：变化 → 基线重建 + 画面清空（tsx 100–106「切台无残留」）。
  final Object? channelKey;

  @override
  State<AylaDanmakuOverlay> createState() => _AylaDanmakuOverlayState();
}

class _AylaDanmakuOverlayState extends State<AylaDanmakuOverlay> {
  final _DanmakuViewerHost _viewer = _DanmakuViewerHost();

  /// 已处理（飘过或基线）的弹幕 id，防重复飘（tsx 77）。
  final Set<String> _seen = <String>{};

  /// 各轨道最近一条弹幕的开始时间戳（tsx 79）。
  List<DanmakuTrackState> _tracks = <DanmakuTrackState>[];

  final List<_FlyingEntry> _entries = <_FlyingEntry>[];

  /// 容器当前尺寸（web 由 ResizeObserver 维护；只影响**后续新条目**）。
  double _width = 0;
  double _height = 0;

  @override
  void initState() {
    super.initState();
    _resetBaseline();
  }

  @override
  void didUpdateWidget(covariant AylaDanmakuOverlay old) {
    super.didUpdateWidget(old);
    if (old.channelKey != widget.channelKey) {
      _resetBaseline();
      return;
    }
    _ingest();
  }

  @override
  void dispose() {
    _viewer.close();
    super.dispose();
  }

  /// 基线重建：现有 id 全部视为已见、画面清空、轨道状态复位。
  void _resetBaseline() {
    _seen
      ..clear()
      ..addAll(widget.items.map((AylaDanmakuEntry item) => item.id));
    _entries.clear();
    _tracks = <DanmakuTrackState>[];
  }

  /// 只飘新弹幕（web 的 store 订阅：`seenRef` 去重 + 逐条分配轨道）。
  void _ingest() {
    if (widget.items.isEmpty) return;
    final int trackCount = trackCountForHeight(_height);
    if (_tracks.length != trackCount) {
      _tracks = List<DanmakuTrackState>.generate(
        trackCount,
        (_) => DanmakuTrackState(),
      );
    }
    final int gap = minGapMs();
    final double fromX = _width > 0 ? _width : 640;
    final int now = DateTime.now().millisecondsSinceEpoch;
    final List<_FlyingEntry> added = <_FlyingEntry>[];

    for (final AylaDanmakuEntry item in widget.items) {
      if (_seen.contains(item.id)) continue;
      _seen.add(item.id);
      final String text = item.content.isEmpty || item.content == '图片'
          ? ''
          : item.content;
      final String? mediaUrl = _thumbSrc(item);
      // 空弹幕不飘：纯图弹幕且无缩略图（或文字为空且无图）
      if (text.isEmpty && mediaUrl == null) continue;
      final int index = pickTrack(_tracks);
      final DanmakuTrackState track = _tracks[index];
      // 同轨道最小间距：上一条开始未满 gap 时从 gap 之后开始
      //（同速 ⇒ 水平间距恒 ≥ 最小间距）
      final int startAt = math.max(now, (track.lastStartAt + gap).round());
      track.lastStartAt = startAt.toDouble();
      added.add(
        _FlyingEntry(
          key: item.id,
          text: text,
          mediaUrl: mediaUrl,
          media: item.media,
          avatar: item.senderAvatarUrl,
          track: index,
          durMs: flyDurationMs(fromX),
          fromX: fromX,
          top: kDanmakuOverlayTopPad + index * kDanmakuTrackHeight,
          delayMs: startAt - now,
        ),
      );
    }
    if (added.isEmpty) return;
    _entries.addAll(added);
    if (_entries.length > kDanmakuMaxFlying) {
      _entries.removeRange(0, _entries.length - kDanmakuMaxFlying);
    }
  }

  void _remove(String key) {
    if (!mounted) return;
    setState(() => _entries.removeWhere((_FlyingEntry e) => e.key == key));
  }

  @override
  Widget build(BuildContext context) {
    // reduced-motion：飘弹幕本质是动效，整层不渲染（tsx 155–156，无静态降级需求）
    if (MediaQuery.disableAnimationsOf(context)) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 与 web 的 ResizeObserver 同语义：记录当前尺寸，供**后续**新条目使用
        _width = constraints.hasBoundedWidth ? constraints.maxWidth : 0;
        _height = constraints.hasBoundedHeight ? constraints.maxHeight : 0;
        return ExcludeSemantics(
          // tsx 159 `aria-hidden`：整层不进无障碍树（含图片钮的 aria-label）
          child: ClipRect(
            // `.danmaku-overlay { overflow: hidden }`
            child: Stack(
              children: <Widget>[
                for (final _FlyingEntry entry in _entries)
                  Positioned(
                    top: entry.top,
                    left: 0, // `.danmaku-fly { position: absolute; left: 0 }`
                    child: _FlyingDanmaku(
                      key: ValueKey<String>(entry.key),
                      entry: entry,
                      onDone: _remove,
                      onOpenImage: _openImage,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openImage(AylaMediaDescriptor media, String alt) {
    _viewer.open(context, media, alt);
  }
}

/// 单条飘弹幕（`.danmaku-fly` + 关键帧 `danmaku-fly`，live.css 875–929 / 1006–1018）。
class _FlyingDanmaku extends StatefulWidget {
  const _FlyingDanmaku({
    super.key,
    required this.entry,
    required this.onDone,
    required this.onOpenImage,
  });

  final _FlyingEntry entry;
  final ValueChanged<String> onDone;
  final void Function(AylaMediaDescriptor media, String alt) onOpenImage;

  @override
  State<_FlyingDanmaku> createState() => _FlyingDanmakuState();
}

class _FlyingDanmakuState extends State<_FlyingDanmaku>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fly = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: widget.entry.durMs),
  );

  final GlobalKey _contentKey = GlobalKey();
  Timer? _startTimer;

  /// 自身宽度（关键帧终点 `calc(-100% - 24px)` 需要它；首帧 layout 后才可知）。
  double? _width;

  @override
  void initState() {
    super.initState();
    // 起点是「容器右缘之外」，量宽之前停在起点与 CSS 首帧一致（肉眼不可见）
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    if (widget.entry.delayMs <= 0) {
      // 无延迟 ⇒ 挂载即起飘（web 的 CSS 动画在元素挂载那一帧就开始，不经定时器）
      _fly.forward();
    } else {
      // 同轨道最小间距：延迟到 `startAt` 才起步（时间差 = 水平间距）
      _startTimer = Timer(Duration(milliseconds: widget.entry.delayMs), () {
        if (mounted) _fly.forward();
      });
    }
    _fly.addStatusListener((AnimationStatus status) {
      if (status == AnimationStatus.completed) widget.onDone(widget.entry.key);
    });
  }

  void _measure() {
    if (!mounted) return;
    final RenderObject? box = _contentKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      setState(() => _width = box.size.width);
    }
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    _fly.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);
    final _FlyingEntry entry = widget.entry;

    return AnimatedBuilder(
      animation: _fly,
      builder: (BuildContext context, Widget? child) {
        final double start = entry.fromX;
        // `to { transform: translateX(calc(-100% - 24px)) }`（CSS 是事实源；
        // tsx 注释写的「-100%」不完整，实际还多 24px 才完全离屏）
        final double end = _width == null ? start : -(_width! + 24);
        return Transform.translate(
          offset: Offset(start + (end - start) * _fly.value, 0),
          child: child,
        );
      },
      child: Row(
        key: _contentKey,
        mainAxisSize: MainAxisSize.min, // inline-flex：按内容宽
        spacing: AylaSpacing.sp2, // gap: var(--sp-2)
        children: <Widget>[
          if (entry.avatar.isNotEmpty) _FlyAvatar(src: entry.avatar),
          if (entry.mediaUrl != null && entry.media != null)
            _FlyImageButton(
              src: entry.mediaUrl!,
              onOpen: () => widget.onOpenImage(
                entry.media!,
                entry.text.isEmpty ? '弹幕图片' : entry.text,
              ),
            ),
          if (entry.text.isNotEmpty)
            Text(
              entry.text,
              // `.danmaku-fly`：--font-body 16 / 700 / line-height 1.3 / #fff
              // + 三层深色描边投影（媒体叠加场景的可读性，不适用界面正文对比度规则）
              style: t.body.copyWith(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                height: 1.3,
                color: const Color(0xFFFFFFFF),
                shadows: const <Shadow>[
                  Shadow(
                    offset: Offset(0, 1),
                    blurRadius: 2,
                    color: Color(0xD9000000), // rgba(0,0,0,.85)
                  ),
                  Shadow(blurRadius: 3, color: Color(0x99000000)), // .6
                  Shadow(blurRadius: 10, color: Color(0x73000000)), // .45
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 飘弹幕头像（`.danmaku-fly-avatar`，live.css 896–905）。
///
/// 20×20 圆 + 1px 白描边 + 深色投影；web 传 `alt=""`（装饰图）且
/// `fallback={null}` ⇒ **加载失败时整个元素消失**（不破图、不留空洞）。
class _FlyAvatar extends StatefulWidget {
  const _FlyAvatar({required this.src});

  final String src;

  @override
  State<_FlyAvatar> createState() => _FlyAvatarState();
}

class _FlyAvatarState extends State<_FlyAvatar> {
  AylaResourceImageState _state = AylaResourceImageState.loading;

  @override
  Widget build(BuildContext context) {
    if (_state == AylaResourceImageState.failed ||
        _state == AylaResourceImageState.expired) {
      return const SizedBox.shrink();
    }
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: const Color(0x8CFFFFFF), // rgba(255,255,255,.55)
        ),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            offset: Offset(0, 1),
            blurRadius: 3,
            color: Color(0x73000000), // rgba(0,0,0,.45)
          ),
        ],
      ),
      child: ClipOval(
        child: ResourceImage(
          src: widget.src,
          alt: '', // 装饰图：失败不提示
          width: 20,
          height: 20,
          fit: BoxFit.cover, // object-fit: cover
          fallback: null,
          onStateChanged: (AylaResourceImageState state) {
            if (mounted) setState(() => _state = state);
          },
        ),
      ),
    );
  }
}

/// 飘弹幕里的媒体图（`.danmaku-fly-img-open` + `.danmaku-fly-img`，live.css 906–929）。
class _FlyImageButton extends StatefulWidget {
  const _FlyImageButton({required this.src, required this.onOpen});

  final String src;
  final VoidCallback onOpen;

  @override
  State<_FlyImageButton> createState() => _FlyImageButtonState();
}

class _FlyImageButtonState extends State<_FlyImageButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    Widget image = ResourceImage(
      src: widget.src,
      alt: '',
      width: 72, // `.danmaku-fly-img { width: 72px; height: 36px }`
      height: 36,
      fit: BoxFit.cover,
      variant: MediaVariant.thumb, // tsx 196 `variant="thumb"`
      fallback: null,
      reserveSpaceWhileLoading: false,
    );
    if (_hovered) {
      // `.danmaku-fly-img-open:hover .danmaku-fly-img { filter: brightness(1.08) }`
      image = ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          1.08, 0, 0, 0, 0, //
          0, 1.08, 0, 0, 0, //
          0, 0, 1.08, 0, 0, //
          0, 0, 0, 1, 0,
        ]),
        child: image,
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.zoomIn, // cursor: zoom-in
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        // 层整体 `pointer-events: none`，只有图片钮恢复可点（tsx 909–910）；
        // opaque 保证图片未就绪时整块 72×36 仍可点（空子树不参与命中测试）
        behavior: HitTestBehavior.opaque,
        onTap: widget.onOpen,
        child: Container(
          width: 72,
          height: 36,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AylaRadii.rSm),
            border: Border.all(
              color: const Color(0x59FFFFFF), // rgba(255,255,255,.35)
            ),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                offset: Offset(0, 1),
                blurRadius: 4,
                color: Color(0x80000000), // rgba(0,0,0,.5)
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AylaRadii.rSm),
            child: image,
          ),
        ),
      ),
    );
  }
}

// ======================= 预览样张 =======================

/// 弹幕族样张（可交互）：列表（宽屏卡内 / 窄屏裸放）+ 空态与历史档 +
/// 输入条三档 + 飘弹幕层。
Widget aylaDanmakuSamples() {
  aylaEnableSampleMedia();
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      _Stage(
        viewport: const Size(420, 360),
        label:
            '列表 · 宽屏（材质归调用方卡片 `.live-room-side`，auroraqua 392–400；**列表自身无底**）· 可交互：点图片开查看器 / 点「有新弹幕」跳底',
        child: Padding(
          padding: const EdgeInsets.all(AylaSpacing.sidebarGutter),
          child: GlassSurface(
            radiusOverride: BorderRadius.all(
              Radius.circular(AylaRadii.rCard), // --radius-card 16
            ),
            blur: AylaGlass.blurCard, // blur(24) saturate(1.4)
            child: const _DanmakuListDemo(),
          ),
        ),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(420, 300),
        label:
            '列表 · 窄屏滑动单元（live.css 830–838：**透明 + 无边框 + 无圆角**，只有 `min-height: 96`；756–764 那份玻璃被本媒体查询清零，永不渲染）',
        child: const _DanmakuListDemo(minHeight: 96),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(420, 300),
        label: '列表 · 空态 + 历史控件档（app.css 3687–3692 / HistoryControls.tsx）',
        child: const _DanmakuListDemo(
          empty: true,
          history: AylaHistoryControlsData(hasMore: true, hasNewer: true),
        ),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(420, 480),
        label:
            '宽屏直播侧栏卡（**真实装配**：`.live-room-side` 卡片内 = 列表 + 输入条同卡；输入条走 sideCard 档 = 透明底 + 仅上边框分隔线 + margin 12 / padding 8）· 可交互：发弹幕（追加到列表）/ 点图片开查看器 / 点「有新弹幕」跳底',
        child: Padding(
          padding: const EdgeInsets.all(AylaSpacing.sidebarGutter),
          child: GlassSurface(
            // `.live-room-side`（auroraqua 392–400）：margin 12 / 1px 边 / radius 16 /
            // `--glass-shadow` / blur24 sat1.4 —— 材质归卡片，卡内列表与输入区透明
            radiusOverride: BorderRadius.all(
              Radius.circular(AylaRadii.rCard),
            ),
            blur: AylaGlass.blurCard,
            padding: EdgeInsets.zero,
            child: ClipRRect(
              borderRadius: BorderRadius.all(Radius.circular(AylaRadii.rCard)),
              child: const _DanmakuSideCardDemo(),
            ),
          ),
        ),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(560, 190),
        label:
            '输入条 · 窄屏沉浸档（≤768；live.css 768–772 的 `--glass-bg` + blur18 sat1.4 **在包装层**，本档已并入组件）· 可交互：输入计数 / Enter 发送 / 图片上传失败→重试',
        child: const _DanmakuInputDemo(
          material: AylaDanmakuInputMaterial.narrowCard,
        ),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(560, 190),
        label:
            '输入条 · base 档（studio 窄屏：`.live-room-side` 本身被 auroraqua 569–581 置透明 ⇒ 只有 app.css 3764–3767 的 padding sp3 + 上边框）',
        child: const _DanmakuInputDemo(
          material: AylaDanmakuInputMaterial.base,
          simulateImageFailure: false,
        ),
      ),
      const SizedBox(height: AylaSpacing.sp6),
      _Stage(
        viewport: const Size(640, 240),
        label: '飘弹幕层（live.css 867–929 + danmakuTracks.ts）· 可交互：点「发一条」看从右向左飘 / 点「换台」看基线重建',
        child: const _DanmakuOverlayDemo(),
      ),
    ],
  );
}

/// 固定视口的样张舞台（与其他批次同纪律：断点/布局都读 `MediaQuery` 视口）。
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

AylaDanmakuEntry _sampleEntry(
  String id,
  String nickname, {
  String content = '',
  String avatar = '',
  bool online = true,
  String? mediaId,
}) {
  return AylaDanmakuEntry(
    id: id,
    senderNickname: nickname,
    senderUserId: 'user-$nickname',
    senderAvatarUrl: avatar,
    senderOnline: online,
    content: content,
    mediaId: mediaId,
    media: mediaId == null
        ? null
        : AylaMediaDescriptor(
            mediaId: mediaId,
            kind: AylaMediaKind.image,
            thumbnail: '$kMediaPathPrefix$mediaId/thumbnail',
          ),
  );
}

/// 宽屏直播侧栏卡（**真实装配**）：`.live-room-side` 卡片内 = 弹幕列表 + 输入条。
///
/// 事实源：`LiveRoomBody.tsx` 531–534（`<aside class="live-room-side">` 同时包住
/// `danmakuList` 与 `danmakuInput`）+ auroraqua.css 392–400（卡片材质）+
/// 553–567（卡内列表与输入区透明、输入区只留上边框）。
class _DanmakuSideCardDemo extends StatefulWidget {
  const _DanmakuSideCardDemo();

  @override
  State<_DanmakuSideCardDemo> createState() => _DanmakuSideCardDemoState();
}

class _DanmakuSideCardDemoState extends State<_DanmakuSideCardDemo> {
  final ScrollController _scroll = ScrollController();
  final List<AylaDanmakuEntry> _items = <AylaDanmakuEntry>[
    _sampleEntry('c1', '观众A', content: '主播好耶'),
    _sampleEntry('c2', '观众B', content: '这张图好看吗？', mediaId: 'sample-img-1'),
  ];
  int _seq = 0;
  bool _hasNewBelow = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Expanded(
          child: AylaDanmakuList(
            items: _items,
            controller: _scroll,
            hasNewBelow: _hasNewBelow,
            onScrollToBottom: () {
              if (_scroll.hasClients) {
                _scroll.jumpTo(_scroll.position.maxScrollExtent);
              }
            },
            onOpenSenderProfile: (_) {},
          ),
        ),
        AylaDanmakuInput(
          material: AylaDanmakuInputMaterial.sideCard,
          onSend: (String content, String? mediaId) async {
            setState(() {
              _seq += 1;
              _items.add(
                _sampleEntry(
                  'live-$_seq',
                  '汐汐',
                  content: content.isEmpty ? '图片' : content,
                  mediaId: mediaId,
                ),
              );
              _hasNewBelow = false;
            });
            return true;
          },
          onPickImage: () async => AylaPickedFile(
            name: 'sample/danmaku.jpg',
            size: 1024,
            mimeType: 'image/jpeg',
            readBytes: () async => throw UnimplementedError('样张不读字节'),
          ),
          onUploadImage: (AylaPickedFile file, ValueChanged<double?> _) async =>
              'sample-media-id',
        ),
      ],
    );
  }
}

/// 列表样张宿主（自持窗口 + 新弹幕提示开关 + 跳底）。
class _DanmakuListDemo extends StatefulWidget {
  const _DanmakuListDemo({
    this.empty = false,
    this.history,
    this.minHeight,
  });

  final bool empty;
  final AylaHistoryControlsData? history;
  final double? minHeight;

  @override
  State<_DanmakuListDemo> createState() => _DanmakuListDemoState();
}

class _DanmakuListDemoState extends State<_DanmakuListDemo> {
  final ScrollController _scroll = ScrollController();
  bool _append = false;

  List<AylaDanmakuEntry> get _items {
    if (widget.empty) return const <AylaDanmakuEntry>[];
    final List<AylaDanmakuEntry> base = <AylaDanmakuEntry>[
      _sampleEntry('s1', '观众A', content: '主播好耶'),
      _sampleEntry('s2', '观众B', content: '这张图好看吗？', mediaId: 'sample-img-1'),
      _sampleEntry('s3', '观众C', content: '图片', mediaId: 'sample-img-2', online: false),
      _sampleEntry('s4', '观众D', content: '今晚几点下播呀，等了好久终于开播了，激动'),
    ];
    if (_append) {
      base.add(_sampleEntry('s5', '观众E', content: '刚来，发生了什么'));
      base.add(_sampleEntry('s6', '观众F', content: '蹲一个歌单'));
    }
    return base;
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: AylaDanmakuList(
            items: _items,
            minHeight: widget.minHeight,
            controller: _scroll,
            history: widget.history,
            hasNewBelow: _append,
            onScrollToBottom: () {
              if (_scroll.hasClients) {
                _scroll.jumpTo(_scroll.position.maxScrollExtent);
              }
            },
            onOpenSenderProfile: (_) {},
          ),
        ),
        TextButton(
          onPressed: () => setState(() => _append = !_append),
          child: const Text('切「有新弹幕」提示'),
        ),
      ],
    );
  }
}

/// 输入条样张宿主：模拟发送成功 / 图片上传失败→重试。
class _DanmakuInputDemo extends StatefulWidget {
  const _DanmakuInputDemo({
    required this.material,
    this.simulateImageFailure = true,
  });

  final AylaDanmakuInputMaterial material;
  final bool simulateImageFailure;

  @override
  State<_DanmakuInputDemo> createState() => _DanmakuInputDemoState();
}

class _DanmakuInputDemoState extends State<_DanmakuInputDemo> {
  String? _error;
  int _sent = 0;
  bool _failNextSend = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: AylaDanmakuInput(
              material: widget.material,
              error: _error,
              onSend: (String content, String? mediaId) async {
                if (_failNextSend) {
                  setState(() => _failNextSend = false);
                  throw Exception('发送失败：网络异常');
                }
                setState(() => _sent += 1);
                return true;
              },
              // 样张不碰平台文件选择：直接造一个「已选中的文件」
              onPickImage: () async => AylaPickedFile(
                path: 'sample/danmaku.jpg',
                name: 'danmaku.jpg',
                mimeType: 'image/jpeg',
                size: 1024,
                readBytes: () async => throw UnimplementedError(),
              ),
              onUploadImage: (AylaPickedFile file, ValueChanged<double?> onProgress) async {
                if (widget.simulateImageFailure) {
                  throw Exception('上传失败');
                }
                return 'sample-media-id';
              },
            ),
          ),
        ),
        Row(
          children: <Widget>[
            TextButton(
              onPressed: () => setState(() => _failNextSend = true),
              child: const Text('下一次发送失败'),
            ),
            TextButton(
              onPressed: () => setState(() => _error = _error == null ? '弹幕不能为空' : null),
              child: const Text('外部错误文案'),
            ),
            Text('已发送 $_sent 条', style: const TextStyle(fontSize: 11)),
          ],
        ),
      ],
    );
  }
}

/// 飘弹幕样张宿主：黑底「视频区」+ 追加弹幕 / 换台。
class _DanmakuOverlayDemo extends StatefulWidget {
  const _DanmakuOverlayDemo();

  @override
  State<_DanmakuOverlayDemo> createState() => _DanmakuOverlayDemoState();
}

class _DanmakuOverlayDemoState extends State<_DanmakuOverlayDemo> {
  final List<AylaDanmakuEntry> _items = <AylaDanmakuEntry>[];
  int _seq = 0;
  int _channel = 1;

  void _append({bool withMedia = false}) {
    setState(() {
      _seq += 1;
      _items.add(
        _sampleEntry(
          'fly-$_channel-$_seq',
          '观众$_seq',
          content: withMedia ? '图片' : '弹幕 $_seq 从右向左飘过',
          avatar: 'https://example.com/avatar/$_seq.png',
          mediaId: withMedia ? 'sample-img-$_seq' : null,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: Stack(
            children: <Widget>[
              // 视频区（黑底：飘弹幕的白字描边就是为这种叠加场景设计的）
              Positioned.fill(
                child: ColoredBox(
                  color: const Color(0xFF1B2434),
                  child: Center(
                    child: Text(
                      '16:9 视频区',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: AylaDanmakuOverlay(
                  items: _items,
                  channelKey: _channel,
                ),
              ),
            ],
          ),
        ),
        Row(
          children: <Widget>[
            TextButton(
              onPressed: _append,
              child: const Text('发一条弹幕'),
            ),
            TextButton(
              onPressed: () => _append(withMedia: true),
              child: const Text('发一条图片弹幕'),
            ),
            TextButton(
              onPressed: () => setState(() {
                _channel += 1;
                _items.clear(); // 切台：基线重建、画面清空
              }),
              child: const Text('换台'),
            ),
          ],
        ),
      ],
    );
  }
}

/// 弹幕族（列表 / 输入 / 飘弹幕层）。
@Preview(
  group: 'Widgets',
  name: '弹幕族（列表 + 输入 + 飘弹幕）',
  size: Size(760, 1700),
  wrapper: previewTheme,
)
Widget aylaDanmakuPreview() => aylaDanmakuSamples();
