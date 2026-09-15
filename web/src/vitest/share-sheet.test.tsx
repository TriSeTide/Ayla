/**
 * ShareSheet 分享弹窗测试：
 * - 选项卡 群聊/私信 切换
 * - 群多子群 → 点击展开 → 选子群发送（sendMessage 携带 subgroup_id/share_payload）
 * - 群仅默认组 → 点击直接发送
 * - 私信发送；发送成功关闭弹窗
 * - 窄屏（375）为 is-narrow 60% 弹窗、宽屏（1440）为中央卡
 */
import { render, screen, waitFor } from "@testing-library/react";
import { fireEvent } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as chatApi from "../api/chat";
import { useAuthStore } from "../stores/auth";
import { useSocialStore } from "../stores/social";
import { ShareSheet } from "../components/share/ShareSheet";

vi.mock("../api/chat", () => ({
  listConversationsPage: vi.fn(),
  listSubgroups: vi.fn(),
  listSubgroupsPage: vi.fn(),
  sendMessage: vi.fn(),
}));

const PAYLOAD = { share_type: "live" as const, target_id: "lc9", title: "爱莉的直播间" };

function groupConv(id: string, title: string, unread = 0) {
  return {
    id,
    type: "group",
    title,
    avatar: "",
    unread_count: unread,
    member_count: 3,
    last_message: null,
    created_at: "2026-09-15T00:00:00Z",
  } as never;
}

function privateConv(id: string, title: string) {
  return {
    id,
    type: "private",
    title,
    unread_count: 0,
    peer: { id: `u-${id}`, nickname: title, username: title, avatar: null },
    last_message: null,
    created_at: "2026-09-15T00:00:00Z",
  } as never;
}

function pageOf(items: never[]) {
  return {
    results: items,
    total: items.length,
    has_more: false,
    next_cursor: null,
  };
}

async function flush() {
  await waitFor(() => expect((chatApi.listConversationsPage as ReturnType<typeof vi.fn>)).toHaveBeenCalled());
}

