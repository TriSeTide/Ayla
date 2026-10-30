package com.ayla.ayla_flutter

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Ayla Flutter 主 Activity。
 *
 * 2026-10-18 新增：应用内更新需要把下载好的 APK 交给系统安装器。
 * Flutter 侧没有公开插件能做 `content://` + 读权限授予，故用最小 MethodChannel：
 *
 *   channel = com.ayla.ayla_flutter/update
 *   method  = installApk { path: String } -> Boolean
 *
 * 安全边界：
 * - 只接受应用缓存目录（cacheDir）下的普通文件，拒绝任意路径；
 * - 用 FileProvider 生成 content://，只授予读权限；
 * - 未声明 provider 时返回 false（Flutter 侧退化为打开下载页），不崩溃。
 *
 * 2026-10-28 新增：Android 语音会话必须是**媒体音量**（不是通话/听筒音量）。
 *
 * 问题根因（实测）：LiveKit 的 flutter 插件虽然自建 LKAudioSwitchManager 并在
 * `mediaPlayback` 配置下以 USAGE_MEDIA 申请焦点、把 mode 设成 MODE_NORMAL，
 * 但**真正的播放轨（WebRTC ADM 的 AudioTrack）在 WebRTC initialize 时按默认
 * USAGE_VOICE_COMMUNICATION 建立**（dumpsys audio 的 playback 记录可见
 * `usage=USAGE_VOICE_COMMUNICATION content=CONTENT_TYPE_SPEECH`），
 * 于是音量键作用在 STREAM_VOICE_CALL 上。Dart 侧 `AudioManager.setAudioSessionOptions`
 * 只改会话策略，不改已经建好的播放轨属性。
 *
 * 因此这里提供一条原生兜底通道，把系统音频状态压回「媒体」语义：
 *
 *   channel = ayla/audio_route
 *   method  = applyMediaMode -> Map（幂等，可反复调用）
 *     1) AudioManager.mode = MODE_NORMAL（通话模式是 MODE_IN_COMMUNICATION）；
 *     2) 检测有线/蓝牙/USB 耳机：有耳机不强制外放（让媒体路由自然走耳机），
 *        无耳机时 isSpeakerphoneOn = true；
 *     3) 以 AudioAttributes(USAGE_MEDIA, CONTENT_TYPE_SPEECH) 申请 AUDIOFOCUS_GAIN；
 *        焦点监听在 LOSS_TRANSIENT 结束（GAIN 回来）后**重施**媒体模式——
 *        系统/其它应用抢占焦点时会把 mode 改回通话，必须在恢复后压回来；
 *     4) 返回 mode / 是否外放 / STREAM_MUSIC 音量等可断言状态。
 *
 * 该通道只做「会话与路由」的工程约束，不参与任何音频内容或认知判断。
 */
class MainActivity : FlutterActivity() {
    private val channelName = "com.ayla.ayla_flutter/update"

    private val audioRouteChannelName = "ayla/audio_route"

    /** 直播「脱离应用」（Android PiP）通道名 —— 与 Dart 侧 `kAylaPipChannel` 逐字一致。 */
    private val livePipChannelName = "ayla/live_pip"

    /** PiP 通道句柄（回调 `onPipChanged` / `onBallTap` 用）。 */
    private var livePipChannel: MethodChannel? = null

    private val mainHandler = Handler(Looper.getMainLooper())


    /** Activity 是否处于 RESUMED（自己维护，避免依赖 embedding 的 LifecycleOwner 形态）。 */
    private var activityResumed = false


    /** 媒体焦点监听器（必须持有强引用，否则会被 GC 后失去回调）。 */
    private var mediaFocusListener: AudioManager.OnAudioFocusChangeListener? = null

    /** API 26+ 的焦点请求对象：复用同一个实例，重复申请对系统是同一客户端。 */
    private var mediaFocusRequest: AudioFocusRequest? = null

    /** 是否发生过「短暂失焦」，用于 GAIN 回来时决定要不要重施媒体会话。 */
    private var mediaFocusLost = false

