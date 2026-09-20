/// AylaImageViewer —— 图片/视频全屏查看器（web `components/chat/ImageViewer.tsx` 503 行）。
///
/// 事实源：`ImageViewer.tsx` + `styles/app.css:1459–1836`（.image-viewer 族全量）
/// + `styles/auroraqua.css:55–94/663–670`（nav/close 的 200ms 组与 hover 1.02 / active .98）
/// + `hooks/useSwipeCommit.ts`（松手判定阈值）。
///
/// 关键事实（回读确认）：
/// 1. 遮罩 `.image-viewer`：`position: fixed; inset: 0; z-index: 90; flex column center;
///    gap sp4`；`background: --overlay-dim-strong` + **`backdrop-filter: blur(8px)`（无 saturate）**；
///    入场 `viewer-in`（opacity 0→1，--dur-fast 180ms --ease-out）；点遮罩空白关闭。
/// 2. 关闭钮 40×40 圆形（glass-bg-strong + 1px 亮边 + indigo 图标），hover/focus → --glow-shadow；
///    打开即聚焦它（键盘可达）。
/// 3. 舞台 `max-width: min(92vw,1200px); max-height: 82vh`；图片 `object-fit: contain` +
///    `--radius-input`(12) + `--surface` 底 + `--card-shadow`。
/// 4. 导航钮 44×44 圆形（glass-bg-strong + blur(12px) saturate(1.4)），`‹ ›` 26px，
///    禁用 0.35；多条目才显示。
/// 5. 操作条：pill 玻璃（blur 18 + saturate 1.4），内含计数（Space Grotesk 12 + ls .5）与保存钮
///    （IconDownload 16 + gap sp1）；保存中「保存中…」、本地预览「发送后可保存」、其余「保存」。
/// 6. 保存失败提示 `.image-viewer-error`：absolute bottom 76、pill、--overlay-dim-strong 底、
///    白字 13；文案「媒体已过期，无法保存」/「保存失败，请重试」。
/// 7. 手势（`useSwipeCommit`）：主轴净位移 ≥ 容器 1/3 → 切；或同向甩动（|v| ≥ 300px/s 且
///    净位移 ≥ 40px）→ 切；**交叉轴净位移 ≥ 主轴 → 一律不切**；单条目不启用横滑
///    （保留既有关闭交互）；reduced-motion 关闭横滑与位移（仅透明度）。
/// 8. 条目切换转场：进入 x = ±40%、退出 x = ∓30%，250ms（--ease-out 进 / --ease-in 出）。
/// 9. 视频分支：web 用原生 `<video controls autoPlay>`（签名 URL + Range 流式）；Flutter 侧
///    播放器是 widget 且库内 `SignedVideo` 目前只到「签名 + 状态机」契约（播放器接入点见
///    media_interaction.dart 注释）→ 本组件复用 `SignedVideo(controls: true)`，
///    **不另造第二条视频路径**；海报帧/过期角标由本组件补齐。
///
/// **展示型组件**：关闭、切换、保存都在组件内完成（保存用 MediaSigner 签名 + dio 直连下载，
/// 与 web 的 `a[download]` 同语义）；页面只需传条目与 onClose。
library;

import 'dart:io' show Directory, File, Platform;

import 'package:dio/dio.dart' show Dio;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widget_previews.dart';
import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory, getDownloadsDirectory;

import '../core/media/media_signer.dart'
    show MediaExpiredError, MediaSigner, MediaVariant, SignedMediaResult;
import '../core/models/post.dart';
import '../theme/app_icons.dart';
import '../theme/glass.dart';
import '../theme/preview_theme.dart';
import '../theme/sample_media.dart';
import '../theme/tokens.dart';
import 'loading.dart' show AylaSkeleton;
import 'media_interaction.dart' show SignedVideo;
import 'resource_image.dart';

/// 查看器条目（web `ViewerItem`）：服务端媒体或乐观本地预览。
class AylaViewerItem {
  const AylaViewerItem({
    this.media,
    this.localPath,
    this.isVideo = false,
    this.alt = '',
  });

  /// 服务端媒体描述符（null = 纯本地预览，不可保存）。
  final AylaMediaDescriptor? media;

  /// 本地文件路径（乐观消息预览；只展示不保存）。
  final String? localPath;

  /// 本地预览是否为视频（服务端媒体按 media.kind 判断）。
  final bool isVideo;

