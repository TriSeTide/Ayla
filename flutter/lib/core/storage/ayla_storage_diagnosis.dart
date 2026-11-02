/// **安装位置诊断**：把「数据根不可写」从一个静默故障变成可操作的前置检查。
///
/// ## 为什么需要（2026-11-02 用户提出）
/// 用户要求「全部改到 `<exe目录>\data\`，不允许任何 C 盘降级回退」。
/// 这条约束有一个必然副作用：**装到 `Program Files` 等受保护目录时，程序目录不可写**。
/// 旧实现会静默降级到 `%APPDATA%`（C 盘，用户已明令禁止），
/// 所以现在必须**在写任何东西之前**就判断出来，并给出可操作的出路，
/// 而不是让用户在启动后才遇到「缓存不生效 / 设置存不下 / 更新装不上」的散装故障。
///
/// ## 现行策略（用户 2026-11-02 第二轮裁决）
/// 「如果真有，就让他装在那里**正常用**，这种情况**允许写 C 盘**，装 C 盘就允许写 C 盘，
/// 但是 **data 还是全部写在 exe 同级**。」
///
/// ⇒ 本诊断**不再阻断启动**，只做两件事：
/// 1. 判断 exe 同级 `data/` 是否可写（能写就是最优，一切照常）；
/// 2. 不能写时（典型：装进 `Program Files` 受 UAC 保护）报告**实际会落到哪**
///    （`%LOCALAPPDATA%\Ayla\data`），让用户/支持者一眼看到数据在哪，
///    并可选提供「搬到用户可写位置」的入口（[aylaRelocateInstallation]）。
///
/// 关键：**无论哪种情况，数据都在一个显式的 `data` 目录里**，绝不散到
/// `%APPDATA%\Roaming\<Company>\<Product>` 那种用户看不见的隐式目录。
///
/// ## 判定口径
/// 只认**可写性探测**（建目录 + 试写 1 字节 + 删除），不猜路径：
/// 用户完全可以把 Ayla 放在 `C:\Program Files\...` 之外的任何地方，
/// 也可能把 `D:\Program Files` 的 ACL 放开 —— 猜目录名会误伤。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'ayla_storage_paths.dart';

// re-export：回落根与测试注入点的公开入口（实现只有一份，在 storage_paths）。
export 'ayla_storage_paths.dart'
    show aylaFallbackDataRoot, aylaFallbackDataRootForTest;

/// 诊断结果。
@immutable
class AylaStorageDiagnosis {
  const AylaStorageDiagnosis({
    required this.ok,
    required this.dataRoot,
    this.reason,
    this.suggestion,
    this.relocateTarget,
  });

  /// 数据根可用（可直接启动）。
  final bool ok;

  /// 期望的数据根（`<exe目录>/data`）。
  final String dataRoot;

  /// 不可用原因（可直接展示）。
  final String? reason;

  /// 建议动作（可直接展示）。
  final String? suggestion;

  /// 推荐的新安装位置（null = 无法给出建议，例如非 Windows）。
  final String? relocateTarget;

  @override
  String toString() => ok
      ? 'AylaStorageDiagnosis(ok, root=$dataRoot)'
      : 'AylaStorageDiagnosis(fail, root=$dataRoot, reason=$reason)';
}

/// Windows 上推荐的「一键搬迁」目标：`%LOCALAPPDATA%\Programs\Ayla`。
///
/// 选它的理由：这是 Windows 对「按用户安装」的标准位置（VS Code、Chrome 都用），
/// 普通用户可写、无需提权、卸载时整目录可删；且它是 `%LOCALAPPDATA%`，
/// 与本次整改要消灭的 `%APPDATA%\Roaming` 隐式缓存**不是同一个地方**。
String? aylaRecommendedInstallDirectory() {
  if (!Platform.isWindows) return null;
  final String? localAppData = Platform.environment['LOCALAPPDATA'];
  if (localAppData == null || localAppData.isEmpty) return null;
  return '$localAppData${Platform.pathSeparator}Programs'
      '${Platform.pathSeparator}Ayla';
}

/// 判断当前安装位置能否落盘，并给出实际会用的数据目录。
///
/// **只读**：探测会在目标 data 目录下建一个临时探针文件再删掉，不写业务数据。
///
/// **不阻断启动**（用户 2026-11-02 裁决）：装进 `Program Files` 时
/// `ok = false` 但应用照常启动，数据落到 `%LOCALAPPDATA%\Ayla\data`；
/// 本函数只负责把「实际落哪」报告出来（启动日志 + 设置页可见）。
Future<AylaStorageDiagnosis> aylaDiagnoseInstallLocation() async {
  final String exe = Platform.resolvedExecutable;
  final int cut = exe.lastIndexOf(Platform.pathSeparator);
  final String exeDir = cut <= 0 ? exe : exe.substring(0, cut);
  final String dataRoot = '$exeDir${Platform.pathSeparator}data';

  if (!Platform.isWindows) {
    // 移动端恒为应用私有沙盒，不存在这个诊断。
    return AylaStorageDiagnosis(ok: true, dataRoot: dataRoot);
  }

  // exe 同级可写 ⇒ 最优路径，什么都不用提示。
  if (await _probe(dataRoot)) {
    return AylaStorageDiagnosis(ok: true, dataRoot: dataRoot);
  }

  // 不可写（典型：Program Files）⇒ 报告真实落点，但**仍然正常启动**。
  final String fallback = aylaFallbackDataRoot();
  final bool fallbackOk = await _probe(fallback);
  return AylaStorageDiagnosis(
    ok: false,
    dataRoot: dataRoot,
    reason: fallbackOk
        ? '程序目录（${_programFilesLike(exeDir) ? 'Program Files 等受保护目录' : '当前目录'}）'
            '不可写，数据将改存到用户数据区。'
        : '程序目录与用户数据区都不可写。',
    suggestion: fallbackOk
        ? '应用可正常使用，数据在：$fallback。'
            '若希望数据跟安装目录走，可把整个文件夹移到可写位置（如 D:\\Ayla），'
            '或点「搬迁」复制一份过去。'
        : '请检查磁盘权限或剩余空间。',
    relocateTarget: aylaRecommendedInstallDirectory(),
  );
}

