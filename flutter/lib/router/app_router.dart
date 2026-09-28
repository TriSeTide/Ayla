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
import '../pages/login_route.dart';
import '../pages/pending_page.dart';
import '../pages/profile_page.dart';
import '../pages/register_page.dart';
import '../pages/user_profile_page.dart';
import '../state/auth_state.dart';

/// 认证状态变化 → `GoRouter` 重算守卫的桥（[GoRouter.refreshListenable]）。
class _AuthRefresh extends ChangeNotifier {
  void bump() => notifyListeners();
}

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
      GoRoute(
        path: '/login',
        builder: (BuildContext context, GoRouterState state) =>
            LoginRoute(next: state.uri.queryParameters['next']),
      ),
      GoRoute(
        path: '/register',
        builder: (BuildContext context, GoRouterState state) =>
            const RegisterPage(),
      ),
      // ---- 受保护（`App.tsx:60–92`，壳层由 AppShell 承担）----
      ShellRoute(
        builder: (BuildContext context, GoRouterState state, Widget child) =>
            AppShell(child: child),
        routes: <RouteBase>[
          GoRoute(path: '/', redirect: (BuildContext c, GoRouterState s) => '/group'),
          GoRoute(
            path: '/group',
            builder: (BuildContext c, GoRouterState s) => const PendingPage(
              path: '/group',
              webSource: 'App.tsx:68 → HomePage',
            ),
          ),
          GoRoute(
            path: '/home',
            redirect: (BuildContext c, GoRouterState s) => '/group',
          ),
          GoRoute(path: '/voice', builder: (c, s) => const PendingPage(path: '/voice', webSource: 'App.tsx:70 → VoiceHubPage')),
          GoRoute(path: '/voice/:channelId', builder: (c, s) => const PendingPage(path: '/voice/:channelId', webSource: 'App.tsx:71 → VoiceHubPage')),
          GoRoute(path: '/live', builder: (c, s) => const PendingPage(path: '/live', webSource: 'App.tsx:72 → LiveHubPage')),
          // ⚠️ 段数不同（3 vs 2），与 `/live/:channelId` 不冲突
          GoRoute(path: '/live/start/:channelId', builder: (c, s) => const PendingPage(path: '/live/start/:channelId', webSource: 'App.tsx:73 → LiveStudioPage')),
          GoRoute(path: '/live/:channelId', builder: (c, s) => const PendingPage(path: '/live/:channelId', webSource: 'App.tsx:74 → LiveRoomPage')),
          GoRoute(path: '/posts', builder: (c, s) => const PendingPage(path: '/posts', webSource: 'App.tsx:75 → PostsHubPage')),
          // ⚠️ **必须排在 `/posts/:postId` 之前**（同为 2 段，go_router 按声明顺序匹配）
          GoRoute(path: '/posts/mine', builder: (c, s) => const PendingPage(path: '/posts/mine', webSource: 'App.tsx:76 → MinePostsRoute')),
          GoRoute(path: '/posts/:postId', builder: (c, s) => const PendingPage(path: '/posts/:postId', webSource: 'App.tsx:77 → PostDetailPage')),
          GoRoute(path: '/games', builder: (c, s) => const PendingPage(path: '/games', webSource: 'App.tsx:78 → GamesHubPage')),
          GoRoute(path: '/games/:roomId', builder: (c, s) => const PendingPage(path: '/games/:roomId', webSource: 'App.tsx:79 → GamesHubPage')),
          GoRoute(path: '/messages', builder: (c, s) => const PendingPage(path: '/messages', webSource: 'App.tsx:80 → MessagesPage')),
          GoRoute(
            path: '/search',
            builder: (BuildContext c, GoRouterState s) => const PendingPage(
              path: '/search',
              webSource: 'App.tsx:81 → SearchPage',
            ),
          ),
          GoRoute(
            path: '/profile',
            builder: (BuildContext c, GoRouterState s) => const ProfilePage(),
          ),
          GoRoute(
            path: '/user/:userId',
            builder: (BuildContext c, GoRouterState s) =>
                UserProfilePage(userId: s.pathParameters['userId'] ?? ''),
          ),
          // ⚠️ 3 段 vs `/user/:userId` 的 2 段，天然不冲突
          GoRoute(path: '/user/:userId/posts', builder: (c, s) => const PendingPage(path: '/user/:userId/posts', webSource: 'App.tsx:84 → UserPostsRoute')),
          GoRoute(
            path: '/favorites',
            builder: (BuildContext c, GoRouterState s) => const PendingPage(
              path: '/favorites',
              webSource: 'App.tsx:85 → FavoritesPage',
            ),
          ),
          GoRoute(path: '/group/:id', builder: (c, s) => const PendingPage(path: '/group/:id', webSource: 'App.tsx:86 → GroupPage')),
          GoRoute(path: '/group/:id/posts/:postId', builder: (c, s) => const PendingPage(path: '/group/:id/posts/:postId', webSource: 'App.tsx:87 → GroupPage')),
          GoRoute(path: '/group/:id/voice/:voiceChannelId', builder: (c, s) => const PendingPage(path: '/group/:id/voice/:voiceChannelId', webSource: 'App.tsx:88 → GroupPage')),
          GoRoute(path: '/group/:id/live/:liveChannelId', builder: (c, s) => const PendingPage(path: '/group/:id/live/:liveChannelId', webSource: 'App.tsx:89 → GroupPage')),
          GoRoute(path: '/group/:id/:scene', builder: (c, s) => const PendingPage(path: '/group/:id/:scene', webSource: 'App.tsx:90 → GroupPage')),
          GoRoute(path: '/chat/:conversationId', builder: (c, s) => const PendingPage(path: '/chat/:conversationId', webSource: 'App.tsx:91 → ChatConversationRoute')),
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