/**
 * ConversationList 会话管理测试（M5）：
 * - 预览行显示最新一条消息（last_message），不再显示「在线/离线」；
 * - 在线状态移到名字行（紧随昵称）；
 * - ⋯ 菜单：置顶/取消置顶、删除（confirm 确认后调用 hide 并本地移除）。
 */
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as chatApi from "../api/chat";
import type { ConversationSummary } from "../api/types";
import { ConversationList } from "../components/chat/ConversationList";
import { useChatStore } from "../stores/chat";

vi.mock("../api/chat", () => ({
  togglePinConversation: vi.fn(),
  hideConversation: vi.fn(),
}));

const togglePinMock = vi.mocked(chatApi.togglePinConversation);
const hideMock = vi.mocked(chatApi.hideConversation);

function privateConv(overrides: Partial<ConversationSummary> = {}): ConversationSummary {
  return {
    id: "c1",
    type: "private",
    title: "小樱",
    announcement: "",
    avatar: "",
    owner_id: "me",
    members: [],
    my_role: "member",
    member_count: 2,
    unread_count: 0,
    is_pinned: false,
    last_message: null,
    created_at: "2026-01-01T00:00:00Z",
    peer: {
      id: "u2",
      username: "u2",
      nickname: "小樱",
      avatar: "",
      signature: "",
      status: "offline",
      online: false,
      date_joined: "2026-01-01T00:00:00Z",
    },
    ...overrides,
  };
}

function renderList(convs: ConversationSummary[], onSelect = vi.fn(), onError = vi.fn()) {
  return render(
    <ConversationList
      conversations={convs}
      activeId={null}
      onSelect={onSelect}
      onError={onError}
    />,
  );
}

beforeEach(() => {
  useChatStore.getState().reset();
  vi.clearAllMocks();
  togglePinMock.mockResolvedValue({ pinned: true, detail: "已置顶" });
  hideMock.mockResolvedValue({ detail: "会话已隐藏", hidden: true });
});

afterEach(() => {
  useChatStore.getState().reset();
  vi.restoreAllMocks();
});

describe("会话列表预览与在线状态", () => {
  it("预览行显示最新一条消息，不显示在线/离线文字", () => {
    renderList([
      privateConv({
        last_message: {
          seq: 3,
          type: "text",
          content: "今晚一起吃饭吗",
          sender_id: "u2",
          sender_name: "小樱",
          status: "sent",
          created_at: "2026-01-01T00:00:00Z",
        },
      }),
    ]);
    expect(screen.getByText("今晚一起吃饭吗")).toBeInTheDocument();
    // 预览行不再是在线状态
    expect(screen.queryByText("在线")).not.toBeInTheDocument();
  });

  it("在线状态显示在昵称后面（在线/离线小标签）", () => {
    renderList([privateConv()]);
    // 昵称与状态同属名字行
    const status = screen.getByText("离线");
    expect(status).toBeInTheDocument();
    expect(screen.getByText("小樱")).toBeInTheDocument();
  });

  it("无消息时显示「暂无消息」", () => {
    renderList([privateConv()]);
    expect(screen.getByText("暂无消息")).toBeInTheDocument();
  });

  it("群聊预览带发送者名，媒体消息显示占位", () => {
    renderList([
      {
        ...privateConv(),
        id: "g1",
        type: "group",
        title: "铁三角",
        peer: null,
        last_message: {
          seq: 7,
          type: "image",
          content: "",
          sender_id: "u3",
          sender_name: "阿蓝",
          status: "sent",
          created_at: "2026-01-01T00:00:00Z",
        },
      },
    ]);
    expect(screen.getByText("阿蓝: [图片]")).toBeInTheDocument();
  });

  it("已撤回消息显示占位", () => {
    renderList([
      privateConv({
        last_message: {
          seq: 4,
          type: "text",
          content: "这条被撤回了",
          sender_id: "u2",
          sender_name: "小樱",
          status: "recalled",
          created_at: "2026-01-01T00:00:00Z",
        },
      }),
    ]);
    expect(screen.getByText("[已撤回]")).toBeInTheDocument();
  });
});

