/// 客户端更新编排的 Riverpod 接线（进程级单例 + 弹窗宿主）。
///
/// - [updateControllerProvider]：唯一 controller；登录后自动检查一次、设置页手动检查；
/// - [AylaUpdateHost]：挂在 AppShell 的 Stack 顶层，当 controller 打开会话时渲染
///   [AylaUpdateDialog]（自身不做任何请求）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/update/update_api.dart';
import '../core/update/update_applier.dart';
import '../core/update/update_controller.dart';
import '../core/update/update_downloader.dart';
import '../widgets/base/update_dialog.dart';

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
            '[AylaUpdate] apply result: ${result.mode} ${result.detail}',
          );
        },
      );
      ref.onDispose(controller.dispose);
      return controller;
    });

/// 更新弹窗宿主（无内容时返回 `SizedBox.shrink`）。
class AylaUpdateHost extends ConsumerWidget {
  const AylaUpdateHost({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AylaUpdateController controller = ref.watch(updateControllerProvider);
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final AylaUpdateDialogSession? session = controller.activeSession;
        if (session == null) return const SizedBox.shrink();
        return AylaUpdateDialog(
          controller: session,
          onClose: session.requestClose,
          showPostpone: true,
        );
      },
    );
  }
}
