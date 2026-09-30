/// 路由表 —— web `src/App.tsx` 98 行的等价物（go_router）。
///
/// ## 结构（与 App.tsx 逐条对应）
/// · **公开路由**：`/login`、`/register`（`App.tsx:57–58`）；
/// · **受保护路由**：其余全部挂在 [AppShell] 的 `ShellRoute` 下
///   （= web 的 `<Route element={<ProtectedRoute><AppShell/></ProtectedRoute>}>`，`App.tsx:60–92`）；
/// · **重定向**：`/` 与 `/home` → `/group`（`App.tsx:67/69`）；
/// · **catch-all**：`*` → `/group`（`App.tsx:94`）。
///
/// ## 守卫（`components/ProtectedRoute.tsx` 的等价物）
/// web 是**组件**（无 token ⇒ `<Navigate to="/login" replace />`）；go_router 用顶层 `redirect`
/// 表达同一语义（无 token 且访问非公开路由 ⇒ 去 `/login`）。
/// ⚠️ **有意偏离（用户指示）**：web 的守卫与登录成功都**不带**回跳（`LoginPage.tsx:19/28` 恒
/// `navigate("/group")`）；Flutter 侧把原目标编码进 `?next=` 并在登录后回原地（见 [LoginRoute]）。
///
/// ## 实现差异（登记）
/// · **声明顺序敏感**：go_router 按声明顺序匹配，React Router 6 按具体度自动排序 ⇒
///   `/posts/mine` **必须**排在 `/posts/:postId` 之前（否则 `mine` 被当成 postId）。
///   其余同级路径段数不同，天然不冲突（已在下方注释标注）。
/// · **未实现页面**：第 1 批只交付 Register / Profile / UserProfile / Favorites / Search + 登录接线；
///   其余路由指向 [PendingPage]（显式登记，不静默重定向）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../layout/app_shell.dart';
import '../pages/chat_conversation_route.dart';
import '../pages/favorites_page.dart';
import '../pages/games_hub_page.dart';
import '../pages/group_page.dart';
import '../pages/messages_page.dart';
import '../pages/home_page.dart';
import '../pages/my_posts_page.dart';
import '../pages/live_hub_page.dart';
import '../pages/live_room_page.dart';
import '../pages/live_studio_page.dart';
import '../pages/login_route.dart';
import '../pages/post_detail_page.dart';
import '../pages/posts_hub_page.dart';
import '../pages/profile_page.dart';
import '../pages/register_page.dart';
import '../pages/search_page.dart';
import '../pages/user_profile_page.dart';
import '../pages/voice_hub_page.dart';
import '../state/auth_state.dart';
import '../theme/page_transitions.dart' show aylaIsTransitionFreePath;
import 'shell_config.dart' show aylaIsGroupScene, aylaPanelOwnedPath;

/// 认证状态变化 → `GoRouter` 重算守卫的桥（[GoRouter.refreshListenable]）。
class _AuthRefresh extends ChangeNotifier {
  void bump() => notifyListeners();
}

// ⚠️ 占位页辅助函数 `_pending` 已于第六批删除：五条 `/group/*` 路由都换成了真实页面
// （`GroupPage`），库内再无占位路由。`pages/pending_page.dart` 保留 —— 它是
// 「未实现页面」的显式登记件，供后续新增路由时复用（不静默重定向）。

