/**
 * 群聊子群功能测试：
 * - subgroup store：列表/未读投影/upsert 保留未读；
 * - ChannelSidebar：子群展开/收起、编辑按钮、编辑态 +/x、添加弹窗；
 * - GroupChat：子群数 > 1 显示选项卡、仅默认组不显示、切换子群标已读。
 */
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ConversationSummary, SubGroup } from "../api/types";
import { SubGroupDialog } from "../components/group/SubGroupDialog";
import { ChannelSidebar } from "../layout/ChannelSidebar";
import { GroupChat } from "../pages/group/GroupChat";
import { useChatStore } from "../stores/chat";
import { useGroupStore } from "../stores/group";
import { useSubGroupStore } from "../stores/subgroup";

function sg(id: string, name: string, isDefault = false, unread = 0): SubGroup {
  return {
    id,
    conversation_id: "g1",
    name,
    is_default: isDefault,
    unread_count: unread,
    unread_seqs: [],
    created_at: "2026-01-01T00:00:00Z",
  };
}

function groupConv(id: string, myRole: "owner" | "admin" | "member" = "owner"): ConversationSummary {
  return {
    id,
    type: "group",
    title: "测试群",
    announcement: "",
    avatar: "",
    owner_id: "o1",
    members: [],
    my_role: myRole,
    member_count: 3,
    unread_count: 0,
    created_at: "2026-01-01T00:00:00Z",
    peer: null,
  };
}

beforeEach(() => {
  useChatStore.setState({ conversations: [groupConv("g1")] });
  useGroupStore.setState({ currentGroupId: "g1", activeScene: "chat" });
  useSubGroupStore.setState({
    byGroup: { g1: [sg("1", "默认组", true), sg("2", "闲聊")] },
    activeByGroup: { g1: "1" },
    unreadByKey: { "g1:1": 0, "g1:2": 3 },
    unreadSeqsByKey: { "g1:1": [], "g1:2": [1, 2, 3] },
  });
});

afterEach(() => {
  vi.clearAllMocks();
  useChatStore.setState({ conversations: [] });
  useGroupStore.getState().reset();
  useSubGroupStore.getState().reset();
});

describe("subgroup store", () => {
  it("setSubgroups 同步未读投影；bump/clear 按子群独立", () => {
    const store = useSubGroupStore.getState();
    store.bumpSubgroupUnread("g1", "2", 4);
    expect(useSubGroupStore.getState().unreadByKey["g1:2"]).toBe(4);
    store.clearSubgroupUnread("g1", "2");
    expect(useSubGroupStore.getState().unreadByKey["g1:2"]).toBe(0);
    expect(useSubGroupStore.getState().unreadByKey["g1:1"]).toBe(0);
  });

  it("upsertSubgroup（WS 帧无未读）保留本地未读投影", () => {
    useSubGroupStore.getState().upsertSubgroup("g1", {
      ...sg("2", "闲聊改名"),
      unread_count: undefined as unknown as number,
      unread_seqs: undefined as unknown as number[],
    });
    const state = useSubGroupStore.getState();
    expect(state.byGroup.g1.find((s) => s.id === "2")?.name).toBe("闲聊改名");
    expect(state.unreadByKey["g1:2"]).toBe(3);
  });
});

