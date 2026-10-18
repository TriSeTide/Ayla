/// 需要退出进程的更新路径（Windows 覆盖安装）—— 可注入的薄封装。
///
/// 生产：`exit(0)`（Flutter 桌面端退出后由覆盖脚本拉起新版本）；
/// 测试：注入记录器，避免测试进程被真正结束。
library;

import 'dart:io';

typedef AylaProcessExit = void Function(int code);

const AylaProcessExit aylaDefaultProcessExit = exit;

/// 请求退出（测试可传替身）。
void aylaRequestProcessExit(AylaProcessExit requestExit, {int code = 0}) {
  requestExit(code);
}
