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
import kotlin.math.roundToInt

/**
 * 系统叠加层里的**悬浮球**宿主 —— 第二 FlutterEngine + FlutterView。
 *
 * ## 为什么必须是第二个 engine（而不是原生 View）
 * 用户 2026-10-31 的验收意见（逐字）：
 * > 「**不要造轮子！用现有的悬浮球和直播小窗**」
 * > 「悬浮球不应该重新做一个出来，而是直接原来的浮层悬浮球直接扔出应用窗口外」
 *
 * 结论：叠加层里必须 build **同一份** `AylaSessionActivityIndicator` widget。
 * **本文件一行绘制代码都没有**：视觉 100% 来自 Dart 侧那棵树。
 *
 * ## 窗口几何（2026-11-01 真机定稿）
 * - **宽度 = 当前球组真实宽度**：双球 132dp / 单球 80dp，高恒 44dp
 *   （用户明确：单球时窗口不能按双球宽度算）；
 * - **右边缘为锚点**（`Gravity.RIGHT`）⇒ 改宽度不会移动右边缘；
 * - **收起 = 窗口整体右移** `(宽 − 28dp)`，左侧移出屏幕，屏幕上只剩 28dp 把手
 *   ⇒ 触摸热区 = 窗口∩屏幕 = 28dp，**不挡触摸**。
 *
 * ## 为什么收起不缩窗口而是右移
 * 改窗口宽高会触发 measure/layout → `FlutterView.onSizeChanged` → `setViewportMetrics`，
 * 而**引擎要下一帧才按新尺寸重排**，surface 却立即变 ⇒ 必然出现「新窗口 + 旧布局」
 * 的一帧，表现为内容跳变。**只要改尺寸就一定发生**。
 * ⇒ 收起/展开**只改 x**（宽高不变），从根上没有那一帧。
 *
 * ## 把手为什么在屏幕上纹丝不动
 * 收起时窗口右移 `(宽 − 28dp)`，同时组件把整组**左移同样的量**
 * （见 `session_activity.dart` 的 compact 分支）⇒ 两者抵消，把手固定在屏幕右缘。
 * 两个位移用**同一条 200ms 缓出曲线同步动画**，否则会一先一后
 * （用户实报「把手会超出屏幕外，也会跑到屏幕内」）。
 */