/// 判定目录是否可写（建目录 + 试写 1 字节 + 删除）。
Future<bool> _probe(String path) async {
  try {
    final Directory dir = Directory(path);
    await dir.create(recursive: true);
    final File probe = File(
      '$path${Platform.pathSeparator}.write-probe-'
      '${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await probe.writeAsBytes(const <int>[0], flush: true);
    await probe.delete();
    return true;
  } catch (error) {
    debugPrint('[AylaStorage] 目录不可写探测失败：$path（${_shortError(error)}）');
    return false;
  }
}

// 回落根的唯一实现在 `ayla_storage_paths.dart`（含测试注入点
// `aylaFallbackDataRootForTest`）；本文件已在顶部 import 它，直接复用，避免口径漂移。

bool _programFilesLike(String dir) {
  final String low = dir.toLowerCase().replaceAll('\\', '/');
  return low.contains('/program files');
}

/// 把整个安装目录复制到 [target]，成功返回新 exe 的绝对路径。
///
/// ## 行为
/// - 递归复制（含 `data/`，因此媒体缓存与账号数据一并带走）；
/// - **不删除原目录**（用户确认新版本能跑之后再自己删，避免半途失败丢安装）；
/// - 目标已存在则先清空（幂等：重复点「搬迁」得到同样结果）；
/// - 复制完成**不自动启动**：由调用方决定（本函数只管文件）。
///
/// ## 失败语义
/// 抛 [AylaStorageException]，消息可直接展示。
Future<String> aylaRelocateInstallation(String target) async {
  final String exe = Platform.resolvedExecutable;
  final int cut = exe.lastIndexOf(Platform.pathSeparator);
  final String exeDir = cut <= 0 ? exe : exe.substring(0, cut);
  final String exeName = cut <= 0 ? exe : exe.substring(cut + 1);

  if (target.trim().isEmpty) {
    throw const AylaStorageException('搬迁目标为空');
  }
  final String normalizedTarget = target.replaceAll('/', Platform.pathSeparator);
  if (normalizedTarget.toLowerCase() == exeDir.toLowerCase()) {
    throw const AylaStorageException('搬迁目标与当前目录相同');
  }

  final Directory dest = Directory(normalizedTarget);
  try {
    if (await dest.exists()) {
      await dest.delete(recursive: true);
    }
    await dest.create(recursive: true);
  } catch (error) {
    throw AylaStorageException('无法创建目标目录', path: '$normalizedTarget（$error）');
  }

  try {
    await _copyTree(Directory(exeDir), dest);
  } catch (error) {
    throw AylaStorageException('复制安装目录失败', path: '$exeDir → $normalizedTarget（$error）');
  }

  final String newExe = '${dest.path}${Platform.pathSeparator}$exeName';
  if (!File(newExe).existsSync()) {
    throw AylaStorageException('复制完成但找不到可执行文件', path: newExe);
  }
  debugPrint('[AylaStorage] 安装目录已复制到 $normalizedTarget');
  return newExe;
}

/// 递归复制目录树（跳过目标自身，避免无限递归）。
Future<void> _copyTree(Directory source, Directory dest) async {
  final String srcPath = source.path.toLowerCase();
  final String dstPath = dest.path.toLowerCase();
  await for (final FileSystemEntity entity
      in source.list(recursive: true, followLinks: false)) {
    final String rel = entity.path
        .substring(source.path.length)
        .replaceFirst(RegExp(r'^[\\/]'), '');
    final String targetPath = '${dest.path}${Platform.pathSeparator}$rel';
    // 目标在源里面时跳过（否则边复制边遍历）
    if (targetPath.toLowerCase().startsWith(srcPath) &&
        targetPath.toLowerCase() != dstPath) {
      continue;
    }
    if (entity is Directory) {
      await Directory(targetPath).create(recursive: true);
    } else if (entity is File) {
      await Directory(File(targetPath).parent.path).create(recursive: true);
      await entity.copy(targetPath);
    }
  }
}

String _shortError(Object error) {
  final String text = error.toString();
  return text.length > 160 ? '${text.substring(0, 160)}…' : text;
}
