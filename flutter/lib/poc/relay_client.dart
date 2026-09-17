/// PoC-A 中继 WS 客户端。
///
/// 对照翻译 wsRelayRoom.ts 的连接/握手/控制/重连语义：
/// - 握手：ws 连接（token 走 query）→ 收 joined（含 slot + members）视为成功
/// - 控制帧：speaking{on} / mute{on} / ping{ts}
/// - 音频：C→S 20ms opus 包（binary）；S→C [1B slot][opus]（binary）
/// - 重连：指数退避 1s→30s，连续失败 6 次放弃（PoC 简化：不刷新 token，
///   重连沿用注入的 token；token 过期由用户手动重连）
/// - 断开（disconnect）后所有异步回调不再动作（closed 语义）
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'relay_protocol.dart';

/// 连接状态（对齐 client.ts LiveKitState）
enum RelayState { idle, connecting, connected, reconnecting, failed, closed }

/// 回调（对齐 wsRelayRoom.ts events / client.ts LiveKitEvents）
class RelayCallbacks {
  /// 状态变化
  void Function(RelayState state)? onStateChange;

  /// 收到 joined（我的 slot + 成员名单）——成员状态恢复点
  void Function(int mySlot, List<RelayMember> members)? onJoined;

  /// 远端加入
  void Function(int slot, String identity)? onMemberJoined;

  /// 远端离开
  void Function(int slot)? onMemberLeft;

  /// 远端说话状态
  void Function(int slot, bool on)? onSpeaking;

  /// 远端静音事实（媒体层）
  void Function(int slot, bool on)? onMuted;

  /// 收到一帧音频（[slot] 对方槽位，[opus] opus 包）
  void Function(int slot, Uint8List opus)? onAudio;

  /// pong 回执（RTT 测量：now - ts）
  void Function(int ts, Duration rtt)? onPong;

  /// 日志（UI 展示）
  void Function(String line)? onLog;
}

class RelayClient {
  RelayClient(this._url, this._events);

  final String _url;
  final RelayCallbacks _events;

  WebSocketChannel? _ws;
  StreamSubscription? _sub;
  Timer? _handshakeTimer;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  bool _closed = false; // 用户主动断开：之后所有异步回调不再动作
  bool _handshaken = false;
  int _reconnectAttempts = 0;
  int _consecutiveFailures = 0;
  RelayState _state = RelayState.idle;

  RelayState get state => _state;

  /// 诊断用（VM service evaluate 从外部库访问）
  bool get debugHandshaken => _handshaken;
  bool get debugWsConnected => _ws != null;
  int get debugFailures => _consecutiveFailures;

  void _setState(RelayState s) {
    _state = s;
    _events.onStateChange?.call(s);
  }

  void _log(String line) => _events.onLog?.call('[relay] $line');

  /// 建立连接并等待 joined 握手（超时 kHandshakeTimeoutMs）。
  Future<void> connect() async {
    _closed = false;
    _setState(RelayState.connecting);
    await _openOnce();
  }

  Future<void> _openOnce() async {
    final completer = Completer<void>();
    // dart:io WebSocket（web_socket_channel 的 IOWebSocketChannel）
    final ws = WebSocketChannel.connect(Uri.parse(_url));
    _ws = ws;
    _handshaken = false;

    _handshakeTimer?.cancel();
    _handshakeTimer = Timer(const Duration(milliseconds: kHandshakeTimeoutMs), () {
      if (completer.isCompleted) return;
      _log('握手超时（${kHandshakeTimeoutMs}ms）');
      _teardownSocket(ws);
      if (!completer.isCompleted) completer.completeError(Exception('语音通道连接超时'));
    });

    _sub = ws.stream.listen(
      (data) {
        if (data is String) {
          _handleText(ws, data, completer);
        } else if (data is List<int>) {
          // 握手期不该出现二进制帧：仅握手完成后处理
          if (_handshaken) _handleBinary(Uint8List.fromList(data));
        }
      },
      onError: (e) {
        if (_closed || completer.isCompleted) return;
        _log('连接错误: $e');
        _teardownSocket(ws);
        if (!completer.isCompleted) completer.completeError(Exception('语音通道连接失败'));
      },
      onDone: () {
        if (ws == _ws) _ws = null;
        if (_closed) return;
        if (!completer.isCompleted) {
          _handshakeTimer?.cancel();
          _teardownSocket(ws);
          completer.completeError(Exception('语音通道握手被拒（未认证、非频道成员或服务不可用）'));
          return;
        }
        _handleSocketClosed();
      },
    );
    await completer.future;
  }

