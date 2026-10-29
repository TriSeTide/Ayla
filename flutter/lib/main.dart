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
///
/// ## 第二个 Dart entrypoint：`aylaLiveWindowMain`（2026-10-30）
/// 电脑端直播「脱离应用」的独立置顶小窗跑在**第二个 Flutter engine** 里
/// （原生侧见 `windows/runner/live_window.cpp`）。自定义 entrypoint 必须是
/// **与 `main()` 同一个库**里的顶层函数，并带 `@pragma('vm:entry-point')`
/// 才不会被 AOT 摇掉 —— 所以它放在本文件，不在单独的文件里。
library;

import 'dart:async';
import 'dart:convert' show jsonDecode;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding, FrameTiming;
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:window_manager/window_manager.dart' show windowManager;

import 'core/media/media_cache.dart';
import 'core/platform/detached_live.dart';
import 'core/media/media_download_keepalive.dart';
import 'core/media/media_download_queue.dart';
import 'core/media/media_signer.dart';
import 'core/media/media_upload.dart';
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
import 'state/chat_state.dart' show aylaRegisterChatStateCurrentUserId;
import 'pages/live_support.dart' show aylaHandleLiveViewingLifecycle;
import 'state/room_providers.dart';
import 'theme/app_theme.dart';
import 'widgets/live/live_player.dart' show aylaUsesDesktopFullscreen;
import 'widgets/live/live_window_surface.dart' show AylaDetachedLiveWindowApp;
import 'widgets/shell/overlay_scrollbar.dart';
import 'theme/aurora_background.dart';

