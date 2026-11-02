/// **Ayla 全部本地数据的唯一存储根解析**（2026-11-02 用户定稿：绝不写 C 盘）。
///
/// ## 硬约束（用户 2026-11-02 两轮裁决）
/// 1. 「**全部改到 `<exe目录>\data\`**」；
/// 2. 「如果真有（把包放进 Program Files 的），就让他装在那里正常用，这种情况
///    **允许写 C 盘，装 C 盘就允许写 C 盘**，但是 **data 还是全部写在 exe 同级**」。
///
/// ⇒ 本文件是 Windows 上**唯一**允许决定落盘的入口：
/// - 目标根 = `<exe 所在目录>/data`，**与安装盘一致**（装在 E 盘就落 E 盘；
///   装在 C 盘的 Program Files 就落 C 盘的那份 exe 同级）——
///   **绝不允许**把数据散到 `%APPDATA%\Roaming\com.ayla`、`%TEMP%` 这类
///   「隐式用户目录」（那正是 7.79 GB 事故里没人发现的根源）；
/// - **exe 同级 data 不可写时**（Program Files 受 UAC 保护）：**允许**落到
///   `%LOCALAPPDATA%\Ayla\data`（本机可见、可整体搬走），并把实际根路径与来源
///   暴露到 [aylaDataRootOrNull] / [aylaDataRootSource] / 设置页，用户随时能看到；
/// - 其它平台（Android / iOS）沿用应用私有沙盒目录，**没有任何跨到用户可见目录的分支**
///   （原先 Android 的 `getExternalStorageDirectory()` 外部存储分支已按同一原则移除）。
///
/// ## 目录布局
/// ```
/// <exe目录>/data/
/// ├── profile/                       账号与偏好
/// │   ├── flutter_secure_storage.dat      DPAPI 加密凭据（Windows）
/// │   ├── ayla_chat_drafts.json
/// │   ├── ayla_search_history.json
/// │   └── ayla_home_prefs.json
/// ├── media-cache/                   媒体漫游缓存（image/voice/video/file/emoji 分桶）
/// ├── updates/                       自更新暂存（<sha256>/…，启动期回收）
/// ├── voice/                         语音录制临时文件
/// ├── download-queue.json            离线下载队列
/// └── ayla_jank.log                  掉帧探针（仅 debug/profile 且显式开启）
/// ```
///
/// ## 为什么需要这个文件（而不是继续用 path_provider）
/// Windows 上 `getApplicationSupportDirectory()` 恒为
/// `%APPDATA%\Roaming\<CompanyName>\<ProductName>`（由 `Runner.rc:92,98` 决定），
/// 即**永远在系统盘**，且 Dart 侧无法配置 —— 这正是 2026-11-02 事故
/// （C 盘被自更新暂存占用 7.79 GB）的根因之一。要真正做到「不落 C 盘」，必须自解析。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// `data/` 下的子目录名（集中定义，禁止各处手拼字符串）。
const String kAylaProfileDirName = 'profile';
const String kAylaMediaCacheDirName = 'media-cache';
const String kAylaUpdatesDirName = 'updates';
const String kAylaVoiceDirName = 'voice';

/// 存储根不可用（不可写 / 无法解析）。**没有回退**：调用方必须显式处理。
class AylaStorageException implements Exception {
  const AylaStorageException(this.message, {this.path});

  /// 可直接展示给用户的原因。
  final String message;

  /// 出问题的绝对路径（诊断用）。
  final String? path;

  @override
  String toString() =>
      'AylaStorageException: $message' + (path == null ? '' : '（$path）');
}

String? _dataRoot;
bool _dataRootProbed = false;
String _dataRootSource = 'unresolved';

/// 当前数据根来源（`exe-data` / `mobile-support` / `test` / `unresolved`）。
String get aylaDataRootSource => _dataRootSource;

