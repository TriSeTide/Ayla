package com.ayla.ayla_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * 语音 / 直播会话的**系统层叠加层**（脱离应用后用）—— 常量与权限入口 + 保活服务。
 *
 * ## 2026-10-31 重做（用户验收否决了上一版）
 * 上一版在这里用 [android.graphics.Canvas] 手绘了一个 44dp 圆球（`BallGlyphView`），
 * 用户原话：「**丑得要命**」「**不要造轮子！用现有的悬浮球和直播小窗**」「**南辕北辙**」。
 * ⇒ **手绘 View 全部删除**。真正的球由 [AylaOverlayFlutterHost] 用
 * **第二 FlutterEngine + FlutterView** build **同一份** `AylaSessionActivityIndicator`
 * widget 来画（视觉/交互与 App 内完全一致）。
 *
 * ## 本文件现在只留两样东西
 * 1. **结果字符串常量**（`"shown"` / `"permissionRequired"` / `"unsupported"` / `"failed"`）
 *    —— 与 Dart 侧 `AylaDetachedBallResult` 逐字对齐，两个原生实现（本宿主 + Windows）共用；
 * 2. **[AylaFloatingBallService]** —— 前台服务，把进程钉住。
 *    叠加层随进程存活；进程被系统回收后球直接消失。前台服务同时给用户一个可见的
 *    「还在挂着会话」通知条（Android 的硬性要求，不是可以省掉的噪音）。
 *
 * ## 为什么是 `mediaPlayback`
 * 会话本身就是语音/直播媒体；`dataSync`（现有下载服务用的）在 Android 15 有
 * 6 小时 / 24 小时上限（`Service.onTimeout`），且语义不符。
 * 声明要求：`FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MEDIA_PLAYBACK` +
 * `android:foregroundServiceType="mediaPlayback"`（见 AndroidManifest.xml）。
 *
 * ## 权限
 * `SYSTEM_ALERT_WINDOW` 是特殊权限，**没有运行时弹窗**，只能跳
 * `Settings.ACTION_MANAGE_OVERLAY_PERMISSION`。未授权时 [AylaOverlayFlutterHost.show]
 * 明确返回 `"permissionRequired"`，**不静默失败**（「功能没反应」是本项目反复实报的问题类型）。
 */
object AylaFloatingBallController {
    private const val TAG = "AylaFloatingBall"

    const val KIND_VOICE = "voice"
    const val KIND_LIVE = "live"

    const val RESULT_SHOWN = "shown"
    const val RESULT_PERMISSION_REQUIRED = "permissionRequired"
    const val RESULT_UNSUPPORTED = "unsupported"
    const val RESULT_FAILED = "failed"

    /**
     * 跳系统「显示在其他应用上层」授权页。
     *
     * 没有运行时权限弹窗，这是**唯一**授权入口。返回 true = 已跳转；
     * 调用方不得假设用户真的打开了开关（用户可能直接返回）。
     */
    fun openOverlaySettings(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        return try {
            val intent = Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:${context.packageName}"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } catch (error: Exception) {
            Log.w(TAG, "open overlay settings failed: ${error.message}", error)
            false
        }
    }
}

/**
 * 叠加层的保活前台服务（进程钉住 + 可见通知条）。
 *
 * **必须在 App 仍处于前台时启动**（Android 12+ 后台起 FGS 会抛
 * `ForegroundServiceStartNotAllowedException`）—— 唯一调用点是
 * [AylaOverlayFlutterHost.show]，由 UI 手势触发，天然满足。
 */
class AylaFloatingBallService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Android 14+ 要求先 startForeground 才允许后续操作；类型已在 manifest 声明。
        // 任何一步失败都只记录日志（球本体仍可用），不崩溃。
        try {
            startForeground(NOTIFICATION_ID, buildNotification())
        } catch (error: Exception) {
            Log.w(TAG, "startForeground failed: ${error.message}", error)
        }
        return START_STICKY
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        if (manager != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "语音 / 直播悬浮球",
                // LOW：不出声、不弹横幅，只在通知栏留一条（用户随时能看到还在挂着会话）。
                NotificationManager.IMPORTANCE_LOW,
            ).apply { description = "会话脱离应用后保持悬浮球可用" }
            manager.createNotificationChannel(channel)
        }
        // 点通知 = 回 App（与点球同一条落点：主 Activity）。
        val launch = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val pending = PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Ayla 会话悬浮球")
            .setContentText("语音 / 直播会话已在系统层保持，点球回房")
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(pending)
            .build()
    }

    companion object {
        private const val TAG = "AylaFloatingBallSvc"
        private const val CHANNEL_ID = "ayla_floating_ball"
        private const val NOTIFICATION_ID = 0x41594C41 // 'AYLA'

        /**
         * 启动保活服务。
         *
         * ⚠️ 必须由**仍在前台**的 App 调用（Android 12+ 后台起 FGS 抛
         * `ForegroundServiceStartNotAllowedException`）；唯一调用点是
         * [AylaOverlayFlutterHost.show]，由 UI 手势触发。
         */
        fun start(context: Context) {
            try {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, AylaFloatingBallService::class.java),
                )
            } catch (error: Exception) {
                // 后台起 FGS 被拒是**预期**分支（某些 ROM 的手势路径），
                // 记日志并继续：球本体仍能显示，只是进程可能被回收。
                Log.w(TAG, "startForegroundService failed: ${error.message}", error)
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, AylaFloatingBallService::class.java))
            } catch (error: Exception) {
                Log.w(TAG, "stopService failed: ${error.message}")
            }
        }
    }
}
