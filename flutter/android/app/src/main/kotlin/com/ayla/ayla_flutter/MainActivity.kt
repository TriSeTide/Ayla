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
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
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

    private val mainHandler = Handler(Looper.getMainLooper())

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

    override fun onDestroy() {
        abandonMediaFocus()
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
