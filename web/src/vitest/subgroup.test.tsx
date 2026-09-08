import { useAuthStore } from "../stores/auth";
import * as chatApi from "../api/chat";
import { disposeSocialTracking } from "../stores/social";
/**
 * 群聊子群功能测试：
 * - subgroup store：列表/未读投影/upsert 保留未读；
 * - ChannelSidebar：子群展开/收起、编辑笔、编辑态 +、添加弹窗；
 * - GroupChat：子群数 > 1 显示选项卡、切换不整组已读，可见消息精确确认。
 */
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ChatMessage, ConversationSummary, SubGroup } from "../api/types";
import { SubGroupDialog } from "../components/group/SubGroupDialog";
import { MessageList } from "../components/chat/MessageList";
import { ChannelSidebar } from "../layout/ChannelSidebar";
import { GroupChat } from "../pages/group/GroupChat";
import { useChatStore } from "../stores/chat";
import { useGroupStore } from "../stores/group";
import { useMessageStore } from "../stores/message";
import { sortSubgroupsByActivity, useSubGroupStore } from "../stores/subgroup";
import { useVoiceStore } from "../stores/voice";
import { disposeDirectoryTracking } from "../stores/directory";
import type { DirectoryParams } from "../api/directory";

vi.mock("../api/voice", async () => ({
  ...(await vi.importActual<typeof import("../api/voice")>("../api/voice")),
  listVoiceChannelsPage: vi.fn(async (params: DirectoryParams) => {
    const results = useVoiceStore.getState().channels.filter((item) => !params.groupId || (item.allowed_group_ids ?? []).includes(params.groupId));
    return { results, next_cursor: null, has_more: false, total: results.length, total_member_count: results.reduce((sum, item) => sum + item.member_count, 0) };
  }),
}));
vi.mock("../api/live", async () => ({
  ...(await vi.importActual<typeof import("../api/live")>("../api/live")),
  listLiveChannelsPage: vi.fn(async () => ({ results: [], next_cursor: null, has_more: false, total: 0 })),
}));

