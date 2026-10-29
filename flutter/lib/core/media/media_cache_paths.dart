/// 本地媒体缓存（漫游缓存）的**目录解析与分桶布局**。
///
/// 事实源：`Ayla/docs/architecture/flutter-local-media-cache.md`（2026-10-21 定稿）。
/// 本文件只负责「缓存放在哪、目录怎么分」，不含读写逻辑（见 [AylaMediaCache]）。
///
/// ## 根目录（文档 §3）
///
/// | 平台 | 根 |
/// |---|---|
/// | Windows | `<exe 所在目录>/data/media-cache/` |
/// | Android / iOS（以及桌面 Linux/macOS） | `<getApplicationSupportDirectory()>/media-cache/` |
///
/// **Windows 的 `data/` 是 Flutter 运行时资源目录**（`app.so` / `icudtl.dat` /
/// `flutter_assets/`），因此缓存必须落进 `data/media-cache/` 这个**独立子目录**，
/// 绝不写平级文件。更新脚本用 `robocopy /E`（只覆盖不删除，
/// `lib/core/update/update_applier.dart:271`）⇒ `data/media-cache/` 更新后不会丢。
///
/// **可写性降级（文档 §3.2）**：Windows 装到 `Program Files` 等受保护目录时，
/// 普通用户对 exe 同级目录没有写权限 ⇒ 试写探测失败后回退
/// `<ApplicationSupport>/media-cache/`，并通过 `debugPrint` 留日志。
///
/// ## 分桶布局（文档 §4）
///
/// ```
/// media-cache/
/// └── <kind>/                    image | voice | video | file | emoji
///     └── <media_id 前 2 位>/     00 .. ff（256 桶）
///         ├── <media_id>.<ext>        原图/原音频/原视频/原文件（original）
///         └── <media_id>.thumb.<ext>  缩略图派生（thumb，见下）
/// ```
///
/// 例：
/// ```
/// media-cache/image/5d/5db02e1571464f91bce21bdda1245125.jpg        ← 原图
/// media-cache/image/5d/5db02e1571464f91bce21bdda1245125.thumb.jpg  ← 缩略图
/// ```
///
/// 理由：
/// - 按 `kind` 分第一层 ⇒ 后续「只清视频」这类按类型清理/统计可直接做；
/// - 按 `media_id` 前 2 位分第二层 ⇒ media_id 是 uuid4 hex，前 2 位均匀分布，
///   天然 256 桶，单目录文件数远小于 256，避开目录遍历退化与资源管理器卡顿；
/// - 文件名就是 media_id（幂等、可反查），扩展名由 `mime_type` 推导，缺失时 `.bin`。
///
/// ### thumb 与 original 共存（2026-10-23 用户改版）
///
/// **旧规则（2026-10-21 D1）**：只缓存 original，不缓存 thumb ⇒ thumb 与 original
/// 共用 `<media_id>.<ext>` 一个路径，靠「thumb 不落盘」避免撞车。
///
/// **新规则（2026-10-23 用户改版）**：图片「看见先存缩略图、点开大图才用原图取代
/// 缩略图」⇒ 两者必须**同时存在且互不覆盖**。用**文件名后缀**区分（而不是子目录）：
/// - 两种形态落在**同一个分桶目录**里 ⇒ [AylaMediaCache] 的「扫分桶找命中」逻辑
///   只需按前缀 + 形态过滤，两种形态并存时**不会互相挡住**；
/// - 后缀 `.thumb` 在扩展名**之前**（`<id>.thumb.jpg`）⇒ 扩展名仍在末尾，
///   按扩展名判断「能不能直接 Image.file / 播放」的逻辑不受影响；
/// - **老版本兼容**：老版本只有 `<media_id>.<ext>`（无 `.thumb` 段）⇒ 新代码按
///   original 命中，无需迁移；只有 thumb 的新数据也不会被误认成 original
///   （[aylaIsThumbCacheFileName]）。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/media_kind.dart';

/// 缓存目录名（`data/` 下的独立子目录，见库文档）。
const String kMediaCacheDirName = 'media-cache';

/// Windows 下 exe 同级的资源目录名。
const String kMediaCacheWindowsDataDirName = 'data';

/// 缩略图文件名里插入的段（`<media_id>.thumb.<ext>`）。
///
/// 放**扩展名之前**：扩展名仍在末尾 ⇒ 任何按扩展名判断「能否 Image.file / 播放」
/// 的逻辑不受影响；同时与 original 的 `<media_id>.<ext>` **永不撞名**。
const String kMediaCacheThumbInfix = '.thumb';

