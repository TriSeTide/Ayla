/// 统一图片加载事实（`components/AylaResourceImage.tsx` 的 Flutter 等价）。
///
/// ## 事实源
///
/// **加载路径（2026-10-21 起：本地缓存优先）**
/// - 内部媒体（src 以 `/api/v1/media/` 开头）→ 提取 `media_id`：
///   1. **先查本地漫游缓存**（[AylaMediaCache]）：命中直接用 `Image.file`，
///      **不发任何网络请求**——这正是「看过就一直能看」的落地，云端 7/30 天
///      过期不影响本地已有内容（见 `docs/architecture/flutter-local-media-cache.md`）；
///   2. 未命中 → 走签名链路（[MediaSigner]）：短时签名 URL ＋ 两级过期降级；
///      远程加载**成功后静默落盘**（加载即存，不提示用户）；
/// - 外部资源 / 非媒体路径 → **直接加载**（不签名、不缓存）。
///
/// **本地命中优先于过期判定**：即使云端已返回 410（对象已删），只要本地有文件
/// 就正常渲染，**不显示「已过期」占位**（用户裁决 D3：能看到图永远比看不到好）。
///
/// **decorative 语义（关键）**：`alt == ""` 表示装饰图（头像、行封面）。
/// web 对装饰图在**失败/过期**时**只渲染 `fallback`、不显示任何提示**
/// （`if (decorative) return <span aria-hidden>{fallback}</span>`），
/// 让承载它的控件保持主操作可用。非装饰图才显示：
/// - 失败 → `fallback` + 「图片加载失败，点击重试」（或外层控件的重试）
/// - 完全过期 → 「已过期」占位（**灰底文字，不裂图、不重试**）
/// - 原图过期（阶段 1）→ 缩略图 + 「原图已过期」角标（`expiredBadge=true` 时）
///
/// **重试**：调用 `invalidateSignedMediaUrl(mediaId)` 后重新加载
/// （web 的 `retryImage`：失效缓存 + `setRetry(n+1)`）。
///
/// ## 与 web 的差异（有意为之）
/// web 用 `<img>` 原生渐进解码 + HTTP 缓存；Flutter 侧用 `Image.network`
/// 的 `loadingBuilder` 呈现骨架、`errorBuilder` 呈现失败态。
/// 图片解码缓存交给 Flutter 的 `ImageCache`（等价浏览器缓存）。
///
/// ## 公开面
/// `AylaResourceImageState` · `AylaResourceImage`

library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/sample_media.dart';
import '../../theme/tokens.dart';
import '../../core/media/media_cache.dart';
import '../../core/media/media_signer.dart';
import '../../core/models/media_kind.dart';
import '../../core/net/api_endpoint.dart';

/// 后端 API 前缀（与 `api/client.ts` 的 `API_PREFIX` 一致）。
const String kApiPrefix = '/api/v1';

/// 媒体路径前缀（`api/media.ts` 的 `MEDIA_PATH_PREFIX`）。
const String kMediaPathPrefix = '$kApiPrefix/media/';

/// 媒体内容路径（web `api/media.ts:12–14` `mediaContentUrl` 同源）。
String mediaContentUrl(String mediaId) =>
    aylaAbsoluteApiUrl('$kMediaPathPrefix${Uri.encodeComponent(mediaId)}/content');

/// 媒体相对路径归一（web `api/media.ts:192–196` `resolveMediaPath`）：
/// 只接受后端媒体路径前缀，其余（外部 URL / 非法路径 / null）一律 null。
///
/// 原为 `danmaku.dart` 的私有实现（弹幕缩略图用），2026-09-24 提升为共享件
/// （chat 域的媒体波形/缩略图同样需要），口径与 web 一致：**不 fallback**。
String? aylaResolveMediaPath(String? path) {
  if (path == null) return null;
  if (path.startsWith(kMediaPathPrefix)) return path;
  // 2026-10-18：mediaContentUrl 现在是绝对地址；同源媒体绝对 URL 归一为路径，
  // 让调用方仍然走签名链路（而不是把带 token 的裸请求打到 API）。
  final Uri? uri = Uri.tryParse(path);
  if (uri != null && uri.hasScheme && uri.path.startsWith(kMediaPathPrefix)) {
    return uri.path;
  }
  return null;
}

