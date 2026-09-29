/// 语音房 WS 音频中继客户端（**媒体面**）—— web `livekit/wsRelayRoom.ts`（825 行）
/// 的连接/握手/控制/重连语义，Flutter 侧的正式实现。
///
/// ## 来源与沿革
/// 本文件 = PoC-A 的 `lib/poc/relay_client.dart`（2026-09-17 双端实测验收：joined/slot
/// 分配、member_joined/left 广播、speaking 广播、带 slot 前缀的音频帧转发、RTT 4ms）
/// **原样提升到 `lib/audio/`**。PoC 目录在 2026-09-25 组件库整理（`98d65e2`）时把
/// `relay_client.dart` / `audio_engine.dart` 一并删除、只留 `relay_protocol.dart`；
/// 房内页接线轮（本批）按 `POC_README.md §4` 的「整链照抄 PoC-A 代码形态」把它取回，
/// 并在下列三处**补齐 web 语义**（PoC 里被标为「简化」的部分）：
///
/// | 补 | web 事实源 |
/// |---|---|
/// | 重连沿用 token → **连续失败达阈值先续期** | `wsRelayRoom.ts:153–166 / 252–262 / 688–693` |
/// | `micEnabled` 门控发送 + 重连后同步 `mute` 事实 | 同 `732` |
/// | 首次连接失败 ⇒ `failed` 且**由调用方决定重进**（媒体断线 ≠ 离开频道） | `client.ts:15 / 726` |
/// | 远端音量**按 user_id 生效**（slot ↔ identity 映射） | `wsRelayRoom.ts:309 / 349` 的 per-slot gain |
///
/// ## 协议（`backend/apps/voice/audio_consumer.py` + `audio_relay.py`）
/// ```
/// C→S binary : 一个 20ms Opus 包（仅 speaking 时发送）
/// S→C binary : [1 字节 slot][Opus 包]
/// text       : joined / member_joined / member_left / speaking / muted / pong / error
/// ```
/// 常量（采样率 / 帧长 / 说话迟滞 / 心跳 / 退避）全部读 `lib/poc/relay_protocol.dart`，
/// **本文件不重复定义数值**。
///
/// ## token 纪律
/// token 只作 query 参数传递，**不打日志、不落盘、不缓存跨房间复用**（同 web 文件头）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../poc/relay_protocol.dart';

/// 连续失败达该次数后先续期 token 再重连（web `wsRelayRoom.ts:117` RECONNECT_REFRESH_AFTER）。
const int kRelayReconnectRefreshAfter = 3;

/// 中继连接地址（web `wsRelayRoom.ts:35–37` 的 `voiceDirectWsUrl`）。
///
/// web 走 `VITE_VOICE_DIRECT_WS`（生产 = `wss://live.trise.top:7881`；本地 = vite 的
/// `wss://127.0.0.1:5173` 反代到 8100）。Flutter 侧没有反代，直连后端 daphne 的
/// `/ws/voice/audio/`（与 `core/ws/ws_manager.dart` 的四通道同主机同端口约定：
/// Android 模拟器 `10.0.2.2` / 桌面 `127.0.0.1`）。
Uri aylaVoiceRelayUri(String channelId, String token) {
  final String host = Platform.isAndroid ? '10.0.2.2' : '127.0.0.1';
  return Uri.parse(
    'ws://$host:8100/ws/voice/audio/?channel=${Uri.encodeComponent(channelId)}'
    '&token=${Uri.encodeComponent(token)}',
  );
}

/// 媒体连接状态（对齐 web `client.ts:22` 的 `LiveKitState`；名字沿用 PoC）。
enum RelayState { idle, connecting, connected, reconnecting, failed, closed }

/// 中继回调（对齐 web `wsRelayRoom.ts` 的 events / `client.ts:24–40` 的 `LiveKitEvents`）。
class RelayCallbacks {
  /// 状态变化。
  void Function(RelayState state)? onStateChange;

  /// 收到 joined（我的 slot + 成员名单）——成员状态恢复点。
  void Function(int mySlot, List<RelayMember> members)? onJoined;

  /// 远端加入。
  void Function(int slot, String identity)? onMemberJoined;

  /// 远端离开。
  void Function(int slot)? onMemberLeft;

  /// 远端说话状态（应用层事实，UI 指示）。
  void Function(int slot, bool on)? onSpeaking;

  /// 远端静音事实（媒体层；web `onTrackMuted`）。
  void Function(int slot, bool on)? onMuted;

  /// 收到一帧音频（[slot] 对方槽位，[opus] opus 包）。
  void Function(int slot, Uint8List opus)? onAudio;

  /// pong 回执（RTT 测量：now - ts）。
  void Function(int ts, Duration rtt)? onPong;

  /// 日志（诊断）。
  void Function(String line)? onLog;
}

