package com.ayla.ayla_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.min

/**
 * 语音 / 直播会话的**系统层悬浮球**（脱离应用后用）。
 *
 * ## 为什么在原生侧
 * 用户要求「手机电脑语音直播浮层悬浮球（默认在右上角的那个）也要脱离应用」——
 * 离开 App 之后 Flutter 的渲染面已经看不到，球必须由系统窗口（
 * `WindowManager.addView` + [WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY]）承载。
 * **不为它起第二个 FlutterEngine**（研究结论：`flutter_floatwing` 证明可行，但会多一个
 * isolate + 多一条 WS，成本不值）⇒ 纯原生 View，点击只回传一次方法调用。
 *
 * ## 权限与窗口
 * - 需要 `SYSTEM_ALERT_WINDOW`（特殊权限，**没有运行时弹窗**，只能跳
 *   `Settings.ACTION_MANAGE_OVERLAY_PERMISSION`）。未授权时 [show] 明确返回
 *   `"permissionRequired"`，**不静默失败**（「功能没反应」是本项目反复实报的问题类型）。
 * - 窗口类型 **必须**是 [WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY]
 *   （API 26+；`TYPE_PHONE` 已废弃且被系统拒绝）。
 * - `FLAG_NOT_FOCUSABLE`：球不抢 IME / 返回键，否则用户在其他应用里打字会被球吞掉。
 * - `FLAG_LAYOUT_NO_LIMITS`：允许球拖到边缘之外一点点再弹回（拖动手感）。
 *
 * ## 保活
 * 叠加层本身在进程被回收后就会消失 ⇒ 用**前台服务** [AylaFloatingBallService] 兜住进程。
 * 复用现有 `dataSync` 下载服务是错的：Android 15 对 dataSync 有 6 小时 / 24 小时上限
 * （`Service.onTimeout`）；且语义不同。这里用 `mediaPlayback`（语音/直播会话本来就是
 * 媒体播放）。**必须在 App 仍处于前台时启动**（Android 12+ 后台起 FGS 会抛
 * `ForegroundServiceStartNotAllowedException`）—— [show] 只由 UI 手势触发，天然满足。
 *
 * ## 交互（与 Flutter 侧 `AylaSessionActivityIndicator` 的球对齐）
 * - 44dp 圆形，配色取 Flutter 的球色（语音 `--sakura-100`/`--grape-700`，
 *   直播 `--ice-300`/`--indigo-700`），1px 亮边 `#A6FFFFFF`；
 * - **可拖动**（`OnTouchListener` + `updateViewLayout`），松手夹回屏幕内；
 * - **点击** ⇒ [onBallTap]（Dart 侧 `context.go(sourceRoute)` 回房）；
 * - **长按** ⇒ 关闭球 + [onBallClosed]（Dart 侧复位「已脱离」标志）。
 *   之所以用长按而不是给球加一个小叉：44dp 的球里再塞关闭键会小于最小可点尺寸
 *   （Material 的 48dp 触摸目标），且 Flutter 侧的球本来就只有「点」。
 *
 * ## 资源纪律
 * **不新增任何图片 / vector 资源**：圆底用 [GradientDrawable] 代码画，图标字形用
 * [BallGlyphView] 的 Canvas 描边画（2px 描边 + 圆端点，与库内 Lucide 风格一致）。
 *
 * ## 线程
 * 所有方法都必须在**主线程**调用（`WindowManager.addView` 与 FGS 启动都要求）。
 * MainActivity 的 MethodChannel 回调天然在主线程。
 */
