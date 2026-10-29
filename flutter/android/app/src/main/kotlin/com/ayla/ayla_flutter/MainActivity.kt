package com.ayla.ayla_flutter

import android.app.PendingIntent
import android.app.PictureInPictureParams
// PictureInPictureUiState 只在 API 33+ 存在：不能用普通 import（minSdk 更低时
// 类校验/混淆阶段会找不到符号），故在 onPictureInPictureUiStateChanged 里用全限定名。
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Rect
import android.graphics.drawable.Icon
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
import android.util.Rational
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

    // ======================= Android PiP（直播脱离应用）状态 =======================

    /**
     * Dart 侧当前是否有**正在进行的直播会话**（由 [setSessionActive] 维护）。
     *
     * 只有它为 true 时才武装自动进 PiP，否则用户在任意页面按 Home 都会弹出 PiP —— 那是错的。
     * ⚠️ 进入 PiP 的**唯一**判据是本标志 + 当前在 RESUMED，不参与任何内容/认知判断。
     */
    private var liveSessionActive = false

    /** 系统是否处于 PiP 中（[onPictureInPictureModeChanged] 维护）。 */
    private var inPipMode = false

    /**
     * API 35+ 的「正在转场到 PiP」预信号（[onPictureInPictureUiStateChanged] 维护）。
     *
     * 用于让 Flutter 侧**提前**把 UI 切成纯视频树（否则转场动画里会看到整屏 App UI 缩下去）。
     */
    private var transitioningToPip = false

    /** 上一次回传给 Dart 的「需要纯视频树」状态（去抖，避免每帧重复 invoke）。 */
    private var pipUiActiveLast = false

    /** Activity 是否处于 RESUMED（自己维护，避免依赖 embedding 的 LifecycleOwner 形态）。 */
    private var activityResumed = false

    /** 上一次设置的 PiP 比例；null = 尚未设置过（重复设置同一比例是无意义的系统调用）。 */
    private var pipAspect: Rational? = null

    /** 最近一次 Dart 传来的 sourceRectHint（视频在屏幕上的位置）。 */
    private var pipSourceRect: Rect? = null

    /** Android 12+ PiP 菜单里的「关闭直播」动作广播接收器（动态注册，需在 onDestroy 注销）。 */
    private var pipActionReceiver: BroadcastReceiver? = null

    /** 「关闭直播」动作的请求码（PendingIntent 身份）。 */
    private val pipCloseActionRequestCode = 4310

    /** 「关闭直播」广播 action（本包私有；接收器 NOT_EXPORTED 注册）。 */
    private val pipCloseAction = "com.ayla.ayla_flutter.action.PIP_CLOSE"

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
                                "isSupported" -> result.success(isPipSupported())
                                "isInPip" -> result.success(inPipMode)
                                "enterPip" -> result.success(enterPip(call))
                                "setSessionActive" -> {
                                    setSessionActive(call.argument<Boolean>("active") == true)
                                    result.success(null)
                                }
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
                                else -> result.notImplemented()
                            }
                        } catch (error: Exception) {
                            Log.w(TAG, "live_pip ${call.method} failed: ${error.message}", error)
                            // 契约要求「不抛异常、返回明确的降级结果」：失败一律给 false/null，
                            // 让上层回落到 App 内小窗。
                            when (call.method) {
                                "isSupported", "isInPip", "enterPip", "openOverlaySettings" ->
                                    result.success(false)
                                "showBall" -> result.success(
                                    AylaFloatingBallController.RESULT_FAILED,
                                )
                                "updateBall" -> result.success(false)
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


    // ======================= Android PiP 实现 =======================

    /**
     * 本设备/本 Activity 是否**真的**能进 PiP。
     *
     * 判据只有两条工程事实：系统特性 [PackageManager.FEATURE_PICTURE_IN_PICTURE] 存在，
     * 且 [Build.VERSION] ≥ O（PiP 从 API 26 起才有）。低内存设备可能关闭该特性 ⇒ 必须运行时探测，
     * 不能只看 Manifest 声明。
     */
    private fun isPipSupported(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
    }

    /**
     * 用户手势触发进入 PiP（通道 `enterPip`）。
     *
     * ⚠️ 官方约束：`enterPictureInPictureMode()` 要求 Activity 处于 **RESUMED**，
     * 否则抛 `IllegalStateException`。所以本方法**只能由 UI 手势**调用（小窗上的脱离键）；
     * 「按 Home 自动进 PiP」走 [onUserLeaveHint] / setAutoEnterEnabled，不经过这里。
     *
     * 返回值语义（Dart 侧据此决定是否回落到 App 内小窗）：
     * true = 已进入或本来就在 PiP；false = 不支持 / 不在前台 / 系统拒绝。
     */
    private fun enterPip(call: MethodCall): Boolean {
        if (!isPipSupported()) return false
        if (inPipMode) return true
        if (isFinishing || isDestroyed) return false
        // 必须在 RESUMED：非前台调用系统必抛 IllegalStateException（契约文件头已登记该约束）。
        if (!activityResumed) {
            Log.w(TAG, "enterPip rejected: activity not resumed")
            return false
        }
        readPipRect(call)
        rememberAspect(
            call.argument<Int>("aspectX") ?: 16,
            call.argument<Int>("aspectY") ?: 9,
        )
        val params = buildPipParams() ?: return false
        return try {
            enterPictureInPictureMode(params)
        } catch (error: IllegalStateException) {
            Log.w(TAG, "enterPictureInPictureMode failed: ${error.message}")
            false
        } catch (error: RuntimeException) {
            // 部分 OEM 在比例不合法时抛 RuntimeException（契约已要求 clamp 1:2.39–2.39:1）。
            Log.w(TAG, "enterPictureInPictureMode runtime failed: ${error.message}")
            false
        }
    }

    /**
     * 直播会话活跃态（通道 `setSessionActive`）。
     *
     * 它只回答一个问题：「现在按 Home 该不该自动进 PiP」。为 true 时在 RESUMED 期间
     * 预先武装 setAutoEnterEnabled（API 31+），低版本由 [onUserLeaveHint] 兜底。
     * 关掉时必须**立刻**撤销武装，否则用户在别的页面按 Home 会误进 PiP。
     */
    private fun setSessionActive(active: Boolean) {
        val changed = liveSessionActive != active
        liveSessionActive = active
        if (!active) {
            // 撤销武装 + 清 sourceRectHint（下一次直播重新给）。
            pipSourceRect = null
        }
        // ⚠️ **撤销必须尽力而为地立即生效**，不能只看 resumed：
        // 会话可能在 Activity 非前台时结束（PiP 里点关闭、页面被销毁）——
        // 若这时跳过 setPictureInPictureParams，系统里仍留着 autoEnterEnabled=true，
        // 用户下次按 Home 会**误进** PiP。所以这里无条件尝试一次（失败只记日志，
        // 下一条 onResume 的 armAutoEnter 会按当时的 liveSessionActive 再校正）。
        if (!active && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try {
                setPictureInPictureParams(
                    PictureInPictureParams.Builder().setAutoEnterEnabled(false).build(),
                )
            } catch (error: RuntimeException) {
                Log.w(TAG, "disarmAutoEnter failed: ${error.message}")
            }
        }
        if (changed) armAutoEnter()
    }

    /**
     * 按「是否在直播中 + 是否已在 PiP 里」武装/撤销自动进入。
     *
     * API 31+ 只能通过 setPictureInPictureParams 的 setAutoEnterEnabled 表达「按 Home 自动进」；
     * 设置动作本身要求 Activity 在前台，故 [onResume] 与 [setSessionActive] 都要调一次。
     */
    private fun armAutoEnter() {
        if (!isPipSupported()) return
        if (inPipMode) return
        // 系统尚未把窗口交给前台时设置参数会抛 IllegalStateException：非 RESUMED 直接跳过，
        // onResume 会补上（这也是「必须在前台武装」的落地方式）。
        if (!activityResumed) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return // <31 由 onUserLeaveHint 兜底
        val params = buildPipParams() ?: return
        try {
            setPictureInPictureParams(params)
        } catch (error: RuntimeException) {
            Log.w(TAG, "armAutoEnter failed: ${error.message}")
        }
    }

    /** 解析 Dart 传来的 sourceRectHint（视频在屏幕上的位置）；缺字段则清空。 */
    private fun readPipRect(call: MethodCall) {
        val x = call.argument<Int>("x")
        val y = call.argument<Int>("y")
        val w = call.argument<Int>("w")
        val h = call.argument<Int>("h")
        pipSourceRect = if (x != null && y != null && w != null && h != null && w > 0 && h > 0) {
            Rect(x, y, x + w, y + h)
        } else {
            null
        }
    }

    /**
     * 组装 PiP 参数：比例（已 clamp）+ sourceRectHint + 自动进入标志 + 「关闭直播」动作。
     *
     * 比例必须落在 1:2.39 ~ 2.39:1：部分 OEM 对越界比例抛
     * `RationalNotMatchingAndroidRequirementsException`（契约文件头已登记）。
     */
    private fun buildPipParams(): PictureInPictureParams? {
        if (!isPipSupported()) return null
        return try {
            val builder = PictureInPictureParams.Builder()
            pipAspect?.let { builder.setAspectRatio(it) }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                pipSourceRect?.let { rect ->
                    if (!rect.isEmpty) builder.setSourceRectHint(rect)
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                builder.setAutoEnterEnabled(liveSessionActive)
                // 转场更顺（12+）：从 sourceRectHint 长出小窗，而不是硬切。
                builder.setSeamlessResizeEnabled(true)
            }
            pipCloseRemoteAction()?.let { builder.setActions(listOf(it)) }
            builder.build()
        } catch (error: RuntimeException) {
            Log.w(TAG, "buildPipParams failed: ${error.message}")
            null
        }
    }

    /** 把宽高比 clamp 进系统可接受区间并缓存（幂等：同一个 Rational 不重复设置）。 */
    private fun rememberAspect(aspectX: Int, aspectY: Int) {
        if (aspectX <= 0 || aspectY <= 0) return
        val min = 1.0 / 2.39
        val max = 2.39
        val raw = aspectX.toDouble() / aspectY.toDouble()
        val clamped = raw.coerceIn(min, max)
        val next = Rational((clamped * 1000).toInt(), 1000)
        if (pipAspect != next) pipAspect = next
    }

    /**
     * Android 12+ PiP 菜单里的「关闭直播」动作。
     *
     * ⚠️ 本工程**没有可用的 drawable 图标资源**，而 RemoteAction 必须带 Icon ⇒ 用代码画的
     * 自绘 Icon（不往仓库里塞二进制资源；契约/任务书的明确要求）。
     * 低版本（<31）没有 PiP 菜单，直接返回 null。
     */
    private fun pipCloseRemoteAction(): RemoteAction? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return null
        val receiver = pipActionReceiver ?: return null
        val icon = closeActionIcon() ?: return null
        val intent = Intent(pipCloseAction).setPackage(packageName)
        val pending = PendingIntent.getBroadcast(
            this,
            pipCloseActionRequestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return try {
            RemoteAction(icon, "关闭直播", "关闭直播", pending)
        } catch (error: RuntimeException) {
            Log.w(TAG, "RemoteAction failed: ${error.message}")
            null
        }
    }

    /** 用 ShapeDrawable 画一个「×」图标（无需 drawable 资源）。 */
    private fun closeActionIcon(): Icon? {
        return try {
            val size = 48
            val bitmap = android.graphics.Bitmap.createBitmap(
                size,
                size,
                android.graphics.Bitmap.Config.ARGB_8888,
            )
            val canvas = android.graphics.Canvas(bitmap)
            val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                color = android.graphics.Color.WHITE
                strokeWidth = 5f
                strokeCap = android.graphics.Paint.Cap.ROUND
            }
            val pad = 12f
            canvas.drawLine(pad, pad, size - pad, size - pad, paint)
            canvas.drawLine(size - pad, pad, pad, size - pad, paint)
            Icon.createWithBitmap(bitmap)
        } catch (error: Exception) {
            Log.w(TAG, "closeActionIcon failed: ${error.message}")
            null
        }
    }

    /** 动态注册「关闭直播」动作的接收器（NOT_EXPORTED：不暴露给其它应用）。 */
    private fun registerPipActionReceiver() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        if (pipActionReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action != pipCloseAction) return
                // 用户点「关闭直播」= 关闭整个 PiP 呈现：先通知 Dart（会话据此回落到 App 内小窗/
                // 或结束观看），再退出 PiP 回前台。
                livePipChannel?.invokeMethod("onPipChanged", false)
                liveSessionActive = false
                if (inPipMode) {
                    try {
                        moveTaskToBack(false)
                    } catch (error: Exception) {
                        Log.w(TAG, "moveTaskToBack failed: ${error.message}")
                    }
                }
            }
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(receiver, IntentFilter(pipCloseAction), Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                registerReceiver(receiver, IntentFilter(pipCloseAction))
            }
            pipActionReceiver = receiver
        } catch (error: Exception) {
            Log.w(TAG, "registerPipActionReceiver failed: ${error.message}")
        }
    }

    private fun unregisterPipActionReceiver() {
        val receiver = pipActionReceiver ?: return
        pipActionReceiver = null
        try {
            unregisterReceiver(receiver)
        } catch (error: Exception) {
            Log.w(TAG, "unregisterPipActionReceiver failed: ${error.message}")
        }
    }

    /**
     * 跳「显示在其他应用上层」授权页（通道 `openOverlaySettings`）。
     *
     * 悬浮球（task-5）是唯一消费方，但通道归本任务建 ⇒ 这里给**真实**实现（不做假）。
     * 无运行时弹窗，只能跳设置；返回 true = 已跳转（**不**代表用户已授权）。
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
     * PiP 形态变化（系统回调）。
     *
     * 回传两件事给 Dart：
     * - `onPipChanged(bool)`：是否在 PiP 里（Dart 侧据此把小窗 UI 切成纯视频树、并保证
     *   PiP 期间仍算「观看人」）；
     * - 纯视频树判据 [pipUiActive]：API 35+ 会在真正进入前先给 isTransitioningToPip 预信号，
     *   提前隐藏 App 的返回键/弹幕输入框，转场动画才好看。
     */
    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        inPipMode = isInPictureInPictureMode
        if (!isInPictureInPictureMode) transitioningToPip = false
        notifyPipUiState(force = true)
        Log.i(TAG, "pip mode changed: inPip=$isInPictureInPictureMode")
    }

    /**
     * API 33+：PiP UI 状态回调（`isTransitioningToPip` 是 API 35 才有的属性）。
     *
     * 提前把「纯视频树」信号发给 Dart：官方语义是转场动画开始前就能隐藏 App 的返回键/
     * 弹幕输入框，缩放动画里便不会出现整屏 App UI。
     * 参数类型用全限定名 —— `PictureInPictureUiState` 类本身只存在于 API 33+。
     */
    override fun onPictureInPictureUiStateChanged(
        pipState: android.app.PictureInPictureUiState,
    ) {
        super.onPictureInPictureUiStateChanged(pipState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            transitioningToPip = pipState.isTransitioningToPip
            notifyPipUiState()
        }
    }

    /** 「是否应当渲染纯视频树」= 已在 PiP 内，或（API 35+）正在转场进 PiP。 */
    private fun pipUiActive(): Boolean = inPipMode || transitioningToPip

    /**
     * 把 PiP 形态回传给 Dart（去抖：状态没变就不重复 invoke；[force] 绕过去抖用于模式切换）。
     *
     * ⚠️ 回调方法名必须与 Dart `AylaDetachedLiveEvents._handle` 的 `onPipChanged` 逐字一致。
     */
    private fun notifyPipUiState(force: Boolean = false) {
        val active = pipUiActive()
        if (!force && active == pipUiActiveLast) return
        pipUiActiveLast = active
        livePipChannel?.invokeMethod("onPipChanged", active)
    }

    /**
     * API 26–30 的「按 Home 自动进 PiP」兜底（31+ 由 setAutoEnterEnabled 承担）。
     *
     * 只有 [liveSessionActive] 为 true（Dart 明确说「正在直播」）时才动作 —— 否则用户在任意
     * 页面按 Home 都会弹 PiP。
     */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) return
        if (!liveSessionActive || inPipMode || !isPipSupported()) return
        val params = buildPipParams() ?: return
        try {
            enterPictureInPictureMode(params)
        } catch (error: IllegalStateException) {
            Log.w(TAG, "onUserLeaveHint enterPip failed: ${error.message}")
        } catch (error: RuntimeException) {
            Log.w(TAG, "onUserLeaveHint enterPip runtime failed: ${error.message}")
        }
    }

    override fun onResume() {
        super.onResume()
        activityResumed = true
        // 兜底复位转场标志：API 35 的 isTransitioningToPip 可能因为用户取消 / 系统中断
        // 而停在 true（我们随后没收到 onPictureInPictureModeChanged(true)）。
        // 不复位 ⇒ Dart 侧会永久停在「纯视频树」档，App 回到前台也是残缺 UI。
        if (!inPipMode && transitioningToPip) {
            transitioningToPip = false
            notifyPipUiState(force = true)
        }
        registerPipActionReceiver()
        // 回前台后重新武装（setPictureInPictureParams 要求在前台；进后台时系统会丢弃）。
        armAutoEnter()
    }

    override fun onPause() {
        activityResumed = false
        // ⚠️ 这里**故意不**撤销 setAutoEnterEnabled：
        //   · 自动进入只在这一屏「被 Home 键离开」时触发，从别的 App 回来不会把我们拽进 PiP；
        //   · 而 onPause 的时机与 PiP 转场重叠（API 31–34 没有 isTransitioningToPip 预信号），
        //     此时改参数会把正在生成的 PiP 窗口打断。
        // ⇒ 自动进入的唯一开关就是 [liveSessionActive]（由 Dart 侧的 setSessionActive 维护）。
        super.onPause()
    }

    override fun onDestroy() {
        abandonMediaFocus()
        unregisterPipActionReceiver()
        // 会话随 Activity 一起没了：撤销武装并如实把状态回给 Dart（避免「退出后仍算在 PiP」）。
        liveSessionActive = false
        inPipMode = false
        transitioningToPip = false
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
