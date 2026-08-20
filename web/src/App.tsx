/**
 * 路由表（聚合主页与多端布局：私聊 / 群聊分离）。
 *
 * - /login、/register 公开；其余受保护页统一挂在 AppShell
 *   （窄屏 BottomTabs 系 / 宽屏 TopNav 系，直播间沉浸）。
 * - 一级路由：/home /voice /live /posts /games /messages /search /profile /favorites
 *   /group/:id[/*]；私聊窗口 /chat/:conversationId（PrivateChatPage，
 *   群聊会话重定向 /group/:id），私聊入口在消息中心 /messages 私信 tab。
 * - / 重定向 /group；/home 作为兼容入口重定向 /group。
 *
 * 性能：页面组件按路由 React.lazy 分割，首屏只加载当前路由 chunk，
 * 降低首屏 JS 体积与解析/执行时间（配合登录预加载，进入各页秒开）。
 */
import { lazy, Suspense } from "react";
import { Navigate, Route, Routes } from "react-router-dom";
import { ProtectedRoute } from "./components/ProtectedRoute";
import { AppShell } from "./layout/AppShell";

// 各页面独立 chunk（懒加载）；/group 主页为默认落地路由，保持最先可见
const ChatConversationRoute = lazy(() => import("./pages/ChatConversationRoute").then((m) => ({ default: m.ChatConversationRoute })));
const FavoritesPage = lazy(() => import("./pages/FavoritesPage").then((m) => ({ default: m.FavoritesPage })));
const GroupPage = lazy(() => import("./pages/GroupPage").then((m) => ({ default: m.GroupPage })));
const HomePage = lazy(() => import("./pages/HomePage").then((m) => ({ default: m.HomePage })));
const GamesHubPage = lazy(() => import("./pages/GamesHubPage").then((m) => ({ default: m.GamesHubPage })));
const LiveHubPage = lazy(() => import("./pages/LiveHubPage").then((m) => ({ default: m.LiveHubPage })));
const LiveRoomPage = lazy(() => import("./pages/LiveRoomPage").then((m) => ({ default: m.LiveRoomPage })));
const LiveStudioPage = lazy(() => import("./pages/LiveStudioPage").then((m) => ({ default: m.LiveStudioPage })));
const LoginPage = lazy(() => import("./pages/LoginPage").then((m) => ({ default: m.LoginPage })));
const MessagesPage = lazy(() => import("./pages/MessagesPage").then((m) => ({ default: m.MessagesPage })));
const MyPostsPage = lazy(() => import("./pages/MyPostsPage").then((m) => ({ default: m.MyPostsPage })));
const PostDetailPage = lazy(() => import("./pages/PostDetailPage").then((m) => ({ default: m.PostDetailPage })));
const PostsHubPage = lazy(() => import("./pages/PostsHubPage").then((m) => ({ default: m.PostsHubPage })));
const ProfilePage = lazy(() => import("./pages/ProfilePage").then((m) => ({ default: m.ProfilePage })));
const RegisterPage = lazy(() => import("./pages/RegisterPage").then((m) => ({ default: m.RegisterPage })));
const SearchPage = lazy(() => import("./pages/SearchPage").then((m) => ({ default: m.SearchPage })));
const VoiceHubPage = lazy(() => import("./pages/VoiceHubPage").then((m) => ({ default: m.VoiceHubPage })));

// 懒加载 fallback：几何占位（保持高度，避免布局跳动）
function RouteFallback() {
  return (
    <div className="route-fallback" aria-busy="true">
      <div className="skeleton route-fallback-block" />
    </div>
  );
}

export default function App() {
  return (
    <Suspense fallback={<RouteFallback />}>
      <Routes>
        <Route path="/login" element={<LoginPage />} />
        <Route path="/register" element={<RegisterPage />} />

        <Route
          element={
            <ProtectedRoute>
              <AppShell />
            </ProtectedRoute>
          }
        >
          <Route path="/" element={<Navigate to="/group" replace />} />
          <Route path="/group" element={<HomePage />} />
          <Route path="/home" element={<Navigate to="/group" replace />} />
          <Route path="/voice" element={<VoiceHubPage />} />
          <Route path="/voice/:channelId" element={<VoiceHubPage />} />
          <Route path="/live" element={<LiveHubPage />} />
          <Route path="/live/start/:channelId" element={<LiveStudioPage />} />
          <Route path="/live/:channelId" element={<LiveRoomPage />} />
          <Route path="/posts" element={<PostsHubPage />} />
          <Route path="/posts/mine" element={<MyPostsPage />} />
          <Route path="/posts/:postId" element={<PostDetailPage />} />
          <Route path="/games" element={<GamesHubPage />} />
          <Route path="/messages" element={<MessagesPage />} />
          <Route path="/search" element={<SearchPage />} />
          <Route path="/profile" element={<ProfilePage />} />
          <Route path="/favorites" element={<FavoritesPage />} />
          <Route path="/group/:id" element={<GroupPage />} />
          <Route path="/group/:id/posts/:postId" element={<GroupPage />} />
          <Route path="/group/:id/voice/:voiceChannelId" element={<GroupPage />} />
          <Route path="/group/:id/:scene" element={<GroupPage />} />
          <Route path="/chat/:conversationId" element={<ChatConversationRoute />} />
        </Route>

        <Route path="*" element={<Navigate to="/group" replace />} />
      </Routes>
    </Suspense>
  );
}
