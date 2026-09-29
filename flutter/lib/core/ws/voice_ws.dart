/// voice 应用层 WS 客户端 —— web `ws/voice.ts`（219 行）的 Flutter 等价物。
///
/// ## 职责对应（web `ws/voice.ts`）
/// | 本类 | web |
/// |---|---|
/// | [attach] + `WsChannel` 的 `onOpen` 钩子 | `ws/voice.ts:62–112`（open/close/generation 语义） |
/// | [subscribe] / [unsubscribe] | `ws/voice.ts:149–162`（幂等；服务端**无退订帧**，清本地集合即可） |
/// | [onReconnected] | `ws/voice.ts:81–85`（重连成功后重发 subscribe + 触发 `members/` 对账） |
/// | [onFrame] | `ws/voice.ts:192–195`（页面级监听：房内聊天帧 / voice.state） |
/// | `voice.state` → voice 状态 | `ws/voice.ts:183–190`（**仅** `voice.state` 直写状态，其余只透传） |
///
/// ## 帧契约（`backend/apps/voice/consumers.py`）
/// 发送帧：`subscribe {channel_ids}` / `ping {ts}`（30s 心跳，由 `WsChannel` 承担）。
/// 接收帧：`voice.subscribed` / `voice.state` / `voice.chat.message` / `pong` / `error`。
///
/// ⚠️ **订阅前提**：服务端**只在我已是成员时**才 `group_add`；非成员/不存在频道被静默忽略
/// ⇒ **必须先 REST `join/` 成功再 subscribe**（web 文件头原话，`ws/voice.ts:4–6`）。
/// ⚠️ `voice.state` **无补发语义** ⇒ 重连后必须走 `members/` 对账（见 [onReconnected]）。
library;

import '../../state/realtime_state.dart';
import '../../state/voice_state.dart';
import 'ws_manager.dart';

/// 接收帧处理器（页面级监听）。
typedef AylaVoiceFrameHandler = void Function(Map<String, dynamic> frame);

/// voice 应用层 WS 客户端。
class AylaVoiceWsClient {
  AylaVoiceWsClient({
    required AylaVoiceState voiceState,
    required AylaRealtimeState realtime,
  })  : _voice = voiceState,
        _realtime = realtime;

  final AylaVoiceState _voice;
  final AylaRealtimeState _realtime;

  WsChannel? _channel;
  bool _hasConnectedOnce = false;
  bool _manualClosed = false;

  /// 已订阅频道（重连后据此重发整个集合；web `subscribed: Set<string>`）。
  final Set<String> _subscribed = <String>{};

  final Set<AylaVoiceFrameHandler> _handlers = <AylaVoiceFrameHandler>{};
  final Set<void Function()> _reconnectHandlers = <void Function()>{};

  /// 当前连接状态（web `voiceWS.connection`）。
  AylaVoiceWsConnection get connection => _voice.wsConnection;

  /// 已订阅频道（只读）。
  Set<String> get subscribed => Set<String>.unmodifiable(_subscribed);

  /// 绑定通道（生产 = `wsManager.voice`；测试 = 注入替身）。
  void attach(WsChannel channel) {
    _channel = channel;
    channel.onEvent = _dispatch;
    channel.onOpen = _onOpen;
    channel.onStatus = _onStatus;
  }

  /// 连接（web `voiceWS.connect()`；令牌缺失时 no-op）。
  void connect() {
    final WsChannel? channel = _channel;
    if (channel == null) return;
    _manualClosed = false;
    _hasConnectedOnce = false;
    channel.connect();
  }

  /// 显式断开（登出）：不自动重连，清本地订阅集合（web `disconnect`）。
  void disconnect() {
    _manualClosed = true;
    _subscribed.clear();
    _handshakeNotified = false;
    _channel?.disconnect();
    _setConnection(AylaVoiceWsConnection.offline);
  }

  /// 订阅一批频道（幂等）。**必须在 REST join 成功后调用**。
  void subscribe(List<String> channelIds) {
    if (channelIds.isEmpty) return;
    final List<String> fresh = <String>[
      for (final String id in channelIds)
        if (_subscribed.add(id)) id,
    ];
    if (fresh.isEmpty) return;
    _send(<String, dynamic>{'type': 'subscribe', 'channel_ids': fresh});
  }

  /// 本地退订（离开频道时调用；服务端无退订帧）。
  void unsubscribe(String channelId) {
    _subscribed.remove(channelId);
  }