class AylaOverlayFlutterHost(
    private val context: Context,
    /** 点球回房：原生把 (kind, sourceRoute) 转给**主引擎**。 */
    private val onBallTap: (kind: String, sourceRoute: String) -> Unit,
) {
    private var windowManager: WindowManager? = null
    private var flutterView: FlutterView? = null
    private var params: WindowManager.LayoutParams? = null
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null

    private var densityValue = 1f

    /** 当前是否收起（只有把手）。 */
    private var collapsed = false

    /** 当前球数（语音 / 直播各一个），决定窗口宽度。 */
    private var ballCount = 0

    /** 浮层引擎是否已报到（ready）。 */
    private var engineReady = false

    /** 最近一次要显示的投影（JSON 串），引擎 ready 后补推。 */
    private var pendingPayload: String? = null


    /** 拖动状态。 */
    private var dragging = false
    private var dragStartRawY = 0f
    private var dragStartY = 0

    val isShowing: Boolean get() = flutterView != null

    // ================================================================ 生命周期

    /**
     * 显示 / 复用叠加层。
     *
     * @return shown / permissionRequired / unsupported / failed
     */
    fun show(payload: String?): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return AylaFloatingBallController.RESULT_UNSUPPORTED
        }
        if (!canDrawOverlays()) return AylaFloatingBallController.RESULT_PERMISSION_REQUIRED

        pendingPayload = payload
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

    /** 只更新投影（窗口已开时不动窗口）。返回 false = 当前没有窗口。 */
    fun update(payload: String?): Boolean {
        if (flutterView == null) return false
        pendingPayload = payload
        pushPayload()
        return true
    }

    /** 隐藏叠加层（幂等）。 */
    fun hide() {
        val view = flutterView
        val wm = windowManager
        flutterView = null
        windowManager = null
        params = null
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

    fun canDrawOverlays(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            android.provider.Settings.canDrawOverlays(context)
        } else {
            false
        }
    // ================================================================ 尺寸与位置

    /**
     * 窗口宽度（dp）= **当前球组的真实宽度**。
     *
     * 精确到组件几何（session_activity.dart）：ballSize=44 / gap=8 / toggleWidth=28
     *   双球 = 44+8+44+8+28 = 132
     *   单球 = 44+8+28      =  80
     *
     * 单球时窗口只有 80dp —— 不留多余空白（用户明确：单个按钮时窗口没这么长）。
     */
    private fun groupWidthDp(): Int = when {
        ballCount >= 2 -> 132
        ballCount == 1 -> 80
        else -> TOGGLE_WIDTH_DP
    }

    /**
     * 窗口 x（Gravity.RIGHT ⇒ 这是**距父容器右边缘的偏移**，正数向左）。
     *
     * - 展开：0 ⇒ 窗口右边缘 = 屏幕右边缘，整组可见；
     * - 收起：-(宽 − 28dp) ⇒ 窗口右边缘右移出屏幕，屏幕上只剩最左 28dp 的把手。
     */
    private fun targetX(widthPx: Int): Int =
        if (collapsed) -(widthPx - dp(TOGGLE_WIDTH_DP)) else 0

    // ================================================================ 窗口

    private fun ensureView() {
        if (flutterView != null) return
        val flutter = ensureEngine()
        densityValue = context.resources.displayMetrics.density
        createWindow(engine = flutter)
    }

    /** 创建窗口（只在首次调用；之后一律改 LayoutParams）。 */
    private fun createWindow(engine: FlutterEngine) {
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as? WindowManager ?: return
        val widthPx = dp(groupWidthDp())
        val heightPx = dp(GROUP_HEIGHT_DP)

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
            // 必须 RIGHT：START 的位掩码含 CENTER 位，会让 x 变成「相对屏幕中心」，
            // 每次改宽度都从中心重算 ⇒ 横跳。RIGHT 让**右边缘成为不变量**。
            gravity = Gravity.TOP or Gravity.RIGHT
            x = targetX(widthPx)
            y = dp(BALL_TOP_DP)
        }
        try {
            wm.addView(view, layout)
            windowManager = wm
            flutterView = view
            params = layout
            installDragHandle(view)
        } catch (error: Exception) {
            Log.w(TAG, "addView failed: ${error.message}")
        }
    }
    /**
     * 收起 / 展开：**只记状态**，窗口 x 由 Dart 侧每帧驱动（见 `setWindowOffset`）。
     *
     * ## 为什么不在原生侧自己跑动画
     * 窗口位移与组位移必须是**同一个插值变量**，否则两套独立动画（ValueAnimator vs
     * Flutter 的 TweenAnimationBuilder）会因计时/曲线差异在中途错开 ⇒
     * 把手被挤来挤去、短暂跑出屏幕（用户实报）。
     * ⇒ 组件每帧把 `v * shift` 报过来，原生**同一帧**设 x，数学上不可能错位。
     */
    private fun applyCollapsed(nextCollapsed: Boolean) {
        collapsed = nextCollapsed
    }

    /**
     * 组件每帧上报的窗口右移量（dp）。收起动画的中间帧也走这里。
     *
     * 窗口 x = −offsetPx（`Gravity.RIGHT` 下 x 是距右边缘的偏移，正数向左）。
     */
    private fun setWindowOffset(offsetDp: Double) {
        val wm = windowManager ?: return
        val view = flutterView ?: return
        val layout = params ?: return
        val nextX = -dp(offsetDp.toFloat())
        if (nextX == layout.x) return
        layout.x = nextX
        try {
            wm.updateViewLayout(view, layout)
        } catch (error: Exception) {
            Log.w(TAG, "setWindowOffset failed: ${error.message}")
        }
    }

    /**
     * 球数变化 ⇒ 窗口宽度跟着变（132 / 80），**右边缘保持不动**。
     *
     * Gravity.RIGHT 让改宽度天然不移动右边缘，所以「加/减一个球」不会跳；
     * x 同步按新宽度重算（收起态才非 0），保证把手仍在屏幕右缘。
     */
    private fun applyWidthForBallCount() {
        val wm = windowManager ?: return
        val view = flutterView ?: return
        val layout = params ?: return
        val widthPx = dp(groupWidthDp())
        if (layout.width == widthPx) return
        layout.width = widthPx
        layout.x = targetX(widthPx)
        try {
            wm.updateViewLayout(view, layout)
        } catch (error: Exception) {
            Log.w(TAG, "applyWidth failed: ${error.message}")
        }
    }

    // ================================================================ 拖动

    /**
     * 竖直拖动：手指按住球组上下移动，**窗口跟着走**。
     *
     * ## 只旁听，绝不干预 Flutter 事件流
     * 旧实现在 MOVE 超阈值后给 Flutter 发 ACTION_CANCEL（想避免「拖完误触点击」），
     * 结果**把手的普通点击也被打断**（用户实报「点把手不收起，拖拽时才收起」）。
     * ⇒ 所有分支返回 false、不发 CANCEL；拖动结束后让 Dart 侧抑制下一次点击。
     *
     * 只改 y（Gravity.RIGHT 下 x 是右边缘偏移，与竖直拖动无关）。
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
                    // 多指（捏合/双指）不拖：那是 Flutter 的手势。
                    if (event.pointerCount > 1) {
                        dragging = false
                        return@setOnTouchListener false
                    }
                    val dy = event.rawY - dragStartRawY
                    if (!dragging && abs(dy) < dp(DRAG_SLOP_DP)) {
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
    // ================================================================ 引擎

    /**
     * 创建第二个引擎（浮层专用）。
     *
     * 用**独立 FlutterEngine**，不用 FlutterEngineGroup：EngineGroup 会让新引擎
     * 复用主引擎的 GPU 上下文，而 overlay 窗口的 surface 与 Activity 的 window surface
     * 不属于同一 EGL 环境，复用的结果是 raster 线程拿不到 current context
     * （libEGL: call to OpenGL ES API with no current context）→ 空指针崩溃。
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

        // 必须显式把第二引擎的生命周期推到 RESUMED（2026-11-01 真机实测根因）。
        //
        // 现象：点击后动画只播一帧，拖一下窗口才继续。插桩实测：这个引擎**一帧都不出**。
        // 根因：SchedulerBinding 只在收到 flutter/lifecycle 的 resumed/inactive 时才把
        // framesEnabled 打开（scheduler/binding.dart:420-427）；而 overlay 窗口不属于任何
        // FlutterActivity，没有任何东西会给这个引擎发生命周期消息 ⇒ 框架停在 hidden/paused
        // ⇒ scheduleFrame() 直接 return，动画永远停在第 1 帧。
        // 修法：手动发一次 RESUMED，与 FlutterActivity.onResume 同款
        // （FlutterActivityAndFragmentDelegate.java:604）。
        try {
            flutter.lifecycleChannel.appIsResumed()
        } catch (error: Exception) {
            Log.w(TAG, "appIsResumed failed: ${error.message}")
        }

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
                "setWindowOffset" -> {
                    val offset = (call.arguments as? Number)?.toDouble() ?: 0.0
                    setWindowOffset(offset)
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

    /** 从最近的 payload 里读出球数（语音 / 直播各一个）。 */
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
        // 球数变化 ⇒ 先把窗口宽度调到球组真实宽度（右边缘不动），再推 payload。
        applyWidthForBallCount()
        if (!engineReady) return
        try {
            // 随 payload 一起下发「收起时整组左移量」（dp）：窗口宽 − 28。
            // 组件用它做 Transform.translate，与窗口右移量精确互补 ⇒ 把手原地不动。
            val shiftDp = groupWidthDp() - TOGGLE_WIDTH_DP
            channel?.invokeMethod(
                "ballPayload",
                mapOf("payload" to payload, "collapseShift" to shiftDp),
            )
        } catch (error: Exception) {
            Log.w(TAG, "pushPayload failed: ${error.message}")
        }
    }

    private fun screenWidth(): Int = context.resources.displayMetrics.widthPixels

    private fun screenHeight(): Int = context.resources.displayMetrics.heightPixels

    private fun dp(value: Float): Int =
        (value * context.resources.displayMetrics.density).roundToInt()

    private fun dp(value: Int): Int =
        (value * context.resources.displayMetrics.density).roundToInt()

    companion object {
        private const val TAG = "AylaOverlayHost"

        /** 第二引擎的 Dart 入口（lib/main.dart 的顶层函数，逐字一致）。 */
        const val ENTRYPOINT = "aylaOverlayWindowMain"

        /** 与 Windows 侧同名 ⇒ Dart 侧复用同一个 AylaOverlayBallWindowApp。 */
        const val INNER_CHANNEL = "ayla/desktop_window"

        /** 球组高度（球/把手均为 44dp）。 */
        const val GROUP_HEIGHT_DP = 44

        /** 把手宽度（收起态只剩它）：AylaSessionActivityIndicator.toggleWidth。 */
        const val TOGGLE_WIDTH_DP = 28

        /** 球组初始竖直位置（距屏幕顶，逻辑 dp）。 */
        const val BALL_TOP_DP = 120

        /** 判定为拖动的最小位移（dp）。低于它仍算点击。 */
        const val DRAG_SLOP_DP = 8

        /** 收起/展开的窗口位移动画时长（与组件动画一致，200ms）。 */
        const val COLLAPSE_ANIM_MS = 200L

        private val mainHandler = Handler(Looper.getMainLooper())
    }
}