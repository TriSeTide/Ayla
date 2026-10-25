/// 本地媒体缓存（**漫游缓存**）—— Flutter 侧媒体链路的磁盘层。
///
/// 事实源：`Ayla/docs/architecture/flutter-local-media-cache.md`（2026-10-21 定稿）。
///
/// ## 为什么存在
///
/// 云端 MinIO 对聊天媒体做分级过期（图片 7 天删原图 / 30 天全过期；语音·文件·视频
/// 7 天全删）。用户的诉求是「**能看到图片永远比不能看到好，云端过期只是服务器存储
/// 优化**」⇒ 客户端把**看过/加载过**的原始字节静默留在本地，此后本地有就一直能看，
/// 与云端是否过期无关（文档 §2 D3/D4）。
///
/// ## 三条硬约束（用户拍板，改之前先读文档）
///
/// - **无上限、不自动清理**（D2）：不做 LRU、不设总量、不按 TTL 删。
///   仅暴露 [stats] 供后续「清理缓存」功能使用；[evict] 只按显式调用生效。
/// - **跨账号共享**（D5）：目录里**没有** user_id 段 —— 同一台机器上 A 号看过的图，
///   B 号也能命中。
/// - **缩略图与原图共存**（2026-10-23 用户改版，**取代旧的 D1「只缓存 original」**）：
///   图片「看见先存缩略图；点开大图才用原图取代缩略图」。两种形态用文件名后缀
///   `.thumb` 区分（见 [AylaMediaCacheLayout.pathFor]），**互不覆盖**。
///   旧的 D1 理由是「把 thumb 字节冒充原图会污染『本地有 = 原图有』的语义」——
///   新规则下这个担心不再成立，因为**两种形态物理上分开存**，[lookupForDisplay]
///   还能分辨拿到的是哪一种。
/// - **按需落盘，不默认全存**（2026-10-23 用户改版，**部分取代旧的 D4「加载即存」**）：
///   落盘时机按媒体类型区分：
///   | 类型 | 何时落盘 | 用户原话 |
///   |---|---|---|
///   | 图片 | 看见（气泡内渲染）→ 存 **thumb**；点开查看器 → 存 **original** | 「看到了图片是保存缩略图，只有点开图片后才取代刚保存的缩略图保存原图」 |
///   | 语音 | **点击播放**才存（不点击不存） | 「语音则是点击语音即保存本地，不点击不保存」 |
///   | 视频 | 加载即存（D4 不变） | — |
///   | **文件** | **永不自动存**；只有用户点「保存」按钮（系统保存对话框）才落盘 | 「这一点不包括保存文件消息，文件消息需要手动点击保存才保存到本地」 |
///
///   ⚠️ 缓存层只提供**能力**（[fetchAndStore]/[storeBytes] 的 `variant` 与时序由
///   调用方决定），真正的时机在组件里；本文件的注释只说明每条链路该怎么用。
///
/// ## 布局
///
/// 见 [AylaMediaCacheLayout]
/// (`media-cache/<kind>/<media_id 前2位>/<media_id>[.thumb].<ext>`)。
///
/// ## 读链路语义（文档 §5）
///
/// | 场景 | 行为 |
/// |---|---|
/// | 本地命中 | 直接返回 File，**连签名都不发** |
/// | 本地未命中 + 云端可用 | 下载 → 返回 File → 静默落盘 |
/// | 本地未命中 + 云端 410 | 抛 [MediaExpiredError]（调用方显示「已过期」占位） |
/// | 本地命中 + 云端 410 | 正常返回本地 File，**不报过期** |
///
/// ## 原子写（文档 §6）
///
/// `写入 <target>.tmp → flush → rename(<target>.tmp, <target>)`。
/// 崩溃/断电最多留下 `.tmp`，启动时由 [cleanupTempFiles] 清理；**半截文件永远不会
/// 以正式文件名出现**，因此 [lookup] 不会读到不完整的字节。
///
/// ## 并发（文档 §7）
///
/// 同一 `kind + media_id` 的并发 [fetchAndStore] 只真正下载一次
/// （`Map<String, Future<File?>> _inflight`，与 [MediaSigner] 同做法）。
///
/// ## 纪律
///
/// 缓存是**增强项**：任何缓存失败（不可写、磁盘满、路径非法）都只 `debugPrint`，
/// **绝不打断**媒体显示与播放链路。唯一会向调用方抛的是媒体自身已过期
/// （[MediaExpiredError]，语义来自后端 410，不是缓存故障）。
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/media_kind.dart';
import 'media_cache_paths.dart';
import 'media_signer.dart';