describe("会话管理菜单", () => {
  it("点击 ⋯ 展开菜单（置顶/删除），再点关闭", () => {
    renderList([privateConv()]);
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /更多操作/ }));
    expect(screen.getByRole("menu")).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "置顶" })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "删除会话" })).toBeInTheDocument();
    // 再次点击 ⋯ 关闭
    fireEvent.click(screen.getByRole("button", { name: /更多操作/ }));
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  });

  it("置顶：调用 API 并更新 store（置顶会话移到最前）", async () => {
    useChatStore.getState().setConversations([
      privateConv(),
      { ...privateConv(), id: "c2", title: "阿蓝" },
    ]);
    renderList(useChatStore.getState().conversations);
    fireEvent.click(screen.getAllByRole("button", { name: /更多操作/ })[1]);
    fireEvent.click(screen.getByRole("menuitem", { name: "置顶" }));
    await waitFor(() => expect(togglePinMock).toHaveBeenCalledWith("c2", true));
    await waitFor(() => {
      expect(useChatStore.getState().conversations[0].id).toBe("c2");
      expect(useChatStore.getState().conversations[0].is_pinned).toBe(true);
    });
  });

  it("已置顶会话菜单显示「取消置顶」", () => {
    renderList([privateConv({ is_pinned: true })]);
    fireEvent.click(screen.getByRole("button", { name: /更多操作/ }));
    expect(screen.getByRole("menuitem", { name: "取消置顶" })).toBeInTheDocument();
  });

  it("置顶会话行带 is-pinned class（视觉区分），普通会话不带", () => {
    renderList([
      privateConv({ id: "p1", is_pinned: true }),
      privateConv({ id: "n1" }),
    ]);
    // 置顶行与普通行都含"暂无消息"预览，取按钮数组按序验证 class
    const btns = screen.getAllByRole("button", { name: /暂无消息/ });
    expect(btns[0].className).toContain("is-pinned");
    expect(btns[1].className).not.toContain("is-pinned");
  });

  it("删除：confirm 确认后调用 hide 并从列表移除", async () => {
    vi.spyOn(window, "confirm").mockReturnValue(true);
    useChatStore.getState().setConversations([privateConv()]);
    renderList(useChatStore.getState().conversations);
    fireEvent.click(screen.getByRole("button", { name: /更多操作/ }));
    fireEvent.click(screen.getByRole("menuitem", { name: "删除会话" }));
    await waitFor(() => expect(hideMock).toHaveBeenCalledWith("c1"));
    await waitFor(() => {
      expect(useChatStore.getState().conversations).toHaveLength(0);
    });
  });

  it("删除：confirm 取消则不调用 API", () => {
    vi.spyOn(window, "confirm").mockReturnValue(false);
    useChatStore.getState().setConversations([privateConv()]);
    renderList(useChatStore.getState().conversations);
    fireEvent.click(screen.getByRole("button", { name: /更多操作/ }));
    fireEvent.click(screen.getByRole("menuitem", { name: "删除会话" }));
    expect(hideMock).not.toHaveBeenCalled();
    expect(useChatStore.getState().conversations).toHaveLength(1);
  });

  it("置顶失败 → 调用 onError 提示", async () => {
    togglePinMock.mockRejectedValue(new Error("服务器错误"));
    const onError = vi.fn();
    renderList([privateConv()], vi.fn(), onError);
    fireEvent.click(screen.getByRole("button", { name: /更多操作/ }));
    fireEvent.click(screen.getByRole("menuitem", { name: "置顶" }));
    await waitFor(() => expect(onError).toHaveBeenCalledWith("服务器错误"));
  });

  it("点击会话仍触发 onSelect（菜单关闭）", () => {
    const onSelect = vi.fn();
    renderList([privateConv()], onSelect);
    // 主按钮（conv-item）的 accessible name 包含预览文本；avatar/更多按钮不包含
    fireEvent.click(screen.getByRole("button", { name: /暂无消息/ }));
    expect(onSelect).toHaveBeenCalledWith("c1");
  });
});
