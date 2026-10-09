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

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding, FrameTiming;
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/net/dio_client.dart';
import 'state/app_preload.dart';
import 'state/auth_bootstrap.dart';
import 'state/favorite_status.dart' show aylaFavoriteResetScope;
import 'core/ws/ws_manager.dart';
import 'preview/component_gallery.dart';
import 'layout/app_gate.dart';
import 'router/app_router.dart';
import 'state/auth_state.dart';
import 'state/chat_providers.dart';
import 'state/room_providers.dart';
import 'theme/app_theme.dart';
import 'widgets/shell/overlay_scrollbar.dart';
import 'theme/aurora_background.dart';

/// **实机掉帧探针（仅 debug）** —— 把「哪一帧慢、慢在 build 还是 raster」直接打到控制台。
///
/// 为什么需要它：性能整改前几轮只能靠 `flutter test` 的**软件光栅化**做相对对照
/// （它测不到 GPU、也测不到真机的 AOT/DPR 差异），无法确定实机那一顿到底出在哪条线程。
/// 这个探针不改任何渲染路径，只订阅 `SchedulerBinding.addTimingsCallback`：
/// 当某帧的 `totalSpan` ≥ 24ms（明显掉帧）时打印一行，例如
/// `[AYLA-FRAME] jank total=42.1ms build=31.2ms raster=9.4ms`。
///
/// · `build` 大 ⇒ Dart/UI 侧（挂载、布局、绘制记录）—— 时间切片/懒挂载能救；
/// · `raster` 大 ⇒ GPU 侧（backdrop 模糊、saveLayer）—— 减少玻璃件/缓存能救。
void _installJankProbe() {
  // 同时**落盘**（cwd = 工程根 `Ayla/flutter`）：控制台容易被滚掉的日志不算证据，
  // 文件能让"那一帧到底慢在哪"变成可复现的读数。
  File? log;
  try {
    log = File('ayla_jank.log');
    log.writeAsStringSync(
      '--- session ${DateTime.now().toIso8601String()} ---\n',
      mode: FileMode.append,
      flush: true,
    );
    debugPrint('[AYLA-FRAME] 日志已开启：${log.absolute.path}');
  } catch (e) {
    debugPrint('[AYLA-FRAME] 日志文件不可写（只打控制台）：$e');
  }
  SchedulerBinding.instance.addTimingsCallback((List<FrameTiming> timings) {
    for (final FrameTiming t in timings) {
      final double build = t.buildDuration.inMicroseconds / 1000.0;
      final double raster = t.rasterDuration.inMicroseconds / 1000.0;
      final double total = t.totalSpan.inMicroseconds / 1000.0;
      // ⚠️ **只落盘、不打控制台**（2026-10-01 用户裁决「把那个刷屏去掉，现在应该没用」）：
      // 本探针在性能整改轮用于定位 build/raster 瓶颈，已完成使命；但它**每帧都可能命中**
      // （阈值 24ms，实测常态 40–60ms 一帧）⇒ 控制台被 `[AYLA-FRAME]` 彻底淹没，
      // **flutter run 的连接状态 / 异常 / print 全部看不见**，反而阻断后续调试。
      // 保留落盘能力（`ayla_jank.log`，按需查），控制台完全静默。
      if (total >= 24.0) {
        try {
          log?.writeAsStringSync(
            '[AYLA-FRAME] jank total=${total.toStringAsFixed(1)}ms '
            'build=${build.toStringAsFixed(1)}ms '
            'raster=${raster.toStringAsFixed(1)}ms\n',
            mode: FileMode.append,
            flush: true,
          );
        } catch (_) {
          // 探针自身绝不拖累渲染。
        }
      }
    }
  });
}

/// 收藏状态的作用域标识 —— web `authScope()`
/// （`stores/favoriteStatus.ts:28–31`）：
/// `` `${currentUser?.id ?? "anonymous"}:${accessToken ? "authenticated" : "anonymous"}` ``。
///
/// 逐字同源：只有「用户 id」或「是否已认证」变化才算换账号。
String _favoriteAuthScope(AuthState state) =>
    '${state.user?.id ?? 'anonymous'}:'
    '${state.isAuthenticated ? 'authenticated' : 'anonymous'}';

/// 上次同步的收藏作用域（web 的模块级 `scope` 变量，`favoriteStatus.ts:20`）。
///
/// null = 尚未建立基线 ⇒ 首次只记录、**不自增代际**（避免启动瞬间白清一次缓存）。
String? _favoriteAuthScopeLast;