/// **实机掉帧探针（debug + profile）** —— 把「哪一帧慢、慢在 build 还是 raster」落到文件。
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
  final StringBuffer pending = StringBuffer();

  /// 只把文本追加进内存缓冲。
  ///
  /// ⚠️ **热路径绝不做磁盘 IO**（2026-10-16，独立调研实测发现）：
  /// 旧实现在每个 jank 帧上 `writeAsStringSync(..., flush: true)` —— 那是
  /// 「同步写 + `FlushFileBuffers`」，**在已经掉帧的帧上再叠加一次磁盘往返**，
  /// 且整屏玻璃+极光下 16.7ms 极易触线 ⇒ 几乎每帧都写 ⇒ **自我强化卡顿**
  /// （与探针数据里 gap 的 p99 = 135.5ms 特征吻合）。
  /// 现在逐帧只 `add` 到内存；`_drain()` 按 ≥1s 的节奏落盘且不强制 flush。
  void write(String s) {
    pending.write(s);
  }

  /// 把缓冲落盘（不 `flush: true`：交给 OS 的写回策略，避免同步等待）。
  void drain() {
    final File? target = log;
    if (target == null || pending.isEmpty) return;
    final String text = pending.toString();
    pending.clear();
    try {
      target.writeAsStringSync(text, mode: FileMode.append, flush: false);
    } catch (_) {
      // 探针自身绝不拖累渲染。
    }
  }

  try {
    log = File('ayla_jank.log');
    log.writeAsStringSync(
      '--- session ${DateTime.now().toIso8601String()} ---\n',
      mode: FileMode.append,
      flush: false,
    );
    debugPrint('[AYLA-FRAME] 日志已开启：${log.absolute.path}');
  } catch (e) {
    debugPrint('[AYLA-FRAME] 日志文件不可写（只打控制台）：$e');
  }

  // ---- 汇总统计（2026-10-16 加）----
  // 为什么需要：只记 `>= 24ms` 的帧时，**静止场景一条都不落** ⇒ 「Impeller vs Skia
  // 哪个更流畅」这种对照拿不到任何读数（实测：profile 空闲 45s = 0 条 jank）。
  // 改为把**全部帧**纳入统计，每 5 秒落一行汇总（p50/p90/p99/max + 帧数），
  // 于是「同一段交互在两个后端下的分布」可以直接对比，且不依赖交互脚本。
  final List<double> buildSamples = <double>[];
  final List<double> rasterSamples = <double>[];
  final List<double> totalSamples = <double>[];
  int lastFlushMs = DateTime.now().millisecondsSinceEpoch;

  double pct(List<double> sorted, double p) {
    if (sorted.isEmpty) return 0;
    final int i = ((sorted.length - 1) * p).round().clamp(0, sorted.length - 1);
    return sorted[i];
  }

  void flushSummary() {
    if (totalSamples.isEmpty) return;
    final List<double> bs = List<double>.of(buildSamples)..sort();
    final List<double> rs = List<double>.of(rasterSamples)..sort();
    final List<double> ts = List<double>.of(totalSamples)..sort();
    final int jank = totalSamples.where((double v) => v >= 24.0).length;
    write(
      '[AYLA-FRAME] summary n=${totalSamples.length} jank=$jank '
      'build p50=${pct(bs, 0.5).toStringAsFixed(1)} p90=${pct(bs, 0.9).toStringAsFixed(1)} '
      'p99=${pct(bs, 0.99).toStringAsFixed(1)} max=${bs.last.toStringAsFixed(1)} '
      '| raster p50=${pct(rs, 0.5).toStringAsFixed(1)} p90=${pct(rs, 0.9).toStringAsFixed(1)} '
      'p99=${pct(rs, 0.99).toStringAsFixed(1)} max=${rs.last.toStringAsFixed(1)} '
      '| total p50=${pct(ts, 0.5).toStringAsFixed(1)} p90=${pct(ts, 0.9).toStringAsFixed(1)} '
      'p99=${pct(ts, 0.99).toStringAsFixed(1)} max=${ts.last.toStringAsFixed(1)}\n',
    );
    buildSamples.clear();
    rasterSamples.clear();
    totalSamples.clear();
  }

  SchedulerBinding.instance.addTimingsCallback((List<FrameTiming> timings) {
    for (final FrameTiming t in timings) {
      final double build = t.buildDuration.inMicroseconds / 1000.0;
      final double raster = t.rasterDuration.inMicroseconds / 1000.0;
      final double total = t.totalSpan.inMicroseconds / 1000.0;
      buildSamples.add(build);
      rasterSamples.add(raster);
      totalSamples.add(total);
      // 明显掉帧逐条留档（便于事后看是哪一帧、慢在哪条线程）
      if (total >= 24.0) {
        write(
          '[AYLA-FRAME] jank total=${total.toStringAsFixed(1)}ms '
          'build=${build.toStringAsFixed(1)}ms '
          'raster=${raster.toStringAsFixed(1)}ms\n',
        );
      }
    }
    // 每 1 秒落一次盘（不逐帧写）：既保证读数及时，又不让 IO 进入渲染热路径。
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - lastFlushMs >= 1000) {
      lastFlushMs = nowMs;
      flushSummary();
      drain();
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
  // ⚠️⚠️ **必须在任何 Binding.instance / MethodChannel 使用之前无条件初始化**
  // （2026-10-31 实报「手机端更新后一点 App 直接白屏」的根因，release-only）。
  //
  // 旧写法把它包在 `if (kDebugMode || kProfileMode)` 里，靠下面 `aylaUsesDesktopFullscreen()`
  // 分支补一次 —— 但那条分支**只对 Windows/macOS/Linux 为真**，Android/iOS 走不到。
  // 于是 Android release 档出现这条致命链：
  //   ① binding 未初始化；
  //   ② 后面 `AylaDetachedLiveEvents.instance.bind()` 调 `MethodChannel.setMethodCallHandler`
  //      ⇒ `ServicesBinding.instance` 断言失败 ⇒ **main() 当场抛出**；
  //   ③ `runApp` 永不执行 ⇒ 没有首帧 ⇒ 用户看到的是纯白屏（进程活着、无任何页面）。
  // debug/profile 档因为上面那个 if 成立而正常 —— 这正是「测试全绿、真机白屏」的原因：
  // 单元测试自己会初始化 binding，`flutter build apk --debug` 也是 debug 档。
  //
  // `ensureInitialized()` 幂等，runApp 内部还会再调；这里无条件调用没有副作用，
  // 且同时满足后续所有「取 Binding.instance」的前置条件。
  WidgetsFlutterBinding.ensureInitialized();
  // 仅 debug：常开语义树（供调试工具读元素；release 下被摇树移除）。
  // ⚠️ SemanticsBinding.instance 只有在 binding 初始化后才可访问：未初始化时取值抛
  //    "Binding has not yet been initialized"，main 当场中断 → runApp 永不执行 →
  //    没有首帧 → Windows runner 的 SetNextFrameCallback 不触发 → 窗口创建了却不 Show，
  //    表现为「进程活着但没有任何页面」。ensureInitialized 幂等，runApp 内部还会再调。
  // ⚠️ `SchedulerBinding.instance` 只在 binding 初始化后才可用：未初始化时取值抛
  // "Null check operator used on a null value"（实测：profile + 探针时崩在
  // `_installJankProbe` 的 `SchedulerBinding.instance`）。
  // 该前置条件已由**函数开头那次无条件 `ensureInitialized()`** 满足（2026-10-31 起）——
  // 旧写法在这里再按 `kDebugMode || kProfileMode` 补一次，正是「release 档漏初始化」
  // 的来源，已删除（重复调用虽幂等，但保留它会掩盖同类缺陷）。
  if (kDebugMode) {
    SemanticsBinding.instance.ensureSemantics();
  }
  // ===== 桌面窗口控制器（直播真·全屏的前置）=====
  // `window_manager` 的 `ensureInitialized()` 在原生侧做一件**必须**的事：
  // `native_window = GetAncestor(GetView()->GetNativeWindow(), GA_ROOT)`
  // （window_manager_plugin.cpp 的 "ensureInitialized" 分支）—— 也就是把插件持有的
  // HWND 从 Flutter view 提升到**顶层窗口**。不调用它 ⇒ 后续 `setFullScreen`
  // 拿到的是 nullptr/子窗口 ⇒ 全屏操作静默无效（正是用户看到的「App 窗口内黑一下」）。
  //
  // ⚠️ 放在这里（binding 已初始化 + 首帧之前）的约束：
  // · 必须在 `WidgetsFlutterBinding.ensureInitialized()` **之后** —— 原生侧要
  //   `registrar->GetView()->GetNativeWindow()`，view 不存在时会崩；
  // · binding 已由函数开头那次**无条件** `ensureInitialized()` 就绪（2026-10-31 起）——
  //   旧写法在这里再补一次，正是「Android release 白屏」缺陷的成因（条件为假 ⇒ 不补）；
  // · 只对 window_manager 真正支持的桌面平台调用；Android/iOS 完全不碰这条通道。
  if (aylaUsesDesktopFullscreen()) {
    unawaited(
      windowManager.ensureInitialized().catchError((
        Object error,
        StackTrace stack,
      ) {
        // 窗口控制失败不能拦住启动：直播全屏会退化成「只有 Overlay 内容层」。
        debugPrint(
          '[AYLA-WINDOW] windowManager.ensureInitialized 失败：$error\n$stack',
        );
      }),
    );
  }
  // ⚠️ 掉帧探针在 **debug 与 profile 都装**（2026-10-16）：
  // profile 才是「测真实性能」的正确档位（AOT 编译、无 debug 断言开销，但仍保留
  // `addTimingsCallback`）；此前只在 debug 装 ⇒ 「release 卡不卡、卡在哪条线程」
  // 只能靠手感判断，无法定位。release 档仍不装：Dart VM 会摇掉该分支，
  // 且探针要写文件（release 环境不一定可写）。
  // ⚠️ 启用条件（2026-10-16 独立调研后收紧）：
  // · debug：默认开（开发期诊断，探针只写内存 + 秒级落盘，无同步 IO）；
  // · profile/release：**必须显式 `--dart-define=AYLA_FRAME_PROBE=true`** 才装。
  //   理由：探针虽已去掉热路径同步写盘，但它仍每帧进 `addTimingsCallback`、
  //   并在内存里累积三个 list —— 测性能时不该让被测对象带观测开销；
  //   要做 A/B 对照时再显式打开，两边都开或都关，保证公平。
  const bool probeForced =
      bool.fromEnvironment('AYLA_FRAME_PROBE', defaultValue: false);
  if (kDebugMode || (kProfileMode && probeForced)) {
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
  // ===== 媒体链路接线（2026-10-21 修复）=====
  // 此前 `MediaSigner` / `AylaMediaUploader` / `AylaMediaPicker` 三者的 `attach()`
  // **全项目零调用**（只有组件画布 preview 注入过替身）⇒ 生产运行时：
  //   · 上传抛 StateError「AylaMediaUploader 未注入 DioClient」→ 气泡恒显「发送失败」；
  //   · 查看抛 StateError「MediaSigner 未注入 DioClient」→ 所有签名媒体加载失败。
  // 表现与「完全没接对象存储」一致（用户实报：无法上传、也无法查看）。
  // 三者与 DioClient 同为进程级单例，必须在 DioClient.init 之后、首帧之前接上。
  MediaSigner.instance.attach(DioClient.instance);
  AylaMediaUploader.instance.attach(DioClient.instance);
  // ===== 语音中继 token 续期接线（2026-10-26）=====
  // `AylaVoiceMedia.setTokenRefresher` 此前**全仓 0 调用** ⇒ 中继连续失败达
  // `kRelayReconnectRefreshAfter`(3) 次后的续期钩子一直是默认的「返回 null」，
  // 即 token 过期导致的断连永远拿旧值重连、永远续不上（web 侧
  // `wsRelayRoom.ts:688–693` 是 `refreshAccessToken()` + 取最新 store 值）。
  //
  // ⚠️ 必须排在 `DioClient.instance.init(...)`（本函数上方）**之后**：续期闭包
  // 体内读的是 `DioClient.instance.refreshAccessToken()` 与 `instance.accessToken`，
  // init 之后 `_tokens` 才被接上（init 前调用会拿到恒 null 的令牌存取件）。
  // 语义对齐 web：先静默续期，**成功才取最新 access token**；续期失败返回 null
  // 本地媒体缓存（漫游缓存）启动预热：解析缓存根 + 探测可写性（不可写则降级到
  // 应用支持目录并记日志）+ 清理上次崩溃残留的 `.tmp`。
  // 语义见 `docs/architecture/flutter-local-media-cache.md` §3.2 / §6；
  // **不 await**：缓存是增强项，绝不能拖慢首帧（媒体真正被请求时也会 lazy 再走一遍，
  // 两条路径由 `ensureReady()` 的幂等 future 收敛，不会重复探测）。
  unawaited(AylaMediaCache.instance.ensureReady());
  // 持久下载队列启动续跑（2026-10-29 用户拍板）：
  // 「如果有下载任务仍未完成，但 app 清后台退出了下载失败了，该下载任务仍然保留，
  //   下次 app 启动时再次自动重新开始执行该下载任务。最多重试三次。」
  // 队列文件在缓存根同级，进程重启后 running 任务会恢复成 pending 重跑。
  // 同样不 await：不能拖慢首帧，且队列内部有并发上限与有界退避。
  // 后台保活接线（Android 前台服务）：队列有活就起、空了就停。
  // iOS/Windows 无「后台」概念，[AylaDownloadKeepAlive] 内部直接 no-op。
  AylaMediaDownloadQueue.instance.keepAliveSync =
      AylaDownloadKeepAlive.instance.syncWithQueue;
  unawaited(AylaMediaDownloadQueue.instance.resumeOnStartup());
  // 预加载接线（web `appInit.ts` 的 `loadCoreData`）：把 state 层的目录 / 帖子
  // store 装进 `core/app_init.dart` 的门（core 不反向依赖 state）。
  aylaRegisterCoreDataLoader();
  // ⚠️ 群主页左侧服务器列读的是 **chatState**（AylaGroupDirectory(chatState: …)，
  // group_page.dart:188），而预加载灌的是 social store ⇒ 必须在这里把取值器接上，
  // 预加载完成时才能把会话摘要灌进 chatState
  //（用户实机：「每次切换到主页选项卡时左侧群头像列表都要加载，这在 web 是不需要的」）。
  aylaRegisterChatStateResolver(() => container.read(chatStateProvider));
  // 「当前用户 id」注入（web `useAuthStore.getState().currentUser?.id` 的等价物）：
  // `chat_state.dart` 的 `_normalize` 推导私聊 peer 时必须能**排除自己**
  // （web `stores/chat.ts:129–133` 的 `members.find(m => m.user.id !== me)`）。
  // 不注入 ⇒ 退化为取 members 首条 ⇒ 后端把本人排在首位的会话（实测真库 15/30）
  // 会把 peer 误判成自己，顶栏头像/昵称跟着错。state 层不依赖 Riverpod ⇒ 用注入。
  aylaRegisterChatStateCurrentUserId(
    () => container.read(authNotifierProvider).user?.id,
  );
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

  // ===== 直播「脱离应用」事件绑定（Android PiP / Windows 独立小窗 / 悬浮球）=====
  // 原生 → Dart 的单一入口（契约见 lib/core/platform/detached_live.dart）。
  // `bind()` 幂等；它只挂 MethodCallHandler、**不发**任何平台调用 ⇒ 首帧前挂上安全。
  // 必须早于页面订阅：PiP 进出事件可能在任意页面建立监听之前就到达，晚绑会丢事件。
  AylaDetachedLiveEvents.instance.bind();

  // ---- 冷启动会话恢复 + 自动登录（一条启动链，2026-10-19 重构）----
  //
  // 用户实报「手机端切后台重登」：Android 在内存紧张时会杀掉进程，回到前台是**冷启动**。
  // 之前只有「自动登录」一条路（用明文口令重放 `/auth/login/`），没勾开关的人会被踢
  // 回登录页 —— 哪怕 refresh 令牌还完全有效。现在补上 web `main.tsx:36 restoreSession()`
  // 的等价物，两条路**串成一条链**，按优先级依次尝试：
  //
  //   ① refresh 静默续期（快、无 UI 闪烁；不依赖任何用户开关，web 同款无条件路径）；
  //   ② 勾了「自动登录」⇒ 用明文口令重放登录（让用户在登录页**看见**它在登）；
  //   ③ 都失败 ⇒ 停在登录页（守卫把人留在 `/login`）。
  //
  // ⚠️ 顺序不能并行：并行会发出两次登录链（两个 /auth/login/ 或 refresh + login 竞争），
  // 正是 [aylaApplyLoginSession] 注释里担心的重复副作用。
  // ⚠️ 也**不能 await 在 runApp 之前**：那会把首帧一起卡住（登录页应当立刻出现）。
  // 成功后令牌落地 → `app_router.dart` 的 redirect 自动把 `/login` 换成目标页。
  unawaited(aylaBootstrapSession(container));

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const _AppRoot(),
    ),
  );
}

