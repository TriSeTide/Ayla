/// WS 通道管理器骨架（四通道：chat / presence / voice 已接线；live 通道由
/// `core/ws/live_ws.dart` 的 `AylaLiveWsClient` 自理 —— 见下方各字段注释）。
///
/// 连接语义对照 `web/src/ws/chat.ts` + `ws/presence.ts`：
/// - 路径 `/ws/chat|presence/?token=<jwt>`（AuthMiddlewareStack，JWT query token）
/// - 心跳：chat 30s / presence 25s 发 `{"type":"ping","ts":...}`（保活 Redis TTL）
/// - 断线指数退避 1s→2s→…→30s 上限（复用 PoC relay_protocol 常量形态）
/// - 重连前令牌临期先 refresh 再连（web refreshAccessToken 语义，防 WSREJECT 循环）
/// - manualClose 不重连（登出语义；登出前调用 disconnect）
/// - chat 重连成功后对已订阅会话补发 resume（web chat.ts resume 帧；M2 接入订阅）
///
/// 事件分发：M0 只挂分发骨架（`onEvent` 回调 + pong 回执静默处理）；
/// **chat 通道的 41 个接收 case 由 `core/ws/chat_ws.dart` 的 [AylaChatWsClient] 承接**
/// （2026-09-28 消息域批次接线）；**presence 通道的两类帧（`presence.update` /
/// `presence.status`）由 `core/ws/presence_ws.dart` 的 `AylaPresenceWsClient` 承接**
/// （2026-09-29 presence 数据层接线）；voice 由 `core/ws/voice_ws.dart` 承接、
/// live 由 `core/ws/live_ws.dart` 自理（各见下方字段注释）。
///
/// ## 2026-09-28 变更（消息域批次）
/// - `subscribed` 集合的**读写归 owner**（chat_ws）：本类只保存它以便 [WsManager.dispose] 清理；
/// - `_onOpen` **不再**自动发 `resume`（原实现发的帧**缺 `last_message_seq`**，后端会按 0 补发
///   全部历史 —— 正是 web `ws/chat.ts:186–195` 记录过的「刷新群聊一口气加载所有历史」根因）。
///   首连补发 `subscribe` / 重连逐条 `resume` 的语义改由 [WsChannel.onOpen] 钩子交给 owner；
/// - 新增公开 [WsChannel.send]：owner 需要发 `subscribe` / `resume` 帧，而 `_sendJson` 是私有的。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../poc/relay_protocol.dart'
    show kPingIntervalMs, kReconnectBaseMs, kReconnectMaxMs;
import '../net/dio_client.dart';

/// 四通道（web §9：chat 主总线 / presence / live 房内帧 / voice 应用层成员事实）。
enum WsChannelKind { chat, presence, live, voice }

/// 通道连接状态（web realtime store 状态聚合的骨架）。
enum WsChannelStatus { idle, connecting, online, offline }

/// chat 心跳间隔（ws/chat.ts HEARTBEAT_INTERVAL_MS = 30s）
const Duration kChatHeartbeat = Duration(milliseconds: 30000);

/// presence 心跳间隔（ws/presence.ts 25s；relay_protocol kPingIntervalMs 同值）
const Duration kPresenceHeartbeat = Duration(milliseconds: kPingIntervalMs);

/// WS 通道（每通道独立状态机；socket 工厂可注入以便测试）。
class WsChannel {
  final WsChannelKind kind;

  /// 通道路径（/ws/chat/ 等）
  final String path;

  final Duration heartbeatInterval;

  /// 是否启用（live/voice 占位 = false，connect() no-op）
  final bool enabled;

  final AuthTokenStore _tokens;
  final Future<bool> Function() _refreshTokens;
  final WebSocketChannel Function(Uri uri) _connectFactory;

  WsChannelStatus _status = WsChannelStatus.idle;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _heartbeat;
  Timer? _reconnect;
  int _attempt = 0;
  bool _manualClosed = false;

  /// 已订阅会话 id 集合（**由 owner 维护**：chat 通道归 `chat_ws.dart`；
  /// 本类只在 [WsManager.dispose] 时统一清理）。
  final Set<String> subscribed = <String>{};

  /// 服务端事件分发（chat 的 41 个接收 case 见 `core/ws/chat_ws.dart`）
  void Function(Map<String, dynamic> json)? onEvent;

  /// 状态变化通知（页面/壳层观察连接态）
  void Function(WsChannelStatus status)? onStatus;

