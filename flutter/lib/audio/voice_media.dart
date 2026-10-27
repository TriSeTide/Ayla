/// 语音媒体层薄封装 —— web `livekit/client.ts`（`VoiceLiveKitClient`）的
/// Flutter 等价物：连接/静音/音量/远端事实归一，**只处理媒体层**。
///
/// ## 依赖倒置（同 web `client.ts:4–5`）
/// 本类只依赖**可注入件**：ws_relay 路径的 [AylaRelayClient]（WS 音频中继）与
/// [AylaAudioEngine]（采集/编解码/播放）；LiveKit 路径的 [AylaLiveKitVoiceBackend]
/// （房间适配 + 100ms 电平节拍）。测试注入替身即可覆盖全部分支。
///
/// ## 双后端（M4-5 单 UDP 端口 LiveKit 接入）
/// 后端 join / media-token 响应带 `media` 旁路字段，**同时下发**两种媒体配置
/// （见 [AylaVoiceMediaConfig]）：
/// - `transport = livekit` 且配置完整 ⇒ [connectWithMedia] 走 LiveKit；
/// - **连接失败原地降级到 ws_relay**（一次重试，不回后端、不发版）——
///   降级只换媒体通道，**不触发 leave/**（媒体断线 ≠ 离开频道，`client.ts:15` 既有契约）；
/// - `transport = ws_relay` / 老后端不返回 `media` ⇒ 与今日行为**逐字节一致**。
///
/// ws_relay 路径（[AylaRelayClient] + [AylaAudioEngine]）**一行未删**，是完整可用的
/// 回滚实现；`VOICE_MEDIA_TRANSPORT=ws_relay`（后端环境变量）是唯一的全局回滚开关。
///
/// ## 语义边界（M5-3 §4.3，web `client.ts:11–17` 原话）
/// - **轨道 mute 是媒体事实**；`voice.state` 的 muted/unmuted 是**应用层**成员事实 ——
///   两者不混用，本封装只处理媒体层；
/// - **远端音量是本地播放偏好**：只调本地增益，不落库、不上报；
/// - **媒体断线 ≠ 离开频道**：断线只映射为 `failed`，由用户决定重进；
/// - token 纪律：token 只作 connect 入参传递，**不打日志、不缓存**。
///
/// ## LiveKit 三条硬约束的落点（web 侧已做到，Flutter 逐条对齐）
/// 1. **identity 必须裸 `str(user.pk)`**：本层不改写、不加前缀；后端签发的
///    `media.livekit.identity` 与当前用户 id 不一致时**主动打日志**（不静默失配）；
/// 2. **关麦真正释放麦克风设备**：LiveKit 路径委托
///    [AylaLiveKitVoiceBackend.setMicrophoneEnabled]；ws_relay 路径保持原有
///    `stopCapture` 语义；
/// 3. **绝不用 isSpeaking / activeSpeakers 门控 publish**：两条路径都只以 `muted`
///    为硬门控（`Ayla/docs/flutter/39-…`）。
///
/// ## 与 web 的差异（登记）
/// - web 用 `WebAudio` 的 per-slot gain 与 `WebCodecs` 编解码；Flutter ws_relay 用
///   `libopus FFI` + `miniaudio`（PoC-A 选型定论）—— 语义等价，增益在**编码前 /
///   播放前**按样本施加（见 `audio_engine.dart` 头注）；
/// - web 的 `owner generation + AbortError` 用 Dart 的 `generation` 计数表达
///   （无 `AbortError` 类型）：连接被取代时旧调用抛 [AylaVoiceMediaCancelled]，
///   调用方按「被取代」静默处理；
/// - **LiveKit 路径的能力边界**（SDK 2.13.2 无 per-track 音量 API）：远端本地禁音
///   以「不订阅」实现（0 档生效，中间档不生效）；本地发送增益不生效 —— 都会打
///   诚实日志，绝不伪装成功（见交付报告）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'audio_engine.dart';
import 'livekit_room_adapter.dart' show aylaInstallLiveKitRoomBuilder;
import 'livekit_voice_backend.dart';
import 'relay_client.dart';
import 'voice_media_config.dart';

export 'voice_media_config.dart';

/// 媒体连接被新连接取代（web `AbortError` 的等价物）。
class AylaVoiceMediaCancelled implements Exception {
  const AylaVoiceMediaCancelled();

