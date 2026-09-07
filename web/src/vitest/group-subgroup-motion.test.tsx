import { useAuthStore } from "../stores/auth";
import { disposeSocialTracking } from "../stores/social";
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { StrictMode } from "react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as chatApi from "../api/chat";
import type { ChatMessage, ConversationSummary, SubGroup } from "../api/types";
import { GroupChat } from "../pages/group/GroupChat";
import { loadHistory, messageInSubgroup } from "../hooks/useChat";
import { useChatStore } from "../stores/chat";
import { useMessageStore } from "../stores/message";
import { useSubGroupStore } from "../stores/subgroup";

vi.mock("../api/chat", () => ({
  listSubgroups: vi.fn(() => Promise.resolve(groups())),
  getConversationMetadata: vi.fn(async () => conversation),
  listSubgroupsPage: vi.fn(async (id: string) => { const results = await chatApi.listSubgroups(id); return { results, total: results.length, has_more: false, next_cursor: null, default: results.find((row) => row.is_default) ?? null }; }),
}));
vi.mock("../api/elysia", () => ({ getElysiaProfile: vi.fn(() => new Promise(() => {})) }));
vi.mock("../ws/chat", () => ({ chatWS: { subscribe: vi.fn() } }));
vi.mock("../hooks/useChat", async () => ({
  messageInSubgroup: (await vi.importActual<typeof import("../hooks/useChat")>("../hooks/useChat")).messageInSubgroup,
  loadHistory: vi.fn(), loadMoreHistory: vi.fn(), loadHistoryUntilSeq: vi.fn(),
  markMessageReadExact: vi.fn(), recallMessage: vi.fn(), retryOptimistic: vi.fn(),
  removeOptimistic: vi.fn(), cancelOptimistic: vi.fn(), TARGET_HISTORY_MAX_PAGES: 10,
}));
vi.mock("../components/chat/MessageList", () => ({
  MessageList: ({ messages, subgroupId, isDefaultSubgroup }: { messages: ChatMessage[]; subgroupId?: string | null; isDefaultSubgroup?: boolean }) => (
    <div className="message-list"><div className="message-scroll">{messages.filter((item) => messageInSubgroup(item, subgroupId, isDefaultSubgroup)).map((item) => <p key={item.id} data-message-id={item.id}>{item.content}</p>)}</div></div>
  ),
}));
vi.mock("../components/chat/MessageInput", async () => {
  const { forwardRef } = await import("react");
  return { MessageInput: forwardRef<HTMLTextAreaElement>((_props, ref) => <div className="composer"><textarea ref={ref} aria-label="群聊草稿" /></div>) };
});

function groups(): SubGroup[] {
  return ["1", "2", "3"].map((id) => ({ id, conversation_id: "g", name: `子群${id}`, is_default: id === "1", unread_count: 0, created_at: "2026-09-08T00:00:00Z" }));
}
function message(subgroupId: string, seq: number, content: string): ChatMessage {
  return { id: `m${seq}`, conversation_id: "g", sender_id: "me", type: "text", content, subgroup_id: subgroupId, seq, media_id: null, reply_to: null, status: "sent", created_at: "2026-09-08T00:00:00Z" };
}
const conversation: ConversationSummary = { id: "g", type: "group", title: "群", announcement: "", avatar: "", owner_id: "me", members: [], my_role: "owner", member_count: 1, unread_count: 0, created_at: "2026-09-08T00:00:00Z", peer: null };
const originalAnimate = Object.getOwnPropertyDescriptor(HTMLElement.prototype, "animate");
let requests: Map<string, () => void>;
let played: Array<{ node: HTMLElement; text: string; cancel: ReturnType<typeof vi.fn> }>;
let composerPlayed: Array<{ node: HTMLElement; frames: Keyframe[]; options: KeyframeAnimationOptions; cancel: ReturnType<typeof vi.fn> }>;
let reduce: (next: boolean) => void;