/// 语音中继客户端（媒体面 owner；频道切换/销毁由页面会话层编排）。
class AylaRelayClient {
  AylaRelayClient(
    this._events, {
    required Future<String?> Function() freshToken,
    Uri Function(String channelId, String token)? urlBuilder,
  })  : _freshToken = freshToken,
        _urlBuilder = urlBuilder ?? aylaVoiceRelayUri;

  final RelayCallbacks _events;
  final Future<String?> Function() _freshToken;
  final Uri Function(String channelId, String token) _urlBuilder;

  WebSocketChannel? _ws;
  StreamSubscription<dynamic>? _sub;
  Timer? _handshakeTimer;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  bool _closed = false; // 用户主动断开：之后所有异步回调不再动作
  bool _handshaken = false;
  int _reconnectAttempts = 0;
  int _consecutiveFailures = 0;
  String? _channelId;
  String _token = '';
  RelayState _state = RelayState.idle;

  /// 麦克风状态（**媒体事实**；web `wsRelayRoom.ts:732` 新入房与重连后同步给服务端）。
  bool _micEnabled = false;

  /// 远端每 slot 的本地播放增益 0~1（web `setRemoteVolume`，按 user_id 生效；静音 = 0）。
  final Map<int, double> _slotGain = <int, double>{};

  /// slot → identity（joined / member_joined 维护；供音量按 user_id 生效）。
  final Map<int, String> _slotIdentity = <int, String>{};

  RelayState get state => _state;

  /// 握手是否完成（诊断用）。
  bool get debugHandshaken => _handshaken;

  /// 连续失败次数（诊断用）。
  int get debugFailures => _consecutiveFailures;

  /// 我的槽位（-1 = 尚未分配）。
  int mySlot = -1;

  /// 当前连接的频道 id。
  String? get channelId => _channelId;

  /// slot → identity 快照（音量映射用）。
  Map<int, String> get slotIdentity => Map<int, String>.unmodifiable(_slotIdentity);

  void _setState(RelayState s) {
    _state = s;
    _events.onStateChange?.call(s);
  }

  void _log(String line) => _events.onLog?.call('[relay] $line');

  /// 建立连接并等待 joined 握手（超时 [kHandshakeTimeoutMs]）。
  Future<void> connect(String channelId, String token) async {
    _closed = false;
    _channelId = channelId;
    _token = token;
    mySlot = -1;
    _slotIdentity.clear();
    _setState(RelayState.connecting);
    try {
      await _openOnce();
    } catch (error) {
      // web `wsRelayRoom.ts:722–726`：首次连接失败 ⇒ closed + failed，异常上抛给调用方
      // （由 join 流程决定回滚；**媒体断线 ≠ 离开频道**）。
      _closed = true;
      _setState(RelayState.failed);
      rethrow;
    }
    // 新入房：默认静音事实同步给服务端（join 流程随后按选项开麦）
    sendControl('mute', on: !_micEnabled);
  }

  Future<void> _openOnce() async {
    final Completer<void> completer = Completer<void>();
    final String? channelId = _channelId;
    if (channelId == null) {
      throw StateError('语音通道缺少 channel 参数');
    }
    final WebSocketChannel ws =
        IOWebSocketChannel.connect(_urlBuilder(channelId, _token));
    _ws = ws;
    _handshaken = false;

    _handshakeTimer?.cancel();
    _handshakeTimer = Timer(
      const Duration(milliseconds: kHandshakeTimeoutMs),
      () {
        if (completer.isCompleted) return;
        _log('握手超时（${kHandshakeTimeoutMs}ms）');
        _teardownSocket(ws);
        if (!completer.isCompleted) {
          completer.completeError(Exception('语音通道连接超时'));
        }
      },
    );

    _sub = ws.stream.listen(
      (dynamic data) {
        if (data is String) {
          _handleText(data, completer);
        } else if (data is List<int>) {
          // 握手期不该出现二进制帧：仅握手完成后处理
          if (_handshaken) _handleBinary(Uint8List.fromList(data));
        }
      },
      onError: (Object e) {
        if (_closed || completer.isCompleted) return;
        _log('连接错误: $e');
        _teardownSocket(ws);
        if (!completer.isCompleted) {
          completer.completeError(Exception('语音通道连接失败'));
        }
      },
      onDone: () {
        if (ws == _ws) _ws = null;
        if (_closed) return;
        if (!completer.isCompleted) {
          _handshakeTimer?.cancel();
          _teardownSocket(ws);
          completer.completeError(
            Exception('语音通道握手被拒（未认证、非频道成员或服务不可用）'),
          );
          return;
        }
        _handleSocketClosed();
      },
    );
    await completer.future;
  }

