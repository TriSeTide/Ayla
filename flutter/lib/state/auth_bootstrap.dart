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
import '../core/net/dio_client.dart' show DioClient;
import '../core/ws/chat_ws.dart';
import '../core/ws/presence_ws.dart';
import '../core/ws/ws_manager.dart';
import '../widgets/base/scroll_restore.dart' show AylaScrollMemory;
import 'auth_prefs.dart';
import 'update_providers.dart';
import 'auth_state.dart';
import 'chat_providers.dart';
import 'presence_providers.dart';
import 'posts_store.dart' show aylaPostTabCache;
import 'room_providers.dart';
import 'social_store.dart' show aylaSocialStore;

/// 凭据与开关仓库（登录页与启动期共用同一存储）。
final Provider<AylaAuthPrefsStore> authPrefsStoreProvider =
    Provider<AylaAuthPrefsStore>((Ref ref) => AylaAuthPrefsStore());

/// **会话恢复用的 refresh 令牌仓库**（2026-10-19，对齐 web `stores/auth.ts:106 restoreSession`）。
///
/// 与 [authPrefsStoreProvider] 分开：这里是**令牌**（长期、跨进程），
/// 那里是**明文口令与开关**（供「自动登录」重放登录请求，见 auth_prefs.dart 文件头）。
/// 两条路径互不依赖 —— 用户可以只记住密码不自动登录，也可以两者都不勾但仍靠 refresh 续期。
final Provider<AylaSessionTokenStore> sessionTokenStoreProvider =
    Provider<AylaSessionTokenStore>((Ref ref) => AylaSessionTokenStore());

/// **自动登录进行中**（login 页据此显示「登录中…」，让用户看得见它在自动登录）。
///
/// 模块级 `ValueNotifier` 而不是 provider：它跨 `main` 与 widget 两侧，
/// 且只有「进行中/结束」两态（web 无对应物，属新增功能的反馈面）。
final ValueNotifier<bool> aylaAutoLoginInFlight = ValueNotifier<bool>(false);

