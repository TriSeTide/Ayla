/// 媒体消息渲染（`components/chat/MediaContent.tsx` 的 Flutter 等价）。
///
/// ## 事实源
///
/// | 本文件 | web |
/// |---|---|
/// | [AylaMediaContent] | `MediaContent.tsx:759–870`（descriptor 归一 + 类型分派） |
/// | [_MediaPlaceholder] | tsx 50–78 + app.css 1899–1932（`.media-placeholder` / `.media-retry`） |
/// | [aylaMediaFrameSize] | tsx 86–97 `mediaFrameStyle`（max 320 约束、**不放大**、发送即占最终尺寸） |
/// | [_ImageMedia] | tsx 99–148 + app.css 1393–1511 |
/// | [_VideoFrame] / [_VideoMedia] | tsx 161–346 + app.css 1414–1456 |
/// | [_MixedMedia] | tsx 355–480 + app.css 1934–1979 + 2328–2355（`.mention-token`） |
/// | [_VoiceMedia] | tsx 484–685 + app.css 1520–1639 |
/// | [_FileMedia] | tsx 689–755 + app.css 1839–1897 |
///
/// ## 有意偏离（登记，勿再当成漏做）
/// 1. **视频预热**：web `warmUpVideoElement` 预建 detached `<video>` 抢缓冲；Flutter 无
///    detached 播放内核可复用（播放器是 widget，且平台视图不能游离于树外）⇒ 不实现，
///    点击进查看器时才打开播放器；
/// 2. **播放控制条**：web 是浏览器原生 `<video controls>`（UA 样式，CSS 不可控）⇒ 库内
///    自绘，度量取自 `.voice-play` / `.voice-seek`（见 `player/vod_player.dart` 文件头）；
/// 3. **查看器宿主**：web 用 `createPortal(document.body)`；Flutter 用 root Overlay
///    （`aylaOverlayEntry`，与弹幕图片查看器同一先例）。
///
/// ## 数据边界
/// 组件**不拥有**会话状态：descriptor 补拉走 [AylaMediaContent.descriptorFetcher]
/// （默认 dio 直连后端 `/media/{id}/`），拉回后经 [AylaMediaContent.onDescriptorFetched]
/// 交回持有方（等价 web `useMessageStore.mergeMedia`），组件自身只做本地投影。
///
/// ## 公开面
/// `AylaMediaContent` · `AylaMediaRetryButton` · 样张 `aylaMediaContentSamples()`

library;

import 'dart:async';
import 'dart:io' show File;
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/media/audio_playback.dart';
import '../../core/media/media_cache.dart';
import '../../core/media/media_download.dart';
import '../../core/media/media_download_queue.dart';
import '../../core/media/media_signer.dart';
import '../../core/media/media_validation.dart';
import '../../core/models/chat_message.dart';
import '../../core/models/media_kind.dart';
import '../../core/models/post.dart' show AylaMediaDescriptor;
import '../../core/net/dio_client.dart';
import '../../player/vod_player.dart';
import '../../theme/app_icons.dart';
import '../../theme/glass.dart';
import '../../theme/sample_media.dart';
import '../../theme/tokens.dart';
import '../base/fit_content.dart';
import 'image_viewer.dart';
import '../base/loading.dart';
import '../base/overlays.dart';
import '../base/resource_image.dart';
import '../base/tooltip.dart';

// =================== 语音卡的 max-content 常量 ===================
//
// 为什么需要显式的「自然宽」常量（2026-10-22 二轮，真机实报「语音气泡撑满整行」）：
// CSS 的 `flex:1` 项在 intrinsic 趟贡献的是**自身 max-content**，Flutter 的
// `Expanded` 在无界主轴下无定义（`RenderFlex` 会断言
// 「children have non-zero flex but incoming width constraints are unbounded」）。
// ⇒ 这几个常量把「浏览器实际取到的 max-content」写死，由 [AylaInlineSize] 使用
// （见 widgets/base/fit_content.dart）。
// 数值全部来自 Chrome 实测 / 后端常量推导，**不得估计**。

/// `.voice-wave` 的高度（app.css:1551–1557 `height: 36px`）。
const double kAylaVoiceWaveHeight = 36;

/// 有波形时 `.voice-wave` 的 **max-content** 宽。
///
/// 推导（可逐条验证）：
/// - 波形 PNG 固有尺寸恒为 **480×120** —— 后端
///   `Ayla/backend/apps/media/derivatives.py:22–23` 的
///   `WAVEFORM_WIDTH = 480` / `WAVEFORM_HEIGHT = 120`；
/// - `.voice-wave` 被 `height: 36px` 定高（app.css:1554）⇒ 保持固有比例时
///   max-content 宽 = 36 × 480 ÷ 120 = **144**；
/// - Chrome 实测 `.voice-wave` 宽 **144**（`.voice-card-main` 232.19
///   = 40 + 12 + 144 + 12 + 24.19），与本式一致。
const double kAylaVoiceWaveNaturalWidth = 144;

/// 无波形时 `.voice-wave` 的 max-content 宽。
///
/// web 降级分支（`MediaContent.tsx:645–651`）是 `.voice-wave` 的 `<span>`
/// 里放 18×18 图标 ⇒ 内容宽 18（`display:grid; place-items:center`）。
const double kAylaVoiceWaveFallbackWidth = 18;

/// `.voice-seek`（range input）的 max-content 宽。
///
/// web `.voice-seek { flex:1; min-width:0; appearance:none; height:14px }`
/// （app.css:1574–1581）⇒ 无界档取 UA 给 range 的固有宽。Chrome 实测：
/// `appearance:none` 的 `input[type=range]` 在 `width:max-content` 下为 **135**；
/// 进度整行 = 135 + 8（gap）+ 34（`.voice-cur{min-width:34}`）= **177**（实测 177）。
const double kAylaVoiceSeekNaturalWidth = 135;

// ======================= 入口 =======================

/// descriptor 拉取契约（web `fetchMediaDescriptor`）；null 返回 = 不可用。
typedef AylaMediaDescriptorFetcher = Future<AylaMediaDescriptor?> Function(
  String mediaId,
);

/// 媒体消息体（图片 / 表情 / 视频 / 语音 / 文件 / 图文混排）。
class AylaMediaContent extends StatefulWidget {
  const AylaMediaContent({
    super.key,
    required this.msg,
    this.descriptorFetcher,
    this.onDescriptorFetched,
    this.audioEngineFactory,
    this.vodPlayerFactory,
    this.onMentionTap,
    this.onDownloaded,
    this.onSaveError,
    this.currentUserId,
  });

  /// 消息（媒体消息；`mixed` 走 segments 分支）。
  final AylaChatMessage msg;

  /// descriptor 补拉（null = dio 直连后端 `/media/{id}/`）。
  final AylaMediaDescriptorFetcher? descriptorFetcher;

  /// 拉回 descriptor 后交回持有方（合并进 store，避免滚动重渲染重复拉取）。
  final void Function(AylaMediaDescriptor media)? onDescriptorFetched;

  /// 音频引擎工厂（null = media_kit 实现；测试/预览注入替身）。
  final AylaAudioEngine Function()? audioEngineFactory;

  /// 点播播放器工厂（null = 按平台创建；测试/预览注入替身）。
  final VodPlayerFactory? vodPlayerFactory;

  /// `mention` 段点击（web `goUserProfile`）—— 导航属页面层，未接线时按钮仍渲染。
  final void Function(String userId)? onMentionTap;

  /// 文件下载完成（web 由浏览器托管；Flutter 侧把落盘路径交回调用方提示）。
  final void Function(String savedPath)? onDownloaded;

  /// 文件下载失败（不伪造成功）。
  final void Function(String detail)? onSaveError;

  /// 当前登录用户 id（混排 `mention` 段的「@我」高亮判定；null = 不判定）。
  final String? currentUserId;

  @override
  State<AylaMediaContent> createState() => _AylaMediaContentState();
}

class _AylaMediaContentState extends State<AylaMediaContent> {
  AylaMediaDescriptor? _media;
  bool _failed = false;
  int _retryKey = 0;
  int _fetchSeq = 0;

  @override
  void initState() {
    super.initState();
    _media = widget.msg.media;
  }

  @override
  void didUpdateWidget(covariant AylaMediaContent old) {
    super.didUpdateWidget(old);
    if (old.msg.id != widget.msg.id) {
      // 换消息（复用组件实例）时重置拉取状态（tsx 774–779）
      _media = widget.msg.media;
      _failed = false;
      _retryKey = 0;
    } else if (widget.msg.media != null && _media != widget.msg.media) {
      _media = widget.msg.media;
      _failed = false;
    }
  }

  /// WS 帧路径：只有 media_id → 异步补拉 descriptor（tsx 781–804）。
  void _ensureFetched() {
    if (_media != null || _failed) return;
    final String? mediaId = widget.msg.mediaId;
    if (mediaId == null || mediaId.isEmpty) {
      // 既无 descriptor 也无 media_id：无法渲染（tsx 785–788）
      _failed = true;
      return;
    }
    final int seq = ++_fetchSeq;
    final AylaMediaDescriptorFetcher fetcher =
        widget.descriptorFetcher ?? _defaultFetcher;
    fetcher(mediaId).then((AylaMediaDescriptor? desc) {
      if (!mounted || seq != _fetchSeq) return;
      if (desc == null) {
        setState(() => _failed = true);
        return;
      }
      setState(() {
        _media = desc;
        _failed = false;
      });
      widget.onDescriptorFetched?.call(desc);
    }).catchError((Object _) {
      if (!mounted || seq != _fetchSeq) return;
      setState(() => _failed = true);
    });
  }

  static Future<AylaMediaDescriptor?> _defaultFetcher(String mediaId) async {
    final Map<String, dynamic> raw = await DioClient.instance
        .get<Map<String, dynamic>>('/media/${Uri.encodeComponent(mediaId)}/');
    return AylaMediaDescriptor.fromJson(raw);
  }