/// 从媒体 URL 提取 media_id（`extractMediaId`）。
///
/// 仅识别 `/api/v1/media/<id>/...` 形式；非媒体路径返回 null（外部资源直接加载）。
String? extractMediaId(String src) {
  String path = src;
  final Uri? uri = Uri.tryParse(src);
  if (uri != null && uri.hasScheme) path = uri.path;
  if (!path.startsWith(kMediaPathPrefix)) return null;
  final String rest = path.substring(kMediaPathPrefix.length);
  final int slash = rest.indexOf('/');
  if (slash <= 0) return null;
  return rest.substring(0, slash);
}

/// 图片加载状态（[AylaResourceImage.onStateChanged] 的投影）。
///
/// web 没有这个回调：调用方若要「失败时把点击路由到重试」只能靠
/// `AylaResourceImage.tsx` 96–115 的 `enclosingControl` 捕获（把外层
/// `button/a[role=button]` 的 click 抢过来重试）。Flutter 没有事件捕获阶段，
/// 故把状态作为显式接线暴露给需要它的宿主（当前唯一调用点：弹幕图片钮）。
enum AylaResourceImageState {
  /// 签名 / 网络加载中（`.resource-image-loading`）。
  loading,

  /// 已就绪（签名完成或外部 URL 直接可用）。
  ready,

  /// 加载失败（可重试）。
  failed,

  /// 完全过期（媒体已永久删除，重试无意义）。
  expired,
}

/// 统一图片组件（对应 `AylaResourceImage`）。
class AylaResourceImage extends StatefulWidget {
  const AylaResourceImage({
    super.key,
    required this.src,
    this.alt = '',
    this.width,
    this.height,
    this.fit,
    this.fallback,
    this.variant,
    this.expiredBadge = false,
    this.reserveSpaceWhileLoading = true,
    this.previewImage,
    this.ignoreSampleMedia = false,
    this.onStateChanged,
  });

  /// 图片地址（可为 `/api/v1/media/<id>/content` 或外部 URL）。
  final String src;

  /// 替代文本。**空字符串 = 装饰图**（失败/过期不提示，只渲染 [fallback]）。
  final String alt;

  /// 宽（对应 `<img width>`；null = 由父约束决定）。
  final double? width;

  /// 高（对应 `<img height>`；null = 由父约束决定）。
  final double? height;

  /// 填充方式（对应 `object-fit`；null = `BoxFit.cover`，与多数调用处一致）。
  final BoxFit? fit;

  /// 装饰图失败/过期时渲染的内容（web 的 `fallback`；常为文字首字）。
  final Widget? fallback;

  /// 气泡缩略图变体（web `variant="thumb"`）。
  final MediaVariant? variant;

  /// 原图已过期（阶段 1）时叠加「原图已过期」角标（web `expiredBadge`）。
  final bool expiredBadge;

  /// 加载中是否占位（web 的 `resource-image-loading` 常配 skeleton）。
  final bool reserveSpaceWhileLoading;

  /// 预览/样张注入的图片源：非 null 时**直接渲染该图**，跳过签名与网络链路。
  ///
  /// **只用于预览与画布样张**（媒体存储链路未落地时让样张看到真实画面，
  /// 例如 `lib/preview/sample_media.dart` 的程序生成示例图）；
  /// 生产调用点一律不传 —— 示例数据不得进入产品路径。
  final ImageProvider? previewImage;

  /// 忽略预览示例媒体开关（**演示过期/失败/装饰静默等特殊态的样张专用**）。
  ///
  /// 默认 false。置 true 时即便 [aylaSampleMediaEnabled] 打开也走真实链路 ——
  /// 否则「原图已过期 / 完全过期 / 装饰图失败静默」这些样张会被示例图盖成
  /// 「正常图片」，把要演示的状态演示没了（2026-09-20 用户点名）。
  /// [previewImage] 非空时仍以显式注入为准。
  final bool ignoreSampleMedia;

