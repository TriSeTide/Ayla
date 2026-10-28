/// LiveKit SDK 胶水层 —— [AylaVoiceRoomLike] 的真实实现（livekit_client 2.13.2）。
///
/// 对应 web `livekitRoom.ts` 的角色：把 SDK 的 Room / 轨道 / 事件映射成后端要的最小面。
/// 本文件**只做映射**，状态机、电平衰减、降级决策都在 `livekit_voice_backend.dart`
/// （所以那部分可以纯单测，不需要真服务器；本文件用源码级契约锁覆盖三条硬约束）。
///
/// ## 三条硬约束在本文件的落点
/// 1. **identity 裸 user_id**：直接透传 `participant.identity`，**从不加前缀/改写**
///    （后端签发 token 时 identity = `str(user.pk)`，见 `voice_media_config.dart`）；
/// 2. **关麦真正释放设备**：`unpublishMicrophone()` = `removePublishedTrack()`（SDK 在
///    `stopLocalTrackOnUnpublish: true` 下停轨）+ **显式** `track.stop()` +
///    `track.mediaStreamTrack.stop()`。三件都要有：前者是协议侧退订，后两者是
///    **确定性设备释放**（隐私：熄灭系统麦克风指示灯）——不赌 SDK 实现细节；
///    ⚠️ **不用** `setMicrophoneEnabled(false)`：它默认只 mute，设备仍被占用；
/// 3. **绝不用 isSpeaking / activeSpeakers 门控发布**：本文件不注册
///    `ActiveSpeakersChangedEvent`、不读 `isSpeaking` 决定发布/发包。
///    `publishDefaults.dtx = false` 是同一约束的一半：DTX 会在安静段**完全停发**，
///    听感正是 doc 39 的「有声音才连上去播放，声音小点了就跟断了一样」。
///
/// ## 电平（Flutter 无 WebAudio AnalyserNode 的等价物）
/// - 本地：`LocalAudioTrack.getSenderStats().audioSourceStats.audioLevel`（media-source
///   统计，200ms 刷新；失败则回退 `localParticipant.audioLevel`）；
/// - 远端：`RemoteAudioTrack.getReceiverStats()` 的 `totalAudioEnergy` /
///   `totalSamplesDuration` **增量**算 RMS（200ms 一拍），与 web 的 AnalyserNode
///   同为「收包侧实测」；平台不给这两个字段时回退 `RemoteParticipant.audioLevel`。
///   ⚠️ 之前直接用 `Participant.audioLevel`（服务端 speaker 电平，~1.5s 粒度）——
///   用户实报「音频条跳动不灵敏」就是它造成的，2026-10-28 改为收包侧统计。
///
/// ## 音频会话（2026-10-28）
/// 用 `AudioManager` 显式声明**媒体播放**语义（`AudioSessionOptions.mediaPlayback`），
/// 不再是通话语义：媒体音量档 + 外放路由。采集侧仍显式开 AEC/NS/AGC
/// （[`_captureOptions`]），离开通话模式不会失去回声消除（libwebrtc 软件 AEC）。
library;

// livekit_client 2.13.2 把整个音频会话 API（AudioManager / AudioSessionOptions /
// AndroidAudioSessionConfiguration）标为 `@experimental`，但我们**需要**它来把手机端
// 从「通话语义」改成「媒体播放语义」（用户 2026-10-28 明确要求）。
// 该 API 一旦在升级后变动，analyzer 会先报 undefined_* —— 不会静默降级。
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
// ⚠️ `Helper`（含 vendor 补丁的 selectAudioOutputDetailed）只由 flutter_webrtc 导出，
// livekit_client 没有 re-export 它 —— 所以这里必须显式 import 那个包。
import 'package:flutter_webrtc/flutter_webrtc.dart' show Helper;
import 'package:livekit_client/livekit_client.dart' as lk;

import '../core/media/android_audio_route.dart';
import '../core/media/windows_audio_device.dart';

import 'livekit_voice_backend.dart';

/// 注册生产房间工厂（由 `AylaVoiceMedia` 在构造时调用一次；幂等）。
///
/// 顺带做一件**必须发生在任何 Room 连接之前**的事：把 Android 的 WebRTC 初始化参数
/// 指定为**媒体播放**语义（见 [ensureAndroidMediaWebRtcInit]）。
void aylaInstallLiveKitRoomBuilder() {
  AylaLiveKitRoomBuilder.install(() async => AylaLiveKitSdkRoom());
  unawaited(ensureAndroidMediaWebRtcInit());
}

/// 音频会话选项：**媒体播放**语义（不是通话）。
///
/// 用户实报（2026-10-28）：手机端听感/音量档是「通话」形态，要求改成媒体播放。
/// `AudioSessionOptions.mediaPlayback` = Android audioMode normal + usage media +
/// streamType music（媒体音量档，非通话音量档），iOS 对应 playback 类目。
/// 采集侧仍显式开 AEC/NS/AGC（见 `AylaLiveKitSdkRoom._captureOptions`），
/// 离开通话模式不会失去回声消除（libwebrtc 软件 AEC）。
const lk.AudioSessionOptions kAylaMediaAudioSessionOptions =
    lk.AudioSessionOptions.mediaPlayback();

