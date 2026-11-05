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
import android.os.Handler
import android.os.IBinder
import android.os.Looper
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

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "onCreate")
    }

    /**
     * 进入前台（系统强制义务：startForegroundService 之后必须走到这里）。
     *
     * ## 为什么这是唯一的 startForeground 落地点（2026-11-05 崩溃修复）
     *
     * 崩溃原文（Android 16 模拟器，100% 复现）：
     * ForegroundServiceDidNotStartInTimeException: Context.startForegroundService()
     *   did not then call Service.startForeground(): ServiceRecord{... .AylaFloatingBallService}
     *
     * 真因是**竞态**（不是主线程慢）：start() 里 startForegroundService() 只是**排队**，
     * system_server 已经记下「这个服务必须转前台」的义务；紧接着同一条调用链上的
     * hide() -> stop() 把引用计数减到 0 => stopService()。此时服务**还没被创建**
     * （onCreate/onStartCommand 都没跑）=> 我们这边永远不会调 startForeground，
     * 而**系统侧的义务不会被 stopService 撤销** => 到点判超时并直接杀进程。
     * 系统日志写得很直白：
     *   Bringing down service while still waiting for start foreground
     *
     * => 修法：stop() 在「服务尚未真正 startForeground」时**不许**调 stopService，
     * 只置 [pendingStop]；本方法成功 startForeground 之后立刻收尾（见 onStartCommand）。
     * 这样「startForegroundService 之后一定执行过一次 startForeground」成为不变量。
     *
     * @return true = 已成功进入前台；false = 失败（已显式 stopSelf，不再等系统超时）
     */
    private fun promoteToForeground(): Boolean {
        if (foregroundStarted) return true
        val notification = try {
            buildNotification()
        } catch (error: Exception) {
            // 通知构造失败（资源缺失等）：也不能让系统超时，走失败收尾。
            Log.w(TAG, "buildNotification failed: ${error.message}", error)
            onForegroundFailed("buildNotification: ${error.message}")
            return false
        }
        return try {
            startForeground(NOTIFICATION_ID, notification)
            foregroundStarted = true
            Log.i(TAG, "startForeground ok")
            true
        } catch (error: Exception) {
            // 以前这里只打日志吞掉 => Dart 侧以为「球开好了」，而系统 10s 后杀进程。
            Log.w(TAG, "startForeground failed: ${error.message}", error)
            onForegroundFailed("startForeground: ${error.message}")
            false
        }
    }

    /**
     * 前台化失败 => **立刻自己收尾**，绝不留着让系统判超时杀进程。
     *
     * 走 stopSelf() 之后「startForegroundService 但没 startForeground」的系统义务
     * 依然会被结清（服务是正常结束，不是被提前拆掉），因此不会触发
     * ForegroundServiceDidNotStartInTimeException。
     */
    private fun onForegroundFailed(reason: String) {
        activeCount = 0
        pendingStop = false
        try {
            stopSelf()
        } catch (error: Exception) {
            Log.w(TAG, "stopSelf after foreground failure failed: ${error.message}")
        }
        // 回传宿主（它会收起窗口），否则用户只会看到「球在、进程被杀」。
        reportForegroundFailure(reason)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Android 14+ 要求先 startForeground 才允许后续操作；类型已在 manifest 声明。
        val ok = promoteToForeground()
        // ⚠️ 前台化失败 => **必须** START_NOT_STICKY。
        // 失败分支里已经 stopSelf()；若这里返回 START_STICKY，系统会在进程被杀后
        // **自动重建这个服务**，于是又产生一次「必须 startForeground」的义务 ——
        // 而我们没有任何宿主可能去满足它（窗口早就失败收掉了）⇒ 必然再崩一次。
        // 这条返回值的语义必须与「这次启动有没有真的成功」严格一致。
        if (!ok) {
            Log.w(TAG, "onStartCommand failed to enter foreground, not sticky")
            return START_NOT_STICKY
        }
        // 前台化期间宿主已经全关了（start 之后紧跟 stop 的同帧场景）=> 立刻收尾。
        // 必须排在 promoteToForeground **之后**：顺序反了又变成「先停后前台」。
        if (pendingStop) {
            Log.i(TAG, "pendingStop satisfied after startForeground")
            stopForegroundNow()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    /** 撤销前台态 + 停服务（幂等；只在已进入前台之后调用）。 */
    private fun stopForegroundNow() {
        pendingStop = false
        if (!foregroundStarted) return
        foregroundStarted = false
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (error: Exception) {
            Log.w(TAG, "stopForeground failed: ${error.message}")
        }
        try {
            stopSelf()
        } catch (error: Exception) {
            Log.w(TAG, "stopSelf failed: ${error.message}")
        }
    }

    override fun onDestroy() {
        // 服务实例没了 => 前台态随之作废。下一次 start() 会重新创建实例并
        // 走一遍 onStartCommand → startForeground（不变量在实例级别成立）。
        foregroundStarted = false
        super.onDestroy()
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


        /** 服务是否**已经真的**执行过 startForeground（系统义务是否已结清）。 */
        private var foregroundStarted = false

        /**
         * 「引用计数已归零，但服务还没 startForeground」=> 等前台化之后立刻收尾。
         *
         * 这是本次崩溃修复的核心状态位：它把「stopService」推迟到系统义务结清之后，
         * 否则就会出现系统侧的 "Bringing down service while still waiting for
         * start foreground" => ForegroundServiceDidNotStartInTimeException。
         */
        private var pendingStop = false

        /** 上一次前台化失败的原因（null = 没失败过；供 Dart 侧诊断）。 */
        private var foregroundFailedReason: String? = null

        /** 主线程 Handler（前台化失败回调的派发用）。 */
        private val mainHandler = Handler(Looper.getMainLooper())

        /**
         * 当前有几个宿主在用这个前台服务（悬浮球 / 直播小窗）。
         *
         * 两个宿主各自独立开关窗口，任何一方关窗都不该把另一方的保活一起停掉
         * （否则「球还在、直播声音却被系统冻结」）。用引用计数表达这件事。
         * 只在**主线程**读写（两个宿主的通道回调都在主线程）。
         */
        private var activeCount = 0

        /**
         * 启动保活服务（幂等；引用计数 +1）。
         *
         * ⚠️ 必须由**仍在前台**的 App 调用（Android 12+ 后台起 FGS 抛
         * `ForegroundServiceStartNotAllowedException`）；调用点是
         * [AylaOverlayFlutterHost.show] 与 [AylaLiveMiniWindowHost.show]，都由 UI 触发。
         */
        fun start(context: Context) {
            activeCount += 1
            // 有新宿主要用 => 撤销待停（同帧 start+stop 的反复抖动不该把服务弄死）。
            pendingStop = false
            if (activeCount > 1) return
            foregroundFailedReason = null
            // ⚠️⚠️ **下发新义务 => 义务立即处于「未结清」状态**（2026-11-05 二次修复）。
            //
            // 这是上一轮漏掉的关键一位。`foregroundStarted` 是**静态**标志，而
            // `context.stopService()` 是**异步**的：服务真正销毁（onDestroy 置回
            // false）之前有一段窗口，标志还停在上一轮的 true。
            // 若这段窗口里来一次 start()+stop()：
            //   · start() 已下发 startForegroundService（新义务挂上，服务还没创建）；
            //   · stop() 读到**过期的** true => 走 stopServiceNow => 在服务创建之前拆掉它
            //   · => 系统日志 "Bringing down service while still waiting for start foreground"
            //   · => 紧接着 ForegroundServiceDidNotStartInTimeException 杀进程。
            //
            // 实测证据（修复后仍复现的那次，同一进程）：
            //   10:47:37.565 Background started FGS: Allowed ...（新义务）
            //   10:47:38.168 Bringing down service ...（1.2s 后，服务尚未 onCreate）
            //   10:47:39.350 AylaFloatingBallSvc: onCreate   ← 服务这时才被创建
            //   10:47:39.448 startForeground ok            ← 但系统已经决定杀进程了
            //   => onCreate 晚于 Bringing down：拆服务发生在「义务结清」之前。
            //
            // 修法：真正下发 startForegroundService 的那一刻，把标志显式清零 ——
            // 「有没有结清」只由 onStartCommand 的 startForeground 成功来置真，
            // 绝不沿用上一轮实例的值。
            foregroundStarted = false
            try {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, AylaFloatingBallService::class.java),
                )
            } catch (error: Exception) {
                // 后台起 FGS 被拒是**预期**分支（某些 ROM 的手势路径），
                // 记日志并继续：窗口仍能显示，只是进程可能被回收。
                Log.w(TAG, "startForegroundService failed: ${error.message}", error)
                activeCount = (activeCount - 1).coerceAtLeast(0)
                foregroundFailedReason = "startForegroundService: ${error.message}"
            }
        }

        /**
         * 停止保活服务（引用计数 -1；归零才真的停）。
         *
         * ## 为什么不能直接 stopService（2026-11-05 崩溃根因）
         * 服务可能**还在排队等主线程创建**（startForegroundService 返回 ≠ 服务已创建）。
         * 此时直接 stopService 会得到：服务从未执行 startForeground，而系统侧的
         * 「必须转前台」义务仍在 => 10s 后 ForegroundServiceDidNotStartInTimeException
         * 直接杀进程（用户看到的就是「点进开播页直接闪退」）。
         *
         * 实测时序（模拟器，同一次点击内 99ms）：
         *   07:50:54.742 I ActivityManager: Background started FGS: Allowed [...AylaFloatingBallService]
         *   07:50:54.930 W ActivityManager: Bringing down service while still waiting for start foreground
         *   07:50:55.596 E AndroidRuntime: ForegroundServiceDidNotStartInTimeException
         *
         * => 归零时：已前台化就正常停；尚未前台化就只置 [pendingStop]，
         *    由 onStartCommand 在 startForeground 成功后立刻收尾。
         */
        fun stop(context: Context) {
            activeCount = (activeCount - 1).coerceAtLeast(0)
            if (activeCount > 0) return
            if (!foregroundStarted) {
                // 服务还没前台化（含「压根还没被创建」）：**不能停**。
                // 直接 stopService 会让系统侧的「必须转前台」义务永远无人结清
                // => 10s 后 ForegroundServiceDidNotStartInTimeException 杀进程。
                // 只置位，由 onStartCommand 在 startForeground 成功后立刻收尾。
                //
                // ⚠️ 不要加「N 秒后强制 stopService」的看门狗：若服务恰好在看门狗
                // 之后才被创建，就会出现「已 startForeground 但没人消费 pendingStop」
                // => 永久前台服务 + 常驻通知条的泄漏。pendingStop 只由 onStartCommand
                // 消费、或由下一次 [start] 重置 —— 这条不变量已足够。
                pendingStop = true
                Log.i(TAG, "stop deferred until startForeground (activeCount=0)")
                return
            }
            stopServiceNow(context)
        }

        private fun stopServiceNow(context: Context) {
            pendingStop = false
            // stopService() 是异步的（真正销毁要等主线程回到 Looper）；
            // 立刻把「已前台化」清零，避免下一个 start() 之前的窗口里读到过期 true。
            foregroundStarted = false
            try {
                context.stopService(Intent(context, AylaFloatingBallService::class.java))
            } catch (error: Exception) {
                Log.w(TAG, "stopService failed: ${error.message}")
            }
        }


        /** 直播小窗关窗用的别名（语义同 [stop]，保留可读性）。 */
        fun stopIfIdle(context: Context) = stop(context)

        /**
         * 供 [AylaOverlayFlutterHost] 判定「保活是否真的成功」。
         *
         * 前台化失败（含权限/通知/系统拒绝）时返回原因，调用方据此返回 `failed`，
         * 让 Dart 侧走明确失败分支（不再「球没出来 + 10s 后闪退」）。
         */
        fun foregroundFailure(): String? = foregroundFailedReason

        /** 上一次 [start] 之后服务是否已成功前台化（诊断用）。 */
        fun isForegroundReady(): Boolean = foregroundStarted

        /**
         * 前台化失败的监听（[AylaOverlayFlutterHost] / [AylaLiveMiniWindowHost] 注册）。
         *
         * 失败发生在系统回调里（onStartCommand），那时 show() 早就返回了 "shown"
         * => 只能由这个回调把「球其实没保活」这一事实回传给宿主，宿主立刻收起窗口，
         * 避免「球显示着、进程 10s 后被系统杀」这种既有假成功又有闪退的形态。
         */
        // ⚠️ 用**列表**而不是单值：悬浮球与直播小窗两个宿主可以同时存在，
        // 覆盖式会让后注册的那个静默顶掉前一个的回调。
        private val foregroundFailureListeners =
            mutableListOf<(String) -> Unit>()

        /** 登记前台化失败回调（宿主在 show() 时调用）。 */
        fun addForegroundFailureListener(listener: (String) -> Unit) {
            if (foregroundFailureListeners.contains(listener)) return
            foregroundFailureListeners.add(listener)
        }

        /** 注销前台化失败回调（宿主 hide() / 销毁时调用，避免泄漏）。 */
        fun removeForegroundFailureListener(listener: (String) -> Unit) {
            foregroundFailureListeners.remove(listener)
        }

        /** 把失败同时记进日志、回传全部宿主。 */
        fun reportForegroundFailure(reason: String) {
            foregroundFailedReason = reason
            val snapshot = foregroundFailureListeners.toList()
            // 宿主会做 removeView / destroy engine，必须回到主线程。
            mainHandler.post {
                for (listener in snapshot) {
                    try {
                        listener(reason)
                    } catch (error: Exception) {
                        Log.w(TAG, "foreground failure listener threw: ${error.message}")
                    }
                }
            }
        }
    }
}