  /// 可访问性/替代文本。
  final String alt;
}

/// 图片/视频全屏查看器。
class AylaImageViewer extends StatefulWidget {
  const AylaImageViewer({
    super.key,
    required this.onClose,
    this.media,
    this.alt = '',
    this.items = const <AylaViewerItem>[],
    this.initialIndex = 0,
    this.embedded = false,
  });

  /// 关闭回调（遮罩点击 / ESC / 关闭钮）。
  final VoidCallback onClose;

  /// 单条目模式（兼容旧调用）。
  final AylaMediaDescriptor? media;

  /// 单条目模式的替代文本。
  final String alt;

  /// 多条目模式（同消息的图片/视频列表）。
  final List<AylaViewerItem> items;

  /// 初始序号（多条目模式）。
  final int initialIndex;

  /// 嵌入宿主（组件画布/内嵌面板）而非全屏铺满时置 true。
  ///
  /// ⚠️ 为什么需要这个位：web 的查看器用 ~createPortal(document.body)~ 挂到 body 顶层，
  /// 所以 ~backdrop-filter: blur(8px)~ 糊的是整页、语义正确；Flutter 没有 portal，组件被
  /// 嵌进画布时，~BackdropFilter~ 采样的是**它背后的整张宿主页**（2026-09-20 用户实测：
  /// 「图片族把整个画布都遮罩弄糊了」）。因此嵌入模式只保留 ~--overlay-dim-strong~ 压暗，
  /// 不启用 backdrop 模糊；全屏使用（默认）行为与 web 一致。
  final bool embedded;

  @override
  State<AylaImageViewer> createState() => _AylaImageViewerState();
}

