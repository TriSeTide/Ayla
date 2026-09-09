/**
 * 入口：Router + 会话恢复 + 全屏预加载门。
 * 页面加载时尝试从 sessionStorage 的 refresh token 恢复会话；
 * 已登录时等待核心数据预加载（所有页面秒开的来源）完成才渲染 App，
 * 期间全屏加载界面常驻，避免白屏与闪跳登录页。
 */
import React from "react";
import ReactDOM from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import App from "./App";
import { FullScreenLoader } from "./components/FullScreenLoader";
import { useAuthStore } from "./stores/auth";
import { appInit } from "./appInit";
import { chatWS } from "./ws/chat";
import { presenceClient } from "./ws/presence";
import "./styles/tokens.css";
import "./styles/base.css";
import "./styles/app.css";
import "./styles/auth.css";
import "./styles/shell.css";
import "./styles/home.css";
import "./styles/group.css";
import "./styles/live.css";
import "./styles/voice.css";
import "./styles/posts.css";
import "./styles/boardgame.css";
import "./styles/messages.css";
import "./styles/search.css";
import "./styles/profile.css";
import "./styles/private.css";
import "./styles/auroraqua.css";

async function bootstrap() {
  // 恢复会话（无 refresh 则直接标记 initialized）
  await useAuthStore.getState().restoreSession();
  // 恢复成功后若有 access，连接 presence + chat 并等待核心数据预加载完成
  const { accessToken } = useAuthStore.getState();
  if (accessToken) {
    presenceClient.connect();
    chatWS.connect();
    await appInit.run();
  }
}

const root = ReactDOM.createRoot(document.getElementById("root")!);
// 先渲染全屏加载界面：会话恢复 + 预加载期间不白屏、不闪跳
root.render(<FullScreenLoader />);
bootstrap().then(() => {
  root.render(
    <React.StrictMode>
      <BrowserRouter>
        <App />
      </BrowserRouter>
    </React.StrictMode>,
  );
});
