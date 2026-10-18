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

import 'package:flutter/foundation.dart';

import '../net/dio_client.dart';
import '../../widgets/base/update_dialog.dart';
import 'app_version.dart';
import 'update_api.dart';
import 'update_applier.dart';
import 'update_exit.dart';
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
  final Future<void> Function(AylaUpdateApplyResult result) _onApplied;
  final VoidCallback _onCloseCallback;

  AylaUpdateDialogState _state;
  AylaPreparedUpdate? _prepared;
  bool _closed = false;
  bool _busy = false;

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
    _state = _state.copyWith(
      phase: AylaUpdatePhase.downloading,
      clearError: true,
      progress: 0,
    );
    notifyListeners();
    try {
      final AylaPreparedUpdate prepared = await _downloader.download(
        _state.download,
        onProgress: (AylaUpdateProgress progress) {
          if (_closed) return;
          _state = _state.copyWith(progress: progress.fraction);
          notifyListeners();
        },
      );
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
  void postpone() => _close();

  void _close() {
    if (_closed) return;
    _closed = true;
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

  /// 手动检查进行中（设置页据此禁用按钮）。
  bool get checking => _checking;

  /// 本次进程是否已经完成登录后自动检查（每个 app 进程只弹一次）。
  bool get loginCheckDone => _loginCheckDone;

  Future<AylaAppVersion> appVersion() async =>
      _version ??= await _versionLoader();

  /// 登录成功后调用：每个进程只检查一次；有更新则请求弹窗。
  ///
  /// 返回本次结果（未执行检查时返回 null），便于调用方记录日志。
  Future<AylaUpdateCheckResult?> checkOnLogin({
    String channel = AylaUpdateApi.defaultChannel,
  }) async {
    if (_loginCheckDone) return null;
    _loginCheckDone = true;
    try {
      final AylaUpdateCheckResult result = await _check(channel: channel);
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
    final AylaUpdateCheckResult result = await _check(channel: channel);
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

  /// 测试/手动重置：允许同进程再次自动检查（生产只在登录时调用一次）。
  @visibleForTesting
  void debugResetLoginCheck() => _loginCheckDone = false;
}