/// **冷启动会话恢复进行中**（2026-10-19；决定首屏落点用）。
///
/// ## 为什么需要它（与 `aylaAutoLoginInFlight` 分开）
/// 静默续期**不该**让用户看见登录页 —— 那正是它与「自动登录」的区别：
/// 前者是「你本来就登录着，恢复一下」，后者是「用户要看它登进去」。
/// 但首屏落点必须在 `runApp` **之前**确定（`app_router.dart:146` 的 `initialLocation`），
/// 而此时网络往返还没回来 ⇒ 用一个同步可读的"在途"位让首屏先落在
/// 一个**中性的启动页**（`/group` 之外的空白档），等结果出来再由守卫落位。
///
/// ## 三态语义
/// - `true`：续期在途 ⇒ 首屏落在登录页但**不渲染表单**（显示启动态，避免一闪）；
/// - 结束时若成功 ⇒ 守卫立刻把 `/login` 换成 `/group`；
/// - 结束时若失败 ⇒ 登录页正常渲染（用户手动登录）。
///
/// ⚠️ 与 `aylaAutoLoginInFlight` **互斥使用**：同一时刻只会有其中一条路径在跑
/// （[aylaBootstrapSession] 串行化，见其文档）。
final ValueNotifier<bool> aylaSessionRestoreInFlight = ValueNotifier<bool>(false);

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
  // 落盘 refresh 令牌（**会话恢复**用；2026-10-19）。
  //
  // 与「记住密码」是两件事：那个存明文口令（供自动登录重放 /auth/login/），
  // 这里存 JWT refresh（供 [aylaRestoreSession] 静默续期）。后者不依赖用户勾任何开关 ——
  // web 也是无条件把 refresh 写进 sessionStorage（`stores/auth.ts:54`）。
  final String? refresh = pair.refresh;
  if (refresh != null && refresh.isNotEmpty) {
    unawaited(container.read(sessionTokenStoreProvider).write(refresh));
  }
  // web `useAuth.login`：connect 两条 WS（`connectAll` 幂等）+ 跑预加载门。
  //
  // ⚠️ **2026-10-26 修复（用户实报「发弹幕后自己的头像仍显示不在线」）**：
  // **attach 必须先于 connectAll**。原因：
  // - `connectAll()` 会让四个通道**立刻开始建连**（异步）；
  // - 后端 `PresenceConsumer.connect()` 在 accept 后**同步下发两条帧**：
  //   `presence.self` + `presence.update(status=online)`（实测确认）；
  // - 而 `_startPresenceWs` 里的 `client.attach(channel)` 才把 `channel.onEvent`
  //   接上 `_dispatch`。
  //
  // 旧顺序是「先把门打开、再装收件箱」⇒ 若 socket 在 attach 之前就绪（本机/局域网
  // 几乎必然），那两条帧到达时 `onEvent` 仍是 null ⇒ **被静默丢弃** ⇒
  // `presence.users` 里永远没有「自己」⇒ `presenceOnline` 回退 REST 快照
  // `user.online`（登录那一刻的值，通常 false）⇒ **自己头像永远灰**。
  //
  // 反过来先 attach 再连，`onEvent` 已就位，建连帧不会丢。
  _startChatWs(container);
  _startPresenceWs(container);
  wsManager?.connectAll();
  // ⚠️ **登录后重装三条帧桥 / 目录订阅通路**（2026-10-20 热更新审计 R1）。
  //
  // 为什么必须在这里补：这三条通路在 `main.dart` 启动期装配一次
  //（`aylaStartSocialTracking` / `aylaStartRoomFrames` / `aylaStartPostsFrames`），
  // 而登出与 401 过期会把它们**全部拆除**（`aylaStopRooms*` 的 `detach()` /
  // `aylaStopDirectoryTracking()` / `aylaDirectoryStore.itemUpsertHooks.clear()`）。
  // 重装函数 `*ForRef` 原本**全仓零调用** ⇒ 「登出/401 → 再登录」之后，
  // 语音/直播/桌游/帖子的 WS 帧**从此再无消费者**（帧到了、没人处理），
  // 取页结果也不再落回域 store，直到重启 App。
  //
  // web 侧不存在这个缺口：那些监听是模块级单例注册（`stores/directory.ts:205–259`
  // 的 `ensureDirectoryTracking`、`ws/chat.ts` 的模块级单例），`logout` 只
  // `reset()` store 数据、**不注销监听**。本处补的就是这个等价语义。
  //
  // 幂等：三条 `attach` / `start` 内部都先拆后挂（`_off?.call()` / `stop()`），
  // 重复登录不会叠加监听。
  _restartRealtimeBridges(container);
  unawaited(container.read(badgesProvider).fetch());
  // userId 进目录 record 的 key 段（web `directoryKey` 读 currentUser.id）。
  unawaited(
    AppInit.instance.run(userId: container.read(authNotifierProvider).user?.id),
  );
  // 客户端更新检查（2026-10-18 用户需求）：登录成功即检查一次，发现新版本弹窗。
  // ⚠️ 刻意不 await（更新检查不能拖慢登录/预加载门）；每个进程只自动弹一次
  //（controller 内部单飞），失败只 debugPrint，不打断登录。
  unawaited(container.read(updateControllerProvider).checkOnLogin());
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

