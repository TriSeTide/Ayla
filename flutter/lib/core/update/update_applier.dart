/// 更新包落地：解包 / 生成覆盖安装脚本 / 启动安装器。
///
/// ## 平台策略（与后端发布产物对齐）
///
/// | 平台 | 产物 | 行为 |
/// |---|---|---|
/// | Windows | `zip`（`ayla_flutter.exe` + `data/` + 运行库） | 解包到临时目录 → 生成 `.cmd` 覆盖安装脚本 → 启动脚本 → **退出当前进程**，脚本等本进程退出后覆盖安装目录并重启应用（全程用户可见一个控制台窗口） |
/// | Android | `apk` | 先尝试直接打开本机 apk 安装器（`Intent.ACTION_VIEW`）；插件不可用/失败时退化为打开 package 下载页 |
/// | iOS | `ipa` / `manifest.plist` | iOS 不允许应用自装，只能打开 `itms-services://` 安装页（后端清单提供 `install_url`） |
/// | 其它 | — | 打开下载目录/安装页，由用户手动完成 |
///
/// ## 为什么 Windows 必须用脚本而不是「解压覆盖」
/// 运行中的 `ayla_flutter.exe`、`flutter_windows.dll`、`data/app.so` 被系统占用，
/// 应用自己无法覆盖自己。脚本在应用退出后再替换文件，然后重启新版本 —— 这是桌面端
/// 自更新唯一不需要管理员权限的可行路径。脚本从 **%TEMP% 的更新 staging 目录**运行，
/// 不写系统目录、不注册服务、不改 PATH。
library;

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'update_api.dart';
import 'update_install_launcher.dart';
import 'update_downloader.dart';

/// 更新安装的目标平台（默认读 dart:io Platform；测试可显式覆盖）。
enum AylaUpdatePlatformKind { windows, android, ios, macOS, linux, other }

AylaUpdatePlatformKind aylaCurrentUpdatePlatform() {
  if (Platform.isWindows) return AylaUpdatePlatformKind.windows;
  if (Platform.isAndroid) return AylaUpdatePlatformKind.android;
  if (Platform.isIOS) return AylaUpdatePlatformKind.ios;
  if (Platform.isMacOS) return AylaUpdatePlatformKind.macOS;
  if (Platform.isLinux) return AylaUpdatePlatformKind.linux;
  return AylaUpdatePlatformKind.other;
}

/// 安装/应用更新失败（消息可直接展示）。
class AylaUpdateApplyException implements Exception {
  const AylaUpdateApplyException(this.message);

  final String message;

  @override
  String toString() => 'AylaUpdateApplyException: $message';
}

/// 应用更新的结果 —— 调用方据此决定是否立即退出。
class AylaUpdateApplyResult {
  const AylaUpdateApplyResult({
    required this.mode,
    this.restarting = false,
    this.scriptPath,
    this.fallbackUrl,
    this.detail = '',
  });

  /// `windows_zip` / `android_apk` / `platform_store` / `open_download`。
  final String mode;

  /// Windows：安装脚本已启动，调用方必须尽快退出进程。
  final bool restarting;

  /// Windows：生成的覆盖安装脚本路径（诊断用）。
  final String? scriptPath;

  /// 无法原生安装时打开的页面（Android 下载页 / iOS itms-services）。
  final String? fallbackUrl;

  /// 附加说明（例如「已打开下载页」）。
  final String detail;
}

/// 更新落地器（可注入启动回调，便于测试不真正启动外部进程）。
class AylaUpdateApplier {
  AylaUpdateApplier({
    Future<Process> Function(List<String> command)? startProcess,
    Future<bool> Function(Uri uri)? openUrl,
    String? executablePath,
    this.applicationSupportPath,
    AylaUpdatePlatformKind? platform,
    AylaUpdateInstallLauncher? installLauncher,
  }) : _startProcess = startProcess ?? _defaultStartProcess,
       _openUrl = openUrl ?? launchUrl,
       _executablePath = executablePath,
       _platform = platform,
       _installLauncher = installLauncher ?? const AylaUpdateInstallLauncher();

  final Future<Process> Function(List<String> command) _startProcess;
  final Future<bool> Function(Uri uri) _openUrl;
  final String? _executablePath;