describe("ChannelSidebar 子群", () => {
  it("默认展开子群列表；点三角形收起，再展开", () => {
    render(<ChannelSidebar groupName="测试群" activeScene="chat" onSelectScene={() => {}} onOpenInfo={() => {}} onSelectSubgroup={() => {}} />);
    // 默认展开：子群可见
    expect(screen.getByRole("button", { name: /默认组/ })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /闲聊/ })).toBeInTheDocument();
    expect(screen.getByLabelText("3 条未读")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "收起子群" }));
    expect(screen.queryByRole("button", { name: /默认组/ })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "展开子群" }));
    expect(screen.getByRole("button", { name: /默认组/ })).toBeInTheDocument();
  });

  it("子群超过 3 个时默认只显示 3 个，点「展开更多」显示全部", () => {
    useSubGroupStore.setState({
      byGroup: {
        g1: [
          sg("1", "默认组", true),
          sg("2", "闲聊"),
          sg("3", "公告"),
          sg("4", "水群"),
          sg("5", "游戏"),
        ],
      },
    });
    render(<ChannelSidebar groupName="测试群" activeScene="chat" onSelectScene={() => {}} onOpenInfo={() => {}} onSelectSubgroup={() => {}} />);
    // 默认只显示前 3 个
    expect(screen.getByRole("button", { name: /默认组/ })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /闲聊/ })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /公告/ })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /水群/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /游戏/ })).not.toBeInTheDocument();
    // 点展开更多 → 显示全部
    fireEvent.click(screen.getByRole("button", { name: /展开更多/ }));
    expect(screen.getByRole("button", { name: /水群/ })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /游戏/ })).toBeInTheDocument();
  });

  it("群主/管理员显示编辑按钮；编辑态变 +/x；点击 + 打开添加弹窗", () => {
    render(<ChannelSidebar groupName="测试群" activeScene="chat" onSelectScene={() => {}} onOpenInfo={() => {}} onSelectSubgroup={() => {}} />);
    fireEvent.click(screen.getByRole("button", { name: "编辑" }));
    expect(screen.getByRole("button", { name: "添加子群" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "退出编辑" })).toBeInTheDocument();
    // 编辑态每个子群行出现编辑按钮
    expect(screen.getByRole("button", { name: "编辑子群 默认组" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "编辑子群 闲聊" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "添加子群" }));
    expect(screen.getByRole("dialog", { name: "添加子群" })).toBeInTheDocument();
  });

  it("普通成员不显示编辑按钮", () => {
    useChatStore.setState({ conversations: [groupConv("g1", "member")] });
    render(<ChannelSidebar groupName="测试群" activeScene="chat" onSelectScene={() => {}} onOpenInfo={() => {}} onSelectSubgroup={() => {}} />);
    expect(screen.queryByRole("button", { name: "编辑" })).not.toBeInTheDocument();
  });

  it("点击子群行触发 onSelectSubgroup", () => {
    const onSelect = vi.fn();
    render(<ChannelSidebar groupName="测试群" activeScene="chat" onSelectScene={() => {}} onOpenInfo={() => {}} onSelectSubgroup={onSelect} />);
    fireEvent.click(screen.getByRole("button", { name: /闲聊/ }));
    expect(onSelect).toHaveBeenCalledWith("2");
  });
});

describe("SubGroupDialog 禁言开关", () => {
  it("编辑态显示禁言开关；确定时回传 muted", () => {
    const onConfirm = vi.fn();
    render(
      <SubGroupDialog
        state={{ kind: "edit", sg: { ...sg("2", "闲聊"), muted: true } }}
        busy={false}
        error={null}
        onClose={vi.fn()}
        onConfirm={onConfirm}
        onDelete={vi.fn()}
      />,
    );
    expect(screen.getByText("禁言该子群")).toBeInTheDocument();
    const checkbox = screen.getByRole("checkbox") as HTMLInputElement;
    expect(checkbox.checked).toBe(true);
    fireEvent.click(checkbox);
    fireEvent.click(screen.getByRole("button", { name: "确定" }));
    expect(onConfirm).toHaveBeenCalledWith("闲聊", false);
  });

  it("添加模式不显示禁言开关", () => {
    render(
      <SubGroupDialog
        state={{ kind: "add" }}
        busy={false}
        error={null}
        onClose={vi.fn()}
        onConfirm={vi.fn()}
        onDelete={vi.fn()}
      />,
    );
    expect(screen.queryByText("禁言该子群")).not.toBeInTheDocument();
  });
});