  @override
  String toString() => '语音媒体连接已被取代';
}

/// 媒体层事件（web `LiveKitEvents`）。
class AylaVoiceMediaEvents {
  /// 状态变化（idle/connecting/connected/reconnecting/failed/closed）。
  void Function(RelayState state)? onStateChange;

  /// 远端轨道静音事实（媒体层；[slot] → 由会话层映射到 user_id）。
  void Function(int slot, bool muted)? onTrackMuted;

  /// 本地麦克风实时音量 0`1（未开麦时为 0）。
  void Function(double level)? onLocalAudioLevel;

  /// 远端成员实时音量**全量快照**（user_id → 0`1，含 0）。
  void Function(Map<String, double> levels)? onRemoteAudioLevels;

  /// 诊断日志。
  void Function(String line)? onLog;
}

/// 语音媒体封装（单例语义由 [aylaVoiceMedia] 承担；测试可直接 new）。
class AylaVoiceMedia {
  AylaVoiceMedia(this._events) {
    // LiveKit 生产房间构造器注册（幂等）：适配层只在真正 connect('livekit') 时
    // 才构造原生 Room —— 单测注入假工厂时完全不碰 SDK / 原生插件。
    aylaInstallLiveKitRoomBuilder();

    // ⚠️ `RelayCallbacks` / `AudioEngineCallbacks` 是**字段式回调容器**
    // （PoC 形态：先建实例再挂回调），不是构造参数式。
    // ⚠️ 逐条赋值（**不要用级联 `..`**：lambda 体以 `=>` 结尾时，下一行的 `..x = y`
    // 会被解析成 lambda 体内的级联，报 use_of_void_result —— 实测踩过）。
    final RelayCallbacks relayCallbacks = RelayCallbacks();
    relayCallbacks.onStateChange = (RelayState s) => _events.onStateChange?.call(s);
    relayCallbacks.onMuted = (int slot, bool on) => _events.onTrackMuted?.call(slot, on);
    relayCallbacks.onLog = (String line) => _events.onLog?.call(line);
    _relay = AylaRelayClient(
      relayCallbacks,
      freshToken: () => _freshToken(),
    );
    relayCallbacks.onAudio = (int slot, Uint8List opus) =>
        unawaited(_engine.onRemoteAudio(slot, opus));
    final AudioEngineCallbacks engineCallbacks = AudioEngineCallbacks();
    engineCallbacks.onLocalLevel =
        (double level) => _events.onLocalAudioLevel?.call(level);
    engineCallbacks.onRemoteAudioLevels =
        (Map<String, double> levels) => _events.onRemoteAudioLevels?.call(levels);
    engineCallbacks.onLog = (String line) => _events.onLog?.call(line);
    _engine = AylaAudioEngine(_relay, engineCallbacks);

    // LiveKit 后端：回调**逐条转发到同一份 [_events]**（与上面中继/引擎同一手法）。
    // ⚠️ 绝不在 LiveKit 实现里另建一个 `AylaVoiceMediaEvents`：那会让会话层绑到
    // 孤儿对象上（两次实报事故的根因，见 [events] 的注释）。
    _livekit = AylaLiveKitVoiceBackend(
      onStateChange: (RelayState state) => _events.onStateChange?.call(state),
      onTrackMuted: (int slot, bool muted) =>
          _events.onTrackMuted?.call(slot, muted),
      onLocalAudioLevel: (double level) => _events.onLocalAudioLevel?.call(level),
      onRemoteAudioLevels: (Map<String, double> levels) =>
          _events.onRemoteAudioLevels?.call(levels),
      onLog: (String line) => _events.onLog?.call(line),
      roomFactory: _createLiveKitRoom,
    );
  }

  final AylaVoiceMediaEvents _events;

  /// 本实例的事件容器（中继/引擎/LiveKit 后端的回调**构造时已接进这一份**）。
  ///
  /// ⚠️ **会话层必须绑这一份**（2026-10-26 用户实报「听得见声音但音量条恒 0」的根因）：
  /// 构造体把 [RelayCallbacks] / [AudioEngineCallbacks]（以及 LiveKit 后端的回调）
  /// 逐条转发到 [_events]，而引擎每 100ms 就调一次
  /// `_events.onRemoteAudioLevels?.call(snapshot)`。
  /// 若调用方另建一个 [AylaVoiceMediaEvents] 去 `bindMediaEvents`，那个对象
  /// **永远不会被任何东西调用** ⇒ 音频电平/静音/状态事实全部丢失，只有声音照旧
  /// （媒体链路本身是好的）⇒ 条子恒 0。
  AylaVoiceMediaEvents get events => _events;

