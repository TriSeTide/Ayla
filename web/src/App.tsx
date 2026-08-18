/**
 * 路由表（聚合主页与多端布局：私聊 / 群聊分离）。
 *
 * - /login、/register 公开；其余受保护页统一挂在 AppShell
 *   （窄屏 BottomTabs 系 / 宽屏 TopNav 系，直播间沉浸）。
 * - 一级路由：/home /voice /live /posts /games /messages /search /profile /favorites
 *   /group/:id[/*]；私聊窗口 /chat/:conversationId（PrivateChatPage，
 *   群聊会话重定向 /group/:id），私聊入口在消息中心 /messages 私信 tab。
 * - / 重定向 /home（窄屏主页；宽屏 /home 重定向到最近群）。
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
import { PostDetailPage } from "./pages/PostDetailPage";
import { PostsHubPage } from "./pages/PostsHubPage";
import { ProfilePage } from "./pages/ProfilePage";
import { RegisterPage } from "./pages/RegisterPage";
import { SearchPage } from "./pages/SearchPage";
import { VoiceHubPage } from "./pages/VoiceHubPage";

export default function App() {
  return (
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
        <Route path="/" element={<Navigate to="/home" replace />} />
        <Route path="/home" element={<HomePage />} />
        <Route path="/voice" element={<VoiceHubPage />} />
        <Route path="/voice/:channelId" element={<VoiceHubPage />} />
        <Route path="/live" element={<LiveHubPage />} />
        <Route path="/live/start/:channelId" element={<LiveStudioPage />} />
        <Route path="/live/:channelId" element={<LiveRoomPage />} />
        <Route path="/posts" element={<PostsHubPage />} />
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

      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}
