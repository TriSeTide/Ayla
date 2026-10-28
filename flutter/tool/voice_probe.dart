/// 本地调试入口：**不经 UI**，直接登录 + 加入语音频道 + 开麦。
///
/// 为什么需要：真机音频问题必须两端同时在线才能复现（手机说话电脑听不到、
/// 关麦/静音状态、电平灵敏度）。手点 UI 既慢又不可重复，这里把「登录 → join →
/// connectWithMedia → 开麦」写成固定流程，只打印诊断信息。
///
/// 用法（Windows 与 Android 各起一份，账号要**不同**，否则同一 identity 会互踢）：
/// ```
/// flutter run -d windows -t tool/voice_probe.dart \
///   --dart-define=VOICE_USER=test --dart-define=VOICE_PASS=12345678 \
///   --dart-define=VOICE_CHANNEL=1 \
///   --dart-define=AYLA_API_BASE=https://s.ayla.trise.top:26211
/// ```
/// 该文件在 tool/ 下，不属于 app 产物，仅调试用。
library;

// ignore_for_file: experimental_member_use

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:ayla_flutter/audio/voice_state.dart' show RelayState;
import 'package:ayla_flutter/audio/livekit_room_adapter.dart' show aylaInstallLiveKitRoomBuilder, AylaLiveKitSdkRoom;
import 'package:ayla_flutter/audio/livekit_voice_backend.dart';
import 'package:ayla_flutter/audio/voice_media_config.dart' show AylaVoiceLiveKitConfig, AylaVoiceMediaConfig;
import 'package:ayla_flutter/core/api/auth_api.dart';
import 'package:ayla_flutter/core/api/voice_api.dart';
import 'package:ayla_flutter/core/net/dio_client.dart';
// ignore: depend_on_referenced_packages
import 'package:logging/logging.dart' show hierarchicalLoggingEnabled;
// ignore: depend_on_referenced_packages
import 'package:flutter_webrtc/flutter_webrtc.dart' show Helper;
import 'package:livekit_client/livekit_client.dart'
    show
        AudioManager,
        AudioSessionOptions,
        Hardware,
        LoggerLevel,
        MediaDevice,
        logger,
        setLoggingLevel;

class _MemTokenStore implements AuthTokenStore {
  String? _access;
  String? _refresh;
  @override
  String? get accessToken => _access;
  @override
  String? get refreshToken => _refresh;
  @override
  void setTokens(String access, String? refresh) {
    _access = access;
    _refresh = refresh;
  }

  @override
  void clear() {
    _access = null;
    _refresh = null;
  }
}

const String _kUser = String.fromEnvironment('VOICE_USER', defaultValue: 'test');
const String _kPass = String.fromEnvironment('VOICE_PASS', defaultValue: '12345678');
const String _kChannel = String.fromEnvironment('VOICE_CHANNEL', defaultValue: '1');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _ProbeApp());
}