/// 判断某个缓存文件名是不是**缩略图**形态（`<media_id>.thumb.<ext>`）。
///
/// 供「扫分桶找命中」区分两种形态；老版本的 `<media_id>.<ext>` 恒返回 false
/// （= original），因此**无需迁移**。
bool aylaIsThumbCacheFileName(String fileName) =>
    fileName.contains('$kMediaCacheThumbInfix.') &&
    !fileName.endsWith('$kMediaCacheThumbInfix.tmp');

/// 缓存根来源（诊断/日志用）。
enum AylaMediaCacheRootSource {
  /// Windows：`<exe 目录>/data/media-cache`（首选）。
  executableData,

  /// `getApplicationSupportDirectory()/media-cache`（Windows 降级 / 移动端兜底）。
  applicationSupport,

  /// Android：`<外部存储>/Android/data/<包名>/files/media-cache`
  /// （用户拍板 2026-10-29「手机端保存在经典的 Android/data」）。
  ///
  /// 为什么不用 `getExternalStorageDirectory()` 直接拼：该 API 返回
  /// `/storage/emulated/0/Android/data/<pkg>/files`，但部分 ROM 会返回
  /// 应用专属的其它挂载点；我们只**校验路径形态**（含 `/Android/data/`），
  /// 形态不符或不可写即降级到 [applicationSupport]，绝不猜路径。
  androidExternalData,
}

/// 平台能力抽象 —— **测试注入点**。
///
/// 生产实现见 [AylaIoMediaCachePlatform]；单测用假实现同时覆盖
/// 「Windows 分支 / 移动端分支 / 不可写降级」三条路径（无需真实 ACL 技巧）。
abstract interface class AylaMediaCachePlatform {
  /// 目标平台（决定根目录策略）。
  TargetPlatform get targetPlatform;

  /// 当前可执行文件绝对路径（`Platform.resolvedExecutable`）。
  String get executablePath;

  /// 应用支持目录（`getApplicationSupportDirectory()`）。
  Future<Directory> applicationSupportDirectory();

  /// Android 外部存储上的应用专属目录（`getExternalStorageDirectory()`）。
  ///
  /// 仅 Android 有值；其它平台返回 null（调用方据此走各自分支）。
  Future<Directory?> externalStorageDirectory();
}

/// 生产实现：直连 `dart:io` 与 `path_provider`。
class AylaIoMediaCachePlatform implements AylaMediaCachePlatform {
  const AylaIoMediaCachePlatform();

  @override
  TargetPlatform get targetPlatform => defaultTargetPlatform;

  @override
  String get executablePath => Platform.resolvedExecutable;

  @override
  Future<Directory> applicationSupportDirectory() =>
      getApplicationSupportDirectory();

  @override
  Future<Directory?> externalStorageDirectory() async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      return await getExternalStorageDirectory();
    } catch (error) {
      debugPrint('[AylaMediaCache] getExternalStorageDirectory 失败：$error');
      return null;
    }
  }
}

/// 解析后的缓存布局。
@immutable
class AylaMediaCacheLayout {
  const AylaMediaCacheLayout({
    required this.root,
    required this.source,
    required this.degraded,
  });

  /// 缓存根目录（绝对路径，`/` 分隔）。
  final String root;

  /// 根目录来源。
  final AylaMediaCacheRootSource source;

  /// 是否因不可写而降级（Windows 装到受保护目录时 true）。
  final bool degraded;

  /// `media-cache/<kind>/<shard>`（不含扩展名的目录）。
  String dirFor(AylaMediaKind kind, String mediaId) {
    final String safe = aylaSafeMediaId(mediaId);
    return '$root/${kind.wire}/${aylaMediaShardOf(safe)}';
  }

  /// 完整落盘路径：`media-cache/<kind>/<shard>/<media_id>[.thumb].<ext>`。
  ///
  /// [extension] 传 `.jpg` 或 `jpg` 均可；null 时按 [mimeType] 推导，再不行 `.bin`。
  ///
  /// [isThumb] 为 true 时在文件名里插入 `.thumb` 段（见库文档「thumb 与 original
  /// 共存」）—— 两种形态因此**永远不撞路径**，可以同时存在。
  String pathFor(
    AylaMediaKind kind,
    String mediaId, {
    String? mimeType,
    String? extension,
    bool isThumb = false,
  }) {
    final String safe = aylaSafeMediaId(mediaId);
    // 扩展名优先级：显式 extension > mimeType 推导 > **按 kind 的默认扩展名**。
    // 最后一档很关键：调用方（如 AylaResourceImage 只有 URL 没有 mime）拿不到
    // mimeType 时若落到 `.bin`，后续按扩展名打开/缩略判断会全部退化。
    final String ext = aylaMediaExtension(
      extension ??
          aylaMediaExtensionForMimeOrKind(mimeType, kind),
    );
    final String middle = isThumb ? kMediaCacheThumbInfix : '';
    return '${dirFor(kind, safe)}/$safe$middle$ext';
  }