/// 是否已发起 Android WebRTC 初始化（只发一次：ADM 初始化是**一次性**的）。
bool _androidMediaInitStarted = false;

/// 初始化去重 future（并发调用合流成一次真正的 `WebRTC.initialize`）。
final Future<void> _androidMediaInitLocked = () async {
  await lk.LiveKitClient.initialize(
    initialAudioSessionOptions: kAylaMediaAudioSessionOptions,
  );
  debugPrint('[lk] Android WebRTC 已按媒体播放语义初始化: playout usage=USAGE_MEDIA');
}();

/// 让 Android 的 WebRTC **音频设备模块（ADM）** 以媒体播放语义建轨（幂等，只生效一次）。
///
/// ## 为什么必须在这里、而不是运行期（2026-10-29 实测定案）
/// 用户实报「手机端是通话音量（音量键调的是通话音量）」。逐层验证结论：
/// · `AudioManager.setAudioSessionOptions(mediaPlayback)` 只改**会话**（mode/焦点/外放），
///   改不了**已经建好的播放轨**；
/// · WebRTC 的播放 AudioTrack 属性在 ADM 初始化时就固定了：flutter_webrtc 的
///   MethodCallHandlerImpl 只有拿到 `androidAudioConfiguration` 才会把 usage/content
///   传给 JavaAudioDeviceModule，否则用默认的 USAGE_VOICE_COMMUNICATION；
/// · 实测证据（模拟器 dumpsys audio）：修之前播放轨一直是
///   usage=USAGE_VOICE_COMMUNICATION content=CONTENT_TYPE_SPEECH sampleRate=8000，
///   按音量键改的是 STREAM_VOICE_CALL 而不是 STREAM_MUSIC；
/// · 该参数只在 WebRTC.initialize 时生效一次，而 livekit_client 为此提供了
///   LiveKitClient.initialize 的 initialAudioSessionOptions 入口（其注释明说
///   "before WebRTC creates its audio device module"）。
///
/// 所以：**在构造第一个 Room 之前**初始化一次。非 Android 平台直接返回（桌面端的
/// 音频设备由系统路由决定，见 [_alignAudioRoute]）。
Future<void> ensureAndroidMediaWebRtcInit() async {
  if (_androidMediaInitStarted) return;
  if (!AylaAndroidAudioRoute.supported) return;
  _androidMediaInitStarted = true;
  try {
    await _androidMediaInitLocked;
  } catch (error) {
    // 初始化失败不能阻断语音（退回默认通话语义 + 原生路由兜底），但必须留痕。
    debugPrint('[lk] Android WebRTC 媒体初始化失败（退回通话语义）: $error');
  }
}

/// LiveKit SDK 房间实现（一个实例 = 一次连接生命周期）。
class AylaLiveKitSdkRoom implements AylaVoiceRoomLike {
  AylaLiveKitSdkRoom() {
    _room = lk.Room(roomOptions: _roomOptions);
    _bindEvents();
  }

  /// 采集参数：与中继版 `getUserMedia` / 现有 RecordConfig 逐项一致
  /// （回声消除 / 降噪 / 自动增益；web `MIC_CAPTURE_OPTIONS`
  /// `livekitRoom.ts:49-54`）。
  static const lk.AudioCaptureOptions _captureOptions =
      lk.AudioCaptureOptions(
    echoCancellation: true,
    noiseSuppression: true,
    autoGainControl: true,
  );

  /// 发布参数：32 kbps（与中继版 Opus 编码参数逐字节一致）+ 关 DTX + 开 RED。
  static const lk.AudioPublishOptions _publishOptions = lk.AudioPublishOptions(
    dtx: false,
    red: true,
    encoding: lk.AudioEncoding(maxBitrate: 32000),
  );

  static const lk.RoomOptions _roomOptions = lk.RoomOptions(
    // 纯音频场景：视频相关特性一律关闭（与 web `livekitRoom.ts:158-160` 一致）。
    adaptiveStream: false,
    dynacast: false,
    // 退订即停轨（多一层保险；显式 stop 仍在 `unpublishMicrophone` 里做）。
    stopLocalTrackOnUnpublish: true,
    defaultAudioCaptureOptions: _captureOptions,
    defaultAudioPublishOptions: _publishOptions,
  );

  /// 音频会话：**媒体播放**语义（不是通话）。见顶层 [kAylaMediaAudioSessionOptions]。
  static const lk.AudioSessionOptions _audioSessionOptions =
      kAylaMediaAudioSessionOptions;

  /// 应用音频会话（幂等）。桌面平台没有音频会话概念 ⇒ 异常按"不支持"处理并留日志。
  Future<void> _applyAudioSession() async {
    try {
      final lk.AudioManager manager = lk.AudioManager.instance;
      await manager.setAudioSessionOptions(_audioSessionOptions);
      final bool canSwitch = manager.canSwitchSpeakerphone;
      if (canSwitch) {
        // 移动端媒体播放语义：优先外放（不是听筒）。
        await manager.setSpeakerOutputPreferred(true, force: true);
      }
      if (kDebugMode) {
        debugPrint('[lk] 音频会话已设为 mediaPlayback canSwitchSpeaker=$canSwitch '
            'speakerPreferred=${manager.isSpeakerOutputPreferred}');
      }
    } catch (error) {
      debugPrint('[livekit] 音频会话设置失败（平台可能不支持）：$error');
    }
  }