  /// 加载状态变化通知（见 [AylaResourceImageState]）。
  ///
  /// 去重后**排到帧后**回调（首帧的 loading 与 `didUpdateWidget` 里的重载都发生在
  /// build 期，直接回调会让宿主在 build 中 setState）。不传 = 行为与从前完全一致。
  final ValueChanged<AylaResourceImageState>? onStateChanged;

  @override
  State<AylaResourceImage> createState() => _ResourceImageState();
}

/// 加载状态机（对应 tsx 的 `expired` / `failed` / `resolvedSrc`）。
enum _State { loading, ready, failed, expired }

class _ResourceImageState extends State<AylaResourceImage> {
  _State _state = _State.loading;
  String? _resolvedUrl;

  /// 本地漫游缓存命中的文件（非 null 时**优先于** [_resolvedUrl] 渲染）。
  ///
  /// 语义见 `docs/architecture/flutter-local-media-cache.md`：本地有就永远能看，
  /// 云端是否过期不影响。
  File? _cachedFile;
  bool _originalExpired = false;

  /// 是否已因「本地缓存文件解码失败」回退过一次（防无限递归，见 errorBuilder）。
  bool _fellBackFromCache = false;

  /// 重试计数（web 用 `key={`${resolvedSrc}:${retry}`}` 强制重建 `<img>`）。
  int _retry = 0;

  /// 已上报的状态（去重，避免同一状态反复回调）。
  AylaResourceImageState? _notified;