// =============================================================================
// 第二个 Dart entrypoint：电脑端直播「脱离应用」的独立置顶小窗
// =============================================================================

/// 独立直播小窗的 Dart 入口（**第二引擎**；原生侧见
/// `windows/runner/live_window.cpp` 的 `AylaLiveWindowHost::Show`）。
///
/// ## 为什么必须写在这里
/// `FlutterDesktopEngineProperties.dart_entrypoint` 要求自定义 entrypoint 是
/// **和 `main()` 同一个 Dart 库**里的顶层函数，并且必须带
/// `@pragma('vm:entry-point')`，否则 AOT/release 会被摇树删掉（debug 下也能
/// 编译通过、release 直接 crash —— 这是这类入口最常见的坑）。
///
/// ## 参数
/// 原生侧通过 `set_dart_entrypoint_arguments({json})` 传一条 JSON：
/// `{"playUrl": "...", "title": "...", "channelId": "..."}`。
/// 「只认 playUrl」是有意的：第二引擎**没有登录态**（不要在这里读
/// shared_preferences / flutter_secure_storage，会 channel-error），
/// 播放地址由主窗口带鉴权 query 传进来（已过 `aylaNormalizeLivePlayUrl` 归一）。
///
/// ## 这一棵树里**没有什么**
/// 没有 ProviderScope / router / Dio / WS / 极光背景 —— 见
/// `lib/widgets/live/live_window_surface.dart` 文件头的「有意差异 3」。
/// 这一路 HLS 与主窗口那一路互不相干；观看登记（心跳 / 在看名单）仍由
/// **主窗口**的会话继续跑（用户要求「小窗观看也算观看人」）。
@pragma('vm:entry-point')
void aylaLiveWindowMain(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  String? playUrl;
  String? title;
  if (args.isNotEmpty) {
    try {
      final Object? decoded = jsonDecode(args.first);
      if (decoded is Map) {
        final Object? rawUrl = decoded['playUrl'];
        final Object? rawTitle = decoded['title'];
        if (rawUrl is String && rawUrl.isNotEmpty) playUrl = rawUrl;
        if (rawTitle is String && rawTitle.isNotEmpty) title = rawTitle;
      }
    } catch (error) {
      // 参数不是合法 JSON（例如手工调试时）：退化成纯黑小窗，不崩。
      debugPrint('[AYLA-LIVE-WINDOW] entrypoint 参数解析失败：$error');
    }
  }
  runApp(
    AylaDetachedLiveWindowApp(
      initialUrl: playUrl,
      initialTitle: title,
    ),
  );
}