beforeEach(() => {
  disposeSocialTracking();
  useAuthStore.setState({ currentUser: { id: "me", username: "me", nickname: "", avatar: "", signature: "", status: "auto", online: false, date_joined: "" }, accessToken: "test" });
  let reduced = false;
  const listeners = new Set<() => void>();
  vi.stubGlobal("matchMedia", vi.fn((query: string) => ({
    get matches() { return query.includes("prefers-reduced-motion") && reduced; },
    addEventListener: (_event: string, cb: () => void) => listeners.add(cb),
    removeEventListener: (_event: string, cb: () => void) => listeners.delete(cb),
  })));
  reduce = (next) => act(() => { reduced = next; Array.from(listeners).forEach((listener) => listener()); });
  requests = new Map();
  vi.mocked(chatApi.listSubgroups).mockReset().mockResolvedValue(groups());
  vi.mocked(loadHistory).mockReset().mockImplementation((_id, _before, _first, subgroupId) => subgroupId === "1" ? Promise.resolve() : new Promise((resolve) => requests.set(String(subgroupId), resolve)));
  useChatStore.setState({ conversations: [conversation], activeConversationId: null });
  useSubGroupStore.setState({ byGroup: { g: groups() }, activeByGroup: { g: "1" } });
  useMessageStore.getState().reset();
  useMessageStore.getState().upsertMessage("g", message("1", 1, "默认组正文"));
  played = [];
  composerPlayed = [];
  Object.defineProperty(HTMLElement.prototype, "animate", { configurable: true, value: function(this: HTMLElement, keyframes: Keyframe[], options: KeyframeAnimationOptions) {
    if (this.matches(".composer")) {
      const record = { node: this, frames: keyframes, options, cancel: vi.fn() };
      composerPlayed.push(record);
      return { cancel: record.cancel };
    }
    const record = { node: this, text: this.textContent ?? "", cancel: vi.fn() };
    played.push(record);
    return { cancel: record.cancel };
  } });
});

afterEach(() => {
  vi.unstubAllGlobals();
  if (originalAnimate) Object.defineProperty(HTMLElement.prototype, "animate", originalAnimate);
  else Reflect.deleteProperty(HTMLElement.prototype, "animate");
});

async function renderChat() {
  const view = render(<MemoryRouter><GroupChat groupId="g" /></MemoryRouter>);
  await waitFor(() => expect(loadHistory).toHaveBeenCalledWith("g", undefined, true, "1", true));
  await act(async () => {});
  return view;
}
function select(id: string) { act(() => useSubGroupStore.getState().setActiveSubgroup("g", id)); }
async function finish(id: string, content: string, seq: number) {
  await act(async () => {
    useMessageStore.getState().prependHistory("g", [message(id, seq, content)], false);
    requests.get(id)!();
  });
}

