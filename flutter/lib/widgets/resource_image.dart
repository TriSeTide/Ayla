/// 统一图片加载事实（`components/ResourceImage.tsx` 的 Flutter 等价）。
///
/// ## 事实源（`ResourceImage.tsx` + `api/media.ts` + base.css 588–679）
///
/// **加载路径**
/// - 内部媒体（src 以 `/api/v1/media/` 开头）→ 提取 `media_id` → 走签名链路
///   （[MediaSigner]）：短时签名 URL ＋ 两级过期降级；
/// - 外部资源 / 非媒体路径 → **直接加载**（不签名）。
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
library;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../theme/app_theme.dart';
import '../theme/preview_theme.dart';
import '../theme/tokens.dart';
import '../core/media/media_signer.dart';
import '../core/net/dio_client.dart';

/// 后端 API 前缀（与 `api/client.ts` 的 `API_PREFIX` 一致）。
const String kApiPrefix = '/api/v1';

/// 媒体路径前缀（`api/media.ts` 的 `MEDIA_PATH_PREFIX`）。
const String kMediaPathPrefix = '$kApiPrefix/media/';

/// 从媒体 URL 提取 media_id（`extractMediaId`）。
///
/// 仅识别 `/api/v1/media/<id>/...` 形式；非媒体路径返回 null（外部资源直接加载）。
String? extractMediaId(String src) {
  if (!src.startsWith(kMediaPathPrefix)) return null;
  final String rest = src.substring(kMediaPathPrefix.length);
  final int slash = rest.indexOf('/');
  if (slash <= 0) return null;
  return rest.substring(0, slash);
}

/// 统一图片组件（对应 `ResourceImage`）。
class ResourceImage extends StatefulWidget {
  const ResourceImage({
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

  @override
  State<ResourceImage> createState() => _ResourceImageState();
}

/// 加载状态机（对应 tsx 的 `expired` / `failed` / `resolvedSrc`）。
enum _State { loading, ready, failed, expired }

class _ResourceImageState extends State<ResourceImage> {
  _State _state = _State.loading;
  String? _resolvedUrl;
  bool _originalExpired = false;

  /// 重试计数（web 用 `key={`${resolvedSrc}:${retry}`}` 强制重建 `<img>`）。
  int _retry = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ResourceImage old) {
    super.didUpdateWidget(old);
    if (old.src != widget.src || old.variant != widget.variant) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _state = _State.loading;
      _resolvedUrl = null;
      _originalExpired = false;
    });

    final String? mediaId = extractMediaId(widget.src);
    if (mediaId == null) {
      // 外部资源 / 非媒体路径：直接加载
      if (!mounted) return;
      setState(() {
        _resolvedUrl = widget.src;
        _state = _State.ready;
      });
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
    } on MediaExpiredError {
      // 完全过期：媒体已永久删除，重试无意义 → 占位不裂图
      if (!mounted) return;
      setState(() => _state = _State.expired);
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = _State.failed);
    }
  }

  /// 重试（web `retryImage`：失效缓存 + 重建 `<img>`）。
  void _retryLoad() {
    final String? mediaId = extractMediaId(widget.src);
    if (mediaId != null) MediaSigner.instance.invalidate(mediaId);
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
        final Widget img = Image.network(
          _resolvedUrl!,
          key: ValueKey<String>('${_resolvedUrl!}:$_retry'), // 重试时强制重建
          width: widget.width,
          height: widget.height,
          fit: widget.fit ?? BoxFit.cover, // object-fit
          // 加载失败 → 走失败态（web onError）
          errorBuilder: (BuildContext context, Object e, StackTrace? s) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _state != _State.failed) {
                setState(() => _state = _State.failed);
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
        Semantics(
          button: true,
          label: '图片加载失败，重试',
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

// ======================= 预览 =======================

/// ResourceImage 全状态（正常 / 装饰图 / 失败重试 / 原图过期角标）。
///
/// ⚠️ **「原图已过期」角标只有签名链路能产生**（`original` 410 → 自动降级 thumb
/// 并置 `originalExpired=true`，见 `api/media.ts` 50–53）。用**外部 URL**
/// 或未注入 client 都永远看不到角标。
///
/// 故本预览注入一个**受控假 client**：让 media_id 以 `expired-original` 开头的
/// 请求走「original 410 → thumb 成功且 originalExpired=true」分支 ——
/// 与真实降级路径**同一代码**，只是数据源可控（不改生产语义）。
@Preview(
  group: 'Widgets',
  name: 'ResourceImage（正常/装饰/失败/角标）',
  size: Size(720, 340),
  wrapper: previewTheme,
)
Widget previewResourceImage() {
  // 注入假 client：演示签名链路的降级分支
  MediaSigner.instance.attach(_PreviewMediaClient());
  const String ok = 'https://picsum.photos/seed/ayla-ri/240/180';
  // 该 id 触发「原图已过期」降级（假 client 对 original 返 410）
  const String expiredOriginal = '/api/v1/media/expired-original/content';
  // 该 id 触发「完全过期」（original 与 thumb 都 410）
  const String fullyExpired = '/api/v1/media/fully-expired/content';
  // 普通媒体 id：签名成功
  const String normalMedia = '/api/v1/media/normal-id/content';

  Widget cell(String label, Widget child) => Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(width: 200, height: 150, child: child),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      );

  return Padding(
    padding: const EdgeInsets.all(AylaSpacing.sp4),
    child: Wrap(
      spacing: AylaSpacing.sp4,
      runSpacing: AylaSpacing.sp4,
      children: <Widget>[
        cell('正常（外部 URL 直连）', const ResourceImage(src: ok, alt: '示例图')),
        cell(
          '签名成功（原图）',
          const ResourceImage(src: normalMedia, alt: '正常图'),
        ),
        cell(
          '⭐ 原图已过期 → 缩略图 + 角标',
          const ResourceImage(
            src: expiredOriginal,
            alt: '图',
            expiredBadge: true, // 必须为 true 才显示角标（同 web）
          ),
        ),
        cell(
          '完全过期 → 「已过期」占位（不重试）',
          const ResourceImage(src: fullyExpired, alt: '图'),
        ),
        cell(
          '装饰图（alt="" → 过期不提示）',
          const ResourceImage(src: fullyExpired), // alt 默认 ''
        ),
      ],
    ),
  );
}


/// 预览用假签名 client：按 media_id 前缀模拟后端 `:sign` 的分级过期行为。
///
/// - `expired-original` → original 返 410、thumb 返 URL（**阶段 1 降级**）
/// - `fully-expired`    → original 与 thumb 都返 410（**阶段 2 完全过期**）
/// - 其余                → 返回占位图 URL（签名成功）
///
/// 与真实 `MediaSigner._sign` 走**同一条降级代码路径**，只是数据源可控。
class _PreviewMediaClient implements DioClient {
  @override
  Future<T> post<T>(
    String path,
    {Object? body, Map<String, dynamic>? query}
  ) async {
    final bool isThumb = body is Map && body['variant'] == 'thumb';
    final bool expiredOriginal = path.contains('expired-original');
    final bool fullyExpired = path.contains('fully-expired');

    if ((expiredOriginal && !isThumb) || fullyExpired) {
      throw const ApiException(410, 'media_expired'); // → 触发降级/过期分支
    }
    return <String, dynamic>{
      'url': 'https://picsum.photos/seed/ayla-${isThumb ? "thumb" : "orig"}/240/180',
      'expires_at': DateTime.now().millisecondsSinceEpoch / 1000 + 3600,
    } as T;
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