  /// 上报加载状态（见 [AylaResourceImage.onStateChanged]）。
  void _notifyState() {
    final ValueChanged<AylaResourceImageState>? callback =
        widget.onStateChanged;
    if (callback == null) return;
    final AylaResourceImageState next = switch (_state) {
      _State.loading => AylaResourceImageState.loading,
      _State.ready => AylaResourceImageState.ready,
      _State.failed => AylaResourceImageState.failed,
      _State.expired => AylaResourceImageState.expired,
    };
    if (_notified == next) return;
    _notified = next;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) callback(next);
    });
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant AylaResourceImage old) {
    super.didUpdateWidget(old);
    if (old.src != widget.src ||
        old.variant != widget.variant ||
        !identical(old.previewImage, widget.previewImage)) {
      // 换图 ⇒ 允许新的回退机会（防递归守卫只在同一张图的加载周期内有效）
      _fellBackFromCache = false;
      _load();
    }
  }

  /// 本次渲染实际使用的注入图源：显式参数优先，其次预览总开关，最后 null（走真实链路）。
  ImageProvider? get _injectedImage {
    final ImageProvider? explicit = widget.previewImage;
    if (explicit != null) return explicit;
    // 演示特殊态的样张强制走真实链路（过期/失败/装饰静默不能被示例图盖掉）
    if (widget.ignoreSampleMedia) return null;
    if (aylaSampleMediaEnabled) return aylaSampleImageFor(widget.src);
    return null;
  }

  Future<void> _load() async {
    // 预览注入：直接进入就绪态，**不走签名/网络**（示例图不是真实媒体）
    if (_injectedImage != null) {
      if (!mounted) return;
      setState(() {
        _state = _State.ready;
        _resolvedUrl = null;
        _originalExpired = false;
      });
      _notifyState();
      return;
    }
    setState(() {
      _state = _State.loading;
      _resolvedUrl = null;
      _cachedFile = null;
      _originalExpired = false;
      // ⚠️ **不在这里重置** _fellBackFromCache：本方法会被 errorBuilder 递归调用，
      // 在这里清零等于把守卫拆掉（死循环复现）。守卫只在 didUpdateWidget
      // （src/variant 变化，即用户切到另一张图）与 _retryLoad（用户点重试）时重置。
    });
    _notifyState();

    // ⚠️ 空 src 直接判失败，**绝不能**走下面的 ready 分支（2026-10-22 卡死根因）：
    // 空串会让 Image.network('') 立刻报错 → errorBuilder → setState(failed)
    // → 若外层再触发重建，就形成「load → 空 URL → 报错 → load」死循环，
    // 表现为进入私聊页后 UI 线程被吃满、应用卡死闪退。
    if (widget.src.trim().isEmpty) {
      if (!mounted) return;
      setState(() => _state = _State.failed);
      _notifyState();
      return;
    }

    final String? mediaId = extractMediaId(widget.src);
    if (mediaId == null) {
      // 外部资源 / 非媒体路径：直接加载（不缓存）
      if (!mounted) return;
      setState(() {
        _resolvedUrl = widget.src;
        _state = _State.ready;
      });
      _notifyState();
      return;
    }

    // ① 本地漫游缓存优先：命中直接渲染本地文件，**不发任何网络请求**
    //    （连签名都不签）。本地有就永远能看，云端过期不影响（用户裁决 D3）。
    //    thumb 变体不缓存（D1），此调用会直接返回 null。
    final File? cached = await AylaMediaCache.instance.lookup(
      mediaId,
      kind: _cacheKindFor(widget.src),
      variant: widget.variant == MediaVariant.thumb
          ? AylaMediaCacheVariant.thumb
          : AylaMediaCacheVariant.original,
    );
    if (!mounted) return;
    if (cached != null) {
      setState(() {
        _cachedFile = cached;
        _resolvedUrl = null;
        _originalExpired = false;
        _state = _State.ready;
      });
      _notifyState();
      return;
    }

    try {
      final SignedMediaResult r =
          await MediaSigner.instance.sign(mediaId, variant: widget.variant);
      if (!mounted) return;
      setState(() {
        _resolvedUrl = r.url;
        _originalExpired = r.originalExpired;
        _state = _State.ready;
      });
      _notifyState();
      // ② 加载即存（用户裁决 D4）：签名成功且**原图仍完好**时静默落盘。
      //    不 await、不提示——缓存是增强项，失败不影响本次显示。
      //    阶段 1（originalExpired）不缓存：那是缩略图，不是原图（D1）。
      if (!r.originalExpired && widget.variant != MediaVariant.thumb) {
        unawaited(
          AylaMediaCache.instance
              .fetchAndStore(
                mediaId: mediaId,
                kind: _cacheKindFor(widget.src),
              )
              .catchError((Object _) => null),
        );
      }
    } on MediaExpiredError {
      // 完全过期且本地没有：占位不裂图（重试无意义）
      if (!mounted) return;
      setState(() => _state = _State.expired);
      _notifyState();
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = _State.failed);
      _notifyState();
    }
  }

  /// 由媒体路径推断缓存分类（用于分桶目录的 kind 层）。
  ///
  /// 图片组件只承载 image / emoji 两类；其余 kind 不会走到这里。
  AylaMediaKind _cacheKindFor(String src) => AylaMediaKind.image;

  /// 重试（web `retryImage`：失效缓存 + 重建 `<img>`）。
  void _retryLoad() {
    final String? mediaId = extractMediaId(widget.src);
    if (mediaId != null) MediaSigner.instance.invalidate(mediaId);
    // 用户主动重试 ⇒ 重新给一次「缓存失败回退远程」的机会
    _fellBackFromCache = false;
    setState(() => _retry++);
    _load();
  }

  bool get _decorative => widget.alt.isEmpty;

  @override
  Widget build(BuildContext context) {
    final AylaTextStyles t = AylaTextStyles.of(context);

    switch (_state) {
      case _State.expired:
        // 完全过期占位（`.resource-image-expired`：灰底 + 文字，不重试）
        if (_decorative) {
          return widget.fallback ?? const SizedBox.shrink();
        }
        return _ExpiredPlaceholder(style: t);

      case _State.failed:
        // 装饰图失败 → 只渲染 fallback（不提示）
        if (_decorative) {
          return widget.fallback ?? const SizedBox.shrink();
        }
        return _FailedPlaceholder(
          onRetry: _retryLoad,
          fallback: widget.fallback,
          style: t,
        );

      case _State.loading:
        // 加载中（`.resource-image-loading` 常配 skeleton）
        if (_decorative) {
          // 装饰图加载中：留空（web 只渲染 fallback，常为 null）
          return widget.fallback ?? const SizedBox.shrink();
        }
        return widget.reserveSpaceWhileLoading
            ? _LoadingPlaceholder(width: widget.width, height: widget.height)
            : const SizedBox.shrink();

      case _State.ready:
        // 预览注入（样张示例图）：直接渲染注入的 ImageProvider（不走网络）
        if (_injectedImage case final ImageProvider preview) {
          // 同样按显示尺寸解码（与网络分支同口径，零观感风险）。
          // ⚠️ `Image` widget 本身**没有** `cacheWidth/cacheHeight`（那是
          // `Image.network/asset` 等**构造函数**的参数）⇒ 注入 ImageProvider 的场景
          // 必须用 `ResizeImage` 包一层（官方等价物，语义相同）。
          final double previewDpr = MediaQuery.devicePixelRatioOf(context);
          // 🔴 同上面主链路的 exact 陷阱：`ResizeImage` 的默认 policy 就是 exact
          // （image_provider.dart:838–851，两个都传 = BoxFit.fill）⇒ **也只传长边**。
          final ImageProvider previewSized;
          if (widget.width == null && widget.height == null) {
            previewSized = preview;
          } else {
            final bool useW = widget.height == null ||
                (widget.width != null && widget.width! >= widget.height!);
            previewSized = ResizeImage(
              preview,
              width: useW && widget.width != null
                  ? (widget.width! * previewDpr).round().clamp(1, 8192)
                  : null,
              height: !useW && widget.height != null
                  ? (widget.height! * previewDpr).round().clamp(1, 8192)
                  : null,
              allowUpscaling: false,
            );
          }
          final Widget previewImg = Image(
            image: previewSized,
            key: ValueKey<String>('preview:$_retry'),
            width: widget.width,
            height: widget.height,
            fit: widget.fit ?? BoxFit.cover,
            // ⚠️ 注入图也是**异步解码**的：解码完成前 RenderImage 的尺寸是 0×0
            // （loose 约束下取 constraints.smallest）→ 样张会短暂空白。
            // 与真实链路同样加 `frameBuilder`，解码前显示骨架（实测解码后为固有尺寸，
            // 例如示例图 480×360）。
            frameBuilder: (
              BuildContext context,
              Widget child,
              int? frame,
              bool wasSync,
            ) {
              if (wasSync || frame != null) return child;
              if (_decorative) return widget.fallback ?? const SizedBox.shrink();
              return widget.reserveSpaceWhileLoading
                  ? _LoadingPlaceholder(width: widget.width, height: widget.height)
                  : const SizedBox.shrink();
            },
          );
          if (_originalExpired && widget.expiredBadge) {
            return Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                previewImg,
                Positioned(
                  top: 8,
                  right: 8,
                  child: _ExpiredBadge(style: t),
                ),
              ],
            );
          }
          return previewImg;
        }
        // ⚠️ **按显示尺寸解码**（2026-10-16 性能整改）：全库此前 0 处 `cacheWidth/`cacheHeight`，
        // 图片一律按**原始分辨率**解码（4000×3000 ≈ 48MB RGBA）再上传 GPU，
        // 而缩略槽位可能只有 240×180 ⇒ 单张浪费约两个数量级的显存与带宽。
        // 危害集中在滚动/入场：解码在后台 isolate，但**纹理上传/raster 在 UI 线程侧**。
        // 这里按「布局尺寸 × DPR」取整作为解码尺寸 —— 解码尺寸 ≥ 显示尺寸时逐像素一致，**零观感风险**。
        //
        // 🔴 **只传一个维度**（2026-10-22 修用户实报「图片被拉伸」）：
        // `Image.network/file` 的 `cacheWidth` + `cacheHeight` 最终走
        // `ImageProvider.resizeIfNeeded`（flutter/lib/src/painting/image_provider.dart:1306–1315），
        // 它**不传 policy** ⇒ 落回 `ResizeImagePolicy.exact`。exact 的文档原话
        // （同文件 :838–851）：
        //   "If width and height are both non-null, the output image will have the
        //    specified width and height **regardless of whether it matches the source
        //    image's intrinsic aspect ratio**. This case is **similar to BoxFit.fill**."
        // ⇒ 两个都传会把**解码缓冲**压成显示框的宽高比，出图阶段再 `BoxFit.cover`
        //   也救不回来（源像素比例已经错）= 「图片被拉伸」的真实机制。
        // 只传一个维度时 exact 退化为 `fitWidth`/`fitHeight`（同文件 :847–851 明确）：
        // **保持原始宽高比**，同时仍把另一条边的像素量压到显示尺寸 ⇒ 性能整改不回退。
        // 选哪一维：取**长边**（限制长边即可决定缩放比；限制短边会让长边仍按原始
        // 分辨率解码，白花内存）。
        final double dpr = MediaQuery.devicePixelRatioOf(context);
        final int? decodeW;
        final int? decodeH;
        if (widget.width == null && widget.height == null) {
          decodeW = null;
          decodeH = null;
        } else if (widget.height == null) {
          decodeW = (widget.width! * dpr).round().clamp(1, 8192);
          decodeH = null;
        } else if (widget.width == null) {
          decodeW = null;
          decodeH = (widget.height! * dpr).round().clamp(1, 8192);
        } else if (widget.width! >= widget.height!) {
          decodeW = (widget.width! * dpr).round().clamp(1, 8192);
          decodeH = null;
        } else {
          decodeW = null;
          decodeH = (widget.height! * dpr).round().clamp(1, 8192);
        }
        // 本地漫游缓存命中 → Image.file（不再走网络）；否则 Image.network。
        // key 区分本地/远程，避免同一媒体在两种来源间切换时复用错误的解码缓存。
        final Widget img = _cachedFile != null
            ? Image.file(
                _cachedFile!,
                key: ValueKey<String>('file:${_cachedFile!.path}:$_retry'),
                width: widget.width,
                height: widget.height,
                cacheWidth: decodeW,
                cacheHeight: decodeH,
                fit: widget.fit ?? BoxFit.cover,
                errorBuilder: (BuildContext context, Object e, StackTrace? s) {
                  // 本地文件损坏/被外部删除 → 当作未命中，重走远程链路**一次**。
                  // ⚠️ 必须带 _fellBackFromCache 守卫：否则「缓存文件坏 → 清空 →
                  //   _load 又命中同一缓存 → 再坏」会无限递归（2026-10-22 卡死根因之一）。
                  if (!_fellBackFromCache) {
                    _fellBackFromCache = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      _cachedFile = null;
                      _load();
                    });
                  }
                  return widget.fallback ?? const SizedBox.shrink();
                },
                frameBuilder: (
                  BuildContext context,
                  Widget child,
                  int? frame,
                  bool wasSync,
                ) {
                  if (wasSync || frame != null) return child;
                  if (_decorative) {
                    return widget.fallback ?? const SizedBox.shrink();
                  }
                  return widget.reserveSpaceWhileLoading
                      ? _LoadingPlaceholder(
                          width: widget.width,
                          height: widget.height,
                        )
                      : const SizedBox.shrink();
                },
              )
            : Image.network(
          _resolvedUrl!,
          key: ValueKey<String>('${_resolvedUrl!}:$_retry'), // 重试时强制重建
          width: widget.width,
          height: widget.height,
          cacheWidth: decodeW,
          cacheHeight: decodeH,
          fit: widget.fit ?? BoxFit.cover, // object-fit
          // 加载失败 → 走失败态（web onError）
          errorBuilder: (BuildContext context, Object e, StackTrace? s) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _state != _State.failed) {
                setState(() => _state = _State.failed);
                _notifyState();
              }
            });
            return widget.fallback ?? const SizedBox.shrink();
          },
          frameBuilder: (
            BuildContext context,
            Widget child,
            int? frame,
            bool wasSync,
          ) {
            // 首帧未到 + 非装饰图 → 显示骨架（web resource-image-loading）
            if (wasSync || frame != null) return child;
            if (_decorative) return widget.fallback ?? const SizedBox.shrink();
            return widget.reserveSpaceWhileLoading
                ? _LoadingPlaceholder(width: widget.width, height: widget.height)
                : const SizedBox.shrink();
          },
        );

        // 原图已过期（阶段 1）→ 叠加角标（`.resource-image-expired-badge`）
        if (_originalExpired && widget.expiredBadge) {
          return Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              img,
              Positioned(
                top: 8,
                right: 8,
                child: _ExpiredBadge(style: t),
              ),
            ],
          );
        }
        return img;
    }
  }
}

