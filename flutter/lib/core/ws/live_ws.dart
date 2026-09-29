/// 直播弹幕 WS 客户端 —— web `ws/live.ts`（189 行）的 Flutter 等价物。
///
/// ## 为什么不用 `WsChannel`
/// 直播弹幕通道**每频道一条连接**：`/ws/live/<channel_id>/?token=<jwt>`
/// （`ws/live.ts:62`），路径里带频道 id，与 `WsChannel` 的固定路径模型不同；
/// 且它有两个 `WsChannel` **没有**的语义：关闭码 `4401`（未认证）/
/// `4404`（频道不存在）**不重连**并回调 UI。故本类自理连接（同 web）。
///
/// ## 协议（`backend/apps/live/consumers.py`）
/// - 服务端只推 `danmaku` / `viewers` / `pong` / `error`；
/// - 客户端可发 `ping` 保活，**不能发弹幕**（发送走 REST，落库后服务端广播，
///   自己也会收到回帧 —— 单一数据流；`hooks/useDanmaku.ts:4–5`）；
/// - 帧是**平铺**的（不是 chat WS 那种 `data` 包装）：`{type:"danmaku", id, sender:{id,…}, content, …}`
///   （`api/types.ts:1105–1117`）、`{type:"viewers", channel_id, count, viewers}`（`1140–1145`）。
///
/// ## 重连
/// 指数退避 1s→2s→…→30s；重连成功后触发 [onReconnected]（由会话层拉历史弹幕对账去重 +
/// 补一次 SRS 判定 + 补一次在看人数快照；WS **无补发语义**）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../state/live_state.dart';
/// 心跳间隔（web `ws/live.ts:16` `HEARTBEAT_INTERVAL_MS = 30_000`）。
const Duration kLiveHeartbeat = Duration(seconds: 30);

/// 重连退避（web `ws/live.ts:17–18`）。
const int kLiveReconnectBaseMs = 1000;
const int kLiveReconnectMaxMs = 30000;

/// 服务端主动关闭的语义（web `LiveWSCloseReason`）。
enum AylaLiveWsCloseReason { unauthorized, channelNotFound, unknown }

/// 接收帧处理器。
typedef AylaLiveFrameHandler = void Function(Map<String, dynamic> frame);

/// 直播弹幕 WS 客户端（同一时刻至多一条连接 —— 切频道先断旧连接）。
class AylaLiveWsClient {
  AylaLiveWsClient({
    required String? Function() accessToken,
    Future<bool> Function()? refreshTokens,
    WebSocketChannel Function(Uri uri)? connectFactory,
  })  : _accessToken = accessToken,
        _refreshTokens = refreshTokens ?? _neverRefresh,
        _connectFactory = connectFactory ?? _defaultConnect;

  final String? Function() _accessToken;
  final Future<bool> Function() _refreshTokens;
  final WebSocketChannel Function(Uri uri) _connectFactory;

  static Future<bool> _neverRefresh() async => false;

  static WebSocketChannel _defaultConnect(Uri uri) =>
      IOWebSocketChannel.connect(uri);

  WebSocketChannel? _ws;
  StreamSubscription<dynamic>? _sub;
  Timer? _heartbeat;
  Timer? _reconnect;
  int _attempt = 0;
  bool _manualClosed = false;
  String? _channelId;
  int _generation = 0;
  final Set<AylaLiveFrameHandler> _handlers = <AylaLiveFrameHandler>{};

  /// 连接状态（供 UI 展示）。
  AylaLiveWsConnection connection = AylaLiveWsConnection.offline;

  /// 服务端主动关闭（4401/4404）时回调。
  void Function(AylaLiveWsCloseReason reason)? onClosedByServer;

  /// 重连成功（onopen 且非首连）时回调。
  void Function()? onReconnected;

  /// 连接状态变化回调。
  void Function(AylaLiveWsConnection conn)? onConnectionChange;

  /// 当前连接状态（测试/对账用）。
  AylaLiveWsConnection get connectionState => connection;

  /// 当前频道 id（null = 未连接）。
  String? get channelId => _channelId;

  /// 连接指定频道的弹幕 WS（重复调用先断开旧连接；token 缺失 ⇒ no-op）。
  void connect(String channelId) {
    final String? access = _accessToken();
    if (access == null || access.isEmpty) return;
    if (_ws != null || _channelId != null) disconnect();
    _channelId = channelId;
    _manualClosed = false;
    _attempt = 0;
    final int generation = ++_generation;
    _setConnection(AylaLiveWsConnection.connecting);
    _open(channelId, access, generation);
  }

  Uri _uri(String channelId, String access) {
    final String host = Platform.isAndroid ? '10.0.2.2' : '127.0.0.1';
    return Uri.parse(
      'ws://$host:8100/ws/live/${Uri.encodeComponent(channelId)}/'
      '?token=${Uri.encodeComponent(access)}',
    );
  }

