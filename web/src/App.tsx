/**
 * 路由表（聚合主页与多端布局 F1 基座，开发步骤文档 F1 + 开发文档 §2.1）。
 *
 * - /login、/register 公开；其余受保护页统一挂在 AppShell
 *   （窄屏 BottomTabs 系 / 宽屏 TopNav 系，直播间为沉浸式无 chrome）。
 * - 新增一级路由：/home /voice /live /posts /games /messages /search /profile
 *   /group/:id[/*]；页面本体未落地的路由渲染 PlaceholderPage（标注 F 步骤）。
 * - 旧路由兼容：/chat 直达会话列表（M5-1/M5-2 保留）；/chat/:conversationId
 *   群聊会话重定向 /group/:id、私聊会话保留渲染 ChatPage（ChatConversationRoute）。
 * - / 重定向 /home（窄屏主页；宽屏 /home 由 F2 重定向到最近群）。
 */
import { Navigate, Route, Routes } from "react-router-dom";
import { ProtectedRoute } from "./components/ProtectedRoute";
import { AppShell } from "./layout/AppShell";
import { ChatConversationRoute } from "./pages/ChatConversationRoute";
import { ChatPage } from "./pages/ChatPage";
import { GroupPage } from "./pages/GroupPage";
import { GroupScenePage } from "./pages/GroupScenePage";
import { HomePage } from "./pages/HomePage";
import { LiveHallPage } from "./pages/LiveHallPage";
import { LiveRoomPage } from "./pages/LiveRoomPage";
import { LoginPage } from "./pages/LoginPage";
import { PlaceholderPage } from "./pages/PlaceholderPage";
import { ProfilePage } from "./pages/ProfilePage";
import { RegisterPage } from "./pages/RegisterPage";
import { VoicePage } from "./pages/VoicePage";

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
        <Route path="/voice" element={<VoicePage />} />
        <Route path="/live" element={<LiveHallPage />} />
        <Route path="/live/:channelId" element={<LiveRoomPage />} />
        <Route path="/posts" element={<PlaceholderPage title="帖子" step="F6" />} />
        <Route path="/posts/:postId" element={<PlaceholderPage title="帖子详情" step="F6" />} />
        <Route path="/games" element={<PlaceholderPage title="桌游" step="F7" />} />
        <Route path="/messages" element={<PlaceholderPage title="消息" step="F8" />} />
        <Route path="/search" element={<PlaceholderPage title="搜索" step="F9" />} />
        <Route path="/profile" element={<ProfilePage />} />
        <Route path="/group/:id" element={<GroupPage />} />
        <Route path="/group/:id/:scene" element={<GroupScenePage />} />
        <Route path="/chat" element={<ChatPage />} />
        <Route path="/chat/:conversationId" element={<ChatConversationRoute />} />
      </Route>

      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}