/// `.async-state-skeleton` 风格的加载占位（灰玻璃底 + frost-pulse）。
class _LoadingPlaceholder extends StatelessWidget {
  const _LoadingPlaceholder({this.width, this.height});

  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      constraints: BoxConstraints(
        minWidth: width == null ? 40 : 0, // `.resource-image-fallback` min-width 40
        minHeight: height == null ? 32 : 0, // min-height 32
      ),
      color: AylaColors.glassBg, // background: var(--glass-bg)
    );
  }
}

/// `.resource-image-expired` —— 完全过期占位（灰底 + 文字，**不提供重试**）。
class _ExpiredPlaceholder extends StatelessWidget {
  const _ExpiredPlaceholder({required this.style});

  final AylaTextStyles style;

  @override
  Widget build(BuildContext context) {
    return Container(
      // min-width: 96px; min-height: 64px; padding: var(--sp-3)
      constraints: const BoxConstraints(minWidth: 96, minHeight: 64),
      padding: const EdgeInsets.all(AylaSpacing.sp3),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AylaColors.glassBg, // background: var(--glass-bg)
        border: Border.all(color: AylaColors.glassBorder), // 1px --glass-border
        borderRadius: BorderRadius.circular(AylaRadii.rInput), // radius-input 12
      ),
      child: Text(
        '已过期',
        textAlign: TextAlign.center,
        style: style.caption.copyWith(
          fontSize: 13, // font-size: 13px
          color: AylaColors.textSecondary,
        ),
      ),
    );
  }
}