  late final AylaRelayClient _relay;
  late final AylaAudioEngine _engine;
  late final AylaLiveKitVoiceBackend _livekit;

  /// 当前生效的媒体传输（连接成功后为**实际使用**的那一条；降级后变成 ws_relay）。
  AylaVoiceTransport _transport = AylaVoiceTransport.wsRelay;

  /// token 续期钩子（默认继承模块级 `_voiceMediaTokenRefresher`，见 [setTokenRefresher]）。
  /// 未注入时返回 null —— **不伪造续期成功**。
  Future<String?> Function() _freshToken =
      _voiceMediaTokenRefresher ?? () async => null;

  /// 见 [debugHasTokenRefresher]（构造时若模块级已有注入则视为已注入）。
  bool _hasTokenRefresher = _voiceMediaTokenRefresher != null;

  int _generation = 0;
  bool _engineReady = false;

  /// 本次连接实际使用的媒体传输（降级后读回 [AylaVoiceTransport.wsRelay]）。
  AylaVoiceTransport get transport => _transport;

  /// 当前是否已连接（媒体面）。
  bool get connected => state == RelayState.connected;

  /// 当前状态（按当前传输分流；LiveKit 无 slot 概念）。
  RelayState get state => _transport == AylaVoiceTransport.livekit
      ? _livekit.state
      : _relay.state;

  /// 我的 slot（-1 = 未分配；LiveKit 恒 -1）。
  int get mySlot =>
      _transport == AylaVoiceTransport.livekit ? -1 : _relay.mySlot;

  /// 是否开麦（媒体事实）。
  bool get microphoneEnabled => _transport == AylaVoiceTransport.livekit
      ? _livekit.microphoneEnabled
      : _engine.micEnabled;

  /// 诊断：引擎是否已成功初始化（**false = 设备/库不可用，不冒充成功**）。
  ///
  /// 仅 ws_relay 路径有意义；LiveKit 路径恒 false（没有本地引擎）。
  bool get debugEngineReady => _engineReady;
  bool get debugLibInit => _engine.debugLibInit;
  bool get debugMiniaudioReady => _engine.debugMiniaudioReady;

  /// 注入 token 续期（`main` 在 `DioClient` init 之后调用一次）。
  ///
  /// ⚠️ 同时写进**模块级** `_voiceMediaTokenRefresher`：登出会
  /// [aylaVoiceMediaTeardown] 把单例置空，下次 [aylaVoiceMedia] 新建的实例必须
  /// 继承同一个续期实现 —— 否则「登出再登录」之后中继又退回「恒返回 null」，
  /// 且再没有人会去补注入（`main` 每个进程只跑一次）。
  void setTokenRefresher(Future<String?> Function() refresher) {
    _freshToken = refresher;
    _voiceMediaTokenRefresher = refresher;
    _hasTokenRefresher = true;
  }

  /// 诊断：是否已注入 token 续期实现。
  ///
  /// `false` = 中继连续失败达阈值后**只能沿用旧 token**（token 过期就永远续不上）。
  /// 生产由 `main` 注入一次；本 getter 是接线回归锁的可观测面。
  bool get debugHasTokenRefresher => _hasTokenRefresher;

  /* ---------------- 连接（双后端 + 原地降级） ---------------- */

  /// 连接频道（**ws_relay**；保留旧签名 —— 回滚路径与既有调用方零改动）。
  ///
  /// 被新连接取代时旧调用以 [AylaVoiceMediaCancelled] 结束；否则异常原样上抛
  /// （由 join 流程决定回滚 —— **媒体断线 ≠ 离开频道**）。
  Future<void> connect(String channelId, String token) async {
    _transport = AylaVoiceTransport.wsRelay;
    final int generation = ++_generation;
    await _connectRelayGuarded(channelId, token, generation);
  }