class _AylaImageViewerState extends State<AylaImageViewer>
    with SingleTickerProviderStateMixin {
  late List<AylaViewerItem> _list = widget.items.isNotEmpty
      ? widget.items
      : <AylaViewerItem>[
          AylaViewerItem(media: widget.media, alt: widget.alt),
        ];
  late int _index = widget.initialIndex.clamp(0, _list.length - 1);

  bool _saving = false;
  bool _saveError = false;
  bool _saveExpired = false;

  /// 手势净位移（跟手位移；0 = 归位）。
  double _dragX = 0;
  bool _dragging = false;
  /// 本次切换方向（1 = 下一张左滑入，-1 = 上一张右滑入）。
  int _direction = 1;
  /// 条目切换滑入（enter x = dir*40%，250ms --ease-out）。
  late final AnimationController _slide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );

  /// 条目/初始序号变化时重新同步（查看器通常每次打开重建，但状态复用也要正确）。
  @override
  void didUpdateWidget(AylaImageViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool changed = oldWidget.initialIndex != widget.initialIndex ||
        oldWidget.media?.mediaId != widget.media?.mediaId ||
        oldWidget.alt != widget.alt ||
        oldWidget.items != widget.items; // 列表身份/内容变化（含长度与元素）
    if (!changed) return;
    setState(() {
      _list = widget.items.isNotEmpty
          ? widget.items
          : <AylaViewerItem>[AylaViewerItem(media: widget.media, alt: widget.alt)];
      _index = widget.initialIndex.clamp(0, _list.length - 1);
    });
  }

  AylaViewerItem get _current => _list[_index];

  bool get _reduceMotion => MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  /// 仅多条目且非 reduced-motion 才启用横滑（web `canSwipe`）。
  bool get _canSwipe => _list.length > 1 && !_reduceMotion;

  @override
  void dispose() {
    _slide.dispose();
    super.dispose();
  }

  /// 切换条目（enter 从 ±40% 滑入 250ms；reduced-motion 直切）。
  void _go(int delta) {
    final int next = (_index + delta).clamp(0, _list.length - 1);
    if (next == _index) return;
    _direction = delta >= 0 ? 1 : -1;
    setState(() => _index = next);
    if (_reduceMotion) {
      _slide.value = 1;
    } else {
      _slide.forward(from: 0);
    }
  }

  void _prev() => _go(-1);

  void _next() => _go(1);

  /// 横滑跟手（web ~dragElastic 0.8~；Flutter 的 HorizontalDrag 已轴锁，交叉轴恒 0）。
  void _onDragStart(DragStartDetails details) {
    setState(() {
      _dragging = true;
      _dragX = 0;
    });
  }

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() => _dragX = _dragX + details.delta.dx * 0.8);
  }

  void _onDragEnd(DragEndDetails details) {
    final double width = MediaQuery.sizeOf(context).width;
    final double velocity = details.velocity.pixelsPerSecond.dx;
    final int commit = _resolveSwipe(
      net: _dragX,
      cross: 0, // 水平拖拽手势已轴锁
      velocity: velocity,
      size: width,
    );
    setState(() {
      _dragging = false;
      _dragX = 0; // 归位（web dragConstraints 0 + elastic）
    });
    if (commit == 1) _next();
    if (commit == -1) _prev();
  }

  /// web `resolveSwipeCommit` 的逐条等价（阈值 1/3、甩动 300px/s + 40px、交叉轴让位）。
  int _resolveSwipe({required double net, required double cross, required double velocity, required double size}) {
    if (cross.abs() >= net.abs()) return 0;
    final double distance = net.abs();
    final bool forward = net < 0;
    if (distance >= size / 3) return forward ? 1 : -1;
    if (distance >= 40 && velocity.abs() >= 300 && velocity.sign == net.sign) {
      return forward ? 1 : -1;
    }
    return 0;
  }

  /// web `downloadMedia`：签名 URL + 原生下载（零内存流式写盘）。
  /// Flutter 用 dio 直连签名 URL 写文件（**不附加 Authorization**——预签名自带鉴权）。
  Future<void> _save() async {
    final AylaMediaDescriptor? media = _current.media;
    if (media == null || _saving) return;
    setState(() {
      _saving = true;
      _saveError = false;
      _saveExpired = false;
    });
    try {
      final SignedMediaResult signed =
          await MediaSigner.instance.sign(media.mediaId);
      final Directory? downloads = await getDownloadsDirectory();
      final Directory dir =
          downloads ?? await getApplicationDocumentsDirectory();
      final String path =
          dir.path + Platform.pathSeparator + _downloadName(media);
      await Dio().download(signed.url, path);
      if (mounted) setState(() => _saving = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = true;
        _saveExpired = error is MediaExpiredError;
      });
    }
  }

  /// 下载文件名（web：`ayla-image|ayla-video-<id 前 8 位>.<mime 扩展名>`）。
  String _downloadName(AylaMediaDescriptor media) {
    final String prefix =
        media.kind == AylaMediaKind.video ? 'ayla-video' : 'ayla-image';
    final String id = media.mediaId.length > 8
        ? media.mediaId.substring(0, 8)
        : media.mediaId;
    return '$prefix-$id.${_extFromMime(media.mimeType)}';
  }

  /// MIME → 扩展名（与 web `extFromMime` 同表）。
  String _extFromMime(String? mime) {
    const Map<String, String> table = <String, String>{
      'image/png': 'png',
      'image/jpeg': 'jpg',
      'image/jpg': 'jpg',
      'image/pjpeg': 'jpg',
      'image/gif': 'gif',
      'image/webp': 'webp',
      'image/avif': 'avif',
      'image/heic': 'heic',
      'image/heif': 'heif',
      'image/bmp': 'bmp',
      'image/x-ms-bmp': 'bmp',
      'image/tiff': 'tiff',
      'image/x-icon': 'ico',
      'image/vnd.microsoft.icon': 'ico',
      'image/svg+xml': 'svg',
      'video/mp4': 'mp4',
      'video/webm': 'webm',
      'video/quicktime': 'mov',
      'video/x-m4v': 'm4v',
      'video/x-matroska': 'mkv',
      'video/3gpp': '3gp',
      'video/3gpp2': '3g2',
    };
    final String m = mime ?? '';
    final String? hit = table[m];
    if (hit != null) return hit;
    return m.startsWith('video/') ? 'mp4' : 'png';
  }


  @override
  Widget build(BuildContext context) {
    final Size vp = MediaQuery.of(context).size;
    final double stageMaxW = vp.width * 0.92 < 1200 ? vp.width * 0.92 : 1200;
    final double stageMaxH = vp.height * 0.82;
    final AylaViewerItem item = _current;
    final bool isLocal = item.localPath != null && item.media == null;
    final bool canSave = !_saving && !isLocal && item.media != null;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): _prev,
        const SingleActivator(LogicalKeyboardKey.arrowRight): _next,
      },
      child: Focus(
        autofocus: true,
        child: Semantics(
          // role=dialog aria-modal=true
          scopesRoute: true,
          namesRoute: true,
          explicitChildNodes: true,
          label: _list.length > 1
              ? '图片查看：${_index + 1}/${_list.length}'
              : (widget.alt.isNotEmpty ? '图片查看：$widget.alt' : '图片查看'),
          child: GestureDetector(
            // 点遮罩空白关闭（stage / 操作条各自 stopPropagation）
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
            child: ColoredBox(
              // background: --overlay-dim-strong + backdrop-filter: blur(8px)（无 saturate）
              color: AylaColors.overlayDimStrong,
              child: Stack(
                children: <Widget>[
                  // 全屏才做 backdrop 模糊（嵌入模式会糊掉宿主页，见 embedded 注释）
                  if (!widget.embedded)
                    Positioned.fill(
                      child: BackdropFilter(
                        filter: GlassConfig.blurOnly(sigma: 8),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  // 入场：opacity 0→1，--dur-fast(180ms) --ease-out
                  Positioned.fill(
                    child: _ViewerFadeIn(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          const Spacer(),
                          GestureDetector(
                            // .image-viewer-stage：点内容不关闭；多条目时横滑切图
                            onTap: () {},
                            onHorizontalDragStart: _canSwipe ? _onDragStart : null,
                            onHorizontalDragUpdate: _canSwipe ? _onDragUpdate : null,
                            onHorizontalDragEnd: _canSwipe ? _onDragEnd : null,
                            child: TweenAnimationBuilder<double>(
                              tween: Tween<double>(end: _dragX),
                              duration: _dragging
                                  ? Duration.zero
                                  : const Duration(milliseconds: 250),
                              curve: AylaCurves.easeOut,
                              builder: (BuildContext c, double v, Widget? child) =>
                                  Transform.translate(
                                offset: Offset(v, 0),
                                child: child,
                              ),
                              child: _slideIn(
                                stageMaxW,
                                ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxWidth: stageMaxW,
                                    maxHeight: stageMaxH,
                                  ),
                                  child: _stageItem(item, stageMaxW, stageMaxH),
                                ),
                              ),
                            ),
                          ),
                          const Spacer(),
                          GestureDetector(
                            onTap: () {},
                            child: _actionBar(canSave: canSave, isLocal: isLocal),
                          ),
                          const SizedBox(height: AylaSpacing.sp4), // gap: sp4
                        ],
                      ),
                    ),
                  ),
                  // 关闭钮（40×40，右上 sp4）
                  Positioned(
                    top: AylaSpacing.sp4,
                    right: AylaSpacing.sp4,
                    child: _ViewerCircleButton(
                      size: 40,
                      label: '关闭查看',
                      onPressed: widget.onClose,
                      child: AylaIcon(
                        aylaIconByName('iconClose')!,
                        size: 22,
                        color: AylaColors.indigo700,
                      ),
                    ),
                  ),
                  // 多条目：左右导航（44×44，垂直居中）
                  if (_list.length > 1) ...<Widget>[
                    Positioned(
                      left: AylaSpacing.sp4,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: _ViewerCircleButton(
                          size: 44,
                          label: '上一张',
                          glyph: '‹',
                          onPressed: _index > 0 ? _prev : null,
                          blurSigma: 12, // blur(12px) saturate(1.4)
                        ),
                      ),
                    ),
                    Positioned(
                      right: AylaSpacing.sp4,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: _ViewerCircleButton(
                          size: 44,
                          label: '下一张',
                          glyph: '›',
                          onPressed: _index < _list.length - 1 ? _next : null,
                          blurSigma: 12,
                        ),
                      ),
                    ),
                  ],
                  // 保存失败提示（absolute bottom 76）
                  if (_saveError)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 76,
                      child: Center(
                        child: Semantics(
                          liveRegion: true,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AylaSpacing.sp4,
                              vertical: AylaSpacing.sp2,
                            ),
                            decoration: BoxDecoration(
                              color: AylaColors.overlayDimStrong,
                              borderRadius: AylaRadii.pill,
                            ),
                            child: Text(
                              _saveExpired ? '媒体已过期，无法保存' : '保存失败，请重试',
                              style: const TextStyle(
                                fontFamily: AylaFonts.body,
                                fontFamilyFallback: AylaFonts.cjkFallback,
                                fontSize: 13,
                                color: Color(0xFFFFFFFF),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 条目滑入：enter x = dir*40% → 0、透明度 0→1，250ms --ease-out
  /// （web 的 exit x = dir*-30% 依赖 AnimatePresence 保留旧节点；Flutter 侧不保留，
  /// 只做进入段，已在代码注释与本文件头记录）。
  Widget _slideIn(double stageWidth, Widget child) {
    if (_reduceMotion) return child;
    return AnimatedBuilder(
      animation: _slide,
      builder: (BuildContext context, Widget? inner) {
        final double v = AylaCurves.easeOut.transform(_slide.value);
        return Transform.translate(
          offset: Offset(_direction * 0.4 * (1 - v) * stageWidth, 0),
          child: Opacity(opacity: v.clamp(0.0, 1.0), child: inner),
        );
      },
      child: child,
    );
  }

  /// 舞台条目：本地预览 / 视频 / 图片 / 不可用兜底。
  Widget _stageItem(AylaViewerItem item, double maxW, double maxH) {
    if (item.localPath != null && item.media == null) {
      final String path = item.localPath!;
      if (item.isVideo) {
        // 本地视频预览（未上传）：Flutter 侧播放器接入点见 SignedVideo 注释
        return _fallbackBox('本地视频预览');
      }
      return _mediaFrame(
        maxW,
        maxH,
        child: Image.file(
          File(path),
          fit: BoxFit.contain,
          errorBuilder: (BuildContext c, Object e, StackTrace? s) =>
              _fallbackBox('图片加载失败'),
        ),
      );
    }
    final AylaMediaDescriptor? media = item.media;
    if (media == null) return _fallbackBox('媒体不可用');
    if (media.kind == AylaMediaKind.video) {
      return _ViewerVideo(media: media, maxWidth: maxW, maxHeight: maxH);
    }
    return _mediaFrame(
      maxW,
      maxH,
      child: ResourceImage(
        src: mediaContentUrl(media.mediaId),
        alt: item.alt.isEmpty ? '图片原图' : item.alt,
        fit: BoxFit.contain,
        expiredBadge: true, // 原图已过期 → 角标（web expiredBadge）
        fallback: _fallbackBox('图片加载失败'),
      ),
    );
  }

  /// `.image-viewer-img` / `.image-viewer-video` 的外框：--surface 底 + radius-input(12) +
  /// --card-shadow（图片自身按 contain 决定尺寸，外框只做装饰与裁剪）。
  Widget _mediaFrame(double maxW, double maxH, {required Widget child}) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxW, maxHeight: maxH),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AylaColors.surface,
          borderRadius: BorderRadius.circular(AylaRadii.rInput),
          boxShadow: AylaShadows.card,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AylaRadii.rInput),
          child: child,
        ),
      ),
    );
  }

  /// `.image-viewer-fallback`：padding sp6 sp8 + radius-input + glass-bg-strong + 14px。
  Widget _fallbackBox(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp8,
        vertical: AylaSpacing.sp6,
      ),
      decoration: BoxDecoration(
        color: AylaColors.glassBgStrong,
        borderRadius: BorderRadius.circular(AylaRadii.rInput),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: AylaFonts.body,
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: 14,
          color: AylaColors.textPrimary,
        ),
      ),
    );
  }

  /// `.image-viewer-actions`：pill 玻璃（blur 18 + saturate 1.4）+ 计数 + 保存。
  Widget _actionBar({required bool canSave, required bool isLocal}) {
    return GlassSurface(
      radiusOverride: AylaRadii.pill,
      // blur(18px) saturate(1.4)；嵌入模式置 0 → 不建滤镜层（否则同样糊宿主页）
      blur: widget.embedded ? 0 : AylaGlass.blurNav,
      shadow: const <BoxShadow>[], // actions 无 box-shadow
      border: true,
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp4,
        vertical: AylaSpacing.sp2,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (_list.length > 1)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AylaSpacing.sp2),
              child: Text(
                '${_index + 1}/${_list.length}',
                style: const TextStyle(
                  fontFamily: AylaFonts.utility,
                  fontFamilyFallback: AylaFonts.cjkFallback,
                  fontSize: 12,
                  letterSpacing: 0.5,
                  color: AylaColors.textSecondary,
                ),
              ),
            ),
          Semantics(
            button: true,
            enabled: canSave,
            label: '保存',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: canSave ? () => _save() : null,
              child: Opacity(
                opacity: canSave ? 1 : 0.55, // button:disabled opacity .55
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    AylaIcon(
                      aylaIconByName('iconDownload')!,
                      size: 16,
                      color: AylaColors.textPrimary,
                    ),
                    const SizedBox(width: AylaSpacing.sp1), // gap: sp1
                    Text(
                      _saving ? '保存中…' : (isLocal ? '发送后可保存' : '保存'),
                      style: const TextStyle(
                        fontFamily: AylaFonts.body,
                        fontFamilyFallback: AylaFonts.cjkFallback,
                        fontSize: 15,
                        color: AylaColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 查看器入场：`viewer-in`（opacity 0→1，--dur-fast 180ms --ease-out）。
class _ViewerFadeIn extends StatefulWidget {
  const _ViewerFadeIn({required this.child});

  final Widget child;

  @override
  State<_ViewerFadeIn> createState() => _ViewerFadeInState();
}

class _ViewerFadeInState extends State<_ViewerFadeIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180), // --dur-fast
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: _c, curve: AylaCurves.easeOut),
      child: widget.child,
    );
  }
}