/// 失败占位：`fallback` + 「图片加载失败，点击重试」按钮
/// （`.resource-image-fallback`）。
class _FailedPlaceholder extends StatelessWidget {
  const _FailedPlaceholder({
    required this.onRetry,
    required this.style,
    this.fallback,
  });

  final VoidCallback onRetry;
  final AylaTextStyles style;
  final Widget? fallback;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (fallback != null) fallback!,
        // 重试键在 web 是 <button>（ResourceImage.tsx:156）⇒ base.css:340 全局 pointer。
        Semantics(
          button: true,
          label: '图片加载失败，重试',
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
            onTap: onRetry,
            child: Container(
              // min-width: 40px; min-height: 32px; padding: 4px 8px; radius-sm 8
              constraints: const BoxConstraints(minWidth: 40, minHeight: 32),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AylaColors.glassBg, // background: var(--glass-bg)
                borderRadius: BorderRadius.circular(AylaRadii.rSm),
              ),
              child: Text(
                '图片加载失败，点击重试',
                style: style.caption.copyWith(
                  fontSize: 11, // font-size: 11px
                  color: AylaColors.textSecondary,
                ),
              ),
            ),
          ),
        ),
        ),
      ],
    );
  }
}

/// `.resource-image-expired-badge` —— 「原图已过期」角标（右上角深色胶囊）。
class _ExpiredBadge extends StatelessWidget {
  const _ExpiredBadge({required this.style});

  final AylaTextStyles style;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        // padding: 2px 8px; border-radius: pill
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          // background: rgba(20,24,40,.72) + backdrop blur(6px)
          color: const Color(0xB8141828),
          borderRadius: AylaRadii.pill,
        ),
        child: Text(
          '原图已过期',
          style: style.caption.copyWith(
            fontSize: 11, // font-size: 11px
            fontWeight: FontWeight.w600, // font-weight: 600
            height: 1.6, // line-height: 1.6
            color: const Color(0xEBFFFFFF), // rgba(255,255,255,.92)
          ),
        ),
      ),
    );
  }
}