  late final lk.Room _room;
  final StreamController<AylaRoomEvent> _events =
      StreamController<AylaRoomEvent>.broadcast();

  /// 事件取消函数（`createListener().on(...)` 的返回值；不显式命名 SDK 类型，
  /// 只用其结构签名 —— 避免依赖 SDK 的内部导出面）。
  final List<Future<void> Function()> _cancels = <Future<void> Function()>[];
  Timer? _levelTimer;
  bool _levelBusy = false;
  bool _disposed = false;

  lk.LocalAudioTrack? _micTrack;
  lk.LocalTrackPublication<lk.LocalAudioTrack>? _micPublication;

  /// 本地电平实测值（[getSenderStats] 200ms 刷新；null = 尚无实测）。
  double? _measuredLocalLevel;

  /// 远端电平实测值（收包侧统计；缺项时回退 Participant.audioLevel）。
  final Map<String, double> _measuredRemoteLevels = <String, double>{};

  /// 远端 totalAudioEnergy / totalSamplesDuration 的上一拍基线（算增量用）。
  final Map<String, num> _remotePrevEnergy = <String, num>{};
  final Map<String, num> _remotePrevDuration = <String, num>{};

  Timer? _remoteLevelTimer;
  bool _remoteLevelBusy = false;

  /// 诊断统计定时器（仅 debug 构建）：每 3s 打印本地发送侧 + 远端接收侧 RTP 统计。
  Timer? _debugStatsTimer;

  /* ---------------- AylaVoiceRoomLike ---------------- */

  @override
  Stream<AylaRoomEvent> get events => _events.stream;

  @override
  Future<void> connect(String url, String token) async {
    // 音频会话必须先于连接生效：SDK 在本机建 PeerConnection 时就绑定 AudioAttributes。
    await _applyAudioSession();
    // Windows 输出端点：connect **前后各一次**，两次都必须有。
    //
    // · connect 前那次：建立「用户意图」基线（也是 macOS/Android 上唯一有效的时机）；
    // · connect 后那次（force）：**真正生效的那次**。实测 ADM 的 Windows playout
    //   通道要等首次 startPlayout 才打开，而它按当时的系统「默认通信设备」初始化，
    //   会把 connect 前设好的设备覆盖掉。所以只做前一次 = 声音留在通信设备上，
    //   正是用户实报的「音频条在跳、耳机没声音」。
    // 排障开关（默认关闭）：跳过 Windows 输出端点切换，用于 A/B 定位「切换是否
    // 影响采集/播放」。生产不传该 define。
    if (!const bool.fromEnvironment('AYLA_SKIP_ROUTE_ALIGN')) {
      await _alignAudioRoute();
    }
    await _room.connect(url, token);
    if (!const bool.fromEnvironment('AYLA_SKIP_ROUTE_ALIGN')) {
      await _alignAudioRoute(force: true);
    }
    _alignAudioRouteAfterConnect();
    // Android：连接后把系统音频会话压回「媒体」语义。SDK 在连接过程中会重施
    // 通话策略（MODE_IN_COMMUNICATION），必须在这之后再压一次。
    await _applyAndroidMediaRoute('connect');
    _startLevelTimer();
    _startRemoteLevelTimer();
    _startDebugStatsTimer();
    if (kDebugMode) {
      debugPrint('[lk] CONNECTED url=$url identity=${_room.localParticipant?.identity}');
    }
  }