class _ProbeApp extends StatefulWidget {
  const _ProbeApp();
  @override
  State<_ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<_ProbeApp> {
  final List<String> _lines = <String>[];
  final _MemTokenStore _store = _MemTokenStore();
  AylaLiveKitVoiceBackend? _backend;
  bool _micOn = false;
  bool _speakerOff = false;
  String? _remoteIdentity;
  final Map<String, double> _levels = <String, double>{};

  void _log(String line) {
    final String stamped = '${DateTime.now().toIso8601String().substring(11, 23)} $line';
    debugPrint('[probe] $stamped');
    if (!mounted) return;
    setState(() {
      if (_lines.length > 300) _lines.removeAt(0);
      _lines.add(stamped);
    });
  }

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<TokenPair> _loginWithRetry() async {
    Object? last;
    for (int attempt = 1; attempt <= 4; attempt++) {
      try {
        return await AuthApi.login(_kUser, _kPass);
      } catch (error) {
        last = error;
        _log('login 第 $attempt 次失败: $error');
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    throw last ?? StateError('login failed');
  }

  Future<void> _run() async {
    try {
      if (const bool.fromEnvironment('VOICE_DEVICE_ONLY')) {
        // 只枚举音频设备（不需要连房间）：确认 flutter_webrtc 在 Windows 上
        // 给出的 label / deviceId 形态，用于「跟随系统默认设备」。
        hierarchicalLoggingEnabled = true;
        try {
          final List<MediaDevice> outs = await Hardware.instance.audioOutputs();
          _log('输出设备数量=${outs.length}');
          for (int i = 0; i < outs.length; i++) {
            final MediaDevice d = outs[i];
            _log('OUT[$i] id=${d.deviceId} label=${d.label}');
          }
          final List<MediaDevice> ins = await Hardware.instance.audioInputs();
          _log('输入设备数量=${ins.length}');
          for (int i = 0; i < ins.length; i++) {
            _log('IN[$i] id=${ins[i].deviceId} label=${ins[i].label}');
          }
        } catch (e) {
          _log('枚举失败: $e');
        }
        return;
      }

      if (const bool.fromEnvironment('VOICE_MODE_ONLY')) {
        // 只验证「音频会话是否真的把 Android 切成媒体播放」：不连 LiveKit。
        hierarchicalLoggingEnabled = true;
        final AudioManager mgr = AudioManager.instance;
        await mgr.setAudioSessionOptions(const AudioSessionOptions.mediaPlayback());
        if (mgr.canSwitchSpeakerphone) {
          await mgr.setSpeakerOutputPreferred(true, force: true);
        }
        _log('MODE_ONLY: mediaPlayback 已应用 canSwitch=${mgr.canSwitchSpeakerphone} '
            'speakerPreferred=${mgr.isSpeakerOutputPreferred}');
        return;
      }
      DioClient.instance.init(
        tokenStore: _store,
        onSessionExpired: () => _log('session expired'),
      );
      // 打开 LiveKit SDK 自己的日志：它会打印真实连接 URL 与 socket 错误
      hierarchicalLoggingEnabled = true;
      // 默认只记 WARNING：全量日志每秒上千行会把 UI 线程刷死，
      // 反过来制造 ICE 超时（实测教训）。需要时改 kALL。
      setLoggingLevel(LoggerLevel.kWARNING);
      logger.onRecord.listen((record) {
        _log('lksdk[${record.level.name}] ${record.message}');
      });
      _log('login user=$_kUser ...');
      // 本机网络经 TUN，偶发 connectionTimeout（实测 3 次里 1~2 次），重试 3 次。
      TokenPair pair = await _loginWithRetry();
      _store.setTokens(pair.access, pair.refresh);
      _log('login ok accessLen=${pair.access.length}');


      final AylaVoiceJoinResult join = await AylaVoiceApi.joinVoiceChannel(_kChannel);
      final AylaVoiceMediaConfig? media = join.media;
      _log('join ok channel=$_kChannel media=${media ?? 'null'}');


      // 直接用 LiveKit 后端：AylaVoiceMedia 会把异常吞成「降级」并只留一句 reason，
      // 这里需要**完整异常类型 + 消息 + 堆栈**来定位连接失败原因。
      aylaInstallLiveKitRoomBuilder();
      final AylaLiveKitVoiceBackend vm = AylaLiveKitVoiceBackend(
        onStateChange: (RelayState s) => _log('STATE=$s'),
        onTrackMuted: (int slot, bool muted) => _log('trackMuted slot=$slot muted=$muted'),
        onLocalAudioLevel: (double l) {
          if (l > 0.02) _log('LOCAL level=${l.toStringAsFixed(2)}');
        },
        onRemoteAudioLevels: (Map<String, double> m) {
          _levels
            ..clear()
            ..addAll(m);
          final Iterable<MapEntry<String, double>> nz =
              m.entries.where((MapEntry<String, double> e) => e.value > 0.02);
          if (nz.isNotEmpty) {
            if (mounted) setState(() {});
            _log('REMOTE levels=${nz.map((MapEntry<String, double> e) => '${e.key}:${e.value.toStringAsFixed(2)}').join(',')}');
          }
        },
        onLog: (String l) => _log('backend: $l'),
        roomFactory: () async => AylaLiveKitSdkRoom(),
      );
      _backend = vm;
      final AylaVoiceLiveKitConfig lk = media!.livekit!;
      // 判别实验：强制把输出切到指定 label 的设备，验证 selectAudioOutput 是否真的生效。
      const String outLabel = String.fromEnvironment('VOICE_OUT_LABEL');
      if (outLabel.isNotEmpty) {
        final List<MediaDevice> outs = await Hardware.instance.audioOutputs();
        _log('输出设备共 ' + outs.length.toString() + ' 个');
        for (final MediaDevice d in outs) {
          _log('  OUT id=' + d.deviceId + ' label=' + d.label);
        }
        MediaDevice? target;
        for (final MediaDevice d in outs) {
          if (d.label.contains(outLabel)) { target = d; break; }
        }
        if (target == null) {
          _log('未找到 label 含 [' + outLabel + '] 的设备');
        } else {
          _log('准备切到 [' + target.label + '] id=' + target.deviceId);
          try {
            await Hardware.instance.selectAudioOutput(target);
            _log('selectAudioOutput 返回成功');
          } catch (e) {
            _log('selectAudioOutput 抛异常: ' + e.toString());
          }
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      _log('尝试 LiveKit url=${lk.url} identity=${lk.identity}');
      try {
        await vm.connect(lk.url, lk.token);
        _log('LiveKit connect OK');
      } catch (connectError, connectStack) {
        _log('LiveKit connect FAILED type=${connectError.runtimeType}');
        _log('LiveKit connect msg=$connectError');
        debugPrint('[probe] connect stack: $connectStack');
        rethrow;
      }
      await vm.startAudio();
      _log('startAudio done');
      // 排查用：`--dart-define=VOICE_FORCE_OUT=<label 片段>` 在连接后强制切到指定输出设备。
      // 目的：判定 selectAudioOutput 在这套 libwebrtc 上到底能不能迁移**运行中**的播放流
      // （生产路径跟随系统默认多媒体设备；这里只做对照实验，不进生产）。
      const String forceOut = String.fromEnvironment('VOICE_FORCE_OUT');
      if (forceOut.isNotEmpty) {
        final List<MediaDevice> outs = await Hardware.instance.audioOutputs();
        MediaDevice? target;
        for (final MediaDevice d in outs) {
          if (d.label.contains(forceOut)) {
            target = d;
            break;
          }
        }
        if (target == null) {
          _log('FORCE_OUT 未找到含 [$forceOut] 的设备');
        } else {
          final Map<String, dynamic> receipt =
              await Helper.selectAudioOutputDetailed(target.deviceId);
          _log('FORCE_OUT -> ${target.label} receipt=$receipt');
        }
      }
      // 只枚举、**不切换**：生产路径的输出端点选择由适配层 `_alignAudioRoute`
      // 负责（它会在 connect 后 / 发布后 / 首次订阅后各校一次并打内核回执）。
      // 这里曾经做过一次「强制切到 outs.first」的实验，会把适配层的对齐结果覆盖掉，
      // 于是「日志说切了、声音没动」永远无法复现 —— 已移除（2026-10-28）。
      try {
        final List<MediaDevice> outs = await Hardware.instance.audioOutputs();
        for (final MediaDevice d in outs) {
          _log('输出设备: id=${d.deviceId} label=${d.label}');
        }
      } catch (e) {
        _log('输出设备枚举失败: $e');
      }
      await vm.setMicrophoneEnabled(true);
      _micOn = true;
      _log('mic ON');
    } catch (error, stack) {
      _log('FAILED: $error');
      debugPrint('[probe] stack: $stack');
    }
  }

  Future<void> _toggleMic() async {
    final AylaLiveKitVoiceBackend? vm = _backend;
    if (vm == null) return;
    final bool next = !_micOn;
    await vm.setMicrophoneEnabled(next);
    setState(() => _micOn = next);
    _log('mic ${next ? 'ON' : 'OFF'}');
  }

  void _toggleRemoteSpeaker() {
    final AylaLiveKitVoiceBackend? vm = _backend;
    final String? id = _remoteIdentity;
    if (vm == null || id == null) return;
    setState(() => _speakerOff = !_speakerOff);
    vm.setRemoteVolume(id, _speakerOff ? 0 : 1);
    _log('remote $id speaker ${_speakerOff ? 'OFF' : 'ON'}');
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: Text('voice probe · $_kUser')),
        body: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  FilledButton(
                    onPressed: _toggleMic,
                    child: Text(_micOn ? '关麦' : '开麦'),
                  ),
                  FilledButton(
                    onPressed: _toggleRemoteSpeaker,
                    child: Text(_speakerOff ? '恢复对方声音' : '关掉对方声音'),
                  ),
                  OutlinedButton(
                    onPressed: () {
                      final Iterable<String> others = _levels.keys
                          .where((String k) => k != _remoteIdentity)
                          .toList();
                      if (others.isEmpty) {
                        _log('还没有远端成员（等另一端进房）');
                        return;
                      }
                      setState(() => _remoteIdentity = others.first);
                      _log('选中远端 $_remoteIdentity');
                    },
                    child: Text(_remoteIdentity == null
                        ? '选中远端'
                        : '远端=${_remoteIdentity!.substring(0, 6)}'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: _lines.length,
                itemBuilder: (BuildContext ctx, int i) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  child: Text(
                    _lines[_lines.length - 1 - i],
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
