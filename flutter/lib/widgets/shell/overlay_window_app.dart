import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../shell/session_activity.dart'
    show AylaActivitySession, AylaSessionActivityIndicator;

/// 窗口外浮层的两种形态（与现有两个浮层一一对应）。
enum AylaOverlayKind {
  /// 会话悬浮球组（现有 [AylaSessionActivityIndicator]，右上角那个）。
  activityBall,

  /// 直播小窗（现有 `AylaLiveMiniPlayer`）。
  liveMini,
}

/// 主引擎 → 浮层窗口的数据投影（**纯值**，可 json 编码过通道）。
///
/// ## 为什么是"投影"而不是共享状态
/// 第二引擎是**另一个 isolate、另一份全局状态**：它没有 ProviderScope、没有登录态、
/// 没有 Dio、没有 WS（见文件头）。所以主引擎把自己已经算好的、UI 真正要显示的那几个
/// 字段序列化过去 —— 这正是 web 侧 store 到组件之间的同一条数据流，只是跨了进程内边界。
class AylaOverlayPayload {
  const AylaOverlayPayload({
    required this.kind,
    this.voiceKind = '',
    this.voiceSessionId = '',
    this.voiceTitle = '',
    this.voiceRoute = '',
    this.liveKind = '',
    this.liveSessionId = '',
    this.liveTitle = '',
    this.liveRoute = '',
    this.collapsed = false,
    this.groupTop = -1,
  });

  final AylaOverlayKind kind;

  /// 语音会话（空串 = 无）。
  final String voiceKind;
  final String voiceSessionId;
  final String voiceTitle;
  final String voiceRoute;

  /// 直播会话（空串 = 无）。
  final String liveKind;
  final String liveSessionId;
  final String liveTitle;
  final String liveRoute;

  /// 悬浮球组是否收起（现有组件的把手状态由主引擎持有，避免第二引擎重复实现）。
  final bool collapsed;

  /// 悬浮球组的 top 偏移（-1 = 用组件默认值）。拖动后的位置由主引擎持有。
  final double groupTop;

