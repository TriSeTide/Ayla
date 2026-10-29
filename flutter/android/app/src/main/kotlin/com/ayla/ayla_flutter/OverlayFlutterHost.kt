package com.ayla.ayla_flutter

import android.content.Context
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
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
    private var flutterView: FlutterView? = null
    private var params: WindowManager.LayoutParams? = null

    private var engineGroup: FlutterEngineGroup? = null
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null

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

    private fun ensureView() {
        if (flutterView != null) return
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as? WindowManager ?: return
        val flutter = ensureEngine()
        // 透明：球/把手有圆角、辉光与半透明玻璃背板，窗口不透明会变成方块黑边。
        val view = FlutterView(context, TransparencyMode.transparent)
        view.attachToFlutterEngine(flutter)

        val widthPx = dp(WINDOW_WIDTH_DP)
        val heightPx = dp(WINDOW_HEIGHT_DP)
        val layout = WindowManager.LayoutParams(
            widthPx,
            heightPx,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            // NOT_FOCUSABLE：不抢 IME / 返回键（用户在其他应用里打字不会被球吞掉）。
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = screenWidth() - widthPx
            // 组件把球放在窗口内 top=80dp 处；把窗口顶边推到屏幕外，
            // 让那 80dp 空白落在状态栏之上（尽量不占屏幕上的可点区域）。
            y = statusBarHeight() - dp(GROUP_TOP_DP)
        }
        wm.addView(view, layout)
        windowManager = wm
        flutterView = view
        params = layout
    }

    private fun ensureEngine(): FlutterEngine {
        engine?.let { return it }
        val loader: FlutterLoader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) {
            // 正常情况下主引擎已经把它初始化过了；这里只做防御。
            loader.startInitialization(context)
            loader.ensureInitializationComplete(context, null)
        }
        val group = FlutterEngineGroup(context)
        engineGroup = group
        val entrypoint = DartExecutor.DartEntrypoint(
            loader.findAppBundlePath(),
            ENTRYPOINT,
        )
        val options = FlutterEngineGroup.Options(context)
            .setDartEntrypoint(entrypoint)
            // ⚠️ 关键：不注册任何插件（见文件头「不注册任何插件」）。
            .setAutomaticallyRegisterPlugins(false)
        // 首个 payload 通过 entrypoint 参数直接给到 Dart：这样**首帧就有正确的球组**，
        // 不会出现「窗口先空一下、再被通道补上」的闪烁。
        // `setDartEntrypointArgs` 只接受 `List<String>` ⇒ 把 payload 包成一条 JSON。
        // 之后的变化走 `ballPayload` 通道（见 [pushPayload]）。
        pendingPayload?.let { payload ->
            options.setDartEntrypointArgs(
                listOf(org.json.JSONObject().put("payload", payload).toString()),
            )
        }
        val flutter = group.createAndRunEngine(options)
        val methodChannel = MethodChannel(
            flutter.dartExecutor.binaryMessenger,
            INNER_CHANNEL,
        )
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "ready" -> {
                    engineReady = true
                    // 引擎起来之前推的 payload 会被丢弃 ⇒ 报到后补推一次。
                    pushPayload()
                    result.success(true)
                }
                "ballTap" -> {
                    val kind = call.argument<String>("kind") ?: AylaFloatingBallController.KIND_VOICE
                    val route = call.argument<String>("sourceRoute") ?: ""
                    if (route.isNotEmpty()) {
                        mainHandler.post { onBallTap(kind, route) }
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

    /** 把最新投影推给浮层引擎（未 ready 时只记下，报到后补推）。 */
    private fun pushPayload() {
        val payload = pendingPayload ?: return
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

        private val mainHandler = Handler(Looper.getMainLooper())
    }
}