  /// 为未来「Linux/macOS 解包到应用支持目录」预留的注入点（当前 Windows 分支不读它）。
  final String? applicationSupportPath;

  /// 平台覆盖（null = 读 [Platform]；测试用）。
  final AylaUpdatePlatformKind? _platform;

  /// Android APK 安装器（MethodChannel；测试可注入替身）。
  final AylaUpdateInstallLauncher _installLauncher;

  AylaUpdatePlatformKind get _resolvedPlatform =>
      _platform ?? aylaCurrentUpdatePlatform();

  /// 应用已下载并校验的更新包。
  Future<AylaUpdateApplyResult> apply(AylaPreparedUpdate prepared) async {
    final AylaUpdateDownload download = prepared.download;
    final String kind = download.kind.toLowerCase();
    if (_resolvedPlatform == AylaUpdatePlatformKind.windows && kind == 'zip') {
      return _applyWindowsZip(prepared);
    }
    if (_resolvedPlatform == AylaUpdatePlatformKind.android && kind == 'apk') {
      return _applyAndroidApk(prepared);
    }
    if (_resolvedPlatform == AylaUpdatePlatformKind.ios) {
      final String? install = download.installUrl;
      if (install != null) {
        final bool opened = await _openUrl(Uri.parse(install));
        if (!opened) {
          throw const AylaUpdateApplyException('无法打开 iOS 安装页');
        }
        return const AylaUpdateApplyResult(
          mode: 'platform_store',
          detail: '已在系统安装页中打开更新，请按提示完成安装',
        );
      }
    }
    // 兜底：打开下载地址（桌面浏览器 / 文件管理器由系统决定）
    final bool opened = await _openUrl(Uri.parse(download.url));
    if (!opened) {
      throw const AylaUpdateApplyException('无法打开更新下载地址');
    }
    return const AylaUpdateApplyResult(
      mode: 'open_download',
      detail: '已打开下载地址，请手动完成安装',
    );
  }

  /// Windows：解包 + 生成覆盖脚本 + 启动脚本。
  Future<AylaUpdateApplyResult> _applyWindowsZip(
    AylaPreparedUpdate prepared,
  ) async {
    final Directory extractDir = Directory(
      '${prepared.stagingDir}${Platform.pathSeparator}extracted',
    );
    if (await extractDir.exists()) await extractDir.delete(recursive: true);
    await extractDir.create(recursive: true);
    try {
      final Archive archive = ZipDecoder().decodeBytes(
        await File(prepared.filePath).readAsBytes(),
        verify: true,
      );
      await extractArchiveToDisk(archive, extractDir.path);
    } catch (error) {
      throw AylaUpdateApplyException('更新包解包失败：$error');
    }
    final String root = await _resolveExtractRoot(extractDir);
    final String exeName = _exeName();
    final String exePath = '$root${Platform.pathSeparator}$exeName';
    if (!await File(exePath).exists()) {
      throw AylaUpdateApplyException('更新包缺少 $exeName');
    }
    final String targetDir = _resolveTargetDir();
    final String scriptPath =
        '${prepared.stagingDir}${Platform.pathSeparator}apply-update.cmd';
    final String logPath =
        '${prepared.stagingDir}${Platform.pathSeparator}apply-update.log';
    final String script = buildWindowsApplyScript(
      pid: pid,
      sourceDir: root,
      targetDir: targetDir,
      exeName: exeName,
      logPath: logPath,
    );
    await File(scriptPath).writeAsString(script, flush: true);
    try {
      await _startProcess(<String>['cmd.exe', '/c', 'start', '', scriptPath]);
    } catch (error) {
      throw AylaUpdateApplyException('无法启动覆盖安装脚本：$error');
    }
    return AylaUpdateApplyResult(
      mode: 'windows_zip',
      restarting: true,
      scriptPath: scriptPath,
      detail: '正在退出并覆盖安装，完成后会自动重启',
    );
  }

