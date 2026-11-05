/// 客户端更新编排的 Riverpod 接线（进程级单例 + 弹窗宿主）。
///
/// - [updateControllerProvider]：唯一 controller；登录后自动检查一次、设置页手动检查；
/// - [AylaUpdateHost]：挂在 AppShell 的 Stack 顶层，当 controller 打开会话时渲染
///   [AylaUpdateDialog]（自身不做任何请求）。
///
/// ## 2026-11-05 两条修正（用户需求：电脑端 + 手机端都要「登录后自动检查更新并弹窗」）
/// 1. **挂到根 Overlay**（[AylaRootOverlay]）：与库内其余模态（确认弹窗 / 创建浮层 /
///    隐私弹层）同一口径。壳层 `Stack` 的上边界在**顶栏之下**（宽屏实测遮罩只覆盖
///    内容区、顶栏那一整条不压暗；Windows 自绘标题栏同理）⇒ 更新弹窗这种「整页模态」
///    必须挂根 Overlay，否则视觉上是「页面被压暗、顶栏和标题栏还亮着」。
/// 2. **登记返回键**（[aylaUpdateDialogBackHandler]）：弹窗不是路由，页面级 `PopScope`
///    到不了（机制链见 `layout/app_back.dart` 文件头）⇒ 手机端按返回会直接落到
///    「再按一次退出应用」。在**强制更新**弹窗上退出 App = 绕过更新，必须拦住。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_init.dart' show AppInit, AppInitStatus;
import '../core/update/update_api.dart';
import '../core/update/update_applier.dart';
import '../core/update/update_controller.dart';
import '../core/update/update_downloader.dart';
import '../layout/app_back.dart'
    show
        AylaUpdateDialogBackHandler,
        aylaUpdateDialogBackHandler,
        aylaWindowChromeLock;
import '../widgets/base/update_dialog.dart' show AylaUpdateDialog, AylaUpdatePhase;
import '../widgets/shell/create_sheet.dart' show AylaRootOverlay;

/// 全局更新 controller。测试可 override 注入替身。
final Provider<AylaUpdateController> updateControllerProvider =
    Provider<AylaUpdateController>((Ref ref) {
      final AylaUpdateController controller = AylaUpdateController(
        api: const AylaUpdateApi(),
        downloader: AylaUpdateDownloader(),
        applier: AylaUpdateApplier(),
        onApplied: (AylaUpdateApplyResult result) async {
          // Windows：安装脚本已启动，进程随即退出，onApplied 后不再做页面动作。
          // Android/iOS：安装器/下载页已被打开，弹窗自行关闭。
          debugPrint(
            '[AylaUpdate] apply result: '
            '${result.mode} ${result.detail}',
          );
        },
      );
      ref.onDispose(controller.dispose);
      return controller;
    });

/// 更新弹窗宿主（无内容时返回 `SizedBox.shrink`）。
///
/// 层序：弹窗经 [AylaRootOverlay] 挂到**根 Overlay** ⇒ 天然压过顶栏 / Windows 自绘
/// 标题栏 / 悬浮球 / FAB / 创建浮层（后两者在壳层 `Stack` 里，根 Overlay 在其之上）。
class AylaUpdateHost extends ConsumerStatefulWidget {
  const AylaUpdateHost({super.key});

  @override
  ConsumerState<AylaUpdateHost> createState() => _AylaUpdateHostState();
}

class _AylaUpdateHostState extends ConsumerState<AylaUpdateHost> {
  /// 本件登记进 [aylaUpdateDialogBackHandler] 的处理器（null = 未登记）。
  AylaUpdateDialogBackHandler? _registered;

  /// 当前是否已登记（避免每帧重复登记）。
  bool _registeredOpen = false;

  /// 返回键处理：交给 session 自己判（可关的关、强制更新/下载中不关）。
  ///
  /// 无论关不关都返回 true —— 返回键**绝不能**穿到「再按一次退出应用」
  /// （强制更新弹窗上退出 App 等于绕过更新）。
  bool _onBack() {
    final AylaUpdateDialogSession? session =
        ref.read(updateControllerProvider).activeSession;
    session?.requestClose();
    return true;
  }

  /// 强制更新 / 下载中 ⇒ 锁住 Windows 自绘标题栏的窗口键。
  ///
  /// 标题栏是 Navigator 的**兄弟且在上方**，root Overlay 盖不住它（推导见
  /// [aylaWindowChromeLock] 的文档）⇒ 不锁的话用户点 X 就绕过了强制更新。
  void _syncWindowChromeLock(AylaUpdateDialogSession? session) {
    final bool lock =
        session != null && (session.state.mandatory || session.state.phase == AylaUpdatePhase.downloading || session.state.phase == AylaUpdatePhase.applying);
    if (aylaWindowChromeLock.value == lock) return;
    // 在 build 期改 ValueNotifier 会触发「build 期间通知」断言 ⇒ 排到帧末。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      aylaWindowChromeLock.value = lock;
    });
  }

  void _syncBackHandler(bool open) {
    // ⚠️ 预加载门（`layout/app_gate.dart`）用 `Offstage` 表达 loading：
    // AppShell 已经在 build（于是本件也 build 了），但整棵子树**不绘制、不参与命中测试**。
    // 此时若登记返回键处理器 ⇒ 用户在门打开前按返回**完全没反应**
    // （弹窗看不见、也回不了主页），最长持续 20s（`kAppInitTimeoutMs`）。
    // ⇒ 门没 ready 就不登记；ready 后本件会再 build 一次并登记上。
    final bool gateOpen = AppInit.instance.status == AppInitStatus.loading;
    final bool want = open && !gateOpen;
    if (want == _registeredOpen) return;
    _registeredOpen = want;
    if (want) {
      final AylaUpdateDialogBackHandler handler = _onBack;
      _registered = handler;
      aylaUpdateDialogBackHandler = handler;
    } else {
      if (identical(aylaUpdateDialogBackHandler, _registered)) {
        aylaUpdateDialogBackHandler = null;
      }
      _registered = null;
    }
  }

  @override
  void dispose() {
    // 宿主消失（登出 / 401 送回登录页）⇒ 必须注销，否则返回键会被一个已卸载的
    // 处理器吞掉（用户会发现「登录页按返回没反应」）。
    if (identical(aylaUpdateDialogBackHandler, _registered)) {
      aylaUpdateDialogBackHandler = null;
    }
    // 窗口键锁同理：不解锁的话登出后标题栏三键永远点不动。
    aylaWindowChromeLock.value = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AylaUpdateController controller = ref.watch(updateControllerProvider);
    // ⚠️ 同时订阅预加载门：门 ready 时本件必须重建一次，把「因门而未登记」的
    // 返回键处理器补登记上（否则那个 0–20s 的窗口会永久丢掉返回键）。
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[controller, AppInit.instance]),
      builder: (BuildContext context, Widget? _) {
        final AylaUpdateDialogSession? session = controller.activeSession;
        _syncBackHandler(session != null);
        _syncWindowChromeLock(session);
        if (session == null) return const SizedBox.shrink();
        return AylaRootOverlay(
          // ⚠️ 必须按 session 给 key：换了一次更新会话（换号登录后的第二次检查）
          // 要重建弹窗，不能复用上一份已 closed 的 session。
          key: ObjectKey(session),
          builder: (BuildContext _) => AylaUpdateDialog(
            controller: session,
            onClose: session.requestClose,
            showPostpone: true,
          ),
        );
      },
    );
  }
}