  /// 语音/直播两个会话都为空 ⇒ 悬浮球组按 tsx 135 零渲染。
  bool get hasAnySession =>
      voiceSessionId.isNotEmpty || liveSessionId.isNotEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.name,
    'voiceKind': voiceKind,
    'voiceSessionId': voiceSessionId,
    'voiceTitle': voiceTitle,
    'voiceRoute': voiceRoute,
    'liveKind': liveKind,
    'liveSessionId': liveSessionId,
    'liveTitle': liveTitle,
    'liveRoute': liveRoute,
    'collapsed': collapsed,
    'groupTop': groupTop,
  };

  /// 编码成一条 JSON 字符串（原生侧只做透传，不解析）。
  String encode() => jsonEncode(toJson());

  static AylaOverlayPayload fromJson(Map<String, dynamic> raw) {
    final String kindName = '${raw['kind'] ?? 'activityBall'}';
    return AylaOverlayPayload(
      kind: AylaOverlayKind.values.firstWhere(
        (AylaOverlayKind k) => k.name == kindName,
        orElse: () => AylaOverlayKind.activityBall,
      ),
      voiceKind: '${raw['voiceKind'] ?? ''}',
      voiceSessionId: '${raw['voiceSessionId'] ?? ''}',
      voiceTitle: '${raw['voiceTitle'] ?? ''}',
      voiceRoute: '${raw['voiceRoute'] ?? ''}',
      liveKind: '${raw['liveKind'] ?? ''}',
      liveSessionId: '${raw['liveSessionId'] ?? ''}',
      liveTitle: '${raw['liveTitle'] ?? ''}',
      liveRoute: '${raw['liveRoute'] ?? ''}',
      collapsed: raw['collapsed'] == true,
      groupTop: (raw['groupTop'] as num?)?.toDouble() ?? -1,
    );
  }

  /// 解析原生传来的 JSON 字符串（失败返回 null —— 浮层是可选增强，不抛）。
  static AylaOverlayPayload? tryDecode(String? encoded) {
    if (encoded == null || encoded.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(encoded);
      if (decoded is! Map<String, dynamic>) return null;
      return AylaOverlayPayload.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  AylaOverlayPayload copyWith({bool? collapsed, double? groupTop}) {
    return AylaOverlayPayload(
      kind: kind,
      voiceKind: voiceKind,
      voiceSessionId: voiceSessionId,
      voiceTitle: voiceTitle,
      voiceRoute: voiceRoute,
      liveKind: liveKind,
      liveSessionId: liveSessionId,
      liveTitle: liveTitle,
      liveRoute: liveRoute,
      collapsed: collapsed ?? this.collapsed,
      groupTop: groupTop ?? this.groupTop,
    );
  }
}

/// 窗口外浮层的根 widget（跑在第二引擎里）。
///
/// **只 build 现有组件**：悬浮球组 = [AylaSessionActivityIndicator]（原样），
/// 直播小窗 = [AylaLiveMiniPlayer]（原样，见 `live_window_surface.dart` 的
/// `AylaDetachedLiveMiniPlayerHost`）。
///
/// ## 宿主窗口尺寸约定（与 `windows/runner/live_window.cpp` 逐条对应）
/// 悬浮球窗口是 **176 × 132 逻辑像素**、贴着工作区右上角，窗口透明、上方空白区域
/// 点击穿透。组件本身用 `Positioned(right: 24, top: 80)` 定位，**不读窗口高度**，
/// 所以这里只需要给它一块足够大的 `Stack`，并保证 `MediaQuery` 的视口宽度是宽屏档
/// （组件据此选 `right: 24` 而不是窄屏 `right: 16`）。
class AylaOverlayWindowApp extends StatelessWidget {
  const AylaOverlayWindowApp({
    super.key,
    required this.payload,
    required this.onOpenSession,
    this.onToggleCollapsed,
    this.onGroupTopChanged,
    this.onHoverChanged,
    this.onHitRectsChanged,
    this.compact = false,
    this.onCollapsedChanged,
    this.suppressTapTick = 0,
  });

  /// 可见按钮的精确矩形（视口坐标）。宿主转给原生做穿透判定。
  final ValueChanged<List<Rect>>? onHitRectsChanged;

  final AylaOverlayPayload payload;

  /// 点球 → 回主引擎导航（第二引擎没有 router）。
  final ValueChanged<AylaActivitySession> onOpenSession;

  /// 点把手 → 切换收起（状态由主引擎持有）。
  final ValueChanged<bool>? onToggleCollapsed;

  /// 拖动把手后的 top（状态由主引擎持有；null = 不接线）。
  final ValueChanged<double>? onGroupTopChanged;

  /// 鼠标是否停在任一按钮（球 / 把手）上。
  ///
  /// 宿主用它切换浮层窗口的 `WS_EX_TRANSPARENT`：停在按钮上 ⇒ 窗口接住点击；
  /// 否则 ⇒ 整窗放行给桌面。判断交给 Flutter（组件本就有 MouseRegion），
  /// 原生侧不需要复制任何布局常量。
  final ValueChanged<bool>? onHoverChanged;

  /// **紧凑宿主**（Android 系统叠加层）：窗口尺寸 = 球组尺寸（132/80/28 × 44dp）。
  ///
  /// 这是 Android 上唯一可行的形态 —— overlay 窗口的尺寸就是触摸热区，没有公开 API
  /// 能做非矩形热区（`TOUCHABLE_INSETS_REGION` 是 @hide）。紧凑模式下组件贴在窗口
  /// 原点 (0,0)，竖直拖动交给原生（移动整个窗口）。
  final bool compact;

  /// 收起态变化（紧凑宿主据此让原生按新宽度重建窗口）。
  final ValueChanged<bool>? onCollapsedChanged;

  /// 原生刚拖动过的计数器（递增 ⇒ 抑制紧随其后的一次合成 tap）。
  final int suppressTapTick;

  /// 宿主窗口的内容宽度（逻辑像素；见 `live_window.cpp` 的 kBallWindowWidth）。
  ///
  /// 窗口只有 176 宽，但**报给组件的视口宽度必须是宽屏档**：
  /// 组件按 `MediaQuery.sizeOf(context).width` 选断点（`>768` = 宽屏），
  /// 176 恒为窄屏 ⇒ `right: 16` + `top: calc(56 + safe + 48)`，与 web / 桌面
  /// 上用户看到的那个样子（`right: 24` / `top: 80`）不一致。
  /// 用户要求「外观和交互完全没有区别」⇒ 必须走宽屏档。
  ///
  /// 为什么改视口宽度不会把球挪错位：组件返回的 `Positioned(right: 24)` 是相对
  /// **真实 Stack**（176 宽）定位的，`MediaQuery` 只影响它读到的断点与 clamp 上限。
  static const double hostContentWidth = 176;

  /// 报给组件的**视口宽度**：只要 `> 768` 就走宽屏档（取值本身不影响布局）。
  static const double hostViewportWidth = 1280;

  /// 报给组件的**视口高度**（拖动 clamp 的上限）。
  ///
  /// Android 的浮层窗口只有内容那么大（176×132dp），若把它当成视口高度，
  /// 组件的 `maxTop` 会被夹到 80dp，球等于拖不动。这里取一个足够大的值让 clamp
  /// 覆盖整屏；真正的屏幕边界由原生在 `setBallGroupTop` 里 clamp。
  ///
  /// Windows 端窗口本来就是满工作区高，这个值对它是等价（只会更宽松，且原生同样 clamp）。
  static const double hostViewportHeight = 3000;

  /// 画布样张的舞台尺寸（只用于 `aylaOverlayWindowSamples`）。
  static const Size sampleStageSize = Size(176, 132);

  @override
  Widget build(BuildContext context) {
    final AylaActivitySession? voice = payload.voiceSessionId.isEmpty
        ? null
        : AylaActivitySession(
            sessionId: payload.voiceSessionId,
            sourceRoute: payload.voiceRoute,
            title: payload.voiceTitle,
          );
    final AylaActivitySession? live = payload.liveSessionId.isEmpty
        ? null
        : AylaActivitySession(
            sessionId: payload.liveSessionId,
            sourceRoute: payload.liveRoute,
            title: payload.liveTitle,
          );

    // 组件按视口做两件事：断点（宽/窄屏）与拖动 clamp 上限。
    //
    // ⚠️ 宽度必须报**宽屏档**（见 hostViewportWidth）：真实窗口只有 176 宽，
    // 报 176 会让组件走窄屏档（right 16 / top 104），与 web 不一致。
    // 高度必须报**真实可用高度**（宿主窗口 = 整个工作区高），因为拖动 clamp 用的是它：
    // 报小了拖动范围就被夹死（这正是第一版 132 高窗口「拖不动」的根因）。
    final Size viewport = MediaQuery.sizeOf(context);
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        // ⚠️ 高度必须报**真实窗口高度**。
        //
        // 曾试过报屏幕高度（3000）让组件 clamp 覆盖全屏，结果 **raster 线程 SIGSEGV**
        // （logcat: `Fatal signal 11 in tid xxx (1.raster)`）：视口远大于真实窗口时，
        // Android 的 FlutterView 会按视口尺寸准备渲染缓冲，与实际 surface 严重不符，
        // 渲染线程直接崩。
        //
        // 正确做法：视口 = 真实窗口；「能拖多远」由原生侧 clamp（applyBallGroupTop），
        // 组件只负责算出它认为的 top 并发给宿主。
        size: Size(hostViewportWidth, viewport.height),
        padding: EdgeInsets.zero,
        viewPadding: EdgeInsets.zero,
        viewInsets: EdgeInsets.zero,
        disableAnimations: false,
      ),
      child: Material(
        // 透明底：浮层窗口本身是无边框/透明窗体，背景必须让出来。
        type: MaterialType.transparency,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // 现有组件原样（它返回 Positioned ⇒ 必须是 Stack 的直接子级）。
            AylaSessionActivityIndicator(
              voice: voice,
              live: live,
              onOpenSession: onOpenSession,
              // ⚠️ MUST be wired: the native side uses this top to decide which
              // strip of the (full-work-area) window is clickable. Without it
              // `ball_group_top_` stays at its initial 80 while the balls move,
              // so after a drag the clickable band no longer covers them and
              // every click on the ball gets passed through to the desktop.
              onTopChanged: onGroupTopChanged,
              onHoverChanged: onHoverChanged,
              onHitRectsChanged: compact ? null : onHitRectsChanged,
              compact: compact,
              onCollapsedChanged: onCollapsedChanged,
              suppressTapTick: suppressTapTick,
            ),
          ],
        ),
      ),
    );
  }
}

