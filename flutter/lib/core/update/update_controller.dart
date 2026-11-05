/// 更新流程编排（检查 → 弹窗 → 下载 → 安装/重启）。
///
/// 归属边界
/// --------
/// - **登录成功后**主动检查一次（[AylaUpdateController.checkOnLogin]）：
///   每个账号会话只自动弹一次，避免每次页面切换都弹；
/// - **设置页手动检查**（[AylaUpdateController.checkManually]）：无论有没有更新都给出
///   明确反馈（通过回调交给页面显示 SnackBar/弹窗）；
/// - 弹窗由 [AylaUpdateDialogController] 持有下载/应用状态，本类负责把后端检查结果
///   与下载器/安装器接起来。
///
/// 失败语义
/// --------
/// - 检查失败（网络/503/清单损坏）：**不弹错误弹窗**（登录流程不能被更新检查拖垮），
///   只在 `debugPrint` 留原因；手动检查时返回失败原因给设置页展示；
/// - 下载失败：弹窗进入失败态，可重试；已下载的损坏包由下载器删除；
/// - 安装失败：弹窗进入失败态，保留已校验的包（重试安装不必重新下载）。
library;

import 'dart:async';

import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter/foundation.dart';

import '../net/dio_client.dart';
import '../../widgets/base/update_dialog.dart';
import 'app_version.dart';
import 'update_api.dart';
import 'update_applier.dart';
import 'update_exit.dart';
import 'update_install_launcher.dart';
import 'update_downloader.dart';

/// 一次检查的结果（手动检查与自动检查共用）。
class AylaUpdateCheckResult {
  const AylaUpdateCheckResult({required this.check, this.error});

  /// 服务端返回（检查失败时为 null）。
  final AylaUpdateCheck? check;

  /// 检查失败原因（检查成功时为 null）。
  final String? error;

  bool get hasUpdate => check?.hasVisibleUpdate ?? false;
  bool get degraded => check?.degraded ?? false;
  bool get failed => check == null || error != null;
}

/// 下载/安装弹窗的 controller 实现。
class AylaUpdateDialogSession extends AylaUpdateDialogController {
  AylaUpdateDialogSession({
    required AylaUpdateCheck check,
    required AylaUpdateDownloader downloader,
    required AylaUpdateApplier applier,
    required Future<void> Function(AylaUpdateApplyResult result) onApplied,
    required VoidCallback onClose,
  }) : _downloader = downloader,
       _applier = applier,
       _onApplied = onApplied,
       _onCloseCallback = onClose,
       _state = AylaUpdateDialogState(
         phase: AylaUpdatePhase.available,
         release: check.latest!,
         download: check.download!,
         mandatory: check.mandatory,
       );

  final AylaUpdateDownloader _downloader;
  final AylaUpdateApplier _applier;

  /// Android 安装权限引导（与 applier 内那份是同一通道；此处只用于跳设置）。
  final AylaUpdateInstallLauncher _installLauncher =
      const AylaUpdateInstallLauncher();
  final Future<void> Function(AylaUpdateApplyResult result) _onApplied;
  final VoidCallback _onCloseCallback;

  AylaUpdateDialogState _state;
  AylaPreparedUpdate? _prepared;
  bool _closed = false;
  bool _busy = false;

  /// 在途下载的取消令牌（关闭弹窗 / 换会话时取消，见 [_close]）。
  CancelToken? _cancelToken;

  /// 最近一次安装是否因「缺安装未知应用权限」被挡（Android）。
  bool _permissionRequired = false;

  @override
  AylaUpdateDialogState get state => _state;

  bool get closed => _closed;

  @override
  Future<void> startDownload() async {
    if (_busy || _closed) return;
    if (_prepared != null) {
      _state = _state.copyWith(phase: AylaUpdatePhase.ready, clearError: true);
      notifyListeners();
      return;
    }
    _busy = true;
    final CancelToken token = CancelToken();
    _cancelToken = token;
    _state = _state.copyWith(
      phase: AylaUpdatePhase.downloading,
      clearError: true,
      progress: 0,
    );
    notifyListeners();
    try {
      final AylaPreparedUpdate prepared = await _downloader.download(
        _state.download,
        cancelToken: token,
        onProgress: (AylaUpdateProgress progress) {
          if (_closed) return;
          _state = _state.copyWith(progress: progress.fraction);
          notifyListeners();
        },
      );
      if (_closed) return;
      _prepared = prepared;
      _state = _state.copyWith(
        phase: AylaUpdatePhase.ready,
        progress: 1,
        note: '下载完成，SHA-256 校验通过',
      );
    } catch (error) {
      _state = _state.copyWith(
        phase: AylaUpdatePhase.failed,
        error: _friendlyDownloadError(error),
        clearProgress: true,
      );
    } finally {
      _busy = false;
      if (!_closed) notifyListeners();
    }
  }