/// `.image-viewer-close` / `.image-viewer-nav`：圆形玻璃钮（40 或 44），
/// hover/focus → --glow-shadow，hover 1.02 / press .98（auroraqua 55–94）。
/// nav 另有 `blur(12px) saturate(1.4)`（close 无）。
class _ViewerCircleButton extends StatefulWidget {
  const _ViewerCircleButton({
    required this.size,
    required this.label,
    this.onPressed,
    this.child,
    this.glyph,
    this.blurSigma,
  });

  final double size;
  final String label;
  final VoidCallback? onPressed;
  final Widget? child;
  final String? glyph;
  final double? blurSigma;

  @override
  State<_ViewerCircleButton> createState() => _ViewerCircleButtonState();
}

class _ViewerCircleButtonState extends State<_ViewerCircleButton> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  bool get _enabled => widget.onPressed != null;

  @override
  Widget build(BuildContext context) {
    final bool reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final BorderRadius r = AylaRadii.pill;

    Widget box = DecoratedBox(
      decoration: BoxDecoration(
        color: AylaColors.glassBgStrong, // --glass-bg-strong
        borderRadius: r,
        border: Border.all(color: AylaColors.glassBorder),
      ),
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: Center(
          child: widget.child ??
              Text(
                widget.glyph ?? '',
                style: const TextStyle(
                  fontFamily: AylaFonts.body,
                  fontFamilyFallback: AylaFonts.cjkFallback,
                  fontSize: 26, // font-size: 26px
                  height: 1,
                  color: AylaColors.indigo700, // color: --indigo-700
                ),
              ),
        ),
      ),
    );

    // nav 的 blur(12px) saturate(1.4)：与面层同 Stack（不新建离屏层，玻璃才有效）
    if (widget.blurSigma != null && !GlassConfig.useOpaqueFallback) {
      box = Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: ClipOval(
              child: BackdropFilter(
                filter: GlassConfig.backdropFilter(sigma: widget.blurSigma!),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          box,
        ],
      );
    }

    // hover/focus → --glow-shadow：只画形状之外（AnimatedOpacity 淡入）
    box = AylaGlassShadow.fadeRing(
      radius: r,
      shadows: AylaShadows.glow,
      visible: _enabled && (_hovered || _focused),
      child: box,
    );
    // hover 1.02 / active .98（200ms --auroraqua-ease）
    if (!reduceMotion) {
      box = AnimatedScale(
        duration: AylaDurations.button,
        curve: AylaCurves.auroraqua,
        scale: !_enabled
            ? 1.0
            : (_pressed ? 0.98 : (_hovered ? 1.02 : 1.0)),
        child: box,
      );
    }

    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.label,
      child: Focus(
        onFocusChange: (bool f) => setState(() => _focused = f),
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() {
            _hovered = false;
            _pressed = false;
          }),
          child: Listener(
            onPointerDown: (_) => setState(() => _pressed = true),
            onPointerUp: (_) => setState(() => _pressed = false),
            onPointerCancel: (_) => setState(() => _pressed = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onPressed,
              child: Opacity(
                opacity: _enabled ? 1 : 0.35, // .image-viewer-nav:disabled { opacity: .35 }
                child: box,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 查看器内视频（web `VideoPlayer` 的状态机）：签名 → 原图过期（阶段 1）只留海报帧 +
/// 「视频已过期」角标；完全过期（阶段 2）→「已过期」占位；失败 → 重试。
///
/// ⚠️ 平台差异（记录在案）：web 用原生 `<video controls autoPlay preload=auto>`（签名 URL
/// Range 流式 + detached 预热接管）；Flutter 侧播放器是 widget，库内 `SignedVideo` 目前只到
/// 「签名 + 状态机」契约（播放器接入点见 media_interaction.dart 注释）→ 这里复用
/// `SignedVideo(controls: true)`，**不另造第二条视频路径**。
class _ViewerVideo extends StatefulWidget {
  const _ViewerVideo({
    required this.media,
    required this.maxWidth,
    required this.maxHeight,
  });

  final AylaMediaDescriptor media;
  final double maxWidth;
  final double maxHeight;

  @override
  State<_ViewerVideo> createState() => _ViewerVideoState();
}

class _ViewerVideoState extends State<_ViewerVideo> {
  String? _posterUrl;
  bool _originalExpired = false;
  bool _expired = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_ViewerVideo old) {
    super.didUpdateWidget(old);
    if (old.media.mediaId != widget.media.mediaId) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _originalExpired = false;
      _expired = false;
      _failed = false;
      _posterUrl = null;
    });
    // 海报帧（thumbnail 变体签名）：缓冲期显示同一帧（web 的 <video poster> 语义）
    final String? thumb = widget.media.thumbnail;
    if (thumb != null && thumb.isNotEmpty) {
      try {
        final SignedMediaResult t =
            await MediaSigner.instance.sign(widget.media.mediaId, variant: MediaVariant.thumb);
        if (mounted) setState(() => _posterUrl = t.url);
      } catch (_) {
        // 海报失败不影响主流程
      }
    }
    try {
      final SignedMediaResult signed =
          await MediaSigner.instance.sign(widget.media.mediaId);
      if (!mounted) return;
      setState(() {
        if (signed.originalExpired) {
          _originalExpired = true; // 阶段 1：只有海报帧可用
        }
      });
    } on MediaExpiredError {
      if (mounted) setState(() => _expired = true); // 阶段 2：完全过期
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_expired) {
      return Semantics(
        liveRegion: true,
        child: _viewerFallbackBox('已过期'),
      );
    }
    if (_originalExpired) {
      return Stack(
        children: <Widget>[
          if (_posterUrl != null)
            _viewerMediaFrame(
              widget.maxWidth,
              widget.maxHeight,
              child: Image.network(_posterUrl!, fit: BoxFit.contain),
            )
          else
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) {
                final double w = c.maxWidth * 0.8 < 640 ? c.maxWidth * 0.8 : 640;
                final double h = c.maxHeight * 0.45 < 360 ? c.maxHeight * 0.45 : 360;
                return SizedBox(width: w, height: h, child: const AylaSkeleton());
              },
            ),
          Positioned(
            top: 8,
            right: 8,
            child: _viewerExpiredBadge('视频已过期'),
          ),
        ],
      );
    }
    if (_failed) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _viewerFallbackBox('视频加载失败'),
          const SizedBox(height: AylaSpacing.sp2),
          _ViewerRetryButton(onTap: () => _load()),
        ],
      );
    }
    // 就绪（或加载中）：复用库内 SignedVideo（签名缓存命中，不重复请求）
    return _viewerMediaFrame(
      widget.maxWidth,
      widget.maxHeight,
      child: SignedVideo(
        mediaId: widget.media.mediaId,
        controls: true, // 查看器显示控制条
        ariaLabel: '视频',
      ),
    );
  }
}

