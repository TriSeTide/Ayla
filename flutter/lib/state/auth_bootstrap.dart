/// 认证会话接线：**登录后副作用 + 冷启动自动登录**的唯一定义处。
///
/// ## 为什么需要这个文件
/// 「登录成功后要做什么」原本只写在 `pages/login_route.dart`（表单登录路径）。加了自动登录后，
/// 冷启动路径（`main.dart`，非 widget）也要做**同一串**副作用。复制一份必然漂移
/// ⇒ 抽到这里两条路径共用。
///
/// ## 用户需求（2026-10-01，原文口径）
/// - 勾「记住密码」⇒ 每次打开 App 不必再输账号密码、直接点登录；
/// - 勾「自动登录」⇒ 每次打开 App **先到登录页、看见它自动登录**（不是绕过登录页）。
///
/// 所以冷启动走的是**真实登录请求**（`POST /auth/login/`，与手动登录同一接口、同一副作用），
/// 而不是 web `stores/auth.ts:106 restoreSession()` 的「refresh 续期」路径 —— 后者不满足
/// 「用记住的账号密码登录」，refresh 失效时也会回落登录页。本件与 web 的关系是**功能增量**，
/// 视觉层仍完全复用既有登录页（`pages/login_page.dart`）。
///
/// ## 接口为什么收 `ProviderContainer` 而不是 `Ref`/`WidgetRef`
/// Riverpod 2.6 里 `Ref` 与 `WidgetRef` **没有公共父类型**（3.0 才统一），而本文件的两个调用方
/// 分别是「`main.dart` 的根容器」与「`ConsumerState` 的 ref」。widget 侧用
/// `ProviderScope.containerOf(context, listen: false)` 拿到同一个根容器即可 ——
/// 与既有的 `aylaStopChatWsForContainer` / `aylaStopChatWs` 配对约定同源。
///
/// ## 与登出的边界
/// [aylaLogoutForContainer] / [aylaLogout] **不删除**已保存的凭据：这是「记住密码」的语义
/// （下次打开仍是回填好、可直接点登录的样子）。想彻底忘记 ⇒ 在登录页取消「记住密码」，
/// 由 `state/auth_prefs.dart` 的 `save(rememberPassword: false)` 清空全部键。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api/auth_api.dart';
import '../core/app_init.dart';
import '../core/ws/chat_ws.dart';
import '../core/ws/presence_ws.dart';
import '../core/ws/ws_manager.dart';
import 'auth_prefs.dart';
import 'auth_state.dart';
import 'chat_providers.dart';
import 'presence_providers.dart';
import 'posts_store.dart' show aylaPostTabCache;
import 'room_providers.dart';
import 'social_store.dart' show aylaSocialStore;

/// 凭据与开关仓库（登录页与启动期共用同一存储）。
final Provider<AylaAuthPrefsStore> authPrefsStoreProvider =
    Provider<AylaAuthPrefsStore>((Ref ref) => AylaAuthPrefsStore());

/// **自动登录进行中**（login 页据此显示「登录中…」，让用户看得见它在自动登录）。
///
/// 模块级 `ValueNotifier` 而不是 provider：它跨 `main` 与 widget 两侧，
/// 且只有「进行中/结束」两态（web 无对应物，属新增功能的反馈面）。
final ValueNotifier<bool> aylaAutoLoginInFlight = ValueNotifier<bool>(false);

/// 登录成功后的**全部副作用**（web `useAuth.login` 链 + 本项目的预加载门）。
///
/// 顺序逐条对齐既有实现（原 `LoginRoute._submit`，不得改变语义）：
/// 1. 写令牌 → 拉 `GET /me/` 写用户；
/// 2. `wsManager.connectAll()`（四通道 socket）；
/// 3. chat 通道 owner 绑定 + 连接 + 登记订阅；
/// 4. presence 通道 owner 绑定 + 连接；
/// 5. 未读聚合 `GET /me/badges/`（不 await）；
/// 6. 预加载门 `AppInit.run(userId)`（不 await，由全屏门消费状态）。
Future<void> aylaApplyLoginSession(
  ProviderContainer container,
  TokenPair pair, {
  AuthUser? user,
}) async {
  final AuthNotifier auth = container.read(authNotifierProvider.notifier);
  // ⚠️ **顺序**：先拉 `/me/`（显式带刚拿到的 access），再写令牌。
  // 反过来的话 `AuthState.isAuthenticated` 会先翻转 ⇒ `app_router.dart` 的守卫在
  // 用户对象尚未落地的窗口里就把登录页换掉，页面会先渲染一帧 "未登录态" 的头像/昵称。
  final AuthUser me = user ?? await AuthApi.me(accessToken: pair.access);
  auth.setTokens(pair.access, pair.refresh);
  auth.setUser(me);
  // web `useAuth.login`：connect 两条 WS（`connectAll` 幂等）+ 跑预加载门。
  wsManager?.connectAll();
  _startChatWs(container);
  _startPresenceWs(container);
  unawaited(container.read(badgesProvider).fetch());
  // userId 进目录 record 的 key 段（web `directoryKey` 读 currentUser.id）。
  unawaited(
    AppInit.instance.run(userId: container.read(authNotifierProvider).user?.id),
  );
}