  @override
  Future<void> applyNow() async {
    if (_busy || _closed) return;
    final AylaPreparedUpdate? prepared = _prepared;
    if (prepared == null) {
      _state = _state.copyWith(
        phase: AylaUpdatePhase.failed,
        error: '更新包尚未下载完成',
      );
      notifyListeners();
      return;
    }
    _busy = true;
    _state = _state.copyWith(phase: AylaUpdatePhase.applying, clearError: true);
    notifyListeners();
    try {
      final AylaUpdateApplyResult result = await _applier.apply(prepared);
      // Android 缺「安装未知应用」权限：**不关弹窗、不伪装成失败**，
      // 进入可引导的失败态（文案 + 重试），由弹窗的「去设置」键跳系统设置。
      // 已校验的 APK 保留在 staging，授权后点「重试」不必重新下载。
      if (result.permissionRequired) {
        _state = _state.copyWith(
          phase: AylaUpdatePhase.failed,
          error: result.detail,
          note: '授权后回到这里点「重试」即可继续安装（不必重新下载）',
          clearProgress: true,
        );
        _permissionRequired = true;
        notifyListeners();
        return;
      }
      _permissionRequired = false;
      _state = _state.copyWith(
        phase: AylaUpdatePhase.applying,
        note: result.detail,
      );
      notifyListeners();
      await _onApplied(result);
      if (!result.restarting) {
        // 非 Windows 分支：安装器/下载页已打开，弹窗可关。
        _close();
      }
    } catch (error) {
      _state = _state.copyWith(
        phase: AylaUpdatePhase.failed,
        error: error is AylaUpdateApplyException
            ? error.message
            : '安装失败：$error',
      );
      notifyListeners();
    } finally {
      _busy = false;
    }
  }

  @override
  bool get permissionRequired => _permissionRequired;

  /// 跳系统「安装未知应用」授权页（Android）。
  @override
  Future<void> openInstallPermissionSettings() async {
    try {
      final bool ok = await _installLauncher.openInstallPermissionSettings();
      if (!ok) {
        _state = _state.copyWith(
          error: '无法打开系统设置，请手动到「设置 → 应用 → 特殊权限 → 安装未知应用」开启',
        );
        notifyListeners();
      }
    } catch (error) {
      debugPrint('[AylaUpdate] 打开安装权限设置失败：$error');
    }
  }

  /// 「稍后」：**与关闭键同一判据**（2026-11-05 修正）。
  ///
  /// 旧实现直接 `_close()`，绕过 [requestClose] 的 mandatory 判断 —— 当前 UI 的
  /// 「稍后」走的是 `onClose`（= `requestClose`）所以没暴露，但任何一次接线改动
  /// 都会让强制更新被「稍后」绕开。这里收敛成同一条判据，堵掉潜伏雷。
  @override
  void postpone() => requestClose();

  void _close() {
    if (_closed) return;
    _closed = true;
    // 取消在途下载：否则关闭弹窗后下载继续跑（占带宽、写磁盘），
    // 且回调仍会往一个已 dispose 的 session 上 notifyListeners。
    _cancelToken?.cancel('dialog closed');
    _onCloseCallback();
    dispose();
  }

  /// 用户点关闭（仅允许在非 mandatory 且非 busy 时）。
  void requestClose() {
    if (!_state.mandatory && !_busy) _close();
  }

  String _friendlyDownloadError(Object error) {
    if (error is AylaUpdateDownloadException) return error.message;
    return '下载失败：$error';
  }
}