/// 供第二引擎的 `main` 使用的主题包装（复用主引擎同一套主题，保证「外观完全一致」）。
Widget aylaOverlayWindowScope({required Widget child}) {
  return Theme(data: buildAylaTheme(), child: child);
}

// ======================= 第二引擎侧（activityBall 窗口） =======================

/// 第二引擎 → 宿主窗口的内层通道（与 `live_window.cpp` 逐字一致）。
const String kAylaOverlayInnerChannel = 'ayla/desktop_window';

/// 窗口外悬浮球组的根 widget（第二引擎的 `runApp` 目标）。
///
/// ## 为什么它是有状态的
/// 宿主会在**每次会话集合变化**时推一条新 payload（`ballPayload`）。组件内部
/// 自己持有「收起态 / 拖动后的 top」，但那是**窗口内**的状态，宿主并不知道；
/// 所以这里把两者的关系固定成：**组件状态优先，payload 只提供会话集合**。
/// 于是「主引擎推一次、组件重排一次」不会把用户刚拖好的位置/收起态冲掉
/// —— 与 App 内使用同一个组件的体验一致。
class AylaOverlayBallWindowApp extends StatefulWidget {
  const AylaOverlayBallWindowApp({super.key, this.initialPayload});

  /// 从 entrypoint 参数里读到的首个 payload（宿主 `ready` 之后还会再推一次；
  /// 重复是幂等的）。
  final AylaOverlayPayload? initialPayload;

