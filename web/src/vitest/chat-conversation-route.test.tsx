/**
 * ChatConversationRoute 测试：
 * - 群聊会话（store 命中 / API 返回）→ 重定向 /group/:id；
 * - 私聊会话 → 渲染 PrivateChatPage（独立私聊窗口）；
 * - 详情查询失败 → 回退 PrivateChatPage 自理。
 * PrivateChatPage/GroupPage/chatApi 全部 mock，避免真实 API/WS 副作用。
 */
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ConversationDetail } from "../api/types";
import { useChatStore } from "../stores/chat";
import { ChatConversationRoute } from "../pages/ChatConversationRoute";

vi.mock("../pages/PrivateChatPage", () => ({
  PrivateChatPage: () => <div>私聊窗口本体</div>,
}));

vi.mock("../api/chat", () => ({
  // 默认返回私聊详情，避免任何未显式设置实现的路径返回 undefined（.then 崩溃）
  getConversation: vi.fn().mockResolvedValue({
    id: "c-default",
    type: "private",
    title: "私聊",
    announcement: "",
    avatar: "",
    owner_id: "o1",
    members: [],
    my_role: null,
    member_count: 2,
    unread_count: 0,
    created_at: "2026-01-01T00:00:00Z",
  }),
}));

import * as chatApi from "../api/chat";

function renderRoute(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="/chat/:conversationId" element={<ChatConversationRoute />} />
        <Route path="/group/:id" element={<div>群聊场景页面</div>} />
      </Routes>
    </MemoryRouter>,
  );
}

function conv(type: "private" | "group"): ConversationDetail {
  return {
    id: "c1",
    type,
    title: type === "group" ? "测试群" : "私聊",
    announcement: "",
    avatar: "",
    owner_id: "o1",
    members: [],
    my_role: null,
    member_count: 2,
    unread_count: 0,
    created_at: new Date().toISOString(),
  };
}

beforeEach(() => {
  useChatStore.setState({ conversations: [] });
});

afterEach(() => {
  vi.clearAllMocks();
  useChatStore.setState({ conversations: [] });
});

describe("ChatConversationRoute", () => {
  it("群聊会话（store 命中）重定向 /group/:id", async () => {
    useChatStore.setState({
      conversations: [
        { ...conv("group"), id: "g1", peer: null } as never,
      ],
    });
    renderRoute("/chat/g1");
    await waitFor(() => expect(screen.getByText("群聊场景页面")).toBeInTheDocument());
  });

  it("私聊会话（store 命中）渲染 ChatPage", async () => {
    useChatStore.setState({
      conversations: [{ ...conv("private"), id: "p1", peer: null } as never],
    });
    renderRoute("/chat/p1");
    await waitFor(() => expect(screen.getByText("私聊窗口本体")).toBeInTheDocument());
  });

  it("store 未命中时查详情：群聊 → 重定向", async () => {
    vi.mocked(chatApi.getConversation).mockResolvedValue(conv("group"));
    renderRoute("/chat/g2");
    await waitFor(() => expect(screen.getByText("群聊场景页面")).toBeInTheDocument());
    expect(chatApi.getConversation).toHaveBeenCalledWith("g2");
  });

  it("store 未命中时查详情：私聊 → 渲染 ChatPage", async () => {
    vi.mocked(chatApi.getConversation).mockResolvedValue(conv("private"));
    renderRoute("/chat/p2");
    await waitFor(() => expect(screen.getByText("私聊窗口本体")).toBeInTheDocument());
  });

  it("详情查询失败显示错误并可重试", async () => {
    vi.mocked(chatApi.getConversation)
      .mockRejectedValueOnce(new Error("boom"))
      .mockResolvedValueOnce(conv("private"));
    renderRoute("/chat/x");
    await waitFor(() => expect(screen.getByRole("alert")).toBeInTheDocument());
    const retry = screen.getByRole("button", { name: "重试" });
    retry.click();
    await waitFor(() => expect(screen.getByText("私聊窗口本体")).toBeInTheDocument());
    expect(chatApi.getConversation).toHaveBeenCalledTimes(2);
  });

  it("详情查询中显示骨架屏", async () => {
    vi.mocked(chatApi.getConversation).mockImplementation(
      () => new Promise(() => {}), // 永不 resolve
    );
    renderRoute("/chat/x");
    await waitFor(() =>
      expect(screen.getByRole("status", { name: "正在加载" })).toBeInTheDocument(),
    );
  });
});