describe("GroupChat 子群选项卡", () => {
  vi.mock("../components/chat/MessageList", () => ({
    MessageList: () => <div>消息列表</div>,
  }));
  vi.mock("../components/chat/MessageInput", () => ({
    MessageInput: ({ disabled, disabledHint }: { disabled?: boolean; disabledHint?: string }) => (
      <div data-disabled={String(disabled)} data-hint={disabledHint ?? ""}>输入框</div>
    ),
  }));
  vi.mock("../api/chat", () => ({
    listSubgroups: vi.fn().mockResolvedValue([
      sg("1", "默认组", true),
      { ...sg("2", "闲聊"), unread_count: 3, unread_seqs: [1, 2, 3] },
    ]),
    sendPoke: vi.fn().mockResolvedValue({}),
  }));
  vi.mock("../api/elysia", () => ({
    getElysiaProfile: vi.fn().mockResolvedValue({ user: { id: "me" } }),
  }));
  vi.mock("../hooks/useChat", () => ({
    loadHistory: vi.fn().mockResolvedValue([]),
    loadMoreHistory: vi.fn().mockResolvedValue([]),
    loadHistoryUntilSeq: vi.fn().mockResolvedValue(true),
    markConversationReadThrough: vi.fn().mockResolvedValue(undefined),
    markMessageReadExact: vi.fn().mockResolvedValue(undefined),
    markSubgroupRead: vi.fn().mockResolvedValue(undefined),
    recallMessage: vi.fn().mockResolvedValue({}),
    retryOptimistic: vi.fn(),
    removeOptimistic: vi.fn(),
    cancelOptimistic: vi.fn(),
    TARGET_HISTORY_MAX_PAGES: 200,
  }));
  vi.mock("../ws/chat", () => ({
    chatWS: { subscribe: vi.fn() },
  }));

  // 选项卡仅窄屏显示：stub matchMedia 为窄屏
  beforeEach(() => {
    const mql = {
      matches: true,
      media: "(max-width: 768px)",
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      addListener: vi.fn(),
      removeListener: vi.fn(),
      onchange: null,
      dispatchEvent: vi.fn(),
    };
    vi.stubGlobal("matchMedia", vi.fn(() => mql));
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  // 渲染 GroupChat 并展开选项卡（默认收起，需先点半圆展开按钮）
  async function renderGroupChatExpanded() {
    render(<MemoryRouter><GroupChat groupId="g1" /></MemoryRouter>);
    await waitFor(() =>
      expect(screen.getByRole("button", { name: "展开子群选项卡" })).toBeInTheDocument(),
    );
    fireEvent.click(screen.getByRole("button", { name: "展开子群选项卡" }));
  }

  it("子群数 > 1 时输入框上方显示选项卡栏", async () => {
    await renderGroupChatExpanded();
    await waitFor(() => {
      expect(screen.getByRole("tablist", { name: "子群切换" })).toBeInTheDocument();
    });
    expect(screen.getByRole("tab", { name: /默认组/ })).toBeInTheDocument();
    expect(screen.getByRole("tab", { name: /闲聊/ })).toBeInTheDocument();
    expect(screen.getByLabelText("3 条未读")).toBeInTheDocument();
  });

  it("切换子群：更新 store 并标该子群已读", async () => {
    await renderGroupChatExpanded();
    await waitFor(() => {
      expect(screen.getByRole("tab", { name: /闲聊/ })).toBeInTheDocument();
    });
    fireEvent.click(screen.getByRole("tab", { name: /闲聊/ }));
    await waitFor(() => {
      expect(useSubGroupStore.getState().activeByGroup.g1).toBe("2");
    });
    const { markSubgroupRead } = await import("../hooks/useChat");
    expect(markSubgroupRead).toHaveBeenCalledWith("g1", "2");
  });

  it("禁言子群 + 普通成员 → 输入框禁用并显示提示", async () => {
    useChatStore.setState({ conversations: [groupConv("g1", "member")] });
    const { listSubgroups } = await import("../api/chat");
    vi.mocked(listSubgroups).mockResolvedValueOnce([
      sg("1", "默认组", true),
      { ...sg("2", "闲聊"), muted: true },
    ]);
    await renderGroupChatExpanded();
    await waitFor(() => {
      expect(screen.getByRole("tab", { name: /闲聊/ })).toBeInTheDocument();
    });
    fireEvent.click(screen.getByRole("tab", { name: /闲聊/ }));
    await waitFor(() => {
      expect(useSubGroupStore.getState().activeByGroup.g1).toBe("2");
    });
    const input = screen.getByText("输入框");
    expect(input.dataset.disabled).toBe("true");
    expect(input.dataset.hint).toBe("该子群已禁言，仅群主/管理员可发言");
  });

  it("禁言子群 + 群主 → 输入框不禁用", async () => {
    const { listSubgroups } = await import("../api/chat");
    vi.mocked(listSubgroups).mockResolvedValueOnce([
      sg("1", "默认组", true),
      { ...sg("2", "闲聊"), muted: true },
    ]);
    await renderGroupChatExpanded();
    await waitFor(() => {
      expect(screen.getByRole("tab", { name: /闲聊/ })).toBeInTheDocument();
    });
    fireEvent.click(screen.getByRole("tab", { name: /闲聊/ }));
    await waitFor(() => {
      expect(useSubGroupStore.getState().activeByGroup.g1).toBe("2");
    });
    expect(screen.getByText("输入框").dataset.disabled).toBe("false");
  });
});