class AylaFloatingBallController(
    private val context: Context,
    private val onBallTap: (kind: String, sourceRoute: String) -> Unit,
    private val onBallClosed: () -> Unit,
) {
    private var windowManager: WindowManager? = null
    private var ballView: View? = null
    private var params: WindowManager.LayoutParams? = null

    private var kind: String = KIND_VOICE
    private var sessionId: String = ""
    private var title: String = ""
    private var sourceRoute: String = ""

    /** 是否已经有球（幂等判据）。 */
    val isShowing: Boolean
        get() = ballView != null

    /**
     * 显示 / 复用悬浮球。
     *
     * @return `"shown"` / `"permissionRequired"` / `"unsupported"` / `"failed"`
     *   —— 与 Dart 侧 `aylaShowDetachedBall` 的映射逐字对齐（见 detached_live.dart）。
     */
    fun show(kind: String, sessionId: String, title: String, sourceRoute: String): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            // TYPE_PHONE 在 API 26 以下才合法，但本项目 Android 目标最低也按 26 走 PiP 语义；
            // 明确降级而不是用已废弃窗口类型偷偷塞一个。
            return RESULT_UNSUPPORTED
        }
        if (!canDrawOverlays()) return RESULT_PERMISSION_REQUIRED

        this.kind = if (kind == KIND_LIVE) KIND_LIVE else KIND_VOICE
        this.sessionId = sessionId
        this.title = title
        this.sourceRoute = sourceRoute

        // 先起保活服务（此刻 App 仍在前台 ⇒ 满足 Android 12+ 的 FGS 启动限制）。
        AylaFloatingBallService.start(context)

        return try {
            ensureView()
            RESULT_SHOWN
        } catch (error: Exception) {
            Log.w(TAG, "show ball failed: ${error.message}", error)
            hide(silent = true)
            RESULT_FAILED
        }
    }

    /** 隐藏悬浮球（幂等；无球时只做服务清理）。[silent] = 不回调 `onBallClosed`。 */
    fun hide(silent: Boolean = false) {
        val view = ballView
        ballView = null
        val wm = windowManager
        if (view != null && wm != null) {
            try {
                wm.removeView(view)
            } catch (error: Exception) {
                Log.w(TAG, "removeView failed: ${error.message}", error)
            }
        }
        windowManager = null
        params = null
        // 保活服务随之停止（没有球就不该常驻通知栏）。
        try {
            AylaFloatingBallService.stop(context)
        } catch (error: Exception) {
            Log.w(TAG, "stop service failed: ${error.message}")
        }
        if (!silent) onBallClosed()
    }

    /** 当前是否有「显示在其他应用上层」权限。 */
    fun canDrawOverlays(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(context)
        } else {
            false
        }

    /**
     * 跳系统「显示在其他应用上层」授权页。
     *
     * 没有运行时权限弹窗，这是**唯一**授权入口（研究结论）。返回 true = 已跳转；
     * 调用方不得假设用户真的打开了开关（用户可能直接返回）。
     */
    fun openOverlaySettings(): Boolean {
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

    // ---------------------------------------------------------------- 视图

    private fun ensureView() {
        if (ballView != null) {
            // 幂等：已有球时只更新配色（kind 可能变了）。
            (ballView as? BallGlyphView)?.setKind(kind)
            return
        }
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as? WindowManager ?: return
        val sizePx = dp(BALL_DP)
        val layout = WindowManager.LayoutParams(
            sizePx,
            sizePx,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            // 默认落点与 Flutter 侧一致：右上角（right 24 → 这里用 12dp 边距更贴手指）。
            x = screenWidth() - sizePx - dp(12)
            y = dp(96)
        }
        val view = BallGlyphView(context, kind)
        attachDrag(view, layout, wm)
        wm.addView(view, layout)
        windowManager = wm
        ballView = view
        params = layout
    }

    /** 拖动 + 点击 + 长按关闭。阈值取系统 touchSlop（与 Flutter 的 kTouchSlop 同源语义）。 */
    private fun attachDrag(
        view: View,
        layout: WindowManager.LayoutParams,
        wm: WindowManager,
    ) {
        val touchSlop = ViewConfiguration.get(context).scaledTouchSlop
        val handler = Handler(Looper.getMainLooper())
        var downRawX = 0f
        var downRawY = 0f
        var startX = 0
        var startY = 0
        var moved = false
        var longPressFired = false

        val closeRunnable = Runnable {
            longPressFired = true
            hide()
        }

        view.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downRawX = event.rawX
                    downRawY = event.rawY
                    startX = layout.x
                    startY = layout.y
                    moved = false
                    longPressFired = false
                    handler.postDelayed(closeRunnable, LONG_PRESS_MS)
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - downRawX
                    val dy = event.rawY - downRawY
                    if (!moved && (abs(dx) > touchSlop || abs(dy) > touchSlop)) {
                        moved = true
                        handler.removeCallbacks(closeRunnable)
                    }
                    if (moved) {
                        val size = layout.width
                        val maxX = (screenWidth() - size).coerceAtLeast(0)
                        val maxY = (screenHeight() - size).coerceAtLeast(0)
                        layout.x = (startX + dx.roundToInt()).coerceIn(0, maxX)
                        layout.y = (startY + dy.roundToInt()).coerceIn(0, maxY)
                        try {
                            wm.updateViewLayout(view, layout)
                        } catch (error: Exception) {
                            Log.w(TAG, "updateViewLayout failed: ${error.message}")
                        }
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    handler.removeCallbacks(closeRunnable)
                    if (!moved && !longPressFired) onBallTap(kind, sourceRoute)
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    handler.removeCallbacks(closeRunnable)
                    true
                }
                else -> false
            }
        }
    }

    private fun screenWidth(): Int = context.resources.displayMetrics.widthPixels

    private fun screenHeight(): Int = context.resources.displayMetrics.heightPixels

    private fun dp(value: Int): Int =
        (value * context.resources.displayMetrics.density).roundToInt()

    companion object {
        private const val TAG = "AylaFloatingBall"

        const val KIND_VOICE = "voice"
        const val KIND_LIVE = "live"

        const val RESULT_SHOWN = "shown"
        const val RESULT_PERMISSION_REQUIRED = "permissionRequired"
        const val RESULT_UNSUPPORTED = "unsupported"
        const val RESULT_FAILED = "failed"

        /** 与 Flutter 侧 `AylaSessionActivityIndicator.ballSize = 44` 对齐。 */
        const val BALL_DP = 44

        private const val LONG_PRESS_MS = 600L
    }
}