describe("子群消息面板以实际可见内容触发过渡", () => {
  it.each([false, true])("异步默认子群只建立选择基线，首次群面板不叠第二次位移（StrictMode=%s）", async (strict) => {
    let resolveSubgroups!: (items: SubGroup[]) => void;
    const pendingSubgroups = new Promise<SubGroup[]>((resolve) => { resolveSubgroups = resolve; });
    vi.mocked(chatApi.listSubgroups).mockReturnValue(pendingSubgroups);
    useSubGroupStore.setState({ byGroup: {}, activeByGroup: {} });
    useMessageStore.getState().upsertMessage("g", message("2", 2, "第二组缓存"));
    const content = <MemoryRouter><GroupChat groupId="g" /></MemoryRouter>;
    render(strict ? <StrictMode>{content}</StrictMode> : content);
    expect(useSubGroupStore.getState().activeByGroup.g).toBeUndefined();
    expect(played).toHaveLength(0);
    expect(composerPlayed).toHaveLength(0);
    await act(async () => resolveSubgroups(groups()));
    await waitFor(() => expect(loadHistory).toHaveBeenCalledWith("g", undefined, true, "1", true));
    expect(useSubGroupStore.getState().activeByGroup.g).toBe("1");
    expect(played).toHaveLength(0);
    expect(composerPlayed).toHaveLength(0);
    select("2");
    expect(played).toHaveLength(1);
    expect(composerPlayed).toHaveLength(1);
  });

  it("输入框同一节点先向下退出再进入，快切取消旧过渡且保留草稿焦点", async () => {
    const { container } = await renderChat();
    const input = screen.getByRole("textbox", { name: "群聊草稿" });
    const composer = container.querySelector(".composer");
    const owner = container.querySelector(".group-chat-compose-area");
    fireEvent.change(input, { target: { value: "输入中的草稿" } });
    input.focus();
    expect(composerPlayed).toHaveLength(0);
    select("2");
    expect(composerPlayed).toHaveLength(1);
    expect(composerPlayed[0].node).toBe(composer);
    expect(composerPlayed[0].frames[1]).toMatchObject({ opacity: 0, transform: "translateY(20px)", offset: 0.5 });
    expect(composerPlayed[0].frames[2]).toMatchObject({ opacity: 1, transform: "translateY(0)", offset: 1 });
    expect(composerPlayed[0].options.duration).toBe(600);
    select("3");
    expect(composerPlayed).toHaveLength(2);
    expect(composerPlayed[0].cancel).toHaveBeenCalledTimes(1);
    expect(container.querySelector(".group-chat-compose-area")).toBe(owner);
    expect(container.querySelector(".composer")).toBe(composer);
    expect(screen.getByRole("textbox", { name: "群聊草稿" })).toBe(input);
    expect(input).toHaveValue("输入中的草稿");
    expect(input).toHaveFocus();
    expect(owner).toHaveAttribute("data-subgroup-composer-owner", "g:3");
    reduce(true);
    expect(composerPlayed[1].cancel).toHaveBeenCalledTimes(1);
    select("1");
    await act(async () => {});
    expect(composerPlayed).toHaveLength(2);
    expect(input).toHaveFocus();
  });

  it("缓存命中时立即动画当前列表，保留草稿焦点，不为日常新消息重播", async () => {
    useMessageStore.getState().upsertMessage("g", message("2", 2, "缓存子群二正文"));
    const { container } = await renderChat();
    const input = screen.getByRole("textbox", { name: "群聊草稿" });
    fireEvent.change(input, { target: { value: "还未发送" } });
    input.focus();
    const owner = container.querySelector(".chat-messages-motion");
    expect(played).toHaveLength(0);
    select("2");
    expect(played).toHaveLength(1);
    expect(played[0].node).toBe(container.querySelector(".message-list"));
    expect(played[0].text).toContain("缓存子群二正文");
    expect(played[0].text).not.toContain("默认组正文");
    expect(container.querySelector(".chat-messages-motion")).toBe(owner);
    expect(screen.getByRole("textbox", { name: "群聊草稿" })).toBe(input);
    expect(input).toHaveValue("还未发送");
    expect(input).toHaveFocus();
    act(() => useMessageStore.getState().upsertMessage("g", message("2", 3, "日常新消息")));
    expect(played).toHaveLength(1);
  });

  it("未缓存时等新正文就绪，快速切组的旧请求不能提前消耗新组动画", async () => {
    const { container } = await renderChat();
    const input = screen.getByRole("textbox", { name: "群聊草稿" });
    fireEvent.change(input, { target: { value: "快切也保留" } });
    select("2");
    expect(played).toHaveLength(0);
    select("3");
    await finish("2", "迟到的子群二", 2);
    expect(played).toHaveLength(0);
    expect(container.querySelector(".message-list")).not.toHaveTextContent("迟到的子群二");
    await finish("3", "当前子群三正文", 3);
    expect(played).toHaveLength(1);
    expect(played[0].text).toContain("当前子群三正文");
    expect(played[0].text).not.toContain("迟到的子群二");
    expect(screen.getByRole("textbox", { name: "群聊草稿" })).toBe(input);
    expect(input).toHaveValue("快切也保留");
  });

  it("等待时开启reduced不补播，当前动画可取消且后续消息仍正常显示", async () => {
    await renderChat();
    select("2");
    reduce(true);
    await finish("2", "减弱动态时到达", 2);
    expect(screen.getByText("减弱动态时到达")).toBeInTheDocument();
    expect(played).toHaveLength(0);
    reduce(false);
    expect(played).toHaveLength(0);
    select("1");
    await act(async () => {});
    expect(played).toHaveLength(1);
    reduce(true);
    expect(played[0].cancel).toHaveBeenCalledTimes(1);
    act(() => useMessageStore.getState().upsertMessage("g", message("1", 4, "继续收到消息")));
    expect(screen.getByText("继续收到消息")).toBeInTheDocument();
    expect(played).toHaveLength(1);
  });
});