/// `.image-viewer-fallback`（与查看器主类共用外观）。
Widget _viewerFallbackBox(String text) => Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp8,
        vertical: AylaSpacing.sp6,
      ),
      decoration: BoxDecoration(
        color: AylaColors.glassBgStrong,
        borderRadius: BorderRadius.circular(AylaRadii.rInput),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: AylaFonts.body,
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: 14,
          color: AylaColors.textPrimary,
        ),
      ),
    );

/// `.image-viewer-img` / `-video` 的外框（--surface 底 + radius-input + --card-shadow）。
Widget _viewerMediaFrame(double maxW, double maxH, {required Widget child}) =>
    ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxW, maxHeight: maxH),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AylaColors.surface,
          borderRadius: BorderRadius.circular(AylaRadii.rInput),
          boxShadow: AylaShadows.card,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AylaRadii.rInput),
          child: child,
        ),
      ),
    );

/// `.resource-image-expired-badge`（base.css 629–643）：top/right 8、padding 2×8、pill、
/// `rgba(20,24,40,.72)` + blur(6)、白 92%、11/600、line-height 1.6。
Widget _viewerExpiredBadge(String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xB8141828), // rgba(20,24,40,.72)
        borderRadius: AylaRadii.pill,
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: AylaFonts.body,
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          height: 1.6,
          color: Color(0xEBFFFFFF), // rgba(255,255,255,.92)
        ),
      ),
    );