/// 登录后**重装**三条实时通路（帧桥 ×2 + 目录订阅通路 + 社交缓存订阅）。
///
/// ## 为什么需要（2026-10-20 热更新审计 R1，头号根因）
/// 这四条通路的装配点只有 `main.dart` 启动期一处；而登出 / 401 过期会把它们**全部拆除**：
/// - `aylaStopRooms*` → `roomDirectoryBridgeProvider.detach()`（语音/直播/桌游帧桥）
/// - `aylaStopPostsFrames*` → `postsFramesBridgeProvider.detach()` + `itemUpsertHooks.clear()`
/// - `aylaStopDirectoryTracking()` → 三个域 store 的 `removeListener`
///
/// 而登录链此前**只**连 chat/presence，不重装这四条 ⇒ 「登出/401 → 再登录」之后
/// WS 帧到达但**没有任何消费者**，列表只能靠手动刷新/重进页面，直到重启 App。
///
/// web 侧没有这个缺口：`ensureDirectoryTracking`（`stores/directory.ts:205–259`）与
/// `ws/chat.ts` 的模块级单例监听在 `logout` 时**不注销**，只 `reset()` store 数据。
/// 本函数补的就是这个等价语义（拆除时清数据、重装时重新挂监听）。
///
/// 幂等：四个 `attach` / `start` 内部都先拆后挂。
void _restartRealtimeBridges(ProviderContainer container) {
  // ① 社交缓存订阅（web `ensureSocialTracking`）。
  aylaStartSocialTracking(container);
  // ② 房内域帧桥（voice.channel.* / live.* / boardgame.room.*）+ 目录订阅通路
  //   + 取页落地钩子（`_wireDirectoryTracking` 里一并注册）。
  aylaStartRoomFrames(container);
  // ③ 帖子域帧桥（post.created / deleted / updated / viewed）。
  aylaStartPostsFrames(container);
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
  // 滚动位置记忆（web `scrollMemory`）：**用户级**投影，登出必须清 —— 否则下一位用户
  // 打开同一列表会被恢复成上一位浏览者的位置。
  AylaScrollMemory.clear();
  aylaSocialStore.reset();
  // 帖子 / 桌游两份全局 store 的清空归 aylaStopRoomsForContainer（与房内设备/状态同一收口，
  // 见 state/room_providers.dart 的 aylaStopPostsFramesForContainer 注释里的账号隔离理由）。
  wsManager?.disconnectAll();
  aylaStopChatWsForContainer(container);
  aylaStopRoomsForContainer(container);
  aylaStopPresenceWsForContainer(container);
  container.read(authNotifierProvider.notifier).clear();
  // 会话恢复用的 refresh 令牌：登出**总是**清（它代表"这次会话"，不是用户偏好）；
  // 「记住密码 / 自动登录」那 4 个键只受 clearCredentials 控制（见上方文档）。
  await container.read(sessionTokenStoreProvider).clear();
  if (clearCredentials) {
    await container.read(authPrefsStoreProvider).clear();
  }
}

/// 登出收尾（`WidgetRef` 版；UI 触发用，`layout/app_shell.dart` 消费）。
void aylaLogout(WidgetRef ref, {bool clearCredentials = false}) {
  AppInit.instance.reset();
  aylaPostTabCache.clear();
  AylaScrollMemory.clear(); // 同上（容器版）：用户级投影，登出清空。
  aylaSocialStore.reset();
  // 同上（WidgetRef 版）：posts / boardgame store 的清空在 aylaStopRooms 内。
  wsManager?.disconnectAll();
  aylaStopChatWs(ref);
  aylaStopRooms(ref);
  aylaStopPresenceWs(ref);
  ref.read(authNotifierProvider.notifier).clear();
  // 同上（容器版）：refresh 令牌登出即清。
  unawaited(ref.read(sessionTokenStoreProvider).clear());
  if (clearCredentials) {
    unawaited(ref.read(authPrefsStoreProvider).clear());
  }
}

/// 冷启动的**首屏落点**（纯函数，便于锁定）。
///
/// ## 两条在途路径（2026-10-19 起）
/// - `autoLoginInFlight`：勾了「自动登录」⇒ 用户口径是「到登录页、**看见**它自动登录」
///   ⇒ 首屏**必须**是 `/login`，不能静默跳过登录页；
/// - `sessionRestoreInFlight`：静默续期 ⇒ 用户本来就没打算看登录页
///   ⇒ 首屏同样落 `/login`（中途成功由守卫换成 `/group`），但登录页会显示启动态
///   而**不渲染表单**（见 `pages/login_route.dart` 的 `_restoring` 档），避免表单闪一下。
///
/// ## 为什么不落 `/group` 再重定向
/// 落 `/group` ⇒ 守卫立刻判定「未登录」⇒ 跳到 `/login?next=/group` ⇒ 续期成功后又跳回
/// `/group`。用户会看到一次完整的登录页闪现 + 地址栏式跳转，比现在直接停在启动态差。
/// 而落 `/login` 时守卫本就不会再重定向（已是公开页），续期成功后由 `refreshListenable`
/// 触发一次 `redirect` 换成 `/group`，干净。
String aylaInitialLocation({
  required bool autoLoginInFlight,
  bool sessionRestoreInFlight = false,
}) =>
    autoLoginInFlight || sessionRestoreInFlight ? '/login' : '/group';

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