describe("ShareSheet", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    useAuthStore.setState({ currentUser: { id: "u-test", username: "tester", nickname: "测试" } as never });
    useSocialStore.getState().reset();
    (chatApi.listConversationsPage as unknown as ReturnType<typeof vi.fn>).mockImplementation(
      (params: { type?: string }) =>
        Promise.resolve(
          params?.type === "private"
            ? pageOf([privateConv("priv1", "小汐"), privateConv("priv2", "我自己")])
            : pageOf([groupConv("g1", "技术群", 3), groupConv("g2", "爱莉之家")]),
        ),
    );
    (chatApi.listSubgroups as unknown as ReturnType<typeof vi.fn>).mockImplementation((convId: string) =>
      Promise.resolve(
        convId === "g1"
          ? [
              { id: "11", name: "默认组", is_default: true, unread_count: 0 },
              { id: "12", name: "闲聊", is_default: false, unread_count: 2 },
            ]
          : [{ id: "21", name: "默认组", is_default: true, unread_count: 0 }],
      ),
    );
    (chatApi.sendMessage as unknown as ReturnType<typeof vi.fn>).mockResolvedValue({ id: "m9" });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("渲染弹窗：标题预览 + 选项卡 + 群聊列表（含未读数）", async () => {
    window.innerWidth = 1440;
    const onClose = vi.fn();
    render(<ShareSheet payload={PAYLOAD} onClose={onClose} />);
    await flush();
    expect(screen.getByText("爱莉的直播间")).toBeTruthy();
    expect(screen.getByRole("tab", { name: "群聊" })).toBeTruthy();
    expect(screen.getByRole("tab", { name: "私信" })).toBeTruthy();
    expect(screen.getByText("技术群")).toBeTruthy();
    expect(screen.getByText("爱莉之家")).toBeTruthy();
    expect(screen.getByText("3")).toBeTruthy(); // 未读数
  });

  it("多子群群项：点击展开子群，选子群发送并携带 subgroup_id 与 share_payload", async () => {
    window.innerWidth = 1440;
    const onClose = vi.fn();
    render(<ShareSheet payload={PAYLOAD} onClose={onClose} />);
    await flush();
    fireEvent.click(screen.getByRole("button", { name: /分享到群聊 技术群/ }));
    await waitFor(() => expect(screen.getByRole("button", { name: /分享到 技术群 的 闲聊/ })).toBeTruthy());
    fireEvent.click(screen.getByRole("button", { name: /分享到 技术群 的 闲聊/ }));
    await waitFor(() =>
      expect(chatApi.sendMessage).toHaveBeenCalledWith("g1", {
        type: "share",
        content: "[分享]爱莉的直播间",
        share_payload: PAYLOAD,
        subgroup_id: 12,
      }),
    );
    expect(onClose).toHaveBeenCalled();
  });

  it("仅默认组的群：点击群项直接发送（无 subgroup_id）", async () => {
    window.innerWidth = 1440;
    const onClose = vi.fn();
    render(<ShareSheet payload={PAYLOAD} onClose={onClose} />);
    await flush();
    fireEvent.click(screen.getByRole("button", { name: /分享到群聊 爱莉之家/ }));
    await waitFor(() =>
      expect(chatApi.sendMessage).toHaveBeenCalledWith("g2", {
        type: "share",
        content: "[分享]爱莉的直播间",
        share_payload: PAYLOAD,
        subgroup_id: undefined,
      }),
    );
    expect(onClose).toHaveBeenCalled();
  });

  it("私信选项卡：列表渲染，点击发送（私聊无 subgroup_id）", async () => {
    window.innerWidth = 1440;
    const onClose = vi.fn();
    render(<ShareSheet payload={PAYLOAD} onClose={onClose} />);
    await flush();
    fireEvent.click(screen.getByRole("tab", { name: "私信" }));
    await waitFor(() => expect(screen.getByText("小汐")).toBeTruthy());
    fireEvent.click(screen.getByRole("button", { name: /分享给 小汐/ }));
    await waitFor(() =>
      expect(chatApi.sendMessage).toHaveBeenCalledWith("priv1", {
        type: "share",
        content: "[分享]爱莉的直播间",
        share_payload: PAYLOAD,
        subgroup_id: undefined,
      }),
    );
    expect(onClose).toHaveBeenCalled();
  });

  it("发送失败显示错误且不关闭", async () => {
    window.innerWidth = 1440;
    const onClose = vi.fn();
    (chatApi.sendMessage as unknown as ReturnType<typeof vi.fn>).mockRejectedValue(new Error("发送失败"));
    render(<ShareSheet payload={PAYLOAD} onClose={onClose} />);
    await flush();
    fireEvent.click(screen.getByRole("button", { name: /分享到群聊 爱莉之家/ }));
    await waitFor(() => expect(screen.getByText("发送失败")).toBeTruthy());
    expect(onClose).not.toHaveBeenCalled();
  });

  it("关闭按钮与遮罩关闭", async () => {
    window.innerWidth = 1440;
    const onClose = vi.fn();
    render(<ShareSheet payload={PAYLOAD} onClose={onClose} />);
    await flush();
    const overlay = document.querySelector(".share-sheet-overlay");
    expect(overlay).toBeTruthy();
    fireEvent.click(overlay as HTMLElement);
    expect(onClose).toHaveBeenCalled();
  });

  it("窄屏（innerWidth=375）卡片带 is-narrow（60% 下半屏）；宽屏（1440）为中央卡", async () => {
    window.innerWidth = 375;
    const { unmount } = render(<ShareSheet payload={PAYLOAD} onClose={vi.fn()} />);
    await flush();
    const cardNarrow = document.querySelector(".share-sheet-card");
    expect(cardNarrow?.classList.contains("is-narrow")).toBe(true);
    expect((cardNarrow as HTMLElement).style.transform).not.toContain("translateX");
    unmount();

    window.innerWidth = 1440;
    render(<ShareSheet payload={PAYLOAD} onClose={vi.fn()} />);
    await flush();
    const cardWide = document.querySelector(".share-sheet-card");
    expect(cardWide?.classList.contains("is-narrow")).toBe(false);
  });
});
