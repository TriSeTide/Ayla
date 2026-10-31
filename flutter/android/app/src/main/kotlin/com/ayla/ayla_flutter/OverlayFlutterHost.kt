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
import kotlin.math.roundToInt

/**
 * 系统叠加层里的**悬浮球**宿主 —— 第二 FlutterEngine + FlutterView。
 *
 * ## 为什么必须是第二个 engine（而不是原生 View）
 * 用户 2026-10-31 的验收意见（逐字）：
 * > 「**不要造轮子！用现有的悬浮球和直播小窗**」
 * > 「悬浮球不应该重新做一个出来，而是直接原来的浮层悬浮球直接扔出应用窗口外」
 * > 「应用内不会再存在任何浮层……外观和交互完全没有区别」
 *
 * 上一轮把球做成了 `BallGlyphView`（Canvas 手绘圆球），用户判定「**丑得要命**」「南辕北辙」。
 * 结论：叠加层里必须 build **同一份** `AylaSessionActivityIndicator` widget ——
 * 一个 Flutter 视图只能铺满自己的窗口，所以它必须有自己的 engine。
 * **本文件一行绘制代码都没有**：视觉 100% 来自 Dart 侧那棵树。
 *
 * ## 2026-11-01 真机重做（三个已定稿的决策）
 * 1. **窗口尺寸严格等于当前状态的球组尺寸**：双球 132dp / 单球 80dp / 收起 28dp，高恒 44dp。
 *    Android overlay 窗口的**尺寸就是触摸热区**（`TOUCHABLE_INSETS_REGION` 是 @hide），
 *    所以「窗口 = 球组」是唯一能让球外区域不被吞掉的实现方式，误差仅为矩形近似
 *    （用户已明确接受）。
 * 2. **拖动只由原生负责**（[installDragHandle]）。Dart 侧在紧凑模式下**不再**改
 *    `Positioned.top`，也不再调 `setBallGroupTop` 移动窗口 ——
 *    两处同时移动正是「上下拖动来回跳变闪烁」的根因。
 * 3. **`setOnTouchListener` 只旁听、绝不干预 Flutter 事件流**：所有分支返回 `false`，
 *    不发 `ACTION_CANCEL`。之前发 CANCEL 会打断把手的普通点击
 *    （用户实报「点把手不收起，拖拽时才收起」）。
 *
 * ## 窗口尺寸变化为什么是 removeView + addView
 * 改尺寸会让合成器重分配 surface buffer，旧内容在新 buffer 里按原原点渲染一帧
 * ⇒ 斜向位置伪影（DE23）。所以**不用** `updateViewLayout` 改宽高，而是摘掉重建。
 *
 * ## 线程
 * 全部方法必须在**主线程**调用（`WindowManager.addView` 与 engine 创建都要求）。
 */
