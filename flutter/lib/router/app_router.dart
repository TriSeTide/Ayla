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

/// 认证状态变化 → `GoRouter` 重算守卫的桥（[GoRouter.refreshListenable]）。
class _AuthRefresh extends ChangeNotifier {
  void bump() => notifyListeners();
}

// ⚠️ 占位页辅助函数 `_pending` 已于第六批删除：五条 `/group/*` 路由都换成了真实页面
// （`GroupPage`），库内再无占位路由。`pages/pending_page.dart` 保留 —— 它是
// 「未实现页面」的显式登记件，供后续新增路由时复用（不静默重定向）。

/// 全局路由（唯一实例；会话过期回登录、页面内 `context.go` 都由它承载）。
final Provider<GoRouter> appRouterProvider = Provider<GoRouter>((Ref ref) {
  final _AuthRefresh refresh = _AuthRefresh();
  ref.listen<AuthState>(authNotifierProvider, (AuthState? prev, AuthState next) {
    // 只在「登录态翻转」时重算（令牌刷新等同态变化不触发路由重定向）。
    if ((prev?.isAuthenticated ?? false) != next.isAuthenticated) refresh.bump();
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
      // ⚠️ 全部用 `NoTransitionPage`（**不是** `builder:`）：`PageTransitionsBuilder` 只改
      // **视觉**，route 的 `transitionDuration` 仍是 300ms ⇒ 旧 route 依然在栈上
      // ⇒ 两页同屏（2026-09-28 用户截图：登录页与注册页叠在一起）。
      // `NoTransitionPage` 的时长是 **0**，这才是「不叠页」的正解。
      GoRoute(
        path: '/login',
        pageBuilder: (BuildContext context, GoRouterState state) =>
            NoTransitionPage<void>(
          child: LoginRoute(next: state.uri.queryParameters['next']),
        ),
      ),
      GoRoute(
        path: '/register',
        pageBuilder: (BuildContext context, GoRouterState state) =>
            const NoTransitionPage<void>(child: RegisterPage()),
      ),
      // ---- 受保护（`App.tsx:60–92`，壳层由 AppShell 承担）----
      ShellRoute(
        builder: (BuildContext context, GoRouterState state, Widget child) =>
            AppShell(child: child),
        routes: <RouteBase>[
          GoRoute(path: '/', redirect: (BuildContext c, GoRouterState s) => '/group'),
          // 第 3 批：主页（窄屏群卡片/列表双形态；宽屏 = 重定向到最近群
          // ⇒ /group/:id，见 HomePage 文件头的机制差异 1）
          GoRoute(
            path: '/group',
            pageBuilder: (BuildContext c, GoRouterState s) =>
                const NoTransitionPage<void>(child: HomePage()),
          ),
          GoRoute(
            path: '/home',
            redirect: (BuildContext c, GoRouterState s) => '/group',
          ),
          // 第二批：大厅已交付（房内态属第 3 批 —— 见各页文件头的「机制差异」登记）
          GoRoute(
            path: '/voice',
            pageBuilder: (BuildContext c, GoRouterState s) => NoTransitionPage<void>(
              child: VoiceHubPage(initialType: s.uri.queryParameters['type']),
            ),
          ),
          // ⚠️ 与 `/voice` **同一个组件**（web `App.tsx:70–71`），由 `channelId` 分支渲染；
          // 房内宿主按 channelId 重建 ⇒ 切房即重建会话（web `lastJoinRouteRef` 的等价物）。
          GoRoute(
            path: '/voice/:channelId',
            pageBuilder: (BuildContext c, GoRouterState s) =>
                NoTransitionPage<void>(
              child: VoiceHubPage(
                channelId: s.pathParameters['channelId'],
              ),
            ),
          ),
          GoRoute(
            path: '/live',
            pageBuilder: (BuildContext c, GoRouterState s) => NoTransitionPage<void>(
              child: LiveHubPage(initialType: s.uri.queryParameters['type']),
            ),
          ),
          // ⚠️ 段数不同（3 vs 2），与 `/live/:channelId` 不冲突
          GoRoute(
            path: '/live/start/:channelId',
            pageBuilder: (BuildContext c, GoRouterState s) =>
                NoTransitionPage<void>(
              child: LiveStudioPage(
                channelId: s.pathParameters['channelId'] ?? '',
              ),
            ),
          ),
          GoRoute(
            path: '/live/:channelId',
            pageBuilder: (BuildContext c, GoRouterState s) =>
                NoTransitionPage<void>(
              child: LiveRoomPage(
                channelId: s.pathParameters['channelId'] ?? '',
              ),
            ),
          ),
          // 第 3 批：帖子域（一级 tab + 我的 + 他人 + 详情）
          GoRoute(
            path: '/posts',
            pageBuilder: (BuildContext c, GoRouterState s) =>
                NoTransitionPage<void>(
              child: PostsHubPage(initialType: s.uri.queryParameters['type']),
            ),
          ),
          // ⚠️ **必须排在 `/posts/:postId` 之前**（同为 2 段，go_router 按声明顺序匹配）
          GoRoute(
            path: '/posts/mine',
            pageBuilder: (BuildContext c, GoRouterState s) =>
                const NoTransitionPage<void>(child: MyPostsPage()),
          ),
          GoRoute(
            path: '/posts/:postId',
            pageBuilder: (BuildContext c, GoRouterState s) =>
                NoTransitionPage<void>(
              child: PostDetailPage(
                postId: s.pathParameters['postId'] ?? '',
                from: s.uri.queryParameters['from'],
              ),
            ),
          ),
          GoRoute(
            path: '/games',
            pageBuilder: (BuildContext c, GoRouterState s) => NoTransitionPage<void>(
              child: GamesHubPage(initialType: s.uri.queryParameters['type']),
            ),
          ),
          // 房内占位：与 `/games` 同一组件（web `App.tsx:78–79`），由 roomId 分支渲染。
          GoRoute(
            path: '/games/:roomId',
            pageBuilder: (BuildContext c, GoRouterState s) =>
                NoTransitionPage<void>(
              child: GamesHubPage(roomId: s.pathParameters['roomId']),
            ),
          ),
          // 第 4 批：消息域（窄屏三 tab / 宽屏两列）
          GoRoute(
            path: '/messages',
            pageBuilder: (BuildContext c, GoRouterState s) =>
                const NoTransitionPage<void>(child: MessagesPage()),
          ),
          GoRoute(
            path: '/search',
            // ?q= 是搜索的驱动源（web SearchPage.tsx:297–324）；
            // ?type= 为分类选项卡（同页 URL 同步）
            pageBuilder: (BuildContext c, GoRouterState s) => NoTransitionPage<void>(
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
                const NoTransitionPage<void>(child: ProfilePage()),
          ),
          GoRoute(
            path: '/user/:userId',
            pageBuilder: (BuildContext c, GoRouterState s) =>
                NoTransitionPage<void>(
              child: UserProfilePage(userId: s.pathParameters['userId'] ?? ''),
            ),
          ),
          // ⚠️ 3 段 vs `/user/:userId` 的 2 段，天然不冲突
          GoRoute(
            path: '/user/:userId/posts',
            pageBuilder: (BuildContext c, GoRouterState s) =>
                NoTransitionPage<void>(
              child: UserPostsPage(userId: s.pathParameters['userId'] ?? ''),
            ),
          ),
          GoRoute(
            path: '/favorites',
            pageBuilder: (BuildContext c, GoRouterState s) => NoTransitionPage<void>(
              child: FavoritesPage(initialType: s.uri.queryParameters['type']),
            ),
          ),
          // 第 6 批：群聊场景容器（web `App.tsx:86–90` 五条路由都指向同一个 GroupPage，
          // 由 route param 决定场景）。⚠️ 声明顺序：三条带具体尾段的必须在
          // `/group/:id/:scene` **之前**，否则 `posts` / `voice` / `live` 会被当成 scene 吃掉。
          // `key: ValueKey(id)` —— 切群时整页重建（目录/子群/语音/直播四条分页状态一起换新；
          // web 用 effect 重跑表达同一语义）。
          GoRoute(
            path: '/group/:id',
            pageBuilder: (BuildContext c, GoRouterState s) => NoTransitionPage<void>(
              child: GroupPage(
                key: ValueKey<String>(s.pathParameters['id'] ?? ''),
                groupId: s.pathParameters['id'] ?? '',
              ),
            ),
          ),
          GoRoute(
            path: '/group/:id/posts/:postId',
            pageBuilder: (BuildContext c, GoRouterState s) => NoTransitionPage<void>(
              child: GroupPage(
                key: ValueKey<String>(s.pathParameters['id'] ?? ''),
                groupId: s.pathParameters['id'] ?? '',
                postId: s.pathParameters['postId'],
              ),
            ),
          ),
          GoRoute(
            path: '/group/:id/voice/:voiceChannelId',
            pageBuilder: (BuildContext c, GoRouterState s) => NoTransitionPage<void>(
              child: GroupPage(
                key: ValueKey<String>(s.pathParameters['id'] ?? ''),
                groupId: s.pathParameters['id'] ?? '',
                voiceChannelId: s.pathParameters['voiceChannelId'],
              ),
            ),
          ),
          GoRoute(
            path: '/group/:id/live/:liveChannelId',
            pageBuilder: (BuildContext c, GoRouterState s) => NoTransitionPage<void>(
              child: GroupPage(
                key: ValueKey<String>(s.pathParameters['id'] ?? ''),
                groupId: s.pathParameters['id'] ?? '',
                liveChannelId: s.pathParameters['liveChannelId'],
              ),
            ),
          ),
          GoRoute(
            path: '/group/:id/:scene',
            pageBuilder: (BuildContext c, GoRouterState s) => NoTransitionPage<void>(
              child: GroupPage(
                key: ValueKey<String>(s.pathParameters['id'] ?? ''),
                groupId: s.pathParameters['id'] ?? '',
                scene: s.pathParameters['scene'],
              ),
            ),
          ),
          // 第 4 批：会话路由适配（群聊 → /group/:id；私聊 → PrivateChatPage）。
          // `?msg=&seq=` 是收藏消息的定位参数（web `PrivateChatPage.tsx:28–38`）。
          GoRoute(
            path: '/chat/:conversationId',
            pageBuilder: (BuildContext c, GoRouterState s) =>
                NoTransitionPage<void>(
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