  @override
  State<AylaOverlayBallWindowApp> createState() =>
      _AylaOverlayBallWindowAppState();
}

class _AylaOverlayBallWindowAppState extends State<AylaOverlayBallWindowApp> {
  final MethodChannel _channel = const MethodChannel(kAylaOverlayInnerChannel);

  AylaOverlayPayload? _payload;
  bool _disposed = false;

  /// 上一次已知的组 top（用于把拖动换算成**窗口位移增量**）。
  double _lastGroupTop = 0;

  /// Last reported on-screen width of the group (see _reportGroupTop).
  double _lastVisibleWidth = 0;

  /// 悬浮球组是否收起（原生按此把窗口重建到 28dp 宽）。
  bool _collapsed = false;

  /// 「原生刚刚拖动过」的计数器：每次递增 ⇒ 组件抑制紧随其后的一次 tap。
  int _suppressTapTick = 0;

  @override
  void initState() {
    super.initState();
    _payload = widget.initialPayload;
    _channel.setMethodCallHandler(_handleHostCall);
    // 第一帧出图后再告诉宿主：窗口先透明出现，不会白闪。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      unawaited(_ready());
    });
  }

  Future<Object?> _handleHostCall(MethodCall call) async {
    // 原生拖动结束 ⇒ 让组件吞掉紧随其后的一次 tap（拖完不该误触收起/回房）。
    if (call.method == 'suppressTap') {
      if (!_disposed) setState(() => _suppressTapTick++);
      return true;
    }
    if (call.method != 'ballPayload') return null;
    final Object? raw = call.arguments;
    String encoded = '';
    if (raw is Map) {
      final Object? value = raw['payload'];
      if (value is String) encoded = value;
    }
    final AylaOverlayPayload? next = AylaOverlayPayload.tryDecode(encoded);
    if (next == null || _disposed) return null;
    setState(() => _payload = next);
    return null;
  }

  /// 拖动把手 ⇒ 把组的**新 top** 告诉原生（**不移动窗口**）。
  ///
  /// ## 为什么是「报告位置」而不是「移动窗口」（2026-10-31 实测订正）
  /// 第一版设计是「原生按 `新top - 旧top` 平移窗口」。那是**错的**，两个缺陷：
  ///
  /// 1. **双重计数**：组件自己已经把 top 应用到了 `Positioned(top:)`，再平移窗口
  ///    ⇒ 球相对手指走两倍距离。
  /// 2. **clamp 让拖动彻底失效**：组件把 top 夹在 `[8, 视口高-52]`。宿主窗口只有
  ///    132 高 ⇒ 夹在 `[8, 80]`，而 176 宽的视口让组件走**窄屏档**（断点 768），
  ///    默认 top 是 104 —— **比 clamp 上限还大** ⇒ 拖动时 top 恒等于 80、增量恒 0，
  ///    窗口一步都不动。
  ///
  /// ## 现在的做法
  /// 宿主窗口改成**整个工作区高**（见 `live_window.cpp` 的 `kBallWindowMinHeight`）⇒
  /// 组件的 `top` 坐标空间 = 屏幕的垂直空间 ⇒ clamp 覆盖全屏、拖动天然 1:1、
  /// 什么都不用平移。这里只把位置报给原生，**唯一用途是 `WM_NCHITTEST`**：
  /// 让原生知道哪一小块是球（可点），其余透明区域要 `HTTRANSPARENT` 放行给下层应用。
  Future<void> _reportGroupTop(double top, {double? visibleWidth}) async {
    if (_disposed) return;
    final double width = visibleWidth ?? _lastVisibleWidth;
    if (top == _lastGroupTop && width == _lastVisibleWidth) return;
    _lastGroupTop = top;
    _lastVisibleWidth = width;
    try {
      await _channel.invokeMethod<bool>('setBallGroupTop', <String, Object?>{
        'top': top,
        // Width of the part that is actually ON SCREEN right now. Collapsed =>
        // only the 28px handle remains, so the native hit band must shrink to
        // it; otherwise the empty strip to its left keeps swallowing clicks.
        'visibleWidth': width,
      });
    } on MissingPluginException {
      // 宿主未实现（画布 / 单测）：静默，不影响拖动本身。
    } on PlatformException {
      // 同上。
    }
  }

  /// 上报可见按钮的精确矩形（视口逻辑坐标）。
  ///
  /// 原生用定时器轮询光标，只在这些矩形内才「接收点击」，其余位置整窗放行。
  /// 矩形来自 Flutter 的 `RenderBox`（真实几何），所以收起态只剩把手、
  /// 单球/双球、球之间的缝隙，全都自动正确。
  Future<void> _reportHitRects(List<Rect> rects) async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<bool>('setHitRects', <String, Object?>{
        'rects': rects
            .map((Rect r) => <String, Object?>{
                  'left': r.left,
                  'top': r.top,
                  'right': r.right,
                  'bottom': r.bottom,
                })
            .toList(),
      });
    } on MissingPluginException {
      // 宿主未实现（画布 / 单测）：静默。
    } on PlatformException {
      // 同上。
    }
  }

  /// 鼠标进出按钮 ⇒ 告诉原生切换整窗点击穿透。
  ///
  /// 这是**唯一**可靠的判断来源：`WS_EX_TRANSPARENT` 打开后窗口收不到鼠标消息，
  /// 原生侧无法自己检测「鼠标又回来了」。
  Future<void> _reportHover(bool hovering) async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<bool>('setInteractive', <String, Object?>{
        'interactive': hovering,
      });
    } on MissingPluginException {
      // 宿主未实现（画布 / 单测）：静默。
    } on PlatformException {
      // 同上。
    }
  }

  /// 收起态变化 ⇒ 原生按新宽度（28dp / 132dp / 80dp）重建窗口。
  ///
  /// 必须是**重建**而不是 updateViewLayout 改宽高：改尺寸会让合成器重分配
  /// surface buffer，旧内容在新 buffer 里按原原点渲染一帧 ⇒ 斜向位置伪影（DE23）。
  Future<void> _reportCollapsed(bool collapsed) async {
    if (_disposed || _collapsed == collapsed) return;
    _collapsed = collapsed;
    try {
      await _channel.invokeMethod<bool>('setCollapsed', <String, Object?>{
        'collapsed': collapsed,
      });
    } on MissingPluginException {
      // 宿主未实现（画布 / 单测）：静默。
    } on PlatformException {
      // 同上。
    }
  }

  Future<void> _ready() async {
    try {
      await _channel.invokeMethod<bool>('ready');
    } on MissingPluginException {
      // 宿主未实现（被单独拿来跑 / 画布）：静默，不影响渲染。
    } on PlatformException {
      // 同上。
    }
  }

  /// 点球 ⇒ 交回主引擎导航（本窗口**不关闭**：用户可能还要看直播/语音）。
  ///
  /// [kind] 由调用方按「哪个球被点了」给出（语音球 / 直播球）——
  /// `AylaActivitySession` 本身不带种类（那是 web 组件的真实口径），
  /// 而主引擎侧要用它区分「回语音房」还是「回直播间」。
  Future<void> _openSession(AylaActivitySession session, String kind) async {
    try {
      await _channel.invokeMethod<bool>('ballTap', <String, Object?>{
        'kind': kind,
        'sourceRoute': session.sourceRoute,
      });
    } on MissingPluginException {
      // 静默。
    } on PlatformException {
      // 静默。
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AylaOverlayPayload payload =
        _payload ?? const AylaOverlayPayload(kind: AylaOverlayKind.activityBall);
    // 无会话 ⇒ 组件按 tsx 135 零渲染；此时窗口里什么都不画（主引擎会顺手关窗）。
    return AylaOverlayWindowApp(
      payload: payload,
      // 拖动把手 ⇒ 让**宿主窗口**跟着球一起移动（Windows 全工作区窗口用）。
      //
      // Android 上的拖动完全由原生 `installDragHandle` 负责（组件在紧凑模式下
      // 不再改 `Positioned.top`，也不回传 top）—— 两处同时移动正是
      // 「上下拖动来回跳变闪烁」的根因（交接文档 §2.1）。
      onGroupTopChanged: (double top) => unawaited(_reportGroupTop(top)),
      onHoverChanged: (bool hovering) => unawaited(_reportHover(hovering)),
      onHitRectsChanged: (List<Rect> rects) => unawaited(_reportHitRects(rects)),
      // Android 系统叠加层的窗口尺寸 = 球组尺寸 ⇒ 走紧凑模式（见 OverlayFlutterHost.kt）。
      compact: true,
      onCollapsedChanged: _reportCollapsed,
      suppressTapTick: _suppressTapTick,
      onOpenSession: (AylaActivitySession session) {
        // 组件只回传会话（web 的真实口径），种类要在这里按 id 反查：
        // 直播球的 id 与语音球的 id 不会相同（一个房间只有一个身份）。
        // 取值与 `AylaActivityKind` 的枚举名逐字一致（'voice' / 'live'）。
        final String kind = session.sessionId == payload.liveSessionId
            ? 'live'
            : 'voice';
        unawaited(_openSession(session, kind));
      },
    );
  }
}

