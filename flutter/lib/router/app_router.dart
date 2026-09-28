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

/// 未实现页面的路由页 —— **不做任何转场**（`NoTransitionPage`）。
///
/// 理由（2026-09-28 用户反馈「没做的页面就别强加动画」）：占位页之间切换时，转场唯一的效果
/// 就是让两块占位文字**重叠几帧**（残影），既不是 web 的行为、也没有任何信息量。
/// 等该路由交付真实页面时，把 `pageBuilder` 换回 `builder:` 即可 —— 那时它才走
/// `AylaPageTransitionsBuilder` 的分档（panelOwned / 群页 / 搜索页 / 普通路由）。
Page<void> _pending({required String path, required String webSource}) =>
    NoTransitionPage<void>(
      child: PendingPage(path: path, webSource: webSource),
    );

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
          GoRoute(
            path: '/group',
            pageBuilder: (BuildContext c, GoRouterState s) => _pending(
              path: '/group',
              webSource: 'App.tsx:68 → HomePage',
            ),
          ),
          GoRoute(
            path: '/home',
            redirect: (BuildContext c, GoRouterState s) => '/group',
          ),
          GoRoute(path: '/voice', pageBuilder: (c, s) => _pending(path: '/voice', webSource: 'App.tsx:70 → VoiceHubPage')),
          GoRoute(path: '/voice/:channelId', pageBuilder: (c, s) => _pending(path: '/voice/:channelId', webSource: 'App.tsx:71 → VoiceHubPage')),
          GoRoute(path: '/live', pageBuilder: (c, s) => _pending(path: '/live', webSource: 'App.tsx:72 → LiveHubPage')),
          // ⚠️ 段数不同（3 vs 2），与 `/live/:channelId` 不冲突
          GoRoute(path: '/live/start/:channelId', pageBuilder: (c, s) => _pending(path: '/live/start/:channelId', webSource: 'App.tsx:73 → LiveStudioPage')),
          GoRoute(path: '/live/:channelId', pageBuilder: (c, s) => _pending(path: '/live/:channelId', webSource: 'App.tsx:74 → LiveRoomPage')),
          GoRoute(path: '/posts', pageBuilder: (c, s) => _pending(path: '/posts', webSource: 'App.tsx:75 → PostsHubPage')),
          // ⚠️ **必须排在 `/posts/:postId` 之前**（同为 2 段，go_router 按声明顺序匹配）
          GoRoute(path: '/posts/mine', pageBuilder: (c, s) => _pending(path: '/posts/mine', webSource: 'App.tsx:76 → MinePostsRoute')),
          GoRoute(path: '/posts/:postId', pageBuilder: (c, s) => _pending(path: '/posts/:postId', webSource: 'App.tsx:77 → PostDetailPage')),
          GoRoute(path: '/games', pageBuilder: (c, s) => _pending(path: '/games', webSource: 'App.tsx:78 → GamesHubPage')),
          GoRoute(path: '/games/:roomId', pageBuilder: (c, s) => _pending(path: '/games/:roomId', webSource: 'App.tsx:79 → GamesHubPage')),
          GoRoute(path: '/messages', pageBuilder: (c, s) => _pending(path: '/messages', webSource: 'App.tsx:80 → MessagesPage')),
          GoRoute(
            path: '/search',
            pageBuilder: (BuildContext c, GoRouterState s) => _pending(
              path: '/search',
              webSource: 'App.tsx:81 → SearchPage',
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
          GoRoute(path: '/user/:userId/posts', pageBuilder: (c, s) => _pending(path: '/user/:userId/posts', webSource: 'App.tsx:84 → UserPostsRoute')),
          GoRoute(
            path: '/favorites',
            pageBuilder: (BuildContext c, GoRouterState s) => _pending(
              path: '/favorites',
              webSource: 'App.tsx:85 → FavoritesPage',
            ),
          ),
          GoRoute(path: '/group/:id', pageBuilder: (c, s) => _pending(path: '/group/:id', webSource: 'App.tsx:86 → GroupPage')),
          GoRoute(path: '/group/:id/posts/:postId', pageBuilder: (c, s) => _pending(path: '/group/:id/posts/:postId', webSource: 'App.tsx:87 → GroupPage')),
          GoRoute(path: '/group/:id/voice/:voiceChannelId', pageBuilder: (c, s) => _pending(path: '/group/:id/voice/:voiceChannelId', webSource: 'App.tsx:88 → GroupPage')),
          GoRoute(path: '/group/:id/live/:liveChannelId', pageBuilder: (c, s) => _pending(path: '/group/:id/live/:liveChannelId', webSource: 'App.tsx:89 → GroupPage')),
          GoRoute(path: '/group/:id/:scene', pageBuilder: (c, s) => _pending(path: '/group/:id/:scene', webSource: 'App.tsx:90 → GroupPage')),
          GoRoute(path: '/chat/:conversationId', pageBuilder: (c, s) => _pending(path: '/chat/:conversationId', webSource: 'App.tsx:91 → ChatConversationRoute')),
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