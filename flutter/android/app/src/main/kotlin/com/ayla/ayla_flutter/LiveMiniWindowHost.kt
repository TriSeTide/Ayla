package com.ayla.ayla_flutter

import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.WindowManager
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.android.TransparencyMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.roundToInt

/**
 * 系统叠加层里的**直播小窗**宿主 —— 第二 FlutterEngine + FlutterView。
 *
 * ## 用户定稿（2026-10-31，逐字）
 * > 「直播小窗也是同样的，要直接用现有的直播小窗让他脱离应用，不要加按钮单独重做一个」
 * > 「**不要造轮子！用现有的悬浮球和直播小窗**」
 * > 1.0.41 的 `LiveOverlayFlutterHost.kt`（533 行）被评价「**各种交互都做烂了**」，**不要抄**。
 *
 * ⇒ 这里**一行绘制代码都没有**：窗口里 build 的仍是 App 内那一个
 * `AylaLiveMiniPlayer`（`lib/widgets/live/live_mini_player.dart`），
 * 换的只是宿主窗口（`TYPE_APPLICATION_OVERLAY` + 第二引擎）。
 * Dart 侧入口 = `lib/main.dart` 的 `aylaAndroidLiveWindowMain`。
 *
 * ## 为什么窗口 = 卡片尺寸（而不是铺满全屏）
 * Android overlay 窗口的**尺寸就是触摸热区**：窗口内任何位置都吃触摸，
 * `onTouch` 返回 false 也不会还给下层（WM input channel 在 DOWN 时已捕获）。
 * 而公开 API 里没有「非矩形热区」（`TOUCHABLE_INSETS_REGION` 是 @hide）。
 * ⇒ 窗口必须**刚好包住卡片**（含关闭键的 10dp 外溢），否则会吞掉桌面触摸。
 *
 * ## 几何约定（与 Dart 侧 `AylaLiveMiniPlayer.compact` 逐条对应）
 * 窗口 = (卡片宽 + [CLOSE_INSET_DP]) × (卡片高 + [CLOSE_INSET_DP])：
 * 卡片画在 `(0, CLOSE_INSET_DP)`，右上角外侧的关闭键正好落在多出来的那条边距里。
 *
 * ## 交互分工
 * - **拖动 / 双指缩放由原生负责**（窗口尺寸就是几何，Dart 侧改不了窗口）；
 * - 点画面 / 点关闭键仍由 Flutter 处理（组件原样，只走一条通道回调）。
 *
 * ## 线程
 * 全部方法必须在**主线程**调用（`WindowManager.addView` 与 engine 创建都要求）。
 */
