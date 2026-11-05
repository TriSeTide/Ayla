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
 * ## 几何约定（与 Dart 侧 `_AylaAndroidLiveMiniWindowAppState.build` 逐条对应）
 * 窗口 = (卡片宽 + **2×**[CLOSE_INSET_DP]) × (卡片高 + **2×**[CLOSE_INSET_DP])。
 *
 * 关闭键用 `Positioned(top: -CLOSE_INSET_DP, right: -CLOSE_INSET_DP)` 画在卡片
 * **右上角外侧**（用户要求「不许把按钮移进卡片内部」），它在窗口坐标系里占
 * `y ∈ [0, 24]`、`x ∈ [w-24, w]`（24 = 按钮直径）。旧实现窗口高度只加了**一侧**
 * 的 CLOSE_INSET，卡片又画在 (0,0) ⇒ 按钮上半部分落在窗口外、被 WM 裁掉
 * （用户实报「关闭键上半部分被裁断」）。四边各留 [CLOSE_INSET_DP]，卡片画在
 * `(CLOSE_INSET_DP, CLOSE_INSET_DP)`，按钮整圆就完整落在窗口里。
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
    /**
     * 点画面 ⇒ 回直播间（原生负责拉前台 + 通知主引擎）。
     *
     * 「屏幕上本来就在这个直播间 ⇒ 只取消小窗、不再 push 路由」这条判定放在
     * Dart 侧（`AppShell` 拿得到当前 pathname），原生只负责把意图送回去。
     */
    private val onOpenRoom: (channelId: String) -> Unit,
    /** 窗口真的没了（用户点关闭键 / Dart 主动关 / Activity 销毁）⇒ 告诉主引擎。 */
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

    /**
     * 卡片逻辑宽度（dp；高度按 16:9）。
     *
     * ⚠️ 这里保留 **Float**，不再取整成 Int：捏合过程中每帧都 `roundToInt()` 会在
     * 慢速捏合时产生明显锯齿（用户实报「缩放有点不跟手、很抖」）。像素级取整
     * 交给 `dp()` 在下发窗口尺寸那一刻做，手势过程中用浮点累积才不会抖动。
     */
    private var cardWidthDp = DEFAULT_WIDTH_DP.toFloat()

    private var dragging = false
    private var dragStartRawX = 0f
    private var dragStartRawY = 0f
    private var dragStartX = 0
    private var dragStartY = 0

    /** 双指缩放会话。 */
    private var scaleStartSpan = 0f
    private var scaleStartWidthDp = 0f

    val isShowing: Boolean
        get() = flutterView != null

    /**
     * 保活服务**异步**前台化失败 => 小窗先收起，再把「窗口没了」回传主引擎。
     *
     * 与 [AylaOverlayFlutterHost] 同因：`show()` 返回时系统回调还没跑，只能乐观成功；
     * 失败必须立刻收窗，否则留下「窗口还在、进程 10s 后被杀」的形态。
     */
    private val foregroundFailureHandler: (String) -> Unit = { reason ->
        Log.w(TAG, "foreground service failed after show(), hiding live mini: $reason")
        AylaFloatingBallService.removeForegroundFailureListener(foregroundFailureHandler)
        hide()
    }

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
        //
        // ⚠️ 与 [AylaOverlayFlutterHost.show] 同一条纪律（2026-11-05 闪退修复）：
        // 保活起不来时**不要**继续建第二引擎 —— 否则窗口出来了、进程随后被系统以
        // ForegroundServiceDidNotStartInTimeException 杀掉。
        AylaFloatingBallService.addForegroundFailureListener(foregroundFailureHandler)
        AylaFloatingBallService.start(context)
        val foregroundFailure = AylaFloatingBallService.foregroundFailure()
        if (foregroundFailure != null) {
            Log.w(TAG, "show aborted, foreground service failed: $foregroundFailure")
            AylaFloatingBallService.removeForegroundFailureListener(foregroundFailureHandler)
            hide(notify = false)
            return false
        }

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
            hide()
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

    /**
     * 关闭（幂等）。
     *
     * [notify] 参数保留为兼容签名，但**不再有「静默关闭」这条路径**：无论谁发起的
     * 关闭，都必须让主引擎知道「窗口已经没了」—— 否则 Dart 侧 `miniPlayer` 投影
     * 还停在「有小窗」，而窗口其实已经消失，下一次同步会被去重逻辑判成「已打开」
     * ⇒ **小窗再也打不开**（关一次就永久失效）。
     *
     * 主引擎据此做的只是「清掉小窗投影」，不销毁会话：用户点关闭键的语义是
     * 「不要这个小窗了」，不是「退出直播间」。
     */
    fun hide(notify: Boolean = true) {
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
        AylaFloatingBallService.removeForegroundFailureListener(foregroundFailureHandler)
        try {
            AylaFloatingBallService.stopIfIdle(context)
        } catch (error: Exception) {
            Log.w(TAG, "stop service failed: ${error.message}")
        }
        onClosed()
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
        // 关闭键画在卡片**外侧**（top/right 各 -CLOSE_INSET），所以窗口四边都要
        // 留出 CLOSE_INSET 的余量，否则它上半部分会被窗口裁掉（用户实报）。
        val widthPx = dp(cardWidthDp + CLOSE_INSET_DP * 2)
        val heightPx = dp((cardWidthDp * 9f / 16f) + CLOSE_INSET_DP * 2)

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

    /**
     * 按 [cardWidthDp] 改窗口宽高（不重建 View）。
     *
     * 调用点：捏合**结束**（[endGestureResize]）、以及任何需要把窗口收敛到
     * 卡片真实尺寸的场合。捏合过程中**不**调用它（见 [beginGestureResize]）。
     */
    private fun resizeInPlace() {
        val wm = windowManager ?: return
        val view = flutterView ?: return
        val layout = params ?: return
        // 关闭键画在卡片**外侧**（top/right 各 -CLOSE_INSET），所以窗口四边都要
        // 留出 CLOSE_INSET 的余量，否则它上半部分会被窗口裁掉（用户实报）。
        val widthPx = dp(cardWidthDp + CLOSE_INSET_DP * 2)
        val heightPx = dp((cardWidthDp * 9f / 16f) + CLOSE_INSET_DP * 2)
        if (layout.width == widthPx && layout.height == heightPx) return
        // **中心锚定**（用户定稿「不要以右下角为准缩放，以中心为准」）：
        // 窗口收回卡片尺寸时保持中心不动，卡片视觉上原地收缩/长大。
        val centerX = layout.x + layout.width / 2
        val centerY = layout.y + layout.height / 2
        layout.width = widthPx
        layout.height = heightPx
        layout.x = (centerX - widthPx / 2).coerceIn(0, (screenWidth() - widthPx).coerceAtLeast(0))
        layout.y = (centerY - heightPx / 2).coerceIn(0, (screenHeight() - heightPx).coerceAtLeast(0))
        try {
            wm.updateViewLayout(view, layout)
        } catch (error: Exception) {
            Log.w(TAG, "resize failed: ${error.message}")
        }
        // 窗口尺寸是权威值 ⇒ 立刻告诉 Dart，卡片按它对齐（捏合结束后清掉临时宽度）。
        pushSize()
    }

    /**
     * 把**窗口尺寸**报给 Dart。
     *
     * 约定（与 Dart 侧 `_AylaAndroidLiveMiniWindowAppState.build` 配对）：
     * 窗口 = 卡片 + 四边各 [CLOSE_INSET_DP]。Dart 收到窗口尺寸后减去 2×inset
     * 得到卡片尺寸。两边必须遵守同一约定，否则卡片会缩水成窗口的一半不到。
     */
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

    /** 捏合手势进行中（窗口已一次性让位到最大档，卡片缩放由 Dart 驱动）。 */
    private var gestureResizing = false

    /**
     * 捏合开始：**一次性**把窗口让位到最大档（[MAX_WIDTH_DP]）。
     *
     * ## 为什么不再每帧改窗口（2026-11-01 用户实报「缩放还是好抖」）
     * 每帧 `updateViewLayout` ⇒ FlutterView 的 surface 每帧都变尺寸 ⇒ Flutter
     * 每帧重新光栅化，而窗口尺寸永远领先画面一帧 —— 用户看到的就是
     * 「先改窗口、直播画面再追上来同步比例」。
     *
     * 新分工：窗口在手势开始**一次性**让到最大档（全程只有这一次重排，且窗口
     * 透明、多出来的部分不可见）；之后每一帧由 Dart 侧按手势比例缩放卡片
     * （通道 `gestureScale`，与 App 内小窗捏合同一条渲染管线，同帧出图）；
     * 手势结束窗口再**一次性**收到最终尺寸。整个手势 = 2 次窗口重排，
     * 中间全部是 Dart 帧内缩放，不再有「窗口领先画面」的追赶。
     *
     * 锚点：**卡片中心**（用户定稿「不要以右下角为准缩放，以中心为准」）。
     * 让位时保持卡片中心点不动、窗口向四周均匀扩展，Dart 侧把卡片画在窗口正中
     * （`(win - size) / 2`）⇒ 放大缩小时视觉中心不漂。
     */
    private fun beginGestureResize() {
        if (gestureResizing) return
        val layout = params ?: return
        val view = flutterView ?: return
        gestureResizing = true
        val maxW = dp(MAX_WIDTH_DP + CLOSE_INSET_DP * 2)
        val maxH = dp((MAX_WIDTH_DP * 9f / 16f) + CLOSE_INSET_DP * 2)
        if (layout.width >= maxW && layout.height >= maxH) return
        // 卡片中心 = 窗口中心（卡片在窗口里居中，四边余量对称）。
        val centerX = layout.x + layout.width / 2
        val centerY = layout.y + layout.height / 2
        layout.width = maxW
        layout.height = maxH
        // 让位后卡片仍居中 ⇒ 窗口左上角 = 中心 - 窗口/2（clamp 回屏幕内）。
        layout.x = (centerX - maxW / 2).coerceIn(0, (screenWidth() - maxW).coerceAtLeast(0))
        layout.y = (centerY - maxH / 2).coerceIn(0, (screenHeight() - maxH).coerceAtLeast(0))
        // 卡片中心随窗口 clamp 一起平移（Dart 侧按窗口居中算，不需要额外传参）。
        try {
            wm()?.updateViewLayout(view, layout)
        } catch (error: Exception) {
            Log.w(TAG, "gesture begin resize failed: ${error.message}")
        }
        pushSize()
    }

    /**
     * 捏合结束：窗口**立刻**收回卡片大小（一次重排），Dart 侧由 `size` 消息对齐。
     *
     * ⚠️ 必须在这里就收回，不能等 Dart：overlay 窗口的尺寸就是**触摸热区**，
     * 让位期间多出来的那圈会吞掉桌面触摸（用户在小窗旁边点桌面没反应）。
     */
    private fun endGestureResize() {
        if (!gestureResizing) return
        gestureResizing = false
        resizeInPlace()
    }

    private fun wm(): WindowManager? =
        context.getSystemService(Context.WINDOW_SERVICE) as? WindowManager

    /**
     * 触摸：**只旁听**，从不消费（全部返回 false）。
     *
     * - 单指竖直/水平位移超 slop ⇒ 移动窗口（拖动）；
     * - 两指 ⇒ 捏合缩放（16:9 等比，120..320dp）。分工：窗口只在**手势开始**
     *   一次性让到最大档、**结束**一次性收回卡片尺寸（两次重排），中间每一帧
     *   只把目标宽度推给 Dart（`gestureScale`）由卡片在帧内缩放 —— 这样不再有
     *   「窗口先变、画面追一帧」的抖动；
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
                        // 捏合开始：窗口一次性让位到最大档，之后由 Dart 帧内缩放。
                        beginGestureResize()
                    }
                    false
                }
                MotionEvent.ACTION_MOVE -> {
                    if (event.pointerCount >= 2) {
                        if (scaleStartSpan <= 0f) return@setOnTouchListener false
                        val ratio = span(event) / scaleStartSpan
                        // 窗口已在 [beginGestureResize] 一次性让到最大档 ⇒ 这里**不再
                        // 动窗口**，只把目标宽度推给 Dart：卡片在帧内缩放（同一条渲染
                        // 管线出图），不会出现「窗口先变、画面再追」。
                        val next = (scaleStartWidthDp * ratio)
                            .coerceIn(MIN_WIDTH_DP.toFloat(), MAX_WIDTH_DP.toFloat())
                        if (abs(next - cardWidthDp) >= SCALE_EPSILON_DP) {
                            cardWidthDp = next
                            channel?.invokeMethod("gestureScale", next)
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
                    // 所有手指都离场 ⇒ 捏合结束：窗口一次性收到最终尺寸，Dart 侧再由
                    // `size` 消息把卡片对齐到同一档（见 [endGestureResize]）。
                    if (event.actionMasked == MotionEvent.ACTION_UP ||
                        event.actionMasked == MotionEvent.ACTION_CANCEL
                    ) {
                        endGestureResize()
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
                    val target = channelId
                    mainHandler.post { onOpenRoom(target) }
                    result.success(true)
                }
                "close" -> {
                    // 用户点关闭键：关窗 + 让主引擎清掉小窗投影（见 hide 的说明）。
                    mainHandler.post { hide() }
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

        /**
         * 默认卡片宽度 = **设计尺寸 168dp**（web `live.css:1026`，与 App 内小窗一致）。
         *
         * 曾经是 400（电脑端值）：Windows 125% 缩放下 168 只有 210 物理像素、画面太糊，
         * 桌面才把它抬上去（commit `5f1a5b4`）。手机不需要那档大尺寸 ——
         * 用户实报「小窗在手机上太大了，手机上应该还原成没有加大过的那个样子」。
         */
        const val DEFAULT_WIDTH_DP = 168

        /**
         * 双指缩放范围：**120..320**（高按 16:9）。
         *
         * 上限 320 = web `LiveMiniPlayer.tsx:32–33` 的手机原值，与 Dart 侧
         * `kLiveMiniMaxWidth` 逐字一致。
         *
         * ⚠️ 这里曾是 900（跟着电脑端一起抬的）：手机屏宽只有 360dp 左右，
         * 900dp 的卡片等于铺满整屏，用户实报「缩放肯定不能缩放到这——么——大」。
         * 电脑端那档 900 在 Dart 侧 `kLiveMiniDesktopMaxWidth`，走独立窗口实现，
         * 与本文件（Android 叠加层）无关。
         */
        const val MIN_WIDTH_DP = 120
        const val MAX_WIDTH_DP = 320

        /** 距屏幕右下角的初始留白。 */
        const val MARGIN_DP = 12

        /** 判定为拖动的最小位移（dp）。 */
        const val DRAG_SLOP_DP = 8

        /**
         * 捏合时触发一次窗口改尺寸所需的最小宽度变化（dp）。
         *
         * 0.5dp ≈ 1.5 物理像素（480dpi）—— 比这更小的变化用户看不出，
         * 但每帧都 `updateViewLayout` 会让 SurfaceFlinger 反复重排，肉眼是「抖」。
         */
        const val SCALE_EPSILON_DP = 0.5f

        private val mainHandler = Handler(Looper.getMainLooper())
    }
}
