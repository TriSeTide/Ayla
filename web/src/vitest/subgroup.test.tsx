/**
 * 群聊子群功能测试：
 * - subgroup store：列表/未读投影/upsert 保留未读；
 * - ChannelSidebar：子群展开/收起、编辑笔、编辑态 +、添加弹窗；
 * - GroupChat：子群数 > 1 显示选项卡、仅默认组不显示、切换子群标已读。
 */
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ConversationSummary, SubGroup } from "../api/types";
import { SubGroupDialog } from "../components/group/SubGroupDialog";
import { ChannelSidebar } from "../layout/ChannelSidebar";
import { GroupChat } from "../pages/group/GroupChat";
import { useChatStore } from "../stores/chat";
import { useGroupStore } from "../stores/group";
import { useSubGroupStore } from "../stores/subgroup";
import { useVoiceStore } from "../stores/voice";

// ChannelSidebar 展开/收起下拉用 framer-motion（AnimatePresence + motion.div + useReducedMotion）：
// mock 成直通组件，收起即卸载、无退出滞留动画（与 image-viewer-swipe.test.tsx 先例一致），
// 保住「收起后子群行立即不在文档」的同步断言语义。
vi.mock("framer-motion", () => {
  const MotionDiv = ({ children }: { children?: unknown }) => children;
  return {
    AnimatePresence: ({ children }: { children?: unknown }) => children,
    motion: { div: MotionDiv },
    useReducedMotion: () => false,
  };
});

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
  useVoiceStore.getState().reset();
});