  /// 按服务端下发的媒体配置连接（web `client.ts connectWithMedia`）。
  ///
  /// - `media` 为空 / `transport != livekit` / livekit 配置不全 ⇒ 走 ws_relay
  ///   （与今日行为逐字节一致，老后端不带 `media` 也一样）；
  /// - `transport = livekit` 且配置完整 ⇒ 走 LiveKit；**连接失败原地降级**到
  ///   ws_relay（服务端双下发，无需二次请求；降级**不触发 leave/**）：
  ///   `transport_fallback from=livekit to=ws_relay reason=…`（不含 token）；
  /// - 被新连接取代（切频道/离开）时**不降级**，原样抛 [AylaVoiceMediaCancelled]。
  ///
  /// [selfUserId] 只用于 identity 纪律诊断（见 [_logIdentityCheck]），不参与连接。
  Future<void> connectWithMedia(
    String channelId,
    String accessToken,
    AylaVoiceMediaConfig? media, {
    String? selfUserId,
  }) async {
    final int generation = ++_generation;
    final AylaVoiceLiveKitConfig? livekit = media?.livekit;
    _logIdentityCheck(livekit, selfUserId);
    if (media == null || !media.wantsLiveKit || livekit == null) {
      _transport = AylaVoiceTransport.wsRelay;
      await _connectRelayGuarded(channelId, accessToken, generation);
      return;
    }
    _transport = AylaVoiceTransport.livekit;
    try {
      await _connectLiveKitGuarded(livekit, generation);
      return;
    } catch (error) {
      // 被取代（切频道/离开）不是降级场景：原样上抛，由调用方静默处理。
      if (error is AylaVoiceMediaCancelled || generation != _generation) {
        rethrow;
      }
      _events.onLog?.call(
        '[voice] transport_fallback from=livekit to=ws_relay '
        'reason=${_redact(error)}',
      );
      _transport = AylaVoiceTransport.wsRelay;
      await _connectRelayGuarded(channelId, accessToken, generation);
    }
  }

  Future<void> _connectLiveKitGuarded(
    AylaVoiceLiveKitConfig config,
    int generation,
  ) async {
    try {
      await _livekit.connect(config.url, config.token);
    } on AylaVoiceBackendCancelled {
      // 后端级「被取代」统一翻译成本类的取消语义（会话层只认这一个）。
      throw const AylaVoiceMediaCancelled();
    } catch (error) {
      if (generation != _generation) throw const AylaVoiceMediaCancelled();
      rethrow;
    }
    if (generation != _generation) {
      await _livekit.disconnect();
      throw const AylaVoiceMediaCancelled();
    }
  }

  Future<void> _connectRelayGuarded(
    String channelId,
    String token,
    int generation,
  ) async {
    if (!_engineReady) {
      _engineReady = await _engine.init();
      if (!_engineReady) {
        await disconnect();
        throw StateError('音频引擎初始化失败（libopus / 音频设备不可用）');
      }
    }
    if (generation != _generation) throw const AylaVoiceMediaCancelled();
    try {
      await _connectRelay(channelId, token);
    } catch (error) {
      if (generation != _generation) throw const AylaVoiceMediaCancelled();
      _events.onStateChange?.call(RelayState.failed);
      rethrow;
    }
    if (generation != _generation) throw const AylaVoiceMediaCancelled();
  }

  /// ws_relay 实际连接（生产 = [AylaRelayClient]；单测可用
  /// [debugRelayConnect] 替换以免触网）。
  Future<void> _connectRelay(String channelId, String token) {
    final Future<void> Function(String channelId, String token)? override =
        debugRelayConnect;
    if (override != null) return override(channelId, token);
    return _relay.connect(channelId, token);
  }

  /* ---------------- 媒体操作（按传输分流） ---------------- */

  /// 播放入口就绪（web `startAudio()` 的等价物）。
  ///
  /// ws_relay：Flutter 侧 miniaudio 是 push 式设备流、无浏览器 autoplay 政策 ⇒
  /// 本方法只保证"引擎已初始化"（返回值 void），**不伪造播放成功**；
  /// LiveKit：委托后端（原生平台远端音频由 WebRTC 自动播放，调用是幂等的）。
  Future<void> startAudio() async {
    if (_transport == AylaVoiceTransport.livekit) {
      await _livekit.startAudio();
      return;
    }
    if (!_engineReady) _engineReady = await _engine.init();
  }

