/// PoC-A Echo 页面：连接语音中继 → 开麦 → 双端互听；实时显示连接状态、
/// 成员表、RTT（ping/pong 实测）、播放缓冲延迟（soloud 已喂-已播）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'audio_engine.dart';
import 'relay_client.dart';
import 'relay_protocol.dart';

/// 全局控制桥：PoC-A 联调自动化。
/// 通过 Dart VM Service 的 evaluate 远程调用（`PocControl.call('loginAndConnect')`），
/// 免 GUI 操作即可驱动两端 App 的连接/开麦/测试音与状态读取。
class PocControl {
  static _EchoPageState? _state;
  static String lastResult = '{"ok":false,"err":"no call yet"}';

  static void attach(Object s) => _state = s as _EchoPageState?;

  /// 同步启动动作（VM service evaluate 不能 await Future，fire-and-forget，
  /// 完成后结果写入 [lastResult]，轮询 [result] 读取）。
  static String fire(String action) {
    unawaited(_run(action));
    return '{"ok":true,"started":"$action"}';
  }

  static Future<void> _run(String action) async {
    lastResult = await call(action);
  }

  /// 同步读取最近一次动作结果（JSON 字符串）。
  static String result() => lastResult;

  /// 设置登录账号（PoC 双账号互听验证用：web 与 Flutter 端用不同 identity）。
  static void setAccount(String user, String pass) {
    final s = _state;
    if (s == null) return;
    s._userCtrl.text = user;
    s._passCtrl.text = pass;
  }

  /// 同步读取最近日志（VM service 联调用，取尾部 N 条）。
  static String logs([int n = 30]) {
    final s = _state;
    if (s == null) return '(no state)';
    final list = s._logs;
    final start = list.length > n ? list.length - n : 0;
    return list.sublist(start).join('\n');
  }

  /// 诊断：当前引擎/中继内部状态（VM service evaluate 用）。
  static String debugState() {
    final s = _state;
    if (s == null) return '{"ok":false,"err":"no state"}';
    final e = s._engine;
    final r = s._relay;
    return '{"relay":${r == null ? "null" : '{"handshaken":${r.debugHandshaken},"ws":${r.debugWsConnected},"failures":${r.debugFailures},"state":"${r.state.name}"}'},'
        '"engine":${e == null ? "null" : '{"libInit":${e.debugLibInit},"miniaudioReady":${e.debugMiniaudioReady},"encoder":${e.debugEncoderReady},"decoder":${e.debugDecoderReady}}'}}';
  }

  /// 返回 JSON 字符串（VM service evaluate 的 valueAsString 可读）。
  static Future<String> call(String action) async {
    final s = _state;
    if (s == null) return '{"ok":false,"err":"no state attached"}';
    try {
      switch (action) {
        case 'loginAndConnect':
          await s._loginAndConnect();
          break;
        case 'connect':
          await s._connect();
          break;
        case 'disconnect':
          await s._disconnect();
          break;
        case 'toggleMic':
          await s._toggleMic();
          break;
        case 'sendTestTone':
          await s._sendTestTone();
          break;
        default:
          return '{"ok":false,"err":"unknown action $action"}';
      }
      return '{"ok":true,"state":"${s._stateName}","slot":${s._mySlot},"mic":${s._micOn}}';
    } catch (e) {
      return '{"ok":false,"err":"$e"}';
    }
  }
}

class EchoPage extends StatefulWidget {
  const EchoPage({super.key});

  @override
  State<EchoPage> createState() => _EchoPageState();
}

class _EchoPageState extends State<EchoPage> {
  // Android 模拟器访问宿主机用 10.0.2.2；桌面端 127.0.0.1。
  late final String _defaultHost =
      Platform.isAndroid ? '10.0.2.2:8100' : '127.0.0.1:8100';
  late final TextEditingController _hostCtrl =
      TextEditingController(text: _defaultHost);
  final _channelCtrl = TextEditingController(text: '80');
  final _tokenCtrl = TextEditingController();
  final _userCtrl = TextEditingController(text: '123');
  final _passCtrl = TextEditingController(text: '12345678');
  bool _loggingIn = false;

  RelayClient? _relay;
  AudioEngine? _engine;

  RelayState _state = RelayState.idle;
  int _mySlot = -1;
  final List<RelayMember> _members = [];
  bool _micOn = false;
  bool _speaking = false;
  String _rttText = '—';
  String _delayText = '—';
  String _frameText = '—';

