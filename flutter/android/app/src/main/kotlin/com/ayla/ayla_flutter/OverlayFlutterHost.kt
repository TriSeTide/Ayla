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
import android.widget.FrameLayout
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.android.TransparencyMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.FlutterInjector
import io.flutter.plugin.common.MethodChannel
import kotlin.math.max
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
 * ## 2026-11-01 重做：窗口**贴合球组**（背景穿透的唯一正确做法）
 * 上一版窗口是 `176 × 整个工作区高`，透明但**整块矩形吃触摸** ⇒ 用户实报
 * 「**背景不穿透，导致一大片点不了了，要改成只有悬浮球本身可点击**」。
 *
 * Android **没有** `SetWindowRgn` 等价物，`ViewTreeObserver.InternalInsetsInfo`
 * 的 `TOUCHABLE_INSETS_REGION` 是 @hide（反射在 9+ 受限，失败就是「整屏吞触摸」的灾难）
 * ⇒ 唯一不依赖隐藏 API 的做法：**把窗口本身缩成刚好包住球组**。
 * 窗口之外**根本不存在矩形** ⇒ 天然穿透到任何下层应用。
 *
 * ### 坐标空间怎么对上（关键设计，勿凭直觉改）
 * 组件用 `Positioned(right: 24, top: <px>)` 定位，并且把拖动 clamp 在
 * `[8, 视口高 - 44 - 8]`。窗口只有 60dp 高 ⇒ 若让组件看见这个高度，
 * 拖动立刻饱和、球被裁掉（Windows 侧踩过同一个坑，见 `live_window.cpp`
 * 的 `kBallWindowMinHeight` 注释）。
 *
 * ⇒ 两侧约定**同一套坐标**：
 * - Dart 侧把 `MediaQuery` 报成「宽屏宽 × **屏幕可用高度**」⇒ clamp 覆盖全屏，
 *   组件认为自己的坐标原点 = 屏幕顶部；
 * - 原生把窗口放到 `y = groupTop - PAD_TOP`，并让 Dart 知道窗口原点
 *   （通道 `overlayWindowRect`）⇒ Dart 用 `Transform.translate(-窗口原点)`
 *   把「屏幕坐标」映射进这个小窗口。
 * 于是**球的屏幕位置恒等于组件的 top**，1:1 跟随，窗口只是它的取景框。
 *
 * ### 窗口贴合球体，且窗口自身不参与拖动（2026-11-01 重做）
 *
 * 上一版让「按下时把窗口临时撑到整屏、抬起缩回」，用来换取拖动 1:1。
 * 用户实报「交互存在严重问题和截断」，根因就在这套补偿：
 *  · 撑开瞬间窗口原点从 oldY 变 0，只要有一条 MOVE/UP 没走到 offsetLocation
 *    补偿分支，球就跳一大截；
 *  · 抬起缩回按「最后一次上报的 top」重算几何，与组件内部 `_topPx` 存在竞态
 *    ⇒ 球被裁掉 / 显示错位；
 *  · 撑开期间整屏高窗口短暂存在，一旦 UP 被系统吞掉就整屏吃触摸。
 *
 * 现在**窗口始终 60dp 高、始终贴合球体，自身完全不参与拖动**：
 * Dart 侧把 MediaQuery 报成屏幕尺寸 ⇒ 组件在「屏幕坐标系」里自己算 top
 * （clamp 覆盖全屏，不会饱和）⇒ 原生只做一件事：把窗口摆到组件算出的 top 上。
 * 组件坐标恒等于屏幕坐标，因此**不需要任何偏移补偿**，也就没有跳动与裁切的来源。
 *
 * ## 引擎组而不是裸 engine
 * [FlutterEngineGroup] 复用主引擎已加载的 AOT 快照与 VM 资源，冷启动快得多，
 * 并且天然共享同一份 `kernel_blob`。入口用 [DartExecutor.DartEntrypoint] 指定
 * `aylaOverlayWindowMain`（`lib/main.dart` 的顶层函数，带 `@pragma('vm:entry-point')`）。
 *
 * ## 不注册任何插件
 * `setAutomaticallyRegisterPlugins(false)` ⇒ media_kit / webrtc / record / livekit
 * 一个都不会在第二引擎里起第二份。这一层只需要「画球 + 一条 MethodChannel」。
 * （直播小窗那一路要视频，它是**另一个**宿主：[AylaLiveOverlayFlutterHost]，
 *  那里只注册 video_player 一个插件。）
 *
 * ## 通道（与 Dart 侧 `overlay_android_host.dart` 逐字一致）
 * - 原生 → 浮层引擎：`ballPayload` { payload: String }
 *                      `overlayWindowRect` { x, y, width, height }（逻辑 px，屏幕坐标）
 * - 浮层引擎 → 原生：`ready` → bool
 *                      `ballTap` { kind, sourceRoute } → bool（点球回房，**同时把 App 拉到前台**）
 *                      `setBallGroupTop` { top } → bool（组件拖出来的新 top，逻辑 px）
 * - 原生 → 主引擎：沿用既有 `ayla/live_pip` 的 `onBallTap`（Dart 侧
 *   `AylaDetachedLiveEvents` 已经在监听，不新增事件类型）。
 *
 * ## 线程
 * 全部方法必须在**主线程**调用（`WindowManager.addView` 与 engine 创建都要求）。
 * MainActivity 的 MethodChannel 回调天然在主线程。
 */