/// 缓存条目形态（2026-10-23 用户改版：**两种都会落盘**，各自独立路径）。
///
/// 旧规则（2026-10-21 D1）是「只缓存 original，thumb 查不到也写不进」；
/// 用户 2026-10-23 明确改成「图片看见先存缩略图、点开大图才用原图取代缩略图」
/// ⇒ thumb 必须能落盘、能命中，且与 original **互不覆盖**（见
/// [AylaMediaCacheLayout.pathFor] 的 `isThumb`）。
enum AylaMediaCacheVariant {
  /// 原始对象（原图 / 原音频 / 原视频 / 原文件）。
  original,

  /// 缩略图派生（图片气泡内看见时先存的那份；`.thumb` 后缀）。
  thumb,
}

/// 签名器抽象（测试注入点）：默认走 [MediaSigner.instance]。
typedef AylaMediaCacheSigner = Future<SignedMediaResult> Function(
  String mediaId, {
  MediaVariant? variant,
});

/// 字节下载器抽象（测试注入点）：默认走 dio。
typedef AylaMediaCacheDownloader = Future<Uint8List> Function(String url);

/// 缓存统计（供后续「清理缓存」功能展示/按类型清理，文档 §10）。
@immutable
class AylaMediaCacheStats {
  const AylaMediaCacheStats({
    required this.totalBytes,
    required this.fileCount,
    required this.bytesByKind,
    required this.fileCountByKind,
  });

  /// 全部缓存文件总字节。
  final int totalBytes;

  /// 全部缓存文件数。
  final int fileCount;

  /// 按 kind 的字节数（键为 [AylaMediaKind.wire]）。
  final Map<String, int> bytesByKind;

  /// 按 kind 的文件数。
  final Map<String, int> fileCountByKind;

  /// 空统计（遍历失败/目录不存在时返回）。
  static const AylaMediaCacheStats empty = AylaMediaCacheStats(
    totalBytes: 0,
    fileCount: 0,
    bytesByKind: <String, int>{},
    fileCountByKind: <String, int>{},
  );

  @override
  String toString() =>
      'AylaMediaCacheStats(bytes=$totalBytes, files=$fileCount, byKind=$bytesByKind)';
}

/// 展示用命中结果（[AylaMediaCache.lookupForDisplay] 的返回）。
///
/// 2026-10-23 用户改版后同一张图可能只有缩略图、也可能原图已有 ⇒ 调用方需要
/// 知道拿到的是哪一种（查看器尤其要：thumb 命中时**仍应去取原图**）。
@immutable
class AylaMediaCacheHit {
  const AylaMediaCacheHit({required this.file, required this.isThumb});

  /// 命中的本地文件。
  final File file;

  /// 是否为缩略图形态（`<media_id>.thumb.<ext>`）。
  final bool isThumb;

  @override
  String toString() => 'AylaMediaCacheHit(${file.path}, isThumb: $isThumb)';
}

/// 本地媒体缓存（单例：[AylaMediaCache.instance]）。
///
/// 测试可直接 `AylaMediaCache(platform: 假平台)` 造独立实例，避免单例状态串味
/// （见 `test/media_cache_test.dart`）。
class AylaMediaCache {
  /// 生产单例。
  ///
  /// 启动期由 `main.dart` 调一次 [ensureReady] 预热（解析根 + 探测可写 + 清 `.tmp`）；
  /// 未预热时任何读写调用也会 lazy 触发同一幂等 future，故两条路径不重复探测。
  static final AylaMediaCache instance = AylaMediaCache();

  AylaMediaCache({
    AylaMediaCachePlatform platform = const AylaIoMediaCachePlatform(),
    AylaMediaCacheSigner? signer,
    AylaMediaCacheDownloader? downloader,
  })  : _platform = platform,
        _signer = signer,
        _downloader = downloader;

  final AylaMediaCachePlatform _platform;

  AylaMediaCacheSigner? _signer;
  AylaMediaCacheDownloader? _downloader;

  /// 总开关：false 时所有读写都**同步返回空**、不碰磁盘。
  ///
  /// 生产恒为 true。widget 测试里 Flutter 跑在 FakeAsync 下，真实磁盘 IO 的
  /// future 不会被推进 ⇒ 任何 `await` 缓存的组件都会卡在 loading 态。测试用
  /// 此开关把缓存层整个短路，保持与"没有缓存"时代完全一致的时序。
  bool _enabled = true;

  /// 缓存是否启用（见 [_enabled]）。
  bool get enabled => _enabled;