/// 应用根（debug 下可在「应用」与「组件画布」之间切换）。
class _AppRoot extends ConsumerStatefulWidget {
  const _AppRoot();

  @override
  ConsumerState<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends ConsumerState<_AppRoot>
    with WidgetsBindingObserver {
  /// 组件画布舞台（唯一视觉验收面）。
  bool _showGallery = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// App 前后台切换 ⇒ 直播观看登记的开/关（2026-10-26 用户实报补齐）。
  ///
  /// ## 为什么必须做（实测定位）
  /// 用户报「手机退出直播间后，电脑仍看到手机账号在观看」。线上 redis 显示
  /// 该观众的活跃分**持续刷新** ⇒ 心跳仍在跑 ⇒ **WS 没断**；而实测「连接一断，
  /// 后端立刻把它移出在看名单」（连上→断开，`zrange` 从 [me] 变 []）。
  ///
  /// 根因：全仓**没有任何 App 生命周期处理**。手机「退出直播间」后若 App 进
  /// 后台/锁屏，页面虽 dispose 但进程常驻、系统允许连接存活 ⇒ 别人一直看到你
  /// 在观看。PC 上关页面即断，所以只有手机方向出问题。
  ///
  /// 语义：**进后台 = 离开观看**（停心跳、退出名单）；回前台且在直播场景则续上。
  ///
  /// ⚠️ 2026-10-30 增补：**Android 画中画里仍算在看**（见
  /// [aylaHandleLiveViewingLifecycle]，实现在 `pages/live_support.dart`）。
  ///
  /// 判定逻辑**不放在这里**：本文件无法被单元测试直接驱动（`main()` 会拉起
  /// ProviderContainer / Dio / WS）。把语义落在会话层，这里只做「观察者转发」——
  /// 于是「PiP 里不算离开观看」这条用户要求有真实的定向测试（`test/live_pip_lifecycle_test.dart`）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    unawaited(aylaHandleLiveViewingLifecycle(state));
  }

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