  @override
  String toString() =>
      'AylaMediaCacheLayout(root=$root, source=${source.name}, degraded=$degraded)';
}

/// 解析缓存根并做可写性探测（文档 §3.2）。
///
/// 失败不抛：极端的「支持目录也不可写」情况下仍返回布局对象，由写入调用方
/// 按「写失败只记日志」的语义处理（缓存是增强项，不能让媒体链路崩）。
Future<AylaMediaCacheLayout> aylaResolveMediaCacheLayout({
  AylaMediaCachePlatform platform = const AylaIoMediaCachePlatform(),
}) async {
  if (platform.targetPlatform == TargetPlatform.windows) {
    final String exeDir = _parentDirOf(platform.executablePath);
    final String primary =
        '$exeDir/$kMediaCacheWindowsDataDirName/$kMediaCacheDirName';
    if (await aylaProbeDirectoryWritable(Directory(primary))) {
      return AylaMediaCacheLayout(
        root: primary,
        source: AylaMediaCacheRootSource.executableData,
        degraded: false,
      );
    }
    debugPrint(
      '[AylaMediaCache] exe 同级 data/ 不可写（${Directory(primary).path}）'
      '—— 可能安装在 Program Files 等受保护目录，降级到应用支持目录',
    );
    final Directory support = await platform.applicationSupportDirectory();
    final String fallbackRoot = _join(support.path, kMediaCacheDirName);
    await _ensureDirectoryQuietly(fallbackRoot);
    return AylaMediaCacheLayout(
      root: fallbackRoot,
      source: AylaMediaCacheRootSource.applicationSupport,
      degraded: true,
    );
  }
  // Android：优先外部存储的 `Android/data/<包名>/files/media-cache`
  // （用户拍板 2026-10-29「手机端保存在经典的 Android/data」）。
  //
  // 校验三件事，任一不满足即降级到应用支持目录（绝不猜路径）：
  //   1. 平台给了外部目录（部分 ROM / 已卸载的 SD 卡返回 null）；
  //   2. 路径形态确实是 `/Android/data/`（防止厂商 ROM 把应用专属目录
  //      映射到别处，此时"Android/data"对用户毫无意义）；
  //   3. 目录可写（外部存储可能被拔出、只读挂载或配额耗尽）。
  if (platform.targetPlatform == TargetPlatform.android) {
    final Directory? external = await platform.externalStorageDirectory();
    if (external != null) {
      final String normalized = external.path.replaceAll('\\', '/');
      if (normalized.contains('/Android/data/')) {
        final String primary = _join(normalized, kMediaCacheDirName);
        if (await aylaProbeDirectoryWritable(Directory(primary))) {
          return AylaMediaCacheLayout(
            root: primary,
            source: AylaMediaCacheRootSource.androidExternalData,
            degraded: false,
          );
        }
        debugPrint(
          '[AylaMediaCache] Android 外部存储不可写（$primary）——降级到应用支持目录',
        );
      } else {
        debugPrint(
          '[AylaMediaCache] 外部目录形态不是 /Android/data/（$normalized）'
          '——降级到应用支持目录',
        );
      }
    }
    final Directory support = await platform.applicationSupportDirectory();
    final String fallbackRoot = _join(support.path, kMediaCacheDirName);
    await _ensureDirectoryQuietly(fallbackRoot);
    return AylaMediaCacheLayout(
      root: fallbackRoot,
      source: AylaMediaCacheRootSource.applicationSupport,
      degraded: true,
    );
  }

  // iOS（以及桌面 Linux/macOS）：应用私有目录，无需探测写权限
  //（仍要建目录：首次使用时目录可能尚不存在，create 幂等且失败由写入链记日志）。
  final Directory support = await platform.applicationSupportDirectory();
  final String root = _join(support.path, kMediaCacheDirName);
  await _ensureDirectoryQuietly(root);
  return AylaMediaCacheLayout(
    root: root,
    source: AylaMediaCacheRootSource.applicationSupport,
    degraded: false,
  );
}

/// 建目录但不抛（缓存是增强项：建不出来也让调用方拿到布局对象，逐次写入时记日志）。
Future<void> _ensureDirectoryQuietly(String path) async {
  try {
    await Directory(path).create(recursive: true);
  } catch (error) {
    debugPrint('[AylaMediaCache] 建缓存目录失败（稍后写入会逐次重试）：$path $error');
  }
}

