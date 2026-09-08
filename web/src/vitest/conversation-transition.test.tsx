import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { AnimatePresence, motion } from "framer-motion";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ChatMessage, ConversationSummary } from "../api/types";
import { ApiError } from "../api/client";
import { ConversationTransition } from "../components/motion/ConversationTransition";
import { PrivateChatPane } from "../components/chat/PrivateChatPane";
import { GroupChat } from "../pages/group/GroupChat";
import { PrivateChatPage } from "../pages/PrivateChatPage";
import { useChatStore } from "../stores/chat";
import { useMessageStore } from "../stores/message";
import { useSubGroupStore } from "../stores/subgroup";
import * as chatActions from "../hooks/useChat";

const observed = vi.hoisted(() => ({
  listeners: new Set<(frame: unknown) => void>(),
  readers: new Map<string, (message: ChatMessage, exact: boolean) => unknown>(),
}));

vi.mock("../components/chat/MessageInput", async () => {
  const { forwardRef } = await import("react");
  return {
    MessageInput: forwardRef<HTMLTextAreaElement, { convId: string; disabled?: boolean }>(({ convId, disabled }, ref) => (
      <textarea ref={ref} aria-label={`草稿 ${convId}`} data-editor-owner={convId} disabled={disabled} />
    )),
  };
});
vi.mock("../components/chat/MessageList", () => ({
  MessageList: ({ conversation, onMarkRead }: {
    conversation: ConversationSummary | null;
    onMarkRead: (message: ChatMessage, exact: boolean) => unknown;
  }) => {
    if (conversation) observed.readers.set(conversation.id, onMarkRead);
    return <div data-messages-owner={conversation?.id} />;
  },
}));
vi.mock("../hooks/useChat", async () => ({
  messageInSubgroup: (await vi.importActual<typeof import("../hooks/useChat")>("../hooks/useChat")).messageInSubgroup,
  loadHistory: vi.fn().mockResolvedValue(undefined),
  loadMoreHistory: vi.fn().mockResolvedValue(undefined),
  loadHistoryUntilSeq: vi.fn().mockResolvedValue(false),
  markMessageReadExact: vi.fn(),
  markConversationReadThrough: vi.fn(),
  recallMessage: vi.fn(),
  retryOptimistic: vi.fn(),
  removeOptimistic: vi.fn(),
  cancelOptimistic: vi.fn(),
  TARGET_HISTORY_MAX_PAGES: 10,
}));
vi.mock("../ws/chat", () => ({
  chatWS: {
    subscribe: vi.fn(),
    onFrame: (handler: (frame: unknown) => void) => {
      observed.listeners.add(handler);
      return () => observed.listeners.delete(handler);
    },
  },
}));
vi.mock("../api/users", () => ({ getUserDetail: vi.fn(() => new Promise(() => {})) }));
vi.mock("../api/elysia", () => ({ getElysiaProfile: vi.fn(() => new Promise(() => {})) }));
vi.mock("../api/chat", () => ({ listSubgroupsPage: vi.fn(() => new Promise(() => {})), getConversationMetadata: vi.fn(() => new Promise(() => {})), listConversationsPage: vi.fn(() => new Promise(() => {})), listConversationMembersPage: vi.fn(() => new Promise(() => {})) }));

function conversation(id: string, type: "private" | "group" = "private"): ConversationSummary {
  return {
    id, type, title: id, announcement: "", avatar: "", owner_id: "me",
    members: [], my_role: "member", member_count: 2, unread_count: 1,
    created_at: "2026-09-08T00:00:00Z", peer: null,
  };
}

function preference(initial = false) {
  let reduced = initial;
  const listeners = new Set<() => void>();
  vi.stubGlobal("matchMedia", vi.fn((query: string) => ({
    get matches() { return query.includes("prefers-reduced-motion") && reduced; },
    addEventListener: (_name: string, listener: () => void) => listeners.add(listener),
    removeEventListener: (_name: string, listener: () => void) => listeners.delete(listener),
  })));
  return (next: boolean) => act(() => {
    reduced = next;
    Array.from(listeners).forEach((listener) => listener());
  });
}

function PrivateOwner({ id }: { id: string }) {
  return <ConversationTransition identity={id}><PrivateChatPane conversationId={id} panelMotion /></ConversationTransition>;
}