  @override
  Future<void> disconnect() async {
    if (_disposed) return;
    _stopLevelTimer();
    _stopRemoteLevelTimer();
    _stopDebugStatsTimer();
    _routeAlignedForPlayback = false;
    await _releaseMicrophone();
    await _cancelListeners();
    try {
      await _room.disconnect();
    } catch (_) {
      // 已断开：断开是幂等语义，不向上抛
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await disconnect();
    _disposed = true;
    try {
      await _room.dispose();
    } catch (_) {
      // 已释放
    }
    try {
      await _events.close();
    } catch (_) {
      // 已关闭
    }
  }

  /// 开麦：采集 + 发布。
  ///
  /// ⚠️ 发布之后 SDK 持续发包（`dtx: false`）——**不做 speaking 门控**（硬约束 3）。
  @override
  Future<void> publishMicrophone() async {
    if (_disposed) throw StateError('LiveKit 已断开');
    if (_micTrack != null) return;
    final lk.LocalParticipant? local = _room.localParticipant;
    if (local == null) throw StateError('LiveKit 未连接');

    // Windows：显式选定**系统默认采集设备**再建轨。
    // 不指定时 flutter_webrtc 会硬选 ADM 枚举下标 0 —— 那可能是虚拟回环设备
    // （本机是「内部 AUX 输入 (Steam Streaming Speakers)」，永远静音），
    // 于是开麦后发出去的全是静音。见 third_party/flutter_webrtc 的采集补丁。
    await _alignAudioInput();
    final lk.LocalAudioTrack track =
        await lk.LocalAudioTrack.create(_captureOptions);
    try {
      // 发布可能因为「连接正在重连 / 重协商」而失败（实测 Windows 上出现过
      // TrackPublishException: Failed to publish track，随后整场都没有麦克风）。
      // 重试一次、间隔 800ms —— 这正好跨过 LiveKit 的一次 resume。
      lk.LocalTrackPublication<lk.LocalAudioTrack>? publication;
      for (int attempt = 0; attempt < 2; attempt++) {
        try {
          publication = await local.publishAudioTrack(track,
              publishOptions: _publishOptions);
          break;
        } catch (error) {
          if (attempt == 1) rethrow;
          debugPrint('[lk] 发布麦克风失败，800ms 后重试: $error');
          await Future<void>.delayed(const Duration(milliseconds: 800));
        }
      }
      if (publication == null) {
        throw StateError('麦克风发布失败');
      }
      _micTrack = track;
      _micPublication = publication;
      _measuredLocalLevel = null;
      _startLevelTimer();
      // 发布之后**不强制**重切（force=false）：只在端点真的变了时对齐。
      // 原因：强制切会触发 libwebrtc 的 Stop/Init/Start playout，每开一次麦就静音一下；
      // 真正必须强制的时机是「connect 完成后」与「首次有远端音频在播后」，见那两处。
      await _alignAudioRoute();
      // 开麦后 SDK 可能重建音频会话（重新绑定 AudioAttributes）⇒ 再压一次。
      await _applyAndroidMediaRoute('publish');
      if (kDebugMode) {
        debugPrint('[lk] 麦克风已发布 sid=${publication.sid} '
            'trackSid=${track.sid}');
      }
    } catch (error) {
      // 发布失败必须把已采集的设备放掉（不留下占用麦克风的孤儿轨）
      try {
        await track.stop();
      } catch (_) {
        // 已停止
      }
      rethrow;
    }
  }

  /// 关麦：**完全释放麦克风设备**（隐私：熄灭硬件指示灯）。
  ///
  /// 三件确定性动作（对齐 web `wsRelayRoom.ts:802-807` 的隐私注释）：
  /// 1. `removePublishedTrack` —— 协议侧退订（`stopLocalTrackOnUnpublish` 会顺带停轨）；
  /// 2. `track.stop()` —— 停 SDK 轨道（非 web 平台内部会 `mediaStreamTrack.stop()`）；
  /// 3. `track.mediaStreamTrack.stop()` —— 停**采集设备原始轨**，不赌第 1/2 步的实现细节。
  @override
  Future<void> unpublishMicrophone() async {
    final lk.LocalAudioTrack? track = _micTrack;
    final lk.LocalTrackPublication<lk.LocalAudioTrack>? publication =
        _micPublication;
    if (kDebugMode && _micPublication != null) {
      debugPrint('[lk] 关麦（释放设备）sid=${_micPublication?.sid}');
    }
    _micTrack = null;
    _micPublication = null;
    _measuredLocalLevel = null;
    _stopLevelTimer();

    final lk.LocalParticipant? local = _room.localParticipant;
    if (publication != null && local != null) {
      try {
        await local.removePublishedTrack(publication.sid);
      } catch (_) {
        // 已断开/已退订：继续走设备释放
      }
    }
    try {
      await track?.stop();
    } catch (_) {
      // 已停止
    }
    try {
      await track?.mediaStreamTrack.stop();
    } catch (_) {
      // 已停止
    }
  }

  @override
  bool get microphoneEnabled => _micTrack != null;

  @override
  List<String> get remoteIdentities =>
      _room.remoteParticipants.keys.toList(growable: false);

  @override
  double get localAudioLevel {
    if (_micTrack == null) return 0;
    final double? measured = _measuredLocalLevel;
    if (measured != null) return measured;
    final double raw = _room.localParticipant?.audioLevel ?? 0;
    return raw.isFinite ? math.max(0.0, math.min(1.0, raw)) : 0;
  }

  @override
  double remoteAudioLevel(String identity) {
    final lk.RemoteParticipant? participant =
        _room.remoteParticipants[identity];
    if (participant == null) return 0;
    // 收包侧实测优先（灵敏）；平台不给统计时才回退服务端 speaker 电平（~1.5s）。
    final double? measured = _measuredRemoteLevels[identity];
    if (measured != null) return measured;
    final double raw = participant.audioLevel;
    return raw.isFinite ? math.max(0.0, math.min(1.0, raw)) : 0;
  }

  @override
  Future<void> startAudio() async {
    // 原生平台：远端音频由 WebRTC 音频设备自动播放；startAudio 仅解锁音频会话
    // （web 的 autoplay 政策在原生不存在，但调用是幂等的、移动端仍有意义）。
    await _room.startAudio();
  }

  /// 远端成员本地播放开关（0 与非 0 两档；SDK 无 per-track 音量，见接口注释）。
  @override
  Future<void> setRemoteAudioEnabled(String identity, bool enabled) async {
    final lk.RemoteParticipant? participant =
        _room.remoteParticipants[identity];
    if (participant == null) return;
    for (final lk.RemoteTrackPublication<lk.RemoteAudioTrack> publication
        in participant.audioTrackPublications) {
      try {
        if (enabled) {
          if (!publication.subscribed) await publication.subscribe();
        } else {
          if (publication.subscribed) await publication.unsubscribe();
        }
        if (kDebugMode) {
          debugPrint('[lk] 远端本地播放 $identity enabled=$enabled '
              'sub=${publication.subscribed}');
        }
      } catch (_) {
        // 订阅状态竞态（刚加入/刚离开）：下一次连接事件会再对齐
      }
    }
  }

  /* ---------------- 诊断：RTP 统计（仅 debug） ---------------- */

  void _startDebugStatsTimer() {
    if (!kDebugMode) return;
    if (_debugStatsTimer != null) return;
    _debugStatsTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(_dumpAudioStats());
    });
  }

  void _stopDebugStatsTimer() {
    _debugStatsTimer?.cancel();
    _debugStatsTimer = null;
  }

  /// 每 3s 打印一次本地发送侧与每个远端接收侧的真实 RTP 统计。
  ///
  /// 为什么必须看这个（用户 2026-10-28 实报「手机说话电脑完全听不到、但音频条在动」）：
  /// 只有 getStats 能区分三种完全不同的故障：
  /// 1. `sub=false` 或 `track=null`  → **根本没订阅**（协商/订阅问题）
  /// 2. `pkts` 不涨                    → **包没到**（网络/加密/协商）
  /// 3. `pkts` 涨但 `energy` 不涨      → 到达但**解码出静音**
  /// 4. `pkts`/`energy` 都涨却没声音  → **平台播放栈**没输出（最终手段：换播放通路）
  Future<void> _dumpAudioStats() async {
    if (_disposed) return;
    try {
      final lk.LocalAudioTrack? loc = _micTrack;
      if (loc != null) {
        final s = await loc.getSenderStats();
        debugPrint('[lk] LOCAL tx pkts=${s?.packetsSent} bytes=${s?.bytesSent} '
            'level=${s?.audioSourceStats?.audioLevel} '
            'energy=${s?.audioSourceStats?.totalAudioEnergy}');
      } else {
        debugPrint('[lk] LOCAL tx 未开麦');
      }
      if (_room.remoteParticipants.isEmpty) {
        debugPrint('[lk] REMOTE 无其他成员');
      }
      for (final MapEntry<String, lk.RemoteParticipant> e
          in _room.remoteParticipants.entries) {
        for (final lk.RemoteTrackPublication<lk.RemoteAudioTrack> pub
            in e.value.audioTrackPublications) {
          final lk.RemoteAudioTrack? t = pub.track;
          debugPrint('[lk] REMOTE ${e.key} sub=${pub.subscribed} '
              'pubMuted=${pub.muted} track=${t != null}');
          if (t == null) continue;
          final st = await t.getReceiverStats();
          debugPrint('[lk] REMOTE ${e.key} rx pkts=${st?.packetsReceived} '
              'bytes=${st?.bytesReceived} energy=${st?.totalAudioEnergy} '
              'dur=${st?.totalSamplesDuration} lost=${st?.packetsLost} '
              'concealed=${st?.concealedSamples} jitter=${st?.jitter}');
        }
      }
    } catch (err) {
      debugPrint('[lk] 统计采集失败: $err');
    }
  }

  /// 实际生效的输出端点（最近一次切换回执里的 ADM 名；null = 未知）。
  String? _playoutDeviceName;

  /// 是否已在「有远端音频在播」之后校正过一次输出端点（每次连接只做一次）。
  bool _routeAlignedForPlayback = false;

  /// 选定采集设备（Windows：跟随系统默认**通信**采集端点 —— Windows 的"麦克风"）。
  ///
  /// 为什么必须显式选：不指定时 flutter_webrtc 的 GetUserMedia 会
  /// `SetRecordingDevice(0)`，而 ADM 的枚举下标 0 可能是**虚拟回环设备**
  /// （本机实测 = 「内部 AUX 输入 (Steam Streaming Speakers)」，永远静音）。
  /// 用户 2026-10-29 实报「电脑/手机开麦对方听不到、web 开麦能听到」，
  /// 根因正是这一条（web 走浏览器自己的选麦逻辑，只有原生端踩到）。
  /// 采不到设备时保持 ADM 默认（不 throw：开麦不能因为选设备失败而失败）。
  Future<void> _alignAudioInput() async {
    if (!AylaWindowsAudioDevice.supported) return;
    if (_captureDeviceId != null) return;
    try {
      final AylaAudioEndpoint? mic =
          await AylaWindowsAudioDevice.defaultEndpoint(
        capture: true,
        role: 1,
      );
      if (mic == null) {
        debugPrint('[lk] 未取到系统默认采集设备，交给 ADM 默认');
        return;
      }
      await lk.Hardware.instance.selectAudioInput(
        lk.MediaDevice(mic.id, mic.name, 'audioinput', null),
      );
      _captureDeviceId = mic.id;
      debugPrint('[lk] 采集设备已切到系统默认麦克风: ${mic.name}');
    } catch (error) {
      // 设备可能不在 WebRTC 的枚举集里 —— 不是致命错误，交给 ADM 默认。
      debugPrint('[lk] 切换采集设备失败（用 ADM 默认）: $error');
    }
  }

  /// 已选定的采集设备 id（避免每次开麦都重复选）。
  String? _captureDeviceId;

  /// 校正输出端点（Windows：跟随系统「默认**多媒体**设备」而不是「默认通信设备」）。
  ///
  /// ## 为什么必须能被重复调用（2026-10-28 用户实报后的关键修正）
  /// 只在 `connect()` 之前切一次是不够的，实测有三条会让它前功尽弃：
  /// 1. WebRTC 的播放设备模块在**首次 startPlayout** 时才真正打开设备 —— 那时
  ///    订阅还没发生；之后 PeerConnection 重新协商（远端开麦 / 重连）可能重建
  ///    ADM 的 playout 通道；
  /// 2. Windows 上「默认设备」与「默认通信设备」可以是**两个不同的物理端点**，
  ///    蓝牙耳机插拔/休眠切换后必须重新对齐；
  /// 3. 切换在 libwebrtc 里是异步 PostTask，失败是静默的（返回 0 不代表成功）。
  ///
  /// 所以：**connect 之后**与**首次订阅到远端音频之后**各强制切一次（[force] = true），
  /// 并把**内核回执**打进日志（vendor 补丁的 `selectAudioOutputDetailed` 会返回
  /// index / matchedById / setResult / devices）。
  Future<void> _alignAudioRoute({bool force = false}) async {
    if (!AylaWindowsAudioDevice.supported) return;
    try {
      final ({AylaAudioEndpoint? communications, AylaAudioEndpoint? multimedia})
          ends = await AylaWindowsAudioDevice.defaultEndpoints();
      final AylaAudioEndpoint? target = ends.multimedia ?? ends.communications;
      if (target == null) {
        debugPrint('[lk] 未取到系统默认输出设备，保持 WebRTC 默认');
        return;
      }
      if (kDebugMode) {
        debugPrint('[lk] 输出端点 多媒体=${ends.multimedia?.name ?? '-'} '
            '通信=${ends.communications?.name ?? '-'}');
      }
      // ⚠️ **这里绝不能因为上次已经切过同名设备就跳过**（2026-10-29 实测定案）：
      //
      // 实测三组 CoreAudio 峰值（远端 440Hz 在播时读端点峰值）：
      // · 生产路径（connect 前切到耳机，守卫挡掉后续切换）→ 通信端点 0.4401、耳机 0.0001；
      // · connect 之后强制切到耳机 → 用户当场听到声音；
      // · connect 之后强制切到虚拟声卡 VB-Audio → VB-Audio 0.3557、通信端点 0。
      //
      // 即：切换动作本身有效，但 connect 之前设的那次不生效——ADM 的 Windows playout
      // 通道是在首次 startPlayout 时才按当时（= 系统默认通信设备）打开的，把 connect 前
      // 那次 SetPlayoutDevice 覆盖掉了。所以「已经切过」推不出「当前正在往那个设备播」：
      // 必须在 playout 真正起来之后**再切一次**。
      //
      // 代价：重复切会触发 libwebrtc 的 Stop/Init/Start playout（极短静音），因此这条
      // 只在 force（连接完成 / 首次有远端音频）或端点真的变了时才执行；普通开麦关麦不触发。
      final bool sameAsLast =
          _playoutDeviceName != null && _playoutDeviceName == target.name;
      if (sameAsLast && !force) return;
      Map<String, dynamic> receipt = <String, dynamic>{};
      try {
        receipt = await Helper.selectAudioOutputDetailed(target.id);
      } catch (error) {
        debugPrint('[lk] 详细切换不可用，退回普通 selectAudioOutput: $error');
      }
      if (receipt.isEmpty) {
        await lk.Hardware.instance.selectAudioOutput(
          lk.MediaDevice(target.id, target.name, 'audiooutput', null),
        );
        _playoutDeviceName = target.name;
        debugPrint('[lk] 输出设备已切到系统默认: ${target.name}（无内核回执）');
        return;
      }
      _playoutDeviceName = (receipt['name'] ?? target.name).toString();
      debugPrint('[lk] 输出设备切换回执 index=${receipt['index']} '
          'name=${receipt['name']} matchedById=${receipt['matchedById']} '
          'setResult=${receipt['setResult']} '
          'count=${receipt['playoutDeviceCount']} '
          'devices=[${receipt['devices']}]');
    } catch (error) {
      // 设备可能不在 WebRTC 的枚举集里（如休眠中的蓝牙耳机）——不是致命错误。
      debugPrint('[lk] 切换输出设备失败: $error');
    }
  }

  /// Android 媒体音频路由（幂等；非 Android 或失败返回 false，**绝不抛**）。
  ///
  /// 为什么 Dart 侧 `AudioSessionOptions.mediaPlayback` 不够：它只改**会话策略**，
  /// 而 WebRTC ADM 的播放 AudioTrack 在 initialize 时已按 USAGE_VOICE_COMMUNICATION
  /// 建好，音量键因此仍落在 STREAM_VOICE_CALL 上（`dumpsys audio` 可见）。
  /// 原生兜底见 `core/media/android_audio_route.dart`。
  Future<void> _applyAndroidMediaRoute(String stage) async {
    final bool applied = await aylaApplyAndroidMediaRoute();
    if (!kDebugMode) return;
    if (!applied && !AylaAndroidAudioRoute.supported) return;
    final AylaAndroidMediaRouteState? state = AylaAndroidAudioRoute.lastState;
    debugPrint('[lk] android 媒体音频路由 stage=$stage applied=$applied '
        'mode=${state?.mode ?? '-'} focus=${state?.focusGranted} '
        'speaker=${state?.speakerOn} headset=${state?.headset} '
        'musicVol=${state?.streamMusicVolume} '
        'voiceCallVol=${state?.streamVoiceCallVolume}');
  }

  /// 连接后再压一次移动端的媒体会话（SDK 在连接过程中可能重施通话策略）。
  void _alignAudioRouteAfterConnect() {
    if (AylaWindowsAudioDevice.supported) return;
    unawaited(_applyAudioSession());
  }

  /* ---------------- 远端电平（收包侧实测） ---------------- */

  void _startRemoteLevelTimer() {
    if (_remoteLevelTimer != null) return;
    _remoteLevelTimer =
        Timer.periodic(const Duration(milliseconds: 200), (_) {
      unawaited(_refreshRemoteLevels());
    });
  }

  void _stopRemoteLevelTimer() {
    _remoteLevelTimer?.cancel();
    _remoteLevelTimer = null;
    _remoteLevelBusy = false;
    _measuredRemoteLevels.clear();
    _remotePrevEnergy.clear();
    _remotePrevDuration.clear();
  }

  /// 远端电平：用**收包侧统计**算 RMS。
  ///
  /// 公式：`level = sqrt(dTotalAudioEnergy / dTotalSamplesDuration)`
  /// （WebRTC 规范里 totalAudioEnergy 是样本平方和，故 sqrt(能量/时长) 即 RMS 幅度）。
  /// 200ms 一拍、单飞不并发；平台不给字段时跳过（`remoteAudioLevel` 会回退）。
  Future<void> _refreshRemoteLevels() async {
    if (_remoteLevelBusy || _disposed) return;
    _remoteLevelBusy = true;
    final Set<String> alive = <String>{};
    try {
      for (final MapEntry<String, lk.RemoteParticipant> entry
          in _room.remoteParticipants.entries) {
        final String identity = entry.key;
        for (final lk.RemoteTrackPublication<lk.RemoteAudioTrack> publication
            in entry.value.audioTrackPublications) {
          if (!publication.subscribed) continue;
          final lk.RemoteAudioTrack? track = publication.track;
          if (track == null) continue;
          final stats = await track.getReceiverStats();
          final num? energy = stats?.totalAudioEnergy;
          final num? duration = stats?.totalSamplesDuration;
          if (energy == null || duration == null) continue;
          final num? prevEnergy = _remotePrevEnergy[identity];
          final num? prevDuration = _remotePrevDuration[identity];
          _remotePrevEnergy[identity] = energy;
          _remotePrevDuration[identity] = duration;
          alive.add(identity);
          if (prevEnergy == null || prevDuration == null) break;
          final num dEnergy = energy - prevEnergy;
          final num dDuration = duration - prevDuration;
          if (dDuration <= 0 || dEnergy < 0) break;
          final double rms =
              math.sqrt((dEnergy / dDuration).toDouble());
          // 语音 RMS 经验值 0.01–0.3；×3.2 映射到条子观感（与 web 的开方放大同量级）。
          final double level = math.max(0.0, math.min(1.0, rms * 3.2));
          if (level > 0.01 && !_measuredRemoteLevels.containsKey(identity)) {
            // 首帧非静音：说明收包侧统计可用（这条日志用于确认"电平不灵敏"已修好）
            debugPrint('[livekit] 远端电平实测可用 identity=$identity level=$level');
          }
          _measuredRemoteLevels[identity] = level;
          break;
        }
      }
    } catch (_) {
      // 统计不可用不是错误路径：保留上一拍，下一拍再试
    } finally {
      for (final String identity
          in _measuredRemoteLevels.keys.toList(growable: false)) {
        if (!alive.contains(identity)) {
          _measuredRemoteLevels.remove(identity);
          _remotePrevEnergy.remove(identity);
          _remotePrevDuration.remove(identity);
        }
      }
      _remoteLevelBusy = false;
    }
  }

  /* ---------------- 事件映射 ---------------- */

  /// 绑定 SDK 事件 → 归一化事件。
  ///
  /// 只映射后端需要的 8 类；**刻意不注册 `ActiveSpeakersChangedEvent`**——
  /// speaking 是 UI 事实，不是媒体门控（硬约束 3）。
  void _bindEvents() {
    final listener = _room.createListener();
    _cancels
      ..add(listener.on<lk.RoomConnectedEvent>(
          (_) => _emit(AylaRoomEventKind.connected)))
      ..add(listener.on<lk.RoomReconnectingEvent>(
          (_) => _emit(AylaRoomEventKind.reconnecting)))
      ..add(listener.on<lk.RoomResumingEvent>(
          (_) => _emit(AylaRoomEventKind.reconnecting)))
      ..add(listener.on<lk.RoomReconnectedEvent>(
          (_) => _emit(AylaRoomEventKind.reconnected)))
      ..add(listener.on<lk.RoomDisconnectedEvent>(
          (_) => _emit(AylaRoomEventKind.disconnected)))
      ..add(listener.on<lk.ParticipantConnectedEvent>((event) {
        _emit(AylaRoomEventKind.participantJoined,
            identity: event.participant.identity);
      }))
      ..add(listener.on<lk.ParticipantDisconnectedEvent>((event) {
        _emit(AylaRoomEventKind.participantLeft,
            identity: event.participant.identity);
      }))
      ..add(listener.on<lk.TrackMutedEvent>((event) {
        if (_isLocalParticipant(event.participant)) return;
        if (event.publication.kind != lk.TrackType.AUDIO) return;
        _emit(AylaRoomEventKind.trackMuted,
            identity: event.participant.identity, muted: true);
      }))
      ..add(listener.on<lk.TrackUnmutedEvent>((event) {
        if (_isLocalParticipant(event.participant)) return;
        if (event.publication.kind != lk.TrackType.AUDIO) return;
        _emit(AylaRoomEventKind.trackUnmuted,
            identity: event.participant.identity, muted: false);
      }))
      // 对方「重新开麦」在我们语义里是**新建 publication**（关麦 = unpublish）。
      // SDK autoSubscribe 会把它订阅回来 ⇒ 本地静音会被静默绕过
      // （用户实报 2026-10-28：「收音方关掉了放音方声音，放音方重新开麦又能听见」）。
      // 这里补一个订阅事件，交给后端按已记录的本地音量重新对齐。
      ..add(listener.on<lk.TrackSubscribedEvent>((event) {
        if (_isLocalParticipant(event.participant)) return;
        if (event.track.kind != lk.TrackType.AUDIO) return;
        // 排查用：远端音频「是否真的订阅上了」是区分
        // 「订阅没发生（网络/协商）」与「订阅了但放不出来（平台音频栈）」的唯一线索。
        // 2026-10-28 用户实报「手机说话电脑听不到」，需要这条日志定位。
        debugPrint('[livekit] 远端音频已订阅 identity=${event.participant.identity}');
        // 第一次真正有远端音频之后必须再校一次输出端点：ADM 的 playout 设备是在
        // **首次真正播放**时才打开的，那一刻才决定声音从哪个物理端点出来。
        // 用户实报「音频条在跳、耳机没声音」正是这一步缺失（声音留在通信设备上）。
        if (!_routeAlignedForPlayback) {
          _routeAlignedForPlayback = true;
          unawaited(_alignAudioRoute(force: true));
        }
        _emit(AylaRoomEventKind.trackSubscribed,
            identity: event.participant.identity);
      }))
      ..add(listener.on<lk.TrackUnsubscribedEvent>((event) {
        if (_isLocalParticipant(event.participant)) return;
        if (event.track.kind != lk.TrackType.AUDIO) return;
        debugPrint('[livekit] 远端音频已退订 identity=${event.participant.identity}');
      }));
  }

  /// 本地参与者判定。
  ///
  /// 不用 `isLocal`：livekit_client 2.13.2 的 `Participant` 基类**没有**该 getter
  /// （只有 `LocalParticipant` / `RemoteParticipant` 子类），而事件参数是基类类型
  /// ⇒ 用 identity 比对（本地参与者 identity 就是 token 的 `sub`）。
  bool _isLocalParticipant(lk.Participant participant) {
    final lk.LocalParticipant? local = _room.localParticipant;
    if (local == null) return false;
    return participant.identity == local.identity;
  }

  /// 取消全部 SDK 事件监听（幂等）。
  Future<void> _cancelListeners() async {
    final List<Future<void> Function()> cancels =
        List<Future<void> Function()>.of(_cancels);
    _cancels.clear();
    for (final Future<void> Function() cancel in cancels) {
      try {
        await cancel();
      } catch (_) {
        // 已取消
      }
    }
  }

  void _emit(AylaRoomEventKind kind, {String? identity, bool? muted}) {
    if (_disposed || _events.isClosed) return;
    _events.add(AylaRoomEvent(kind, identity: identity, muted: muted));
  }

  /* ---------------- 本地电平取数 ---------------- */

  void _startLevelTimer() {
    if (_levelTimer != null) return;
    _levelTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      unawaited(_refreshLocalLevel());
    });
  }

  void _stopLevelTimer() {
    _levelTimer?.cancel();
    _levelTimer = null;
    _levelBusy = false;
  }

  /// 刷新本地实测电平（`getSenderStats` 有平台通道成本 ⇒ 200ms 一次、不并发）。
  ///
  /// 取 `audioSourceStats.audioLevel`（libwebrtc 的 media-source 统计）；
  /// 平台不给该字段时留 null，由 [localAudioLevel] 回退到
  /// `localParticipant.audioLevel`（服务端 speaker 电平）。
  Future<void> _refreshLocalLevel() async {
    final lk.LocalAudioTrack? track = _micTrack;
    if (track == null || _levelBusy || _disposed) {
      if (track == null) _measuredLocalLevel = null;
      return;
    }
    _levelBusy = true;
    try {
      final stats = await track.getSenderStats();
      final num? level = stats?.audioSourceStats?.audioLevel;
      if (level != null && level.isFinite) {
        _measuredLocalLevel = math.max(0.0, math.min(1.0, level.toDouble()));
      }
    } catch (_) {
      // 统计不可用不是错误路径：保留上一次实测（下一拍再试）
    } finally {
      _levelBusy = false;
    }
  }

  /* ---------------- 设备释放 ---------------- */

  /// 断开前先放设备（与 [unpublishMicrophone] 同一语义；幂等）。
  Future<void> _releaseMicrophone() => unpublishMicrophone();
}
