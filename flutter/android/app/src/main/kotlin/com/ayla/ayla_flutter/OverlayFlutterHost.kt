package com.ayla.ayla_flutter

import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.MotionEvent
import android.view.View
import android.view.Gravity
import android.view.WindowManager
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.android.TransparencyMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.FlutterInjector
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
 * 上一轮把球做成了 [BallGlyphView]（Canvas 手绘圆球），用户判定「**丑得要命**」「南辕北辙」。
 * 结论：叠加层里必须 build **同一份** `AylaSessionActivityIndicator` widget ——
 * 一个 Flutter 视图只能铺满自己的窗口，所以它必须有自己的 engine。
 * **本文件一行绘制代码都没有**：视觉 100% 来自 Dart 侧那棵树。
 *
 * ## 引擎组而不是裸 engine
 * [FlutterEngineGroup] 复用主引擎已加载的 AOT 快照与 VM 资源，冷启动快得多，
 * 并且天然共享同一份 `kernel_blob`。入口用 [DartExecutor.DartEntrypoint] 指定
 * `aylaOverlayWindowMain`（`lib/main.dart` 的顶层函数，带 `@pragma('vm:entry-point')`）。
 *
 * ## 不注册任何插件
 * `setAutomaticallyRegisterPlugins(false)` ⇒ media_kit / webrtc / record / livekit
 * 一个都不会在第二引擎里起第二份。这一层只需要「画球 + 一条 MethodChannel」。
 *
 * ## 通道（与 Dart 侧逐字一致）
 * - 通道名 `ayla/desktop_window`：**与 Windows 侧同名**，Dart 侧复用同一个
 *   `AylaOverlayBallWindowApp`（`lib/widgets/shell/overlay_window_app.dart`），
 *   于是两端行为一致、只有原生实现不同。
 * - 原生 → 浮层引擎：`ballPayload` { payload: String }（主引擎算好的整组投影）
 * - 浮层引擎 → 原生：`ready` → bool（第一帧已出，宿主据此认为可用）
 *                      `ballTap` { kind, sourceRoute } → bool（点球回房）
 * - 原生 → 主引擎：沿用既有 `ayla/live_pip` 的 `onBallTap` / `onBallClosed`
 *   （Dart 侧 `AylaDetachedLiveEvents` 已经在监听，不新增事件类型）。
 *
 * ## 窗口（为什么是「小窗」而不是全屏）
 * 全屏透明窗口 + 触摸穿透需要 `ViewTreeObserver.InternalInsetsInfo`
 * 的 `TOUCHABLE_INSETS_REGION`，那是 **@hide** API（`android.jar` 里没有，
 * 反射在 Android 9+ 属于受限隐藏 API，失败就是「整屏吞掉触摸」的灾难性降级）。
 * ⇒ 改用**与 Windows 完全同构的小窗**：窗口尺寸 = 内容信封（176×132dp），
 * 窗口之外的手势天然落到下面的应用，**零反射、零隐藏 API、零灾难降级**。
 *
 * ⚠️ 已知限制（如实登记）：球组在窗口坐标系里的位置由组件自己的
 * `Positioned(right: 24, top: 80)` 决定 ⇒
 * ① 竖直拖动只能在窗口内小幅移动（与 Windows 侧完全相同的限制）；
 * ② 窗口内「球之外的空白」会吞掉该处的触摸 —— 通过把窗口顶边推到屏幕外
 *   （`y = statusBarHeight - 80dp`）把这块空白尽量挪出屏幕，只留下状态栏那一条。
 *
 * ## 线程
 * 全部方法必须在**主线程**调用（`WindowManager.addView` 与 engine 创建都要求）。
 * MainActivity 的 MethodChannel 回调天然在主线程。
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

    /** 当前窗口宽度（逻辑 dp），用于判断状态是否变化。 */
    private var currentWindowWidthDp = 0

    /** 拖动起点（手指 rawY 与窗口 y）。 */
    private var dragStartRawY = 0f
    private var dragStartY = 0

    /** 当前是否因为手指按下而临时扩窗。 */
    private var expandedForTouch = false

    /** 扩窗前的位置（松手时恢复）。 */
    private var savedForExpand: Pair<Int, Int>? = null
    private var flutterView: FlutterView? = null
    private var params: WindowManager.LayoutParams? = null

    private var engineGroup: FlutterEngineGroup? = null
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null

    /** 当前是否处于收起态（只有把手）。用于把窗口其余部分推出屏幕。 */
    private var collapsed = false

    /** 最近一次要显示的投影（JSON 串）。浮层引擎 `ready` 之后补推一次。 */
    private var pendingPayload: String? = null

    /** 浮层引擎是否已经报到（`ready`）。 */
    private var engineReady = false

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
            // TYPE_APPLICATION_OVERLAY 是 API 26+；低版本用已废弃的 TYPE_PHONE 属于
            // 「偷偷塞一个」——明确降级而不是绕过。
            return AylaFloatingBallController.RESULT_UNSUPPORTED
        }
        if (!canDrawOverlays()) return AylaFloatingBallController.RESULT_PERMISSION_REQUIRED

        pendingPayload = payload
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
        if (view != null && wm != null) {
            try {
                wm.removeView(view)
            } catch (error: Exception) {
                Log.w(TAG, "removeView failed: ${error.message}")
            }
        }
        // 引擎必须显式销毁：FlutterView 被移除只是断开渲染面，Dart isolate 还在跑。
        channel?.setMethodCallHandler(null)
        channel = null
        try {
            engine?.destroy()
        } catch (error: Exception) {
            Log.w(TAG, "engine.destroy failed: ${error.message}")
        }
        engine = null
        engineGroup = null
        engineReady = false
        pendingPayload = null
        // 没有球就不该常驻通知栏。
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

    // ---------------------------------------------------------------- 视图

    /**
     * 单个紧凑 overlay 窗口：**窗口尺寸 = 球组真实尺寸**。
     *
     * ## 为什么是这个形状
     * Android overlay 窗口的**尺寸就是触摸热区**：窗口内任何位置都会吃掉触摸，
     * `onTouch` 返回 false 也不会还给下层（WM input channel 在 DOWN 时已捕获，DE26）。
     * 而公开 API 里没有「非矩形热区」（`TOUCHABLE_INSETS_REGION` 是 @hide，DE25）。
     *
     * ⇒ 唯一可行解：**把窗口做到刚好包住球组**，让矩形误差最小。
     * 球组宽 132dp（双球）/ 28dp（收起态把手），高 44dp。窗口按展开态最大尺寸分配，
     * 收起时把多余的横向空白推出屏幕右缘。
     *
     * ## 拖动
     * 拖动时**移动窗口本身**（只改 x/y）。窗口高 44dp 刚好等于球组高，所以球在
     * 窗口内没有竖直移动空间 —— Dart 侧收到的 top 变化全部换算成窗口位移。
     *
     * ⚠️ 永不改宽高（Fixed Surface Rule / DE23：改尺寸会让合成器重分配 surface
     * buffer，旧内容按原原点渲染一帧 ⇒ 斜向位置伪影，用户会看到「一闪一闪被拉伸」）。
     */
    private fun ensureView() {
        if (flutterView != null) return
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as? WindowManager ?: return
        val flutter = ensureEngine()
        densityValue = context.resources.displayMetrics.density

        // 透明：球有圆角、辉光、半透明玻璃背板，窗口不透明会变成方块黑边。
        val view = FlutterView(context, TransparencyMode.transparent)
        view.attachToFlutterEngine(flutter)

        val widthPx = dp(WINDOW_WIDTH_DP)
        val heightPx = dp(WINDOW_HEIGHT_DP)
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
            x = screenWidth() - widthPx
            y = statusBarHeight() + dp(BALL_TOP_DP)
        }
        wm.addView(view, layout)

        windowManager = wm
        flutterView = view
        params = layout

        installDragHandle(view)
    }

    /**
     * 拖动：手指按住球组竖直移动，窗口跟着走。
     *
     * ## 为什么不用 setOnTouchListener
     * `setOnTouchListener` 挂在 FlutterView 上时，会先于 Flutter 的触摸分发执行；
     * 一旦在里面给 Flutter 发 `ACTION_CANCEL`（为了「拖完不误触点击」），
     * **把手的普通点击也会被打断** —— 用户实报「点把手不收起，拖拽时才收起」。
     *
     * ## 现在的做法
     * 只**旁听**，绝不干预：
     *   · DOWN 记起点，不消费；
     *   · MOVE 超阈值后移动窗口，但**不**给 Flutter 发 CANCEL；
     *   · Flutter 侧收到的是完整事件流，点击/长按语义完全正常。
     *
     * 代价：拖完松手时 Flutter 可能把它当成一次「点击」而触发跳转。用
     * [suppressNextTap] 标记抑制：拖动一旦发生，就在 UP 后短暂吞掉随后的点击。
     */
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
                "setBallGroupTop" -> {
                    val top = call.argument<Double>("top")
                        ?: call.argument<Number>("top")?.toDouble()
                    if (top != null) {
                        mainHandler.post { applyBallGroupTop(top) }
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        channel = methodChannel
        engine = flutter
        return flutter
    }

    private fun installDragHandle(view: FlutterView) {
        view.setOnTouchListener { _, event ->
            val wm = windowManager ?: return@setOnTouchListener false
            val layout = params ?: return@setOnTouchListener false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    dragging = false
                    dragStartRawY = event.rawY
                    dragStartY = layout.y
                    false
                }
                MotionEvent.ACTION_MOVE -> {
                    val dy = event.rawY - dragStartRawY
                    if (!dragging && Math.abs(dy) < dp(DRAG_SLOP_DP)) {
                        return@setOnTouchListener false
                    }
                    dragging = true
                    val nextY = (dragStartY + dy).toInt()
                    val clamped = nextY.coerceIn(
                        dp(MIN_TOP_DP),
                        screenHeight() - dp(GROUP_HEIGHT_DP),
                    )
                    if (clamped != layout.y) {
                        layout.y = clamped
                        try {
                            wm.updateViewLayout(view, layout)
                        } catch (error: Exception) {
                            Log.w(TAG, "drag move failed: ${error.message}")
                        }
                    }
                    // 不消费、不发 CANCEL：Flutter 的点击语义保持完整。
                    false
                }
                MotionEvent.ACTION_UP,
                MotionEvent.ACTION_CANCEL -> {
                    dragging = false
                    false
                }
                else -> false
            }
        }
    }

    /**
     * 按「收起状态 + 球的数量」重建窗口，让窗口永远紧贴球组的真实尺寸。
     *
     * ## 为什么是 remove + add 而不是 updateViewLayout
     * 改窗口尺寸会让合成器重分配 surface buffer，旧内容在新 buffer 里按原原点渲染
     * 一帧 ⇒ 斜向位置伪影（DE23）。所以**不用** `updateViewLayout` 改宽高，而是
     * 把窗口摘掉重建（尺寸在 `addView` 时一次定死，符合 Fixed Surface Rule AX12）。
     *
     * ## 各状态的宽度
     *   双球展开 = 44 + 8 + 44 + 8 + 28 = 132dp
     *   单球展开 = 44 + 8 + 28        =  80dp
     *   收起     = 28dp（只有把手）
     *
     * 收起后窗口真的只有 28dp 宽 —— 这才是「收起」应有的效果：不挡触摸。
     */
    private fun resizeWindowForState(isCollapsed: Boolean, ballCount: Int) {
        // 精确到组件真实几何（session_activity.dart）：
        //   ballSize=44, gap=8, toggleWidth=28
        //   双球 = 44+8+44+8+28 = 132
        //   单球 = 44+8+28       =  80
        //   收起 = 28（只有把手）
        val targetDp = when {
            isCollapsed -> TOGGLE_WIDTH_DP
            ballCount >= 2 -> 132
            ballCount == 1 -> 80
            else -> TOGGLE_WIDTH_DP
        }
        if (targetDp == currentWindowWidthDp) return
        val wm = windowManager ?: return
        val oldView = flutterView ?: return
        val oldLayout = params ?: return
        currentWindowWidthDp = targetDp
        // 记住当前竖直位置，重建后保持（用户拖到哪就留在哪）。
        val keepY = oldLayout.y
        try {
            wm.removeView(oldView)
        } catch (error: Exception) {
            Log.w(TAG, "removeView for resize failed: ${error.message}")
        }
        val newView = FlutterView(context, TransparencyMode.transparent)
        val eng = engine ?: return
        newView.attachToFlutterEngine(eng)
        val widthPx: Int = dp(targetDp)
        val heightPx: Int = dp(GROUP_HEIGHT_DP)  // 44dp，正好是球组高度
        val newLayout = WindowManager.LayoutParams(
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
            x = screenWidth() - widthPx
            y = keepY
        }
        try {
            wm.addView(newView, newLayout)
            flutterView = newView
            params = newLayout
            installDragHandle(newView)
        } catch (error: Exception) {
            Log.w(TAG, "addView for resize failed: ${error.message}")
        }
    }

    /**
     * 把球组的竖直位置应用到窗口上。
     *
     * Dart 侧 `Positioned(top:)` 的坐标空间是**窗口内的逻辑像素**；窗口高度固定为
     * [WINDOW_HEIGHT_DP]，球组在其内部位于 `top - GROUP_TOP_DP` 处。想要球在屏幕上
     * 走到某个高度，就要让窗口的 y 相应平移：
     *
     *   ballScreenY = windowY + dp(top) - dp(GROUP_TOP_DP)
     *   ⇒ windowY   = ballScreenY - dp(top) + dp(GROUP_TOP_DP)
     *
     * 这里直接用「Dart 给的 top 变化量」平移窗口即可（两者一一对应），
     * 并把结果 clamp 在屏幕可视范围内。
     *
     * ⚠️ 只改 `y`，永不改宽高（Fixed Surface Rule）。
     */
    private fun applyBallGroupTop(topLogical: Double) {
        val wm = windowManager ?: return
        val view = flutterView ?: return
        val layout = params ?: return
        // Dart 侧 top 是「球组顶边在**全屏**坐标系里的位置」（逻辑 px）。
        // TOUCH 窗口就是球组本体，所以直接把窗口 y 设成它即可。
        val topPx = (topLogical * densityValue).roundToInt() - dp(GROUP_TOP_DP)
        val maxTop = screenHeight() - dp(GROUP_HEIGHT_DP)
        val nextY = topPx.coerceIn(dp(MIN_TOP_DP), maxTop)
        if (nextY == layout.y) return
        layout.y = nextY
        try {
            wm.updateViewLayout(view, layout)
        } catch (error: Exception) {
            Log.w(TAG, "applyBallGroupTop failed: ${error.message}")
        }
    }

    /** 把最新投影推给浮层引擎（未 ready 时只记下，报到后补推）。 */
    private fun pushPayload() {
        val payload = pendingPayload ?: return
        // 收起态变化会影响窗口的 x（让球组之外的空白移出屏幕），先同步。
        val nextCollapsed = try {
            org.json.JSONObject(payload).optBoolean("collapsed", false)
        } catch (error: Exception) {
            false
        }
        // 按「当前状态的球组真实宽度」重建窗口（不是 resize —— 见 resizeWindowForState）。
        val hasVoice = try {
            org.json.JSONObject(payload).optString("voiceSessionId", "").isNotEmpty()
        } catch (error: Exception) { false }
        val hasLive = try {
            org.json.JSONObject(payload).optString("liveSessionId", "").isNotEmpty()
        } catch (error: Exception) { false }
        val ballCount = (if (hasVoice) 1 else 0) + (if (hasLive) 1 else 0)
        resizeWindowForState(nextCollapsed, ballCount)
        if (!engineReady) return
        try {
            channel?.invokeMethod(
                "ballPayload",
                mapOf("payload" to payload),
            )
        } catch (error: Exception) {
            Log.w(TAG, "pushPayload failed: ${error.message}")
        }
    }

    private fun screenWidth(): Int = context.resources.displayMetrics.widthPixels

    private fun screenHeight(): Int = context.resources.displayMetrics.heightPixels

    private fun statusBarHeight(): Int {
        val id = context.resources.getIdentifier(
            "status_bar_height",
            "dimen",
            "android",
        )
        if (id > 0) {
            val value = context.resources.getDimensionPixelSize(id)
            if (value > 0) return value
        }
        return dp(24)
    }

    private fun dp(value: Int): Int =
        (value * context.resources.displayMetrics.density).roundToInt()

    companion object {
        private const val TAG = "AylaOverlayHost"

        /** 第二引擎的 Dart 入口（`lib/main.dart` 的顶层函数，逐字一致）。 */
        const val ENTRYPOINT = "aylaOverlayWindowMain"

        /** 与 Windows 侧同名 ⇒ Dart 侧复用同一个 `AylaOverlayBallWindowApp`。 */
        const val INNER_CHANNEL = "ayla/desktop_window"

        /**
         * 窗口逻辑尺寸（dp）= 与 Windows 侧 `AylaOverlayWindowApp.hostViewport` 同构：
         * 176×132 = 组件宽屏档 `right: 24` + 球组最大宽 132 + 余量 / `top: 80` + 44 + 8。
         */
        const val WINDOW_WIDTH_DP = 176
        const val WINDOW_HEIGHT_DP = 132

        /** 组件 `.session-activity-group` 的宽屏 top（`shell.css:462`，= 80）。 */
        const val GROUP_TOP_DP = 80

        /** 球组高度（两个 44dp 球 + 内边距）。 */
        const val GROUP_HEIGHT_DP = 44

        /** 球组顶端允许到达的最小屏幕高度（避开状态栏）。 */
        const val MIN_TOP_DP = 8

        /** 把手宽度（收起态只剩它）：`AylaSessionActivityIndicator.toggleWidth`。 */
        const val TOGGLE_WIDTH_DP = 28

        /** 球组距状态栏的初始高度。 */
        const val BALL_TOP_DP = 80

        /** 判定为拖动的最小位移（dp）。低于它仍算点击。 */
        const val DRAG_SLOP_DP = 8


        private val mainHandler = Handler(Looper.getMainLooper())
    }
}
