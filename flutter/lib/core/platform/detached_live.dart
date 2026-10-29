/// 直播「脱离应用」平台通道契约 —— Android PiP / Windows 独立小窗 / 悬浮窗。
///
/// ## 为什么需要这一层
/// 用户四条需求里有三条要求**离开 App 后仍能看到直播 / 仍能点回会话**：
///   ① 手机端直播小窗要脱离应用（App 在后台也能悬浮看直播）；
///   ② 电脑端直播小窗也要脱离应用（真正的独立窗口）；
///   ③ 悬浮球（右上角那个）要脱离应用。
///
/// 三者都**没有纯 Dart 实现**：必须落到平台侧（Android PictureInPicture /
/// WindowManager 叠加层；Windows 顶层窗口）。本文件是**唯一的 Dart↔原生契约**，
/// 上层（会话运行时、小窗组件、悬浮球组件）只依赖这里的抽象，不直接碰 MethodChannel。
///
/// ## 分平台能力（研究结论，勿凭印象改）
/// | 能力 | Android | Windows | iOS |
/// |---|---|---|---|
/// | [aylaEnterDetachedLive] 视频脱离 | ✅ API 26+ 原生 PiP | ✅ 独立 always-on-top 窗口 | ❌ 见下 |
/// | [aylaShowDetachedBall] 悬浮球 | ✅ 需 SYSTEM_ALERT_WINDOW | ✅ 独立置顶小窗 | ❌ 无此 API |
/// | [aylaSupportsLivePip] 查询 | 运行时探测 | 恒 true | 恒 false |
///
/// **iOS 明确不支持**（研究结论，已核官方文档）：
/// - iOS 只能把 AVPlayerLayer / AVSampleBufferDisplayLayer 的画面升进 PiP ——
///   本工程的视频走 Flutter texture（video_player 默认 textureView），
///   **Flutter 画的帧进不了 iOS PiP**；且 App 进后台后 Flutter 停止出帧，
///   任何「截 Flutter 画面喂给系统」的方案（pip_kit / fl_pip）在后台都会黑屏。
/// - iOS **没有任何 API** 能让自绘窗口压在其他 App 之上（Live Activity 只出现在锁屏/灵动岛）。
/// ⇒ 这两条在 iOS 上如实降级为「回到 App 内小窗」，不伪装成已实现。
///
/// ## 关键约束（原生侧必须遵守；Dart 侧据此设计）
/// 1. **Android 进入 PiP 必须在 Activity RESUMED 时发起**。从
///    didChangeAppLifecycleState 里调 enterPictureInPictureMode() 必抛
///    IllegalStateException: Activity must be resumed to enter picture-in-picture
///    ⇒ 所以 [aylaEnterDetachedLive] **只能由 UI 手势触发**（点小窗/点「最小化」键），
///    而「按 Home 键自动进 PiP」走原生 setAutoEnterEnabled（12+）/
///    onUserLeaveHint（26–30），由原生侧自行判断，Dart **不参与**。
/// 2. **PiP 期间 Flutter 只收到 inactive，不会收到 paused**（引擎源码语义：
///    onPause → appIsInactive、onStop → appIsPaused；PiP 不触发 onStop）⇒
///    弹幕 WS / 在看登记**本来就不会断**。但某些 OEM 的 stashed PiP 可能真的走到
///    paused，故 [aylaIsInLivePip] 必须可查，生命周期处理要据此守卫（见 main.dart）。
/// 3. **Windows 第二窗口需要第二个 Flutter engine**（FlutterDesktopEngineCreate +
///    FlutterDesktopViewControllerCreate）。media_kit_video 2.0.1 有进程级单例
///    static MediaKitVideoPlugin* instance_，第二个 engine 会覆盖它、导致**主窗口**
///    的 VideoController 永久挂起（上游 media-kit#1383，OPEN）⇒ 必须先打
///    third_party/media_kit_video 的 `unordered_map<HWND, …>` 补丁。
///
/// ## 通道名（原生侧必须逐字一致）
/// - ayla/live_pip       —— Android PiP
/// - ayla/desktop_window —— Windows 独立小窗 + 悬浮球
///
/// ## 无原生实现时的行为（桌面调试 / 测试 / iOS）
/// 所有 API 都**不抛异常**、返回明确的降级结果，上层据此回落到 App 内小窗 ——
/// 「功能没做」不允许伪装成「已经做了但没反应」。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android PiP 通道名（与 MainActivity.kt 逐字一致）。
const String kAylaPipChannel = 'ayla/live_pip';