  /// 全局启用/关闭（测试隔离用）。关闭时同时丢弃已解析布局，重新打开会重新解析。
  @visibleForTesting
  set enabledForTest(bool value) {
    _enabled = value;
    if (!value) {
      _layout = null;
      _layoutFuture = null;
      _resolvedPaths.clear();
    }
  }

  /// 解析后的布局（[ensureReady] 之后非 null）。
  AylaMediaCacheLayout? _layout;
  Future<AylaMediaCacheLayout>? _layoutFuture;

  /// 启动期 `.tmp` 扫除是否已做过（只做一次）。
  bool _tempsCleaned = false;

  /// 同媒体并发去重（文档 §7）。
  final Map<String, Future<File?>> _inflight = <String, Future<File?>>{};

  /// 已知落盘路径索引：`<kind>|<media_id>|<variant>` → 绝对路径。
  ///
  /// **只加速 [lookup]**（避免每次列分桶目录）；文件被外部删除时以 `exists()` 兜住。
  /// 上限 [kResolvedPathMemoLimit]：这只是内存里的查找加速表，**不是**磁盘缓存策略
  /// （D2 的"无上限"约束作用于磁盘文件，见 [AylaMediaCacheStats]）。溢出时按插入顺序
  /// 淘汰最旧条目 —— 淘汰只会让下次 lookup 多扫一次分桶目录，**不会丢文件、不会丢命中**。
  final Map<String, String> _resolvedPaths = <String, String>{};

  /// 路径索引容量上限（见 [_resolvedPaths]）。
  static const int kResolvedPathMemoLimit = 4096;

  /// 记入路径索引（超上限时淘汰最旧一条）。
  void _memoizePath(String key, String path) {
    _resolvedPaths[key] = path;
    if (_resolvedPaths.length > kResolvedPathMemoLimit) {
      _resolvedPaths.remove(_resolvedPaths.keys.first);
    }
  }

  /// 测试注入点：替换布局（生产路径不设置）。
  ///
  /// widget 测试跑在 FakeAsync 下，`path_provider` 的 platform channel 没有
  /// 实现（`MissingPluginException`）⇒ 任何真实 `ensureReady()` 都会失败。
  /// 需要验证「落盘时机」的测试用它把根指到临时目录。
  @visibleForTesting
  set layoutForTest(AylaMediaCacheLayout? value) {
    _layout = value;
    _layoutFuture =
        value == null ? null : Future<AylaMediaCacheLayout>.value(value);
    _tempsCleaned = value != null; // 测试不扫 .tmp
  }

  /// 测试注入点：替换签名器（生产路径不设置）。
  @visibleForTesting
  set signerForTest(AylaMediaCacheSigner? value) => _signer = value;

  /// 测试注入点：替换下载器（生产路径不设置）。
  @visibleForTesting
  set downloaderForTest(AylaMediaCacheDownloader? value) => _downloader = value;

  /// 当前布局（未初始化时为 null）。
  AylaMediaCacheLayout? get layout => _layout;

  /// 解析根目录并完成一次性启动清理（幂等）。
  ///
  /// 不抛：根目录解析/建目录失败时仍返回布局对象，写入链路由 [storeBytes] 逐次记日志。
  Future<AylaMediaCacheLayout> ensureReady() {
    final Future<AylaMediaCacheLayout>? current = _layoutFuture;
    if (current != null) return current;
    final Future<AylaMediaCacheLayout> future = _init();
    _layoutFuture = future;
    return future;
  }

  Future<AylaMediaCacheLayout> _init() async {
    final AylaMediaCacheLayout layout =
        await aylaResolveMediaCacheLayout(platform: _platform);
    _layout = layout;
    debugPrint('[AylaMediaCache] 缓存根 = ${layout.root} '
        '(来源=${layout.source.name}${layout.degraded ? '，已降级' : ''})');
    await cleanupTempFiles();
    return layout;
  }

  // ---------------------------------------------------------------------------
  // 读
  // ---------------------------------------------------------------------------