/// chat 通道 owner 的容器版启动（= `chat_providers.dart:aylaStartChatWs` 的 WidgetRef 版语义）。
///
/// 单独写在这里而不是改动 `chat_providers.dart`：那两处是 widget 侧入口，
/// 本文件只服务容器侧调用方（`Ref`/`WidgetRef` 无公共父类型，见库文档）。
void _startChatWs(ProviderContainer container) {
  final AylaChatWsClient client = container.read(chatWsProvider);
  final WsManager? manager = wsManager;
  if (manager != null) client.attach(manager.chat);
  client.connect();
}

/// presence 通道 owner 的容器版启动（= `presence_providers.dart:aylaStartPresenceWs`）。
void _startPresenceWs(ProviderContainer container) {
  final AylaPresenceWsClient client = container.read(presenceWsProvider);
  final WsManager? manager = wsManager;
  if (manager != null) client.attach(manager.presence);
  client.connect();
}

/// 登出收尾（[ProviderContainer] 版）—— `main.dart` 的 401 过期与 widget 侧登出共用。
///
/// **等价于** Flutter 侧既有的两条登出链：`main.dart` 的 `onSessionExpired` 与
/// `layout/app_shell.dart` 的 `_logout()`。此处只把两者合成一份，不改顺序。
///
/// `clearCredentials`：
/// - `false`（默认，登出 / 会话过期）⇒ **保留**已保存凭据，下次打开仍可一键登录；
/// - `true` ⇒ 一并清空安全存储里的凭据与开关。
Future<void> aylaLogoutForContainer(
  ProviderContainer container, {
  bool clearCredentials = false,
}) async {
  AppInit.instance.reset();
  // 帖子页 tab 缓存（web `postTabSession` 机制）：账号切换 / 登出清空，
  // 避免下一位用户读到上一位的分页快照。
  aylaPostTabCache.clear();
  aylaSocialStore.reset();
  // 帖子 / 桌游两份全局 store 的清空归 aylaStopRoomsForContainer（与房内设备/状态同一收口，
  // 见 state/room_providers.dart 的 aylaStopPostsFramesForContainer 注释里的账号隔离理由）。
  wsManager?.disconnectAll();
  aylaStopChatWsForContainer(container);
  aylaStopRoomsForContainer(container);
  aylaStopPresenceWsForContainer(container);
  container.read(authNotifierProvider.notifier).clear();
  if (clearCredentials) {
    await container.read(authPrefsStoreProvider).clear();
  }
}

/// 登出收尾（`WidgetRef` 版；UI 触发用，`layout/app_shell.dart` 消费）。
void aylaLogout(WidgetRef ref, {bool clearCredentials = false}) {
  AppInit.instance.reset();
  aylaPostTabCache.clear();
  aylaSocialStore.reset();
  // 同上（WidgetRef 版）：posts / boardgame store 的清空在 aylaStopRooms 内。
  wsManager?.disconnectAll();
  aylaStopChatWs(ref);
  aylaStopRooms(ref);
  aylaStopPresenceWs(ref);
  ref.read(authNotifierProvider.notifier).clear();
  if (clearCredentials) {
    unawaited(ref.read(authPrefsStoreProvider).clear());
  }
}

/// 冷启动的**首屏落点**（纯函数，便于锁定）。
///
/// 用户口径：「勾了自动登录 ⇒ 每次打开 App **到登录页面、然后看见他自动登录**」
/// ⇒ 自动登录在途时首屏必须是 `/login`，**不能**静默跳过登录页直接进应用。
///
/// 没开自动登录时该位同样会短暂为真（读安全存储那一小段），落到 `/login` 与既有行为等价：
/// 未登录访问 `/group` 本来就会被守卫送回登录页（冷启动没有 deep-link，不缺 `?next=`）。
String aylaInitialLocation({required bool autoLoginInFlight}) =>
    autoLoginInFlight ? '/login' : '/group';