  /// 开/关麦（web `setMicrophoneEnabled`；失败原样上抛由调用方回滚 UI）。
  ///
  /// ⚠️ LiveKit 路径的「关麦」= **释放麦克风设备**（unpublish + track.stop()），
  /// 不是 mute —— 见 [AylaLiveKitVoiceBackend.setMicrophoneEnabled]。
  Future<void> setMicrophoneEnabled(bool enabled) {
    if (_transport == AylaVoiceTransport.livekit) {
      return _livekit.setMicrophoneEnabled(enabled);
    }
    return _engine.setMicrophoneEnabled(enabled);
  }

  /// 远端成员本地播放增益 0`1（web `setRemoteVolume`）。
  void setRemoteVolume(String userId, double volume) {
    if (_transport == AylaVoiceTransport.livekit) {
      _livekit.setRemoteVolume(userId, volume);
      return;
    }
    _engine.setRemoteVolume(userId, volume);
  }

  /// 本地发送增益 0`2（web `setLocalVolume`；UI 的 0`100 → `volume / 50`）。
  void setLocalVolume(double gain) {
    if (_transport == AylaVoiceTransport.livekit) {
      _livekit.setLocalVolume(gain);
      return;
    }
    _engine.setLocalGain(gain);
  }

  /// 断开（幂等；web `disconnect()`）。**不代表离开频道**。
  Future<void> disconnect() async {
    _generation++;
    if (_transport == AylaVoiceTransport.livekit) {
      await _livekit.disconnect();
      return;
    }
    await _relay.disconnect();
  }

  /// 释放（登出/测试收尾）：断开 + 销毁引擎 + 释放 LiveKit 房间。
  Future<void> dispose() async {
    _generation++;
    await _livekit.dispose();
    await _relay.disconnect();
    await _engine.dispose();
    _engineReady = false;
    _transport = AylaVoiceTransport.wsRelay;
  }

  /* ---------------- 诊断 / 测试注入点 ---------------- */

  /// 测试注入点：LiveKit 房间工厂（默认由适配层注册；测试置 null 恢复生产实现）。
  ///
  /// **static** 是因为后端在构造时就绑定了工厂闭包（见构造函数）。
  @visibleForTesting
  static AylaVoiceRoomFactory? debugLiveKitRoomFactory;

  /// 测试注入点：替换 ws_relay 的真实连接（避免单测触网）。
  ///
  /// 替身**自己**按真实语义回调 `events.onStateChange`（本类不替替身伪造状态）。
  @visibleForTesting
  Future<void> Function(String channelId, String token)? debugRelayConnect;

  /// 测试注入点：把「引擎已就绪」置真 —— 绕过原生音频初始化
  /// （CI/单测环境没有音频设备与 FFI 库，否则中继连接前的引擎初始化必失败）。
  ///
  /// ⚠️ 只建可观测事实，不伪造播放/采集成功：生产路径**从不**调用它。
  @visibleForTesting
  void debugMarkEngineReady() => _engineReady = true;

  Future<AylaVoiceRoomLike> _createLiveKitRoom() {
    final AylaVoiceRoomFactory? override = debugLiveKitRoomFactory;
    if (override != null) return override();
    return AylaLiveKitRoomBuilder.build();
  }

  /// 测试注入点：直接拿引擎（断言增益/采样）。
  @visibleForTesting
  AylaAudioEngine get debugEngine => _engine;

  /// 测试注入点：直接拿 LiveKit 后端（断言状态/电平/slot 表）。
  @visibleForTesting
  AylaLiveKitVoiceBackend get debugLiveKit => _livekit;

  /// slot → identity（远端轨道静音事实映射到成员用；**公开面**，不是测试专用）。
  ///
  /// web 侧同一信息在 `wsRelayRoom.ts` 的 `slotToIdentity` 里，由 `client.ts`
  /// 的 `onTrackMuted(identity, muted)` 直接给出；Flutter 侧由会话层查这张表。
  /// LiveKit 后端内部维护「identity ↔ 合成 slot」，对外仍是同一张表（语义不变）。
  String? identityOfSlot(int slot) {
    if (_transport == AylaVoiceTransport.livekit) {
      return _livekit.identityOfSlot(slot);
    }
    final String? identity = _relay.slotIdentity[slot];
    return (identity == null || identity.isEmpty) ? null : identity;
  }

