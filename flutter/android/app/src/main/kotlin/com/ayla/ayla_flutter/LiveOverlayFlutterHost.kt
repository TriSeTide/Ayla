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
import io.flutter.plugins.videoplayer.VideoPlayerPlugin
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * 系统叠加层里的**直播小窗**宿主 —— 第二 FlutterEngine + FlutterView。
 *
 * ## 用户要求（2026-11-01 逐字）
 * > 「手机端直播小窗重做，打开的小窗**仍然不是原来的小窗口**，而是直接打开了重新搓的那个新的，
 * >   **新的删掉，用我原来的窗口**」
 *
 * 上一版 Android 走**系统 PiP**（把整个 App 界面缩小）⇒ 用户看到的是「另一个东西」，
 * 不是 App 内那张 `AylaLiveMiniPlayer`（168×94 圆角玻璃卡 + 右上外侧关闭键）。
 * ⇒ 本宿主在叠加层里 build **同一份** `AylaLiveMiniPlayer`
 * （`lib/widgets/live/live_mini_player.dart`，**一行都不改**）。
 *
 * ## 为什么必须在这里注册 video_player（而不是 media_kit）
 * 主引擎 Android 的 HLS 走 **video_player（ExoPlayer）**
 * （`lib/player/platforms/hls_platform.dart` → `video_player_impl.dart`）。
 * 第二引擎若「不注册任何插件」，Dart 侧的 `VideoPlayerController` 调通道会直接
 * `MissingPluginException` ⇒ 小窗里只能是黑框。
 *
 * ⚠️ **不能用 media_kit**：本工程只打包了 `media_kit_libs_windows_video`
 * （`pubspec.yaml` 注释明确写着「Android/iOS 上没有 libmpv」、
 * `pubspec.lock` 里 `media_kit_libs_android` 零命中）⇒ 在 Android 上必然起播失败。
 *
 * ⚠️ **只注册 video_player 一个插件**：livekit_client / flutter_webrtc / record /
 * shared_preferences 一个都不注册 —— 它们要么会起第二份摄像头/麦克风采集，
 * 要么依赖主引擎的登录态。这一层只需要「一路 HLS + 小窗本体」。
 *
 * ## 窗口几何（**贴合卡片**，与悬浮球同一套思路）
 * Android 没有 `SetWindowRgn`、`TOUCHABLE_INSETS_REGION` 是 @hide
 * ⇒ 唯一不依赖隐藏 API 的穿透做法：**窗口只包住卡片**，窗口之外根本不存在矩形。
 *
 * 卡片自己的拖动/双指缩放改的是它**在视口内**的 `left/top/size`。
 * 视口由 Dart 侧报成「整屏」，于是卡片可以被拖/缩到屏幕任意位置；
 * 原生按 Dart 每帧上报的卡片矩形把窗口**跟着挪并改尺寸**。
 *
 * ### 为什么拖动时要临时把窗口撑到整屏（[LiveWindowRootView]）
 * 窗口若**实时**跟着卡片走，手指的「视图内坐标」会被窗口位移抵消
 * ⇒ 组件算出的位移只有真实值的一半（双重计数；悬浮球那边是同一个坑）。
 * ⇒ 手指按下时把窗口原地撑成整屏、原点归 0（此时视图坐标 == 屏幕坐标，
 * 拖动/缩放天然 1:1），抬起后再缩回贴合卡片的窗口。
 * 撑开时原点从 `oldY/oldX` 变成 0 ⇒ 必须把**这一条 DOWN 事件**平移
 * `(+oldX, +oldY)`，否则组件记下的手势起点与后续 MOVE 不在同一坐标系（会跳一下）。
 *
 * ## 通道（与 Dart 侧 `overlay_android_host.dart` 逐字一致）
 * - 原生 → 浮层引擎：`play` { url, title }
 *                      `overlayWindowRect` { x, y, width, height }（逻辑 px，屏幕坐标）
 * - 浮层引擎 → 原生：`ready` → bool
 *                      `close` → bool（关闭键；回传主引擎重建 App 内播放器）
 *                      `activateMain` → bool（点卡片 = 回直播间）
 *                      `setCardRect` { left, top, width, height }（逻辑 px，屏幕坐标）
 * - 原生 → 主引擎：`onLiveWindowClosed`（用户关掉小窗）
 *
 * ## 线程
 * 全部方法必须在**主线程**调用。
 */