/// 冷启动自动登录的**最小可见时长**。
///
/// 用户对这条功能的口径是「每次打开 App **到登录页、看见它自动登录**」——
/// 本机后端一次 `/auth/login/` 往往只要几十毫秒，不刻意留一拍的话登录页会一闪而过，
/// 变成「功能没生效」的观感。这里让自动登录**晚一拍**开始：首帧先稳稳落在登录页
/// （账号密码已回填、按钮已是「登录中…」），随后才发请求。
///
/// ⚠️ 这只是**开始时机**的延迟，不是假动画：登录请求本身仍是真实的、紧接着就发出。
/// 数值刻意取小（一帧 ≈16.7ms；400ms 是"看得清"与"不拖沓"的折中），调它只改这一个常量。
const Duration kAutoLoginVisibleDwell = Duration(milliseconds: 400);

/// 冷启动自动登录结果（调用方据此决定是否提示用户）。
enum AylaAutoLoginOutcome {
  /// 未满足条件（没勾自动登录，或没有完整凭据）⇒ 什么都不做。
  skipped,

  /// 已有有效会话（极少数：同进程内重新触发）⇒ 不重复登录。
  alreadySignedIn,

  /// 自动登录成功。
  success,

  /// 尝试过但失败（网络 / 口令已改 / 后端拒绝）⇒ 登录页显示错误，用户手动输入即可。
  failed,
}

/// 模块级单飞位：同一进程内自动登录**只可能跑一次**。
///
/// 为什么必须单飞：重复触发会产生多条登录链（多个 `/auth/login/`、重复的 WS 连接与
/// 预加载门）。与 web「单一 `restoreSession` 入口」同风险面。
Future<AylaAutoLoginOutcome>? _autoLoginInFlight;

/// 冷启动自动登录：**用已保存的账号密码跑一次真实登录**，成功后走
/// [aylaApplyLoginSession] 的完整副作用链。
///
/// 幂等：重复调用返回同一个 Future（见 [_autoLoginInFlight]）。
/// 调用点只有一个 —— `main.dart` 在 `runApp` 之前触发；随后路由守卫会在
/// 令牌落地时自动把 `/login` 重定向进应用（因此**不需要**登录页额外配合）。
Future<AylaAutoLoginOutcome> aylaRunAutoLogin(ProviderContainer container) {
  return _autoLoginInFlight ??= _runAutoLogin(container);
}

/// 测试用：复位单飞位（生产路径不得调用）。
@visibleForTesting
void aylaResetAutoLoginGate() {
  _autoLoginInFlight = null;
  aylaAutoLoginInFlight.value = false;
}

Future<AylaAutoLoginOutcome> _runAutoLogin(ProviderContainer container) async {
  final AuthNotifier auth = container.read(authNotifierProvider.notifier);
  if (container.read(authNotifierProvider).isAuthenticated) {
    return AylaAutoLoginOutcome.alreadySignedIn;
  }
  aylaAutoLoginInFlight.value = true;
  // 「本轮自己写进去的 access」—— 只有它才允许被本轮回滚（见 catch 的竞态说明）。
  String? written;
  try {
    final AylaAuthPrefs prefs = await container.read(authPrefsStoreProvider).load();
    if (!prefs.canAutoLogin) return AylaAutoLoginOutcome.skipped;
    // 让登录页先「被看见」（见 [kAutoLoginVisibleDwell] 的说明）。
    await Future<void>.delayed(kAutoLoginVisibleDwell);
    final TokenPair pair = await AuthApi.login(prefs.username, prefs.password);
    written = pair.access;
    await aylaApplyLoginSession(container, pair);
    return AylaAutoLoginOutcome.success;
  } catch (err) {
    // 失败必须可观测（工程纪律）；网络不通 / 口令已改属常见情形，不是异常路径。
    debugPrint('[AylaAuth] 自动登录失败：$err');
    // ⚠️ **只回滚自己写的那串令牌**（2026-10-01 竞态修复）：
    // 自动登录在后台跑的同时，用户可能已经在登录页手动登录成功；无条件 `clear()`
    // 会把用户刚拿到的会话踢掉。判据 = 当前 access 与本轮 login 返回的 access 相同。
    final AuthState now = container.read(authNotifierProvider);
    if (written != null && now.accessToken == written) {
      auth.clear();
    }
    return AylaAutoLoginOutcome.failed;
  } finally {
    aylaAutoLoginInFlight.value = false;
  }
}
