import { useState } from "react";
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { VisibilitySelector } from "../components/VisibilitySelector";
import { useAuthStore } from "../stores/auth";
import { useChatStore } from "../stores/chat";
import { disposeSocialTracking } from "../stores/social";
import * as chatApi from "../api/chat";
import type { ConversationSummary, UserPublic } from "../api/types";

vi.mock("../api/chat", () => ({ listConversationsPage: vi.fn(), listConversations: vi.fn() }));
const group = (id: string, title: string): ConversationSummary => ({ id, type: "group", title, announcement: "", avatar: "", owner_id: "me", members: [], member_count: 1, unread_count: 0, my_role: "member", created_at: "", peer: null });
const page = (results: ConversationSummary[], next: string | null = null) => ({ results, total: next ? 31 : results.length, has_more: !!next, next_cursor: next });
function Selection({ initial = [] as string[], locked = false }) {
  const [ids, setIds] = useState(initial);
  return <VisibilitySelector value={{ public: false, friends: false, group: true }} onChange={vi.fn()} selectedGroupIds={ids} onSelectedGroupIdsChange={setIds} initialGroupId={locked ? initial[0] : undefined} lockGroup={locked} />;
}
beforeEach(() => {
  disposeSocialTracking(); useChatStore.getState().reset(); vi.clearAllMocks();
  useAuthStore.setState({ currentUser: { id: "me" } as UserPublic, accessToken: "test" });
});
afterEach(() => { disposeSocialTracking(); useAuthStore.setState({ currentUser: null, accessToken: null }); });

describe("VisibilitySelector actual pages", () => {
  it("loads the first bounded page and reaches another page without fetching the legacy array", async () => {
    vi.mocked(chatApi.listConversationsPage).mockResolvedValueOnce(page([group("1", "第一页")], "second"))
      .mockResolvedValueOnce(page([group("31", "第三十一群")]));
    render(<Selection />);
    expect(await screen.findByText("第一页")).toBeInTheDocument();
    expect(screen.queryByText("第三十一群")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "加载更多" }));
    expect(await screen.findByText("第三十一群")).toBeInTheDocument();
    expect(chatApi.listConversationsPage).toHaveBeenLastCalledWith(expect.objectContaining({ cursor: "second", type: "group", limit: 30 }));
    expect(chatApi.listConversations).not.toHaveBeenCalled();
  });
  it("keeps selections while a server-side search replaces candidates", async () => {
    vi.mocked(chatApi.listConversationsPage).mockResolvedValueOnce(page([group("1", "已选的群")]))
      .mockResolvedValueOnce(page([group("99", "远处的群")]));
    render(<Selection />);
    fireEvent.click(await screen.findByLabelText("已选的群"));
    fireEvent.change(screen.getByRole("textbox", { name: "搜索群" }), { target: { value: "远处" } });
    expect(await screen.findByText("远处的群")).toBeInTheDocument();
    expect(within(screen.getByLabelText("已选群")).getByText("已选的群")).toBeInTheDocument();
    expect(chatApi.listConversationsPage).toHaveBeenLastCalledWith(expect.objectContaining({ q: "远处", cursor: null }));
  });
  it("exposes a failure silently and does not claim no matching groups", async () => {
    // bcb00dc 起失败静默：无错误文案、无重试按钮，也不显示"没有匹配的群"；
    // 搜索变化触发重新加载 → 成功显示恢复的群。
    vi.mocked(chatApi.listConversationsPage).mockRejectedValueOnce(new Error("群目录断网"))
      .mockResolvedValueOnce(page([group("1", "恢复的群")]));
    render(<Selection />);
    await waitFor(() => expect(chatApi.listConversationsPage).toHaveBeenCalled());
    expect(screen.queryByText("群目录断网")).not.toBeInTheDocument();
    expect(screen.queryByText("没有匹配的群")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "重试" })).not.toBeInTheDocument();
    fireEvent.change(screen.getByRole("textbox", { name: "搜索群" }), { target: { value: "恢复" } });
    expect(await screen.findByText("恢复的群")).toBeInTheDocument();
  });
  it("shows the successful empty state only after the response", async () => {
    let finish!: (value: ReturnType<typeof page>) => void;
    vi.mocked(chatApi.listConversationsPage).mockReturnValueOnce(new Promise((resolve) => { finish = resolve; }));
    render(<Selection />);
    expect(screen.queryByText("没有匹配的群")).not.toBeInTheDocument();
    await waitFor(() => expect(chatApi.listConversationsPage).toHaveBeenCalled());
    finish(page([]));
    expect(await screen.findByText("没有匹配的群")).toBeInTheDocument();
  });
  it("does not interpret a descriptor cache as the complete group collection", async () => {
    useChatStore.getState().setConversations([group("cached", "缓存群")]);
    vi.mocked(chatApi.listConversationsPage).mockResolvedValueOnce(page([group("new", "服务端第一页")]));
    render(<Selection />);
    expect(await screen.findByText("服务端第一页")).toBeInTheDocument();
    expect(chatApi.listConversationsPage).toHaveBeenCalledTimes(1);
  });
  it("preserves a locked initial selection even when it lies beyond the first page", async () => {
    vi.mocked(chatApi.listConversationsPage).mockResolvedValueOnce(page([group("1", "第一页")], "second"));
    render(<Selection initial={["999"]} locked />);
    expect(await screen.findByText("第一页")).toBeInTheDocument();
    expect(within(screen.getByLabelText("已选群")).getByText("群 999")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "取消选择群 999" })).not.toBeInTheDocument();
  });
});