  /// 连接建立回调（`ready` 完成后触发一次）。
  ///
  /// **owner 负责首连 `subscribe` / 重连 `resume` 的区分**（web `ws/chat.ts:171–196`）。
  void Function()? onOpen;

  WsChannel({
    required this.kind,
    required this.path,
    required this.heartbeatInterval,
    required AuthTokenStore tokens,
    required Future<bool> Function() refreshTokens,
    required WebSocketChannel Function(Uri uri) connectFactory,
    this.enabled = true,
  })  : _tokens = tokens,
        _refreshTokens = refreshTokens,
        _connectFactory = connectFactory;

  WsChannelStatus get status => _status;

  void _setStatus(WsChannelStatus next) {
    if (_status == next) return;
    _status = next;
    onStatus?.call(next);
  }

  /// 登录后调用（web presence.connect 语义）。
  void connect() {
    if (!enabled) return;
    final String? access = _tokens.accessToken;
    if (access == null || access.isEmpty) return;
    connectWithToken(access);
  }

  /// 用指定 token 建立连接（Android 模拟器 10.0.2.2 / 桌面 127.0.0.1，同 dio）。
  void connectWithToken(String access) {
    if (!enabled) return;
    _manualClosed = false;
    _setStatus(WsChannelStatus.connecting);
    final String host = Platform.isAndroid ? '10.0.2.2' : '127.0.0.1';
    final Uri uri = Uri.parse(
      'ws://$host:8100$path?token=${Uri.encodeComponent(access)}',
    );
    try {
      final WebSocketChannel channel = _connectFactory(uri);
      _channel = channel;
      _sub = channel.stream.listen(
        _onMessage,
        onDone: _onClosed,
        onError: (Object _) {/* onDone 随后触发，统一走重连逻辑 */},
      );
      channel.ready.then((_) => _onOpen()).catchError((Object _) {});
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _onOpen() {
    _attempt = 0;
    _setStatus(WsChannelStatus.online);
    _startHeartbeat();
    // 订阅补发交给 owner（见文件头「2026-09-28 变更」）：本类不知道各会话的
    // `last_message_seq` 基线，自行发 `resume` 只会让后端按 0 补发全部历史。
    onOpen?.call();
  }

  void _onMessage(dynamic raw) {
    Map<String, dynamic>? json;
    try {
      final Object? decoded = jsonDecode(raw as String);
      if (decoded is Map<String, dynamic>) {
        json = decoded;
      }
    } catch (_) {
      return; // 非 JSON 帧静默忽略（不报错）
    }
    if (json == null) return;
    // pong：心跳回执，静默（web pong 属连接层）
    if (json['type'] == 'pong') return;
    onEvent?.call(json);
  }

  void _onClosed() {
    _stopHeartbeat();
    _setStatus(_manualClosed ? WsChannelStatus.offline : WsChannelStatus.connecting);
    if (!_manualClosed) _scheduleReconnect();
  }

  /// 指数退避重连（1s→2s→…→30s 上限；relay_protocol 常量形态）。
  /// 重连前先 refresh（令牌临期先 refresh 再连，防 WSREJECT 循环；
  /// 刷新失败仍用现有 token 重试——连接层不伪造成功）。
  void _scheduleReconnect() {
    final int delayMs = kReconnectBaseMs * (1 << _attempt);
    final int capped = delayMs > kReconnectMaxMs ? kReconnectMaxMs : delayMs;
    _attempt += 1;
    _reconnect?.cancel();
    _reconnect = Timer(Duration(milliseconds: capped), () async {
      if (_manualClosed) return;
      await _refreshTokens();
      final String? access = _tokens.accessToken;
      if (access == null || access.isEmpty || _manualClosed) return;
      connectWithToken(access);
    });
  }

  void _startHeartbeat() {
    _stopHeartbeat();
    _heartbeat = Timer.periodic(heartbeatInterval, (Timer _) {
      if (_status == WsChannelStatus.online) {
        _sendJson(<String, dynamic>{
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

  void _sendJson(Map<String, dynamic> json) {
    try {
      _channel?.sink.add(jsonEncode(json));
    } catch (_) {
      // sink 已关闭：连接关闭路径会统一走 _onClosed 重连
    }
  }

  /// 发送一帧（owner 用：`subscribe` / `resume` / 自定义帧）。
  ///
  /// ⚠️ 连接未 OPEN 时 [WebSocketChannel.sink] 会缓冲或丢弃 —— 与 web 的
  /// `sendJson`（`readyState !== OPEN` 直接不发送）同语义：owner 必须在 `onOpen` 时补发。
  void send(Map<String, dynamic> json) => _sendJson(json);

  /// 订阅会话（登记 id；帧由 owner 决定发 subscribe 还是 resume）。
  void subscribe(String conversationId) {
    subscribed.add(conversationId);
  }

  /// 显式断开（登出时调用）：不自动重连（web disconnect 语义）。
  void disconnect() {
    _manualClosed = true;
    _reconnect?.cancel();
    _reconnect = null;
    _stopHeartbeat();
    _sub?.cancel();
    _sub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _setStatus(WsChannelStatus.offline);
  }
}

/// WS 管理器：聚合四通道，负责令牌/刷新注入与启停。
class WsManager {
  final WsChannel chat;
  final WsChannel presence;
  final WsChannel live;
  final WsChannel voice;

  WsManager({
    required AuthTokenStore tokens,
    Future<bool> Function()? refreshTokens,
    WebSocketChannel Function(Uri uri)? connectFactory,
  })  : chat = WsChannel(
          kind: WsChannelKind.chat,
          path: '/ws/chat/',
          heartbeatInterval: kChatHeartbeat,
          tokens: tokens,
          refreshTokens: refreshTokens ?? _noRefresh,
          connectFactory: connectFactory ?? _defaultConnect,
        ),
        presence = WsChannel(
          kind: WsChannelKind.presence,
          path: '/ws/presence/',
          heartbeatInterval: kPresenceHeartbeat,
          tokens: tokens,
          refreshTokens: refreshTokens ?? _noRefresh,
          connectFactory: connectFactory ?? _defaultConnect,
        ),
        live = WsChannel(
          kind: WsChannelKind.live,
          path: '/ws/live/',
          heartbeatInterval: kChatHeartbeat,
          tokens: tokens,
          refreshTokens: refreshTokens ?? _noRefresh,
          connectFactory: connectFactory ?? _defaultConnect,
          enabled: false,
        ),
        // 2026-09-28（房内页批次）：voice 应用层通道**启用**。
        // 路径与心跳按 web `ws/voice.ts:18 / 63`：`/ws/voice/?token=` + **30s** ping
        // （原占位写的是 presence 的 25s，与 web 不一致 —— 一并订正）。
        // ⚠️ **live 通道仍占位**：web 的直播弹幕通道路径是 `/ws/live/<channel_id>/`，
        // **每频道一连接**（`ws/live.ts:62`），不是本类这种固定路径通道 ⇒ 由
        // `core/ws/live_ws.dart` 的 `AylaLiveWsClient` 自理（含 4401/4404 关闭码语义，
        // WsChannel 无此档）。本字段保留给「固定路径的直播类通道」将来使用，
        // 当前不参与任何链路（不静默冒充已接线）。
        voice = WsChannel(
          kind: WsChannelKind.voice,
          path: '/ws/voice/',
          heartbeatInterval: kChatHeartbeat,
          tokens: tokens,
          refreshTokens: refreshTokens ?? _noRefresh,
          connectFactory: connectFactory ?? _defaultConnect,
        );

  static Future<bool> _noRefresh() async => false;

  static WebSocketChannel _defaultConnect(Uri uri) =>
      IOWebSocketChannel.connect(uri);

  /// 登录后连接 chat/presence 两通道（web auth 恢复流程语义）。
  void connectAll() {
    chat.connect();
    presence.connect();
  }

  /// 登出前断开全部（不重连）。
  void disconnectAll() {
    chat.disconnect();
    presence.disconnect();
    live.disconnect();
    voice.disconnect();
  }

  /// 释放（disconnect + 清订阅）。
  void dispose() {
    disconnectAll();
    chat.subscribed.clear();
    presence.subscribed.clear();
  }
}

/// WS 管理器全局单例（main 中 wiring 后可用）。
WsManager? wsManager;

/// 便捷：应用启动 wiring（DioClient.init 后调用）。
/// 默认刷新实现：DioClient.refreshAccessToken（互斥锁 + 轮换，同 web
/// refreshAccessToken 语义——WS 重连前令牌临期先 refresh 再连）。
void initWsManager({
  required AuthTokenStore tokens,
  Future<bool> Function()? refreshTokens,
}) {
  wsManager?.dispose();
  wsManager = WsManager(
    tokens: tokens,
    refreshTokens:
        refreshTokens ?? () => DioClient.instance.refreshAccessToken(),
  );
}