  /// 当前是否已订阅某频道。
  bool isSubscribed(String channelId) => _subscribed.contains(channelId);

  /// 重连成功回调（触发 `members/` 对账）；返回值 = 解注册函数。
  void Function() onReconnected(void Function() handler) {
    _reconnectHandlers.add(handler);
    return () => _reconnectHandlers.remove(handler);
  }

  /// 监听接收帧（返回值 = 取消函数）。
  void Function() onFrame(AylaVoiceFrameHandler handler) {
    _handlers.add(handler);
    return () => _handlers.remove(handler);
  }

  /// 发送一帧（房内聊天等**不经本类的业务**一律走 REST；本方法只给测试/扩展留口）。
  void send(Map<String, dynamic> json) => _send(json);

  // ---------------- 连接生命周期 ----------------

  bool _handshakeNotified = false;

  void _onStatus(WsChannelStatus status) {
    switch (status) {
      case WsChannelStatus.connecting:
        _setConnection(
          _manualClosed
              ? AylaVoiceWsConnection.offline
              : AylaVoiceWsConnection.connecting,
        );
      case WsChannelStatus.online:
        _setConnection(AylaVoiceWsConnection.online);
      case WsChannelStatus.offline:
        _setConnection(AylaVoiceWsConnection.offline);
      case WsChannelStatus.idle:
        break;
    }
  }

  void _setConnection(AylaVoiceWsConnection connection) {
    _voice.setWsConnection(connection);
    _realtime.setStatus(
      AylaRealtimeChannel.voice,
      switch (connection) {
        AylaVoiceWsConnection.online => AylaRealtimeConnection.online,
        AylaVoiceWsConnection.connecting => AylaRealtimeConnection.connecting,
        AylaVoiceWsConnection.offline => AylaRealtimeConnection.offline,
      },
    );
  }

  /// 连接建立：**首连不补发**（订阅前提是 join 成功，由页面调用 [subscribe]），
  /// 重连则重发整个已订阅集合 + 触发对账（web `ws/voice.ts:75–86`）。
  void _onOpen() {
    if (!_hasConnectedOnce) {
      _hasConnectedOnce = true;
      _handshakeNotified = true;
      return;
    }
    if (_subscribed.isNotEmpty) {
      _send(<String, dynamic>{
        'type': 'subscribe',
        'channel_ids': _subscribed.toList(growable: false),
      });
    }
    for (final void Function() handler
        in _reconnectHandlers.toList(growable: false)) {
      handler();
    }
  }

  void _send(Map<String, dynamic> json) {
    final void Function(Map<String, dynamic> frame)? override = debugSend;
    if (override != null) {
      override(json);
      return;
    }
    _channel?.send(json);
  }

  /// 测试专用：覆盖发送出口（断言 `subscribe` 帧形状）。
  void Function(Map<String, dynamic> frame)? debugSend;

  /// 测试专用：直接投喂一帧（生产路径是 [attach] 挂上的 `onEvent`）。
  void debugHandleFrame(Map<String, dynamic> frame) => _dispatch(frame);

  /// 测试专用：模拟通道 open（触发 [onOpen] 语义）。
  void debugHandleOpen() => _onOpen();

  /// 测试专用：是否已经过首连。
  bool get debugHasConnectedOnce => _hasConnectedOnce;

  /// 测试专用：首连是否已通知过。
  bool get debugHandshakeNotified => _handshakeNotified;

  // ---------------- 事件分发 ----------------

  void _dispatch(Map<String, dynamic> frame) {
    final Object? rawType = frame['type'];
    if (rawType is! String) return;
    if (rawType == 'voice.state') {
      final Object? rawData = frame['data'];
      if (rawData is Map) {
        final Map<String, dynamic> data = Map<String, dynamic>.from(rawData);
        final AylaVoiceMemberEventState? state =
            AylaVoiceMemberEventState.parse(data['state']);
        // 未知 state 枚举 → **不猜测语义**（不 fallback 成 joined/heartbeat）。
        if (state != null) {
          _voice.applyVoiceState(
            data['channel_id']?.toString() ?? '',
            data['user_id']?.toString() ?? '',
            state,
            data['ts']?.toString(),
          );
        }
      }
    }
    // voice.subscribed / voice.chat.message / pong / error：**只透传**给页面
    // （web `ws/voice.ts:188–190` 同口径；聊天帧由房内页消费）。
    for (final AylaVoiceFrameHandler handler
        in _handlers.toList(growable: false)) {
      handler(frame);
    }
  }
}
