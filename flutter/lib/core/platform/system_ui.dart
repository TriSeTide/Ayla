/// 系统 UI 形态控制（状态栏 / 导航栏的隐藏与恢复）。
///
/// ## 为什么不能只用 `SystemChrome.setEnabledSystemUIMode`（2026-11-01 实测根因）
///
/// 用户实报「手机端全屏看直播的时候顶部状态栏要隐藏」——但 Flutter 侧**从来没人调过**
/// `SystemChrome`，所以状态栏一直露着。补上之后仍然不生效，根因在**目标 SDK**：
///
/// | 事实 | 依据 |
/// |---|---|
/// | 本工程 `targetSdk = 36`（Android 16） | `android/app/build.gradle.kts` 用 `flutter.targetSdkVersion`，Flutter 3.47 的默认值就是 **36**（`flutter_tools/gradle/.../FlutterExtension.kt:34`） |
/// | `SystemUiMode.leanBack / immersive / immersiveSticky / manual` 在 target 36 上**被系统忽略** | Flutter 官方文档原文：「If your app targets Android SDK 16 (API 36) or later, then the Android system will ignore this value.」（`system_chrome.dart` 的 enum 注释逐字如此） |
/// | 忽略发生在**引擎侧**：`PlatformPlugin.setSystemChromeEnabledSystemUIMode` 对这三个模式只是算一个 legacy flags 整数，最后走 `View.setSystemUiVisibility(...)` | 反编译 `flutter.jar` 的 `io/flutter/plugin/platform/PlatformPlugin.class` 可复核：三种模式分别给 1798 / 3846 / 5894，随后 `updateSystemUiOverlays()` → `setSystemUiVisibility` |
/// | 而 `View.setSystemUiVisibility` 与 `SYSTEM_UI_FLAG_*` 在 Android 16 上已失效 | Android 16 行为变更：edge-to-edge 强制、legacy flags 不再生效 |
///
/// ⇒ **唯一可靠的路径是原生 `WindowInsetsController`**（API 30+）/
/// legacy flags（API 24–29），由 [kAylaSystemUiChannel] 承接。
/// `SystemChrome` 那条**仍然保留**：iOS 上它才是正解（隐藏状态栏 + home indicator），
/// 老 Android 上它也能独立生效；两条路都走一次，谁生效算谁，互不冲突。
///
/// ## 契约
/// ```text
/// channel = ayla/system_ui        （与 android/.../MainActivity.kt 逐字一致）
/// method  = setImmersive { enabled: Boolean } -> Boolean
/// ```
/// 只做「呈现形态」的工程约束，不参与任何内容或认知判断。
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart'
    show DeviceOrientation, MethodChannel, MissingPluginException, SystemChrome, SystemUiMode;

/// 系统 UI 形态通道名（Android 原生侧 `MainActivity.kt` 必须逐字一致）。
const String kAylaSystemUiChannel = 'ayla/system_ui';

final MethodChannel _channel = const MethodChannel(kAylaSystemUiChannel);

/// 当前平台是否「有系统状态栏需要让/藏」的移动端。
///
/// 只对 Android / iOS 为真：桌面的 window_manager 真·全屏由
/// `AylaLivePlayer._applyDesktopFullscreen` 负责，Web 没有窗口概念。
bool aylaIsMobilePlatform({TargetPlatform? platform, bool isWeb = kIsWeb}) {
  if (isWeb) return false;
  switch (platform ?? defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
      return true;
    case TargetPlatform.windows:
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      return false;
  }
}

/// 进入 / 退出「沉浸式」（隐藏或恢复状态栏 + 导航栏）。
///
/// - **Android**：优先走原生通道（target 36 下唯一生效的路径，见文件头）；
/// - **iOS**：`SystemUiMode.immersiveSticky` 会隐藏状态栏与 home indicator；
/// - **桌面 / Web**：整体 no-op（返回立即完成，不碰任何通道）。
///
/// 通道缺失（组件画布 / widget test / 未实现该通道的宿主）时**静默降级**：
/// 沉浸式是呈现增强，失败不得打断播放器状态机。
Future<void> aylaSetImmersive(bool enabled) async {
  if (!aylaIsMobilePlatform()) return;
  // ⚠️ **Android 只走原生通道，不调 `SystemChrome`**（不是遗漏）。
  //
  // 引擎的 `PlatformPlugin.setSystemChromeEnabledSystemUIMode` 在非 EDGE_TO_EDGE
  // 模式下会先 `disableEdgeToEdge()` ⇒ `WindowCompat.setDecorFitsSystemWindows(window, true)`。
  // 那会把「Flutter 边到边绘制」关掉：Android 15 以下系统栏一出现，整棵 UI 就被挤到
  // 系统栏之内（本工程全站的 `AylaTopInsetGap` 是按 edge-to-edge 设计的）⇒ 进出全屏
  // 会看到布局跳动。而 target 36 上它本来也不生效 ⇒ 这条调用在 Android 上只有害处。
  if (defaultTargetPlatform != TargetPlatform.android) {
    try {
      await SystemChrome.setEnabledSystemUIMode(
        enabled ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
    } on Object {
      // iOS 极少数宿主没有该实现：静默；沉浸式是呈现增强，不打断播放器。
    }
    return;
  }
  try {
    await _channel.invokeMethod<bool>(
      'setImmersive',
      <String, Object?>{'enabled': enabled},
    );
  } on MissingPluginException {
    // 画布 / 单测 / 未接线宿主：静默。
  } on Object {
    // 原生侧异常：同样不打断播放器。
  }
}

/// 恢复默认朝向（**不**含沉浸式；沉浸式由 [aylaSetImmersive] 单独控制）。
Future<void> aylaUnlockOrientation() async {
  try {
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  } on Object {
    // 忽略：桌面/Web 上该调用本就是 no-op。
  }
}
