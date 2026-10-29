/// 后台下载保活（Android 前台服务 / iOS 尽力而为）。
///
/// ## 用户要求（2026-10-29 拍板）
///
/// > 创建一个后台静默的下载任务，直到下载成功了为止，app 内无论在什么位置都保持
/// > 下载，包括 app 后台运行时。
///
/// ## 平台能力边界（如实声明，不假装 iOS 能做到）
///
/// | 平台 | 能做到什么 | 依据 |
/// |---|---|---|
/// | **Android** | 前台服务常驻（通知栏一条「正在缓存媒体」），App 退到后台**继续下载**；进程被系统杀掉后由下次启动的 [AylaMediaDownloadQueue.resumeOnStartup] 续跑 | `flutter_foreground_task` 的前台服务在 Android 8+ 是标准能力 |
/// | **iOS** | **做不到常驻后台下载**。系统只给有限宽限期，App 被上滑杀死后不保证续传。现实策略 = 前台持续 + 进入后台尽力续传 + **下次启动立刻续跑**（与用户要求的「下次启动重新开始」一致） | iOS 后台执行模型限制，无法绕过 |
/// | **Windows** | 无「后台」概念：进程活着就继续，关掉下次启动续跑 | — |
///
/// ## 为什么放在这里而不是队列里
///
/// [AylaMediaDownloadQueue] 只关心「下什么、重试几次、写不写盘」，**不关心进程状态**
/// —— 它可以在纯 Dart 单测里跑。前台服务是**平台副作用**，单独一层，队列不认识它。
/// 两者通过 [AylaDownloadKeepAlive.syncWithQueue] 单向关联：队列有活 ⇒ 保活；空 ⇒ 停。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'media_download_queue.dart';

/// 前台服务的任务回调（Android 侧每分钟被唤醒一次，用来兜底推进队列）。
typedef AylaKeepAliveTick = void Function();

/// 后台下载保活控制器（单例：[AylaDownloadKeepAlive.instance]）。
class AylaDownloadKeepAlive {
  AylaDownloadKeepAlive();

  static final AylaDownloadKeepAlive instance = AylaDownloadKeepAlive();

  /// 是否已启动前台服务（幂等）。
  bool _running = false;

  /// 当前是否在保活。
  bool get isRunning => _running;

  /// 注入点：真正的平台启动/停止实现（生产见 [AylaForegroundServiceImpl]）。
  @visibleForTesting
  Future<void> Function()? debugStart;
  @visibleForTesting
  Future<void> Function()? debugStop;

  /// 是否需要保活（Android 才有意义；其它平台是 no-op）。
  bool get _supported => !kIsWeb && Platform.isAndroid;

  /// 按队列状态同步保活（队列有活 ⇒ 起；空 ⇒ 停）。
  ///
  /// 调用点：队列的每次 `pump()` 之后、以及 `enqueue` 之后。
  /// 幂等：重复调用不会重复起服务。
  Future<void> syncWithQueue() async {
    if (!_supported) return;
    final bool busy = AylaMediaDownloadQueue.instance.stats.total > 0;
    if (busy && !_running) {
      await start();
    } else if (!busy && _running) {
      await stop();
    }
  }

  /// 起前台服务（幂等）。
  ///
  /// **失败不抛**：拿不到通知权限/被系统拒绝时只记日志 —— 下载仍会在前台继续，
  /// 只是退到后台可能被挂起（缓存是增强项，不能因此阻断媒体链路）。
  Future<void> start() async {
    if (_running) return;
    _running = true;
    try {
      final Future<void> Function()? custom = debugStart;
      if (custom != null) {
        await custom();
      } else {
        await AylaForegroundServiceImpl.start();
      }
    } catch (error) {
      debugPrint('[AylaDownloadKeepAlive] 启动前台服务失败（忽略）：$error');
    }
  }

