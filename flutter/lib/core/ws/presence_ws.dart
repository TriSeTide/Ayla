/// presence 通道客户端 —— web `ws/presence.ts`（151 行）的 Flutter 等价物。
///
/// ## 职责对应（web `ws/presence.ts`）
/// | 本类 | web |
/// |---|---|
/// | [attach] + `WsChannel` 的 `onEvent`/`onStatus` | `ws/presence.ts:31–93`（open/close/心跳/指数退避重连） |
/// | `presence.update` → `users` | `ws/presence.ts:113–118`（**归一化**：非 offline 一律记 online） |
/// | `presence.status` → `statuses` | `ws/presence.ts:119–123`（**原样存**，不归一化） |
/// | 连接态 → presence store + realtime | `ws/presence.ts:35 / 53 / 70 / 86`（connecting/online/offline） |
/// | [disconnect] 的 `reset()` | `ws/presence.ts:133–147`（登出：不重连 + 清 users/statuses/connection） |
///
/// ## 传输层归属（Flutter 侧差异，登记）
/// 路径 `/ws/presence/?token=`、**25s 心跳**（`kPresenceHeartbeat`）与指数退避重连
/// （1s→2s→…→30s）由 `core/ws/ws_manager.dart` 的 `WsChannel` 承担（web 是自己实现）；
/// 本类只做「帧 → 状态」与「连接态 → 状态」两件事。因此 [connect] 是**幂等**的：
/// 登录/注册路径先调 `wsManager.connectAll()`（已开 socket），再挂 owner
/// ⇒ 此时**不重复开连接**（`WsChannel.connectWithToken` 会新建 socket 并覆盖旧订阅）。
///
/// ## 未移植项（登记）
/// web 的 `onMessage`（`ws/presence.ts:127–130` 的 handlers 集合）**在 web 侧无消费者**
/// ⇒ 本类不提供该钩子；两类帧全部直写状态（域内没有第二类消费者）。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../state/presence_state.dart';
import '../../state/realtime_state.dart';
import 'ws_manager.dart';

/// presence 通道客户端（单例语义由 `aylaStartPresenceWs` 承担；测试可直接 new）。
class AylaPresenceWsClient {
  AylaPresenceWsClient({
    required AylaPresenceState presence,
    required AylaRealtimeState realtime,
  })  : _presence = presence,
        _realtime = realtime;

  final AylaPresenceState _presence;
  final AylaRealtimeState _realtime;

  WsChannel? _channel;
  bool _manualClosed = false;

  /// 绑定通道（生产 = `wsManager.presence`；测试 = 注入替身）。
  void attach(WsChannel channel) {
    _channel = channel;
    channel.onEvent = _dispatch;
    channel.onStatus = _onStatus;
    // attach 可能**晚于** connect（登录路径先 `wsManager.connectAll()`）⇒ 同步一次当前事实，
    // 否则会漏掉已经发生的 connecting/online 回调（状态卡在 offline）。
    _onStatus(channel.status);
  }

  /// 登录后连接（web `presenceClient.connect()`；令牌缺失时 `WsChannel` 自行 no-op）。
  void connect() {
    final WsChannel? channel = _channel;
    if (channel == null) return;
    _manualClosed = false;
    if (channel.status == WsChannelStatus.connecting ||
        channel.status == WsChannelStatus.online) {
      // 幂等：socket 已由 wsManager 开好（见文件头「传输层归属」）——只同步状态。
      _onStatus(channel.status);
      return;
    }
    channel.connect();
  }

  /// 显式断开（登出 / 401）：不自动重连，**清空在线集合**（web `disconnect` 的 `reset`）。
  void disconnect() {
    _manualClosed = true;
    _channel?.disconnect();
    _presence.reset();
    _realtime.setStatus(
      AylaRealtimeChannel.presence,
      AylaRealtimeConnection.offline,
    );
  }

  // ---------------- 连接生命周期 ----------------

  void _onStatus(WsChannelStatus status) {
    switch (status) {
      case WsChannelStatus.idle:
        break;
      case WsChannelStatus.connecting:
        _setConnection(
          _manualClosed
              ? AylaPresenceConnection.offline
              : AylaPresenceConnection.connecting,
        );
      case WsChannelStatus.online:
        _setConnection(AylaPresenceConnection.online);
      case WsChannelStatus.offline:
        _setConnection(AylaPresenceConnection.offline);
    }
  }

  void _setConnection(AylaPresenceConnection connection) {
    _presence.setConnection(connection);
    _realtime.setStatus(
      AylaRealtimeChannel.presence,
      switch (connection) {
        AylaPresenceConnection.connecting => AylaRealtimeConnection.connecting,
        AylaPresenceConnection.online => AylaRealtimeConnection.online,
        AylaPresenceConnection.offline => AylaRealtimeConnection.offline,
      },
    );
  }

  // ---------------- 帧分发（web `ws/presence.ts:111–125`） ----------------

  void _dispatch(Map<String, dynamic> frame) {
    final Object? rawType = frame['type'];
    if (rawType is! String) return;
    final Object? rawData = frame['data'];
    final Map<String, dynamic>? data = rawData is Map
        ? Map<String, dynamic>.from(rawData)
        : null;

    if (rawType == 'presence.update') {
      final String? userId = _userIdOf(data);
      if (userId != null) {
        // 记录已知状态（online/offline 都保留），供显示层区分「未收到」与「已离线」。
        // web：`data.status === "offline" ? "offline" : "online"`（其余值一律 online）。
        _presence.setUser(
          userId,
          data?['status'] == 'offline' ? 'offline' : 'online',
        );
      }
    } else if (rawType == 'presence.status') {
      final String? userId = _userIdOf(data);
      final Object? status = data?['status'];
      // 状态模式原样存（auto/dnd/away/invisible，未知值也不归一化）。
      // ⚠️ 缺 `status` 时不写：web 存进去的是 `undefined`，而 `??` 把 undefined 视为无值
      // （`displayStatus.ts:59`）⇒ 等价于「没有记录」，Dart 侧不能存成字符串 "null"。
      if (userId != null && status is String) {
        _presence.setUserStatus(userId, status);
      }
    }
  }

  String? _userIdOf(Map<String, dynamic>? data) {
    final Object? raw = data?['user_id'];
    if (raw == null) return null;
    final String id = raw.toString();
    return id.isEmpty ? null : id; // web `if (data?.user_id)`：空串是 falsy
  }

  // ---------------- 测试钩子 ----------------

  /// 测试专用：直接投喂一帧（生产路径是 [attach] 挂上的 `onEvent`）。
  @visibleForTesting
  void debugHandleFrame(Map<String, dynamic> frame) => _dispatch(frame);

  /// 测试专用：模拟通道状态回调（生产路径是 [attach] 挂上的 `onStatus`）。
  @visibleForTesting
  void debugHandleStatus(WsChannelStatus status) => _onStatus(status);
}
