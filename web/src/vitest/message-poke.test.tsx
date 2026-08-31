/**
 * 戳一戳（任务 01）前端组件测试：
 * - MessageList：poke 消息居中提示渲染（历史与实时同一路径），文案「A戳了戳B」；
 * - MessageBubble：双击头像触发 poke（不进个人主页）、单击仍进主页（延迟判定）。
 */
import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ChatMessage, ConversationSummary } from "../api/types";
import { MessageList } from "../components/chat/MessageList";
import { MessageBubble } from "../components/chat/MessageBubble";
import { useAuthStore } from "../stores/auth";

vi.mock("../utils/navigation", () => ({ goUserProfile: vi.fn() }));

function pokeMessage(overrides: Partial<ChatMessage> = {}): ChatMessage {
  return {
    id: "poke1",
    conversation_id: "c1",
    sender_id: "u2",
    type: "poke",
    content: "me",
    media_id: null,
    reply_to: null,
    status: "sent",
    seq: 5,
    created_at: "2026-08-21T00:00:05Z",
    ...overrides,
  };
}

function groupConversation(): ConversationSummary {
  return {
    id: "c1",
    type: "group",
    title: "测试群",
    announcement: "",
    avatar: "",
    owner_id: "me",
    members: [
      {
        id: "u2",
        user: {
          id: "u2",
          username: "xiaoyi",
          nickname: "小乙",
          avatar: "",
          signature: "",
          status: "online",
          online: true,
          date_joined: "2026-01-01T00:00:00Z",
        },
        role: "member",
        muted: false,
        joined_at: "2026-01-01T00:00:00Z",
      },
    ],
    my_role: "member",
    member_count: 2,
    unread_count: 0,
    created_at: "2026-08-21T00:00:00Z",
    peer: null,
  };
}

afterEach(() => {
  useAuthStore.setState({ currentUser: null });
  vi.restoreAllMocks();
  vi.useRealTimers();
});

describe("MessageList 戳一戳居中提示", () => {
  it("poke 消息渲染居中提示「小乙戳了戳我」（target=自己归一为「我」）", () => {
    useAuthStore.setState({ currentUser: { id: "me" } as never });
    render(
      <MessageList
        messages={[pokeMessage()]}
        conversation={groupConversation()}
        elysiaUserId={null}
        hasMore={false}
        loading={false}
        onLoadMore={() => undefined}
      />,
    );
    const pill = document.querySelector(".msg-poke-pill");
    expect(pill?.textContent).toBe("小乙戳了戳我");
    // 非气泡：没有 MessageBubble 行
    expect(document.querySelector(".msg-row")).toBeNull();
  });

  it("poke 渲染节点带 data-message-id 且不触发未读逻辑（无未读标签）", () => {
    useAuthStore.setState({ currentUser: { id: "me" } as never });
    const { container } = render(
      <MessageList
        messages={[pokeMessage(), { ...pokeMessage(), id: "poke2", seq: 6 }]}
        conversation={groupConversation()}
        elysiaUserId={null}
        hasMore={false}
        loading={false}
        onLoadMore={() => undefined}
      />,
    );
    expect(container.querySelectorAll(".msg-poke")).toHaveLength(2);
    expect(container.querySelector('[data-message-id="poke1"]')).not.toBeNull();
    expect(screen.queryByText(/新消息/)).toBeNull();
  });
});

describe("MessageBubble 双击头像戳一戳", () => {
  it("双击头像 → onPokeSender（目标=消息发送者），单击被抑制不进主页", () => {
    vi.useFakeTimers();
    const onPoke = vi.fn();
    const onClick = vi.fn();
    render(
      <MessageBubble
        message={pokeMessage()}
        isSelf={false}
        senderName="小乙"
        senderAvatarLabel="乙"
        onSenderClick={onClick}
        onPokeSender={onPoke}
      />,
    );
    const avatar = screen.getByRole("button", { name: /小乙/ });
    fireEvent.click(avatar);
    fireEvent.click(avatar);
    act(() => {
      vi.advanceTimersByTime(400);
    });
    expect(onPoke).toHaveBeenCalledTimes(1);
    expect(onPoke).toHaveBeenCalledWith("u2");
    expect(onClick).not.toHaveBeenCalled();
  });

  it("单击头像 → 延迟后仍进个人主页，不触发 poke", () => {
    vi.useFakeTimers();
    const onPoke = vi.fn();
    const onClick = vi.fn();
    render(
      <MessageBubble
        message={pokeMessage()}
        isSelf={false}
        senderName="小乙"
        senderAvatarLabel="乙"
        onSenderClick={onClick}
        onPokeSender={onPoke}
      />,
    );
    const avatar = screen.getByRole("button", { name: /小乙/ });
    fireEvent.click(avatar);
    act(() => {
      vi.advanceTimersByTime(400);
    });
    expect(onClick).toHaveBeenCalledTimes(1);
    expect(onPoke).not.toHaveBeenCalled();
  });

  it("自己的头像也能双击触发 poke（需求：自己的头像也触发）", () => {
    vi.useFakeTimers();
    const onPoke = vi.fn();
    render(
      <MessageBubble
        message={pokeMessage({ sender_id: "me", content: "u2" })}
        isSelf
        senderAvatarLabel="我"
        onPokeSender={onPoke}
      />,
    );
    const avatar = screen.getByRole("button", { name: /发送者个人主页/ });
    fireEvent.click(avatar);
    fireEvent.click(avatar);
    act(() => {
      vi.advanceTimersByTime(400);
    });
    expect(onPoke).toHaveBeenCalledTimes(1);
    expect(onPoke).toHaveBeenCalledWith("me");
  });
});