/// Windows 独立窗口通道名（与 windows/runner/live_window.cpp 逐字一致）。
const String kAylaDesktopWindowChannel = 'ayla/desktop_window';

/// 当前平台是否**可能**支持「直播脱离应用」。
///
/// 这是**静态**能力判断（按平台），真实可用性还要问 [aylaSupportsLivePip]
/// （Android 要探测 FEATURE_PICTURE_IN_PICTURE，低内存设备会被关闭）。
bool get aylaDetachedLivePlatformSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.windows);

/// 当前平台是否支持「悬浮球脱离应用」。
///
/// iOS 无此能力（无跨越其他 App 的窗口 API）；Android 需要用户授予
/// 「显示在其他应用上层」特殊权限；Windows 用独立置顶窗口。
bool get aylaDetachedBallPlatformSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.windows);

/// 原生 PiP 是否可用（Android 探测系统特性；Windows 恒 true；其它 false）。
///
/// **不抛异常**：通道缺失（未实现原生 / 单元测试环境）⇒ 平台静态判断兜底。
Future<bool> aylaSupportsLivePip() async {
  if (!aylaDetachedLivePlatformSupported) return false;
  if (defaultTargetPlatform == TargetPlatform.windows) return true;
  try {
    final bool? ok = await _pipChannel.invokeMethod<bool>('isSupported');
    return ok ?? false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// 当前是否**正处在**系统 PiP 里。
///
/// 用途：App 生命周期回调里区分「真的离开了」与「还在 PiP 里看」——
/// PiP 也算作观看（用户要求「小窗观看直播时也算作观看人」）。
Future<bool> aylaIsInLivePip() async {
  if (!aylaDetachedLivePlatformSupported) return false;
  try {
    final bool? inPip = await _pipChannel.invokeMethod<bool>('isInPip');
    return inPip ?? false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// 请求进入「脱离应用」的直播呈现。
///
/// - Android：进入系统 PiP（[videoRect] 作为 sourceRectHint，让转场动画从
///   视频所在位置长出来 —— 官方文档明确：不传会让系统自己猜、转场很丑）。
/// - Windows：打开独立 always-on-top 小窗播放 [playUrl]。
///
/// **返回值语义**：true = 原生侧已接管（此时上层应隐藏 App 内小窗，
/// 但**不要**销毁会话 —— 观看登记要继续）。false = 本平台不支持 / 原生失败
/// ⇒ 上层**回落到 App 内小窗**，不得静默什么都不做。
///
/// [playUrl] 是已经过 aylaNormalizeLivePlayUrl 归一、**带鉴权 query** 的 HLS 地址
/// （Windows 第二窗口没有登录态，必须靠 URL 自证）。
Future<bool> aylaEnterDetachedLive({
  required String channelId,
  required String title,
  String? playUrl,
  Rect? videoRect,
  int aspectX = 16,
  int aspectY = 9,
}) async {
  if (defaultTargetPlatform == TargetPlatform.windows) {
    try {
      final bool? ok = await _desktopChannel.invokeMethod<bool>(
        'openLiveWindow',
        <String, Object?>{
          'channelId': channelId,
          'title': title,
          'playUrl': playUrl,
        },
      );
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
  if (defaultTargetPlatform == TargetPlatform.android) {
    try {
      final bool? ok = await _pipChannel.invokeMethod<bool>(
        'enterPip',
        <String, Object?>{
          'aspectX': aspectX,
          'aspectY': aspectY,
          if (videoRect != null) ...<String, Object?>{
            'x': videoRect.left.round(),
            'y': videoRect.top.round(),
            'w': videoRect.width.round(),
            'h': videoRect.height.round(),
          },
        },
      );
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
  return false;
}

/// 直播会话活跃态（原生侧据此**预先武装**「按 Home 自动进 PiP」）。
///
/// ## 为什么必须由 Dart 告诉原生
/// Android 的自动进 PiP 有两条原生路径，都需要「当前是否正在直播」这个判据：
/// - API 31+：`PictureInPictureParams.setAutoEnterEnabled(true)` 必须**预先**设置，
///   且只能在 Activity RESUMED 时设置 ⇒ 原生无法自己知道什么时候该武装；
/// - API 26–30：`onUserLeaveHint()` 里调 `enterPictureInPictureMode()`，同样需要判据。
///
/// 若不做这一步，只能二选一：全局武装（在任何页面按 Home 都弹 PiP，错误行为），
/// 或完全放弃「按 Home 自动进 PiP」（只剩用户主动点脱离键，少一层系统级体验）。
///
/// ## 调用契约（Dart 侧必须成对）
/// - 进入直播观看 / 进入小窗态 ⇒ `true`；
/// - `stop()` / 直播结束 / PiP 被系统关闭 ⇒ `false`。
/// **漏传 false 会让用户在其他页面按 Home 时误进 PiP** —— 这是本方法唯一的失败模式。
///
/// 幂等；非 Android 平台 no-op；原生未实现时静默（不抛）。
Future<void> aylaSetLivePipSessionActive(bool active) async {
  if (defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await _pipChannel.invokeMethod<void>('setSessionActive', <String, Object?>{
      'active': active,
    });
  } on MissingPluginException {
    // 原生未实现：静默（这是状态同步，不是用户动作）
  } on PlatformException {
    // 同上
  }
}

/// 关闭「脱离应用」的直播呈现。
///
/// Android：PiP 由系统关闭（用户点 X / 上滑消失），Dart 主动关只能退到后台，
/// 故这里是 **no-op 但仍有意义** —— 它保证「关闭」路径在两个平台上都有单一入口。
/// Windows：关闭那个独立窗口（并让主窗口重新接管播放）。
///
/// 幂等：没有脱离态时调用不产生副作用。
Future<void> aylaCloseDetachedLive() async {
  if (defaultTargetPlatform != TargetPlatform.windows) return;
  try {
    await _desktopChannel.invokeMethod<void>('closeLiveWindow');
  } on MissingPluginException {
    // 原生未实现：静默（这是「关闭」，静默安全）
  } on PlatformException {
    // 同上
  }
}

/// 悬浮球「脱离应用」的结果。
enum AylaDetachedBallResult {
  /// 已显示在其他应用上层（或桌面顶层）。
  shown,

  /// 平台不支持（iOS / Web）。
  unsupported,

  /// 用户尚未授予「显示在其他应用上层」权限（Android）。
  ///
  /// 调用方应给出**明确的用户引导**（跳系统设置页），而不是静默失败 ——
  /// 「功能没反应」是本项目反复实报的问题类型。
  permissionRequired,

  /// 原生侧失败。
  failed,
}

/// 让悬浮球脱离应用（压在其他 App 之上 / 桌面顶层）。
///
/// Android：需要 SYSTEM_ALERT_WINDOW（特殊权限，无运行时弹窗）。
/// 未授权时返回 [AylaDetachedBallResult.permissionRequired]。
/// Windows：独立置顶小窗。
///
/// 幂等：重复调用是同一件事（原生侧复用已有窗口）。
/// [payload] 是主引擎已经算好的**整组投影**（`AylaOverlayPayload.encode()`）。
///
/// 为什么不让原生侧自己拼：窗口外浮层要显示的是「当前有哪些会话」，那份判定
/// （auth 的四个媒体字段 + 活动态索引 + 隐藏档）全在主引擎里；第二引擎没有
/// 登录态与 store，原生更不可能知道。所以 Dart 侧序列化、原生只透传。
Future<AylaDetachedBallResult> aylaShowDetachedBall({
  required String kind,
  required String sessionId,
  required String title,
  required String sourceRoute,
  String? payload,
}) async {
  if (!aylaDetachedBallPlatformSupported) {
    return AylaDetachedBallResult.unsupported;
  }
  final Map<String, Object?> args = <String, Object?>{
    'kind': kind,
    'sessionId': sessionId,
    'title': title,
    'sourceRoute': sourceRoute,
    if (payload != null) 'payload': payload,
  };
  try {
    final String? result = defaultTargetPlatform == TargetPlatform.windows
        ? await _desktopChannel.invokeMethod<String>('showBall', args)
        : await _pipChannel.invokeMethod<String>('showBall', args);
    return switch (result) {
      'shown' => AylaDetachedBallResult.shown,
      'permissionRequired' => AylaDetachedBallResult.permissionRequired,
      _ => AylaDetachedBallResult.failed,
    };
  } on MissingPluginException {
    return AylaDetachedBallResult.unsupported;
  } on PlatformException {
    return AylaDetachedBallResult.failed;
  }
}

/// 隐藏已脱离应用的悬浮球（幂等；无脱离态时静默）。
Future<void> aylaHideDetachedBall() async {
  if (!aylaDetachedBallPlatformSupported) return;
  try {
    if (defaultTargetPlatform == TargetPlatform.windows) {
      await _desktopChannel.invokeMethod<void>('hideBall');
    } else {
      await _pipChannel.invokeMethod<void>('hideBall');
    }
  } on MissingPluginException {
    // 原生未实现：静默（这是「隐藏」，静默安全）
  } on PlatformException {
    // 同上
  }
}

/// 把**新的会话集合**推给已经打开的悬浮球窗口（不新建窗口）。
///
/// 返回 true = 已送达；false = 当前没有脱离态窗口（调用方应改走
/// [aylaShowDetachedBall] 重新创建）。原生未实现时也返回 false（不抛）。
///
/// 幂等：同一份 payload 重复推送只是同一件事（组件侧 setState 一次）。
Future<bool> aylaUpdateDetachedBall({required String payload}) async {
  if (!aylaDetachedBallPlatformSupported) return false;
  try {
    final String? result = defaultTargetPlatform == TargetPlatform.windows
        ? await _desktopChannel.invokeMethod<String>('updateBall', <String, Object?>{
            'payload': payload,
          })
        : null;
    return result == 'shown';
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// 告诉原生侧「主窗口是否处在窗口级全屏」（桌面平台；其它平台 no-op）。
///
/// ## 为什么需要显式告知（2026-10-31 用户实报「最大化时点全屏完全没全屏成功」）
/// 原生侧原本只能**逆向推断**：`窗口矩形 ≈ 显示器 rcMonitor` 且 `WS_THICKFRAME 被剥掉`
/// ⇒ 判为全屏。但 window_manager 0.5.2 的 `SetFullScreen` 只在
/// `!g_maximized_before_fullscreen` 时才调 `SetAsFrameless()`；从最大化进全屏会跳过它
/// ⇒ 那条判据在**真正全屏的窗口**上为假 ⇒ Win11 圆角没关、`is_fullscreen_` 没置位
/// ⇒ `WM_DPICHANGED` 继续把窗口挪回窗口化矩形（看起来像「全屏没生效」）。
///
/// Dart 侧**知道**自己刚调过 `setFullScreen(true/false)`，直接告诉原生比反推可靠。
/// 原生侧把它当**提示**用：只有几何也同意时才采纳，采纳后立刻清除（不会卡住）。
///
/// 幂等；非桌面平台 no-op；原生未实现时静默（这是状态同步，不是用户动作）。
Future<void> aylaSetWindowFullscreen(bool fullscreen) async {
  if (!aylaDetachedLivePlatformSupported) return;
  if (defaultTargetPlatform != TargetPlatform.windows) return;
  try {
    await _desktopChannel.invokeMethod<void>('setWindowFullscreen', <String, Object?>{
      'fullscreen': fullscreen,
    });
  } on MissingPluginException {
    // 原生未实现：静默（原生侧还有几何推断兜底）。
  } on PlatformException {
    // 同上。
  }
}

/// Android：跳「显示在其他应用上层」授权页（无运行时弹窗，只能跳设置）。
///
/// 返回 true = 已经跳了设置页；false = 本平台无此设置。
/// **不要**在跳转后立刻假设已授权 —— 用户可能在设置页直接返回。
Future<bool> aylaOpenOverlayPermissionSettings() async {
  if (defaultTargetPlatform != TargetPlatform.android) return false;
  try {
    final bool? ok = await _pipChannel.invokeMethod<bool>('openOverlaySettings');
    return ok ?? false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// 原生事件的值对象（不做继承层级，避免上层写 is 分支时漏档）。
class AylaDetachedLiveEvent {
  const AylaDetachedLiveEvent._(
    this.kind, {
    this.inPip = false,
    this.sessionKind = '',
    this.sourceRoute = '',
  });

  /// PiP 进出（Android）。
  const AylaDetachedLiveEvent.pipChanged(bool inPip)
      : this._(AylaDetachedLiveEventKind.pipChanged, inPip: inPip);

  /// 用户点了脱离态的悬浮球（应当回房）。
  const AylaDetachedLiveEvent.ballTap({
    required String kind,
    required String sourceRoute,
  }) : this._(
         AylaDetachedLiveEventKind.ballTap,
         sessionKind: kind,
         sourceRoute: sourceRoute,
       );

  /// 独立直播窗口被用户关闭（Windows）。
  const AylaDetachedLiveEvent.liveWindowClosed()
    : this._(AylaDetachedLiveEventKind.liveWindowClosed);

  /// 脱离态悬浮球被关闭。
  const AylaDetachedLiveEvent.ballClosed()
    : this._(AylaDetachedLiveEventKind.ballClosed);

  final AylaDetachedLiveEventKind kind;

  /// [AylaDetachedLiveEventKind.pipChanged] 专用。
  final bool inPip;

  /// [AylaDetachedLiveEventKind.ballTap] 专用：'voice' / 'live'。
  final String sessionKind;

  /// [AylaDetachedLiveEventKind.ballTap] 专用：回房路由。
  final String sourceRoute;
}

/// [AylaDetachedLiveEvent] 的档位。
enum AylaDetachedLiveEventKind {
  pipChanged,
  ballTap,
  liveWindowClosed,
  ballClosed,
}

/// 原生 → Dart 的事件总线（PiP 进出、悬浮球被点击、独立窗口关闭）。
///
/// 上层用它把「用户在小窗里点了回房」「PiP 被系统收起」这类事实接回会话运行时。
class AylaDetachedLiveEvents {
  AylaDetachedLiveEvents._();

  static final AylaDetachedLiveEvents instance = AylaDetachedLiveEvents._();

  final StreamController<AylaDetachedLiveEvent> _controller =
      StreamController<AylaDetachedLiveEvent>.broadcast();

  /// 事件流（广播；重复订阅各自收全量）。
  Stream<AylaDetachedLiveEvent> get stream => _controller.stream;

  bool _bound = false;

  /// 绑定原生回调（幂等；App 启动时调用一次即可，重复调用不会重复绑定）。
  void bind() {
    if (_bound) return;
    _bound = true;
    // ⚠️⚠️ **绝不能让绑定失败拖死启动**（2026-10-31 实报「手机端一点 App 直接白屏」）。
    //
    // `MethodChannel.setMethodCallHandler` 内部取 `ServicesBinding.instance`；binding 未
    // 初始化时抛断言 ⇒ 若这里不拦，异常会一路冒到 `main()` ⇒ `runApp` 永不执行 ⇒ 白屏。
    // 调用方（main.dart）已改为无条件 `ensureInitialized()`，但**防御仍留在这里**：
    // 「脱离应用」是可选增强能力，它绑不上只该退化成「没有原生事件」，
    // 不该让用户连 App 都进不去。
    try {
      _pipChannel.setMethodCallHandler(_handle);
      _desktopChannel.setMethodCallHandler(_handle);
    } catch (error) {
      _bound = false;
      debugPrint('[AYLA-DETACHED] 原生事件绑定失败（降级为无原生事件）：$error');
    }
  }

  Future<Object?> _handle(MethodCall call) async {
    switch (call.method) {
      case 'onPipChanged':
        final bool inPip = call.arguments is bool
            ? call.arguments as bool
            : false;
        _emit(AylaDetachedLiveEvent.pipChanged(inPip));
      case 'onBallTap':
        final Map<Object?, Object?> raw = call.arguments is Map
            ? call.arguments as Map<Object?, Object?>
            : const <Object?, Object?>{};
        _emit(
          AylaDetachedLiveEvent.ballTap(
            kind: '${raw['kind'] ?? ''}',
            sourceRoute: '${raw['sourceRoute'] ?? ''}',
          ),
        );
      case 'onLiveWindowClosed':
        _emit(const AylaDetachedLiveEvent.liveWindowClosed());
      case 'onBallClosed':
        _emit(const AylaDetachedLiveEvent.ballClosed());
    }
    return null;
  }

  void _emit(AylaDetachedLiveEvent event) {
    if (_controller.isClosed) return;
    _controller.add(event);
  }

  /// 测试用：直接注入一条事件。
  @visibleForTesting
  void debugEmit(AylaDetachedLiveEvent event) => _emit(event);

  /// 测试用：解除绑定（下一次 [bind] 会重新挂）。
  @visibleForTesting
  void debugReset() {
    _bound = false;
  }
}

final MethodChannel _pipChannel = const MethodChannel(kAylaPipChannel);
final MethodChannel _desktopChannel = const MethodChannel(
  kAylaDesktopWindowChannel,
);