  void _handleText(String text, Completer<void> handshake) {
    Object? parsed;
    try {
      parsed = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (parsed is! Map<String, dynamic>) return;
    final RelayServerFrame frame = RelayServerFrame.fromJson(parsed);
    switch (frame.type) {
      case 'joined':
        if (!handshake.isCompleted) {
          _handshakeTimer?.cancel();
          _log('joined: mySlot=${frame.slot} members=${frame.members?.length ?? 0}');
          _handshaken = true;
          _consecutiveFailures = 0;
          _reconnectAttempts = 0;
          mySlot = frame.slot ?? -1;
          _slotIdentity
            ..clear()
            ..addEntries(
              <MapEntry<int, String>>[
                for (final RelayMember m in frame.members ?? const <RelayMember>[])
                  MapEntry<int, String>(m.slot, m.identity),
              ],
            );
          _setState(RelayState.connected);
          _startPing();
          _events.onJoined?.call(
            frame.slot ?? -1,
            frame.members ?? const <RelayMember>[],
          );
          handshake.complete();
        }
      case 'member_joined':
        _slotIdentity[frame.slot ?? -1] = frame.identity ?? '';
        _events.onMemberJoined?.call(frame.slot ?? -1, frame.identity ?? '');
      case 'member_left':
        _slotIdentity.remove(frame.slot ?? -1);
        _slotGain.remove(frame.slot ?? -1);
        _events.onMemberLeft?.call(frame.slot ?? -1);
      case 'speaking':
        _events.onSpeaking?.call(frame.slot ?? -1, frame.on ?? false);
      case 'muted':
        _events.onMuted?.call(frame.slot ?? -1, frame.on ?? false);
      case 'pong':
        final int? ts = frame.ts;
        if (ts != null) {
          final Duration rtt = Duration(
            milliseconds: DateTime.now().millisecondsSinceEpoch - ts,
          );
          _events.onPong?.call(ts, rtt);
        }
      case 'error':
        _log('服务端错误帧: ${frame.detail}');
      default:
        _log('未知控制帧: ${frame.type}');
    }
  }

  void _handleBinary(Uint8List bytes) {
    if (bytes.length < 2) return;
    final int slot = bytes[0];
    final Uint8List opus = Uint8List.fromList(bytes.sublist(1));
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
    final int delayMs =
        (kReconnectBaseMs * (1 << _reconnectAttempts)).clamp(0, kReconnectMaxMs);
    _reconnectAttempts += 1;
    _log('${delayMs}ms 后重连（第 $_reconnectAttempts 次）');
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      _reconnectTimer = null;
      unawaited(_attemptReconnect());
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
    // web `wsRelayRoom.ts:688–693`：连续失败达阈值先续期 token（token 过期是
    // 断连最常见的持久原因），拿到新值再连；续期失败沿用现值。
    if (_consecutiveFailures >= kRelayReconnectRefreshAfter) {
      final String? refreshed = await _freshToken();
      if (refreshed != null && refreshed.isNotEmpty) _token = refreshed;
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

  /// 发送文本控制帧（web `wsRelayRoom.ts` sendControl）。
  void sendControl(String type, {bool? on, int? ts}) {
    final WebSocketChannel? ws = _ws;
    if (ws == null) return;
    try {
      ws.sink.add(controlJson(type, on: on, ts: ts));
    } catch (_) {
      // sink 已关闭：连接关闭路径会统一走重连
    }
  }

  /// 发送一个 opus 包（仅 connected + 开麦时发送，静音不发帧）。
  void sendOpus(Uint8List opus) {
    final WebSocketChannel? ws = _ws;
    if (ws == null || !_handshaken || !_micEnabled) return;
    try {
      ws.sink.add(opus);
    } catch (_) {
      // 同上
    }
  }

  /// 麦克风状态（媒体事实，供 [sendOpus] 门控与重连后同步 mute）。
  void setMicEnabled(bool enabled) => _micEnabled = enabled;

  /// 远端成员本地播放增益 0~1（web `setRemoteVolume`：按 user_id 生效、不落库）。
  ///
  /// identity → slot 的映射来自 joined / member_joined（与 web 的
  /// `slotToIdentity` 同源）。
  void setRemoteVolume(String userId, double volume) {
    _slotGain.removeWhere((int slot, double _) => _slotIdentity[slot] == userId);
    for (final MapEntry<int, String> e in _slotIdentity.entries) {
      if (e.value == userId) _slotGain[e.key] = volume.clamp(0.0, 1.0);
    }
  }

  /// 某 slot 的播放增益（默认 1.0 = 原始）。
  double gainOfSlot(int slot) => _slotGain[slot] ?? 1.0;

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

  /// 主动断开（幂等）。**不代表离开频道**——REST `leave/` 才是成员事实。
  Future<void> disconnect() async {
    _closed = true;
    _handshakeTimer?.cancel();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stopPing();
    final WebSocketChannel? ws = _ws;
    _ws = null;
    if (ws != null) {
      _sub?.cancel();
      _sub = null;
      try {
        await ws.sink.close(1000, 'leave');
      } catch (_) {}
    }
    mySlot = -1;
    _slotIdentity.clear();
    _slotGain.clear();
    _setState(RelayState.closed);
  }
}