  /// 本地查找**指定形态**（**不发任何网络请求**）。
  ///
  /// 2026-10-23 用户改版后 thumb 与 original **都能落盘**，因此本方法是
  /// 「按形态精确查」：
  /// - [AylaMediaCacheVariant.original] ⇒ 只返回 `<media_id>.<ext>`
  ///   （**不会**把 `.thumb` 那份当原图返回）；
  /// - [AylaMediaCacheVariant.thumb] ⇒ 只返回 `<media_id>.thumb.<ext>`。
  ///
  /// 调用方一般应该用 [lookupForDisplay]（「有原图就给原图，否则给缩略图」）；
  /// 只有明确要「这份必须是原图」（如查看器、保存）时才用本方法。
  ///
  /// 路径策略：先用内存索引 / 按 mime 推导的确定路径试一次；不中再扫该分桶目录
  /// （容忍「同一媒体不同调用点传了不同 mime_type」这种现实情况，不因此丢命中）。
  Future<File?> lookup(
    String mediaId, {
    AylaMediaKind kind = AylaMediaKind.image,
    String? mimeType,
    AylaMediaCacheVariant variant = AylaMediaCacheVariant.original,
  }) async {
    if (!_enabled) return null;
    if (!_isCacheableId(mediaId)) return null;
    final bool isThumb = variant == AylaMediaCacheVariant.thumb;
    try {
      final AylaMediaCacheLayout layout = await ensureReady();
      final String safe = aylaSafeMediaId(mediaId);
      final String key = _key(kind, safe, variant);

      final String? indexed = _resolvedPaths[key];
      if (indexed != null) {
        final File file = File(indexed);
        if (await file.exists()) return file;
        _resolvedPaths.remove(key);
      }

      if (mimeType != null && mimeType.trim().isNotEmpty) {
        final File direct = File(layout.pathFor(
          kind,
          safe,
          mimeType: mimeType,
          isThumb: isThumb,
        ));
        if (await direct.exists()) {
          _memoizePath(key, direct.path);
          return direct;
        }
      }

      final File? scanned =
          await _scanShard(layout, kind, safe, isThumb: isThumb);
      if (scanned != null) _memoizePath(key, scanned.path);
      return scanned;
    } catch (error) {
      debugPrint('[AylaMediaCache] lookup 失败（按未命中处理）：$mediaId $error');
      return null;
    }
  }

  /// 展示用查找：**优先原图，退而求其次缩略图**（2026-10-23 用户改版）。
  ///
  /// 语义来自用户原话「看到了图片是保存缩略图，只有点开图片后才取代刚保存的
  /// 缩略图保存原图」⇒ 同一张图可能只有 thumb，也可能两者都有。展示时：
  /// 1. 有 original ⇒ 返回 original（原图更清晰，且缩略图是它的降级版）；
  /// 2. 只有 thumb ⇒ 返回 thumb（**能看到永远比看不到好**，与 D3 同源）。
  ///
  /// 返回值的形态可由 [AylaMediaCacheHit.isThumb] 分辨 —— 调用方据此决定是否
  /// 还要去取原图（当前唯一需要区分的是查看器）。
  Future<AylaMediaCacheHit?> lookupForDisplay(
    String mediaId, {
    AylaMediaKind kind = AylaMediaKind.image,
    String? mimeType,
  }) async {
    final File? original = await lookup(
      mediaId,
      kind: kind,
      mimeType: mimeType,
    );
    if (original != null) {
      return AylaMediaCacheHit(file: original, isThumb: false);
    }
    final File? thumb = await lookup(
      mediaId,
      kind: kind,
      mimeType: mimeType,
      variant: AylaMediaCacheVariant.thumb,
    );
    if (thumb != null) {
      return AylaMediaCacheHit(file: thumb, isThumb: true);
    }
    return null;
  }

  /// 同步版命中检查（供 build 期做快速分支）：**只查内存索引，不做 IO**。
  ///
  /// 返回 null 不代表「一定没有」，只代表「需要 [lookup] 进一步确认」。
  File? lookupIndexed(
    String mediaId, {
    AylaMediaKind kind = AylaMediaKind.image,
    AylaMediaCacheVariant variant = AylaMediaCacheVariant.original,
  }) {
    final String? path =
        _resolvedPaths[_key(kind, aylaSafeMediaId(mediaId), variant)];
    return path == null ? null : File(path);
  }

