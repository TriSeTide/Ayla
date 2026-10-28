/// 媒体连接状态（对齐 web `client.ts` 的状态枚举；六值映射零改动）。
///
/// 2026-09 从 `relay_client.dart` 移到此处：ws_relay 中继实现已整体移除，
/// 但 `RelayState` 是**会话层契约**（状态映射函数、页面/Store 都依赖），与传输无关。
library;

/// 媒体连接状态。
enum RelayState {
  /// 未开始。
  idle,

  /// 连接中。
  connecting,

  /// 已连接。
  connected,

  /// 正在重连。
  reconnecting,

  /// 连接失败（需要用户决定重进）。
  failed,

  /// 已主动关闭。
  closed,
}