class AylaLiveOverlayFlutterHost(
    private val context: Context,
    /** 把主 Activity 拉到前台（点小窗 = 回直播间）。 */
    private val onBringToFront: () -> Unit,
    /** 用户关掉了系统层小窗（主引擎据此重建 App 内播放器）。 */
    private val onClosed: () -> Unit,
) {
    private var windowManager: WindowManager? = null
    private var rootView: LiveWindowRootView? = null
    private var flutterView: FlutterView? = null
    private var params: WindowManager.LayoutParams? = null

    private var engineGroup: FlutterEngineGroup? = null
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null

    private var engineReady = false
    private var pendingUrl: String? = null
    private var pendingTitle: String? = null

    /** 卡片在屏幕上的矩形（逻辑 px；Dart 每帧上报，原生据此贴窗口）。 */
    private var cardLeft = Double.NaN
    private var cardTop = Double.NaN
    private var cardWidth = DEFAULT_CARD_WIDTH_DP
    private var cardHeight = DEFAULT_CARD_HEIGHT_DP

    /** 窗口此刻是不是被临时撑到整屏（手势会话中）。 */
    private var expanded = false

    val isShowing: Boolean
        get() = flutterView != null

    /** 本机是否支持叠加层（TYPE_APPLICATION_OVERLAY 是 API 26+）。 */
    fun isSupported(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O

    fun canDrawOverlays(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            android.provider.Settings.canDrawOverlays(context)
        } else {
            false
        }

    /**
     * 打开 / 复用窗口并起播。
     *
     * @return `"shown"` / `"permissionRequired"` / `"unsupported"` / `"failed"`
     *   —— 与 Dart 侧 `AylaDetachedBallResult` 同一套字面量（`enterDetachedLive`
     *   的 Android 分支据此决定是否回落到 App 内小窗）。
     */
    fun show(url: String?, title: String?): String {
        if (!isSupported()) return AylaFloatingBallController.RESULT_UNSUPPORTED
        if (!canDrawOverlays()) return AylaFloatingBallController.RESULT_PERMISSION_REQUIRED
        pendingUrl = url
        pendingTitle = title
        AylaFloatingBallService.start(context)
        return try {
            ensureView()
            pushPlay()
            AylaFloatingBallController.RESULT_SHOWN
        } catch (error: Exception) {
            Log.w(TAG, "show live overlay failed: ${error.message}", error)
            hide(notify = false)
            AylaFloatingBallController.RESULT_FAILED
        }
    }

    /** 只更新播放地址/标题（切台；窗口与引擎都不重建）。 */
    fun update(url: String?, title: String?): Boolean {
        if (flutterView == null) return false
        pendingUrl = url
        pendingTitle = title
        pushPlay()
        return true
    }

    /**
     * 关闭窗口。
     *
     * [notify] = 是否把「用户关掉了小窗」回传主引擎。Dart 主动关时为 false
     * （调用方自己知道），用户点小窗上的关闭键时为 true。
     */
    fun hide(notify: Boolean) {
        release()
        if (notify) {
            try {
                onClosed()
            } catch (error: Exception) {
                Log.w(TAG, "onClosed failed: ${error.message}")
            }
        }
    }

    private fun release() {
        val view = rootView
        rootView = null
        flutterView = null
        val wm = windowManager
        windowManager = null
        params = null
        expanded = false
        cardLeft = Double.NaN
        cardTop = Double.NaN
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
        engineGroup = null
        engineReady = false
        pendingUrl = null
        pendingTitle = null
        AylaFloatingBallService.stop(context)
    }

    // ---------------------------------------------------------------- 视图

    private fun ensureView() {
        if (flutterView != null) return
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as? WindowManager ?: return
        val flutter = ensureEngine()
        val view = FlutterView(context, TransparencyMode.transparent)
        view.attachToFlutterEngine(flutter)

        val root = LiveWindowRootView(context)
        root.addView(
            view,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
        root.onTouchDown = { expandForDrag() }
        root.onTouchUp = { collapseAfterDrag() }

        val layout = WindowManager.LayoutParams(
            dp(TIGHT_WIDTH_DP),
            dp(TIGHT_HEIGHT_DP),
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            // 初始落点：右下角（与 web `.live-mini-player { right: 16; bottom: 16 }` 同档，
            // 但这里要让出系统导航区，按 24dp 取）。
            x = screenWidth() - width - dp(MARGIN_DP)
            y = screenHeight() - height - dp(MARGIN_DP)
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
            loader.startInitialization(context)
            loader.ensureInitializationComplete(context, null)
        }
        val group = FlutterEngineGroup(context)
        engineGroup = group
        val entrypoint = DartExecutor.DartEntrypoint(
            loader.findAppBundlePath(),
            ENTRYPOINT,
        )
        val args = org.json.JSONObject()
        pendingUrl?.let { args.put("playUrl", it) }
        pendingTitle?.let { args.put("title", it) }
        args.put("kind", "liveMini")
        args.put("viewportHeight", screenHeightLogical())
        args.put("viewportWidth", screenWidthLogical())
        args.put(
            "windowRect",
            org.json.JSONObject()
                .put("x", 0.0)
                .put("y", 0.0)
                .put("width", TIGHT_WIDTH_DP.toDouble())
                .put("height", TIGHT_HEIGHT_DP.toDouble()),
        )
        val options = FlutterEngineGroup.Options(context)
            .setDartEntrypoint(entrypoint)
            // ⚠️ 自动注册必须关掉：否则 livekit/record 会在这层起第二份采集。
            .setAutomaticallyRegisterPlugins(false)
            .setDartEntrypointArgs(listOf(args.toString()))
        val flutter = group.createAndRunEngine(options)

        // 只注册 video_player 一个（见文件头「只注册 video_player 一个插件」）。
        try {
            flutter.plugins.add(VideoPlayerPlugin())
        } catch (error: Exception) {
            Log.w(TAG, "registering VideoPlayerPlugin failed: ${error.message}", error)
        }

        val methodChannel = MethodChannel(
            flutter.dartExecutor.binaryMessenger,
            INNER_CHANNEL,
        )
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "ready" -> {
                    engineReady = true
                    pushPlay()
                    notifyWindowRect()
                    result.success(true)
                }
                "close" -> {
                    // 小窗上的关闭键 ⇒ 关窗口 + 回传主引擎（App 内会话要重新接管播放）。
                    result.success(true)
                    mainHandler.post { hide(notify = true) }
                }
                "activateMain" -> {
                    // 点卡片主体 = 回直播间：先把 App 拉到前台，再关窗口。
                    result.success(true)
                    mainHandler.post {
                        try {
                            onBringToFront()
                        } catch (error: Exception) {
                            Log.w(TAG, "bringToFront failed: ${error.message}")
                        }
                        hide(notify = true)
                    }
                }
                "setCardRect" -> {
                    readCardRect(call.arguments)
                    // 手势进行中窗口已撑到整屏 ⇒ 这时不要动窗口（会打断 1:1）。
                    if (!expanded) applyTightGeometry()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        channel = methodChannel
        engine = flutter
        return flutter
    }

    private fun readCardRect(args: Any?) {
        val map = args as? Map<*, *> ?: return
        val l = (map["left"] as? Number)?.toDouble()
        val t = (map["top"] as? Number)?.toDouble()
        val w = (map["width"] as? Number)?.toDouble()
        val h = (map["height"] as? Number)?.toDouble()
        if (l != null && l.isFinite()) cardLeft = l
        if (t != null && t.isFinite()) cardTop = t
        if (w != null && w.isFinite() && w > 0) cardWidth = w
        if (h != null && h.isFinite() && h > 0) cardHeight = h
    }

    private fun pushPlay() {
        if (!engineReady) return
        try {
            channel?.invokeMethod(
                "play",
                mapOf(
                    "url" to (pendingUrl ?: ""),
                    "title" to (pendingTitle ?: ""),
                ),
            )
        } catch (error: Exception) {
            Log.w(TAG, "pushPlay failed: ${error.message}")
        }
    }

    /** 把窗口当前几何告诉 Dart（它据此把「屏幕坐标」平移进这个小窗口）。 */
    private fun notifyWindowRect() {
        if (!engineReady) return
        val p = params ?: return
        val d = density()
        if (d <= 0) return
        try {
            channel?.invokeMethod(
                "overlayWindowRect",
                mapOf(
                    "x" to p.x / d.toDouble(),
                    "y" to p.y / d.toDouble(),
                    "width" to p.width / d.toDouble(),
                    "height" to p.height / d.toDouble(),
                ),
            )
        } catch (error: Exception) {
            Log.w(TAG, "notifyWindowRect failed: ${error.message}")
        }
    }

    // ------------------------------------------------------- 手势会话（撑开/缩回）

    /**
     * 手指按下：把窗口**原地**撑成整屏、原点归 0。
     *
     * @return 需要给这条 DOWN 事件加的 (x, y) 平移量（px）。
     */
    private fun expandForDrag(): Pair<Int, Int> {
        val p = params ?: return 0 to 0
        if (expanded) return 0 to 0
        val oldX = p.x
        val oldY = p.y
        expanded = true
        p.x = 0
        p.y = 0
        p.width = screenWidth()
        p.height = screenHeight()
        applyLayout()
        notifyWindowRect()
        // 兜底：手势异常结束时不能让整屏一直吞触摸。
        mainHandler.removeCallbacks(collapseGuard)
        mainHandler.postDelayed(collapseGuard, SPURIOUS_EXPAND_MS)
        return oldX to oldY
    }

    /** 手指抬起：缩回贴合卡片的窗口。 */
    private fun collapseAfterDrag() {
        mainHandler.removeCallbacks(collapseGuard)
        if (!expanded) return
        expanded = false
        applyTightGeometry()
        notifyWindowRect()
    }

    private val collapseGuard = Runnable {
        if (expanded) {
            Log.w(TAG, "gesture session did not end; collapsing window")
            expanded = false
            applyTightGeometry()
            notifyWindowRect()
        }
    }

    /**
     * 贴合窗口：包住卡片 + 四周 [CARD_INSET_DP]（关闭键在卡片外侧 `top/right: -10`，
     * 且组件用 `clipBehavior: Clip.none` ⇒ 窗口必须留出这 10dp，否则键被裁掉）。
     *
     * 卡片矩形未知（还没上报过）时保持当前初始落点不动 —— 不能瞎猜。
     */
    private fun applyTightGeometry() {
        val p = params ?: return
        if (cardLeft.isNaN() || cardTop.isNaN()) return
        val d = density().toDouble()
        if (d <= 0) return
        val inset = CARD_INSET_DP
        val widthPx = dp(ceil(cardWidth + inset * 2).toInt())
        val heightPx = dp(ceil(cardHeight + inset * 2).toInt())
        val leftPx = dp(floor(cardLeft - inset).toInt())
        val topPx = dp(floor(cardTop - inset).toInt())
        val maxX = max(0, screenWidth() - widthPx)
        val maxY = max(0, screenHeight() - heightPx)
        p.width = widthPx
        p.height = heightPx
        p.x = leftPx.coerceIn(0, maxX)
        p.y = topPx.coerceIn(0, maxY)
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

    private fun density(): Float = context.resources.displayMetrics.density

    private fun screenWidth(): Int = context.resources.displayMetrics.widthPixels

    private fun screenHeight(): Int = context.resources.displayMetrics.heightPixels

    private fun screenWidthLogical(): Double = (screenWidth() / density()).toDouble()

    private fun screenHeightLogical(): Double = (screenHeight() / density()).toDouble()

    private fun dp(value: Int): Int = (value * density()).roundToInt()

    companion object {
        private const val TAG = "AylaLiveOverlay"

        /** 第二引擎的 Dart 入口（`lib/main.dart`；与 Windows 共用 `aylaLiveWindowMain`）。 */
        const val ENTRYPOINT = "aylaLiveWindowMain"

        /** 与 `overlay_android_host.dart` 的 `kAylaAndroidLiveWindowChannel` 逐字一致。 */
        const val INNER_CHANNEL = "ayla/desktop_window"

        /** 默认卡片逻辑尺寸（`live.css:1026` / `kLiveMiniWidth` / `kLiveMiniHeight`）。 */
        const val DEFAULT_CARD_WIDTH_DP = 168.0
        const val DEFAULT_CARD_HEIGHT_DP = 94.0

        /**
         * 卡片外侧留给关闭键的余量（组件 `top/right: -10` + 24×24 键）。
         * 与 `live_window_surface.dart` 的 `kAylaDetachedMiniInset` **必须一致**。
         */
        const val CARD_INSET_DP = 10

        /** 首帧贴合窗口的占位尺寸（卡片矩形上报前）。 */
        private const val TIGHT_WIDTH_DP = 188
        private const val TIGHT_HEIGHT_DP = 114

        /** 距屏幕右下角的初始边距。 */
        private const val MARGIN_DP = 24

        /** 撑开后若手势一直不结束，最多等这么久就缩回（防止整屏长期吞触摸）。 */
        private const val SPURIOUS_EXPAND_MS = 2000L

        private val mainHandler = Handler(Looper.getMainLooper())
    }
}

/**
 * 直播小窗窗口的根视图 —— **手势会话闸门**。
 *
 * 作用只有一个：在一个手势的生命周期内把窗口撑成整屏、结束后缩回
 * （理由见 [AylaLiveOverlayFlutterHost] 文件头「为什么拖动时要临时把窗口撑到整屏」）。
 *
 * 撑开让窗口原点从 `(oldX, oldY)` 变成 `(0, 0)` ⇒ **这一条 DOWN 事件必须平移**
 * `(+oldX, +oldY)`，否则组件记下的手势起点与后续 MOVE 不在同一坐标系里。
 */
private class LiveWindowRootView(context: Context) : FrameLayout(context) {
    /** 返回需要给 DOWN 事件加的 (x, y) 平移量（px）。 */
    var onTouchDown: (() -> Pair<Int, Int>)? = null
    var onTouchUp: (() -> Unit)? = null

    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        if (ev.actionMasked == MotionEvent.ACTION_DOWN) {
            val shift = onTouchDown?.invoke() ?: (0 to 0)
            if (shift.first != 0 || shift.second != 0) {
                ev.offsetLocation(shift.first.toFloat(), shift.second.toFloat())
            }
        }
        val handled = super.dispatchTouchEvent(ev)
        if (ev.actionMasked == MotionEvent.ACTION_UP ||
            ev.actionMasked == MotionEvent.ACTION_CANCEL
        ) {
            onTouchUp?.invoke()
        }
        return handled
    }
}