/// 可写性探测：建目录 → 试写临时文件 → 删除。
///
/// 只探测**缓存子目录**（不是 `data/` 本身）：`data/` 里放的是运行时资源，
/// 这里绝不写任何东西进它（除非 `data/media-cache` 尚不存在，此时 create 只会
/// 新建我们自己的子目录）。
Future<bool> aylaProbeDirectoryWritable(Directory dir) async {
  try {
    await dir.create(recursive: true);
    final File probe = File(
      '${dir.path}/.write-probe-${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await probe.writeAsBytes(const <int>[0], flush: true);
    await probe.delete();
    return true;
  } catch (error) {
    debugPrint('[AylaMediaCache] 目录不可写探测失败：${dir.path}（$error）');
    return false;
  }
}

/// media_id 净化：只保留 `[a-z0-9]`（小写），去掉路径分隔符与 `..`，
/// 防路径穿越、保证文件名合法（media_id 实际是 uuid4 hex，净化是防御性动作）。
///
/// 全部被过滤空时返回 `_`（确定性的哨兵，不伪造媒体身份、不返回空串让调用方
/// 拼出 `<shard>/.jpg` 这类越界路径）。
String aylaSafeMediaId(String mediaId) {
  final String cleaned =
      mediaId.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (cleaned.isEmpty) return '_';
  return cleaned;
}

/// 分桶目录名：media_id 前 2 位（不足 2 位用自身）。
String aylaMediaShardOf(String safeMediaId) {
  if (safeMediaId.length <= 2) return safeMediaId;
  return safeMediaId.substring(0, 2);
}

/// mime → 扩展名（含 `.`）。未知一律 `.bin`（不猜、不伪造类型）。
String aylaMediaExtensionForMime(String? mimeType) {
  final String mime = (mimeType ?? '').trim().toLowerCase();
  // 去掉 `; charset=...` 之类参数（web 侧同样的主类型口径）
  final int semi = mime.indexOf(';');
  final String main = semi < 0 ? mime : mime.substring(0, semi).trim();
  return aylaMediaExtensionMap[main] ?? '.bin';
}

/// 扩展名推导（带 kind 兜底）：mime 已知按 mime，未知按 kind 给默认扩展名。
///
/// 为什么需要 kind 兜底：部分调用点（如 `AylaResourceImage`）只有 URL、
/// 没有 descriptor 的 mime_type；若一律退回 `.bin`，后续按扩展名判断/打开会退化。
/// 兜底只影响文件名，不影响内容字节，也不改变「按 media_id 反查」的幂等性。
String aylaMediaExtensionForMimeOrKind(
  String? mimeType,
  AylaMediaKind kind,
) {
  final String byMime = aylaMediaExtensionForMime(mimeType);
  if (byMime != '.bin') return byMime;
  if ((mimeType ?? '').trim().isNotEmpty) return byMime; // 有 mime 但未收录：尊重 .bin
  return switch (kind) {
    AylaMediaKind.image => '.jpg',
    AylaMediaKind.emoji => '.png',
    AylaMediaKind.voice => '.webm',
    AylaMediaKind.video => '.mp4',
    AylaMediaKind.file => '.bin',
  };
}

/// 主类型 → 扩展名映射表（文档 §4：扩展名从 mime_type 推导，缺失时 `.bin`）。
const Map<String, String> aylaMediaExtensionMap = <String, String>{
  'image/jpeg': '.jpg',
  'image/jpg': '.jpg',
  'image/png': '.png',
  'image/gif': '.gif',
  'image/webp': '.webp',
  'image/bmp': '.bmp',
  'image/svg+xml': '.svg',
  'video/mp4': '.mp4',
  'video/webm': '.webm',
  'video/quicktime': '.mov',
  'audio/mpeg': '.mp3',
  'audio/mp4': '.m4a',
  'audio/ogg': '.ogg',
  'audio/webm': '.webm',
  'audio/x-wav': '.wav',
  'audio/wav': '.wav',
  'application/pdf': '.pdf',
  'application/zip': '.zip',
  'text/plain': '.txt',
};

/// 归一扩展名：`jpg` → `.jpg`；空 → `.bin`；带非法字符 → `.bin`。
String aylaMediaExtension(String? raw) {
  final String ext = (raw ?? '').trim().toLowerCase();
  if (ext.isEmpty) return '.bin';
  final String withDot = ext.startsWith('.') ? ext : '.$ext';
  if (!RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(withDot)) return '.bin';
  return withDot;
}

String _parentDirOf(String filePath) {
  final String normalized = filePath.replaceAll('\\', '/');
  final int index = normalized.lastIndexOf('/');
  final String parent = index <= 0 ? normalized : normalized.substring(0, index);
  return _stripTrailingSlash(parent);
}

String _join(String a, String b) => '${_stripTrailingSlash(a.replaceAll('\\', '/'))}/$b';

String _stripTrailingSlash(String path) {
  if (path.length > 1 && path.endsWith('/')) {
    return path.substring(0, path.length - 1);
  }
  return path;
}