  void _handleText(WebSocketChannel ws, String text, Completer<void> handshake) {
    dynamic parsed;
    try {
      parsed = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (parsed is! Map<String, dynamic>) return;
    final frame = RelayServerFrame.fromJson(parsed);
    switch (frame.type) {
      case 'joined':
        if (!handshake.isCompleted) {
          _handshakeTimer?.cancel();
          _log('joined: mySlot=${frame.slot} members=${frame.members?.length ?? 0}');
          _handshaken = true;
          _consecutiveFailures = 0;
          _reconnectAttempts = 0;
          _setState(RelayState.connected);
          _startPing();
          _events.onJoined?.call(frame.slot ?? -1, frame.members ?? const []);
          handshake.complete();
        }
        break;
      case 'member_joined':
        _events.onMemberJoined?.call(frame.slot ?? -1, frame.identity ?? '');
        break;
      case 'member_left':
        _events.onMemberLeft?.call(frame.slot ?? -1);
        break;
      case 'speaking':
        _events.onSpeaking?.call(frame.slot ?? -1, frame.on ?? false);
        break;
      case 'muted':
        _events.onMuted?.call(frame.slot ?? -1, frame.on ?? false);
        break;
      case 'pong':
        if (frame.ts != null) {
          final rtt = DateTime.now().millisecondsSinceEpoch - frame.ts!;
          _events.onPong?.call(frame.ts!, Duration(milliseconds: rtt));
        }
        break;
      case 'error':
        _log('服务端错误帧: ${frame.detail}');
        break;
      default:
        _log('未知控制帧: ${frame.type}');
    }
  }

  void _handleBinary(Uint8List bytes) {
    if (bytes.length < 2) return;
    final slot = bytes[0];
    final opus = Uint8List.fromList(bytes.sublist(1));
    _events.onAudio?.call(slot, opus);
  }

  void _handleSocketClosed() {
    if (_closed) return;
    if (!_handshaken) return; // 握手期失败由 completer 处理
    _log('连接断开，安排重连');
    _setState(RelayState.reconnecting);
    _stopPing();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_closed || _reconnectTimer != null) return;
    final delayMs =
        (kReconnectBaseMs * (1 << _reconnectAttempts)).clamp(0, kReconnectMaxMs);
    _reconnectAttempts += 1;
    _log('${delayMs}ms 后重连（第 $_reconnectAttempts 次）');
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      _reconnectTimer = null;
      _attemptReconnect();
    });
  }

  Future<void> _attemptReconnect() async {
    if (_closed) return;
    _consecutiveFailures += 1;
    if (_consecutiveFailures > kReconnectGiveUpAfter) {
      _log('连续失败 $_consecutiveFailures 次，放弃（failed）');
      _setState(RelayState.failed);
      return;
    }
    try {
      await _openOnce();
      // 重连成功：向新房间同步媒体事实（服务端房间表按连接重建）
      _log('重连成功，同步 mute 事实');
      sendControl('mute', on: !_micEnabled);
    } catch (e) {
      _log('重连失败: $e');
      _scheduleReconnect();
    }
  }

  bool _micEnabled = false;

  /// 发送文本控制帧（wsRelayRoom.ts sendControl）
  void sendControl(String type, {bool? on, int? ts}) {
    final ws = _ws;
    if (ws == null) return;
    ws.sink.add(controlJson(type, on: on, ts: ts));
  }

  /// 发送一个 opus 包（仅 connected + 开麦时发送，静音不发）
  void sendOpus(Uint8List opus) {
    final ws = _ws;
    if (ws == null || !_handshaken || !_micEnabled) return;
    ws.sink.add(opus);
  }

  /// 麦克风状态（媒体事实，供重连后同步 mute）
  void setMicEnabled(bool enabled) {
    _micEnabled = enabled;
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(
      const Duration(milliseconds: kPingIntervalMs),
      (_) => sendControl('ping', ts: DateTime.now().millisecondsSinceEpoch),
    );
  }

  void _stopPing() {
    _pingTimer?.cancel();
    _pingTimer = null;
  }

  void _teardownSocket(WebSocketChannel ws) {
    if (ws == _ws) _ws = null;
    _sub?.cancel();
    _sub = null;
    try {
      ws.sink.close();
    } catch (_) {}
  }

  /// 主动断开（幂等）。
  Future<void> disconnect() async {
    _closed = true;
    _handshakeTimer?.cancel();
    _reconnectTimer?.cancel();
    _stopPing();
    final ws = _ws;
    _ws = null;
    if (ws != null) {
      _sub?.cancel();
      _sub = null;
      try {
        await ws.sink.close(1000, 'leave');
      } catch (_) {}
    }
    _setState(RelayState.closed);
  }
}