/// 更新编排器（进程级单例由 provider 持有；测试直接 new）。
class AylaUpdateController extends ChangeNotifier {
  AylaUpdateController({
    AylaUpdateApi? api,
    AylaUpdateDownloader? downloader,
    AylaUpdateApplier? applier,
    Future<AylaAppVersion> Function()? versionLoader,
    void Function(AylaUpdateDialogSession session)? onDialogRequested,
    Future<void> Function(AylaUpdateApplyResult result)? onApplied,
    AylaProcessExit requestExit = aylaDefaultProcessExit,
    Duration exitDelay = const Duration(milliseconds: 400),
  }) : _api = api ?? const AylaUpdateApi(),
       _downloader = downloader ?? AylaUpdateDownloader(),
       _applier = applier ?? AylaUpdateApplier(),
       _versionLoader = versionLoader ?? loadAppVersion,
       _onDialogRequested = onDialogRequested,
       _onApplied = onApplied,
       _requestExit = requestExit,
       _exitDelay = exitDelay;

  final AylaUpdateApi _api;
  final AylaUpdateDownloader _downloader;
  final AylaUpdateApplier _applier;
  final Future<AylaAppVersion> Function() _versionLoader;
  final void Function(AylaUpdateDialogSession session)? _onDialogRequested;
  final Future<void> Function(AylaUpdateApplyResult result)? _onApplied;
  final AylaProcessExit _requestExit;
  final Duration _exitDelay;

  AylaAppVersion? _version;
  bool _loginCheckDone = false;
  bool _checking = false;
  AylaUpdateDialogSession? _activeSession;

  /// 登录会话代号：每次 [resetForNewSession] 自增。
  ///
  /// 在途检查跨过一次登出时，返回的结果**必须丢弃** —— 否则它会在宿主已卸载的
  /// 新会话里把 `_activeSession` 重新填上（旧 session 成孤儿、下一次登录被覆盖）。
  int _sessionEpoch = 0;

  /// 手动检查进行中（设置页据此禁用按钮）。
  bool get checking => _checking;

  /// 本次**登录会话**是否已经完成登录后自动检查（每个会话只弹一次）。
  bool get loginCheckDone => _loginCheckDone;

  Future<AylaAppVersion> appVersion() async =>
      _version ??= await _versionLoader();

  /// 版本是否可信（能读到真实安装包版本）。
  ///
  /// ## 为什么必须判（2026-11-05 审计发现的放大风险）
  /// [loadAppVersion] 读失败时回退 `0.0.0+0`（那是对的：更新不是启动硬依赖）。
  /// 但服务端按 `build` 比大小 ⇒ `0` 恒小于任何已发布版本 ⇒ **永远 update_available**。
  /// 若那一版还带 `--mandatory`，用户会陷入「每次登录都被强制更新弹窗锁死、
  /// 装上同一版本、再弹」的死循环。
  ///
  /// ⇒ 判据：`build <= 0` 视为「读不到版本」⇒ 自动检查**放弃本轮**（不弹窗、
  /// 不伪装成已是最新），手动检查则把原因交给调用方展示。
  bool get versionKnown {
    final AylaAppVersion? v = _version;
    return v != null && v.build > 0;
  }

  /// 登录成功后调用：每个**登录会话**只检查一次；有更新则请求弹窗。
  ///
  /// 返回本次结果（未执行检查时返回 null），便于调用方记录日志。
  Future<AylaUpdateCheckResult?> checkOnLogin({
    String channel = AylaUpdateApi.defaultChannel,
  }) async {
    if (_loginCheckDone) return null;
    _loginCheckDone = true;
    final int epoch = _sessionEpoch;
    try {
      final AylaUpdateCheckResult result = await _check(channel: channel);
      // 跨过登出（换会话）才回来的结果：丢弃，不弹窗。
      if (epoch != _sessionEpoch) return result;
      // 读不到当前版本（build=0）：**不弹**。否则服务端恒判「有更新」，
      // 配合 mandatory 会把「读版本失败」放大成每次登录都被强制更新锁死。
      if (result.hasUpdate && !versionKnown) {
        debugPrint('[AylaUpdate] 当前版本读取失败，跳过本轮自动更新提示');
        return result;
      }
      if (result.hasUpdate) _present(result.check!);
      return result;
    } catch (error) {
      debugPrint('[AylaUpdate] 登录后检查更新失败（不影响登录）：$error');
      return AylaUpdateCheckResult(check: null, error: '$error');
    }
  }

