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
    notifyListeners();
  }

  /// `presence.status` 增量（web `setUserStatus`）：模式原样存
  /// （**不归一化**，未知值也照存 —— 显示层按 auto 兜底）。
  void setUserStatus(String userId, String status) {
    _statuses = Map<String, String>.unmodifiable(<String, String>{
      ..._statuses,
      userId: status,
    });
    notifyListeners();
  }

  /// 移除单个用户的连接记录（web `removeUser`；不存在时同样通知一次，语义 = web 的新建对象）。
  void removeUser(String userId) {
    final Map<String, String> next = Map<String, String>.of(_users)
      ..remove(userId);
    _users = Map<String, String>.unmodifiable(next);
    notifyListeners();
  }

  /// 全量替换在线集合（web `replaceAll`）。
  void replaceAll(Map<String, String> users) {
    _users = Map<String, String>.unmodifiable(users);
    notifyListeners();
  }

  /// 写连接状态（同值不通知；可观察状态与 web 的 `set` 一致）。
  void setConnection(AylaPresenceConnection connection) {
    if (_connection == connection) return;
    _connection = connection;
    notifyListeners();
  }

  /// 登出 / 显式断开：全清（web `reset`，`ws/presence.ts:145` 调用）。
  void reset() {
    _users = const <String, String>{};
    _statuses = const <String, String>{};
    _connection = AylaPresenceConnection.offline;
    notifyListeners();
  }
}