  final List<String> _logs = [];
  final ScrollController _scroll = ScrollController();

  void _log(String line) {
    _logs.add('${DateTime.now().toString().substring(11, 23)} $line');
    if (_logs.length > 200) _logs.removeAt(0);
    // 未 attach（如 initState 阶段）时不能调用 animateTo（ScrollController 断言崩溃）
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 100),
      curve: Curves.easeOut,
    );
  }

  /// 用用户名/密码登录后端拿 access token，填入 _tokenCtrl。
  Future<void> _loginAndConnect() async {
    if (_loggingIn) return;
    // setState 可能在 App 启动 build 未完成时抛"during build"异常；独立 try-catch
    // 吞掉（不卡 _loggingIn、不中断登录流程），否则该异常曾让 _loggingIn 卡 true
    // 导致后续登录全部直接 return（实测 2026-09-17）。
    try {
      setState(() => _loggingIn = true);
    } catch (_) {
      _log('登录状态标记失败（build 期 setState，忽略）');
    }
    final host = _hostCtrl.text.trim();
    final user = _userCtrl.text.trim();
    final pass = _passCtrl.text.trim();
    try {
      final client = HttpClient();
      try {
        final payload = jsonEncode({'username': user, 'password': pass});
        final bodyBytes = utf8.encode(payload);
        _log('登录请求 → http://$host/api/v1/auth/login/');
        final req = await client.postUrl(
          Uri.parse('http://$host/api/v1/auth/login/'),
        );
        req.headers.contentType = ContentType.json;
        // 踩坑（PoC-A 实测）：Ayla 后端（daphne ASGI）不解析 chunked
        // transfer-encoding 请求体——dart HttpClient 默认 chunked，
        // 必须显式 Content-Length（定长 body）后端才读到字段。
        req.contentLength = bodyBytes.length;
        req.add(bodyBytes);
        final res = await req.close();
        final body = await res.transform(utf8.decoder).join();
        _log('登录响应 HTTP ${res.statusCode}');
        if (res.statusCode == 200) {
          final j = jsonDecode(body) as Map<String, dynamic>;
          final access = j['access'] as String?;
          if (access == null) {
            _log('登录响应缺 access token');
          } else {
            _tokenCtrl.text = access;
            _log('登录成功（token ${access.length} 字符），自动连接…');
            await _connect();
          }
        } else {
          _log('登录失败 HTTP ${res.statusCode}: ${body.substring(0, body.length > 120 ? 120 : body.length)}');
        }
      } finally {
        client.close();
      }
    } catch (e) {
      _log('登录异常: $e');
    } finally {
      if (mounted) setState(() => _loggingIn = false);
    }
  }

  Future<void> _connect() async {
    if (_relay != null) return;
    final host = _hostCtrl.text.trim();
    final channel = _channelCtrl.text.trim();
    final token = _tokenCtrl.text.trim();
    if (host.isEmpty || channel.isEmpty) {
      _log('缺少 host 或 channel');
      return;
    }
    // 与 wsRelayRoom.ts voiceDirectWsUrl 同构：token 走 query
    final url = 'ws://$host/ws/voice/audio/?channel=$channel&token=$token';
    _log('连接 $url');

    final relayCallback = RelayCallbacks();
    relayCallback.onStateChange = (RelayState s) {
      setState(() => _state = s);
    };
    relayCallback.onJoined = (int slot, List<RelayMember> members) {
      setState(() {
        _mySlot = slot;
        _members
          ..clear()
          ..addAll(members);
        _log('joined: mySlot=$slot members=${members.length}');
      });
    };
    relayCallback.onMemberJoined = (int slot, String identity) {
      setState(() {
        _members.add(RelayMember(slot: slot, identity: identity));
        _log('member_joined: slot=$slot identity=$identity');
      });
    };
    relayCallback.onMemberLeft = (int slot) {
      setState(() {
        _members.removeWhere((m) => m.slot == slot);
        _log('member_left: slot=$slot');
      });
    };
    relayCallback.onAudio = (int slot, Uint8List opus) {
      // 双端延迟实测：接收端打时间戳（T2），与发送端 T1 相减得端到端延迟
      _log('[LAT] T2 ${DateTime.now().millisecondsSinceEpoch} 收到 slot=$slot 音频帧（${opus.length}B）');
      _engine?.onRemoteAudio(slot, opus);
    };
    relayCallback.onPong = (int ts, Duration rtt) {
      setState(() => _rttText = '${rtt.inMilliseconds} ms');
    };
    relayCallback.onLog = _log;
    final relay = RelayClient(url, relayCallback);

    final engineCallback = AudioEngineCallbacks();
    engineCallback.onSpeakingChanged = (bool v) {
      setState(() => _speaking = v);
    };
    engineCallback.onPlaybackDelay = (int ms) {
      setState(() => _delayText = '$ms ms');
    };
    engineCallback.onFrameCount = (int s, int r) {
      setState(() => _frameText = '$s 发 / $r 收');
    };
    engineCallback.onLog = _log;
    final engine = AudioEngine(relay, engineCallback);

    setState(() {
      _relay = relay;
      _engine = engine;
    });
    final ok = await engine.init();
    if (!ok) {
      _log('音频引擎初始化失败，无法继续');
      return;
    }
    try {
      await relay.connect();
      _log('连接成功');
    } catch (e) {
      _log('连接失败: $e');
    }
  }

  Future<void> _disconnect() async {
    final relay = _relay;
    final engine = _engine;
    setState(() {
      _relay = null;
      _engine = null;
      _micOn = false;
      _mySlot = -1;
      _members.clear();
    });
    if (engine != null) await engine.dispose();
    if (relay != null) await relay.disconnect();
    _state = RelayState.closed;
    _log('已断开');
  }

  Future<void> _toggleMic() async {
    final engine = _engine;
    if (engine == null) return;
    final target = !_micOn;
    setState(() => _micOn = target);
    await engine.setMicrophoneEnabled(target);
    _log(target ? '开麦' : '关麦');
  }

  Future<void> _sendTestTone() async {
    // T1 打点在 audio_engine.sendTestTone 发送循环前（避免本地播放初始化污染）
    await _engine?.sendTestTone();
  }

  @override
  void initState() {
    super.initState();
    PocControl.attach(this);
    _log('PoC-A Echo —— 服务端就绪后连接');
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _channelCtrl.dispose();
    _tokenCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _state == RelayState.connected;
    return Scaffold(
      appBar: AppBar(title: const Text('PoC-A 音频 Echo')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _hostCtrl,
            decoration: const InputDecoration(labelText: '中继 host:port'),
            enabled: !connected,
          ),
          TextField(
            controller: _channelCtrl,
            decoration: const InputDecoration(labelText: '频道 id'),
            enabled: !connected,
          ),
          TextField(
            controller: _tokenCtrl,
            decoration: const InputDecoration(labelText: 'access token'),
            obscureText: true,
            enabled: !connected,
          ),
          TextField(
            controller: _userCtrl,
            decoration: const InputDecoration(labelText: '用户名（PoC 联调用）'),
            enabled: !connected,
          ),
          TextField(
            controller: _passCtrl,
            decoration: const InputDecoration(labelText: '密码'),
            obscureText: true,
            enabled: !connected,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed:
                    connected || _loggingIn ? null : _loginAndConnect,
                child: Text(_loggingIn ? '登录中…' : '登录并连接'),
              ),
              FilledButton(
                onPressed: connected ? null : _connect,
                child: const Text('连接'),
              ),
              OutlinedButton(
                onPressed: _state == RelayState.idle ||
                        _state == RelayState.closed
                    ? null
                    : _disconnect,
                child: const Text('断开'),
              ),
              FilledButton.tonal(
                onPressed: connected ? _toggleMic : null,
                child: Text(_micOn ? '关麦' : '开麦'),
              ),
              FilledButton.tonal(
                onPressed: connected ? _sendTestTone : null,
                child: const Text('测试音'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('状态: $_stateName  |  我的 slot: $_mySlot'),
                  Text('成员: ${_members.map((m) => '${m.slot}:${m.identity}').join(' ')}'),
                  Text('说话: ${_speaking ? '🔴' : '⚪'}  |  RTT: $_rttText'),
                  Text('播放缓冲延迟: $_delayText  |  帧: $_frameText'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            height: 260,
            decoration: BoxDecoration(
              color: const Color(0xFF0D1117),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListView.builder(
              controller: _scroll,
              itemCount: _logs.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                child: Text(
                  _logs[i],
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String get _stateName => switch (_state) {
        RelayState.idle => 'idle',
        RelayState.connecting => 'connecting',
        RelayState.connected => 'connected',
        RelayState.reconnecting => 'reconnecting',
        RelayState.failed => 'failed',
        RelayState.closed => 'closed',
      };
}