void main() {
  // 仅 debug：常开语义树（供调试工具读元素；release 下被摇树移除）。
  // ⚠️ SemanticsBinding.instance 只有在 binding 初始化后才可访问：未初始化时取值抛
  //    "Binding has not yet been initialized"，main 当场中断 → runApp 永不执行 →
  //    没有首帧 → Windows runner 的 SetNextFrameCallback 不触发 → 窗口创建了却不 Show，
  //    表现为「进程活着但没有任何页面」。ensureInitialized 幂等，runApp 内部还会再调。
  if (kDebugMode) {
    WidgetsFlutterBinding.ensureInitialized();
    SemanticsBinding.instance.ensureSemantics();
    _installJankProbe();
  }

  // 逻辑层 wiring：DioClient 单例 ← AuthNotifier（实现 AuthTokenStore 契约）
  final ProviderContainer container = ProviderContainer();
  final AuthNotifier auth = container.read(authNotifierProvider.notifier);
  DioClient.instance.init(
    tokenStore: auth,
    onSessionExpired: () {
      // 401 过期收尾：与显式登出**同一套**（断四通道 / 清缓存 / 清令牌），
      // 定义处 = `state/auth_bootstrap.dart`（两条路径共用一份，避免漂移）。
      // ⚠️ 不删已保存凭据：用户勾了「记住密码」就应当打开即回填。
      unawaited(aylaLogoutForContainer(container));
      // 回登录由路由守卫接（`app_router.dart` 的 redirect + refreshListenable）
    },
  );
  initWsManager(tokens: auth);
  // 预加载接线（web `appInit.ts` 的 `loadCoreData`）：把 state 层的目录 / 帖子
  // store 装进 `core/app_init.dart` 的门（core 不反向依赖 state）。
  aylaRegisterCoreDataLoader();
  // ⚠️ 群主页左侧服务器列读的是 **chatState**（AylaGroupDirectory(chatState: …)，
  // group_page.dart:188），而预加载灌的是 social store ⇒ 必须在这里把取值器接上，
  // 预加载完成时才能把会话摘要灌进 chatState
  //（用户实机：「每次切换到主页选项卡时左侧群头像列表都要加载，这在 web 是不需要的」）。
  aylaRegisterChatStateResolver(() => container.read(chatStateProvider));
  // 收藏状态的作用域（登录账号）跟踪 —— web `ensureFavoriteScope`
  // （`stores/favoriteStatus.ts:34–48`）里那条
  // `useAuthStore.subscribe(() => ensureFavoriteScope())` 的等价物。
  //
  // web 在**每次读写前**比对 `authScope()`（`currentUser.id + 是否已认证`），
  // 变了就 `epoch += 1` 并清空 entries/queue/active ⇒ 在途响应作废、旧账号状态不残留。
  // Flutter 侧对应 [aylaFavoriteResetScope]；此前**没有任何调用点**（本文件即接线点），
  // 于是跨登录周期残留旧账号收藏状态、且在途响应不会被丢弃。
  //
  // ⚠️ 只在**账号标识真的变化**时自增（`favoriteStatus.ts:36` 的 `if (scope !== next)`）：
  // 否则每次 build/每帧都多留一代。判据与 web 的 `authScope()` 逐字同源。
  container.listen<AuthState>(
    authNotifierProvider,
    (AuthState? previous, AuthState next) {
      final String scope = _favoriteAuthScope(next);
      if (_favoriteAuthScopeLast != null &&
          _favoriteAuthScopeLast != scope) {
        aylaFavoriteResetScope();
      }
      _favoriteAuthScopeLast = scope;
    },
  );
  _favoriteAuthScopeLast = _favoriteAuthScope(
    container.read(authNotifierProvider),
  );

  // 社交缓存订阅（web `ensureSocialTracking`，`stores/social.ts:108–120`）：
  // chatState.conversations / subgroupState.byGroup 一变，就把新值就地合并进 social record
  // 的已加载投影（主页群列表 / 宽屏群头像列的数据源）。
  // ⚠️ **必须启动期建**（web 是 loadSocial 首次调用时懒装配）：WS 帧可能在任何页面取数之前
  // 到达（chat_ws 已经写 chatState），懒装配会漏掉这批早期帧。
  aylaStartSocialTracking(container);
  // 房内域目录帧桥：挂在 chat WS 的 onFrame 上（web `chat.ts` 的 voice.channel.* /
  // live.* / boardgame.room.* 分支 + `stores/directory.ts` 的创建/删除跟踪）。
  // 与 chat 连接时机解耦：只登记回调，未连时不消费任何帧。
  aylaStartRoomFrames(container);
  // 帖子域帧桥（chat WS 的 `post.*` 四条 + 帖子/桌游全局 store 的落地）
  // —— web `ws/chat.ts:766–840`；同样只登记回调，与 chat 连接时机解耦。
  aylaStartPostsFrames(container);

  // 冷启动自动登录（用户需求 2026-10-01）：勾了「自动登录」时，用安全存储里的账号密码
  // 跑一次真实 `POST /auth/login/`，成功即走与手动登录**完全相同**的副作用链。
  //
  // ⚠️ **刻意不 await**：自动登录要占一次完整往返，等它会把首帧一起卡住；
  // 登录页由路由守卫立即渲染，用户在页面上**看得见**它自动登录成
  // （`pages/login_page.dart` 的 `submitting` 档显「登录中…」，状态来自
  // `state/auth_bootstrap.dart` 的 `aylaAutoLoginInFlight`）。
  // 成功后令牌落地 → `app_router.dart` 的 redirect 自动把 `/login` 换成目标页。
  unawaited(aylaRunAutoLogin(container));

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
                // 预加载门 × 路由页面的互斥装配（web App.tsx:48–51）——
                // 见 layout/app_gate.dart 的库文档（含早期 Stack 塌成 0×0 的尺寸陷阱）。
                // 抽成独立组件是为了能对它做**实绘尺寸**回归（test/app_gate_test.dart）：
                // 门打开时若 Stack 没设 fit=expand，Offstage 会把 Stack 量成 0×0、
                // 门被填成 0×0，且只在门该显示时消失 ⇒ 极易漏过。
                AylaAppGate(
                  page: child ?? const SizedBox.shrink(),
                  gallery: const ComponentGallery(),
                  showGallery: _showGallery,
                ),
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