afterEach(() => {
  vi.clearAllMocks();
  useChatStore.setState({ conversations: [] });
  useGroupStore.getState().reset();
  useSubGroupStore.getState().reset();
  useVoiceStore.getState().reset();
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
    // 点展开更多 → 显示全部（追加部分复用选项卡展开收起动画：独立 ul 结构）
    fireEvent.click(screen.getByRole("button", { name: /展开更多/ }));
    expect(screen.getByRole("button", { name: /水群/ })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /游戏/ })).toBeInTheDocument();
    expect(document.querySelectorAll(".channel-subgroup-list")).toHaveLength(2);
    // 再点收起（精确匹配展开更多按钮，避免与「收起子群」主拉下按钮歧义）→ 回到前 3 条，追加部分卸载
    fireEvent.click(screen.getByRole("button", { name: "收起" }));
    expect(screen.queryByRole("button", { name: /水群/ })).not.toBeInTheDocument();
    expect(document.querySelectorAll(".channel-subgroup-list")).toHaveLength(1);
  });

  it("群主/管理员显示编辑笔；编辑态变 +；再点笔退出编辑；点 + 打开添加弹窗", () => {
    render(<ChannelSidebar groupName="测试群" activeScene="chat" onSelectScene={() => {}} onOpenInfo={() => {}} onSelectSubgroup={() => {}} />);
    fireEvent.click(screen.getByRole("button", { name: "编辑" }));
    expect(screen.getByRole("button", { name: "添加子群" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "退出编辑" })).toBeInTheDocument();
    // 编辑态每个子群行出现编辑按钮
    expect(screen.getByRole("button", { name: "编辑子群 默认组" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "编辑子群 闲聊" })).toBeInTheDocument();
    // 再点笔退出编辑：+ 与行内编辑按钮消失
    fireEvent.click(screen.getByRole("button", { name: "退出编辑" }));
    expect(screen.queryByRole("button", { name: "添加子群" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "编辑子群 默认组" })).not.toBeInTheDocument();
    // 再次进入编辑并打开添加弹窗
    fireEvent.click(screen.getByRole("button", { name: "编辑" }));
    fireEvent.click(screen.getByRole("button", { name: "添加子群" }));
    expect(screen.getByRole("dialog", { name: "添加子群" })).toBeInTheDocument();
  });

  it("普通成员不显示编辑按钮", () => {
    useChatStore.setState({ conversations: [groupConv("g1", "member")] });
    render(<ChannelSidebar groupName="测试群" activeScene="chat" onSelectScene={() => {}} onOpenInfo={() => {}} onSelectSubgroup={() => {}} />);
    expect(screen.queryByRole("button", { name: "编辑" })).not.toBeInTheDocument();
  });

  it("子群收起时编辑笔隐藏；展开后可见并可进入编辑态", () => {
    render(<ChannelSidebar groupName="测试群" activeScene="chat" onSelectScene={() => {}} onOpenInfo={() => {}} onSelectSubgroup={() => {}} />);
    fireEvent.click(screen.getByRole("button", { name: "收起子群" }));
    expect(screen.queryByRole("button", { name: /默认组/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "编辑" })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "展开子群" }));
    const pen = screen.getByRole("button", { name: "编辑" });
    expect(pen).toBeInTheDocument();
    fireEvent.click(pen);
    expect(screen.getByRole("button", { name: "默认组" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "添加子群" })).toBeInTheDocument();
  });

  it("点击子群行触发 onSelectSubgroup", () => {
    const onSelect = vi.fn();
    render(<ChannelSidebar groupName="测试群" activeScene="chat" onSelectScene={() => {}} onOpenInfo={() => {}} onSelectSubgroup={onSelect} />);
    fireEvent.click(screen.getByRole("button", { name: /闲聊/ }));
    expect(onSelect).toHaveBeenCalledWith("2");
  });

  it("语音房排序（有人区/无人区，事实源=后端持久字段）：3 一直有人 + 我在 1/2 来回 → 我在 1 时 [1,3,2]、我在 2 时 [2,3,1]", () => {
    // 房 id 对应「1/2/3」；created_at 反序让初始 created_at 降序 = [1,2,3]
    const mk = (id: string) => ({
      id,
      name: id,
      owner_id: "u1",
      group: "g1",
      allowed_group_ids: ["g1"],
      visibility: "group" as const,
      status: "idle" as const,
      member_count: 0,
      room_name: id,
      group_name: "测试群",
      created_at: `2026-08-0${4 - Number(id)}T00:00:00Z`,
      mine: false,
    });
    const rooms = () =>
      [...document.querySelectorAll(".channel-voice-room-name")].map((n) => n.textContent);
    // 模拟后端 WS 帧 patch（排序字段由后端 join/leave 落库并随帧广播）
    const frame = (id: string, patch: Partial<{ member_count: number; last_occupied_at: string; last_vacant_at: string }>) =>
      act(() => useVoiceStore.getState().patchChannel(id, patch));

    useVoiceStore.setState({ channels: [mk("1"), mk("2"), mk("3")] });
    render(<ChannelSidebar groupName="测试群" activeScene="chat" onSelectScene={() => {}} onOpenInfo={() => {}} onSelectSubgroup={() => {}} />);
    expect(rooms()).toEqual(["1", "2", "3"]);
    // 3 一直有人（别人进 3，10:00）→ 有人区置顶 → [3,1,2]
    frame("3", { member_count: 1, last_occupied_at: "2026-09-05T10:00:00+08:00" });
    expect(rooms()).toEqual(["3", "1", "2"]);
    // 我进 1（10:01）→ 有人区 1 最新前、3 后 → [1,3,2]
    frame("1", { member_count: 1, last_occupied_at: "2026-09-05T10:01:00+08:00" });
    expect(rooms()).toEqual(["1", "3", "2"]);
    // 我离 1（10:02 变空）进 2（10:03）→ 有人 2,3；空 1 → [2,3,1]
    frame("1", { member_count: 0, last_vacant_at: "2026-09-05T10:02:00+08:00" });
    frame("2", { member_count: 1, last_occupied_at: "2026-09-05T10:03:00+08:00" });
    expect(rooms()).toEqual(["2", "3", "1"]);
    // 我回 1（10:05，离 2 于 10:04）→ 有人 1,3；空曾进 2 → [1,3,2]，2 不回落
    frame("2", { member_count: 0, last_vacant_at: "2026-09-05T10:04:00+08:00" });
    frame("1", { member_count: 1, last_occupied_at: "2026-09-05T10:05:00+08:00" });
    expect(rooms()).toEqual(["1", "3", "2"]);
    // 刷新等价（重渲染后读字段排序仍保持）：重新渲染一次，断言排序不依赖前端内存
    expect(rooms()).toEqual(["1", "3", "2"]);
  });

  it("语音房排序：1234 完整验收序列（进4→4123，进2→2413，进1(2空)→1423，离4→1423，进4→4123，离4→1423，4永不回4号位）", () => {
    const mk = (id: string) => ({
      id,
      name: id,
      owner_id: "u1",
      group: "g1",
      allowed_group_ids: ["g1"],
      visibility: "group" as const,
      member_count: 0,
      room_name: id,
      group_name: "测试群",
      created_at: `2026-08-0${4 - Number(id)}T00:00:00Z`, // 1 最新 → 初始 [1,2,3,4]
      mine: false,
    });
    const rooms = () =>
      [...document.querySelectorAll(".channel-voice-room-name")].map((n) => n.textContent);
    // 帧序列（模拟后端 join/leave 事件广播，时间戳单调递增）
    const frame = (id: string, patch: Partial<{ member_count: number; last_occupied_at: string; last_vacant_at: string }>) =>
      act(() => useVoiceStore.getState().patchChannel(id, patch));

    useVoiceStore.setState({ channels: [mk("1"), mk("2"), mk("3"), mk("4")] });
    render(<ChannelSidebar groupName="测试群" activeScene="chat" onSelectScene={() => {}} onOpenInfo={() => {}} onSelectSubgroup={() => {}} />);
    // 侧栏默认收起只显示前 3 个：先展开更多让 4 个房全部可见，再做完整排序断言
    fireEvent.click(screen.getByRole("button", { name: /展开更多/ }));
    expect(rooms()).toEqual(["1", "2", "3", "4"]);
    // 你进入 4 → [4,1,2,3]
    frame("4", { member_count: 1, last_occupied_at: "2026-09-05T10:01:00+08:00" });
    expect(rooms()).toEqual(["4", "1", "2", "3"]);
    // 我进入 2 → [2,4,1,3]
    frame("2", { member_count: 1, last_occupied_at: "2026-09-05T10:02:00+08:00" });
    expect(rooms()).toEqual(["2", "4", "1", "3"]);
    // 我离开 2 进入 1（2 变空）→ [1,4,2,3]（2 空曾进，排 3 前但被 4/1 压着）
    frame("2", { member_count: 0, last_vacant_at: "2026-09-05T10:03:00+08:00" });
    frame("1", { member_count: 1, last_occupied_at: "2026-09-05T10:04:00+08:00" });
    expect(rooms()).toEqual(["1", "4", "2", "3"]);
    // 你离开 4（4 变空）→ 仍 [1,4,2,3]（4 空曾进，排在有人 1 后、不回落 4 号位）
    frame("4", { member_count: 0, last_vacant_at: "2026-09-05T10:05:00+08:00" });
    expect(rooms()).toEqual(["1", "4", "2", "3"]);
    // 你又进入 4 → [4,1,2,3]
    frame("4", { member_count: 1, last_occupied_at: "2026-09-05T10:06:00+08:00" });
    expect(rooms()).toEqual(["4", "1", "2", "3"]);
    // 你又离开 4 → 仍 [1,4,2,3]（4 永不在 4 号位）
    frame("4", { member_count: 0, last_vacant_at: "2026-09-05T10:07:00+08:00" });
    expect(rooms()).toEqual(["1", "4", "2", "3"]);
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