// ======================= 画布样张 =======================

/// 窗口外悬浮球组样张（画布验收面）。
///
/// 舞台尺寸 = 宿主窗口的逻辑尺寸（176×132），背景刻意做成「桌面截图色」，
/// 用来对账「透明窗口里只有球/把手可见」这件事。
Widget aylaOverlayWindowSamples() {
  Widget stage(String label, AylaOverlayPayload payload) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          width: AylaOverlayWindowApp.sampleStageSize.width,
          height: AylaOverlayWindowApp.sampleStageSize.height,
          child: DecoratedBox(
            // 模拟"窗口后面的桌面"：透明窗口里这部分应当完全看不见。
            decoration: BoxDecoration(
              color: AylaColors.surface,
              borderRadius: BorderRadius.circular(AylaRadii.rCard),
            ),
            child: AylaOverlayWindowApp(
              payload: payload,
              onOpenSession: (AylaActivitySession _) {},
            ),
          ),
        ),
        const SizedBox(height: AylaSpacing.sp1),
        SizedBox(
          width: AylaOverlayWindowApp.sampleStageSize.width,
          child: Text(label, style: const TextStyle(fontSize: 11)),
        ),
      ],
    );
  }

  return Wrap(
    spacing: AylaSpacing.sp6,
    runSpacing: AylaSpacing.sp6,
    crossAxisAlignment: WrapCrossAlignment.start,
    children: <Widget>[
      stage(
        '窗口外悬浮球 · 语音+直播并存（现有 AylaSessionActivityIndicator 原样 · '
        'right 24 / top 80 · 宿主窗口 176×132 透明 + 上方空白点击穿透）',
        const AylaOverlayPayload(
          kind: AylaOverlayKind.activityBall,
          voiceSessionId: '5',
          voiceTitle: '语音房',
          voiceRoute: '/voice/5',
          liveSessionId: '9',
          liveTitle: '直播间',
          liveRoute: '/live/start/9',
        ),
      ),
      stage(
        '同一窗口 · 只有语音会话（直播球不渲染）',
        const AylaOverlayPayload(
          kind: AylaOverlayKind.activityBall,
          voiceSessionId: '5',
          voiceTitle: '语音房',
          voiceRoute: '/voice/5',
        ),
      ),
      stage(
        '同一窗口 · 无会话 ⇒ 组件零渲染（此时主引擎应当直接关掉窗口）',
        const AylaOverlayPayload(kind: AylaOverlayKind.activityBall),
      ),
    ],
  );
}