class AylaOverlayFlutterHost(
    private val context: Context,
    /** 点球回房：原生把 (kind, sourceRoute) 转给**主引擎**。 */
    private val onBallTap: (kind: String, sourceRoute: String) -> Unit,
) {
    private var windowManager: WindowManager? = null

    /** 屏幕密度缓存（逻辑 px → 物理 px）。 */
    private var densityValue = 1f

    /** 是否正在拖着窗口走。 */
    private var dragging = false

    /** 拖动起点（手指 rawY 与窗口 y）。 */
    private var dragStartRawY = 0f
    private var dragStartY = 0

    /** 当前窗口宽度（逻辑 dp），用于判断是否需要重建。 */
    private var currentWindowWidthDp = 0

    /** 当前是否处于收起态（只有把手）。由 Dart 侧 `setCollapsed` 同步。 */
    private var collapsed = false

    /** 当前球数（0/1/2），来自主引擎推来的 payload。 */
    private var ballCount = 0

    /** 最近一次要显示的投影（JSON 串）。浮层引擎 `ready` 之后补推一次。 */
    private var pendingPayload: String? = null

    /** 浮层引擎是否已经报到（`ready`）。 */
    private var engineReady = false

    private var flutterView: FlutterView? = null
    private var params: WindowManager.LayoutParams? = null

    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null

    /** 是否有窗口（幂等判据）。 */
    val isShowing: Boolean
        get() = flutterView != null

    /**
     * 显示 / 复用叠加层。
     *
     * @return `"shown"` / `"permissionRequired"` / `"unsupported"` / `"failed"`
     *   —— 与 Dart 侧 `AylaDetachedBallResult` 逐字对齐。
     */
    fun show(payload: String?): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return AylaFloatingBallController.RESULT_UNSUPPORTED
        }
        if (!canDrawOverlays()) return AylaFloatingBallController.RESULT_PERMISSION_REQUIRED

        pendingPayload = payload
        // 球数必须**先**算出来：窗口宽度 = 球组宽度，第一次 addView 就要是终态宽度
        // （否则会先建 28dp 再重建 132dp，多一次 EngineView 抖动）。
        updateBallCount()
        // 先起保活服务（此刻 App 仍在前台 ⇒ 满足 Android 12+ 的 FGS 启动限制）。
        AylaFloatingBallService.start(context)

        return try {
            ensureView()
            pushPayload()
            AylaFloatingBallController.RESULT_SHOWN
        } catch (error: Exception) {
            Log.w(TAG, "show overlay failed: ${error.message}", error)
            hide()
            AylaFloatingBallController.RESULT_FAILED
        }
    }

    /** 只更新投影（窗口已开时不重建 engine）。返回 false = 当前没有窗口。 */
    fun update(payload: String?): Boolean {
        if (flutterView == null) return false
        pendingPayload = payload
        pushPayload()
        return true
    }

    /** 隐藏叠加层（幂等）。 */
    fun hide() {
        val view = flutterView
        flutterView = null
        val wm = windowManager
        windowManager = null
        params = null
        currentWindowWidthDp = 0
        collapsed = false
        ballCount = 0
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
        engineReady = false
        pendingPayload = null
        try {
            AylaFloatingBallService.stop(context)
        } catch (error: Exception) {
            Log.w(TAG, "stop service failed: ${error.message}")
        }
    }

    /** 当前是否有「显示在其他应用上层」权限。 */
    fun canDrawOverlays(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            android.provider.Settings.canDrawOverlays(context)
        } else {
            false
        }

    // ---------------------------------------------------------------- 尺寸

    /**
     * 当前球数对应的**球组展开宽度**（dp）。
     *
     * 精确到组件真实几何（`session_activity.dart`）：ballSize=44 / gap=8 / toggleWidth=28
     *   双球 = 44+8+44+8+28 = 132
     *   单球 = 44+8+28      =  80
     *
     * ⚠️ **与收起态无关**：收起不再改窗口宽度（见 [applyCollapsed]）。
     */
    private fun expandedWidthDp(): Int = when {
        ballCount >= 2 -> 132
        ballCount == 1 -> 80
        else -> TOGGLE_WIDTH_DP
    }

    // ---------------------------------------------------------------- 视图

    /**
     * 单个紧凑 overlay 窗口：**窗口尺寸 = 球组展开尺寸**，贴屏幕右缘。
     *
     * 收起态**不重建窗口**，只把它右移、只留 28dp 在屏幕内 ⇒ 触摸热区也只剩 28dp
     * （屏幕外部分不可触），与「窗口缩到 28dp」等价而不冻结动画（见 [applyCollapsed]）。
     */
    private fun ensureView() {
        if (flutterView != null) return
        collapsed = false
        val flutter = ensureEngine()
        densityValue = context.resources.displayMetrics.density
        rebuildWindow(expandedWidthDp(), topDp = initialTopDp(), engine = flutter)
    }

    /**
     * 按 (展开宽, 竖直位置) 重建窗口。
     *
     * ⚠️ 只在**球数变化**（132/80）时调用 —— 收起/展开**绝不**重建（见 [applyCollapsed]）。
     * 改尺寸会让合成器重分配 surface buffer，旧内容在新 buffer 里按原原点渲染一帧
     * ⇒ 斜向位置伪影（DE23）；这里靠 remove + add 规避。
     */
    private fun rebuildWindow(widthDp: Int, topDp: Int, engine: FlutterEngine) {
        val wm = windowManager
            ?: (context.getSystemService(Context.WINDOW_SERVICE) as? WindowManager)
            ?: return
        val widthPx = dp(widthDp)
        val heightPx = dp(GROUP_HEIGHT_DP)
        val maxTop = (screenHeight() - heightPx).coerceAtLeast(0)
        val y = topPx(topDp).coerceIn(0, maxTop)

        val oldView = flutterView
        if (oldView != null) {
            try {
                wm.removeView(oldView)
            } catch (error: Exception) {
                Log.w(TAG, "removeView for resize failed: ${error.message}")
            }
            flutterView = null
        }

        val view = FlutterView(context, TransparencyMode.transparent)
        view.attachToFlutterEngine(engine)
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
            // **右缘对齐屏幕右缘**（见 [applyCollapsed]）：窗口从左侧收缩时，
            // 最右端的把手在屏幕上原地不动，收起/展开看不出位移。
            x = screenWidth() - widthPx
            this.y = y
        }
        try {
            wm.addView(view, layout)
            windowManager = wm
            flutterView = view
            params = layout
            currentWindowWidthDp = widthDp
            installDragHandle(view)
        } catch (error: Exception) {
            Log.w(TAG, "addView failed: ${error.message}")
        }
    }

    /**
     * 拖动：手指按住球组竖直移动，**窗口跟着走**（不消费事件）。
     *
     * ## 为什么只旁听
     * `setOnTouchListener` 挂在 FlutterView 上时先于 Flutter 的触摸分发执行。
     * 旧实现在 MOVE 超阈值后给 Flutter 发 `ACTION_CANCEL`（想避免「拖完误触点击」），
     * 结果**把手的普通点击也被打断** —— 用户实报「点把手不收起，拖拽时才收起」。
     *
     * ⇒ 现在所有分支返回 `false`、不发 CANCEL；拖动结束后改为让 Dart 侧
     * 抑制**下一次**点击（`suppressTap` 通道消息，见 Dart 的 `suppressTapTick`）。
     */
    private fun installDragHandle(view: FlutterView) {
        view.setOnTouchListener { _, event ->
            val layout = params
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    dragging = false
                    dragStartRawY = event.rawY
                    dragStartY = layout?.y ?: 0
                    false
                }
                MotionEvent.ACTION_MOVE -> {
                    val wm = windowManager
                    if (wm == null || layout == null) return@setOnTouchListener false
                    // 多指（捏合/双指）一律不拖：那是 Flutter 的手势。
                    if (event.pointerCount > 1) {
                        dragging = false
                        return@setOnTouchListener false
                    }
                    val dy = event.rawY - dragStartRawY
                    if (!dragging && Math.abs(dy) < dp(DRAG_SLOP_DP)) {
                        return@setOnTouchListener false
                    }
                    dragging = true
                    val maxY = (screenHeight() - dp(GROUP_HEIGHT_DP)).coerceAtLeast(0)
                    val nextY = (dragStartY + dy).roundToInt().coerceIn(0, maxY)
                    if (nextY != layout.y) {
                        layout.y = nextY
                        try {
                            wm.updateViewLayout(view, layout)
                        } catch (error: Exception) {
                            Log.w(TAG, "drag move failed: ${error.message}")
                        }
                    }
                    false
                }
                MotionEvent.ACTION_UP,
                MotionEvent.ACTION_CANCEL -> {
                    if (dragging) {
                        dragging = false
                        // 告诉 Dart：刚刚拖动过 ⇒ 抑制紧随其后的一次合成 tap。
                        channel?.invokeMethod("suppressTap", null)
                    }
                    false
                }
                else -> false
            }
        }
    }

    /**
     * 收起 / 展开：窗口宽度 132/80dp ↔ 28dp，**右缘对齐屏幕右缘**。
     *
     * ## 语义（不要改，这是用户已验收的「收起」定义）
     * 组件里把手（`_ActivityToggle`）是 `Row` 的**最后一个**子级 ⇒ 它在球组最右端。
     * 窗口右缘恒等于屏幕右缘 ⇒ 窗口从**左侧**收缩到 28dp 时，把手在屏幕上的位置
     * 一个像素都不动，只是两个球滑出窗口被裁掉。
     * 反面做法（窗口整体右移、宽度不变）会把把手推到右边、球半截留在屏幕内 —— 已实测否决。
     */
    private fun applyCollapsed(nextCollapsed: Boolean) {
        if (collapsed == nextCollapsed && flutterView != null) return
        collapsed = nextCollapsed
        mainHandler.removeCallbacks(collapseRebuild)
        if (nextCollapsed) {
            // 🎯 **收起：等动画播完再缩窗口**。
            //
            // 组件里球有 200ms 的滑出 + 淡隐。若点下把手就立刻 removeView+addView，
            // 渲染面在半路消失 ⇒ 动画冻结在中间帧，只有别的手势逼出新帧才继续
            // （用户实报：「要拖拽移动一下才继续播放动画」）。
            // ⇒ 先在宽窗口里把 200ms 播完（球向右滑出窗口，窗口右缘 = 屏幕右缘，
            //    所以视觉上是「滑出去」），再换成 28dp 的窗口 —— 两个动作接得上。
            mainHandler.postDelayed(collapseRebuild, COLLAPSE_SETTLE_MS)
        } else {
            // 🎯 **展开：立刻把窗口撑宽，撑好之后才通知组件播动画**。
            //
            // 反了就会「在 28dp 窗口里滑」⇒ 整段动画被裁掉，球落点也不对
            // （用户实报「展开时悬浮球位置不对」）。
            collapseRebuild.run()
            channel?.invokeMethod("expanded", null)
        }
    }

    /** 按当前收起态重建窗口（收起 = 28dp / 展开 = 132 或 80dp）。 */
    private val collapseRebuild = Runnable {
        val flutter = engine ?: return@Runnable
        if (flutterView == null) return@Runnable
        rebuildWindow(
            if (collapsed) TOGGLE_WIDTH_DP else expandedWidthDp(),
            topDp = currentTopDp(),
            engine = flutter,
        )
    }

    private fun currentTopDp(): Int {
        val layout = params ?: return initialTopDp()
        return (layout.y / densityValue).roundToInt()
    }

    private fun topPx(topDp: Int): Int = dp(topDp)

    private fun initialTopDp(): Int = BALL_TOP_DP

    // ---------------------------------------------------------------- 引擎

    /**
     * 创建第二个引擎（浮层专用）。
     *
     * ⚠️ 用**独立 FlutterEngine**，不用 FlutterEngineGroup：EngineGroup 会让新引擎
     * 复用主引擎的 GPU 上下文，而 overlay 窗口的 surface 与 Activity 的 window surface
     * 不属于同一 EGL 环境，复用的结果是 raster 线程拿不到 current context
     * （`libEGL: call to OpenGL ES API with no current context`）→ 空指针崩溃。
     */
    private fun ensureEngine(): FlutterEngine {
        engine?.let { return it }
        val loader: FlutterLoader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) {
            loader.startInitialization(context)
            loader.ensureInitializationComplete(context, null)
        }
        val entrypoint = DartExecutor.DartEntrypoint(
            loader.findAppBundlePath(),
            ENTRYPOINT,
        )
        val flutter = FlutterEngine(context)
        val dartArgs = pendingPayload?.let { payload ->
            listOf(org.json.JSONObject().put("payload", payload).toString())
        } ?: emptyList()
        flutter.dartExecutor.executeDartEntrypoint(entrypoint, dartArgs)
        val methodChannel = MethodChannel(
            flutter.dartExecutor.binaryMessenger,
            INNER_CHANNEL,
        )
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "ready" -> {
                    engineReady = true
                    pushPayload()
                    result.success(true)
                }
                "ballTap" -> {
                    val kind = call.argument<String>("kind")
                        ?: AylaFloatingBallController.KIND_VOICE
                    val route = call.argument<String>("sourceRoute") ?: ""
                    if (route.isNotEmpty()) {
                        mainHandler.post { onBallTap(kind, route) }
                    }
                    result.success(true)
                }
                "setCollapsed" -> {
                    val next = call.argument<Boolean>("collapsed") == true
                    mainHandler.post { applyCollapsed(next) }
                    result.success(true)
                }
                // 紧凑窗口下这些都不需要（窗口尺寸 = 球组尺寸 ⇒ 无需 hit-rect）。
                "setBallGroupTop", "setHitRects", "setInteractive" -> result.success(true)
                else -> result.notImplemented()
            }
        }
        channel = methodChannel
        engine = flutter
        return flutter
    }

    /** 从最近的 payload 里读出球数（语音/直播各一个）。 */
    private fun updateBallCount() {
        val payload = pendingPayload ?: return
        ballCount = try {
            val json = org.json.JSONObject(payload)
            val hasVoice = json.optString("voiceSessionId", "").isNotEmpty()
            val hasLive = json.optString("liveSessionId", "").isNotEmpty()
            (if (hasVoice) 1 else 0) + (if (hasLive) 1 else 0)
        } catch (error: Exception) {
            0
        }
    }

    /** 把最新投影推给浮层引擎（未 ready 时只记下，报到后补推）。 */
    private fun pushPayload() {
        val payload = pendingPayload ?: return
        updateBallCount()
        // 球数变化 ⇒ 窗口要按新的**目标宽度**重建（收起态恒 28dp，别把它顶回去）。
        if (flutterView != null) {
            val target = if (collapsed) TOGGLE_WIDTH_DP else expandedWidthDp()
            if (target != currentWindowWidthDp) {
                val flutter = engine
                if (flutter != null) {
                    rebuildWindow(target, topDp = currentTopDp(), engine = flutter)
                }
            }
        }
        if (!engineReady) return
        try {
            channel?.invokeMethod("ballPayload", mapOf("payload" to payload))
        } catch (error: Exception) {
            Log.w(TAG, "pushPayload failed: ${error.message}")
        }
    }

    private fun screenWidth(): Int = context.resources.displayMetrics.widthPixels

    private fun screenHeight(): Int = context.resources.displayMetrics.heightPixels

    private fun dp(value: Int): Int =
        (value * context.resources.displayMetrics.density).roundToInt()

    companion object {
        private const val TAG = "AylaOverlayHost"

        /** 第二引擎的 Dart 入口（`lib/main.dart` 的顶层函数，逐字一致）。 */
        const val ENTRYPOINT = "aylaOverlayWindowMain"

        /** 与 Windows 侧同名 ⇒ Dart 侧复用同一个 `AylaOverlayBallWindowApp`。 */
        const val INNER_CHANNEL = "ayla/desktop_window"

        /** 球组高度（两个 44dp 球 + 内边距）。 */
        const val GROUP_HEIGHT_DP = 44

        /** 把手宽度（收起态只剩它）：`AylaSessionActivityIndicator.toggleWidth`。 */
        const val TOGGLE_WIDTH_DP = 28

        /** 球组初始竖直位置（距屏幕顶，逻辑 dp）。 */
        const val BALL_TOP_DP = 120

        /** 判定为拖动的最小位移（dp）。低于它仍算点击。 */
        const val DRAG_SLOP_DP = 8

        /** 收起动画时长（组件是 200ms）之后再重建窗口；留 60ms 余量。 */
        const val COLLAPSE_SETTLE_MS = 260L

        private val mainHandler = Handler(Looper.getMainLooper())
    }
}