  /// 扫分桶目录：找**指定形态**的 `<media_id>[.thumb].<ext>`（跳过 `*.tmp`）。
  ///
  /// ⚠️ 必须按形态过滤 —— 两种形态在同一个目录里，若只按 `<media_id>.` 前缀匹配，
  /// 会把 `<media_id>.thumb.jpg` 当原图返回（反之亦然）。
  Future<File?> _scanShard(
    AylaMediaCacheLayout layout,
    AylaMediaKind kind,
    String safe, {
    required bool isThumb,
  }) async {
    final Directory dir = Directory(layout.dirFor(kind, safe));
    if (!await dir.exists()) return null;
    final String prefix = '$safe.';
    await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final String name = entity.uri.pathSegments.last;
      if (!name.startsWith(prefix)) continue;
      if (name.endsWith('.tmp')) continue;
      if (aylaIsThumbCacheFileName(name) != isThumb) continue;
      return entity;
    }
    return null;
  }

  /// 丢弃某形态的**内存索引**（不删磁盘文件）。
  ///
  /// 写盘后调用：让 [lookupForDisplay] 下次重新扫两种形态 —— 索引是
  /// `kind|id|variant` 三段的，形态之间本互不干扰，但跨形态的展示逻辑需要
  /// 两种都查一遍，写盘后清掉该 media 的全部索引最直接。
  void _forgetPaths(AylaMediaKind kind, String safe) {
    _resolvedPaths
      ..remove(_key(kind, safe, AylaMediaCacheVariant.original))
      ..remove(_key(kind, safe, AylaMediaCacheVariant.thumb));
  }

  // ---------------------------------------------------------------------------
  // 写
  // ---------------------------------------------------------------------------

  /// 落盘（字节版）。失败只记日志并返回 null（缓存是增强项，不抛）。
  ///
  /// [variant] 决定落到哪个文件（见 [AylaMediaCacheLayout.pathFor]）：
  /// - [AylaMediaCacheVariant.original] ⇒ `<media_id>.<ext>`
  /// - [AylaMediaCacheVariant.thumb]    ⇒ `<media_id>.thumb.<ext>`
  ///
  /// 2026-10-23 用户改版：thumb **可以**落盘（旧 D1 是直接拒绝）。
  Future<File?> storeBytes({
    required String mediaId,
    required AylaMediaKind kind,
    required List<int> bytes,
    String? mimeType,
    String? extension,
    AylaMediaCacheVariant variant = AylaMediaCacheVariant.original,
  }) async {
    if (!_enabled) return null;
    if (!_isCacheableId(mediaId)) return null;
    if (bytes.isEmpty) return null;
    final bool isThumb = variant == AylaMediaCacheVariant.thumb;
    try {
      final AylaMediaCacheLayout layout = await ensureReady();
      final File target = File(
        layout.pathFor(
          kind,
          mediaId,
          mimeType: mimeType,
          extension: extension,
          isThumb: isThumb,
        ),
      );
      final bool ok = await _atomicWriteBytes(target, bytes);
      if (!ok) return null;
      // 写盘后清掉该 media 的全部索引：让 [lookupForDisplay] 下次重新扫两种形态
      // （缩略图落盘不该把已存在的原图索引「盖」掉，反之亦然）。
      _forgetPaths(kind, aylaSafeMediaId(mediaId));
      _memoizePath(_key(kind, aylaSafeMediaId(mediaId), variant), target.path);
      return target;
    } catch (error) {
      debugPrint('[AylaMediaCache] storeBytes 失败（忽略）：$mediaId $error');
      return null;
    }
  }

  /// 落盘（文件版）：流式拷贝到 `.tmp` 再 rename，**不整文件读进内存**
  /// （视频/大附件要能存）。
  Future<File?> storeFile({
    required String mediaId,
    required AylaMediaKind kind,
    required File source,
    String? mimeType,
    String? extension,
    bool deleteSource = false,
    AylaMediaCacheVariant variant = AylaMediaCacheVariant.original,
  }) async {
    if (!_enabled) return null;
    if (!_isCacheableId(mediaId)) return null;
    final bool isThumb = variant == AylaMediaCacheVariant.thumb;
    try {
      final AylaMediaCacheLayout layout = await ensureReady();
      final File target = File(
        layout.pathFor(
          kind,
          mediaId,
          mimeType: mimeType,
          extension: extension,
          isThumb: isThumb,
        ),
      );
      final bool ok = await _atomicWriteFile(target, source);
      if (!ok) return null;
      // 同 [storeBytes]：清掉两种形态的索引，避免跨形态展示时读到过期索引。
      _forgetPaths(kind, aylaSafeMediaId(mediaId));
      _memoizePath(_key(kind, aylaSafeMediaId(mediaId), variant), target.path);
      if (deleteSource) {
        try {
          await source.delete();
        } catch (_) {
          // 拷贝成功但源删不掉：不影响缓存可用性，静默即可。
        }
      }
      return target;
    } catch (error) {
      debugPrint('[AylaMediaCache] storeFile 失败（忽略）：$mediaId $error');
      return null;
    }
  }

  /// 原子写入（字节版）：`<target>.tmp` → flush → rename（文档 §6）。
  Future<bool> _atomicWriteBytes(File target, List<int> bytes) {
    return _atomicWrite(target, (File tmp) async {
      final RandomAccessFile handle = await tmp.open(mode: FileMode.writeOnly);
      try {
        await handle.writeFrom(bytes);
        // flush 把内核缓冲刷到设备（Windows 上是 FlushFileBuffers）：
        // 断电也不会留下「名字正确、内容半截」的文件。
        await handle.flush();
      } finally {
        await handle.close();
      }
    });
  }

  /// 原子写入（文件版）：流式拷贝，不整文件读进内存。
  Future<bool> _atomicWriteFile(File target, File source) {
    return _atomicWrite(target, (File tmp) async {
      final RandomAccessFile handle = await tmp.open(mode: FileMode.writeOnly);
      try {
        await for (final List<int> chunk in source.openRead()) {
          await handle.writeFrom(chunk);
        }
        await handle.flush();
      } finally {
        await handle.close();
      }
    });
  }

  /// 写 `.tmp` → rename 的统一实现。
  ///
  /// **失败时清理 `.tmp` 并把错误降级成 false**：正式文件名只会出现在
  /// 「内容已完整写入并 flush 过」的时刻，因此 [lookup] 不可能读到半截文件。
  Future<bool> _atomicWrite(
    File target,
    Future<void> Function(File tmp) writeTmp,
  ) async {
    final File tmp = File('${target.path}.tmp');
    try {
      await target.parent.create(recursive: true);
      if (await tmp.exists()) await tmp.delete();
      await writeTmp(tmp);
      await tmp.rename(target.path);
      return true;
    } catch (error) {
      debugPrint('[AylaMediaCache] 原子写入失败：${target.path} $error');
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {
        // 清不掉 tmp 也无妨：启动扫描会清（cleanupTempFiles）
      }
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // 取（本地优先 + 远程下载 + 静默落盘）
  // ---------------------------------------------------------------------------

  /// 本地优先取文件；未命中则签名 → 下载 → 落盘 → 返回本地 File。
  ///
  /// 行为（文档 §5，2026-10-23 用户改版后）：
  /// - 本地命中**该形态** ⇒ **直接返回，不签名、不下载**；
  /// - 本地未命中 ⇒ 签名（[MediaSigner] 语义：410 时抛 [MediaExpiredError]）；
  /// - **原图已删（阶段 1）** 时签名链会降级成 thumb URL：
  ///   - 要的是 [AylaMediaCacheVariant.thumb] ⇒ **正常按 thumb 落盘**
  ///     （新规则：缩略图本来就该存）；
  ///   - 要的是 [AylaMediaCacheVariant.original] ⇒ **不落盘**，返回 null
  ///     （云端已经没有原图，把缩略图字节命名成原图仍是不诚实的）；
  /// - 下载/落盘失败 ⇒ 只记日志返回 null（调用方可回退到远程 URL）；
  /// - 同一 kind + media_id + variant 并发只跑一次（文档 §7）。
  ///
  /// 返回 null 的两种含义由调用方区分：抛 [MediaExpiredError] = 云端已过期；
  /// 返回 null = 缓存不可用（不是媒体不存在）。
  Future<File?> fetchAndStore({
    required String mediaId,
    required AylaMediaKind kind,
    String? mimeType,
    AylaMediaCacheVariant variant = AylaMediaCacheVariant.original,
  }) {
    if (!_enabled) return Future<File?>.value();
    if (!_isCacheableId(mediaId)) return Future<File?>.value();
    final String key = _key(kind, aylaSafeMediaId(mediaId), variant);

    final Future<File?>? running = _inflight[key];
    if (running != null) return running;

    // late：whenComplete 闭包里要引用 job 自身，用于「只清自己那条 inflight」
    late final Future<File?> job;
    job = _fetchAndStoreOnce(
      mediaId: mediaId,
      kind: kind,
      mimeType: mimeType,
      variant: variant,
    ).whenComplete(() {
      if (identical(_inflight[key], job)) _inflight.remove(key);
    });
    _inflight[key] = job;
    return job;
  }

  Future<File?> _fetchAndStoreOnce({
    required String mediaId,
    required AylaMediaKind kind,
    String? mimeType,
    required AylaMediaCacheVariant variant,
  }) async {
    // ① 命中**该形态**才算命中：要原图时缩略图不算（反之亦然）。
    final File? cached = await lookup(
      mediaId,
      kind: kind,
      mimeType: mimeType,
      variant: variant,
    );
    if (cached != null) return cached;

    final bool wantThumb = variant == AylaMediaCacheVariant.thumb;

    // ② 签名：要缩略图就显式签 thumb；要原图就签 original
    //   （original 收到 410 时 [MediaSigner] 会自动降级成 thumb 并置 originalExpired）。
    final SignedMediaResult signed = wantThumb
        ? await _sign(mediaId, variant: MediaVariant.thumb)
        : await _sign(mediaId);

    // ③ 阶段 1 且要的是原图 ⇒ 云端只有缩略图，**不冒充原图落盘**。
    //    （2026-10-23 用户改版后不再是「一律不缓存」，而是「要什么存什么」。）
    if (signed.originalExpired && !wantThumb) {
      debugPrint('[AylaMediaCache] 原图已过期（只剩缩略图）—— 不按原图落盘：$mediaId');
      return null;
    }

    Uint8List bytes;
    try {
      bytes = await _download(signed.url);
    } catch (error) {
      debugPrint('[AylaMediaCache] 下载失败（不影响显示）：$mediaId $error');
      return null;
    }
    if (bytes.isEmpty) {
      debugPrint('[AylaMediaCache] 下载到 0 字节，跳过缓存：$mediaId');
      return null;
    }
    // ④ 落盘时显式带上形态：即使签名链「降级」了，也不会把字节写进错的那一格。
    return storeBytes(
      mediaId: mediaId,
      kind: kind,
      bytes: bytes,
      mimeType: mimeType,
      variant: variant,
    );
  }

  Future<SignedMediaResult> _sign(String mediaId, {MediaVariant? variant}) {
    final AylaMediaCacheSigner? signer = _signer;
    if (signer != null) return signer(mediaId, variant: variant);
    return MediaSigner.instance.sign(mediaId, variant: variant);
  }

  Future<Uint8List> _download(String url) {
    final AylaMediaCacheDownloader? downloader = _downloader;
    if (downloader != null) return downloader(url);
    return _defaultDownload(url);
  }

  /// 下载用的独立 Dio 实例：**不继承全局拦截器**。
  ///
  /// 全局 `DioClient.dio` 的 auth 拦截器会给每个请求加 `Authorization: Bearer`，
  /// 而 S3 预签名只签了 `host`（`X-Amz-SignedHeaders=host`）——多带任何未签名头
  /// （实测 Authorization / Content-Type 都会）会被 MinIO 判为签名不匹配返回 400。
  /// 预签名 URL 自带票据，本就不需要 Bearer。
  late final Dio _downloadDio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    // 媒体原图可达几十 MB（线上实测 84MB），给足 5 分钟
    receiveTimeout: const Duration(minutes: 5),
  ));

  Future<Uint8List> _defaultDownload(String url) async {
    try {
      final Response<dynamic> response =
          await _downloadDio.get<dynamic>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          validateStatus: (int? status) =>
              status != null && status >= 200 && status < 300,
        ),
      );
      final Object? data = response.data;
      if (data is Uint8List) return data;
      if (data is List<int>) return Uint8List.fromList(data);
      return Uint8List(0);
    } on DioException catch (error) {
      final int status = error.response?.statusCode ?? 0;
      // 410：云端已过期（阶段 2 / 单级媒体）—— 交给调用方显示「已过期」占位
      if (status == 410) throw const MediaExpiredError();
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // 删除 / 统计 / 维护
  // ---------------------------------------------------------------------------

  /// 删除该媒体在**所有 kind** 下的落盘文件（文档 §10 的按条目清理）。
  ///
  /// 返回删除的文件数；失败只记日志（不抛）。
  Future<int> evict(String mediaId) async {
    if (!_isCacheableId(mediaId)) return 0;
    int removed = 0;
    try {
      final AylaMediaCacheLayout layout = await ensureReady();
      final String safe = aylaSafeMediaId(mediaId);
      for (final AylaMediaKind kind in AylaMediaKind.values) {
        // 两种形态一起清（2026-10-23 用户改版后 thumb 也落盘）。
        _forgetPaths(kind, safe);
        final Directory dir = Directory(layout.dirFor(kind, safe));
        if (!await dir.exists()) continue;
        final String prefix = '$safe.';
        await for (final FileSystemEntity entity
            in dir.list(followLinks: false)) {
          if (entity is! File) continue;
          final String name = entity.uri.pathSegments.last;
          if (!name.startsWith(prefix)) continue;
          try {
            await entity.delete();
            removed++;
          } catch (error) {
            debugPrint('[AylaMediaCache] evict 删除失败：${entity.path} $error');
          }
        }
      }
    } catch (error) {
      debugPrint('[AylaMediaCache] evict 失败（忽略）：$mediaId $error');
    }
    return removed;
  }

  /// 占用统计（文档 §10：供后续「清理缓存」功能）。
  ///
  /// 遍历根目录下全部正式文件（跳过 `.tmp`）；失败返回 [AylaMediaCacheStats.empty]
  /// 并留日志（不抛）。
  Future<AylaMediaCacheStats> stats() async {
    try {
      final AylaMediaCacheLayout layout = await ensureReady();
      final Directory root = Directory(layout.root);
      if (!await root.exists()) return AylaMediaCacheStats.empty;

      int totalBytes = 0;
      int fileCount = 0;
      final Map<String, int> bytesByKind = <String, int>{};
      final Map<String, int> countByKind = <String, int>{};

      // 已知 kind 目录名集合（未知目录只计入总量，不伪造 kind 归类）
      final Set<String> knownKinds =
          AylaMediaKind.values.map((AylaMediaKind k) => k.wire).toSet();

      await for (final FileSystemEntity entity
          in root.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final String name = entity.uri.pathSegments.last;
        if (name.endsWith('.tmp')) continue;
        int size = 0;
        try {
          size = await entity.length();
        } catch (_) {
          continue;
        }
        totalBytes += size;
        fileCount += 1;
        final String relative = _relativeOf(layout.root, entity.path);
        final int slash = relative.indexOf('/');
        final String kind = slash < 0 ? '' : relative.substring(0, slash);
        if (knownKinds.contains(kind)) {
          bytesByKind[kind] = (bytesByKind[kind] ?? 0) + size;
          countByKind[kind] = (countByKind[kind] ?? 0) + 1;
        }
      }
      return AylaMediaCacheStats(
        totalBytes: totalBytes,
        fileCount: fileCount,
        bytesByKind: bytesByKind,
        fileCountByKind: countByKind,
      );
    } catch (error) {
      debugPrint('[AylaMediaCache] stats 失败（返回空统计）：$error');
      return AylaMediaCacheStats.empty;
    }
  }

  /// 清理根目录下所有残留 `.tmp`（启动时自动调用一次；也可手动触发）。
  ///
  /// 返回删除个数。文档 §6：崩溃留下的半截文件只在启动时扫除，读路径永远看不到它们。
  Future<int> cleanupTempFiles() async {
    if (_tempsCleaned) return 0;
    _tempsCleaned = true;
    final AylaMediaCacheLayout? layout = _layout;
    if (layout == null) return 0;
    int removed = 0;
    try {
      final Directory root = Directory(layout.root);
      if (!await root.exists()) return 0;
      await for (final FileSystemEntity entity
          in root.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.tmp')) continue;
        try {
          await entity.delete();
          removed++;
        } catch (error) {
          debugPrint('[AylaMediaCache] 清理 .tmp 失败：${entity.path} $error');
        }
      }
      if (removed > 0) {
        debugPrint('[AylaMediaCache] 启动清理残留 .tmp：$removed 个');
      }
    } catch (error) {
      debugPrint('[AylaMediaCache] 清理 .tmp 扫描失败（忽略）：$error');
    }
    return removed;
  }

  /// 重置实例状态（测试隔离用；生产不需要）。
  @visibleForTesting
  Future<void> reset() async {
    _inflight.clear();
    _resolvedPaths.clear();
    _layout = null;
    _layoutFuture = null;
    _tempsCleaned = false;
  }

  // ---------------------------------------------------------------------------

  /// 内存索引键：`<kind>|<id>|<variant>`。
  ///
  /// 2026-10-23 用户改版后 thumb 与 original 可同时存在且**路径不同** ⇒ 索引也
  /// 必须按形态分开，否则「先存了 thumb 再存 original」会让索引指向错的文件。
  static String _key(
    AylaMediaKind kind,
    String safeId, [
    AylaMediaCacheVariant variant = AylaMediaCacheVariant.original,
  ]) =>
      '${kind.wire}|$safeId|${variant.name}';

  /// 空 id / 全非法字符的 id 不缓存（净化后是 `_` 会与其它 id 撞名 ⇒ 宁可少缓存，
  /// 绝不串内容）。
  static bool _isCacheableId(String mediaId) {
    if (mediaId.trim().isEmpty) return false;
    final String safe = aylaSafeMediaId(mediaId);
    return safe != '_' && safe.isNotEmpty;
  }

  static String _relativeOf(String root, String path) {
    final String normalizedRoot = root.replaceAll('\\', '/');
    final String normalizedPath = path.replaceAll('\\', '/');
    if (normalizedPath.startsWith('$normalizedRoot/')) {
      return normalizedPath.substring(normalizedRoot.length + 1);
    }
    return normalizedPath;
  }
}