/// `.media-retry`（app.css 1919–1932）：padding sp1 sp3、pill、12/700 indigo-700、
/// 1px `rgba(70,91,146,.35)` 边；hover → `rgba(157,191,230,.18)` 底。
class _ViewerRetryButton extends StatefulWidget {
  const _ViewerRetryButton({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_ViewerRetryButton> createState() => _ViewerRetryButtonState();
}

class _ViewerRetryButtonState extends State<_ViewerRetryButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AylaDurations.fast, // --dur-fast
          curve: AylaCurves.easeOut,
          padding: const EdgeInsets.symmetric(
            horizontal: AylaSpacing.sp3,
            vertical: AylaSpacing.sp1,
          ),
          decoration: BoxDecoration(
            color: _hovered
                ? AylaColors.ice500.withValues(alpha: 0.18)
                : AylaColors.ice500.withValues(alpha: 0),
            borderRadius: AylaRadii.pill,
            border: Border.all(color: const Color(0x59465B92)), // rgba(70,91,146,.35)
          ),
          child: const Text(
            '重试',
            style: TextStyle(
              fontFamily: AylaFonts.body,
              fontFamilyFallback: AylaFonts.cjkFallback,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AylaColors.indigo700,
            ),
          ),
        ),
      ),
    );
  }
}