/// 与 web 一致的**页面容器选择**（`AppShell.tsx:61–74` 的 `panelOwned` 分档）。
///
/// ## 为什么这条决定同时是「性能」与「与 web 一致」（2026-09-30 实机第六轮）
/// 用户实报：「**刷新反而不卡，是在语音、直播、帖子、桌游选项卡之间切换才卡**」。
/// 根因：`MaterialPage` 的 `transitionDuration` 是 300ms，这段时间**旧页仍挂在 Navigator
/// 上并继续渲染** ⇒ 切选项卡时**两页各 20 张玻璃卡同时在场**（每帧 40 次 backdrop 模糊 +
/// 两页的整棵树）。而 web 的 panelOwned 路由（`/voice` `/live` `/posts` `/games` …）是
/// **整页不动画**（`initial` 即终值、`transition.duration = 0`）⇒ **旧页立即卸载**、只剩一页。
///
/// ## 分档
/// - `aylaPanelOwnedPath`（绝大多数路由）⇒ [NoTransitionPage]（`transitionDuration` 为零）
///   ⇒ 旧页在切换那一帧就卸载 = web 语义（**也是唯一能避免「两页并存」的手段**：
///   `maintainState: false` 不够 —— 它在转场期间仍保留旧页）；
/// - 其余（`/group`、`/posts/mine` 等 web 播整页转场的）⇒ `MaterialPage`
///   + `AylaPageTransitionsBuilder` 的分档（新旧页并存、各播各的 = `AnimatePresence mode="sync"`）。
/// 群页 5 条路由**共用的 Page key**（见 [aylaRoutePage] 的注释）。
///
/// 目的：切场景（/group/:id ↔ /group/:id/:scene ↔ .../posts/:postId …）时**不重建整页**
/// —— 与 web「5 条 Route 的 element 都是同一个 GroupPage 组件，React 复用」等价。
/// 换群（/group/a → /group/b）同样复用（web 也是），群级面板的重播由面板自己的
/// key: groupId 负责（channel_sidebar.dart:576）。
const LocalKey kAylaGroupShellPageKey = ValueKey<String>('ayla-group-shell-page');

Page<void> aylaRoutePage({
  required GoRouterState state,
  required Widget child,
}) {
  // ⚠️ **不要按「路径字符串精确匹配」收窄**（2026-10-01 试过一次，被群页测试挡回）：
  // 群页的**切群**（`/group/:id` 之间）与**切场景**（`/group/:id/:scene`）**本来就依赖
  // 零时长** —— `group_page_shell_test` 的「切群：第二列新面板必须播入场」
  // 与「群级目录桶复用、不重拉」两条正是这个语义（面板自编排、路由层不动画）。
  // ⇒ 判定一律走 `aylaPanelOwnedPath`（它已覆盖群场景 / 消息中心 / 详情页 / 四大厅…）。
  // ⚠️ **群页 5 条路由共用同一个 Page key**（2026-10-01 用户实机三条反馈：
  // 「点击第二列选项卡时左侧群头像选项卡选中高亮不应该闪一下」「点击第二列选项卡内容时
  // 不应该重载第二列侧栏」「目前的状态就像每次点击都在跳转，而没有实现 web 那种第一列第二列
  // 作为该页面的选项卡丝滑切换」）。
  //
  // web 事实源：App.tsx:86–90 的 5 条 /group/* Route **element 全是同一个 GroupPage 组件**
  // ⇒ 路径变化时 React 按类型复用同一实例 ⇒ **组件不卸载**，只是 useParams 更新
  // ⇒ 第一列/第二列**不重建**（高亮不闪、侧栏不重载）。
  // Flutter 侧此前用 state.pageKey（含路径）⇒ 切场景 = **换 Page = 整页重建** ⇒ 就是用户
  // 看到的「每次点击都在跳转」。共用一个 key 后，Navigator 的 Page.canUpdate 判定为
  // 「同一个 Page」⇒ **复用 route、保留 Element/State**，只更新 child（场景参数）。
  final LocalKey pageKey = aylaIsGroupScene(state.uri.path)
      ? kAylaGroupShellPageKey
      // go_router 的 state.pageKey 声明为 Key（非 LocalKey），这里按路径自建等价 key。
      : ValueKey<String>(state.uri.path);
  if (aylaPanelOwnedPath(state.uri.path) ||
      aylaIsTransitionFreePath(state.uri.path)) {
    return NoTransitionPage<void>(key: pageKey, child: child);
  }
  return MaterialPage<void>(key: pageKey, child: child);
}

