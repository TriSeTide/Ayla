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
import { useChatStore } from "./stores/chat";
import { usePostsStore } from "./stores/posts";
import { loadDirectory } from "./stores/directory";
import { chatWS, subscribeGroupConversations } from "./ws/chat";
import { presenceClient } from "./ws/presence";
import { listConversations } from "./api/chat";
import { listPosts } from "./api/posts";
import { listFavorites } from "./api/favorites";
import "./styles/tokens.css";
import "./styles/base.css";
import "./styles/app.css";
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
  // 恢复成功后若有 access，连接 presence + chat
  const { accessToken } = useAuthStore.getState();
  if (accessToken) {
    presenceClient.connect();
    chatWS.connect();
    // 并发预加载核心列表（含帖子信息流/收藏/桌游房，进各页面秒开）
    const loadCoreData = async () => {
      try {
        const [convs, , , posts, favs] = await Promise.all([
          listConversations(),
          loadDirectory("voice"),
          loadDirectory("live"),
          listPosts({ scope: "feed", limit: 20 }),
          listFavorites("post"),
          loadDirectory("game"),
        ]);
        useChatStore.getState().setConversations(convs);
        // 订阅所有群：主页/宽屏 ServerRail 不打开群聊天也能收到群消息 message.new，
        // 红点/轮播消息卡/排序实时刷新。
        subscribeGroupConversations(convs);
        usePostsStore.getState().setPage(posts.results, posts.next_cursor, posts.has_more);
        usePostsStore.getState().loadFavorites(favs);
      } catch (err) {
        console.error("[预加载] 核心数据加载失败", err);
        // 不阻断流程，用户访问页面时会重试
      }
    };
    void loadCoreData();
  }
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