/**
 * 球面：圆底 + 2px 描边图标（**纯代码绘制**，见 [AylaFloatingBallController] 的资源纪律）。
 *
 * 配色逐字取 Flutter 侧 `theme/tokens.dart` 的球色：
 * 语音 `sakura100 #FCD8FF` / `grape700 #722E88`，
 * 直播 `ice300 #BDD4E9` / `indigo700 #465B92`，
 * 亮边 `glassBorder #A6FFFFFF`。字形是库内 Lucide 风格（mic / video）的等价描边。
 */
private class BallGlyphView(context: Context, kind: String) : View(context) {
    private val body = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val border = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
    }
    private val glyph = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val rect = RectF()

    private var kind: String = kind

    fun setKind(next: String) {
        if (kind == next) return
        kind = next
        invalidate()
    }

    private val isLive: Boolean get() = kind == AylaFloatingBallController.KIND_LIVE

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val w = width.toFloat()
        val h = height.toFloat()
        val d = min(w, h)
        val strokeWidth = d * 0.075f

        // 圆底（不透明球色，与 Flutter 侧一致：球的底色不透明，所以不做背板模糊）
        body.color = if (isLive) COLOR_LIVE_BG else COLOR_VOICE_BG
        canvas.drawCircle(w / 2f, h / 2f, d / 2f, body)
        // 1px 亮边
        border.color = COLOR_BORDER
        border.strokeWidth = d * 0.02f
        canvas.drawCircle(w / 2f, h / 2f, d / 2f - border.strokeWidth / 2f, border)

        glyph.color = if (isLive) COLOR_LIVE_FG else COLOR_VOICE_FG
        glyph.strokeWidth = strokeWidth
        if (isLive) drawVideoGlyph(canvas, w, h, d) else drawMicGlyph(canvas, w, h, d)
    }

    /** Lucide `mic`：胶囊麦身 + 拾音弧 + 支架。 */
    private fun drawMicGlyph(canvas: Canvas, w: Float, h: Float, d: Float) {
        val cx = w / 2f
        val bodyW = d * 0.20f
        val bodyTop = h * 0.24f
        val bodyBottom = h * 0.52f
        val radius = bodyW / 2f
        rect.set(cx - radius, bodyTop, cx + radius, bodyBottom)
        canvas.drawRoundRect(rect, radius, radius, glyph)
        // 拾音弧：以球心为圆心、半径 bodyBottom-cx 的下半圆
        val arcR = d * 0.20f
        rect.set(cx - arcR, h * 0.52f - arcR, cx + arcR, h * 0.52f + arcR)
        canvas.drawArc(rect, 0f, 180f, false, glyph)
        // 支架
        canvas.drawLine(cx, h * 0.72f, cx, h * 0.78f, glyph)
        canvas.drawLine(cx - d * 0.14f, h * 0.78f, cx + d * 0.14f, h * 0.78f, glyph)
    }

    /** Lucide `video`：机身圆角矩形 + 右侧取景三角。 */
    private fun drawVideoGlyph(canvas: Canvas, w: Float, h: Float, d: Float) {
        val left = w / 2f - d * 0.26f
        val top = h / 2f - d * 0.17f
        val right = w / 2f + d * 0.06f
        val bottom = h / 2f + d * 0.17f
        rect.set(left, top, right, bottom)
        canvas.drawRoundRect(rect, d * 0.07f, d * 0.07f, glyph)
        val path = android.graphics.Path()
        path.moveTo(right + d * 0.03f, h / 2f - d * 0.07f)
        path.lineTo(w / 2f + d * 0.24f, h / 2f)
        path.lineTo(right + d * 0.03f, h / 2f + d * 0.07f)
        path.close()
        canvas.drawPath(path, glyph)
    }

    private companion object {
        const val COLOR_VOICE_BG = 0xFFFCD8FF.toInt() // --sakura-100
        const val COLOR_VOICE_FG = 0xFF722E88.toInt() // --grape-700
        const val COLOR_LIVE_BG = 0xFFBDD4E9.toInt() // --ice-300
        const val COLOR_LIVE_FG = 0xFF465B92.toInt() // --indigo-700
        const val COLOR_BORDER = 0xA6FFFFFF.toInt() // --glass-border
    }
}

/**
 * 悬浮球的保活前台服务。
 *
 * **为什么需要**：叠加层窗口随进程存活；进程被系统回收后球直接消失。前台服务把进程
 * 钉住（同时给用户一个可见的「还在挂着会话」的通知条 —— 这是 Android 的硬性要求，
 * 不是可以省掉的噪音）。
 *
 * **为什么是 `mediaPlayback`**：会话本身就是语音/直播媒体；`dataSync`（现有下载服务用的）
 * 在 Android 15 有 6 小时 / 24 小时上限，且语义不符（研究结论）。
 * 声明要求：`FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MEDIA_PLAYBACK` +
 * `android:foregroundServiceType="mediaPlayback"`（见 AndroidManifest.xml）。
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
         * `ForegroundServiceStartNotAllowedException`）；本服务的唯一调用点是
         * [AylaFloatingBallController.show]，由 UI 手势触发。
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