/// 全局路由（唯一实例；会话过期回登录、页面内 `context.go` 都由它承载）。
final Provider<GoRouter> appRouterProvider = Provider<GoRouter>((Ref ref) {
  final _AuthRefresh refresh = _AuthRefresh();
  ref.listen<AuthState>(authNotifierProvider, (
    AuthState? prev,
    AuthState next,
  ) {
    // 只在「登录态翻转」时重算（令牌刷新等同态变化不触发路由重定向）。
    if ((prev?.isAuthenticated ?? false) != next.isAuthenticated) {
      refresh.bump();
    }
  });
  ref.onDispose(refresh.dispose);

  final GoRouter router = GoRouter(
    initialLocation: '/group',
    refreshListenable: refresh,
    redirect: (BuildContext context, GoRouterState state) {
      final bool loggedIn = ref.read(authNotifierProvider).isAuthenticated;
      final String path = state.uri.path;
      final bool isPublic = path == '/login' || path == '/register';
      if (!loggedIn && !isPublic) {
        return '/login?next=${Uri.encodeComponent(state.uri.toString())}';
      }
      if (loggedIn && isPublic) {
        final String? next = state.uri.queryParameters['next'];
        if (next != null &&
            next.startsWith('/') &&
            !next.startsWith('/login') &&
            !next.startsWith('/register')) {
          return next;
        }
        return '/group';
      }
      return null;
    },
    routes: <RouteBase>[
      // ---- 公开（`App.tsx:57–58`）----
      // ⚠️ **2026-09-30 裁决反转**（用户：「切换页面时上一个页面不是立刻完全消失的」）：
      // 改用 `MaterialPage`（`transitionDuration` 300ms）⇒ 新旧页在过渡期间**并存**
      //（= web `AnimatePresence mode="sync"` 的语义）：旧页淡出、新页淡入。
      // 2026-09-28 曾因「登录页与注册页叠在一起」而全部改为 `NoTransitionPage` —— 那个
      // 问题由 `AylaPageTransitionsBuilder` 的**分档**解决：`/login` `/register` 属
      // **无转场档**（web `App.tsx:57–58` 的两个顶层 Route 本来就没有过渡），
      // 其余页面才走交叉过渡。
      GoRoute(
        path: '/login',
        pageBuilder: (BuildContext context, GoRouterState state) =>
            aylaRoutePage(
              state: state,
              child: LoginRoute(next: state.uri.queryParameters['next']),
            ),
      ),
      GoRoute(
        path: '/register',
        pageBuilder: (BuildContext context, GoRouterState state) =>
            aylaRoutePage(state: state, child: RegisterPage()),
      ),
      // ---- 受保护（`App.tsx:60–92`，壳层由 AppShell 承担）----
      ShellRoute(
        builder: (BuildContext context, GoRouterState state, Widget child) =>
            AppShell(child: child),
        routes: <RouteBase>[
          GoRoute(
            path: '/',
            redirect: (BuildContext c, GoRouterState s) => '/group',
          ),
          // 第 3 批：主页（窄屏群卡片/列表双形态；宽屏 = 重定向到最近群
          // ⇒ /group/:id，见 HomePage 文件头的机制差异 1）
          GoRoute(
            path: '/group',
            pageBuilder: (BuildContext c, GoRouterState s) =>
                aylaRoutePage(state: s, child: HomePage()),
          ),
          GoRoute(
            path: '/home',
            redirect: (BuildContext c, GoRouterState s) => '/group',
          ),
          // 第二批：大厅已交付（房内态属第 3 批 —— 见各页文件头的「机制差异」登记）
          GoRoute(
            path: '/voice',
            pageBuilder: (BuildContext c, GoRouterState s) => aylaRoutePage(
              state: s,
              child: VoiceHubPage(initialType: s.uri.queryParameters['type']),
            ),
          ),
          // ⚠️ 与 `/voice` **同一个组件**（web `App.tsx:70–71`），由 `channelId` 分支渲染；
          // 房内宿主按 channelId 重建 ⇒ 切房即重建会话（web `lastJoinRouteRef` 的等价物）。
          GoRoute(
            path: '/voice/:channelId',
            pageBuilder: (BuildContext c, GoRouterState s) => aylaRoutePage(
              state: s,
              child: VoiceHubPage(channelId: s.pathParameters['channelId']),
            ),
          ),
          GoRoute(
            path: '/live',
            pageBuilder: (BuildContext c, GoRouterState s) => aylaRoutePage(
              state: s,
              child: LiveHubPage(initialType: s.uri.queryParameters['type']),
            ),
          ),
          // ⚠️ 段数不同（3 vs 2），与 `/live/:channelId` 不冲突
          GoRoute(
            path: '/live/start/:channelId',
            pageBuilder: (BuildContext c, GoRouterState s) => aylaRoutePage(
              state: s,
              child: LiveStudioPage(
                channelId: s.pathParameters['channelId'] ?? '',
              ),
            ),
          ),
          GoRoute(
            path: '/live/:channelId',
            pageBuilder: (BuildContext c, GoRouterState s) => aylaRoutePage(
              state: s,
              child: LiveRoomPage(
                channelId: s.pathParameters['channelId'] ?? '',
              ),
            ),
          ),
          // 第 3 批：帖子域（一级 tab + 我的 + 他人 + 详情）
          GoRoute(
            path: '/posts',
            pageBuilder: (BuildContext c, GoRouterState s) => aylaRoutePage(
              state: s,
              child: PostsHubPage(initialType: s.uri.queryParameters['type']),
            ),
          ),
          // ⚠️ **必须排在 `/posts/:postId` 之前**（同为 2 段，go_router 按声明顺序匹配）
          GoRoute(
            path: '/posts/mine',
            pageBuilder: (BuildContext c, GoRouterState s) =>
                aylaRoutePage(state: s, child: MyPostsPage()),
          ),
          GoRoute(
            path: '/posts/:postId',
            pageBuilder: (BuildContext c, GoRouterState s) => aylaRoutePage(
              state: s,
              child: PostDetailPage(
                postId: s.pathParameters['postId'] ?? '',
                from: s.uri.queryParameters['from'],
              ),
            ),
          ),
          GoRoute(
            path: '/games',
            pageBuilder: (BuildContext c, GoRouterState s) => aylaRoutePage(
              state: s,
              child: GamesHubPage(initialType: s.uri.queryParameters['type']),
            ),
          ),
          // 房内占位：与 `/games` 同一组件（web `App.tsx:78–79`），由 roomId 分支渲染。
          GoRoute(
            path: '/games/:roomId',
            pageBuilder: (BuildContext c, GoRouterState s) => aylaRoutePage(
              state: s,
              child: GamesHubPage(roomId: s.pathParameters['roomId']),
            ),
          ),
          // 第 4 批：消息域（窄屏三 tab / 宽屏两列）
          GoRoute(
            path: '/messages',
            pageBuilder: (BuildContext c, GoRouterState s) =>
                aylaRoutePage(state: s, child: MessagesPage()),
          ),
          GoRoute(
            path: '/search',
            // ?q= 是搜索的驱动源（web SearchPage.tsx:297–324）；
            // ?type= 为分类选项卡（同页 URL 同步）
            pageBuilder: (BuildContext c, GoRouterState s) => aylaRoutePage(
              state: s,
              child: SearchPage(
                initialQuery: s.uri.queryParameters['q'],
                initialType: s.uri.queryParameters['type'],
              ),
            ),
          ),
          GoRoute(
            path: '/profile',
            // 同上：无转场页（时长 0）。页面自己的入场动画（两列 `AylaRevealItem`）不受影响。
            pageBuilder: (BuildContext c, GoRouterState s) =>
                aylaRoutePage(state: s, child: ProfilePage()),
          ),
          GoRoute(
            path: '/user/:userId',
            pageBuilder: (BuildContext c, GoRouterState s) => aylaRoutePage(
              state: s,
              child: UserProfilePage(userId: s.pathParameters['userId'] ?? ''),
            ),
          ),
          // ⚠️ 3 段 vs `/user/:userId` 的 2 段，天然不冲突
          GoRoute(
            path: '/user/:userId/posts',
            pageBuilder: (BuildContext c, GoRouterState s) => aylaRoutePage(
              state: s,
              child: UserPostsPage(userId: s.pathParameters['userId'] ?? ''),
            ),
          ),
          GoRoute(
            path: '/favorites',
            pageBuilder: (BuildContext c, GoRouterState s) => aylaRoutePage(
              state: s,
              child: FavoritesPage(initialType: s.uri.queryParameters['type']),
            ),
          ),
          // 第 6 批：群聊场景容器（web `App.tsx:86–90` 五条路由都指向同一个 GroupPage，
          // 由 route param 决定场景）。⚠️ 声明顺序：三条带具体尾段的必须在
          // `/group/:id/:scene` **之前**，否则 `posts` / `voice` / `live` 会被当成 scene 吃掉。
          //
          // ⚠️ **五条都不得加 `key: ValueKey(id)`**（2026-09-29 用户实报「切群整个界面重新加载」后移除）：
          // 它们共用不带 key 的 `NoTransitionPage` ⇒ Navigator 的 `Page.canUpdate`（runtimeType + key）
          // 为真 ⇒ 原地 update 同一条 route、保留同一棵 Element 树。加 ValueKey 等于换新 route，
          // GroupPage 的 State 连同 ServerRail / ChannelSidebar 整棵重建、四条分页状态重新拉取。
          // web 只有**一个** GroupPage 实例、只换 route param：`ServerRail` 常驻；`ChannelSidebar`
          // 走 `AnimatePresence mode="wait"` 换面板；内容区由 `ConversationTransition
          // identity="group:<id>"` 编排（`GroupPage.tsx:405–436`）。切群的数据换新落在
          // `_GroupPageState.didUpdateWidget`（等价 tsx 229–245 的 effect）。
          GoRoute(
            path: '/group/:id',
            pageBuilder: (BuildContext c, GoRouterState s) => aylaRoutePage(
              state: s,
              child: GroupPage(groupId: s.pathParameters['id'] ?? ''),
            ),
          ),
          GoRoute(
            path: '/group/:id/posts/:postId',
            pageBuilder: (BuildContext c, GoRouterState s) => aylaRoutePage(
              state: s,
              child: GroupPage(
                groupId: s.pathParameters['id'] ?? '',
                postId: s.pathParameters['postId'],
              ),
            ),
          ),
          GoRoute(
            path: '/group/:id/voice/:voiceChannelId',
            pageBuilder: (BuildContext c, GoRouterState s) => aylaRoutePage(
              state: s,
              child: GroupPage(
                groupId: s.pathParameters['id'] ?? '',
                voiceChannelId: s.pathParameters['voiceChannelId'],
              ),
            ),
          ),
          GoRoute(
            path: '/group/:id/live/:liveChannelId',
            pageBuilder: (BuildContext c, GoRouterState s) => aylaRoutePage(
              state: s,
              child: GroupPage(
                groupId: s.pathParameters['id'] ?? '',
                liveChannelId: s.pathParameters['liveChannelId'],
              ),
            ),
          ),
          GoRoute(
            path: '/group/:id/:scene',
            pageBuilder: (BuildContext c, GoRouterState s) => aylaRoutePage(
              state: s,
              child: GroupPage(
                groupId: s.pathParameters['id'] ?? '',
                scene: s.pathParameters['scene'],
              ),
            ),
          ),
          // 第 4 批：会话路由适配（群聊 → /group/:id；私聊 → PrivateChatPage）。
          // `?msg=&seq=` 是收藏消息的定位参数（web `PrivateChatPage.tsx:28–38`）。
          GoRoute(
            path: '/chat/:conversationId',
            pageBuilder: (BuildContext c, GoRouterState s) => aylaRoutePage(
              state: s,
              child: ChatConversationRoute(
                conversationId: s.pathParameters['conversationId'] ?? '',
                query: s.uri.query.isEmpty ? '' : '?${s.uri.query}',
                jumpMessageId: s.uri.queryParameters['msg'],
                jumpSeq: int.tryParse(s.uri.queryParameters['seq'] ?? ''),
              ),
            ),
          ),
        ],
      ),
      // ---- catch-all（`App.tsx:94`）----
      GoRoute(
        path: '/:pathMatch(.*)',
        redirect: (BuildContext context, GoRouterState state) => '/group',
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