// ======================= 预览与样张 =======================

/// 查看器样张（组件画布与 @Preview 共用；**单一来源**）。
///
/// 1. 单图（无计数/导航，仅关闭钮 + 保存条）
/// 2. 多图（计数 2/3 + 左右导航 + 保存条）
Widget aylaImageViewerSamples() {
  // 预览/画布：媒体存储链路未落地，启用程序生成的示例图（生产默认关闭）
  aylaEnableSampleMedia();
  const List<AylaViewerItem> items = <AylaViewerItem>[
    AylaViewerItem(
      media: AylaMediaDescriptor(
        mediaId: 'view-1',
        kind: AylaMediaKind.image,
        mimeType: 'image/png',
        thumbnail: '/api/v1/media/view-1/thumbnail',
      ),
      alt: '单图样张',
    ),
    AylaViewerItem(
      media: AylaMediaDescriptor(
        mediaId: 'view-2',
        kind: AylaMediaKind.image,
        mimeType: 'image/jpeg',
        thumbnail: '/api/v1/media/view-2/thumbnail',
      ),
      alt: '多图样张 2',
    ),
    AylaViewerItem(
      media: AylaMediaDescriptor(
        mediaId: 'view-3',
        kind: AylaMediaKind.image,
        mimeType: 'image/png',
        thumbnail: '/api/v1/media/view-3/thumbnail',
      ),
      alt: '多图样张 3',
    ),
  ];

  Widget box(String label, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            style: const TextStyle(
              fontFamily: AylaFonts.utility,
              fontFamilyFallback: AylaFonts.cjkFallback,
              fontSize: 11,
              color: AylaColors.textSecondary,
            ),
          ),
          const SizedBox(height: AylaSpacing.sp2),
          SizedBox(width: 520, height: 560, child: child),
        ],
      );

  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp6),
    child: Wrap(
      spacing: AylaSpacing.sp6,
      runSpacing: AylaSpacing.sp6,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: <Widget>[
        box(
          '单图（仅关闭钮 + 保存条）',
          AylaImageViewer(
            items: <AylaViewerItem>[items.first],
            onClose: () {},
            alt: '单图样张',
            embedded: true, // 组件画布内嵌：不糊画布
          ),
        ),
        box(
          '多图（计数 2/3 + 左右导航）',
          AylaImageViewer(
            items: items,
            initialIndex: 1,
            onClose: () {},
            embedded: true,
          ),
        ),
      ],
    ),
  );
}

/// 查看器预览。
@Preview(
  group: 'Cards',
  name: 'AylaImageViewer 单图 / 多图',
  size: Size(1220, 760),
  wrapper: previewScope,
)
Widget aylaImageViewerPreview() => aylaImageViewerSamples();
