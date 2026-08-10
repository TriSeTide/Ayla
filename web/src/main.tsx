/**
 * 入口：Router + 会话恢复。
 * 页面加载时尝试从 sessionStorage 的 refresh token 恢复会话；
 * 恢复完成后才渲染，避免已登录用户闪跳登录页。
 */
import React from "react";
import ReactDOM from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import App from "./App";
import { useAuthStore } from "./stores/auth";
import { presenceClient } from "./ws/presence";
import "./styles/global.css";

async function bootstrap() {
  // 恢复会话（无 refresh 则直接标记 initialized）
  await useAuthStore.getState().restoreSession();
  // 恢复成功后若有 access，连接 presence
  const { accessToken } = useAuthStore.getState();
  if (accessToken) presenceClient.connect();
}

bootstrap().then(() => {
  ReactDOM.createRoot(document.getElementById("root")!).render(
    <React.StrictMode>
      <BrowserRouter>
        <App />
      </BrowserRouter>
    </React.StrictMode>,
  );
});