/// **冷启动会话引导链**（2026-10-19 新增，`main.dart` 唯一调用点）。
///
/// ## 为什么要有这一层
/// 之前只有 [aylaRunAutoLogin] 一条路，两条路径各自有单飞位、各自发请求，
/// 并行调用会变成「refresh 与 login 同时打」，产生重复的登录副作用链。
/// 这里把优先级串行化，语义与 web 一致：**先静默续期，失败才轮到显式登录**。
///
/// ## 顺序与时序（逐条对齐 web `main.tsx:30–45`）
/// 1. `restoreSession()`：有 refresh ⇒ 续期 + 拉 `/me/` + 建连（web 同）；
/// 2. 续期不可用（没令牌 / 已过期）⇒ 若用户勾了「自动登录」，重放 `/auth/login/`；
/// 3. 两条都不成 ⇒ 停在登录页（不报错弹窗：冷启动没登录是正常状态，不是故障）。
///
/// ## 与 web 的差异（登记，有意）
/// web 的 `restoreSession` 失败会 `logout()` 并停在登录页；Flutter 额外多一条
/// 「自动登录」分支 —— 这是用户 2026-10-01 明确要求的增量功能（web 无对应），
/// 因此本函数是 web 那条链的**超集**，不是取代。
Future<void> aylaBootstrapSession(ProviderContainer container) async {
  final AylaSessionRestoreOutcome restored =
      await aylaRestoreSession(container);
  if (restored == AylaSessionRestoreOutcome.success ||
      restored == AylaSessionRestoreOutcome.alreadySignedIn) {
    // 静默续期已把人送回应用 ⇒ **不再**跑自动登录（避免第二次登录链）。
    // 但仍要让登录页的「自动登录中…」档位落回 false（它没被触发过，本就是 false）。
    return;
  }
  // 走到这里 = 没有可用会话（noToken / failed）⇒ 尝试用户勾选的自动登录。
  // [aylaRunAutoLogin] 内部会自行判定「没勾 ⇒ skipped」，不需要这里再读一遍偏好。
  final AylaAutoLoginOutcome outcome = await aylaRunAutoLogin(container);
  debugPrint('[AylaAuth] 冷启动引导完成：restore=$restored autoLogin=$outcome');
}
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

/// 会话恢复结果（调用方据此决定提示与首屏落点）。
enum AylaSessionRestoreOutcome {
  /// 没有存过 refresh 令牌 ⇒ 未登录，正常走登录页。
  noToken,

  /// 已有有效会话（本进程内已登录）⇒ 不重复恢复。
  alreadySignedIn,

  /// refresh 续期成功 + `GET /me/` 成功 ⇒ 直接进应用。
  success,

  /// refresh 过期 / 被吊销 / 网络失败 ⇒ 清掉存的那串，回登录页。
  failed,
}

/// **冷启动会话恢复**（web `main.tsx:36` 的 `restoreSession()` 等价物，2026-10-19 新增）。
///
/// ## 要解决的问题
/// 用户实报「手机端切后台重登」：Android 在内存紧张时会杀掉进程，回到前台是**冷启动**；
/// 而 Flutter 侧此前只有 `aylaRunAutoLogin`（用**明文口令**重放 `/auth/login/`），
/// 没勾「自动登录」的用户就会被踢回登录页 —— 哪怕 refresh 令牌还完全有效。
///
/// ## 与自动登录的分工（两条路径，按用户开关分流）
/// - 勾了「自动登录」⇒ [aylaRunAutoLogin]（可见地重放登录，用户当场看见它在登）；
/// - 没勾 / 自动登录不可用但存了 refresh ⇒ **本函数**静默续期，静默进应用。
/// 两者都能覆盖「切后台被回收」；区别只是要不要让用户看见过程。
///
/// ## 与 web 的差异（登记）
/// web 存 `sessionStorage`（关标签页失效），Flutter 存平台安全存储、跨进程存活 ——
/// 原生 App 用户对「切回来还在」的预期强于网页，这是有意的语义加强。
///
/// ## 失败语义（工程纪律：失败必须可观测、不得伪装成功）
/// - refresh 无效 / 网络失败 ⇒ 清掉已存令牌（避免每次启动都拿一串死令牌重试），
///   返回 [AylaSessionRestoreOutcome.failed]，由路由守卫把人送回登录页；
/// - **不删除**「记住密码 / 自动登录」那 4 个键：那是用户偏好，与令牌无关。
Future<AylaSessionRestoreOutcome> aylaRestoreSession(
  ProviderContainer container,
) async {
  final AuthNotifier auth = container.read(authNotifierProvider.notifier);
  if (container.read(authNotifierProvider).isAuthenticated) {
    return AylaSessionRestoreOutcome.alreadySignedIn;
  }
  final AylaSessionTokenStore tokens =
      container.read(sessionTokenStoreProvider);
  // 读存储没有网络往返，很快；但「有令牌」才置在途位 —— 没令牌时首屏直接落登录页，
  // 不该让用户多看一眼启动态。
  final String? refresh = await tokens.read();
  if (refresh == null || refresh.isEmpty) {
    return AylaSessionRestoreOutcome.noToken;
  }
  // 从这里开始是真实网络往返 ⇒ 置在途位（首屏据此显示启动态而非登录表单）。
  aylaSessionRestoreInFlight.value = true;
  try {
    return await _restoreSessionWithToken(container, auth, tokens, refresh);
  } finally {
    // ⚠️ 必须复位：这条位跨 `main`/widget 两侧、且只在「有令牌」时被置真 ——
    // 漏复位会让首屏永远停在启动态（用户看到无限转圈）。用 finally 保证
    // 成功、失败、异常三条路径都复位。
    aylaSessionRestoreInFlight.value = false;
  }
}

