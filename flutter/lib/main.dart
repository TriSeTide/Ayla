/// 应用入口。
///
/// 结构（2026-09-28 页面层 D 档起步）：
/// `ProviderScope → MaterialApp.router（[appRouterProvider]）→ AppShell（双形态）→ 页面`；
/// · **登录守卫 / `?next=` 回跳 / catch-all** 全部在 `lib/router/app_router.dart`；
/// · 极光背景与全局 Scaffold 在 `MaterialApp.builder` 里统一包（缺 Scaffold 会让所有 Text
///   长出「未落在 Material 上」的黄色双下划线，debug/release 都会出现 —— 见 skill）；
/// · 逻辑层 wiring（自 PoC/M0 保留层沿用，勿改语义）：
///   ① `DioClient.instance.init`：注入 AuthNotifier 令牌存取 + 会话过期回调；
///   ② `initWsManager`：四通道 WS 管理器；
/// · **debug 专用**：右下角「组件 / 应用」切换（组件画布 = 唯一视觉验收面，`@Preview` 已弃用）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/app_init.dart';
import 'core/net/dio_client.dart';
import 'core/ws/ws_manager.dart';
import 'preview/component_gallery.dart';
import 'router/app_router.dart';
import 'state/auth_state.dart';
import 'state/chat_providers.dart';
import 'state/presence_providers.dart';
import 'state/room_providers.dart';
import 'theme/app_theme.dart';
import 'widgets/shell/overlay_scrollbar.dart';
import 'theme/aurora_background.dart';

void main() {
  // 仅 debug：常开语义树（供调试工具读元素；release 下被摇树移除）。
  // ⚠️ SemanticsBinding.instance 只有在 binding 初始化后才可访问：未初始化时取值抛
  //    "Binding has not yet been initialized"，main 当场中断 → runApp 永不执行 →
  //    没有首帧 → Windows runner 的 SetNextFrameCallback 不触发 → 窗口创建了却不 Show，
  //    表现为「进程活着但没有任何页面」。ensureInitialized 幂等，runApp 内部还会再调。
  if (kDebugMode) {
    WidgetsFlutterBinding.ensureInitialized();
    SemanticsBinding.instance.ensureSemantics();
  }

  // 逻辑层 wiring：DioClient 单例 ← AuthNotifier（实现 AuthTokenStore 契约）
  final ProviderContainer container = ProviderContainer();
  final AuthNotifier auth = container.read(authNotifierProvider.notifier);
  DioClient.instance.init(
    tokenStore: auth,
    onSessionExpired: () {
      AppInit.instance.reset();
      wsManager?.disconnectAll();
      // 消息域：401 过期与显式登出同一套收尾（清订阅/基线/消息与红点状态）。
      aylaStopChatWsForContainer(container);
      // 房内域：断开 voice/live 两通道 + 解绑目录帧桥 + 清房内状态。
      aylaStopRoomsForContainer(container);
      // presence 域：断开通道 owner + 清空在线集合（web `presenceClient.disconnect` 的 reset）。
      aylaStopPresenceWsForContainer(container);
      auth.clear();
      // 回登录由路由守卫接（`app_router.dart` 的 redirect + refreshListenable）
    },
  );
  initWsManager(tokens: auth);
  // 房内域目录帧桥：挂在 chat WS 的 onFrame 上（web `chat.ts` 的 voice.channel.* /
  // live.* / boardgame.room.* 分支 + `stores/directory.ts` 的创建/删除跟踪）。
  // 与 chat 连接时机解耦：只登记回调，未连时不消费任何帧。
  aylaStartRoomFrames(container);

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const _AppRoot(),
    ),
  );
}

/// 应用根（debug 下可在「应用」与「组件画布」之间切换）。
class _AppRoot extends ConsumerStatefulWidget {
  const _AppRoot();

  @override
  ConsumerState<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends ConsumerState<_AppRoot> {
  /// 组件画布舞台（唯一视觉验收面）。
  bool _showGallery = false;

  @override
  Widget build(BuildContext context) {
    final GoRouter router = ref.watch(appRouterProvider);
    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      theme: buildAylaTheme(),
      routerConfig: router,
      // 必须包 Scaffold：MaterialApp 在没有 Scaffold 时会给所有 Text 套上
      // 「未落在 Material 上」的默认文本装饰（**黄色双下划线**）——这是
      // Flutter 的视觉提示而非设计线，debug/release 都会出现。
      // 极光背景交给 Scaffold 的 body 铺满。
      builder: (BuildContext context, Widget? child) {
        // ⚠️ 全局滚动条策略，**对齐 web 两处**（2026-09-28 用户截图点名「这个滚动条有问题」）：
        // ① `base.css:376–383` 全局隐藏原生滚动条（`* { scrollbar-width: none }` +
        //    `::-webkit-scrollbar { width: 0 }`）⇒ Flutter 侧用 `ScrollConfiguration` 关掉
        //    Material 自动挂的 `Scrollbar`（否则桌面端每个滚动容器右侧都会露一条粗条）；
        // ② `App.tsx:55` 在 **App 根部**挂 `<OverlayScrollbar />`（自绘细条 4px；窄屏 ≤768
        //    完全不显示）⇒ Flutter 侧等价物 = 库内 [AylaOverlayScrollbar]，同样挂**根部单实例**
        //    （它监听子树里所有 `Scrollable` 的滚动通知）。
        return ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: AylaOverlayScrollbar(
            child: Scaffold(
          backgroundColor: Colors.transparent,
          body: AylaAuroraBackground(
            child: Stack(
              children: <Widget>[
                // ⚠️ 用 Offstage 而不是「不挂」：切到画布再切回来时路由状态保活
                // （否则整棵 router 子树被销毁，退出画布会回到 initialLocation）。
                Offstage(
                  offstage: _showGallery,
                  child: child ?? const SizedBox.shrink(),
                ),
                if (_showGallery) const Positioned.fill(child: ComponentGallery()),
                if (kDebugMode)
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: FloatingActionButton.small(
                      onPressed: () =>
                          setState(() => _showGallery = !_showGallery),
                      child: Text(_showGallery ? '应用' : '组件'),
                    ),
                  ),
              ],
            ),
          ),
            ),
          ),
        );
      },
    );
  }
}