class AylaOverlayFlutterHost(
    private val context: Context,
    /** 点球回房：原生把 (kind, sourceRoute) 转给**主引擎**（在此之前 App 已被拉到前台）。 */
    private val onBallTap: (kind: String, sourceRoute: String) -> Unit,
    /** 把主 Activity 拉到前台（点球必须**先**唤起 App，再看导航；见 MainActivity.bringAppToFront）。 */
    private val onBringToFront: () -> Unit,
) {
    private var windowManager: WindowManager? = null
    private var rootView: FrameLayout? = null
    private var flutterView: FlutterView? = null
    private var params: WindowManager.LayoutParams? = null

    private var engineGroup: FlutterEngineGroup? = null
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null

    /** 最近一次要显示的投影（JSON 串）。浮层引擎 `ready` 之后补推一次。 */
    private var pendingPayload: String? = null

    /** 浮层引擎是否已经报到（`ready`）。 */
    private var engineReady = false

    /** 球组当前 top（逻辑 px，屏幕坐标；由 Dart 侧拖动上报）。 */
    private var groupTopDp: Double = DEFAULT_GROUP_TOP_DP

    /** 窗口此刻是不是被临时撑到整屏（拖动会话中）。 */

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
        val view = rootView
        rootView = null
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

        // 窗口根 = 触摸闸门（见文件头「拖动时为什么要把窗口撑到整屏」）。
        val root = FrameLayout(context)
        root.addView(
            view,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
        // ⚠️ 2026-11-01 重做：**不再挂 expandForDrag / collapseAfterDrag**。
        //
        // 那套「按下把窗口撑到整屏 + 给 DOWN 补 offsetLocation + 抬起缩回」是
        // 上一版「交互严重问题 + 截断」的直接来源：
        //   · 撑开瞬间窗口原点从 oldY 变 0；只要有一条 MOVE/UP 没走到补偿分支，
        //     球就跳一大截；
        //   · 抬起缩回按「最后一次上报的 top」重算几何，与组件内部 _topPx 存在
        //     竞态 ⇒ 球被裁掉或错位；
        //   · 撑开期间整屏高窗口短暂存在，一旦 UP 被系统吞掉就整屏吃触摸
        //     （虽有 3s 兜底，仍是隐患）。
        //
        // 现在窗口**始终贴合球体、自身不参与拖动**：Dart 侧 MediaQuery 报屏幕尺寸
        // ⇒ 组件在「屏幕坐标系」里自己算 top（clamp 覆盖全屏）⇒ 原生只把窗口摆到
        // 那个 top 上。组件坐标 == 屏幕坐标，无需任何 offset 补偿，
        // 也就没有跳动与裁切的来源。

        val widthPx = dp(WINDOW_WIDTH_DP)
        val layout = WindowManager.LayoutParams(
            widthPx,
            dp(WINDOW_HEIGHT_DP),
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            // NOT_FOCUSABLE：不抢 IME / 返回键（用户在其他应用里打字不会被球吞掉）。
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = screenWidth() - widthPx
            y = tightTopPx()
            height = dp(WINDOW_HEIGHT_DP)
        }
        wm.addView(root, layout)
        windowManager = wm
        rootView = root
        flutterView = view
        params = layout
        notifyWindowRect()
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
        // 首个 payload + **视口几何**通过 entrypoint 参数直接给到 Dart：
        // 这样首帧就有正确的球组与坐标系，不会出现「窗口先空一下、再被通道补上」的闪烁。
        // `setDartEntrypointArgs` 只接受 `List<String>` ⇒ 把 payload 包成一条 JSON。
        val args = org.json.JSONObject()
        pendingPayload?.let { payload -> args.put("payload", payload) }
        args.put("viewportHeight", screenHeightLogical())
        args.put("viewportWidth", screenWidthLogical())
        args.put(
            "windowRect",
            org.json.JSONObject()
                .put("x", (screenWidth() - dp(WINDOW_WIDTH_DP)) / density().toDouble())
                .put("y", tightTopPx() / density().toDouble())
                .put("width", WINDOW_WIDTH_DP.toDouble())
                .put("height", WINDOW_HEIGHT_DP.toDouble()),
        )
        args.put("groupTop", groupTopDp)
        options.setDartEntrypointArgs(listOf(args.toString()))
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
                    notifyWindowRect()
                    result.success(true)
                }
                "ballTap" -> {
                    val kind = call.argument<String>("kind") ?: AylaFloatingBallController.KIND_VOICE
                    val route = call.argument<String>("sourceRoute") ?: ""
                    // ⚠️ **先把 App 拉到前台，再转发导航**（用户实报：App 在后台时点球叫不出 Ayla）。
                    // App 在后台时主引擎的 Flutter 可能已暂停/停止，通道回调能到但
                    // `context.go` 不会凭空把进程切到前台 ⇒ 唤起必须由原生做。
                    mainHandler.post {
                        try {
                            onBringToFront()
                        } catch (error: Exception) {
                            Log.w(TAG, "bringToFront failed: ${error.message}")
                        }
                        if (route.isNotEmpty()) onBallTap(kind, route)
                    }
                    result.success(true)
                }
                "setBallGroupTop" -> {
                    val top = readDouble(call.arguments, "top")
                    if (top != null && top.isFinite()) {
                        groupTopDp = currentGroupTop(top)
                        applyTightGeometry()
                        notifyWindowRect()
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

    /** 把窗口当前几何告诉 Dart（它据此把「屏幕坐标」平移进这个小窗口）。 */
    private fun notifyWindowRect() {
        if (!engineReady) return
        val p = params ?: return
        val density = density()
        if (density <= 0) return
        try {
            channel?.invokeMethod(
                "overlayWindowRect",
                mapOf(
                    "x" to p.x / density.toDouble(),
                    "y" to p.y / density.toDouble(),
                    "width" to p.width / density.toDouble(),
                    "height" to p.height / density.toDouble(),
                ),
            )
        } catch (error: Exception) {
            Log.w(TAG, "notifyWindowRect failed: ${error.message}")
        }
    }


    /** 贴合窗口：`y = top - PAD_TOP`，高度 = 球组 + 上下余量。 */
    private fun applyTightGeometry() {
        val p = params ?: return
        p.width = dp(WINDOW_WIDTH_DP)
        p.x = screenWidth() - p.width
        p.height = dp(WINDOW_HEIGHT_DP)
        p.y = tightTopPx()
        applyLayout()
    }

    private fun applyLayout() {
        val p = params ?: return
        val v = rootView ?: return
        val wm = windowManager ?: return
        try {
            wm.updateViewLayout(v, p)
        } catch (error: Exception) {
            Log.w(TAG, "updateViewLayout failed: ${error.message}")
        }
    }

    /** 组 top（逻辑 px，屏幕坐标）⇒ 窗口 y（px），并 clamp 在屏幕内。 */
    private fun tightTopPx(): Int {
        val raw = (groupTopDp * density()).roundToInt() - dp(PAD_TOP_DP)
        val maxY = max(0, screenHeight() - dp(WINDOW_HEIGHT_DP))
        return raw.coerceIn(0, maxY)
    }

    // ---------------------------------------------------------------- 工具

    private fun density(): Float = context.resources.displayMetrics.density

    private fun screenWidth(): Int = context.resources.displayMetrics.widthPixels

    private fun screenHeight(): Int = context.resources.displayMetrics.heightPixels

    private fun screenWidthLogical(): Double = (screenWidth() / density()).toDouble()

    private fun screenHeightLogical(): Double = (screenHeight() / density()).toDouble()

    private fun dp(value: Int): Int = (value * density()).roundToInt()

    private fun readDouble(args: Any?, key: String): Double? {
        val map = args as? Map<*, *> ?: return null
        return when (val raw = map[key]) {
            is Number -> raw.toDouble()
            else -> null
        }
    }

    /**
     * 组件拖出来的 top 是「相对窗口原点」的屏幕坐标 —— 窗口**没动**（撑开状态下原点 0），
     * 所以它已经是屏幕坐标，直接用。
     *
     * 这里只做一次「与窗口原点的自洽」：若收到的是负数（异常输入），退回默认 top。
     */
    private fun currentGroupTop(raw: Double): Double =
        if (raw.isFinite() && raw >= 0) raw else DEFAULT_GROUP_TOP_DP

    companion object {
        private const val TAG = "AylaOverlayHost"

        /** 第二引擎的 Dart 入口（`lib/main.dart` 的顶层函数，逐字一致）。 */
        const val ENTRYPOINT = "aylaOverlayWindowMain"

        /** 与 `overlay_android_host.dart` 的 `kAylaAndroidOverlayChannel` 逐字一致。 */
        const val INNER_CHANNEL = "ayla/overlay_android"

        /**
         * 球组四周为「阴影/辉光外溢」预留的逻辑像素。
         *
         * 取自 `_kActivityShadow`：`blurRadius: 12` + `offset.dy: 2` ⇒ 14，向上取整到 16。
         * 这是**纯视觉留白**，不是点击区域（点击区域仍是窗口矩形，而窗口只有这么大）。
         *
         * 必须声明在 [WINDOW_WIDTH_DP] / [WINDOW_HEIGHT_DP] **之前**
         * （Kotlin 的 const 初始化顺序按声明位置求值）。
         */
        const val BALL_GLOW_PAD_DP = 16

        /**
         * 窗口逻辑宽度（dp）。
         *
         * 球组最大宽 = 44(语音球) + 8(gap) + 44(直播球) + 8(gap) + 28(把手) = 132；
         * 组件自带 `right: 24` 内缩 ⇒ 需要 156；左右再各留 [BALL_GLOW_PAD_DP] 的
         * 阴影外溢 ⇒ 160 + 2*[BALL_GLOW_PAD_DP]。
         *
         * ⚠️ **窗口外根本不存在矩形** —— 这是「只有球可点」的实现方式，
         * 上一版是 176 × 整屏高，用户实报「一大片点不了」。
         */
        const val WINDOW_WIDTH_DP = 160 + 2 * BALL_GLOW_PAD_DP

        /**
         * 窗口逻辑高度（dp）：球组 44 + 上下阴影外溢。
         *
         * ⚠️ 2026-11-01 修正「球被截断锁死」：球本身带
         * `BoxShadow(blurRadius: 12, offset: (0,2))`（session_activity.dart:88–94），
         * 视觉上向外溢出约 `blurRadius + |offsetY|` ≈ 14dp。
         * 旧值 60 只留了 8dp ⇒ 上下各有约 6dp 被窗口边缘切掉，看起来就是「截断」。
         * 现在按真实外溢量留白。
         */
        const val WINDOW_HEIGHT_DP = 44 + 2 * BALL_GLOW_PAD_DP

        /** 球组上方的余量（与 [BALL_GLOW_PAD_DP] 同一口径）。 */
        const val PAD_TOP_DP = BALL_GLOW_PAD_DP

        /** 组件在**宽屏档**下的默认 top（`shell.css:462` 的 `top: 80px`）⇒ 首帧落点。 */
        const val DEFAULT_GROUP_TOP_DP = 80.0

        /** 撑开后若一直没有新的 top 上报，最多等这么久就缩回（防止整屏长期吞触摸）。 */

        private val mainHandler = Handler(Looper.getMainLooper())
    }
}