  @override
  Widget build(BuildContext context) {
    // ⚠️ 这层 `Align` 有**两条**语义，缺一不可：
    // ① **松横向紧约束**：本族媒体帧/卡片的宽度是**内容尺寸**（图片长边 max 320、表情 96、
    //    语音 min 240、文件 240–320、混排媒体段 180/240），而 `SizedBox(width:)` /
    //    `ConstrainedBox(maxWidth:)` 都走 `constraints.enforce` —— 宿主给紧宽时（被
    //    `Expanded`、竖向滚动视图的紧宽、画布的 `SizedBox` 包住）会被夹回宿主宽
    //    （13 号 §五「CSS 的 width 是权威的，但 Flutter `SizedBox(width:)` 不是」）；
    // ② **自身必须收缩到 child 尺寸**（`widthFactor/heightFactor = 1`）：`Align` 的
    //    shrink-wrap 只在**无界**约束下自动生效，父级给有限宽时它会撑满可用宽
    //    ⇒ 气泡里图片右侧留一大片空白（实测「图片气泡大了，导致气泡有空白」）。
    //    两个 factor = 1 让自身尺寸恰为 child 尺寸，同时 child 仍拿 loosened 约束。
    // ⚠️ 别照抄 `live_studio.dart` 的 `Align`（那是「撑满容器」语义，故意不收缩）。
    return Align(
      alignment: Alignment.topLeft,
      widthFactor: 1,
      heightFactor: 1,
      child: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final AylaMessageType? kind = widget.msg.type;

    // 图文混排：按 segments 渲染，无需单媒体 descriptor（tsx 810–812）
    if (kind == AylaMessageType.mixed) {
      return _MixedMedia(
        msg: widget.msg,
        onMentionTap: widget.onMentionTap,
        vodPlayerFactory: widget.vodPlayerFactory,
        currentUserId: widget.currentUserId,
      );
    }

    const Set<AylaMessageType> singleKinds = <AylaMessageType>{
      AylaMessageType.image,
      AylaMessageType.emoji,
      AylaMessageType.voice,
      AylaMessageType.file,
      AylaMessageType.video,
    };
    if (kind == null || !singleKinds.contains(kind)) {
      return const _MediaPlaceholder(state: _PlaceholderState.unknown, label: '媒体');
    }

    _ensureFetched();

    // 乐观文件消息（descriptor 未就绪，上传中/失败）：本地文件名 + 大小（tsx 822–839）
    if (kind == AylaMessageType.file && _media == null) {
      final AylaLocalMediaPreview? local = _localFile();
      if (local != null) {
        return _FileCard(
          name: local.fileName ?? '附件',
          size: local.fileSize,
        );
      }
    }

    if (_failed) {
      return _MediaPlaceholder(
        state: _PlaceholderState.error,
        label: _typeLabel(kind),
        onRetry: () {
          setState(() {
            _failed = false;
            _retryKey++;
          });
        },
      );
    }

    final AylaMediaDescriptor? media = _media;
    if (media == null) {
      return _MediaPlaceholder(
        state: _PlaceholderState.loading,
        label: _typeLabel(kind),
      );
    }

    // `_retryKey` 参与 key：重试时重建子件（等价 web 的重试计数触发重新签发）
    switch (kind) {
      case AylaMessageType.image:
        return _ImageMedia(
          key: ValueKey<int>(_retryKey),
          msg: widget.msg,
          media: media,
          isEmoji: false,
          vodPlayerFactory: widget.vodPlayerFactory,
        );
      case AylaMessageType.emoji:
        return _ImageMedia(
          key: ValueKey<int>(_retryKey),
          msg: widget.msg,
          media: media,
          isEmoji: true,
          vodPlayerFactory: widget.vodPlayerFactory,
        );
      case AylaMessageType.video:
        return _VideoMedia(
          key: ValueKey<int>(_retryKey),
          msg: widget.msg,
          media: media,
          vodPlayerFactory: widget.vodPlayerFactory,
        );
      case AylaMessageType.voice:
        return _VoiceMedia(
          key: ValueKey<String>(media.mediaId),
          media: media,
          audioEngineFactory: widget.audioEngineFactory,
        );
      case AylaMessageType.file:
        return _FileMedia(
          key: ValueKey<int>(_retryKey),
          msg: widget.msg,
          media: media,
          onDownloaded: widget.onDownloaded,
          onSaveError: widget.onSaveError,
        );
      case AylaMessageType.text:
      case AylaMessageType.mixed:
      case AylaMessageType.system:
      case AylaMessageType.poke:
      case AylaMessageType.share:
        return const _MediaPlaceholder(state: _PlaceholderState.unknown, label: '媒体');
    }
  }

  AylaLocalMediaPreview? _localFile() {
    for (final AylaLocalMediaPreview item in widget.msg.localMedia) {
      if (item.kind == AylaMediaKind.file) return item;
    }
    return null;
  }

  /// `typeLabel`（tsx 806–807）。
  static String _typeLabel(AylaMessageType kind) => switch (kind) {
        AylaMessageType.image => '图片',
        AylaMessageType.emoji => '表情',
        AylaMessageType.voice => '语音',
        AylaMessageType.video => '视频',
        AylaMessageType.mixed => '图文消息',
        _ => '文件',
      };
}

// ======================= 占位 =======================

enum _PlaceholderState { loading, error, unknown }

/// `.media-placeholder`（app.css 1899–1917 + `.failed` 1914–1917）。
class _MediaPlaceholder extends StatelessWidget {
  const _MediaPlaceholder({
    required this.state,
    required this.label,
    this.onRetry,
  });

  final _PlaceholderState state;
  final String label;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final bool failed = state != _PlaceholderState.loading;
    final String text = switch (state) {
      _PlaceholderState.loading => '$label加载中…',
      _PlaceholderState.unknown => '暂不支持的$label类型',
      _PlaceholderState.error => '$label加载失败',
    };
    return Semantics(
      label: state == _PlaceholderState.loading ? '$label加载中' : null,
      child: Container(
        constraints: const BoxConstraints(minWidth: 200, minHeight: 56),
        padding: const EdgeInsets.all(AylaSpacing.sp3),
        decoration: BoxDecoration(
          color: AylaColors.glassBg,
          borderRadius: BorderRadius.circular(AylaRadii.rInput),
          border: Border.all(
            color: failed
                ? const Color(0x59D64D6E) // rgba(214,77,110,.35)
                : AylaColors.glassBorder,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (state == _PlaceholderState.loading)
              const AylaSkeleton(width: 36, height: 36, radius: 10)
            else
              const SizedBox.shrink(),
            if (state == _PlaceholderState.loading)
              const SizedBox(width: AylaSpacing.sp3),
            Flexible(
              child: Text(
                text,
                style: TextStyle(
                  fontFamily: AylaFonts.body,
                  fontFamilyFallback: AylaFonts.cjkFallback,
                  fontSize: 13,
                  color: failed ? AylaColors.destructive : AylaColors.textSecondary,
                ),
              ),
            ),
            if (onRetry != null && state != _PlaceholderState.unknown) ...<Widget>[
              const SizedBox(width: AylaSpacing.sp3),
              AylaMediaRetryButton(onTap: onRetry!),
            ],
          ],
        ),
      ),
    );
  }
}

/// `.media-retry`（app.css 1919–1932）：pill + 12/700 + indigo 字 + 1px indigo 边；
/// hover → `rgba(157,191,230,.18)` 底。
class AylaMediaRetryButton extends StatefulWidget {
  const AylaMediaRetryButton({
    super.key,
    required this.onTap,
    this.label = '重试',
    this.enabled = true,
  });

  final VoidCallback onTap;
  final String label;
  final bool enabled;

  @override
  State<AylaMediaRetryButton> createState() => _AylaMediaRetryButtonState();
}