/// 续期 + 拉用户 + 建连的实际实现（由 [aylaRestoreSession] 在置好在途位后调用）。
///
/// 拆出来只为让上面的 `try/finally` 干净：成功/失败的所有分支都在本函数内返回，
/// 在途位由调用方统一复位，不需要在每个 `return` 前重复写一遍（容易漏）。
Future<AylaSessionRestoreOutcome> _restoreSessionWithToken(
  ProviderContainer container,
  AuthNotifier auth,
  AylaSessionTokenStore tokens,
  String refresh,
) async {
  // ⚠️ 先把 refresh 交给 DioClient 的令牌存取器：
  // `refreshAccessToken()` 只认 `AuthTokenStore.refreshToken`（见 `core/net/dio_client.dart:184`）。
  // 恢复阶段的 access 是空的，这里只写 refresh（access 由续期结果填）。
  auth.setTokens('', refresh);
  try {
    final bool ok = await DioClient.instance.refreshAccessToken();
    if (!ok) {
      debugPrint('[AylaAuth] 会话恢复失败：refresh 续期被拒绝');
      await tokens.clear();
      auth.clear();
      return AylaSessionRestoreOutcome.failed;
    }
    final AuthState afterRefresh = container.read(authNotifierProvider);
    final String? access = afterRefresh.accessToken;
    final String? rotated = afterRefresh.refreshToken;
    if (access == null || access.isEmpty) {
      await tokens.clear();
      auth.clear();
      return AylaSessionRestoreOutcome.failed;
    }
    // ROTATE_REFRESH_TOKENS=True ⇒ refresh 会轮换，必须把新的那串写回存储，
    // 否则下次启动拿旧（已作废）令牌 ⇒ 必然 401（web `stores/auth.ts:113` 同款注释）。
    if (rotated != null && rotated.isNotEmpty && rotated != refresh) {
      await tokens.write(rotated);
    }
    // 拉当前用户（与登录链同一步：`?next=` 回跳与路由守卫都依赖 user 落地）。
    final AuthUser me = await AuthApi.me(accessToken: access);
    auth.setUser(me);
    // 与手动登录**完全相同**的副作用链（WS / 预加载门 / 未读 / 更新检查）。
    // ⚠️ attach 必须先于 connectAll（同 [aylaApplyLoginSession] 的说明）：
    // 建连帧（`presence.self` / `presence.update(online)`）在 accept 后立刻下发，
    // 若 `onEvent` 还没接上就会被静默丢弃 ⇒ 自己的 presence 记录永远缺失。
    _startChatWs(container);
    _startPresenceWs(container);
    wsManager?.connectAll();
    unawaited(container.read(badgesProvider).fetch());
    unawaited(AppInit.instance.run(userId: me.id));
    return AylaSessionRestoreOutcome.success;
  } catch (err) {
    debugPrint('[AylaAuth] 会话恢复失败：$err');
    await tokens.clear();
    auth.clear();
    return AylaSessionRestoreOutcome.failed;
  }
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