class AylaLiveMiniWindowHost(
    private val context: Context,
    /** 点画面 ⇒ 回直播间（原生负责拉前台 + 通知主引擎导航）。 */
    private val onOpenRoom: (channelId: String) -> Unit,
    /** 点关闭键 / 直播结束 ⇒ 关窗（不通知主引擎，Dart 侧自己知道的路径不回调）。 */
    private val onClosed: () -> Unit,
) {
    private var windowManager: WindowManager? = null
    private var flutterView: FlutterView? = null
    private var params: WindowManager.LayoutParams? = null
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null

    /** 当前播放地址 / 频道（重复 `show` 同参幂等）。 */
    private var channelId = ""
    private var playUrl = ""

    private var density = 1f

    /** 第一帧已出。 */
    private var ready = false

    /** 卡片逻辑宽度（dp；高度按 16:9）。 */
    private var cardWidthDp = DEFAULT_WIDTH_DP

    private var dragging = false
    private var dragStartRawX = 0f
    private var dragStartRawY = 0f
    private var dragStartX = 0
    private var dragStartY = 0

    /** 双指缩放会话。 */
    private var scaleStartSpan = 0f
    private var scaleStartWidthDp = 0

    val isShowing: Boolean
        get() = flutterView != null

    // ------------------------------------------------------------------ 生命周期

    /**
     * 打开（或复用）小窗。
     *
     * @return true = 已显示；false = 无权限 / 平台不支持 / 失败（调用方据此回落）。
     */
    fun show(channelId: String, title: String, playUrl: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        if (!canDrawOverlays()) return false
        // 保活：小窗 + 第二引擎的音频必须在 App 进后台后继续（Android 会冻结
        // 后台进程的 CPU / 渲染；mediaPlayback 前台服务才能钉住）。必须在 App
        // 仍在前台时启动（Android 12+ 的后台 FGS 限制）。
        AylaFloatingBallService.start(context)

        val sameStream = isShowing && this.channelId == channelId
        this.channelId = channelId
        if (sameStream && this.playUrl == playUrl) return true
        this.playUrl = playUrl

        return try {
            if (flutterView == null) {
                ensureView()
            }
            // 播放地址变了（切台）：交给 Dart 侧换流（幂等；同 URL 不重建播放器）。
            val payload = org.json.JSONObject().apply {
                put("kind", "liveMini")
                put("channelId", channelId)
                put("title", title)
                put("playUrl", playUrl)
            }.toString()
            if (ready) {
                channel?.invokeMethod("play", mapOf("url" to playUrl, "title" to title))
            }
            true
        } catch (error: Exception) {
            Log.w(TAG, "show live mini failed: ${error.message}", error)
            hide(notify = false)
            false
        }
    }

    /** 更新（切台）：只推新地址，不重建窗口。返回 false = 当前没有窗口。 */
    fun update(title: String, playUrl: String): Boolean {
        if (flutterView == null) return false
        if (this.playUrl == playUrl) return true
        this.playUrl = playUrl
        channel?.invokeMethod("play", mapOf("url" to playUrl, "title" to title))
        return true
    }

    /** 关闭（幂等）。[notify] = 是否回调 [onClosed]（Dart 自己要求的关闭不回调）。 */
    fun hide(notify: Boolean) {
        val view = flutterView
        val wm = windowManager
        flutterView = null
        params = null
        windowManager = null
        ready = false
        channelId = ""
        playUrl = ""
        if (view != null && wm != null) {
            try {
                wm.removeView(view)
            } catch (error: Exception) {
                Log.w(TAG, "removeView failed: ${error.message}")
            }
        }
        channel?.setMethodCallHandler(null)
        channel = null
        try {
            engine?.destroy()
        } catch (error: Exception) {
            Log.w(TAG, "engine.destroy failed: ${error.message}")
        }
        engine = null
        try {
            AylaFloatingBallService.stopIfIdle(context)
        } catch (error: Exception) {
            Log.w(TAG, "stop service failed: ${error.message}")
        }
        if (notify) onClosed()
    }

    fun canDrawOverlays(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            android.provider.Settings.canDrawOverlays(context)
        } else {
            false
        }

    // ------------------------------------------------------------------ 窗口

    private fun ensureView() {
        val flutter = ensureEngine()
        density = context.resources.displayMetrics.density
        rebuildWindow()
    }

    /** 按当前 [cardWidthDp] 建（或重建）窗口；卡片固定的初始落点 = 右下角。 */
    private fun rebuildWindow() {
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as? WindowManager ?: return
        val flutter = engine ?: return
        val widthPx = dp(cardWidthDp + CLOSE_INSET_DP)
        val heightPx = dp((cardWidthDp * 9 / 16) + CLOSE_INSET_DP)

        val old = flutterView
        if (old != null) {
            try {
                wm.removeView(old)
            } catch (error: Exception) {
                Log.w(TAG, "removeView for resize failed: ${error.message}")
            }
            flutterView = null
        }

        val view = FlutterView(context, TransparencyMode.transparent)
        view.attachToFlutterEngine(flutter)
        val layout = WindowManager.LayoutParams(
            widthPx,
            heightPx,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = (screenWidth() - widthPx - dp(MARGIN_DP)).coerceAtLeast(0)
            y = (screenHeight() - heightPx - dp(MARGIN_DP)).coerceAtLeast(0)
        }
        try {
            wm.addView(view, layout)
            windowManager = wm
            flutterView = view
            params = layout
            installGestures(view)
            pushSize()
        } catch (error: Exception) {
            Log.w(TAG, "addView failed: ${error.message}")
        }
    }

    /** 只改宽高（不重建 View）。缩放过程中用它，避免每帧重建 FlutterView。 */
    private fun resizeInPlace() {
        val wm = windowManager ?: return
        val view = flutterView ?: return
        val layout = params ?: return
        val widthPx = dp(cardWidthDp + CLOSE_INSET_DP)
        val heightPx = dp((cardWidthDp * 9 / 16) + CLOSE_INSET_DP)
        if (layout.width == widthPx && layout.height == heightPx) return
        layout.width = widthPx
        layout.height = heightPx
        // 右下锚定：缩放时左上角跟着移动，视觉上像从右下角长出来。
        layout.x = (layout.x + (layout.width - widthPx)).let { layout.x }
        try {
            wm.updateViewLayout(view, layout)
        } catch (error: Exception) {
            Log.w(TAG, "resize failed: ${error.message}")
        }
        pushSize()
    }

    /** 把「卡片可用区」报给 Dart（窗口减去关闭键外溢）。 */
    private fun pushSize() {
        val layout = params ?: return
        if (!ready) return
        try {
            channel?.invokeMethod(
                "size",
                mapOf(
                    "width" to (layout.width / density),
                    "height" to (layout.height / density),
                    "inset" to CLOSE_INSET_DP,
                ),
            )
        } catch (error: Exception) {
            Log.w(TAG, "pushSize failed: ${error.message}")
        }
    }

    /**
     * 触摸：**只旁听**，从不消费（全部返回 false）。
     *
     * - 单指竖直/水平位移超 slop ⇒ 移动窗口（拖动）；
     * - 两指 ⇒ 按指距比例改窗口宽度（16:9 等比，168..900dp）；
     * - 与悬浮球同一纪律：**绝不发 ACTION_CANCEL**，否则 Flutter 的点击会被打断
     *   （悬浮球上一版「点把手不收起」就是这么来的）。
     */
    private fun installGestures(view: FlutterView) {
        view.setOnTouchListener { _, event ->
            val wm = windowManager
            val layout = params
            if (wm == null || layout == null) return@setOnTouchListener false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    dragging = false
                    dragStartRawX = event.rawX
                    dragStartRawY = event.rawY
                    dragStartX = layout.x
                    dragStartY = layout.y
                    scaleStartSpan = 0f
                    false
                }
                MotionEvent.ACTION_POINTER_DOWN -> {
                    dragging = false
                    if (event.pointerCount == 2) {
                        scaleStartSpan = span(event)
                        scaleStartWidthDp = cardWidthDp
                    }
                    false
                }
                MotionEvent.ACTION_MOVE -> {
                    if (event.pointerCount >= 2) {
                        if (scaleStartSpan <= 0f) return@setOnTouchListener false
                        val ratio = span(event) / scaleStartSpan
                        val next = (scaleStartWidthDp * ratio)
                            .roundToInt()
                            .coerceIn(MIN_WIDTH_DP, MAX_WIDTH_DP)
                        if (next != cardWidthDp) {
                            cardWidthDp = next
                            resizeInPlace()
                        }
                        return@setOnTouchListener false
                    }
                    val dx = event.rawX - dragStartRawX
                    val dy = event.rawY - dragStartRawY
                    if (!dragging && abs(dx) < dp(DRAG_SLOP_DP) && abs(dy) < dp(DRAG_SLOP_DP)) {
                        return@setOnTouchListener false
                    }
                    dragging = true
                    val maxX = (screenWidth() - layout.width).coerceAtLeast(0)
                    val maxY = (screenHeight() - layout.height).coerceAtLeast(0)
                    val nx = (dragStartX + dx).roundToInt().coerceIn(0, maxX)
                    val ny = (dragStartY + dy).roundToInt().coerceIn(0, maxY)
                    if (nx != layout.x || ny != layout.y) {
                        layout.x = nx
                        layout.y = ny
                        try {
                            wm.updateViewLayout(view, layout)
                        } catch (error: Exception) {
                            Log.w(TAG, "drag move failed: ${error.message}")
                        }
                    }
                    false
                }
                MotionEvent.ACTION_POINTER_UP,
                MotionEvent.ACTION_UP,
                MotionEvent.ACTION_CANCEL -> {
                    if (dragging) {
                        dragging = false
                        // 拖动结束 ⇒ 抑制紧随其后的一次 tap（否则「拖完跳回直播间」）。
                        channel?.invokeMethod("suppressTap", null)
                    }
                    if (event.actionMasked != MotionEvent.ACTION_POINTER_UP) {
                        scaleStartSpan = 0f
                    }
                    false
                }
                else -> false
            }
        }
    }

    private fun span(event: MotionEvent): Float =
        hypot(
            (event.getX(1) - event.getX(0)),
            (event.getY(1) - event.getY(0)),
        )

    // ------------------------------------------------------------------ 引擎

    /**
     * 第二个引擎。
     *
     * ⚠️ 独立 [FlutterEngine]（不用 FlutterEngineGroup）：overlay 的 surface 与
     * Activity 的 window surface 不属于同一 EGL 环境，共享 GPU 上下文会让 raster
     * 线程拿不到 current context（`libEGL: no current context`）→ SIGSEGV。
     *
     * 这个引擎**需要插件**：视频走 `video_player`（Android 上是 ExoPlayer）。
     * 自动注册由 `FlutterEngine(context)` 完成（同悬浮球宿主的用法）。
     */
    private fun ensureEngine(): FlutterEngine {
        engine?.let { return it }
        val loader: FlutterLoader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) {
            loader.startInitialization(context)
            loader.ensureInitializationComplete(context, null)
        }
        val flutter = FlutterEngine(context)
        val args = listOf(
            org.json.JSONObject().apply {
                put("kind", "liveMini")
                put("channelId", channelId)
                put("playUrl", playUrl)
            }.toString(),
        )
        flutter.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(loader.findAppBundlePath(), ENTRYPOINT),
            args,
        )
        // 同一个坑（见 OverlayFlutterHost.ensureEngine）：overlay 窗口不属于任何
        // FlutterActivity ⇒ 没有任何东西会给这个引擎发 flutter/lifecycle ⇒ 框架停在
        // hidden/paused ⇒ scheduleFrame() 直接 return ⇒ 小窗画面冻在第一帧。
        try {
            flutter.lifecycleChannel.appIsResumed()
        } catch (error: Exception) {
            Log.w(TAG, "appIsResumed failed: ${error.message}")
        }
        val methodChannel = MethodChannel(flutter.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "ready" -> {
                    ready = true
                    pushSize()
                    if (playUrl.isNotEmpty()) {
                        channel?.invokeMethod("play", mapOf("url" to playUrl, "title" to ""))
                    }
                    result.success(true)
                }
                "openRoom" -> {
                    mainHandler.post { onOpenRoom(channelId) }
                    result.success(true)
                }
                "close" -> {
                    mainHandler.post { hide(notify = false) }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        channel = methodChannel
        engine = flutter
        return flutter
    }

    private fun screenWidth(): Int = context.resources.displayMetrics.widthPixels

    private fun screenHeight(): Int = context.resources.displayMetrics.heightPixels

    private fun dp(value: Int): Int =
        (value * context.resources.displayMetrics.density).roundToInt()

    private fun dp(value: Float): Int =
        (value * context.resources.displayMetrics.density).roundToInt()

    companion object {
        private const val TAG = "AylaLiveMiniHost"

        /** Dart 入口（`lib/main.dart` 的顶层函数，逐字一致）。 */
        const val ENTRYPOINT = "aylaAndroidLiveWindowMain"

        /** 第二引擎 ↔ 原生的私有通道（与 Dart 侧逐字一致）。 */
        const val CHANNEL = "ayla/live_mini_window"

        /** 关闭键相对卡片右上角的**外溢**（= Dart 的 `kLiveCloseInset`）。 */
        const val CLOSE_INSET_DP = 10

        /** 默认卡片宽度（逻辑 dp；用户要求 400×225）。 */
        const val DEFAULT_WIDTH_DP = 400

        /** 双指缩放范围（用户：168×94 ~ 900×506）。 */
        const val MIN_WIDTH_DP = 168
        const val MAX_WIDTH_DP = 900

        /** 距屏幕右下角的初始留白。 */
        const val MARGIN_DP = 12

        /** 判定为拖动的最小位移（dp）。 */
        const val DRAG_SLOP_DP = 8

        private val mainHandler = Handler(Looper.getMainLooper())
    }
}