    /** 至少成功 apply 过一次媒体会话（[reapplyMediaSession] 的守卫）。 */
    private var mediaSessionApplied = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("bad_args", "path is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(installApk(path))
                        } catch (error: Exception) {
                            result.error("install_failed", error.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, audioRouteChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "applyMediaMode" -> {
                        try {
                            result.success(applyMediaMode())
                        } catch (error: Exception) {
                            Log.w(TAG, "applyMediaMode failed: ${error.message}", error)
                            result.error("audio_route_failed", error.message, null)
                        }
                    }
                    "getMediaModeState" -> {
                        try {
                            result.success(readMediaModeState())
                        } catch (error: Exception) {
                            result.error("audio_route_failed", error.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        // ===== 直播「脱离应用」：Android Picture-in-Picture =====
        // 契约见 Dart 侧 lib/core/platform/detached_live.dart（**唯一** Dart↔原生契约）。
        // 本通道只做「呈现形态」的工程约束（窗口/系统状态），不参与任何内容或认知判断。
        livePipChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, livePipChannelName)
                .also { channel ->
                    channel.setMethodCallHandler { call, result ->
                        try {
                            when (call.method) {
                                // ===== 系统 PiP 已**彻底移除**（2026-11-01 用户明确要求）=====
                                // 用户原话：「彻底移除那个手机端系统 PiP（缩小整个 App），
                                //           现在离开 app 还是会出来手机端系统 PiP」。
                                //
                                // PiP 的三个入口全部关死（只留通道方法名，避免 Dart 侧
                                // MissingPluginException，语义改为「本平台不支持」）：
                                //   1. `isSupported` -> false
                                //      ⇒ `aylaSupportsLivePip()` 恒 false；
                                //   2. `enterPip` -> false
                                //      ⇒ 任何显式进入都被拒绝；
                                //   3. `setSessionActive` -> no-op
                                //      ⇒ 不再武装 setAutoEnterEnabled ⇒ **按 Home 不会再自动进 PiP**
                                //      （这是「离开 app 还出来 PiP」的真正触发点）。
                                // 另外 manifest 的 supportsPictureInPicture 已移除、
                                // onUserLeaveHint 的自动进入已删除 —— 四处全关。
                                "isSupported" -> result.success(false)
                                "isInPip" -> result.success(false)
                                "enterPip" -> result.success(false)
                                "setSessionActive" -> result.success(null)
                                "openOverlaySettings" -> result.success(openOverlaySettings())
                                // ===== 系统层悬浮球（语音/直播会话脱离应用）=====
                                // 返回字符串语义与 Dart 侧 AylaDetachedBallResult 逐字对齐：
                                // "shown" / "permissionRequired" / "unsupported" / "failed"。
                                // 未授权时**必须**给 permissionRequired（不静默失败）。
                                //
                                // ⚠️ 2026-10-31 重做：球不再由原生 Canvas 手绘（用户判定
                                // 「丑得要命」），改由第二 FlutterEngine + FlutterView 在
                                // 叠加层里 build **同一份** AylaSessionActivityIndicator
                                // （见 OverlayFlutterHost.kt）。
                                "showBall" -> result.success(showBall(call))
                                "updateBall" -> result.success(updateBall(call))
                                "hideBall" -> {
                                    overlayBall.hide()
                                    result.success(null)
                                }
                                // ===== 直播小窗（用「原来那个」AylaLiveMiniPlayer）=====
                                // 返回字符串语义与悬浮球同一套字面量（Dart 侧
                                // `aylaEnterDetachedLive` 的 Android 分支据此判断回落）。
                                "showLiveWindow" -> result.success(showLiveWindow(call))
                                "updateLiveWindow" -> result.success(updateLiveWindow(call))
                                "closeLiveWindow" -> {
                                    liveOverlay.hide(notify = false)
                                    result.success(null)
                                }
                                else -> result.notImplemented()
                            }
                        } catch (error: Exception) {
                            Log.w(TAG, "live_pip ${call.method} failed: ${error.message}", error)
                            // 契约要求「不抛异常、返回明确的降级结果」：失败一律给 false/null，
                            // 让上层回落到 App 内小窗。
                            when (call.method) {
                                "isSupported", "isInPip", "enterPip", "openOverlaySettings" ->
                                    result.success(false)
                                "showBall", "showLiveWindow" -> result.success(
                                    AylaFloatingBallController.RESULT_FAILED,
                                )
                                "updateBall", "updateLiveWindow" -> result.success(false)
                                else -> result.success(null)
                            }
                        }
                    }
                }
    }

    /**
     * 把音频会话压回「媒体播放」语义（幂等）。
     *
     * 只做三件工程事实：设置系统音频模式、设置输出路由、申请媒体焦点。
     * 任何一步失败都只影响该步，不抛出（返回的 Map 里带实际读回值供断言）。
     */
    @Suppress("DEPRECATION")
    private fun applyMediaMode(): Map<String, Any?> {
        val audioManager = audioManager()
            ?: return mapOf("ok" to false, "reason" to "AudioManager unavailable")

        val modeBefore = audioManager.mode

        // 1) 音频模式：媒体 = MODE_NORMAL；通话/听筒语义 = MODE_IN_COMMUNICATION。
        setModeSafely(audioManager, AudioManager.MODE_NORMAL)

        // 2) 输出路由：有耳机就不动外放（媒体路由天然走耳机），无耳机才强制外放。
        val headset = detectHeadset(audioManager)
        val speakerForced = !headset.present
        try {
            audioManager.isSpeakerphoneOn = speakerForced
        } catch (error: Exception) {
            Log.w(TAG, "setSpeakerphoneOn failed: ${error.message}")
        }

        // 3) 媒体焦点：USAGE_MEDIA + CONTENT_TYPE_SPEECH 的 AUDIOFOCUS_GAIN。
        val focusGranted = ensureMediaFocus(audioManager)

        // 4) 音量键语义兜底：本 Activity 的窗口建议音量键调媒体流。
        try {
            volumeControlStream = AudioManager.STREAM_MUSIC
        } catch (error: Exception) {
            Log.w(TAG, "setVolumeControlStream failed: ${error.message}")
        }

        mediaSessionApplied = true
        val state = readMediaModeState(audioManager)
        state["ok"] = true
        state["modeBefore"] = modeToString(modeBefore)
        state["focusGranted"] = focusGranted
        state["speakerForced"] = speakerForced
        Log.i(
            TAG,
            "media route applied: mode=${state["mode"]} focus=$focusGranted " +
                "speaker=$speakerForced headset=${headset.present}(${headset.kind}) " +
                "musicVol=${state["streamMusicVolume"]} voiceCallVol=${state["streamVoiceCallVolume"]}",
        )
        return state
    }

    /** 只读：当前音频模式 / 外放 / 音量（诊断与 Dart 侧断言用）。 */
    @Suppress("DEPRECATION")
    private fun readMediaModeState(): Map<String, Any?> {
        val audioManager = audioManager()
            ?: return mapOf("ok" to false, "reason" to "AudioManager unavailable")
        return readMediaModeState(audioManager)
    }

    /** 只读：当前音频模式 / 外放 / 音量（给定 AudioManager，调用方已确保非空）。 */
    @Suppress("DEPRECATION")
    private fun readMediaModeState(audioManager: AudioManager): MutableMap<String, Any?> {
        val headset = detectHeadset(audioManager)
        return mutableMapOf(
            "mode" to modeToString(audioManager.mode),
            "modeInt" to audioManager.mode,
            "speakerOn" to audioManager.isSpeakerphoneOn,
            "headset" to headset.present,
            "headsetKind" to headset.kind,
            "streamMusicVolume" to audioManager.getStreamVolume(AudioManager.STREAM_MUSIC),
            "streamMusicMaxVolume" to audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
            "streamVoiceCallVolume" to audioManager.getStreamVolume(AudioManager.STREAM_VOICE_CALL),
            "outputDevice" to currentOutputDeviceName(audioManager),
        )
    }

    private fun audioManager(): AudioManager? =
        getSystemService(Context.AUDIO_SERVICE) as? AudioManager

    private fun setModeSafely(audioManager: AudioManager, mode: Int) {
        if (audioManager.mode == mode) return
        try {
            @Suppress("DEPRECATION")
            audioManager.mode = mode
        } catch (error: Exception) {
            Log.w(TAG, "setMode($mode) failed: ${error.message}")
        }
    }

    private fun mediaAudioAttributes(): AudioAttributes =
        AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()

    /** 申请媒体焦点；已持有同一请求时重复申请是幂等的。 */
    @Suppress("DEPRECATION")
    private fun ensureMediaFocus(audioManager: AudioManager): Boolean {
        val listener = mediaFocusListener
            ?: AudioManager.OnAudioFocusChangeListener { change -> onMediaFocusChange(change) }
                .also { mediaFocusListener = it }
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val request = mediaFocusRequest
                    ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                        .setAudioAttributes(mediaAudioAttributes())
                        .setAcceptsDelayedFocusGain(false)
                        .setWillPauseWhenDucked(false)
                        .setOnAudioFocusChangeListener(listener, mainHandler)
                        .build()
                        .also { mediaFocusRequest = it }
                audioManager.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            } else {
                audioManager.requestAudioFocus(
                    listener,
                    AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN,
                ) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            }
        } catch (error: Exception) {
            Log.w(TAG, "requestAudioFocus failed: ${error.message}")
            false
        }
    }

    /**
     * 焦点变化：**被别的应用/通话短暂打断结束后重施媒体模式**。
     *
     * 系统在焦点被通话占用期间会把 audio mode 改成 MODE_IN_COMMUNICATION，
     * 通话结束后不会自动恢复；这里在 GAIN 回来时压回媒体语义。
     * 永久 LOSS 不抢回焦点（避免与其它应用互抢），等下一次显式 apply。
     */
    private fun onMediaFocusChange(change: Int) {
        when (change) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                if (mediaFocusLost) {
                    mediaFocusLost = false
                    mainHandler.post { reapplyMediaSession() }
                }
            }
            AudioManager.AUDIOFOCUS_LOSS,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> mediaFocusLost = true
            else -> Unit
        }
    }

    /** 焦点恢复后重施媒体会话（mode / 外放 / 焦点三件套）。 */
    @Suppress("DEPRECATION")
    private fun reapplyMediaSession() {
        if (!mediaSessionApplied) return
        val audioManager = audioManager() ?: return
        setModeSafely(audioManager, AudioManager.MODE_NORMAL)
        val headset = detectHeadset(audioManager)
        try {
            audioManager.isSpeakerphoneOn = !headset.present
        } catch (error: Exception) {
            Log.w(TAG, "reapply setSpeakerphoneOn failed: ${error.message}")
        }
        val granted = ensureMediaFocus(audioManager)
        Log.i(
            TAG,
            "media session re-applied after focus gain: mode=${modeToString(audioManager.mode)} " +
                "focus=$granted speaker=${!headset.present}",
        )
    }

    /** 有线/蓝牙/USB 耳机检测结果。 */
    private data class HeadsetStatus(val present: Boolean, val kind: String)

    /**
     * 检测是否接着耳机（有线 / USB / 蓝牙 A2DP·SCO·BLE / 助听器）。
     *
     * 以 AudioDeviceInfo 枚举为准（A2DP 在旧版本 isBluetoothA2dpOn 上常误报 false），
     * 并用已废弃的 isWiredHeadsetOn / isBluetoothA2dpOn 做兼容兜底。
     */
    @Suppress("DEPRECATION")
    private fun detectHeadset(audioManager: AudioManager): HeadsetStatus {
        val kinds = LinkedHashSet<String>()
        try {
            for (device in audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
                when (device.type) {
                    AudioDeviceInfo.TYPE_WIRED_HEADSET -> kinds.add("wired-headset")
                    AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> kinds.add("wired-headphones")
                    AudioDeviceInfo.TYPE_USB_HEADSET -> kinds.add("usb-headset")
                    AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> kinds.add("bluetooth-a2dp")
                    AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> kinds.add("bluetooth-sco")
                    AudioDeviceInfo.TYPE_HEARING_AID -> kinds.add("hearing-aid")
                    AudioDeviceInfo.TYPE_BLE_HEADSET -> kinds.add("ble-headset")
                    else -> Unit
                }
            }
        } catch (error: Exception) {
            Log.w(TAG, "getDevices(GET_DEVICES_OUTPUTS) failed: ${error.message}")
        }
        try {
            if (audioManager.isWiredHeadsetOn) kinds.add("wired-headset")
            if (audioManager.isBluetoothA2dpOn) kinds.add("bluetooth-a2dp")
        } catch (error: Exception) {
            Log.w(TAG, "legacy headset flags failed: ${error.message}")
        }
        return HeadsetStatus(kinds.isNotEmpty(), kinds.joinToString("+"))
    }

    private fun currentOutputDeviceName(audioManager: AudioManager): String {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val device = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                    .firstOrNull { it.isSink }
                device?.productName?.toString() ?: "unknown"
            } else {
                "unknown"
            }
        } catch (error: Exception) {
            "unknown"
        }
    }

    private fun modeToString(mode: Int): String = when (mode) {
        AudioManager.MODE_NORMAL -> "MODE_NORMAL"
        AudioManager.MODE_RINGTONE -> "MODE_RINGTONE"
        AudioManager.MODE_IN_CALL -> "MODE_IN_CALL"
        AudioManager.MODE_IN_COMMUNICATION -> "MODE_IN_COMMUNICATION"
        AudioManager.MODE_CALL_SCREENING -> "MODE_CALL_SCREENING"
        else -> "MODE_$mode"
    }


    /**
     * 跳「显示在其他应用上层」授权页（通道 `openOverlaySettings`）。
     *
     * 悬浮球是唯一消费方。无运行时弹窗，只能跳设置；
     * 返回 true = 已跳转（**不**代表用户已授权）。
     *
     * ⚠️ 2026-11-01：系统 PiP 已整体删除，但这个方法是**悬浮球权限**用的，
     * 与 PiP 无关，故保留（早前它在 PiP 那一节末尾，删除时被一并带走，现已补回）。
     */
    private fun openOverlaySettings(): Boolean =
        AylaFloatingBallController.openOverlaySettings(this)

    // ======================= 系统层悬浮球（语音/直播会话脱离应用）=======================

    /**
     * 叠加层宿主（懒创建；**单实例**，重复 `showBall` 复用同一个窗口 + 同一个引擎）。
     *
     * ## 它是什么
     * 第二 FlutterEngine + FlutterView 塞进 `WindowManager` 的
     * `TYPE_APPLICATION_OVERLAY` 窗口，里面 build **同一份**
     * `AylaSessionActivityIndicator`（`lib/widgets/shell/session_activity.dart`）。
     * **原生侧一行绘制代码都没有** —— 上一版手绘圆球被用户判定「丑得要命」，
     * 这一版换的只是**宿主窗口**，widget 树是同一份代码。
     *
     * 回调语义：
     * - `onBallTap` → 原生回调 Dart `onBallTap{kind, sourceRoute}`（Dart 侧 `context.go` 回房）。
     * 只是**导航投影**，不参与任何内容或认知判断。
     */
    private val overlayBall: AylaOverlayFlutterHost by lazy {
        AylaOverlayFlutterHost(
            applicationContext,
            onBallTap = { kind, sourceRoute ->
                mainHandler.post {
                    livePipChannel?.invokeMethod(
                        "onBallTap",
                        mapOf("kind" to kind, "sourceRoute" to sourceRoute),
                    )
                }
            },
            // 点球**先**把 App 拉到前台，再转发导航（用户实报「App 在后台时点球唤不醒」）。
            onBringToFront = { bringAppToFront() },
        )
    }

    /**
     * 系统层**直播小窗**宿主（懒创建；单实例，重复 `showLiveWindow` 复用同一个窗口 + 引擎）。
     *
     * ## 它是什么
     * 第二 FlutterEngine + FlutterView 塞进 `TYPE_APPLICATION_OVERLAY` 窗口，里面 build
     * **同一份** `AylaLiveMiniPlayer`（App 内那张 168×94 卡片本身）。
     * 与悬浮球宿主的关键差别：这里**要**注册 video_player 插件（否则放不了视频），
     * 但**只注册它一个**（不重复起 livekit / record 那套媒体栈）。
     *
     * ## 为什么不用 media_kit
     * 工程只打包了 `media_kit_libs_windows_video`（pubspec.yaml：「Android/iOS 上没有 libmpv」）
     * ⇒ 在 Android 上必然黑屏。Android 侧与主引擎同一条路径：video_player / ExoPlayer。
     */
    private val liveOverlay: AylaLiveOverlayFlutterHost by lazy {
        AylaLiveOverlayFlutterHost(
            applicationContext,
            onBringToFront = { bringAppToFront() },
            // 用户点小窗上的关闭键 ⇒ 告诉主引擎「窗口没了」，它据此把 App 内播放器重新接上。
            onClosed = {
                mainHandler.post {
                    livePipChannel?.invokeMethod("onLiveWindowClosed", null)
                }
            },
        )
    }

    /**
     * 通道 `showBall`：让悬浮球脱离应用（压在其他 App 之上）。
     *
     * 参数 `{kind, sessionId, title, sourceRoute, payload}`。
     * [payload] 是主引擎算好的**整组投影**（`AylaOverlayPayload.encode()` 的 JSON 串）——
     * 第二引擎没有登录态 / store，会话集合只能由主引擎推过来。
     * 返回值见 [AylaOverlayFlutterHost.show]。
     * 幂等：已有窗口时只更新投影，不重复 addView / 不重建引擎。
     */
    private fun showBall(call: MethodCall): String =
        overlayBall.show(call.argument<String>("payload"))

    /**
     * 通道 `updateBall`：只更新投影（窗口已开时不重建 engine）。
     *
     * 返回 true = 已送达；false = 当前没有窗口（Dart 侧据此改走 `showBall` 重开）。
     */
    private fun updateBall(call: MethodCall): Boolean =
        overlayBall.update(call.argument<String>("payload"))

    /**
     * 通道 `showLiveWindow`：把直播小窗放到系统层（压在其他 App 之上）。
     *
     * 参数 `{playUrl, title}`。返回值与悬浮球同一套字面量
     * （"shown" / "permissionRequired" / "unsupported" / "failed"）。
     * 幂等：已有窗口时只更新地址，不重复 addView / 不重建引擎。
     */
    private fun showLiveWindow(call: MethodCall): String =
        liveOverlay.show(
            call.argument<String>("playUrl"),
            call.argument<String>("title"),
        )

    /** 通道 `updateLiveWindow`：只更新地址/标题（切台）。返回 false = 当前没有窗口。 */
    private fun updateLiveWindow(call: MethodCall): Boolean =
        liveOverlay.update(
            call.argument<String>("playUrl"),
            call.argument<String>("title"),
        )

    /**
     * 把主 Activity 拉到前台。
     *
     * ## 为什么必须原生做（用户实报「Ayla 在后台时点悬浮球叫不出 App」）
     * 点球时球窗是**另一个 engine、另一个窗口**，主 Activity 可能已经 STOPPED；
     * Dart 侧收到通道回调只会在**自己的引擎**里执行 `context.go` —— 那不会把
     * 已经退到后台的进程/任务切到前台（也不该由 UI 层做这件事）。
     * ⇒ 原生用 `FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_REORDER_TO_FRONT` 重新唤起，
     * 已存在任务时**复用**它（`launchMode="singleTop"` + `onNewIntent`），不新建。
     *
     * 幂等：Activity 已在前台时该调用只是把任务重新置前，无副作用。
     */
    private fun bringAppToFront() {
        try {
            val intent = Intent(this, MainActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP,
                )
            }
            startActivity(intent)
        } catch (error: Exception) {
            Log.w(TAG, "bringAppToFront failed: ${error.message}", error)
        }
    }

    /**
     * 复用到已存在的任务（`singleTop` + `REORDER_TO_FRONT` 会走这里）。
     *
     * 目前没有额外动作：`onResume` 会照常触发，Dart 侧的路由跳转由
     * `onBallTap` 通道承担。显式覆写是为了留下**契约位置** ——
     * 将来若需要携带深链（例如从通知点进某个会话），入口就在这里。
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }


    override fun onResume() {
        super.onResume()
        activityResumed = true
    }

    override fun onPause() {
        activityResumed = false
        // ⇒ 自动进入的唯一开关就是 [liveSessionActive]（由 Dart 侧的 setSessionActive 维护）。
        super.onPause()
    }

    override fun onDestroy() {
        abandonMediaFocus()
        // 悬浮球**不在这里 hide**：它存在的意义就是「App 界面没了、球还在」。
        // 真正的清理点是 Dart 侧会话结束（`aylaHideDetachedBall`，经 Activity 重建后的
        // 新通道实例送达）与用户从系统层关掉它（`onBallClosed`）。
        // 只把通道句柄置空，避免已经销毁的 messenger 被回调。
        livePipChannel = null
        super.onDestroy()
    }

    /** 释放媒体焦点（Activity 销毁时；幂等）。 */
    @Suppress("DEPRECATION")
    private fun abandonMediaFocus() {
        val audioManager = audioManager() ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                mediaFocusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
            } else {
                mediaFocusListener?.let { audioManager.abandonAudioFocus(it) }
            }
        } catch (error: Exception) {
            Log.w(TAG, "abandonAudioFocus failed: ${error.message}")
        }
        mediaFocusLost = false
    }

    private fun installApk(path: String): Boolean {
        val file = File(path).canonicalFile
        val cacheRoot = cacheDir.canonicalFile
        if (!file.exists() || !file.isFile) return false
        if (!file.path.startsWith(cacheRoot.path + File.separator)) return false
        val authority = "$packageName.fileprovider"
        val uri: Uri = try {
            FileProvider.getUriForFile(this, authority, file)
        } catch (_: IllegalArgumentException) {
            // provider 未声明（旧工程）：明确返回 false，让 Dart 侧走下载页兜底。
            return false
        }
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            intent.putExtra(Intent.EXTRA_NOT_UNKNOWN_SOURCE, true)
        }
        startActivity(intent)
        return true
    }

    companion object {
        private const val TAG = "AylaAudioRoute"
    }
}
