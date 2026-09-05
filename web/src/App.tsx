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
 * 性能（重要）：页面组件保持**同步导入**，不按路由 React.lazy 切分。
 * 原因：本应用是类桌面 SPA，底部五 tab / 顶部导航频繁切换，路由懒加载会让每次
 * 切换都重新下载/解析对应 chunk（直播间 chunk 含 livekit+hls 约 600KB+），
 * 造成"切换卡一次空白"的负优化，且打破数据 store/WS 的全局预热连续性。
 * 正确的加载策略是"登录后全局预加载核心数据 + 组件同步渲染"，而非按路由取 chunk。
 * 如确需分包，应针对性只拆"重依赖"（livekit/hls）并常驻内存，不能整页懒加载。
 */
import { Navigate, Route, Routes } from "react-router-dom";
import { ProtectedRoute } from "./components/ProtectedRoute";
import { AppShell } from "./layout/AppShell";
import { ChatConversationRoute } from "./pages/ChatConversationRoute";
import { FavoritesPage } from "./pages/FavoritesPage";
import { GroupPage } from "./pages/GroupPage";
import { HomePage } from "./pages/HomePage";
import { GamesHubPage } from "./pages/GamesHubPage";
import { LiveHubPage } from "./pages/LiveHubPage";
import { LiveRoomPage } from "./pages/LiveRoomPage";
import { LiveStudioPage } from "./pages/LiveStudioPage";
import { LoginPage } from "./pages/LoginPage";
import { MessagesPage } from "./pages/MessagesPage";
import { MyPostsPage } from "./pages/MyPostsPage";
import { PostDetailPage } from "./pages/PostDetailPage";
import { PostsHubPage } from "./pages/PostsHubPage";
import { ProfilePage } from "./pages/ProfilePage";
import { RegisterPage } from "./pages/RegisterPage";
import { SearchPage } from "./pages/SearchPage";
import { VoiceHubPage } from "./pages/VoiceHubPage";
import { UserProfilePage } from "./pages/UserProfilePage";
import { NavigateBridge } from "./components/NavigateBridge";
import OverlayScrollbar from "./components/overlay/OverlayScrollbar";

export default function App() {
  return (
    <>
      <NavigateBridge />
      <OverlayScrollbar />
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
        <Route path="/games/:roomId" element={<GamesHubPage />} />
        <Route path="/messages" element={<MessagesPage />} />
        <Route path="/search" element={<SearchPage />} />
        <Route path="/profile" element={<ProfilePage />} />
        <Route path="/user/:userId" element={<UserProfilePage />} />
        <Route path="/favorites" element={<FavoritesPage />} />
        <Route path="/group/:id" element={<GroupPage />} />
        <Route path="/group/:id/posts/:postId" element={<GroupPage />} />
        <Route path="/group/:id/voice/:voiceChannelId" element={<GroupPage />} />
        <Route path="/group/:id/live/:liveChannelId" element={<GroupPage />} />
        <Route path="/group/:id/:scene" element={<GroupPage />} />
        <Route path="/chat/:conversationId" element={<ChatConversationRoute />} />
      </Route>

      <Route path="*" element={<Navigate to="/group" replace />} />
      </Routes>
    </>
  );
}