  /// Android：通过原生通道拉起系统安装器；不可用时退化为打开下载页。
  Future<AylaUpdateApplyResult> _applyAndroidApk(
    AylaPreparedUpdate prepared,
  ) async {
    bool launched = false;
    try {
      launched = await _installLauncher.installApk(prepared.filePath);
    } catch (error) {
      // 系统拒绝（未知来源权限未授予等）：保留 APK，展示可操作原因。
      throw AylaUpdateApplyException('无法启动 APK 安装器：$error');
    }
    if (launched) {
      return const AylaUpdateApplyResult(
        mode: 'android_apk',
        detail: '已打开系统安装器，请按提示完成安装',
      );
    }
    final bool fallback = await _openUrl(Uri.parse(prepared.download.url));
    if (!fallback) {
      throw const AylaUpdateApplyException('无法打开 APK 安装器或下载地址');
    }
    return AylaUpdateApplyResult(
      mode: 'open_download',
      fallbackUrl: prepared.download.url,
      detail: '当前构建没有内置安装器，已打开 APK 下载地址',
    );
  }

  String _exeName() {
    final String exe = Platform.resolvedExecutable;
    final int index = exe.lastIndexOf(Platform.pathSeparator);
    return index < 0 ? exe : exe.substring(index + 1);
  }

  String _resolveTargetDir() {
    final String exe = _executablePath ?? Platform.resolvedExecutable;
    final File file = File(exe);
    return file.parent.path;
  }

  Future<String> _resolveExtractRoot(Directory extractDir) async {
    final List<FileSystemEntity> entries = await extractDir.list().toList();
    final List<Directory> dirs = entries.whereType<Directory>().toList(
      growable: false,
    );
    final List<File> files = entries.whereType<File>().toList(growable: false);
    if (files.any((File f) => f.uri.pathSegments.last == _exeName())) {
      return extractDir.path;
    }
    if (dirs.length == 1) return dirs.first.path;
    throw const AylaUpdateApplyException('更新包结构不合法（找不到 exe 根目录）');
  }
}

/// 生成 Windows 覆盖安装脚本（纯函数，便于逐字符断言）。
///
/// 脚本行为：
/// 1. `taskkill /PID <pid>`（应用已退出时忽略失败）；
/// 2. `robocopy <source> <target> /E /COPY:DAT /R:3 /W:2`（只覆盖，不删除额外文件）；
/// 3. 成功后 `start "" "<target>\<exe>"` 重启应用；
/// 4. 全程把输出写入 log，避免用户看到一个空控制台。
String buildWindowsApplyScript({
  required int pid,
  required String sourceDir,
  required String targetDir,
  required String exeName,
  required String logPath,
}) {
  return <String>[
    '@echo off',
    'setlocal',
    'rem Ayla 覆盖安装脚本（由应用生成；仅在本机 %TEMP% 更新目录内运行）',
    'set "SRC=$sourceDir"',
    'set "DST=$targetDir"',
    'set "EXE=$exeName"',
    'set "LOG=$logPath"',
    'echo [%DATE% %TIME%] Ayla update start >> "%LOG%" 2>&1',
    'taskkill /PID $pid /T /F >> "%LOG%" 2>&1',
    'ping 127.0.0.1 -n 3 > nul',
    'robocopy "%SRC%" "%DST%" /E /COPY:DAT /R:3 /W:2 /NFL /NDL /NJH /NJS >> "%LOG%" 2>&1',
    'set "RC=%ERRORLEVEL%"',
    'if %RC% GEQ 8 (',
    '  echo [%DATE% %TIME%] robocopy failed rc=%RC% >> "%LOG%"',
    '  echo 更新安装失败，请查看日志：%LOG%',
    '  pause',
    '  exit /b %RC%',
    ')',
    'start "" "%DST%\\%EXE%"',
    'echo [%DATE% %TIME%] Ayla update done >> "%LOG%"',
    'exit /b 0',
    '',
  ].join('\r\n');
}

/// 清理失败的 staging 目录（失败不抛）。
Future<void> cleanupUpdateStaging(String stagingDir) async {
  try {
    final Directory dir = Directory(stagingDir);
    if (await dir.exists()) await dir.delete(recursive: true);
  } catch (error) {
    debugPrint('[AylaUpdate] 清理更新目录失败：$error');
  }
}

Future<Process> _defaultStartProcess(List<String> command) => Process.start(
  command.first,
  command.sublist(1),
  mode: ProcessStartMode.detached,
);