  /// 停前台服务（幂等；失败不抛）。
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    try {
      final Future<void> Function()? custom = debugStop;
      if (custom != null) {
        await custom();
      } else {
        await AylaForegroundServiceImpl.stop();
      }
    } catch (error) {
      debugPrint('[AylaDownloadKeepAlive] 停止前台服务失败（忽略）：$error');
    }
  }

  @visibleForTesting
  void resetForTest() {
    _running = false;
    debugStart = null;
    debugStop = null;
  }
}

/// Android 前台服务的默认实现（`flutter_foreground_task`）。
///
/// 只在 Android 上真正做事；其它平台直接返回，保证调用方不必自己判平台。
abstract final class AylaForegroundServiceImpl {
  /// 通知标题/正文（用户可视）。
  static const String notificationTitle = 'Ayla 正在缓存媒体';
  static const String notificationText = '后台保存聊天媒体，完成后自动停止';

  static Future<void> start() async {
    if (kIsWeb || !Platform.isAndroid) return;
    // 依赖在 Android 侧真正可用；导入是延迟的，桌面/iOS 构建不会触发插件通道。
    await _startAndroid();
  }

  static Future<void> stop() async {
    if (kIsWeb || !Platform.isAndroid) return;
    await _stopAndroid();
  }

  /* 平台调用集中在下面两个函数，方便后续替换实现（不影响调用方契约）。 */
  static Future<void> _startAndroid() async {
    final Future<void> Function(bool start)? bridge = _foregroundBridge;
    if (bridge != null) {
      await bridge(true);
      return;
    }
    await aylaStartAndroidForegroundTask();
  }

  static Future<void> _stopAndroid() async {
    final Future<void> Function(bool start)? bridge = _foregroundBridge;
    if (bridge != null) {
      await bridge(false);
      return;
    }
    await aylaStopAndroidForegroundTask();
  }

  /// 平台桥（`main.dart` 可注入替身；测试用）。
  ///
  /// 生产默认走下面的 [aylaStartAndroidForegroundTask]（真实插件），
  /// 注入只用于测试隔离 —— 不能用「默认 null ⇒ no-op」，否则真机上永远不起服务。
  static Future<void> Function(bool start)? _foregroundBridge;

  /// 注册平台桥（`main.dart` 启动时调用一次；测试也可注入）。
  static void install(Future<void> Function(bool start) bridge) {
    _foregroundBridge = bridge;
  }

  @visibleForTesting
  static void uninstall() => _foregroundBridge = null;
}

/// 真正启动 Android 前台服务（`flutter_foreground_task`）。
///
/// 通知文案固定在这里，避免散落到 UI 层。**失败只记日志**：
/// 用户拒绝通知权限时下载仍在前台继续，只是退到后台可能被系统挂起。
Future<void> aylaStartAndroidForegroundTask() async {
  try {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'ayla_media_download',
        channelName: 'Ayla 媒体缓存',
        channelDescription: '后台保存聊天媒体（图片/语音/视频）',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
    final ServiceRequestResult result = await FlutterForegroundTask.startService(
      serviceId: 5201,
      serviceTypes: const <ForegroundServiceTypes>[
        ForegroundServiceTypes.dataSync,
      ],
      notificationTitle: AylaForegroundServiceImpl.notificationTitle,
      notificationText: AylaForegroundServiceImpl.notificationText,
    );
    if (result is ServiceRequestFailure) {
      debugPrint('[AylaDownloadKeepAlive] 前台服务启动失败：${result.error}');
    }
  } catch (error) {
    debugPrint('[AylaDownloadKeepAlive] 前台服务启动异常：$error');
  }
}

/// 停止 Android 前台服务（幂等）。
Future<void> aylaStopAndroidForegroundTask() async {
  try {
    await FlutterForegroundTask.stopService();
  } catch (error) {
    debugPrint('[AylaDownloadKeepAlive] 前台服务停止异常：$error');
  }
}
