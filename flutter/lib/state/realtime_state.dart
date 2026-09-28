/// 跨通道实时连接事实 —— web `stores/realtime.ts`（37 行）的 Flutter 等价物。
///
/// **只记录连接状态，不把失败伪装成空数据**（web 文件头原话）：
/// 页面若读不到在线状态，应显示「未知」，而不是「离线/0」。
library;

import 'package:flutter/foundation.dart';

/// 四通道（与 `core/ws/ws_manager.dart` 的 [WsChannelKind] 同集合）。
enum AylaRealtimeChannel { chat, presence, voice, live }

/// 连接状态（web `realtime.ts:5`）。
enum AylaRealtimeConnection { connecting, online, offline, failed }

/// 单通道状态（web `realtime.ts:7–11`）。
class AylaRealtimeStatus {
  const AylaRealtimeStatus({
    required this.connection,
    this.lastError,
    required this.updatedAt,
  });

  final AylaRealtimeConnection connection;

  /// 最近一次错误文案（null = 无）。**不得**用它顶替业务数据。
  final String? lastError;

  final DateTime updatedAt;
}

/// 实时连接状态表（四个通道各一档）。
class AylaRealtimeState extends ChangeNotifier {
  final Map<AylaRealtimeChannel, AylaRealtimeStatus> _statuses =
      <AylaRealtimeChannel, AylaRealtimeStatus>{
    for (final AylaRealtimeChannel c in AylaRealtimeChannel.values)
      c: AylaRealtimeStatus(
        connection: AylaRealtimeConnection.offline,
        updatedAt: DateTime.now(),
      ),
  };

  Map<AylaRealtimeChannel, AylaRealtimeStatus> get statuses =>
      Map<AylaRealtimeChannel, AylaRealtimeStatus>.unmodifiable(_statuses);

  AylaRealtimeStatus statusOf(AylaRealtimeChannel channel) =>
      _statuses[channel]!;

  /// 写一档状态（同值不通知）。
  void setStatus(
    AylaRealtimeChannel channel,
    AylaRealtimeConnection connection, {
    String? error,
  }) {
    final AylaRealtimeStatus prev = _statuses[channel]!;
    if (prev.connection == connection && prev.lastError == error) return;
    _statuses[channel] = AylaRealtimeStatus(
      connection: connection,
      lastError: error,
      updatedAt: DateTime.now(),
    );
    notifyListeners();
  }

  void reset() {
    for (final AylaRealtimeChannel c in AylaRealtimeChannel.values) {
      _statuses[c] = AylaRealtimeStatus(
        connection: AylaRealtimeConnection.offline,
        updatedAt: DateTime.now(),
      );
    }
    notifyListeners();
  }
}