  /// 手动检查（设置页）：不吞错误，交给调用方展示。
  Future<AylaUpdateCheckResult> checkManually({
    String channel = AylaUpdateApi.defaultChannel,
  }) async {
    if (_checking) {
      throw const AylaUpdateException('已有更新检查在进行中');
    }
    final int epoch = _sessionEpoch;
    final AylaUpdateCheckResult result = await _check(channel: channel);
    if (epoch != _sessionEpoch) return result;
    // 手动检查同样不弹「读不到版本」的假更新，但**如实说明原因**（不静默）。
    if (result.hasUpdate && !versionKnown) {
      return AylaUpdateCheckResult(
        check: null,
        error: '无法读取当前安装包版本，暂时无法判断更新',
      );
    }
    if (result.hasUpdate) _present(result.check!);
    return result;
  }

  Future<AylaUpdateCheckResult> _check({required String channel}) async {
    _checking = true;
    try {
      final AylaAppVersion version = await appVersion();
      final AylaUpdateCheck check = await _api.check(
        version: version,
        channel: channel,
      );
      return AylaUpdateCheckResult(check: check);
    } on AylaUpdateException catch (error) {
      return AylaUpdateCheckResult(check: null, error: error.message);
    } on ApiException catch (error) {
      return AylaUpdateCheckResult(check: null, error: error.message);
    } finally {
      _checking = false;
    }
  }

  void _present(AylaUpdateCheck check) {
    late final AylaUpdateDialogSession session;
    session = AylaUpdateDialogSession(
      check: check,
      downloader: _downloader,
      applier: _applier,
      onApplied: (AylaUpdateApplyResult result) async {
        _activeSession = null;
        notifyListeners();
        await _onApplied?.call(result);
        if (result.restarting) {
          // Windows：覆盖脚本已启动。给界面一帧时间显示「正在安装」后退出，
          // 脚本会等本进程结束后覆盖安装目录并重启新版本。
          await Future<void>.delayed(_exitDelay);
          _requestExit(0);
        }
      },
      onClose: () {
        if (identical(_activeSession, session)) {
          _activeSession = null;
          notifyListeners();
        }
      },
    );
    _activeSession = session;
    _onDialogRequested?.call(session);
    notifyListeners();
  }

  /// 最近一次打开过的弹窗会话（设置页/测试可读；关闭后为 null）。
  AylaUpdateDialogSession? get activeSession => _activeSession;

  /// 换了一个**登录会话**（登出 / 401 过期 / 换账号登录）⇒ 复位自动检查位。
  ///
  /// ## 为什么必须复位（2026-11-05）
  /// 用户口径是「**每次登录**都自动检查更新」。`_loginCheckDone` 若按**进程**而不是
  /// 按会话计，则「登出 → 换号登录」之后再也不弹更新 —— 而换号登录恰恰是最需要
  /// 提示更新的场景（本机装的可能还是别人那次会话判过的旧版本）。
  ///
  /// ## 为什么顺手关掉在途弹窗
  /// 登出后 AppShell 会整棵卸载（路由守卫把人送回登录页）⇒ 弹窗宿主随之消失，
  /// 但 controller 里的 `_activeSession` 会留到下次登录 —— 于是「登出前正在下载的
  /// 那次更新」会在**另一个账号**登录后突然又弹出来。这里显式丢弃；**不动磁盘上
  /// 已校验的包**（下次真需要更新时会重新走检查 → 下载路径命中已有 staging）。
  void resetForNewSession() {
    _loginCheckDone = false;
    // 在途检查 / 在途下载的结果按会话代号丢弃（见 [_sessionEpoch]）。
    _sessionEpoch++;
    // ⚠️ 必须复位 `_checking`：登出前那次检查可能还卡在 dio 的 connect/receive
    // 超时里（10s / 20s），不复位会让换号登录后的第一次手动检查直接抛
    // 「已有更新检查在进行中」。
    _checking = false;
    final AylaUpdateDialogSession? session = _activeSession;
    _activeSession = null;
    // 释放旧 session（它在 `_close` 里才 dispose）：不 dispose 就成孤儿，
    // 且其内部 `_busy` / 下载回调会继续对着已卸载的宿主发通知。
    session?.dispose();
    notifyListeners();
  }

  /// 测试/手动重置：允许同进程再次自动检查（生产只在登录会话开始时复位）。
  @visibleForTesting
  void debugResetLoginCheck() => _loginCheckDone = false;
}
