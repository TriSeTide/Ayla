/**
 * VisibilitySelector 按需加载兜底测试（验收：数据未加载时弹窗显示空的问题）
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import { VisibilitySelector } from "../components/VisibilitySelector";
import { useChatStore } from "../stores/chat";
import * as chatApi from "../api/chat";
import type { ConversationSummary } from "../api/types";

vi.mock("../api/chat");

function groupConv(id: string, title: string): ConversationSummary {
  return {
    id,
    type: "group",
    title,
    announcement: "",
    avatar: "",
    owner_id: "u1",
    members: [],
    my_role: "member",
    member_count: 1,
    unread_count: 0,
    created_at: "2025-01-01T00:00:00Z",
    peer: null,
  };
}

describe("VisibilitySelector 按需加载", () => {
  beforeEach(() => {
    // 重置 store 为空状态（模拟弹窗打开时数据未加载；含 lastFetched 归零）
    useChatStore.getState().reset();
    vi.clearAllMocks();
  });

  afterEach(() => {
    useChatStore.getState().reset();
  });

  it("conversations 为空时自动调用 listConversations 加载", async () => {
    const mockConversations = [groupConv("g1", "测试群1"), groupConv("g2", "测试群2")];
    vi.mocked(chatApi.listConversations).mockResolvedValue(mockConversations);

    const onChange = vi.fn();
    const onSelectedGroupIdsChange = vi.fn();

    render(
      <VisibilitySelector
        value={{ public: false, friends: false, group: true }}
        onChange={onChange}
        selectedGroupIds={[]}
        onSelectedGroupIdsChange={onSelectedGroupIdsChange}
      />
    );

    // 验证 API 被调用
    await waitFor(() => {
      expect(chatApi.listConversations).toHaveBeenCalledTimes(1);
    });

    // 验证数据加载到 store
    await waitFor(() => {
      expect(useChatStore.getState().conversations).toHaveLength(2);
    });

    // 验证群列表显示
    await waitFor(() => {
      expect(screen.getByText("测试群1")).toBeInTheDocument();
      expect(screen.getByText("测试群2")).toBeInTheDocument();
    });
  });

  it("conversations 已有数据时不重复加载", () => {
    // 模拟 store 已持有新鲜群列表（lastFetched 为当前时间）
    useChatStore.setState({
      conversations: [groupConv("g1", "已有群")],
      loading: false,
      error: null,
      lastFetched: Date.now(),
    });

    const onChange = vi.fn();
    const onSelectedGroupIdsChange = vi.fn();

    render(
      <VisibilitySelector
        value={{ public: false, friends: false, group: true }}
        onChange={onChange}
        selectedGroupIds={[]}
        onSelectedGroupIdsChange={onSelectedGroupIdsChange}
      />
    );

    // API 不应被调用
    expect(chatApi.listConversations).not.toHaveBeenCalled();

    // 已有数据应正常显示
    expect(screen.getByText("已有群")).toBeInTheDocument();
  });

  it("加载期间显示骨架屏", async () => {
    vi.mocked(chatApi.listConversations).mockImplementation(
      () => new Promise((resolve) => setTimeout(() => resolve([]), 50))
    );

    const onChange = vi.fn();
    const onSelectedGroupIdsChange = vi.fn();

    render(
      <VisibilitySelector
        value={{ public: false, friends: false, group: true }}
        onChange={onChange}
        selectedGroupIds={[]}
        onSelectedGroupIdsChange={onSelectedGroupIdsChange}
      />
    );

    // 加载期间应显示骨架屏
    await waitFor(() => {
      expect(document.querySelector(".visibility-groups-skeleton")).toBeInTheDocument();
    });

    // 等待加载完成后骨架屏消失，显示空状态
    await waitFor(() => {
      expect(document.querySelector(".visibility-groups-skeleton")).not.toBeInTheDocument();
      expect(screen.getByText("没有匹配的群")).toBeInTheDocument();
    }, { timeout: 2000 });
  });

  it("加载失败时不中断界面", async () => {
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.mocked(chatApi.listConversations).mockRejectedValue(new Error("网络错误"));

    const onChange = vi.fn();
    const onSelectedGroupIdsChange = vi.fn();

    render(
      <VisibilitySelector
        value={{ public: false, friends: false, group: true }}
        onChange={onChange}
        selectedGroupIds={[]}
        onSelectedGroupIdsChange={onSelectedGroupIdsChange}
      />
    );

    await waitFor(() => {
      expect(consoleError).toHaveBeenCalledWith("加载群列表失败", expect.any(Error));
    });

    // 等待加载状态清除后，界面应显示"没有匹配的群"而非崩溃
    await waitFor(() => {
      expect(document.querySelector(".visibility-groups-skeleton")).not.toBeInTheDocument();
      expect(screen.getByText("没有匹配的群")).toBeInTheDocument();
    }, { timeout: 2000 });

    consoleError.mockRestore();
  });
});