// ChannelSidebar 展开/收起下拉用 framer-motion（AnimatePresence + motion.div + useReducedMotion）：
// mock 成直通组件，收起即卸载、无退出滞留动画（与 image-viewer-swipe.test.tsx 先例一致），
// 保住「收起后子群行立即不在文档」的同步断言语义。
vi.mock("framer-motion", async () => {
  const { createElement, forwardRef } = await import("react");
  const { isValidMotionProp } = await vi.importActual<typeof import("framer-motion")>("framer-motion");
  const surface = (tag: "div" | "span" | "aside" | "ul" | "li" | "button") => forwardRef<HTMLElement, Record<string, unknown>>(({ children, ...props }, ref) => {
    const domProps = Object.fromEntries(Object.entries(props).filter(([key]) => !isValidMotionProp(key)));
    return createElement(tag, { ...domProps, ref }, children as import("react").ReactNode);
  });
  return {
    AnimatePresence: ({ children }: { children?: unknown }) => children,
    motion: { div: surface("div"), span: surface("span"), aside: surface("aside"), ul: surface("ul"), li: surface("li"), button: surface("button") },
    useReducedMotion: () => false,
    useIsPresent: () => true,
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

function subgroupMessage(subgroupId: string, seq: number): ChatMessage {
  return {
    id: `m${seq}`, conversation_id: "g1", sender_id: "me", type: "text",
    content: "新消息", media_id: null, reply_to: null, status: "sent", seq,
    created_at: "2026-09-07T00:00:00Z", subgroup_id: subgroupId,
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
  disposeSocialTracking();
  useAuthStore.setState({ currentUser: { id: "me", username: "me", nickname: "", avatar: "", signature: "", status: "auto", online: false, date_joined: "" }, accessToken: "test" });
  disposeDirectoryTracking();
  useMessageStore.getState().reset();
  useSubGroupStore.getState().reset();
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
  cleanup();
  disposeDirectoryTracking();
  vi.clearAllMocks();
  useChatStore.setState({ conversations: [] });
  useGroupStore.getState().reset();
  useSubGroupStore.getState().reset();
  useVoiceStore.getState().reset();
});

describe("subgroup store", () => {
  it("默认组固定首位，按最近消息排序；同序号/无消息保持原顺序且不改基础列表", () => {
    const list = [
      { ...sg("2", "较旧"), last_message_seq: 10 },
      sg("1", "改名的默认组", true),
      { ...sg("3", "较新"), last_message_seq: 20 },
      { ...sg("4", "并列"), last_message_seq: 20 },
      sg("5", "空组甲"), sg("6", "空组乙"),
    ];
    expect(sortSubgroupsByActivity(list).map((item) => item.id)).toEqual(["1", "3", "4", "2", "5", "6"]);
    expect(list.map((item) => item.id)).toEqual(["2", "1", "3", "4", "5", "6"]);
  });

  it("列表前消息、迟到 REST、重放和改名都不会回退活跃度；删除/退出清理投影", () => {
    const store = useSubGroupStore.getState();
    store.reset();
    store.recordMessageActivity("g1", "2", 30);
    store.setSubgroups("g1", [{ ...sg("2", "闲聊"), last_message_seq: 10 }]);
    store.recordMessageActivity("g1", "2", 15);
    store.upsertSubgroup("g1", sg("2", "改名"));
    store.clearSubgroupUnread("g1", "2");
    expect(useSubGroupStore.getState().byGroup.g1[0].last_message_seq).toBe(30);
    store.setSubgroups("g2", [{ ...sg("2", "别群"), conversation_id: "g2", last_message_seq: 5 }]);
    expect(useSubGroupStore.getState().byGroup.g2[0].last_message_seq).toBe(5);
    store.removeSubgroup("g1", "2");
    expect(useSubGroupStore.getState().lastMessageSeqByKey["g1:2"]).toBeUndefined();
    store.reset();
    expect(useSubGroupStore.getState().lastMessageSeqByKey).toEqual({});
  });

  it("自己消息 REST 确认和 WS 幂等确认推进序号，pending/失败/较早历史不抢位", () => {
    const messages = useMessageStore.getState();
    const local = { ...subgroupMessage("2", 0), id: "local", pending: true, idempotencyKey: "send-key" };
    messages.addPendingMessage("g1", local);
    messages.markMessageFailed("g1", "local");
    expect(useSubGroupStore.getState().lastMessageSeqByKey["g1:2"]).toBeUndefined();
    messages.resolvePendingMessage("g1", "local", "send-key", subgroupMessage("2", 40));
    messages.resolvePendingByKey("g1", "send-key", subgroupMessage("2", 40));
    messages.prependHistory("g1", [subgroupMessage("2", 5)], false);
    expect(useSubGroupStore.getState().byGroup.g1.find((item) => item.id === "2")?.last_message_seq).toBe(40);
    messages.upsertMessage("g1", { ...subgroupMessage("2", 41), type: "poke" });
    expect(useSubGroupStore.getState().byGroup.g1.find((item) => item.id === "2")?.last_message_seq).toBe(41);
  });

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
  it("新消息子群进入前三位，正在看的子群也重排；默认组固定、选中和点击目标保持", () => {
    useSubGroupStore.getState().setSubgroups("g1", [
      sg("1", "默认组", true),
      { ...sg("2", "闲聊"), last_message_seq: 10 },
      { ...sg("3", "公告"), last_message_seq: 20 },
      sg("4", "游戏"),
    ]);
    useSubGroupStore.getState().setActiveSubgroup("g1", "4");
    const select = vi.fn();
    render(<ChannelSidebar groupName="测试群" activeScene="chat" onSelectScene={() => {}} onOpenInfo={() => {}} onSelectSubgroup={select} />);
    const names = () => [...document.querySelectorAll(".channel-subgroup-name")].map((item) => item.textContent);
    expect(names()).toEqual(["默认组", "公告", "闲聊"]);
    act(() => useMessageStore.getState().upsertMessage("g1", subgroupMessage("4", 21)));
    expect(names()).toEqual(["默认组", "游戏", "公告"]);
    expect(useSubGroupStore.getState().activeByGroup.g1).toBe("4");
    fireEvent.click(screen.getByRole("button", { name: "游戏" }));
    expect(select).toHaveBeenCalledWith("4");
    act(() => useMessageStore.getState().upsertMessage("g1", subgroupMessage("1", 22)));
    expect(names()).toEqual(["默认组", "游戏", "公告"]);
    fireEvent.click(screen.getByRole("button", { name: /展开更多/ }));
    expect(names()).toEqual(["默认组", "游戏", "公告", "闲聊"]);
    // 刷新仅靠 API 持久消息序号恢复相同顺序。
    const snapshot = useSubGroupStore.getState().byGroup.g1;
    act(() => {
      useSubGroupStore.getState().reset();
      useSubGroupStore.getState().setSubgroups("g1", snapshot);
    });
    expect(names()).toEqual(["默认组", "游戏", "公告", "闲聊"]);
  });

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

  it("语音高亮立即跟随当前群路由，在旧房仍连接或新join挂起时不等待媒体状态", async () => {
    const room = (id: string) => ({ id, name: id, owner_id: "u1", group: "g1", allowed_group_ids: ["g1"],
      visibility: "group" as const, member_count: 0, room_name: id, group_name: "测试群",
      created_at: "2026-09-08T00:00:00Z", mine: false });
    useVoiceStore.setState({ channels: [room("A"), room("C")], currentChannelId: "A", livekit: "connected" });
    const props = { groupName: "测试群", activeScene: "voice" as const, onSelectScene: vi.fn(), onOpenInfo: vi.fn(), onSelectSubgroup: vi.fn() };
    const { rerender } = render(<ChannelSidebar {...props} activeVoiceChannelId="A" />);
    const a = await screen.findByRole("button", { name: "A" });
    const c = screen.getByRole("button", { name: "C" });
    expect(a).toHaveAttribute("aria-current", "true");
    rerender(<ChannelSidebar {...props} activeVoiceChannelId="C" />);
    expect(useVoiceStore.getState().currentChannelId).toBe("A");
    expect(c).toHaveAttribute("aria-current", "true");
    expect(a).not.toHaveAttribute("aria-current");
    act(() => useVoiceStore.getState().setLivekit("connecting"));
    expect(c).toHaveAttribute("aria-current", "true");
    act(() => useVoiceStore.getState().enterChannel("C", []));
    expect(c).toHaveAttribute("aria-current", "true");
    expect(screen.getByRole("button", { name: "C" })).toBe(c);
    rerender(<ChannelSidebar {...props} activeScene="chat" activeVoiceChannelId="C" />);
    expect(c).not.toHaveAttribute("aria-current");
  });

  it("语音房排序（有人区/无人区，事实源=后端持久字段）：3 一直有人 + 我在 1/2 来回 → 我在 1 时 [1,3,2]、我在 2 时 [2,3,1]", async () => {
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
    await waitFor(() => expect(rooms()).toEqual(["1", "2", "3"]));
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

  it("语音房排序：1234 完整验收序列（进4→4123，进2→2413，进1(2空)→1423，离4→1423，进4→4123，离4→1423，4永不回4号位）", async () => {
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
    fireEvent.click(await screen.findByRole("button", { name: /展开更多/ }));
    expect(rooms()).toEqual(["1", "2", "3", "4"]);
    const originalRows = new Map([...document.querySelectorAll(".channel-voice-room-item")]
      .map((row) => [row.querySelector(".channel-voice-room-name")?.textContent, row]));
    const originalButtons = new Map([...originalRows].map(([id, row]) => [id, row.querySelector("button")]));
    expect(document.querySelectorAll(".channel-voice-room-list")).toHaveLength(1);
    // 你进入 4 → [4,1,2,3]
    frame("4", { member_count: 1, last_occupied_at: "2026-09-05T10:01:00+08:00" });
    expect(rooms()).toEqual(["4", "1", "2", "3"]);
    for (const [id, row] of originalRows) {
      expect([...document.querySelectorAll(".channel-voice-room-item")].find((node) => node.querySelector(".channel-voice-room-name")?.textContent === id)).toBe(row);
      expect(row.querySelector("button")).toBe(originalButtons.get(id));
    }
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
    const fourth = originalRows.get("3")!;
    fireEvent.click(screen.getByRole("button", { name: /^收起$/ }));
    expect(fourth).toBeInTheDocument();
    expect(fourth).toHaveAttribute("aria-hidden", "true");
    expect(fourth).toHaveAttribute("inert");
    expect(fourth.querySelector("button")).toBeDisabled();
    expect(fourth.querySelector("button")).toHaveAttribute("tabindex", "-1");
    fireEvent.click(screen.getByRole("button", { name: /展开更多/ }));
    expect(fourth).not.toHaveAttribute("aria-hidden");
    expect(fourth).not.toHaveAttribute("inert");
    expect(fourth.querySelector("button")).toBe(originalButtons.get("3"));
    expect(fourth.querySelector("button")).toBeEnabled();
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
    MessageList: vi.fn(() => <div>消息列表</div>),
  }));
  vi.mock("../components/chat/MessageInput", async () => {
    const { forwardRef } = await import("react");
    return { MessageInput: forwardRef<HTMLDivElement, { disabled?: boolean; disabledHint?: string }>(
      ({ disabled, disabledHint }, ref) => <div ref={ref} data-disabled={String(disabled)} data-hint={disabledHint ?? ""}>输入框</div>,
    ) };
  });
  vi.mock("../api/chat", () => ({
  listSubgroupsPage: vi.fn(async (id: string) => { const results = await chatApi.listSubgroups(id); return { results, total: results.length, has_more: false, next_cursor: null, default: results.find((row) => row.is_default) ?? null }; }),
  getConversationMetadata: vi.fn(async (id: string) => useChatStore.getState().conversations.find((row) => row.id === id)!),
  listConversationMembersPage: vi.fn(async () => ({ results: [], total: 0, has_more: false, next_cursor: null })),
    listSubgroups: vi.fn().mockResolvedValue([
      sg("1", "默认组", true),
      { ...sg("2", "闲聊"), unread_count: 3, unread_seqs: [1, 2, 3] },
    ]),
    sendPoke: vi.fn().mockResolvedValue({}),
  }));
  vi.mock("../api/elysia", () => ({
    getElysiaProfile: vi.fn().mockResolvedValue({ user: { id: "me" } }),
  }));
  vi.mock("../hooks/useChat", async () => ({
    messageInSubgroup: (await vi.importActual<typeof import("../hooks/useChat")>("../hooks/useChat")).messageInSubgroup,
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
    chatWS: { subscribe: vi.fn(), onFrame: vi.fn(() => vi.fn()) },
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

  // 渲染 GroupChat 并展开选项卡（默认收起）。
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

  it("展开收起保留同一按钮焦点和输入框，隐藏tab不可聚焦且手势不冒泡到场景", async () => {
    const pointer = vi.fn();
    const touch = vi.fn();
    render(<div onPointerDown={pointer} onTouchStart={touch}><MemoryRouter><GroupChat groupId="g1" /></MemoryRouter></div>);
    const toggle = await screen.findByRole("button", { name: "展开子群选项卡" });
    const input = screen.getByText("输入框");
    const composeArea = input.closest(".group-chat-compose-area");
    expect(composeArea).not.toBeNull();
    expect(toggle.closest(".group-chat-compose-area")).toBe(composeArea);
    expect(composeArea).not.toContainElement(screen.getByText("消息列表"));
    expect(screen.queryByRole("tablist", { name: "子群切换" })).not.toBeInTheDocument();
    toggle.focus();
    fireEvent.pointerDown(toggle);
    fireEvent.touchStart(toggle);
    expect(pointer).not.toHaveBeenCalled();
    expect(touch).not.toHaveBeenCalled();
    fireEvent.click(toggle);
    expect(screen.getByRole("button", { name: "收起子群选项卡" })).toBe(toggle);
    expect(toggle).toHaveFocus();
    expect(toggle).toHaveAttribute("aria-expanded", "true");
    expect(screen.getByRole("tablist", { name: "子群切换" })).toBeInTheDocument();
    expect(screen.getByRole("tab", { name: /闲聊/ })).toBeEnabled();
    expect(screen.getByText("输入框")).toBe(input);
    fireEvent.click(toggle);
    expect(toggle).toHaveFocus();
    expect(toggle).toHaveAttribute("aria-expanded", "false");
    expect(screen.queryByRole("tablist", { name: "子群切换" })).not.toBeInTheDocument();
    expect(document.querySelectorAll('.group-chat-subgroup-tab[disabled][tabindex="-1"]')).toHaveLength(2);
    expect(screen.getByText("输入框")).toBe(input);
  });

  it("跨窄屏宽屏断点保持输入区和消息列表DOM，仅移除或恢复子群浮层", async () => {
    let narrow = true;
    const listeners = new Set<() => void>();
    vi.stubGlobal("matchMedia", vi.fn((query: string) => ({
      get matches() { return query === "(max-width: 768px)" ? narrow : false; },
      addEventListener: (_event: string, listener: () => void) => listeners.add(listener),
      removeEventListener: (_event: string, listener: () => void) => listeners.delete(listener),
    })));
    render(<MemoryRouter><GroupChat groupId="g1" /></MemoryRouter>);
    const toggle = await screen.findByRole("button", { name: "展开子群选项卡" });
    const input = screen.getByText("输入框");
    const list = screen.getByText("消息列表");
    const composeArea = input.closest(".group-chat-compose-area");
    fireEvent.click(toggle);
    act(() => { narrow = false; listeners.forEach((listener) => listener()); });
    expect(screen.queryByRole("button", { name: "收起子群选项卡" })).not.toBeInTheDocument();
    expect(screen.getByText("输入框")).toBe(input);
    expect(screen.getByText("消息列表")).toBe(list);
    expect(input.closest(".group-chat-compose-area")).toBe(composeArea);
    act(() => { narrow = true; listeners.forEach((listener) => listener()); });
    expect(screen.getByRole("button", { name: "收起子群选项卡" })).toHaveAttribute("aria-expanded", "true");
    expect(screen.getByText("输入框")).toBe(input);
    expect(screen.getByText("消息列表")).toBe(list);
    expect(input.closest(".group-chat-compose-area")).toBe(composeArea);
  });

  it("进入/切换只加载历史，标签不整段标读；只有可见消息回调精确确认", async () => {
    await renderGroupChatExpanded();
    await waitFor(() => {
      expect(screen.getByRole("tab", { name: /闲聊/ })).toBeInTheDocument();
    });
    fireEvent.click(screen.getByRole("tab", { name: /闲聊/ }));
    await waitFor(() => {
      expect(useSubGroupStore.getState().activeByGroup.g1).toBe("2");
    });
    const { markSubgroupRead, markMessageReadExact } = await import("../hooks/useChat");
    expect(markSubgroupRead).not.toHaveBeenCalled();
    expect(useSubGroupStore.getState().unreadByKey["g1:2"]).toBe(3);
    const props = vi.mocked(MessageList).mock.calls.at(-1)![0];
    expect(props.onMarkConversationRead).toBeUndefined();
    await act(async () => props.onMarkRead?.(subgroupMessage("2", 2), true));
    expect(markMessageReadExact).toHaveBeenCalledWith("g1", "m2");
    expect(markSubgroupRead).not.toHaveBeenCalled();
  });

  it("@/回复未读标签仅投影当前子群，不隐藏未看到的特殊消息或混入别组", async () => {
    useChatStore.setState({ conversations: [{ ...groupConv("g1"), mention_unread_seqs: [1, 9], reply_unread_seqs: [2, 10] }] });
    await renderGroupChatExpanded();
    fireEvent.click(screen.getByRole("tab", { name: /闲聊/ }));
    await waitFor(() => expect(useSubGroupStore.getState().activeByGroup.g1).toBe("2"));
    const props = vi.mocked(MessageList).mock.calls.at(-1)![0];
    expect(props.mentionUnreadSeqsOverride).toEqual([1]);
    expect(props.replyUnreadSeqsOverride).toEqual([2]);
    expect(props.unreadSeqsOverride).toEqual([1, 2, 3]);
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
    await waitFor(() => expect(input.dataset.disabled).toBe("true"));
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