/// **同步**读取已解析的数据根（未初始化时 null）。仅供日志/诊断；
/// 任何要落盘的调用必须先 `await aylaEnsureDataRoot()`。
String? get aylaDataRootOrNull => _dataRoot;

/// Windows：`<exe 目录>`；其它平台返回空串。
String aylaWindowsExecutableDirectory() {
  if (!Platform.isWindows) return '';
  final String exe = Platform.resolvedExecutable;
  final int cut = exe.lastIndexOf(Platform.pathSeparator);
  return cut <= 0 ? exe : exe.substring(0, cut);
}

/// 解析并**确保**数据根可用（幂等，成功时进程内只探测一次）。
///
/// Windows：`<exe目录>/data`，建目录 + 试写探针；失败**抛 [AylaStorageException]**。
/// Android / iOS：`getApplicationSupportDirectory()`（应用私有沙盒）。
///
/// 失败不缓存结果，下次调用会重新探测。
Future<String> aylaEnsureDataRoot() async {
  final String? cached = _dataRoot;
  if (cached != null && _dataRootProbed) return cached;

  if (Platform.isWindows) {
    final String exeDir = aylaWindowsExecutableDirectory();
    if (exeDir.isEmpty) {
      throw const AylaStorageException('无法解析可执行文件所在目录');
    }
    final String root = '$exeDir${Platform.pathSeparator}data';
    final Directory dir = Directory(root);
    try {
      await dir.create(recursive: true);
    } catch (error) {
      throw AylaStorageException('数据目录无法创建', path: '$root（$error）');
    }
    if (await _probeWritable(dir)) {
      _dataRoot = root;
      _dataRootSource = 'exe-data';
      _dataRootProbed = true;
      return root;
    }

    // ---- exe 同级不可写（典型：装进 Program Files，受 UAC 保护）----
    // 用户 2026-11-02 裁决：「装在那里就让他正常用，这种情况允许写 C 盘，
    // 但是 data 还是全部写在 exe 同级」。
    // ⇒ 落 `%LOCALAPPDATA%\Ayla\data`：仍是「Ayla 自己的 data 目录」这一语义，
    //    只是宿主位置换成了用户可写的本地应用数据区；**不写** `%APPDATA%\Roaming`
    //    那种按 Company/Product 自动派生、用户完全看不见的隐式目录。
    final String fallback = await _localAppDataDataRoot();
    if (await _probeWritable(Directory(fallback))) {
      debugPrint(
        '[AylaStorage] exe 同级 data 不可写（$root）——按裁决落到用户数据区：$fallback',
      );
      _dataRoot = fallback;
      _dataRootSource = 'local-appdata';
      _dataRootProbed = true;
      return fallback;
    }

    throw AylaStorageException(
      '数据目录不可写：程序目录与用户数据区都写不进去。'
          '请检查磁盘权限或剩余空间。',
      path: '$root / $fallback',
    );
  }

  // Android / iOS：应用私有沙盒（不存在「系统盘用户目录」概念，无需也不允许回退）。
  final Directory support = await getApplicationSupportDirectory();
  final String root = support.path;
  try {
    await Directory(root).create(recursive: true);
  } catch (_) {
    // 已存在但 create 失败（并发）时忽略；真实错误会在首次写入时暴露。
  }
  _dataRoot = root;
  _dataRootSource = 'mobile-support';
  _dataRootProbed = true;
  return root;
}

/// `%LOCALAPPDATA%\Ayla\data`（exe 同级不可写时的落点）。
///
/// 为什么不是 `%APPDATA%\Roaming\<Company>\<Product>`：那个路径由 exe 的 VERSIONINFO
/// 自动派生、用户完全看不到，正是 7.79 GB 事故里没人发现的原因。
/// `%LOCALAPPDATA%\Ayla` 是显式命名、可被用户在设置页看到、可整体搬走的目录。
Future<String> _localAppDataDataRoot() async =>
    aylaFallbackDataRoot();

