/**
 * MessageList U16 窗口化测试。
 *
 * 边界：message store 是全量权威缓存，MessageList 只是 DOM 投影。
 * - 首屏只渲染最近 20 条（方案 §4.1 验收项）；
 * - 向上滚动优先从缓存扩展（不请求网络），窗口到 200 条后按 50 条批次滑动；
 * - 触及缓存最早端才触发 onLoadMore（防重入）；
 * - pending 本地消息不计入 200 条服务端窗口、永不裁切；
 * - 前插后按 scrollHeight 差锚定，不跳顶不跳底；
 * - 非底部出现「回到底部」浮钮，点击回底并恢复实时跟随。
 *
 * 注意：jsdom 无真实布局，滚动几何（scrollTop/scrollHeight/clientHeight）需显式 mock。
 */
import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ChatMessage, ConversationSummary } from "../api/types";
import { MessageList } from "../components/chat/MessageList";
import { useAuthStore } from "../stores/auth";

vi.mock("../components/chat/MessageBubble", () => ({
  MessageBubble: ({ message }: { message: ChatMessage }) => (
    <div data-testid="bubble">{message.content}</div>
  ),
  canRecall: () => false,
}));
vi.mock("../utils/navigation", () => ({ goUserProfile: vi.fn() }));

function serverMessage(seq: number): ChatMessage {
  return {
    id: `m${seq}`,
    conversation_id: "c1",
    sender_id: "me",
    type: "text",
    content: `消息${seq}`,
    media_id: null,
    reply_to: null,
    status: "sent",
    seq,
    created_at: new Date(Date.UTC(2026, 0, 1, 0, 0, Math.floor(seq / 60), seq % 60)).toISOString(),
  };
}

function pendingMessage(localId: string): ChatMessage {
  return {
    id: localId,
    conversation_id: "c1",
    sender_id: "me",
    type: "text",
    content: `本地${localId}`,
    media_id: null,
    reply_to: null,
    status: "sent",
    seq: 0,
    created_at: new Date().toISOString(),
    pending: true,
  };
}

function conversation(): ConversationSummary {
  return {
    id: "c1",
    type: "group",
    title: "群",
    announcement: "",
    avatar: "",
    owner_id: "me",
    members: [],
    my_role: "member",
    member_count: 2,
    unread_count: 0,
    created_at: "2026-01-01T00:00:00Z",
    peer: null,
  };
}

interface MockScroller {
  setScrollHeight: (v: number) => void;
  getScrollTop: () => number;
  element: HTMLElement;
}

function makeScroller(container: HTMLElement, initialScrollHeight: number): MockScroller {
  const element = container.querySelector<HTMLElement>(".message-scroll");
  if (!element) throw new Error("message-scroll 未渲染");
  let scrollHeight = initialScrollHeight;
  let scrollTop = 0;
  Object.defineProperty(element, "scrollHeight", {
    get: () => scrollHeight,
    configurable: true,
  });
  Object.defineProperty(element, "clientHeight", { value: 600, configurable: true });
  Object.defineProperty(element, "scrollTop", {
    get: () => scrollTop,
    set: (v: number) => {
      scrollTop = v;
    },
    configurable: true,
  });
  return {
    setScrollHeight: (v: number) => {
      scrollHeight = v;
    },
    getScrollTop: () => scrollTop,
    element,
  };
}

function messageCount(container: HTMLElement): number {
  return container.querySelectorAll("[data-message-id]").length;
}

function seqsOf(container: HTMLElement): number[] {
  return Array.from(container.querySelectorAll("[data-message-seq]")).map((node) =>
    Number(node.getAttribute("data-message-seq")),
  );
}

afterEach(() => {
  useAuthStore.setState({ currentUser: null });
});