  void _open(String channelId, String access, int generation) {
    WebSocketChannel ws;
    try {
      ws = _connectFactory(_uri(channelId, access));
    } catch (_) {
      if (generation == _generation) _scheduleReconnect(generation);
      return;
    }
    _ws = ws;
    _sub = ws.stream.listen(
      (dynamic data) {
        if (generation != _generation || _ws != ws) return;
        if (data is! String) return;
        Object? parsed;
        try {
          parsed = jsonDecode(data);
        } catch (_) {
          return;
        }
        if (parsed is! Map<String, dynamic>) return;
        if (parsed['type'] == 'pong') return; // 心跳回执静默
        _dispatch(parsed);
      },
      onError: (Object _) {
        // onDone 随后触发，统一走重连逻辑
      },
      onDone: () {
        if (generation != _generation || _ws != ws) return;
        _ws = null;
        _stopHeartbeat();
        _setConnection(AylaLiveWsConnection.offline);
        final int? code = ws.closeCode;
        if (code == 4401) {
          _manualClosed = true;
          onClosedByServer?.call(AylaLiveWsCloseReason.unauthorized);
          return;
        }
        if (code == 4404) {
          _manualClosed = true;
          onClosedByServer?.call(AylaLiveWsCloseReason.channelNotFound);
          return;
        }
        if (!_manualClosed) _scheduleReconnect(generation);
      },
    );
    // ready = 握手完成（web `onopen`）：首连不算"重连"，重连要通知对账。
    ws.ready.then((_) {
      if (generation != _generation || _ws != ws) {
        unawaited(_closeQuietly(ws));
        return;
      }
      final bool isReconnect = _attempt > 0;
      _attempt = 0;
      _setConnection(AylaLiveWsConnection.online);
      _startHeartbeat();
      if (isReconnect) onReconnected?.call();
    }).catchError((Object _) {
      // 连接失败：onDone 会随后触发
    });
  }

  void _startHeartbeat() {
    _stopHeartbeat();
    _heartbeat = Timer.periodic(kLiveHeartbeat, (_) {
      if (connection == AylaLiveWsConnection.online) {
        _send(<String, dynamic>{
          'type': 'ping',
          'ts': DateTime.now().millisecondsSinceEpoch,
        });
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  void _scheduleReconnect(int generation) {
    if (generation != _generation || _reconnect != null || _manualClosed) return;
    final int delay =
        (kLiveReconnectBaseMs * (1 << _attempt)).clamp(0, kLiveReconnectMaxMs);
    _attempt += 1;
    _setConnection(AylaLiveWsConnection.connecting);
    _reconnect = Timer(Duration(milliseconds: delay), () {
      _reconnect = null;
      final String? channelId = _channelId;
      if (_manualClosed || channelId == null || generation != _generation) {
        return;
      }
      // 重连前先续期（令牌过期是断连最常见原因；web 在 openOnce 前取最新 token）
      unawaited(_refreshTokens().then((bool _) {
        final String? access = _accessToken();
        if (access == null || access.isEmpty || _manualClosed) return;
        if (generation != _generation) return;
        _open(channelId, access, generation);
      }));
    });
  }

  void _setConnection(AylaLiveWsConnection conn) {
    connection = conn;
    onConnectionChange?.call(conn);
  }

  void _send(Map<String, dynamic> json) {
    try {
      _ws?.sink.add(jsonEncode(json));
    } catch (_) {
      // 连接关闭路径会统一走重连
    }
  }

  void _dispatch(Map<String, dynamic> frame) {
    for (final AylaLiveFrameHandler handler
        in _handlers.toList(growable: false)) {
      handler(frame);
    }
  }

  /// 监听接收帧（返回值 = 取消函数）。
  void Function() onFrame(AylaLiveFrameHandler handler) {
    _handlers.add(handler);
    return () => _handlers.remove(handler);
  }

  /// 测试专用：直接投喂一帧。
  void debugHandleFrame(Map<String, dynamic> frame) => _dispatch(frame);

  /// 显式断开（退房时调用）：不自动重连。
  void disconnect() {
    _manualClosed = true;
    _generation += 1;
    _channelId = null;
    _reconnect?.cancel();
    _reconnect = null;
    _stopHeartbeat();
    final WebSocketChannel? ws = _ws;
    _ws = null;
    _sub?.cancel();
    _sub = null;
    if (ws != null) unawaited(_closeQuietly(ws));
    _setConnection(AylaLiveWsConnection.offline);
  }

  Future<void> _closeQuietly(WebSocketChannel ws) async {
    try {
      await ws.sink.close();
    } catch (_) {}
  }
}