beforeEach(() => {
  preference();
  observed.listeners.clear();
  observed.readers.clear();
  vi.mocked(chatActions.loadHistory).mockReset().mockResolvedValue(undefined);
  useChatStore.setState({ conversations: [conversation("a"), conversation("b"), conversation("c")], activeConversationId: null });
  useMessageStore.getState().reset();
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.clearAllMocks();
});

describe("wide conversation panel ownership", () => {
  it("窄屏私聊也由顶栏/输入框各自进入，全屏右滑层不叠加自动位移", async () => {
    vi.stubGlobal("matchMedia", vi.fn((query: string) => ({ matches: query === "(max-width: 768px)", addEventListener: vi.fn(), removeEventListener: vi.fn() })));
    const { container } = render(<MemoryRouter initialEntries={["/chat/a"]}><Routes><Route path="/chat/:conversationId" element={<PrivateChatPage />} /></Routes></MemoryRouter>);
    const head = container.querySelector<HTMLElement>('[data-motion-panel="chat-header"]')!;
    const composer = container.querySelector<HTMLElement>('[data-motion-panel="chat-composer"]')!;
    expect(head.style.transform).toContain("translateY(-20px)");
    expect(composer.style.transform).toContain("translateY(20px)");
    expect(container.querySelector<HTMLElement>(".fullscreen-swipe-back")!.style.transform).not.toContain("translate");
    expect(container.querySelector<HTMLElement>(".private-chat")!.style.transform).not.toContain("translate");
    await waitFor(() => expect(composer.style.transform).toBe("none"));
    expect(useChatStore.getState().activeConversationId).toBe("a");
  });
  it("顶栏从上、消息从右、输入从下进入，完成后准确归零", async () => {
    const { container } = render(<PrivateOwner id="a" />);
    const header = container.querySelector<HTMLElement>('[data-motion-panel="chat-header"]')!;
    const messages = container.querySelector<HTMLElement>('[data-motion-panel="chat-messages"]')!;
    const composer = container.querySelector<HTMLElement>('[data-motion-panel="chat-composer"]')!;
    expect(header.style.transform).toContain("translateY(-20px)");
    expect(messages.style.transform).toContain("translateX(20px)");
    expect(composer.style.transform).toContain("translateY(20px)");
    await waitFor(() => {
      for (const panel of [header, messages, composer]) {
        expect(panel.style.transform).toBe("none");
        expect(panel.style.opacity).toBe("1");
      }
    });
  });

  it("旧对象先退出，快切只挂最新对象且草稿、typing 和已读归属不串线", async () => {
    const { container, rerender } = render(<PrivateOwner id="a" />);
    const oldEditor = screen.getByRole("textbox", { name: "草稿 a" });
    fireEvent.change(oldEditor, { target: { value: "只属于 a" } });
    await waitFor(() => expect(container.querySelector<HTMLElement>('[data-motion-panel="chat-composer"]')!.style.opacity).toBe("1"));
    expect(observed.listeners.size).toBe(1);

    rerender(<PrivateOwner id="b" />);
    const exiting = container.querySelector('[data-conversation-owner="a"]')!;
    expect(exiting).toHaveAttribute("inert");
    expect(exiting).toHaveAttribute("data-motion-state", "exiting");
    expect(oldEditor).toBeDisabled();
    expect(useChatStore.getState().activeConversationId).toBeNull();
    expect(observed.listeners.size).toBe(0);
    expect(container.querySelectorAll("textarea")).toHaveLength(1);
    expect(chatActions.loadHistory).not.toHaveBeenCalledWith("b", undefined, true);
    observed.readers.get("a")!({ id: "late-a" } as ChatMessage, true);
    expect(chatActions.markMessageReadExact).not.toHaveBeenCalled();

    rerender(<PrivateOwner id="c" />);
    const newEditor = await screen.findByRole("textbox", { name: "草稿 c" });
    expect(newEditor).toHaveValue("");
    expect(newEditor).not.toBe(oldEditor);
    expect(oldEditor).not.toBeInTheDocument();
    expect(container.querySelectorAll("textarea")).toHaveLength(1);
    expect(useChatStore.getState().activeConversationId).toBe("c");
    expect(observed.listeners.size).toBe(1);
    expect(vi.mocked(chatActions.loadHistory).mock.calls.map(([id]) => id)).toEqual(["a", "c"]);
    observed.readers.get("c")!({ id: "visible-c" } as ChatMessage, true);
    expect(chatActions.markMessageReadExact).toHaveBeenCalledWith("c", "visible-c");
  });

  it("整页退出向内传播，旧 owner 清理发生在新页面打开前且不清掉新 owner", async () => {
    function Pages({ id }: { id: string }) {
      return <AnimatePresence mode="sync"><motion.div key={id} exit={{ opacity: 0, transition: { duration: 0.5 } }}><PrivateOwner id={id} /></motion.div></AnimatePresence>;
    }
    const states: Array<string | null> = [];
    const { container, rerender } = render(<Pages id="a" />);
    await waitFor(() => expect(container.querySelector<HTMLElement>('[data-motion-panel="chat-composer"]')!.style.opacity).toBe("1"));
    const off = useChatStore.subscribe((state, old) => {
      if (state.activeConversationId !== old.activeConversationId) states.push(state.activeConversationId);
    });
    rerender(<Pages id="c" />);
    expect(container.querySelector('[data-conversation-owner="a"]')).toHaveAttribute("inert");
    expect(container.querySelector('[data-editor-owner="a"]')).toBeDisabled();
    expect(states).toEqual([null, "c"]);
    expect(observed.listeners.size).toBe(1);
    observed.readers.get("a")!({ id: "late-a" } as ChatMessage, true);
    expect(chatActions.markMessageReadExact).not.toHaveBeenCalled();
    await waitFor(() => expect(container.querySelector('[data-conversation-owner="a"]')).toBeNull());
    expect(useChatStore.getState().activeConversationId).toBe("c");
    off();
  });

  it("reduced-motion 不产生面板位移，退出途中启用也结束旧 owner", async () => {
    const reduce = preference(true);
    const { container, rerender } = render(<PrivateOwner id="a" />);
    for (const panel of container.querySelectorAll<HTMLElement>("[data-motion-panel]")) {
      expect(panel.style.transform).not.toContain("translate");
    }
    reduce(false);
    rerender(<PrivateOwner id="b" />);
    reduce(true);
    await screen.findByRole("textbox", { name: "草稿 b" });
    expect(container.querySelector('[data-conversation-owner="a"]')).toBeNull();
    expect(useChatStore.getState().activeConversationId).toBe("b");
    for (const panel of container.querySelectorAll<HTMLElement>("[data-motion-panel]")) {
      expect(panel.style.transform).not.toContain("translate");
    }
  });

  it("群聊退出后的旧历史失败不能删除新群或把当前页面导航回主页", async () => {
    useChatStore.setState({ conversations: [conversation("a", "group"), conversation("c", "group")] });
    useSubGroupStore.setState({
      activeByGroup: { a: "sg-a", c: "sg-c" },
      byGroup: {
        a: [{ id: "sg-a", conversation_id: "a", name: "默认组", is_default: true, unread_count: 0, created_at: "2026-09-08T00:00:00Z" }],
        c: [{ id: "sg-c", conversation_id: "c", name: "默认组", is_default: true, unread_count: 0, created_at: "2026-09-08T00:00:00Z" }],
      },
    });
    let rejectOld!: (error: Error) => void;
    vi.mocked(chatActions.loadHistory).mockReturnValueOnce(new Promise((_resolve, reject) => { rejectOld = reject; }));
    function GroupOwner({ id }: { id: string }) {
      return <MemoryRouter><ConversationTransition identity={id}><GroupChat groupId={id} panelMotion /></ConversationTransition></MemoryRouter>;
    }
    const { rerender } = render(<GroupOwner id="a" />);
    expect(useChatStore.getState().activeConversationId).toBe("a");
    rerender(<GroupOwner id="c" />);
    expect(useChatStore.getState().activeConversationId).toBeNull();
    await screen.findByRole("textbox", { name: "草稿 c" });
    await act(async () => rejectOld(new ApiError(403, "旧群权限已变更")));
    expect(useChatStore.getState().activeConversationId).toBe("c");
    expect(useChatStore.getState().conversations.map(({ id }) => id)).toEqual(["a", "c"]);
    expect(screen.getByRole("textbox", { name: "草稿 c" })).toBeInTheDocument();
  });
});