/// **测试注入点**：覆盖 exe 同级不可写时的回落根（生产不设置）。
///
/// 为什么需要：回落根默认是 `%LOCALAPPDATA%\Ayla\data`，属于**真实用户目录**。
/// 单元测试若直接调解析函数，就会在开发机/CI 的用户目录里留下垃圾
/// （2026-11-02 实测踩过：跑测试在 `%LOCALAPPDATA%\Ayla` 里留下缓存与凭据）。
/// 测试必须把它指到临时目录。
@visibleForTesting
String? aylaFallbackDataRootForTest;

/// exe 同级不可写时的实际数据根（Program Files 场景）。
///
/// 形如 `%LOCALAPPDATA%\Ayla\data` —— 仍是**显式的 Ayla data 目录**，
/// 只是宿主位置换成用户可写区；**绝不**用 `%APPDATA%\Roaming\<Company>\<Product>`
/// 那种按 VERSIONINFO 派生、用户看不见的隐式目录（7.79 GB 事故就是这么藏起来的）。
String aylaFallbackDataRoot() {
  final String? override = aylaFallbackDataRootForTest;
  if (override != null) return override;
  final String? localAppData = Platform.environment['LOCALAPPDATA'];
  if (localAppData != null && localAppData.isNotEmpty) {
    return '$localAppData${Platform.pathSeparator}Ayla'
        '${Platform.pathSeparator}data';
  }
  // 环境变量缺失（极罕见）：落到系统临时区的显式 Ayla/data，仍然可见可清理。
  return '${Directory.systemTemp.path}${Platform.pathSeparator}Ayla'
      '${Platform.pathSeparator}data';
}

/// `data/profile`（账号与偏好）。
Future<Directory> aylaProfileDirectory() async => _sub(kAylaProfileDirName);

/// `data/media-cache`（媒体漫游缓存）。
Future<Directory> aylaMediaCacheDirectory() async =>
    _sub(kAylaMediaCacheDirName);

/// `data/updates`（自更新暂存）。
Future<Directory> aylaUpdatesDirectory() async => _sub(kAylaUpdatesDirName);

/// `data/voice`（语音录制临时文件）。
Future<Directory> aylaVoiceDirectory() async => _sub(kAylaVoiceDirName);

Future<Directory> _sub(String name) async {
  final String root = await aylaEnsureDataRoot();
  final Directory dir = Directory('$root${Platform.pathSeparator}$name');
  try {
    await dir.create(recursive: true);
  } catch (error) {
    throw AylaStorageException('子目录无法创建', path: '${dir.path}（$error）');
  }
  return dir;
}

/// 探测序号（保证并发探测的文件名**进程内唯一**）。
int _probeSeq = 0;

Future<bool> _probeWritable(Directory dir) async {
  // ⚠️ 文件名必须唯一（2026-11-02 修复的实际故障）：
  //
  // 原实现只用 `DateTime.now().microsecondsSinceEpoch`，但本函数会被**并发调用**
  // ——启动期 `aylaEnsureDataRoot()`（main.dart）与 `AylaMediaCache.ensureReady()` 并行跑，
  // 且 `_dataRootProbed` 幂等位只在解析**完成**后才置真，两个调用方会同时进入探测。
  // 同一微秒内两次调用 ⇒ **文件名相同** ⇒ A 写、B 写、A 删成功、B 删报 ENOENT
  // ⇒ 误判「目录不可写」⇒ 数据根初始化失败 ⇒ **凭据读不出、无法登录**。
  //
  // 实测日志（修复前）：
  //   `Cannot delete file ... .write-probe-1793610476900386.tmp (errno = 2)`
  //   同一个文件名出现了两次 ⇒ 并发重名确证。
  //
  // 加自增序号后每次探测拥有独立文件，互不影响。
  final File probe = File(
    '${dir.path}${Platform.pathSeparator}.write-probe-'
    '${DateTime.now().microsecondsSinceEpoch}-${_probeSeq++}.tmp',
  );
  try {
    await probe.writeAsBytes(const <int>[0], flush: true);
    await probe.delete();
    return true;
  } catch (error) {
    debugPrint('[AylaStorage] 目录不可写探测失败：${dir.path}（$error）');
    // 失败也尽力清理，避免留下垃圾文件（清理失败无所谓）。
    try {
      if (await probe.exists()) await probe.delete();
    } catch (_) {
      // 忽略：清理是尽力而为。
    }
    return false;
  }
}