  /// 测试注入点：直接拿中继客户端。
  @visibleForTesting
  AylaRelayClient get debugRelay => _relay;

  /// identity 纪律诊断（硬约束 1）：后端 token.identity 必须是裸 `str(user.pk)`。
  ///
  /// 带前缀（如历史实现里的 `user_<id>`）会让成员表/音量/静音**全部失配**，且症状
  /// 隐蔽（声音正常、条子与静音标记错位）⇒ 这里主动报，不静默。
  void _logIdentityCheck(AylaVoiceLiveKitConfig? livekit, String? selfUserId) {
    final String? identity = livekit?.identity;
    if (identity == null || identity.isEmpty) return;
    if (selfUserId == null || selfUserId.isEmpty) return;
    if (identity == selfUserId) return;
    _events.onLog?.call(
      '[voice] identity_mismatch token.identity=$identity self=$selfUserId'
      ' —— 后端 media.livekit.identity 必须是裸 str(user.pk)',
    );
  }

  /// 脱敏：SDK 原始错误可能夹带 token（JWT 形如三段 base64url），日志不得泄露凭据
  /// （AGENTS.md §9）。
  static String _redact(Object error) {
    final String text = error.toString().replaceAllMapped(
          RegExp(r'[A-Za-z0-9_-]{20,}.[A-Za-z0-9_-]{10,}.[A-Za-z0-9_-]{10,}'),
          (Match match) => '<redacted-jwt>',
        ).replaceAllMapped(
          RegExp(
            r'([?&](?:access_token|token|key|secret)=)[^&s]+',
            caseSensitive: false,
          ),
          (Match match) => '${match[1]}<redacted>',
        );
    return text.length > 200 ? text.substring(0, 200) : text;
  }
}

/// 进程级 token 续期实现（由 `main` 注入一次；**跨单例重建存活**，见
/// [AylaVoiceMedia.setTokenRefresher]）。null = 尚未注入（不伪造续期成功）。
Future<String?> Function()? _voiceMediaTokenRefresher;

/// 全局单例（web `client.ts` 的 `voiceLiveKit`；房间同时只有一个媒体会话）。
AylaVoiceMedia? _voiceMedia;

/// 取/建全局媒体封装（首次调用时注入 events；已存在则原样返回 —— 与 web 单例同语义）。
AylaVoiceMedia aylaVoiceMedia([AylaVoiceMediaEvents? events]) {
  final AylaVoiceMedia? existing = _voiceMedia;
  if (existing != null) return existing;
  final AylaVoiceMedia created = AylaVoiceMedia(events ?? AylaVoiceMediaEvents());
  _voiceMedia = created;
  return created;
}

/// 测试专用：替换/清空全局单例。
@visibleForTesting
void debugSetVoiceMedia(AylaVoiceMedia? media) => _voiceMedia = media;

/// 登出 / 401 过期时的**语音媒体收尾**（幂等）。
///
/// 对应 web `stores/auth.ts:136` 的 `void voiceLiveKit.disconnect()`：登出必须断开语音
/// 媒体（WebAudio 设备、中继 WS、编解码器；LiveKit 路径则是房间 + 麦克风设备），
/// 否则下一位登录者会继承上一位的音频会话。
///
/// 与 [AylaVoiceMedia.disconnect] 的差别（有意）：
/// - `disconnect()` 是**房间级**语义（"离开当前频道、仍可复用实例"，web 同名）；
/// - 本函数是**账号级**收尾：连单例一起放掉（`_voiceMedia = null`），下一次
///   [aylaVoiceMedia] 会新建一份干净实例 —— 与 web 登出后 `voiceLiveKit` 重新 `connect`
///   的观感一致，且能保证事件回调不泄漏到已登出的会话。
///
/// **不阻塞调用方**：登出路径不等待音频设备释放（web 也是 `void` 调用）。
void aylaVoiceMediaTeardown() {
  final AylaVoiceMedia? media = _voiceMedia;
  _voiceMedia = null;
  if (media == null) return;
  // 不 await：登出是同步路径；dispose 内部幂等且自带错误吞并（见其实现）。
  unawaited(media.dispose());
}
