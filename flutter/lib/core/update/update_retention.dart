/// **更新暂存回收器**：把 `<数据根>/updates` 的占用钉死在「当前版本 + 最近 1 个」。
///
/// ## 为什么必须存在（2026-11-02 事故根因）
/// `AylaUpdateDownloader` 用**安装包内容 sha256** 当 staging 目录名
/// （`update_downloader.dart` 的 `_safeDirName(download.sha256)`）⇒ 每发一版必然新建一个目录，
/// 跨版本永不重名；而 Windows 覆盖安装必须「脚本等本进程退出后替换文件」，
/// 所以 apply 一启动就 `exit(0)`，Dart 侧再无「安装成功后」的回调可执行。
/// 结果：**每更新一版就永久留下一个 150~320 MB 的目录**（zip + 1.5~2.4 倍的解包体）。
///
/// ⇒ 唯一能覆盖「成功路径必须退出」这个约束的清理位置，就是**下一次启动**。
///
/// ## 保留策略
/// - 保留**最近修改的 [keep] 个** staging 目录（默认 1）；
/// - 保留**当前运行版本**对应的目录（如果它能被识别出来）；
/// - 其余全部 `delete(recursive: true)`。
///
/// ## 失败语义
/// 清理是**增强项**，任何异常只记日志，绝不影响启动（与媒体缓存同一口径）。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../storage/ayla_storage_paths.dart';

/// 默认保留的 staging 目录数（当前版本之外的额外保留数）。
const int kAylaUpdateStagingKeep = 1;

/// 清理结果（供测试与诊断断言）。
@immutable
class AylaUpdateRetentionResult {
  const AylaUpdateRetentionResult({
    required this.kept,
    required this.removed,
    required this.freedBytes,
    this.error,
  });

  /// 保留的目录名（sha256）。
  final List<String> kept;

  /// 已删除的目录名。
  final List<String> removed;

  /// 释放的字节数（尽力统计，失败计 0）。
  final int freedBytes;

  /// 顶层失败原因（null = 正常）。
  final String? error;

  @override
  String toString() =>
      'AylaUpdateRetentionResult(kept=${kept.length}, removed=${removed.length}, '
      'freed=${(freedBytes / (1024 * 1024)).toStringAsFixed(1)}MB, error=$error)';
}

/// 扫描并回收 `<数据根>/updates`，保留最近 [keep] 个 + [currentSha256]（若给出）。
///
/// [root] 仅供测试注入；生产走 [aylaUpdatesDirectory]。
Future<AylaUpdateRetentionResult> aylaPruneUpdateStaging({
  int keep = kAylaUpdateStagingKeep,
  String? currentSha256,
  Directory? root,
}) async {
  final Directory dir;
  try {
    dir = root ?? await aylaUpdatesDirectory();
  } catch (error) {
    return AylaUpdateRetentionResult(
      kept: const <String>[],
      removed: const <String>[],
      freedBytes: 0,
      error: '$error',
    );
  }
  if (!dir.existsSync()) {
    return const AylaUpdateRetentionResult(
      kept: <String>[],
      removed: <String>[],
      freedBytes: 0,
    );
  }

  final List<Directory> candidates = <Directory>[];
  try {
    await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
      if (entity is Directory) candidates.add(entity);
    }
  } catch (error) {
    return AylaUpdateRetentionResult(
      kept: const <String>[],
      removed: const <String>[],
      freedBytes: 0,
      error: '$error',
    );
  }

  // 按修改时间倒序（最新在前）。目录 mtime 在解包/写脚本后会刷新，
  // 因此它近似「这一版最后一次被动过的时间」。
  final List<({Directory dir, DateTime mtime, String name})> entries =
      <({Directory dir, DateTime mtime, String name})>[];
  for (final Directory d in candidates) {
    DateTime mtime;
    try {
      mtime = d.statSync().modified;
    } catch (_) {
      mtime = DateTime.fromMillisecondsSinceEpoch(0);
    }
    entries.add((
      dir: d,
      mtime: mtime,
      name: d.uri.pathSegments.where((String s) => s.isNotEmpty).last,
    ));
  }
  entries.sort(
    ((a, b) => b.mtime.compareTo(a.mtime)),
  );

  final List<String> kept = <String>[];
  final List<String> removed = <String>[];
  int freed = 0;
  final int safeKeep = keep < 0 ? 0 : keep;

  for (int i = 0; i < entries.length; i++) {
    final entry = entries[i];
    final bool isCurrent =
        currentSha256 != null && entry.name == currentSha256;
    if (isCurrent || i < safeKeep) {
      kept.add(entry.name);
      continue;
    }
    try {
      freed += await _sizeOf(entry.dir);
      await entry.dir.delete(recursive: true);
      removed.add(entry.name);
    } catch (error) {
      debugPrint('[AylaUpdate] 回收失败（跳过）：${entry.dir.path} $error');
    }
  }

  if (removed.isNotEmpty) {
    debugPrint(
      '[AylaUpdate] 已回收 ${removed.length} 个更新暂存目录，'
      '释放 ${(freed / (1024 * 1024)).toStringAsFixed(1)} MB（保留 $kept）',
    );
  }
  return AylaUpdateRetentionResult(
    kept: kept,
    removed: removed,
    freedBytes: freed,
  );
}

Future<int> _sizeOf(Directory dir) async {
  int total = 0;
  try {
    await for (final FileSystemEntity entity in dir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) {
        try {
          total += entity.lengthSync();
        } catch (_) {
          // 统计失败不影响删除。
        }
      }
    }
  } catch (_) {
    // 同上。
  }
  return total;
}