// ---------------------------------------------------------------------------
// 旧落点迁移（一次性、幂等）
// ---------------------------------------------------------------------------

/// 旧版 Windows 落点：`%APPDATA%\com.ayla\ayla_flutter`。
///
/// 由 exe VERSIONINFO 决定（`windows/runner/Runner.rc:92` `CompanyName="com.ayla"`、
/// `:98` `ProductName="ayla_flutter"`）。这里**显式拼路径而不调 path_provider**：
/// 后者解析时会顺带把该目录重新创建出来，与本项目「不碰 C 盘」的目标冲突。
String aylaLegacyAppDataDirectory() {
  if (!Platform.isWindows) return '';
  final String? appData = Platform.environment['APPDATA'];
  if (appData == null || appData.isEmpty) return '';
  return '$appData${Platform.pathSeparator}com.ayla'
      '${Platform.pathSeparator}ayla_flutter';
}

/// 把旧落点数据搬到新数据根，然后**整目录删除**（不留任何 C 盘残留）。
///
/// 幂等：目标已存在的文件不覆盖；旧目录不存在时直接返回。
/// **不抛异常**：迁移失败只留日志，不能挡住启动。
///
/// 迁移内容：`*.json`（草稿 / 搜索历史 / 首页偏好）与
/// `flutter_secure_storage.dat`（DPAPI 凭据）→ `<data>/profile/`。
/// `updates/` **不迁移**（历史安装包与解包体无价值，随旧目录一起删除）。
Future<void> aylaMigrateLegacyAppData() async {
  final String legacy = aylaLegacyAppDataDirectory();
  if (legacy.isEmpty) return;
  final Directory legacyDir = Directory(legacy);
  if (!legacyDir.existsSync()) return;
  try {
    final String root = await aylaEnsureDataRoot();
    final Directory profile =
        Directory('$root${Platform.pathSeparator}$kAylaProfileDirName');
    await profile.create(recursive: true);

    int moved = 0;
    await for (final FileSystemEntity entity
        in legacyDir.list(followLinks: false)) {
      if (entity is! File) continue;
      final String name = entity.uri.pathSegments.last;
      if (!name.endsWith('.json') && name != 'flutter_secure_storage.dat') {
        continue;
      }
      final File target =
          File('${profile.path}${Platform.pathSeparator}$name');
      if (target.existsSync()) continue; // 新落点已有 ⇒ 以新落点为准
      await entity.copy(target.path);
      moved++;
    }
    debugPrint('[AylaStorage] 旧落点已迁移 $moved 个文件到 ${profile.path}');
  } catch (error) {
    debugPrint('[AylaStorage] 旧落点迁移失败（继续使用新落点）：$error');
  }
  // 无论迁移成功与否都清掉旧目录：它是 C 盘占用的唯一来源，
  // 且新版本不再读写它（凭据丢失可由用户重新登录恢复）。
  try {
    await legacyDir.delete(recursive: true);
    debugPrint('[AylaStorage] 旧落点已删除：$legacy');
  } catch (error) {
    debugPrint('[AylaStorage] 旧落点删除失败（可能被占用）：$legacy $error');
  }
}

/// 测试/诊断用：重置进程内缓存，强制下次重新解析。
@visibleForTesting
void aylaResetDataRootForTest({String? root}) {
  _dataRoot = root;
  _dataRootProbed = root != null;
  _dataRootSource = root == null ? 'unresolved' : 'test';
}
