/// presence 全局状态 —— web `stores/presence.ts`（49 行）的 Flutter 等价物。
///
/// ## 逐字段对应（web `stores/presence.ts:9–24`）
/// | 本类 | web | 口径 |
/// |---|---|---|
/// | [users] | `users: Record<string, string>` | `user_id → 连接状态`（`presence.update` 增量：online/offline） |
/// | [statuses] | `statuses: Record<string, string>` | `user_id → 状态模式`（`presence.status` 增量：auto/dnd/away/invisible） |
/// | [connection] | `connection: PresenceStatus` | 本通道连接状态 connecting/online/offline |
/// | `setUser` / `setUserStatus` / `removeUser` / `replaceAll` / `setConnection` / `reset` | 同名 | 语义逐条相同 |
///
/// ## 纪律（web 文件头 + `ws/presence.ts:116–118` 原话）
/// - `offline` 增量**保留记录**（`setUser(id, "offline")`）⇒ 显示层才能区分
///   「未收到过」与「已离线」（`utils/displayStatus.ts:45–47` 的 `known != null` 分支）；
/// - [removeUser] 只在**显式剔除**时用（删 key；web 侧无生产调用点）；
/// - [replaceAll] 是**全量替换**（REST 批量快照的入口；web 侧同样无生产调用点）；
/// - 本类**只存事实**（连接态 / 模式字符串）；显示口径（隐身强制离线、auto 跟随实时）
///   一律在 `state/display_status.dart`，与 web 的分层一致。
///
/// ## 生命周期（2026-10-02 修复）
/// 本类是 `ChangeNotifierProvider` 持有的可回收对象。**容器销毁期间**通道 owner
/// （`core/ws/presence_ws.dart` 的 `disconnect`，由 `ref.onDispose` 调用）仍会写它
/// ⇒ 所有写入与通知都必须在**已回收**时降级为「只改值、不通知」，否则
/// `ChangeNotifier.notifyListeners` 会抛 "was used after being disposed"。
/// 守卫见 [isDisposed] / [_notify]；不可通知的字段写入保持与 web store 同值。
library;

import 'package:flutter/foundation.dart';

/// presence 通道连接状态（web `PresenceStatus`，`stores/presence.ts:9`）。
enum AylaPresenceConnection { connecting, online, offline }

/// presence 状态（登录周期内单例；登出时 [reset]）。
class AylaPresenceState extends ChangeNotifier {
  Map<String, String> _users = const <String, String>{};
  Map<String, String> _statuses = const <String, String>{};
  AylaPresenceConnection _connection = AylaPresenceConnection.offline;

  /// `user_id → 连接状态`（不可变视图；**没收到过**的用户不在表里）。
  Map<String, String> get users => _users;

  /// `user_id → 状态模式`（不可变视图）。
  Map<String, String> get statuses => _statuses;

  /// 本通道连接状态。
  AylaPresenceConnection get connection => _connection;

  /// `presence.update` 增量（web `setUser`）：值**原样存**，
  /// `online` / `offline` 都保留记录。
  void setUser(String userId, String status) {
    _users = Map<String, String>.unmodifiable(<String, String>{
      ..._users,
      userId: status,
    });
    _notify();
  }

  /// `presence.status` 增量（web `setUserStatus`）：模式原样存
  /// （**不归一化**，未知值也照存 —— 显示层按 auto 兜底）。
  void setUserStatus(String userId, String status) {
    _statuses = Map<String, String>.unmodifiable(<String, String>{
      ..._statuses,
      userId: status,
    });
    _notify();
  }

  /// 移除单个用户的连接记录（web `removeUser`；不存在时同样通知一次，语义 = web 的新建对象）。
  void removeUser(String userId) {
    final Map<String, String> next = Map<String, String>.of(_users)
      ..remove(userId);
    _users = Map<String, String>.unmodifiable(next);
    _notify();
  }

  /// 全量替换在线集合（web `replaceAll`）。
  void replaceAll(Map<String, String> users) {
    _users = Map<String, String>.unmodifiable(users);
    _notify();
  }

  /// 写连接状态（同值不通知；可观察状态与 web 的 `set` 一致）。
  void setConnection(AylaPresenceConnection connection) {
    if (_connection == connection) return;
    _connection = connection;
    _notify();
  }

  /// 登出 / 显式断开：全清（web `reset`，`ws/presence.ts:145` 调用）。
  ///
  /// **幂等且可安全重入**：容器已回收（见 [isDisposed]）时只改值、不再通知，
  /// 不再抛 "was used after being disposed"（AGENTS.md §7 的关闭顺序/幂等要求）。
  void reset() {
    _users = const <String, String>{};
    _statuses = const <String, String>{};
    _connection = AylaPresenceConnection.offline;
    _notify();
  }

  // ---------------- 生命周期 ----------------

  bool _disposed = false;

  /// 是否已被 ProviderScope 回收（[dispose] 之后为真）。
  ///
  /// 与 `state/live_state.dart`（`isDisposed`，:283–296）、`state/paged_list.dart`
  /// （`_notify`，:181–190）、`state/badges_state.dart`（:17–51）同一形制。
  /// 调用方（例如 presence 通道的 `disconnect()`）可据此判断「这个 state 是否还能被写」。
  bool get isDisposed => _disposed;

  /// 仅在**未被回收**时通知。
  ///
  /// 为什么状态层要自己兜这一下（而不是靠调用方）：
  /// `ChangeNotifier.dispose()` 之后，本对象仍被通道客户端持有时**完全可写**
  /// （字段赋值不会抛），**只有通知会抛** —— 所以守卫必须落在状态层，
  /// 否则任何持有者（dispose 回调、迟到的 WS 帧、在途请求）都可能把容器关闭
  /// 变成一次未捕获异常。**不回滚字段赋值**：与 web store 语义一致，
  /// 「清空事实」不因为是最后一步就不做，只是不再广播。
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