describe("MessageList U16 窗口化", () => {
  it("500 条缓存首屏只渲染最近 20 条（验收核心）", () => {
    const messages = Array.from({ length: 500 }, (_, i) => serverMessage(i + 1));
    const { container } = render(
      <MessageList
        messages={messages}
        conversation={conversation()}
        elysiaUserId={null}
        hasMore={false}
        loading={false}
        onLoadMore={vi.fn()}
      />,
    );
    expect(messageCount(container)).toBe(20);
    const seqs = seqsOf(container);
    expect(seqs[0]).toBe(481);
    expect(seqs[seqs.length - 1]).toBe(500);
    expect(screen.queryByText("消息480")).not.toBeInTheDocument();
  });

  it("向上滚动优先扩展缓存，窗口到 200 条后按 50 条批次滑动且不请求网络", () => {
    const onLoadMore = vi.fn();
    const messages = Array.from({ length: 500 }, (_, i) => serverMessage(i + 1));
    const { container } = render(
      <MessageList
        messages={messages}
        conversation={conversation()}
        elysiaUserId={null}
        hasMore={false}
        loading={false}
        onLoadMore={onLoadMore}
      />,
    );
    const scroller = makeScroller(container, 2000);

    // 连续向上触顶 6 次：20 → 70 → 120 → 170 → 200 → 200（批次滑动）
    for (let i = 0; i < 6; i += 1) {
      act(() => {
        scroller.element.scrollTop = 0;
        fireEvent.scroll(scroller.element);
      });
    }

    expect(messageCount(container)).toBe(200);
    const seqs = seqsOf(container);
    // 从尾部 20 扩散满 200 后，继续上翻会从头部/尾部各按 50 滑动：最终范围 [181, 380)
    expect(seqs).toHaveLength(200);
    expect(seqs[0]).toBe(181);
    expect(seqs[seqs.length - 1]).toBe(380);
    expect(onLoadMore).not.toHaveBeenCalled();
  });

  it("触及缓存最早端才走 onLoadMore，且同一在途请求防重入", async () => {
    const onLoadMore = vi.fn(() => new Promise<void>(() => {})); // 永不 resolve，保持 in-flight
    const messages = Array.from({ length: 20 }, (_, i) => serverMessage(i + 1));
    const { container } = render(
      <MessageList
        messages={messages}
        conversation={conversation()}
        elysiaUserId={null}
        hasMore
        loading={false}
        onLoadMore={onLoadMore}
      />,
    );
    const scroller = makeScroller(container, 2000);

    await act(async () => {
      scroller.element.scrollTop = 0;
      fireEvent.scroll(scroller.element);
    });
    expect(onLoadMore).toHaveBeenCalledTimes(1);

    // 加载完成前继续滚动到顶：不重复触发（onLoadMore 仍在 in-flight，pendingAnchor 未释放）
    await act(async () => {
      scroller.element.scrollTop = 0;
      fireEvent.scroll(scroller.element);
    });
    expect(onLoadMore).toHaveBeenCalledTimes(1);
  });

  it("pending 本地消息不计入 200 条窗口、永不裁切", () => {
    const messages = [
      ...Array.from({ length: 500 }, (_, i) => serverMessage(i + 1)),
      pendingMessage("local-a"),
      pendingMessage("local-b"),
    ];
    const { container } = render(
      <MessageList
        messages={messages}
        conversation={conversation()}
        elysiaUserId={null}
        hasMore={false}
        loading={false}
        onLoadMore={vi.fn()}
      />,
    );
    // 首屏 20 确认 + 2 pending 恒在尾部
    expect(screen.getByText("本地local-a")).toBeInTheDocument();
    expect(screen.getByText("本地local-b")).toBeInTheDocument();

    // 反复向上翻页把确认窗口扩到 200，pending 仍在
    const scroller = makeScroller(container, 2000);
    for (let i = 0; i < 10; i += 1) {
      act(() => {
        scroller.element.scrollTop = 0;
        fireEvent.scroll(scroller.element);
      });
    }
    expect(messageCount(container)).toBe(202); // 200 确认 + 2 pending
    expect(screen.getByText("本地local-a")).toBeInTheDocument();
    expect(screen.getByText("本地local-b")).toBeInTheDocument();
  });

  it("向上插入更早消息后按 scrollHeight 差补偿，不跳底", async () => {
    const messages20 = Array.from({ length: 20 }, (_, i) => serverMessage(481 + i));
    const onLoadMore = vi.fn();
    const { container, rerender } = render(
      <MessageList
        messages={messages20}
        conversation={conversation()}
        elysiaUserId={null}
        hasMore
        loading={false}
        onLoadMore={onLoadMore}
      />,
    );
    const scroller = makeScroller(container, 1000);

    // 用户向上阅读：停在离底一段距离的位置（触发预加载锚定）
    await act(async () => {
      scroller.element.scrollTop = 120;
      fireEvent.scroll(scroller.element);
    });
    expect(onLoadMore).toHaveBeenCalledTimes(1);

    // 模拟历史前插 50 条更早消息 + 滚动高度 +450
    const messages70 = [
      ...Array.from({ length: 50 }, (_, i) => serverMessage(431 + i)),
      ...messages20,
    ];
    await act(async () => {
      scroller.setScrollHeight(1450);
      rerender(
        <MessageList
          messages={messages70}
          conversation={conversation()}
          elysiaUserId={null}
          hasMore
          loading={false}
          onLoadMore={onLoadMore}
        />,
      );
    });

    // 视口内容不跳：scrollTop 补偿为 120 + (1450 - 1000) = 570
    expect(scroller.getScrollTop()).toBe(570);
  });

  it("缓存超 200 且窗口上滑离开尾部后出现回到底部浮钮，点击回底并隐藏", async () => {
    const messages = Array.from({ length: 500 }, (_, i) => serverMessage(1 + i));
    const { container } = render(
      <MessageList
        messages={messages}
        conversation={conversation()}
        elysiaUserId={null}
        hasMore={false}
        loading={false}
        onLoadMore={vi.fn()}
      />,
    );
    const scroller = makeScroller(container, 2400);

    // 连续向上翻页，直到窗口尾部离开最新消息（hasHiddenTail=true）
    const jumpButton = document.querySelector<HTMLElement>(".message-jump-bottom");
    expect(jumpButton).not.toBeNull();
    for (let i = 0; i < 12; i += 1) {
      await act(async () => {
        scroller.element.scrollTop = 0;
        fireEvent.scroll(scroller.element);
      });
      if (jumpButton?.getAttribute("aria-hidden") === "false") break;
    }

    expect(jumpButton?.getAttribute("aria-hidden")).toBe("false");

    await act(async () => {
      jumpButton?.click();
    });

    // 窗口回到最新尾段，浮钮隐藏
    expect(jumpButton?.getAttribute("aria-hidden")).toBe("true");
    const seqs = seqsOf(container);
    expect(seqs[seqs.length - 1]).toBe(500);
  });
});