class _AylaMediaRetryButtonState extends State<AylaMediaRetryButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.enabled ? widget.onTap : null,
        child: Semantics(
          button: true,
          label: widget.label,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AylaSpacing.sp3,
              vertical: AylaSpacing.sp1,
            ),
            decoration: BoxDecoration(
              color: _hovered && widget.enabled
                  ? const Color(0x2E9DBFE6) // rgba(157,191,230,.18)
                  : null,
              borderRadius: BorderRadius.circular(AylaRadii.rPill),
              border: Border.all(color: const Color(0x59465B92)), // rgba(70,91,146,.35)
            ),
            child: Text(
              widget.label,
              style: const TextStyle(
                fontFamily: AylaFonts.body,
                fontFamilyFallback: AylaFonts.cjkFallback,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AylaColors.indigo700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ======================= 图片 / 表情 =======================

/// 媒体帧最终尺寸（web `mediaFrameStyle`，tsx 86–97）：
/// `scale = min(320/w, 320/h, 1)`（**不放大**）；宽高缺失 → 320 × 4:3。
({double width, double height}) aylaMediaFrameSize(AylaMediaDescriptor media) {
  final int w = media.width ?? 0;
  final int h = media.height ?? 0;
  if (w > 0 && h > 0) {
    final double scale = math.min(math.min(320 / w, 320 / h), 1);
    final double dw = (w * scale).roundToDouble();
    final double dh = (h * scale).roundToDouble();
    return (width: dw, height: dh);
  }
  return (width: 320, height: 320 * 3 / 4);
}

/// 图片/表情消息（tsx 99–148）。
class _ImageMedia extends StatefulWidget {
  const _ImageMedia({
    super.key,
    required this.msg,
    required this.media,
    required this.isEmoji,
    this.vodPlayerFactory,
  });

  final AylaChatMessage msg;
  final AylaMediaDescriptor media;
  final bool isEmoji;
  final VodPlayerFactory? vodPlayerFactory;

  @override
  State<_ImageMedia> createState() => _ImageMediaState();
}

class _ImageMediaState extends State<_ImageMedia> {
  final _MediaViewerHost _viewer = _MediaViewerHost();

  @override
  void dispose() {
    _viewer.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String label = widget.isEmoji ? '表情' : '图片';
    final AylaMediaDescriptor media = widget.media;
    // 气泡内用缩略图；GIF 例外（缩略图是静帧会丢动图）→ 走原图（tsx 109–115）
    final bool isGif = media.mimeType == 'image/gif';
    final bool useThumb = !widget.isEmoji && !isGif && media.thumbnail != null;
    final String src = useThumb
        ? media.thumbnail!
        : mediaContentUrl(media.mediaId);

    final ({double width, double height}) size = widget.isEmoji
        ? (width: 96, height: 96)
        : aylaMediaFrameSize(media);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // `width: <dw>px; max-width: 100%` —— 容器发送即占最终尺寸，加载后不改变高度
        final double w = math.min(size.width, c.maxWidth);
        final double h = size.height * (w / size.width);
        return SizedBox(
          width: w,
          height: h,
          child: AylaCardInteraction(
            interactive: false,
            focusRingColor: AylaColors.glow500,
            focusRingRadius: BorderRadius.circular(AylaRadii.rInput),
            semanticLabel: '查看$label原图',
            onTap: () => _viewer.open(
              context,
              media: media,
              alt: _caption(widget.msg).isEmpty ? label : _caption(widget.msg),
            ),
            builder: (BuildContext ctx, bool hovered) => ClipRRect(
              borderRadius: BorderRadius.circular(AylaRadii.rInput),
              // `.media-frame`：--surface 底（图片态是 --glass-bg）+ overflow hidden
              child: ColoredBox(
                color: AylaColors.glassBg,
                child: MouseRegion(
                  cursor: SystemMouseCursors.zoomIn,
                  child: AylaResourceImage(
                    src: src,
                    alt: _caption(widget.msg).isEmpty ? label : _caption(widget.msg),
                    fit: BoxFit.cover,
                    width: w,
                    height: h,
                    variant: useThumb ? MediaVariant.thumb : null,
                    expiredBadge: !useThumb,
                    fallback: const AylaSkeleton(),
                    // 用户裁决 2026-10-23：**表情消息**（isEmoji）的媒体是
                    // **永久资产 A2**（表情包，MinIO 永不删）=> 不落本地缓存。
                    // 聊天里的普通图片走 E1（7/30 天过期）=> 保持缓存。
                    // 同一组件两个分支语义相反，别一刀切。
                    cacheable: !widget.isEmoji,
                    // 落盘扩展名按真实 mime 推导（PNG/WebP/GIF 不要记成 .jpg）
                    mediaMimeType: media.mimeType,
                    // descriptor 已知完全过期 ⇒ 直接占位，省一次必然 410 的 :sign
                    knownExpired: media.expired,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ======================= 视频 =======================

/// 视频消息（tsx 332–346）：内联帧 + 播放键，点击进查看器。
class _VideoMedia extends StatefulWidget {
  const _VideoMedia({
    super.key,
    required this.msg,
    required this.media,
    this.vodPlayerFactory,
  });

  final AylaChatMessage msg;
  final AylaMediaDescriptor media;
  final VodPlayerFactory? vodPlayerFactory;

  @override
  State<_VideoMedia> createState() => _VideoMediaState();
}

class _VideoMediaState extends State<_VideoMedia> {
  final _MediaViewerHost _viewer = _MediaViewerHost();

  @override
  void dispose() {
    _viewer.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ({double width, double height}) size = aylaMediaFrameSize(widget.media);
    return _VideoFrame(
      media: widget.media,
      size: size,
      ariaLabel: '查看视频',
      vodPlayerFactory: widget.vodPlayerFactory,
      onOpen: () => _viewer.open(
        context,
        media: widget.media,
        alt: _caption(widget.msg).isEmpty ? '视频' : _caption(widget.msg),
        isVideo: true,
      ),
    );
  }
}

/// 视频帧块（tsx 161–330）：本地预览 / 海报帧 / 无海报降级首帧 / 过期 / 失败。
class _VideoFrame extends StatefulWidget {
  const _VideoFrame({
    required this.media,
    required this.size,
    required this.onOpen,
    this.localPath,
    this.ariaLabel = '查看视频',
    this.vodPlayerFactory,
  });

  final AylaMediaDescriptor? media;
  final ({double width, double height}) size;
  final VoidCallback onOpen;
  final String? localPath;
  final String ariaLabel;
  final VodPlayerFactory? vodPlayerFactory;

  @override
  State<_VideoFrame> createState() => _VideoFrameState();
}

class _VideoFrameState extends State<_VideoFrame> {
  String? _videoSrc;
  bool _failed = false;
  bool _expired = false;
  bool _hovered = false;
  int _retryKey = 0;

  bool get _hasPoster => widget.media?.thumbnail != null;

  @override
  void initState() {
    super.initState();
    _resolveSource();
  }

  @override
  void didUpdateWidget(covariant _VideoFrame old) {
    super.didUpdateWidget(old);
    if (old.media?.mediaId != widget.media?.mediaId ||
        old.localPath != widget.localPath) {
      _resolveSource();
    }
  }

  /// 源选择（tsx 189–226）：本地预览直接可用；有海报帧不签 original；
  /// 否则签 original 拉首帧（`MediaExpiredError` → 过期态）。
  void _resolveSource() {
    if (widget.localPath != null) {
      setState(() {
        _videoSrc = widget.localPath;
        _failed = false;
        _expired = false;
      });
      return;
    }
    setState(() {
      _videoSrc = null;
      _failed = false;
      _expired = false;
    });
    final AylaMediaDescriptor? media = widget.media;
    if (media == null) {
      setState(() => _failed = true);
      return;
    }
    // ④ descriptor 已告诉我们「完全过期」⇒ 直接占位，**不白跑一次 :sign**
    //    （2026-10-29 新增 descriptor.expired 投影）。
    if (media.expired) {
      setState(() => _expired = true);
      return;
    }
    // ⑤ 阶段 1（视频本体已删、只剩海报帧）：
    //    · 有海报 → 直接渲染海报 + 「视频已过期」角标（下方 _buildContent 的海报分支）；
    //    · 无海报 → 没有任何可显示对象 ⇒ 过期占位（不签 original，必然 410）。
    if (media.originalExpired) {
      if (!_hasPoster) setState(() => _expired = true);
      return;
    }
    if (_hasPoster) return;
    _signOriginal(media);
  }

  Future<void> _signOriginal(AylaMediaDescriptor media) async {
    try {
      // ① 本地漫游缓存优先：命中就直接用本地文件当视频源，不发网络请求；
      //    本地有就永远能看，云端过期不影响（用户裁决 D3）。
      final File? cached = await AylaMediaCache.instance.lookup(
        media.mediaId,
        kind: AylaMediaKind.video,
        mimeType: media.mimeType,
      );
      if (!mounted) return;
      if (cached != null) {
        setState(() {
          _videoSrc = cached.path;
          _failed = false;
          _expired = false;
        });
        return;
      }
      final SignedMediaResult result =
          await MediaSigner.instance.sign(media.mediaId);
      if (!mounted) return;
      setState(() {
        _videoSrc = result.url;
        _failed = false;
      });
      // ② **不落盘**（用户裁决 2026-10-23：视频改成「点击播放才存」）。
      //
      //    用户原话：「视频改成『点击播放才存』，但视频首帧缩略图是看见就存」。
      //
      //    旧代码（D4「加载即存」）在**签完 original 就**把整片视频下载落盘 ——
      //    只要消息进视口就吃掉几十 MB 带宽与磁盘，而用户从没点过播放。
      //
      //    本方法只在「没有首帧海报」时被调用（见 [_resolveSource]），目的是
      //    **给气泡取一帧画面**，不是播放 ⇒ 不该落盘。
      //
      //    真正的落盘时机：用户点开查看器播放（`image_viewer.dart` 的
      //    `_ViewerVideo` → `AylaSignedVideo(cacheable: true)`）。
      //
      //    ✅ 首帧缩略图（poster）不受影响：`_buildContent` 的 `_hasPoster` 分支
      //    走 `AylaResourceImage(cacheable: 默认 true)` ⇒「看见就存 thumb」照旧。
    } on MediaExpiredError {
      if (!mounted) return;
      setState(() => _expired = true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  void _retry() {
    final AylaMediaDescriptor? media = widget.media;
    if (media != null) MediaSigner.instance.invalidate(media.mediaId);
    setState(() {
      _failed = false;
      _retryKey++;
    });
    _resolveSource();
  }

  @override
  Widget build(BuildContext context) {
    final double w = widget.size.width;
    final double h = widget.size.height;
    return SizedBox(
      width: w,
      height: h,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AylaRadii.rInput),
        child: ColoredBox(
          color: AylaColors.surface,
          child: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_expired) return const _VideoLoadFailed(text: '已过期');
    if (_failed) return _VideoLoadFailed(text: '视频加载失败', onRetry: _retry);

    final Widget? content = _buildContent();
    if (content == null) return const AylaSkeleton();

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: AylaCardInteraction(
            interactive: false,
            focusRingColor: AylaColors.glow500,
            focusRingRadius: BorderRadius.circular(AylaRadii.rInput),
            semanticLabel: widget.ariaLabel,
            onTap: widget.onOpen,
            builder: (BuildContext ctx, bool focused) => content,
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: Center(
              child: _PlayBadge(hovered: _hovered),
            ),
          ),
        ),
      ],
    );
  }

  /// 画面来源（tsx 253–328 的四个分支）。
  Widget? _buildContent() {
    if (widget.localPath != null) {
      return AylaVodVideo(
        key: ValueKey<int>(_retryKey),
        src: widget.localPath!,
        fit: BoxFit.cover,
        playerFactory: widget.vodPlayerFactory,
      );
    }
    final AylaMediaDescriptor? media = widget.media;
    if (media == null) return null;
    // 海报帧封面直连秒出（`object-fit: cover` 由 .media-video 提供）
    if (_hasPoster) {
      final Widget poster = AylaResourceImage(
        src: media.thumbnail!,
        alt: '',
        fit: BoxFit.cover,
        variant: MediaVariant.thumb,
        fallback: const AylaSkeleton(),
      );
      // 阶段 1（视频本体已删、只剩海报帧）：与图片「原图已过期」对齐，
      // 叠加「视频已过期」角标，且播放键不再出现（点开只会得到一张静帧）。
      if (media.originalExpired) {
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            poster,
            const Positioned(
              top: 6,
              right: 6,
              child: _VideoExpiredBadge(),
            ),
          ],
        );
      }
      return poster;
    }
    final String? src = _videoSrc;
    if (src == null) return null;
    return AylaVodVideo(
      key: ValueKey<int>(_retryKey),
      src: src,
      fit: BoxFit.cover,
      playerFactory: widget.vodPlayerFactory,
    );
  }
}

/// 「视频已过期」角标（阶段 1：本体已删、海报帧仍在）。
///
/// 视觉对齐图片的 `.resource-image-expired-badge`（玻璃胶囊 + 次要文字色），
/// 用同一个 `AylaColors.textSecondary` / `AylaRadii` 令牌，不另造样式。
class _VideoExpiredBadge extends StatelessWidget {
  const _VideoExpiredBadge();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '视频已过期',
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AylaSpacing.sp6,
          vertical: AylaSpacing.sp2,
        ),
        decoration: BoxDecoration(
          color: AylaColors.glassBgStrong,
          borderRadius: BorderRadius.circular(AylaRadii.rPill),
        ),
        child: const Text(
          '视频已过期',
          style: TextStyle(
            fontSize: 11,
            color: AylaColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// `.video-play-badge`（app.css 1423–1444）：48 圆 + strong 玻璃 + blur8 sat1.4 +
/// 1px 亮边 + indigo 图标 + `--card-shadow`；hover（在父按钮上）→ 1.06 + `--glow-shadow`。
class _PlayBadge extends StatelessWidget {
  const _PlayBadge({required this.hovered});

  final bool hovered;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: hovered ? 1.06 : 1.0,
      duration: AylaDurations.fast,
      curve: AylaCurves.easeOut,
      child: AnimatedContainer(
        duration: AylaDurations.fast,
        curve: AylaCurves.easeOut,
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: AylaColors.glassBgStrong,
          shape: BoxShape.circle,
          border: Border.all(color: AylaColors.glassBorder),
          boxShadow: hovered ? AylaShadows.glow : AylaShadows.card,
        ),
        child: ClipOval(
          // ClipOval 不能由 BorderRadius 表达 ⇒ 外层保留；预模糊档下
          // AylaGlassBackdrop 会把图标挪到采样层之上。
          child: AylaGlassBackdrop(
            filter: AylaGlassConfig.backdropFilter(sigma: AylaGlass.blurButton),
            // web «MediaContent.tsx:249» 的 «<IconPlay width={22} height={22} />»
            // （lucide 描边三角）——此前用 Material 实心三角占位。
            child: Center(
              child: AylaIcon(
                aylaIconByName('iconPlay')!,
                size: 22,
                color: AylaColors.indigo700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.video-load-failed`（app.css 1446–1456）。
class _VideoLoadFailed extends StatelessWidget {
  const _VideoLoadFailed({required this.text, this.onRetry});

  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 120),
      padding: const EdgeInsets.all(AylaSpacing.sp3),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Text(
            text,
            style: const TextStyle(
              fontFamily: AylaFonts.body,
              fontFamilyFallback: AylaFonts.cjkFallback,
              fontSize: 13,
              color: AylaColors.textSecondary,
            ),
          ),
          if (onRetry != null) ...<Widget>[
            const SizedBox(height: AylaSpacing.sp2),
            AylaMediaRetryButton(onTap: onRetry!),
          ],
        ],
      ),
    );
  }
}

// ======================= 图文混排 =======================

/// 混排消息（tsx 355–480）：文本段流式排列 + `mention` 胶囊 + 图片/视频段
/// （多图自动换行成网格；同消息内 image/video 共享查看器可左右切换）。
class _MixedMedia extends StatefulWidget {
  const _MixedMedia({
    required this.msg,
    this.onMentionTap,
    this.vodPlayerFactory,
    this.currentUserId,
  });

  final AylaChatMessage msg;
  final void Function(String userId)? onMentionTap;
  final VodPlayerFactory? vodPlayerFactory;

  /// 当前登录用户 id（「@我」高亮判定，`MediaContent.tsx:356` currentUserId）。
  final String? currentUserId;

  @override
  State<_MixedMedia> createState() => _MixedMediaState();
}

class _MixedMediaState extends State<_MixedMedia> {
  final _MediaViewerHost _viewer = _MediaViewerHost();

  @override
  void dispose() {
    _viewer.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<AylaMediaSegment> segments = widget.msg.segments;
    if (segments.isEmpty) {
      return const _MediaPlaceholder(
        state: _PlaceholderState.unknown,
        label: '图文消息',
      );
    }

    // 媒体段（image/video）序列 = 查看器条目序（mention/text 段不参与，tsx 359–363）
    final List<AylaMediaSegment> mediaSegs = segments
        .where((AylaMediaSegment s) =>
            s.type == AylaSegmentType.image || s.type == AylaSegmentType.video)
        .toList(growable: false);
    // 媒体段按序对应本地预览（乐观消息；tsx 366–373）
    final List<AylaLocalMediaPreview?> locals = <AylaLocalMediaPreview?>[
      for (int i = 0; i < mediaSegs.length; i++)
        i < widget.msg.localMedia.length ? widget.msg.localMedia[i] : null,
    ];

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        int mediaCursor = 0;
        final List<Widget> children = <Widget>[];
        for (final AylaMediaSegment seg in segments) {
          switch (seg.type) {
            case AylaSegmentType.text:
              children.add(
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: c.maxWidth),
                  child: Text(
                    seg.text,
                    style: const TextStyle(
                      fontFamily: AylaFonts.body,
                      fontFamilyFallback: AylaFonts.cjkFallback,
                      fontSize: 15,
                      height: 1.55,
                      color: AylaColors.indigo700,
                    ),
                  ),
                ),
              );
            case AylaSegmentType.mention:
              children.add(
                _MentionToken(
                  label: seg.mentionLabel,
                  isMe: widget.currentUserId != null &&
                      seg.userId == widget.currentUserId,
                  onTap: seg.userId == null
                      ? null
                      : () => widget.onMentionTap?.call(seg.userId!),
                ),
              );
            case AylaSegmentType.image:
              final int segIndex = mediaCursor++;
              children.add(
                _MixedImageBlock(
                  media: seg.media,
                  localPath: locals[segIndex]?.url,
                  onTap: () => _openViewer(context, mediaSegs, locals, segIndex),
                ),
              );
            case AylaSegmentType.video:
              final int segIndex = mediaCursor++;
              children.add(
                SizedBox(
                  // tsx 461：混排视频段 240 宽 4:3
                  width: 240,
                  height: 180,
                  child: _VideoFrame(
                    media: seg.media,
                    localPath: locals[segIndex]?.url,
                    size: (width: 240, height: 180),
                    ariaLabel: '查看视频',
                    vodPlayerFactory: widget.vodPlayerFactory,
                    onOpen: () =>
                        _openViewer(context, mediaSegs, locals, segIndex),
                  ),
                ),
              );
          }
        }
        return Wrap(
          spacing: AylaSpacing.sp2,
          runSpacing: AylaSpacing.sp2,
          alignment: WrapAlignment.start,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: children,
        );
      },
    );
  }

  void _openViewer(
    BuildContext context,
    List<AylaMediaSegment> mediaSegs,
    List<AylaLocalMediaPreview?> locals,
    int initialIndex,
  ) {
    final List<AylaViewerItem> items = <AylaViewerItem>[];
    for (int i = 0; i < mediaSegs.length; i++) {
      final AylaMediaSegment seg = mediaSegs[i];
      final AylaLocalMediaPreview? local = locals[i];
      items.add(
        AylaViewerItem(
          media: seg.media,
          localPath: local?.url,
          isVideo: seg.isVideo || local?.kind == AylaMediaKind.video,
          alt: seg.isVideo ? '视频' : '图片',
        ),
      );
    }
    _viewer.openItems(context, items, initialIndex);
  }
}

/// 混排图片块（app.css 1951–1974）：180×180 方块 + radius-input + `cover`。
class _MixedImageBlock extends StatelessWidget {
  const _MixedImageBlock({required this.media, this.localPath, required this.onTap});

  final AylaMediaDescriptor? media;
  final String? localPath;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AylaMediaDescriptor? descriptor = media;
    final Widget? content;
    if (descriptor != null) {
      final bool isGif = descriptor.mimeType == 'image/gif';
      final bool hasThumb = !isGif && descriptor.thumbnail != null;
      content = AylaResourceImage(
        src: hasThumb ? descriptor.thumbnail! : mediaContentUrl(descriptor.mediaId),
        alt: '图片',
        fit: BoxFit.cover,
        variant: hasThumb ? MediaVariant.thumb : null,
        expiredBadge: !hasThumb,
        fallback: const AylaSkeleton(),
      );
    } else if (localPath != null) {
      content = Image.file(File(localPath!), fit: BoxFit.cover);
    } else {
      content = const AylaSkeleton();
    }

    return SizedBox(
      width: 180,
      height: 180,
      child: AylaCardInteraction(
        interactive: false,
        focusRingColor: AylaColors.glow500,
        focusRingRadius: BorderRadius.circular(AylaRadii.rInput),
        semanticLabel: '查看图片',
        onTap: onTap,
        builder: (BuildContext ctx, bool hovered) => ClipRRect(
          borderRadius: BorderRadius.circular(AylaRadii.rInput),
          child: ColoredBox(
            color: AylaColors.glassBg,
            child: MouseRegion(
              cursor: SystemMouseCursors.zoomIn,
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

/// `.mention-token`（app.css 2328–2355）：ice-500 pill + indigo 700 字 + 700；
/// 「@我」加 1.5px glow 内环；hover/focus → brightness 1.05 + `--focus-ring`。
class _MentionToken extends StatefulWidget {
  const _MentionToken({required this.label, required this.isMe, this.onTap});

  final String label;
  final bool isMe;
  final VoidCallback? onTap;

  @override
  State<_MentionToken> createState() => _MentionTokenState();
}

class _MentionTokenState extends State<_MentionToken> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    // web «MediaContent.tsx:411»：mention 按钮带 «title="@昵称"»（与 aria-label 同值）
    return AylaTooltip(
      message: '@${widget.label}',
      child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Focus(
        onFocusChange: (bool v) => setState(() => _focused = v),
        child: GestureDetector(
          onTap: widget.onTap,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: Semantics(
              button: true,
              label: '@${widget.label}',
              child: AnimatedContainer(
                duration: AylaDurations.fast,
                curve: AylaCurves.easeOut,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: _hovered || _focused
                      ? const Color(0xFFA9C7EA) // brightness(1.05) 的等价提亮
                      : AylaColors.ice500,
                  borderRadius: BorderRadius.circular(AylaRadii.rPill),
                  border: _focused
                      ? Border.all(color: AylaColors.glow500, width: 2)
                      : (widget.isMe
                          ? Border.all(color: AylaColors.glow500, width: 1.5)
                          : null),
                ),
                child: Text(
                  '@${widget.label}',
                  style: const TextStyle(
                    fontFamily: AylaFonts.body,
                    fontFamilyFallback: AylaFonts.cjkFallback,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    height: 1.45,
                    color: AylaColors.indigo700,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }
}

// ======================= 语音 =======================

/// 语音消息（tsx 484–685 + app.css 1520–1639）。
class _VoiceMedia extends StatefulWidget {
  const _VoiceMedia({
    super.key,
    required this.media,
    this.audioEngineFactory,
  });

  final AylaMediaDescriptor media;
  final AylaAudioEngine Function()? audioEngineFactory;

  @override
  State<_VoiceMedia> createState() => _VoiceMediaState();
}

class _VoiceMediaState extends State<_VoiceMedia> {
  AylaAudioEngine? _engine;
  AylaAudioPlaybackState _state = const AylaAudioPlaybackState();
  bool _loading = false;
  bool _pending = false;
  bool _disposed = false;

  /// 云端已完全过期且本地无缓存 → 渲染「已过期」占位（不显示重试）。
  ///
  /// 本地漫游缓存有内容时**不会**置位：看过就一直能播放（用户裁决 D3）。
  bool _expired = false;

  /// 总时长：descriptor 为准；波形/metadata 派生失败时由音频 metadata 兜底（tsx 495–496）。
  Duration? _metaDuration;

  Duration? get _total {
    final Duration? fromMeta = _metaDuration;
    if (fromMeta != null && fromMeta > Duration.zero) return fromMeta;
    final double? seconds = widget.media.duration;
    if (seconds != null && seconds > 0) {
      return Duration(milliseconds: (seconds * 1000).round());
    }
    if (_state.duration > Duration.zero) return _state.duration;
    return null;
  }

  /// 停止播放（稳定引用，供互斥注册表 claim/release）：
  /// 暂停 + 进度归零 + UI 复位（tsx 503–517）。
  void _stopPlayback() {
    _engine?.pause();
    _engine?.seek(Duration.zero);
    if (mounted) {
      setState(() => _state = _state.copyWith(playing: false, position: Duration.zero));
    }
    AylaAudioClaims.release(_stopPlayback);
  }

  Future<AylaAudioEngine?> _ensureEngine({bool retry = false}) async {
    if (retry) {
      _stopPlayback();
      await _engine?.dispose();
      _engine = null;
    }
    final AylaAudioEngine? existing = _engine;
    if (existing != null) return existing;
    setState(() => _loading = true);
    setState(() => _state = _state.copyWith(error: null));
    final AylaAudioEngine engine =
        (widget.audioEngineFactory ?? createAylaAudioEngine)();
    engine.onStateChange = (AylaAudioPlaybackState s) {
      if (_disposed || !mounted) return;
      setState(() {
        _state = s;
        if (s.duration > Duration.zero) _metaDuration = s.duration;
      });
      if (s.error != null) {
        _stopPlayback();
        setState(() => _state = _state.copyWith(error: s.error));
      }
    };
    _engine = engine;
    try {
      // ① 本地漫游缓存优先（docs/architecture/flutter-local-media-cache.md）：
      //    命中则直接播放本地文件，不发网络请求；
      //    未命中 → 走签名 URL 远程播放，并静默落盘（加载即存）。
      final File? cached = await AylaMediaCache.instance.lookup(
        widget.media.mediaId,
        kind: AylaMediaKind.voice,
        mimeType: widget.media.mimeType,
      );
      if (_disposed || !mounted) return null;
      if (cached != null) {
        await engine.open(cached.path);
        if (_disposed || !mounted) return null;
        setState(() {
          _loading = false;
          _expired = false;
        });
        return engine;
      }
      final AylaAudioSource source =
          AylaAudioSource.media(widget.media.mediaId);
      await engine.open(source.url, headers: source.headers);
      if (_disposed || !mounted) return null;
      setState(() {
        _loading = false;
        _expired = false;
      });
      // ② 落盘（**2026-10-23 用户改版**）：语音**点击播放才存**，不点击不存。
      //
      //    用户原话：「语音则是点击语音即保存本地，不点击不保存」。
      //
      //    本方法 [_ensureEngine] **只由 [_toggle]（播放键/重试键）调用** ⇒
      //    走到这里就代表用户已经点了播放，落盘时机正确。
      //    仍然不 await、不提示：缓存是增强项，失败不影响本次播放。
      //
      //    ⚠️ **不要**把它挪回 build / initState（旧 D4「加载即存」的写法）：
      //    那会让每条语音一进视口就下载整条音频，与用户明确裁决冲突。
      // 走**持久下载队列**（2026-10-29 用户拍板）：任务先落盘，失败最多重试 3 次，
      // app 被杀后下次启动自动续跑。落盘时机不变（仍然是「点击播放才存」）。
      unawaited(
        AylaMediaDownloadQueue.instance
            .enqueue(
              mediaId: widget.media.mediaId,
              kind: AylaMediaKind.voice,
              mimeType: widget.media.mimeType,
            )
            .catchError((Object _) {}),
      );
      return engine;
    } on MediaExpiredError {
      // 云端已完全过期且本地没有 → 「已过期」占位（不显示重试）
      if (!mounted) return null;
      setState(() {
        _loading = false;
        _expired = true;
      });
      return null;
    } catch (e) {
      if (!mounted) return null;
      setState(() {
        _loading = false;
        _state = _state.copyWith(error: e.toString());
      });
      return null;
    }
  }

  /// 播放/暂停（tsx 554–590）。
  Future<void> _toggle({bool retry = false}) async {
    if (_pending) return;
    if (_state.playing) {
      _stopPlayback();
      return;
    }
    _pending = true;
    try {
      final AylaAudioEngine? engine = await _ensureEngine(retry: retry);
      if (engine == null || _disposed) return;
      AylaAudioClaims.claim(_stopPlayback);
      await engine.play();
    } finally {
      _pending = false;
    }
  }

  void _seekTo(Duration position) {
    final AylaAudioEngine? engine = _engine;
    if (engine == null) return;
    engine.seek(position);
    setState(() => _state = _state.copyWith(position: position));
  }

  @override
  void dispose() {
    _disposed = true;
    AylaAudioClaims.release(_stopPlayback);
    _engine?.dispose();
    _engine = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String? wave = aylaResolveMediaPath(widget.media.waveform);
    final Duration? total = _total;
    final double? totalSeconds = total == null ? null : total.inMilliseconds / 1000;
    final double currentSeconds = _state.position.inMilliseconds / 1000;
    final bool seekable = _engine != null && totalSeconds != null;

    // ⚠️ `.voice-card`（app.css:1521–1527）是 `display:flex; flex-direction:column`
    // 的块级 flex 容器 ⇒ 宽度 = max-content（被自身 `min-width:240px` 托底，
    // 被外层 `.msg-body` 的 75%/84% 上限约束）。Flutter 侧同构：
    //  - 外层 `Container(minWidth:240)` = `.voice-card{min-width:240}`；
    //  - **列内两行都必须收缩到内容宽**（块级 flex 容器按内容收缩）。
    //
    // 🔴 2026-10-22 二轮回归根因（真机截图：语音气泡撑满整行约 84%）：
    // 主行原本是 `Row`（默认 `MainAxisSize.max`）+ `Expanded(波形)`。
    // 外层消息行用 [AylaCssFlexRow] 的**无界主轴测量**实现 CSS 的
    // `flex-basis:auto`（= max-content）⇒ 这里 `Row` 拿到的 `maxWidth` 是
    // `.msg-body` 的 75%/84% 上限 ⇒ 行宽 = 上限 ⇒ 语音卡被拉成整行。
    // CSS 里 `.voice-wave{flex:1}` 在 max-content 度量下按**自身内容宽**参与，
    // 不会把上限当内容宽 ⇒ 本件必须显式表达（见 [AylaInlineSize]）。
    //
    // 此外整体必须 **fit-content**（= [AylaFitContent]）：CSS 里 `.voice-card`
    // 作为 `.bubble`（块级）的子级，宽度由 `.bubble` 的 fit-content 决定，
    // 而 `.bubble` 由 `.msg-bubble-wrap` 的 flex 项语义决定 ⇒ 三层都是
    // 「先算 max-content、再被 75% 夹住」。Flutter 的 `Align(widthFactor:1)`
    // 只有一趟（用已被夹过的约束布局）⇒ 内部 `Row` 把上限当内容宽。
    return AylaFitContent(
      minWidth: 240, // .voice-card { min-width: 240px }（app.css:1525）
      child: Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AylaSpacing.sp3,
        vertical: AylaSpacing.sp2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _VoicePlayButton(
                loading: _loading,
                playing: _state.playing,
                onTap: () => _toggle(),
              ),
              const SizedBox(width: AylaSpacing.sp3),
              // `.voice-wave { flex: 1; min-width: 0; height: 36px; object-fit: fill }`
              // （app.css:1551–1557）。`flex:1` 的「有界 ⇒ 占满剩余」与
              // 「无界 ⇒ 按自身内容宽」两档语义见 [AylaInlineSize]。
              // ⚠️ `.voice-wave` 还有 `min-width: 0`（app.css:1553）⇒ 有界档**可以被压窄**
              // （375 档浏览器实测被压到 127.81）。故必须包在 `Flexible(fit: loose)` 里：
              // 无界档 `RenderFlex` 不给弹性 ⇒ 走 [AylaInlineSize] 的 max-content 分支；
              // 有界档拿到「剩余空间」的 loose 约束 ⇒ 占满或按需压窄，与 CSS 同解。
              Flexible(
                fit: FlexFit.loose,
                child: AylaInlineSize(
                  minWidth: wave == null
                      ? kAylaVoiceWaveFallbackWidth
                      : kAylaVoiceWaveNaturalWidth,
                  child: SizedBox(
                    height: kAylaVoiceWaveHeight,
                    child: wave == null
                        ? const _VoiceWaveFallback()
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(AylaRadii.rSm),
                            child: AylaResourceImage(
                              src: wave,
                              alt: '语音波形',
                              fit: BoxFit.fill,
                              fallback: const _VoiceWaveFallback(),
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(width: AylaSpacing.sp3),
              Text(
                aylaFormatDuration(totalSeconds ?? 0),
                style: const TextStyle(
                  fontFamily: AylaFonts.utility,
                  fontFamilyFallback: AylaFonts.cjkFallback,
                  fontSize: 12,
                  letterSpacing: 0.3,
                  color: AylaColors.textSecondary,
                ),
              ),
            ],
          ),
          // 云端已完全过期且本地无缓存 → 「已过期」占位（不裂图、不重试）。
          // 本地漫游缓存命中时不会走到这里（看过就一直能播）。
          if (_expired) ...<Widget>[
            const SizedBox(height: AylaSpacing.sp2),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(
                  Icons.schedule_outlined,
                  size: 14,
                  color: AylaColors.textSecondary,
                ),
                const SizedBox(width: AylaSpacing.sp1),
                Text(
                  '已过期',
                  style: TextStyle(
                    fontFamily: AylaFonts.body,
                    fontFamilyFallback: AylaFonts.cjkFallback,
                    fontSize: 12,
                    color: AylaColors.textSecondary,
                  ),
                ),
              ],
            ),
          ] else if (_state.error != null) ...<Widget>[
            const SizedBox(height: AylaSpacing.sp2),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const Text(
                  '语音播放失败',
                  style: TextStyle(
                    fontFamily: AylaFonts.body,
                    fontFamilyFallback: AylaFonts.cjkFallback,
                    fontSize: 12,
                    color: AylaColors.destructive,
                  ),
                ),
                const SizedBox(width: AylaSpacing.sp2),
                AylaMediaRetryButton(
                  enabled: !_loading,
                  onTap: () => _toggle(retry: true),
                ),
              ],
            ),
          ],
          const SizedBox(height: AylaSpacing.sp1),
          // `.voice-seek-row { display:flex; align-items:center; gap:var(--sp-2) }`
          // （app.css:1568–1572）+ `.voice-seek { flex:1; min-width:0 }`（1574–1580）
          // —— 与主行同构：必须 `MainAxisSize.min` + 无界档的 max-content
          // （Chrome 实测 range 无界宽 135，整行 135 + 8 + 34 = 177）。
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Flexible(
                fit: FlexFit.loose,
                child: AylaInlineSize(
                minWidth: kAylaVoiceSeekNaturalWidth,
                child: SliderTheme(
                    data: SliderThemeData(
                    trackHeight: 4,
                    activeTrackColor: seekable
                        ? AylaColors.indigo700
                        : const Color(0x739DBFE6),
                    inactiveTrackColor: const Color(0x739DBFE6), // rgba(157,191,230,.45)
                    thumbColor: AylaColors.indigo700,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                    overlayColor: const Color(0x2E9DBFE6),
                  ),
                  child: Slider(
                    // ⚠️ 不传 divisions（Flutter isDiscrete 会让拇指动画化、追不上指针）
                    value: totalSeconds == null
                        ? 0
                        : currentSeconds.clamp(0.0, totalSeconds),
                    max: totalSeconds == null || totalSeconds <= 0 ? 1 : totalSeconds,
                    onChanged: seekable
                        ? (double v) =>
                            _seekTo(Duration(milliseconds: (v * 1000).round()))
                        : null,
                    semanticFormatterCallback: (double v) =>
                        '语音播放进度 ${v.round()} 秒',
                  ),
                ),
                ),
              ),
              const SizedBox(width: AylaSpacing.sp2),
              SizedBox(
                width: 34,
                child: Text(
                  aylaFormatDuration(currentSeconds),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontFamily: AylaFonts.utility,
                    fontFamilyFallback: AylaFonts.cjkFallback,
                    fontSize: 11,
                    letterSpacing: 0.3,
                    color: AylaColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      ),
    );
  }
}

/// `.voice-play`（app.css 1535–1549）：40 圆 + `--indigo-700` 底 + `#fffafb` 图标；
/// 加载中 → skeleton 14×14 radius 4；hover → `--glow-shadow`。
class _VoicePlayButton extends StatefulWidget {
  const _VoicePlayButton({
    required this.loading,
    required this.playing,
    required this.onTap,
  });

  final bool loading;
  final bool playing;
  final VoidCallback onTap;

  @override
  State<_VoicePlayButton> createState() => _VoicePlayButtonState();
}

class _VoicePlayButtonState extends State<_VoicePlayButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.loading ? null : widget.onTap,
        child: Semantics(
          button: true,
          label: widget.playing
              ? '暂停语音'
              : (widget.loading ? '语音加载中' : '播放语音'),
          child: AnimatedContainer(
            duration: AylaDurations.fast,
            curve: AylaCurves.easeOut,
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AylaColors.indigo700,
              shape: BoxShape.circle,
              boxShadow: _hovered && !widget.loading ? AylaShadows.glow : null,
            ),
            child: Center(child: _icon()),
          ),
        ),
      ),
    );
  }

  Widget _icon() {
    if (widget.loading) {
      return const AylaSkeleton(width: 14, height: 14, radius: 4);
    }
    // web «MediaContent.tsx:632/634»：«IconPause 16» / «IconPlay 16»（lucide）。
    return AylaIcon(
      aylaIconByName(widget.playing ? 'iconPause' : 'iconPlay')!,
      size: 16,
      color: const Color(0xFFFFFAFB),
    );
  }
}

/// 无波形降级（tsx 643–652）：grid 居中 + mic 图标 18。
class _VoiceWaveFallback extends StatelessWidget {
  const _VoiceWaveFallback();

  @override
  Widget build(BuildContext context) {
    // web «MediaContent.tsx:645/651»：«IconMic width={18} height={18} />»（lucide）。
    return ColoredBox(
      color: const Color(0x149DBFE6),
      child: Center(
        child: AylaIcon(
          aylaIconByName('iconMic')!,
          size: 18,
          color: AylaColors.textSecondary,
        ),
      ),
    );
  }
}

// ======================= 文件 =======================

/// 文件消息（tsx 689–755 + app.css 1839–1897）。
class _FileMedia extends StatefulWidget {
  const _FileMedia({
    super.key,
    required this.msg,
    required this.media,
    this.onDownloaded,
    this.onSaveError,
  });

  final AylaChatMessage msg;
  final AylaMediaDescriptor media;
  final void Function(String savedPath)? onDownloaded;
  final void Function(String detail)? onSaveError;

  @override
  State<_FileMedia> createState() => _FileMediaState();
}

class _FileMediaState extends State<_FileMedia> {
  bool _ready = false;
  bool _failed = false;
  bool _expired = false;
  bool _saving = false;
  int _signSeq = 0;

  @override
  void initState() {
    super.initState();
    _sign();
  }

  @override
  void didUpdateWidget(covariant _FileMedia old) {
    super.didUpdateWidget(old);
    if (old.media.mediaId != widget.media.mediaId) _sign();
  }

  Future<void> _sign() async {
    final int seq = ++_signSeq;
    setState(() {
      _ready = false;
      _failed = false;
      _expired = false;
    });
    try {
      // ① 本地漫游缓存优先：命中则无需签名（离线也能下载/打开）；
      //    本地有就永远可用，云端过期不影响（用户裁决 D3）。
      final File? cached = await AylaMediaCache.instance.lookup(
        widget.media.mediaId,
        kind: AylaMediaKind.file,
        mimeType: widget.media.mimeType,
      );
      if (!mounted || seq != _signSeq) return;
      if (cached != null) {
        setState(() {
          _ready = true;
          _expired = false;
        });
        return;
      }
      await MediaSigner.instance.sign(widget.media.mediaId);
      if (!mounted || seq != _signSeq) return;
      setState(() => _ready = true);
      // ② **不落盘**（**2026-10-23 用户改版**）。
      //
      //    用户原话：「前面我说的看见媒体消息直接保存，这一点**不包括保存文件消息**，
      //    文件消息需要手动点击保存才保存到本地」。
      //
      //    ⇒ 这里**故意什么都不做**。旧代码（D4「加载即存」）签完就
      //    `fetchAndStore(kind: file)` 静默把整个附件下载落盘 —— 一份 50MB 的
      //    附件只要被扫到就吃满磁盘与带宽，且用户从没点过「保存」。
      //
      //    真正的落盘时机只有一个：用户点「保存」按钮
      //    → [_download] → `AylaMediaDownload.save`（系统保存对话框）。
      //    那条路径经 `AylaMediaDownload.readBytes` 读字节，**本方法不参与**。
      //
      //    ⚠️ **不要**恢复自动预取：文件是三类媒体里唯一「用户明确要求手动保存」
      //    的类型（图片/语音/视频都有各自的自动或点击落盘规则）。
    } on MediaExpiredError {
      if (!mounted || seq != _signSeq) return;
      setState(() => _expired = true);
    } catch (_) {
      if (!mounted || seq != _signSeq) return;
      setState(() => _failed = true);
    }
  }

  Future<void> _download() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      // 统一走 `AylaMediaDownload.save`：内部已实现「缓存优先 → 鉴权下载」，
      // 并弹**系统保存对话框**（桌面）/ SAF（移动端）—— 等价 web 的 `<a download>`。
      // 2026-10-21 用户实报「文件发送后无法下载」：此前页面层根本没传
      // `onDownloaded`（回调为空），且旧实现只静默写下载目录、无任何 UI 反馈。
      final String? path = await AylaMediaDownload.save(
        mediaId: widget.media.mediaId,
        fileName: _name,
      );
      if (!mounted) return;
      if (path != null) widget.onDownloaded?.call(path);
    } catch (e) {
      if (!mounted) return;
      setState(() => _failed = true);
      widget.onSaveError?.call(e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String get _name {
    final String caption = _caption(widget.msg);
    return caption.isEmpty ? '附件' : caption;
  }

  @override
  Widget build(BuildContext context) {
    return _FileCard(
      name: _name,
      size: widget.media.size,
      expired: _expired,
      failed: _failed,
      ready: _ready && !_saving,
      onDownload: _ready && !_expired ? _download : null,
      onRetry: () {
        MediaSigner.instance.invalidate(widget.media.mediaId);
        _sign();
      },
    );
  }
}

/// `.file-card`（app.css 1839–1897）：图标 + 名 + 大小 + 下载圆键。
class _FileCard extends StatelessWidget {
  const _FileCard({
    required this.name,
    this.size,
    this.expired = false,
    this.failed = false,
    this.ready = false,
    this.onDownload,
    this.onRetry,
  });

  final String name;
  final int? size;
  final bool expired;
  final bool failed;
  final bool ready;
  final VoidCallback? onDownload;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    // `.file-card { min-width:240px; max-width:320px; display:flex; gap:sp3;
    //              padding:sp3 }`（app.css:1839–1846）+ `.file-info { flex:1;
    //              min-width:0 }`（1859–1866）。
    //
    // 🔴 与语音卡同一根因（2026-10-22 二轮）：行内 `.file-info` 是 `flex:1`，
    // Flutter 侧写成 `Expanded` ⇒ 在消息行的**无界主轴测量**下把
    // `.msg-body` 的 75% 上限当内容宽 ⇒ 文件卡被拉满（实测 328，web 276.73）。
    // ⇒ 整卡必须 fit-content（[AylaFitContent]），行内 `flex:1` 项走
    // [AylaInlineSize]（无界时取自身的 max-content = 0 ⇒ 由 min-width:240 托底）。
    return AylaFitContent(
      minWidth: 240, // .file-card { min-width: 240px }（app.css:1843）
      maxWidth: 320, // .file-card { max-width: 320px }（app.css:1844）
      child: Padding(
        padding: const EdgeInsets.all(AylaSpacing.sp3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AylaColors.ice100,
                borderRadius: BorderRadius.circular(AylaRadii.rInput),
              ),
              // web «MediaContent.tsx:723/828»：«IconFile width={20} height={20} />»（lucide）。
              child: Center(
                child: AylaIcon(
                  aylaIconByName('iconFile')!,
                  size: 20,
                  color: AylaColors.indigo700,
                ),
              ),
            ),
            const SizedBox(width: AylaSpacing.sp3),
            // `.file-info { flex:1; min-width:0 }`（app.css:1859–1866）——
            // 「有界占满 / 无界取自身内容宽」两档语义见 [AylaInlineNaturalSize]
            // （内容宽是动态的：文件名长度）。
            Flexible(
              fit: FlexFit.loose,
              child: AylaInlineNaturalSize(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  // web «MediaContent.tsx:726»：消息文件行的 «span.file-name title={name}»
                  // ⇒ 本轮统一收敛到 AylaTooltip（此前这里接的是裸 Material Tooltip）
                  AylaTooltip(
                    message: name,
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: AylaFonts.body,
                        fontFamilyFallback: AylaFonts.cjkFallback,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AylaColors.indigo700,
                      ),
                    ),
                  ),
                  if (size != null)
                    Text(
                      aylaFormatBytes(size!),
                      style: const TextStyle(
                        fontFamily: AylaFonts.utility,
                        fontFamilyFallback: AylaFonts.cjkFallback,
                        fontSize: 12,
                        color: AylaColors.textSecondary,
                      ),
                    ),
                  if (expired)
                    const Text(
                      '已过期',
                      style: TextStyle(
                        fontFamily: AylaFonts.body,
                        fontFamilyFallback: AylaFonts.cjkFallback,
                        fontSize: 12,
                        color: AylaColors.destructive,
                      ),
                    ),
                  if (failed)
                    const Text(
                      '附件加载失败',
                      style: TextStyle(
                        fontFamily: AylaFonts.body,
                        fontFamilyFallback: AylaFonts.cjkFallback,
                        fontSize: 12,
                        color: AylaColors.destructive,
                      ),
                    ),
                ],
              ),
              ),
            ),
            const SizedBox(width: AylaSpacing.sp3),
            if (failed && onRetry != null)
              AylaMediaRetryButton(onTap: onRetry!)
            else
              _FileDownloadButton(
                enabled: ready && !expired,
                expired: expired,
                onTap: onDownload,
                name: name,
              ),
          ],
        ),
      ),
    );
  }
}

/// `.file-download`（app.css 1881–1897）：36 圆 + 1px indigo 边 + indigo 图标；
/// hover → `rgba(157,191,230,.18)` 底 + `--glow-shadow`。
class _FileDownloadButton extends StatefulWidget {
  const _FileDownloadButton({
    required this.enabled,
    required this.expired,
    required this.name,
    this.onTap,
  });

  final bool enabled;
  final bool expired;
  final String name;
  final VoidCallback? onTap;

  @override
  State<_FileDownloadButton> createState() => _FileDownloadButtonState();
}

class _FileDownloadButtonState extends State<_FileDownloadButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.enabled ? widget.onTap : null,
        child: Semantics(
          button: widget.enabled,
          label: widget.expired ? '附件已过期' : '下载 ${widget.name}',
          child: AnimatedContainer(
            duration: AylaDurations.fast,
            curve: AylaCurves.easeOut,
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: _hovered && widget.enabled
                  ? const Color(0x2E9DBFE6)
                  : null,
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0x59465B92)),
              boxShadow: _hovered && widget.enabled ? AylaShadows.glow : null,
            ),
            child: Center(
              // :disabled 语义：不可点时降透明。性能（2026-09-27 §8.17）：
              // 单图标、无重叠 ⇒ 把 .55 乘进图标色与整层 Opacity 等价，
              // 省掉一次 saveLayer。
              // web «MediaContent.tsx:735/748/751»：«IconDownload width={16} height={16} />»（lucide）。
              child: AylaIcon(
                aylaIconByName('iconDownload')!,
                size: 16,
                color: widget.enabled
                    ? AylaColors.indigo700
                    : AylaColors.indigo700
                        .withValues(alpha: AylaColors.indigo700.a * 0.55),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ======================= 查看器宿主 =======================

/// 图片/视频全屏查看器宿主（web `createPortal(document.body)`；
/// Flutter 用 root Overlay —— 与弹幕图片查看器同一先例）。
class _MediaViewerHost {
  OverlayEntry? _entry;

  void open(
    BuildContext context, {
    AylaMediaDescriptor? media,
    String alt = '',
    bool isVideo = false,
  }) {
    close();
    final OverlayEntry entry = aylaOverlayEntry(
      builder: (BuildContext ctx) => AylaImageViewer(
        media: media,
        alt: alt,
        items: media == null
            ? const <AylaViewerItem>[]
            : <AylaViewerItem>[
                AylaViewerItem(media: media, isVideo: isVideo, alt: alt),
              ],
        onClose: close,
      ),
    );
    _entry = entry;
    _insertOnRootOverlay(context, entry);
  }

  /// 把查看器插到**根 Overlay**（覆盖整个窗口，含顶部导航栏）。
  ///
  /// 2026-10-21 用户实报「查看图片时顶部导航栏没被遮住」：此前用
  /// `Overlay.of(context)`（**最近**的 Overlay）。聊天页的最近 Overlay 是
  /// 消息区那一层（`Scaffold` 内的 body 区），它**不含**顶部导航栏 ⇒ 查看器
  /// 只铺满内容区、导航栏浮在上面。web 用 `createPortal(document.body)` 铺满视口，
  /// 对应 Flutter 的 **rootOverlay**。
  ///
  /// 为什么早先注释说「不要 rootOverlay」：画布/测试宿主（`preview_theme.dart:55`）
  /// 没有 Navigator ⇒ `rootOverlay: true` 会抛 `No Overlay widget found`。
  /// 这里改成「优先 rootOverlay，宿主不可用时退回最近 Overlay」：
  /// 生产恒走 root（正确），画布/测试退回最近层（不抛异常）。
  void _insertOnRootOverlay(BuildContext context, OverlayEntry entry) {
    final OverlayState? root = Overlay.maybeOf(context, rootOverlay: true);
    if (root != null) {
      root.insert(entry);
      return;
    }
    Overlay.of(context).insert(entry);
  }

  /// 多条目模式（混排消息同消息内多图/视频左右切换，tsx 466–477）。
  void openItems(
    BuildContext context,
    List<AylaViewerItem> items,
    int initialIndex,
  ) {
    if (items.isEmpty) return;
    close();
    final OverlayEntry entry = aylaOverlayEntry(
      builder: (BuildContext ctx) => AylaImageViewer(
        items: items,
        initialIndex: initialIndex,
        onClose: close,
      ),
    );
    _entry = entry;
    _insertOnRootOverlay(context, entry);
  }

  void close() {
    _entry?.remove();
    _entry = null;
  }
}

/// 消息正文里的说明文字（tsx 44–46 `caption`）。
String _caption(AylaChatMessage msg) => msg.content.trim();

// ======================= 样张 =======================

AylaMediaDescriptor _previewDescriptor({
  required String id,
  required AylaMediaKind kind,
  String mime = 'image/png',
  int? width,
  int? height,
  double? duration,
  bool thumbnail = false,
  bool waveform = false,
  int size = 240000,
}) =>
    AylaMediaDescriptor(
      mediaId: id,
      kind: kind,
      mimeType: mime,
      size: size,
      width: width,
      height: height,
      duration: duration,
      thumbnail: thumbnail ? '/api/v1/media/$id/thumbnail' : null,
      waveform: waveform ? '/api/v1/media/$id/waveform' : null,
      status: 'ready',
    );

AylaChatMessage _previewMessage({
  required String id,
  required AylaMessageType type,
  String content = '',
  AylaMediaDescriptor? media,
  List<AylaMediaSegment> segments = const <AylaMediaSegment>[],
}) =>
    AylaChatMessage(
      id: id,
      conversationId: 'conv-1',
      senderId: 'user-1',
      type: type,
      content: content,
      mediaId: media?.mediaId,
      media: media,
      segments: segments,
      status: AylaMessageStatus.sent,
      seq: 1,
      createdAt: '2026-09-24T10:00:00Z',
    );

/// 样张用的最小气泡壳（模拟 `.msg-body → .bubble.bubble-media` 的 fit-content 链）。
///
/// 只做**宽度语义**（fit-content + 媒体气泡的 padding），不复制 message_bubble.dart
/// 的材质/工具栏 —— 样张要看的是「媒体卡的自然宽」，不是气泡外观
/// （外观在「聊天消息气泡」那节）。这样也避免 media_content ↔ message_bubble
/// 的循环 import。
class _PreviewBubble extends StatelessWidget {
  const _PreviewBubble({required this.msg});

  final AylaChatMessage msg;

  @override
  Widget build(BuildContext context) {
    // `.msg-body { max-width: 75%; align-items: flex-start }` 的等价：
    // 外层给 75% 的**松**约束，内层按内容收缩。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        return Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: c.maxWidth * 0.75),
            child: Align(
              alignment: Alignment.centerLeft,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AylaColors.glassOpaqueFallbackSoft,
                  borderRadius: BorderRadius.circular(AylaRadii.rBubble),
                  border: Border.all(color: AylaColors.glassBorder),
                ),
                child: Padding(
                  // `.bubble-media { padding: var(--sp-1) }`（app.css:1514–1518）
                  padding: const EdgeInsets.all(AylaSpacing.sp1),
                  child: AylaMediaContent(msg: msg),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 气泡内媒体宽度的样张（2026-10-22 二轮，fit-content 两趟布局的验收面）。
///
/// 演示的是**整条消息气泡**（不是裸媒体件），因为本轮修的是「媒体卡在
/// `.msg-body` 的 fit-content 链里被撑满」这件事 —— 单看媒体件看不出差异。
///
/// 看什么（对照 web 的 `message-scroll` → `message-column` 几何）：
/// 1. **语音**（有波形）气泡应是 ≈266 的**窄卡**，**不是**撑满整行 / 75% 上限
///    （web `.voice-card{min-width:240}`，`tool/web_media_expected.json` 1440 档 266.19）；
/// 2. **语音**（无波形）≈250；
/// 3. **图片 640×480** ≈330（= 320 + padding）、**480×640** ≈250、**100×100** ≈110
///    —— 宽度随图片比例变化，且小图不放大（`mediaFrameStyle`，tsx 86–97）；
/// 4. **表情** ≈106（96 固定）；**视频 1280×720** ≈330；**文件** ≈277；
/// 5. 全部都不应触及行的右边缘（即不是 714 的 75% 上限）。
Widget aylaBubbleMediaWidthSamples() {
  aylaEnableSampleMedia();
  final AylaMediaDescriptor voice = _previewDescriptor(
    id: 'w-voice',
    kind: AylaMediaKind.voice,
    mime: 'audio/ogg',
    duration: 12,
    waveform: true,
    size: 96000,
  );
  final AylaMediaDescriptor voiceNoWave = _previewDescriptor(
    id: 'w-voice2',
    kind: AylaMediaKind.voice,
    mime: 'audio/ogg',
    duration: 8,
    size: 64000,
  );
  final AylaMediaDescriptor image1 = _previewDescriptor(
    id: 'w-img1',
    kind: AylaMediaKind.image,
    width: 640,
    height: 480,
    thumbnail: true,
  );
  final AylaMediaDescriptor image2 = _previewDescriptor(
    id: 'w-img2',
    kind: AylaMediaKind.image,
    width: 480,
    height: 640,
    thumbnail: true,
  );
  final AylaMediaDescriptor image3 = _previewDescriptor(
    id: 'w-img3',
    kind: AylaMediaKind.image,
    width: 100,
    height: 100,
    thumbnail: true,
  );
  final AylaMediaDescriptor file = _previewDescriptor(
    id: 'w-file',
    kind: AylaMediaKind.file,
    mime: 'application/pdf',
    size: 2411724,
  );

  Widget label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: AylaSpacing.sp1),
        child: Text(
          text,
          style: const TextStyle(
            fontFamily: AylaFonts.utility,
            fontFamilyFallback: AylaFonts.cjkFallback,
            fontSize: 11,
            color: AylaColors.textSecondary,
          ),
        ),
      );

  return SingleChildScrollView(
    padding: const EdgeInsets.all(AylaSpacing.sp4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        label('语音（有波形）→ web 266.19 · 窄卡，不得撑满整行'),
        _PreviewBubble(
          msg: _previewMessage(
            id: 'wb1',
            type: AylaMessageType.voice,
            media: voice,
          ),
        ),
        const SizedBox(height: AylaSpacing.sp4),
        label('语音（无波形）→ web 250'),
        _PreviewBubble(
          msg: _previewMessage(
            id: 'wb2',
            type: AylaMessageType.voice,
            media: voiceNoWave,
          ),
        ),
        const SizedBox(height: AylaSpacing.sp4),
        label('图片 640×480 → web 330（按比例，不放大）'),
        _PreviewBubble(
          msg: _previewMessage(
            id: 'wb3',
            type: AylaMessageType.image,
            media: image1,
          ),
        ),
        const SizedBox(height: AylaSpacing.sp4),
        label('图片 480×640 → web 250（竖图）'),
        _PreviewBubble(
          msg: _previewMessage(
            id: 'wb4',
            type: AylaMessageType.image,
            media: image2,
          ),
        ),
        const SizedBox(height: AylaSpacing.sp4),
        label('图片 100×100 → web 110（小图不放大）'),
        _PreviewBubble(
          msg: _previewMessage(
            id: 'wb5',
            type: AylaMessageType.image,
            media: image3,
          ),
        ),
        const SizedBox(height: AylaSpacing.sp4),
        label('文件 → web 276.73（.file-card 240–320）'),
        _PreviewBubble(
          msg: _previewMessage(
            id: 'wb6',
            type: AylaMessageType.file,
            media: file,
          ),
        ),
      ],
    ),
  );
}

/// 媒体族样张。
///
/// 覆盖：图片（原比例）/ 表情（96 固定）/ 视频（海报帧 + 播放键）/ 语音（波形 + 时长 +
/// 进度）/ 文件（就绪 · 过期 · 失败）/ 混排（文本 + @胶囊 + 图 + 视频）/ 占位三态。
Widget aylaMediaContentSamples() {
  // 示例图：程序生成（外链不可达）；图片位真实渲染布局/圆角/裁切
  aylaEnableSampleMedia();

  final AylaMediaDescriptor image = _previewDescriptor(
    id: 'm-image',
    kind: AylaMediaKind.image,
    width: 640,
    height: 480,
    thumbnail: true,
  );
  final AylaMediaDescriptor emoji = _previewDescriptor(
    id: 'm-emoji',
    kind: AylaMediaKind.emoji,
    width: 240,
    height: 240,
    size: 48000,
  );
  final AylaMediaDescriptor video = _previewDescriptor(
    id: 'm-video',
    kind: AylaMediaKind.video,
    mime: 'video/mp4',
    width: 1280,
    height: 720,
    thumbnail: true,
    size: 4200000,
  );
  final AylaMediaDescriptor voice = _previewDescriptor(
    id: 'm-voice',
    kind: AylaMediaKind.voice,
    mime: 'audio/ogg',
    duration: 12,
    waveform: true,
    size: 96000,
  );
  final AylaMediaDescriptor file = _previewDescriptor(
    id: 'm-file',
    kind: AylaMediaKind.file,
    mime: 'application/pdf',
    size: 2411724,
  );

  return SingleChildScrollView(
    padding: const EdgeInsets.all(AylaSpacing.sp6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const _PreviewLabel('图片消息（原比例 640×480 → 320×240；缩略图 + 点击看原图）'),
        AylaMediaContent(
          msg: _previewMessage(id: 'c1', type: AylaMessageType.image, media: image),
        ),
        const SizedBox(height: AylaSpacing.sp6),
        const _PreviewLabel('表情消息（固定 96×96）'),
        AylaMediaContent(
          msg: _previewMessage(id: 'c2', type: AylaMessageType.emoji, media: emoji),
        ),
        const SizedBox(height: AylaSpacing.sp6),
        const _PreviewLabel('视频消息（海报帧封面 + 播放键；hover 放大 1.06 + 辉光）'),
        AylaMediaContent(
          msg: _previewMessage(id: 'c3', type: AylaMessageType.video, media: video),
        ),
        const SizedBox(height: AylaSpacing.sp6),
        const _PreviewLabel('语音消息（波形 + 时长 0:12 + 可拖进度；播放键 hover 辉光）'),
        AylaMediaContent(
          msg: _previewMessage(id: 'c4', type: AylaMessageType.voice, media: voice),
        ),
        const SizedBox(height: AylaSpacing.sp6),
        const _PreviewLabel('文件消息（就绪 / 已过期 / 加载失败重试）'),
        _FileCard(
          name: '设计规范-千禧冰樱.pdf',
          size: file.size,
          ready: true,
          onDownload: () {},
        ),
        const SizedBox(height: AylaSpacing.sp3),
        const _FileCard(name: '已过期的附件.zip', size: 512000, expired: true),
        const SizedBox(height: AylaSpacing.sp3),
        _FileCard(
          name: '加载失败的附件.docx',
          size: 128000,
          failed: true,
          onRetry: () {},
        ),
        const SizedBox(height: AylaSpacing.sp6),
        const _PreviewLabel('图文混排（text + @胶囊 + 180 方块图 + 240×180 视频段）'),
        AylaMediaContent(
          currentUserId: 'me',
          msg: _previewMessage(
            id: 'c5',
            type: AylaMessageType.mixed,
            segments: <AylaMediaSegment>[
              const AylaMediaSegment(
                type: AylaSegmentType.text,
                text: '今天的素材，@小樱 你看下这版：',
              ),
              const AylaMediaSegment(
                type: AylaSegmentType.mention,
                userId: 'me',
                userNickname: '我自己',
              ),
              AylaMediaSegment(
                type: AylaSegmentType.image,
                mediaId: image.mediaId,
                media: image,
              ),
              AylaMediaSegment(
                type: AylaSegmentType.video,
                mediaId: video.mediaId,
                media: video,
              ),
            ],
          ),
        ),
        const SizedBox(height: AylaSpacing.sp6),
        const _PreviewLabel('占位三态（加载中 / 加载失败 + 重试 / 未知类型）'),
        const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _MediaPlaceholder(state: _PlaceholderState.loading, label: '图片'),
            SizedBox(width: AylaSpacing.sp3),
            _MediaPlaceholder(
              state: _PlaceholderState.error,
              label: '视频',
              onRetry: _noop,
            ),
            SizedBox(width: AylaSpacing.sp3),
            _MediaPlaceholder(state: _PlaceholderState.unknown, label: '媒体'),
          ],
        ),
      ],
    ),
  );
}

void _noop() {}

/// 预览分组标题。
class _PreviewLabel extends StatelessWidget {
  const _PreviewLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AylaSpacing.sp3),
      child: Text(
        text,
        style: const TextStyle(
          fontFamily: AylaFonts.body,
          fontFamilyFallback: AylaFonts.cjkFallback,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AylaColors.textSecondary,
        ),
      ),
    );
  }
}
