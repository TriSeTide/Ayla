/**
 * GroupInfo 测试（F3 R-G9 角色化）：
 * - owner/admin 看到「编辑群资料」+ 管理项占位；成员看不到编辑，看到退出占位；
 * - 成员列表角色标签（owner/admin/member）；
 * - 群头像上传（M5-2.1）：owner 可换、成员不可；选择→预览→保存上传+PATCH→store 更新；失败重试。
 */
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ConversationSummary, ConversationMember, UserPublic } from "../api/types";
import { GroupInfo } from "../pages/group/GroupInfo";
import { useAuthStore } from "../stores/auth";
import { useChatStore } from "../stores/chat";
import { useHomeStore } from "../stores/home";
import * as chatApi from "../api/chat";
import * as mediaApi from "../api/media";

vi.mock("../api/chat", () => ({
  // 默认返回一个群详情，避免未命中 store 时的 effect 拿 undefined（.then 崩）
  getConversation: vi.fn().mockResolvedValue({
    id: "1",
    type: "group",
    title: "测试群",
    announcement: "",
    avatar: "",
    owner_id: "o1",
    members: [],
    my_role: null,
    member_count: 0,
    unread_count: 0,
    created_at: "2026-01-01T00:00:00Z",
    peer: null,
  }),
  patchConversation: vi.fn(),
  listJoinRequests: vi.fn().mockResolvedValue([]),
  actionJoinRequest: vi.fn().mockResolvedValue({ detail: "ok" }),
  setMemberRole: vi.fn().mockResolvedValue({}),
  removeMember: vi.fn().mockResolvedValue(undefined),
  transferGroupOwner: vi.fn().mockResolvedValue({}),
  dissolveGroup: vi.fn().mockResolvedValue({ deleted: true }),
  leaveGroup: vi.fn().mockResolvedValue({ left: true }),
}));

vi.mock("../api/media", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../api/media")>();
  return {
    ...actual,
    uploadMediaFile: vi.fn(),
  };
});

function user(id: string, nickname: string): UserPublic {
  return {
    id,
    username: id,
    nickname,
    avatar: "",
    signature: "",
    status: "online",
    online: true,
    date_joined: "2026-01-01T00:00:00Z",
  };
}

function member(userId: string, role: ConversationMember["role"]): ConversationMember {
  return { id: userId, user: user(userId, userId === "u1" ? "爱丽丝" : "用户" + userId), role, muted: false, joined_at: "2026-01-01T00:00:00Z" };
}

function conv(myRole: ConversationSummary["my_role"]): ConversationSummary {
  return {
    id: "1",
    type: "group",
    title: "测试群",
    announcement: "群公告",
    avatar: "",
    owner_id: "o1",
    members: [
      member("o1", "owner"),
      { ...member("u1", "member"), user: user("u1", "爱丽丝") },
      member("a1", "admin"),
      member("m1", "member"),
    ],
    my_role: myRole,
    member_count: 4,
    unread_count: 0,
    created_at: "2026-01-01T00:00:00Z",
    peer: null,
  };
}

function renderInfo(myRole: ConversationSummary["my_role"]) {
  useChatStore.setState({ conversations: [conv(myRole)] });
  return render(
    <MemoryRouter>
      <GroupInfo groupId="1" />
    </MemoryRouter>,
  );
}

beforeEach(() => {
  useAuthStore.setState({
    accessToken: "acc",
    currentUser: user("u1", "爱丽丝"),
  });
});

afterEach(() => {
  vi.clearAllMocks();
  useChatStore.setState({ conversations: [] });
});

describe("GroupInfo 角色化", () => {
  it("owner 看到编辑群资料 + 成员角色标签（群主/管理员）", () => {
    renderInfo("owner");
    expect(screen.getByRole("button", { name: "编辑群资料" })).toBeInTheDocument();
    expect(screen.getByText("群主")).toBeInTheDocument();
    expect(screen.getByText("管理员")).toBeInTheDocument();
    expect(screen.getByText("群公告")).toBeInTheDocument();
  });

  it("owner 看到管理项占位（入群申请审批）", () => {
    renderInfo("owner");
    expect(screen.getByText(/入群申请审批/)).toBeInTheDocument();
  });

  it("普通成员不看到编辑按钮，看到退出占位", () => {
    renderInfo("member");
    expect(screen.queryByRole("button", { name: "编辑群资料" })).not.toBeInTheDocument();
    expect(screen.getByText(/退出群/)).toBeInTheDocument();
  });
});

describe("GroupInfo 群头像上传（M5-2.1）", () => {
  beforeEach(() => {
    Object.defineProperty(URL, "createObjectURL", {
      value: vi.fn(() => "blob:mock-group-avatar"),
      configurable: true,
    });
    Object.defineProperty(URL, "revokeObjectURL", {
      value: vi.fn(),
      configurable: true,
    });
    vi.mocked(mediaApi.uploadMediaFile).mockReset();
    vi.mocked(chatApi.patchConversation).mockReset();
  });

  function pngFile() {
    return new File(["img"], "a.png", { type: "image/png" });
  }

  it("owner 看到更换群头像按钮；选择文件显示预览 + 保存按钮", async () => {
    renderInfo("owner");
    const input = screen.getByLabelText("更换群头像") as HTMLInputElement;
    fireEvent.change(input, { target: { files: [pngFile()] } });
    await screen.findByText("新头像将在保存后生效");
    expect(screen.getByRole("button", { name: "保存群头像" })).toBeInTheDocument();
  });

  it("普通成员不看到更换群头像按钮", () => {
    renderInfo("member");
    expect(screen.queryByLabelText("更换群头像")).not.toBeInTheDocument();
  });

  it("保存群头像：三步上传 + PATCH avatar + store 更新", async () => {
    vi.mocked(mediaApi.uploadMediaFile).mockResolvedValue({ media_id: "m-1", descriptor: {} as never });
    const url = "/api/v1/media/m-1/content";
    vi.mocked(chatApi.patchConversation).mockResolvedValue({ ...conv("owner"), avatar: url });
    renderInfo("owner");
    const input = screen.getByLabelText("更换群头像") as HTMLInputElement;
    fireEvent.change(input, { target: { files: [pngFile()] } });
    await screen.findByText("新头像将在保存后生效");

    fireEvent.click(screen.getByRole("button", { name: "保存群头像" }));
    await waitFor(() => expect(chatApi.patchConversation).toHaveBeenCalledWith("1", { avatar: url }));
    expect(mediaApi.uploadMediaFile).toHaveBeenCalledWith(pngFile(), "image");
    // store 中的群头像已更新
    await waitFor(() =>
      expect(useChatStore.getState().conversations[0].avatar).toBe(url),
    );
    // 成功后预览提示消失
    await waitFor(() =>
      expect(screen.queryByText("新头像将在保存后生效")).not.toBeInTheDocument(),
    );
  });

  it("上传失败保留文件，可再次保存重试", async () => {
    vi.mocked(mediaApi.uploadMediaFile)
      .mockRejectedValueOnce(new Error("网络失败"))
      .mockResolvedValueOnce({ media_id: "m-2", descriptor: {} as never });
    const url = "/api/v1/media/m-2/content";
    vi.mocked(chatApi.patchConversation).mockResolvedValue({ ...conv("owner"), avatar: url });
    renderInfo("owner");
    const input = screen.getByLabelText("更换群头像") as HTMLInputElement;
    fireEvent.change(input, { target: { files: [pngFile()] } });
    await screen.findByText("新头像将在保存后生效");

    fireEvent.click(screen.getByRole("button", { name: "保存群头像" }));
    await screen.findByRole("alert");
    // 失败后预览仍在，可重试
    expect(screen.getByText("新头像将在保存后生效")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "保存群头像" }));
    await waitFor(() => expect(chatApi.patchConversation).toHaveBeenCalledTimes(1));
    expect(mediaApi.uploadMediaFile).toHaveBeenCalledTimes(2);
    await waitFor(() =>
      expect(screen.queryByText("新头像将在保存后生效")).not.toBeInTheDocument(),
    );
  });
});

describe("GroupInfo 转让群主（Bug #5：弹窗选人替代 window.prompt）", () => {
  beforeEach(() => {
    // jsdom 未实现 confirm；默认确认（只 spy 这一个，勿用 restoreAllMocks——那会清空模块 mock 实现）
    vi.spyOn(window, "confirm").mockReturnValue(true);
  });

  afterEach(() => {
    vi.mocked(window.confirm).mockRestore();
  });

  function openTransferDialog() {
    renderInfo("owner");
    fireEvent.click(screen.getByRole("button", { name: "转让群主" }));
    return screen.getByRole("dialog", { name: "转让群主" });
  }

  it("点转让群主弹出对话框：列出除自己与群主外的成员（含角色标签）", () => {
    const dialog = openTransferDialog();
    // 候选：a1（管理员）、m1（成员）；群主 o1 与自己 u1 被排除
    expect(within(dialog).getByRole("button", { name: "转让给 用户a1" })).toBeInTheDocument();
    expect(within(dialog).getByRole("button", { name: "转让给 用户m1" })).toBeInTheDocument();
    expect(within(dialog).queryByRole("button", { name: "转让给 爱丽丝" })).not.toBeInTheDocument();
    expect(within(dialog).getByRole("button", { name: "转让给 用户a1" })).toHaveAttribute(
      "aria-pressed",
      "false",
    );
    // 管理员角色标签（弹窗内）
    expect(within(dialog).getByText("管理员")).toBeInTheDocument();
    // 未选择时确认禁用
    expect(within(dialog).getByRole("button", { name: "确认转让" })).toBeDisabled();
  });

  it("搜索框按昵称/用户名过滤成员", () => {
    const dialog = openTransferDialog();
    const search = within(dialog).getByLabelText("搜索成员");
    fireEvent.change(search, { target: { value: "m1" } });
    expect(within(dialog).getByRole("button", { name: "转让给 用户m1" })).toBeInTheDocument();
    expect(within(dialog).queryByRole("button", { name: "转让给 用户a1" })).not.toBeInTheDocument();

    fireEvent.change(search, { target: { value: "不存在的昵称" } });
    expect(within(dialog).getByText("没有匹配的成员")).toBeInTheDocument();
  });

  it("选择成员 → 确认 → 二次 confirm → 调用 transferGroupOwner 并关闭对话框", async () => {
    const dialog = openTransferDialog();
    fireEvent.click(within(dialog).getByRole("button", { name: "转让给 用户m1" }));
    expect(within(dialog).getByRole("button", { name: "转让给 用户m1" })).toHaveAttribute(
      "aria-pressed",
      "true",
    );

    fireEvent.click(within(dialog).getByRole("button", { name: "确认转让" }));
    await waitFor(() => expect(chatApi.transferGroupOwner).toHaveBeenCalledWith("1", "m1"));
    expect(window.confirm).toHaveBeenCalledWith("确定将群主转让给 用户m1？转让后你将成为普通成员");
    // 成功后对话框关闭
    await waitFor(() =>
      expect(screen.queryByRole("dialog", { name: "转让群主" })).not.toBeInTheDocument(),
    );
  });

  it("二次 confirm 取消则不执行转让，对话框保留", () => {
    vi.mocked(window.confirm).mockReturnValue(false);
    const dialog = openTransferDialog();
    fireEvent.click(within(dialog).getByRole("button", { name: "转让给 用户m1" }));
    fireEvent.click(within(dialog).getByRole("button", { name: "确认转让" }));

    expect(chatApi.transferGroupOwner).not.toHaveBeenCalled();
    expect(screen.getByRole("dialog", { name: "转让群主" })).toBeInTheDocument();
  });

  it("仅群主一人的群：显示暂无其他成员可转让且确认禁用", () => {
    // 群主 u1 即当前用户，群内只有自己（不能用 renderInfo，它会覆盖 store 为 4 人群）
    useChatStore.setState({
      conversations: [
        {
          ...conv("owner"),
          owner_id: "u1",
          members: [{ ...member("u1", "owner"), user: user("u1", "爱丽丝") }],
          member_count: 1,
        },
      ],
    });
    render(
      <MemoryRouter>
        <GroupInfo groupId="1" />
      </MemoryRouter>,
    );
    fireEvent.click(screen.getByRole("button", { name: "转让群主" }));
    const dialog = screen.getByRole("dialog", { name: "转让群主" });
    expect(within(dialog).getByText("暂无其他成员可转让")).toBeInTheDocument();
    expect(within(dialog).getByRole("button", { name: "确认转让" })).toBeDisabled();
  });
});

describe("GroupInfo 解散群聊与退出群聊", () => {
  beforeEach(() => {
    vi.spyOn(window, "confirm").mockReturnValue(true);
    useHomeStore.setState({ layout: "card", recentGroupId: "1" });
    useChatStore.setState({ conversations: [conv("owner")] });
  });
  afterEach(() => {
    vi.mocked(window.confirm).mockRestore();
  });

  function renderInfoRoutes() {
    return render(
      <MemoryRouter initialEntries={["/group/1/info"]}>
        <Routes>
          <Route path="/group/:id/info" element={<GroupInfo groupId="1" />} />
          <Route path="/group" element={<div>主页</div>} />
        </Routes>
      </MemoryRouter>,
    );
  }

  it("解散成功：从会话列表移除、清最近群并跳转 /group 主页", async () => {
    renderInfoRoutes();
    fireEvent.click(screen.getByRole("button", { name: "解散群聊" }));
    await waitFor(() => expect(chatApi.dissolveGroup).toHaveBeenCalledWith("1"));
    // 会话已从 store 移除
    expect(useChatStore.getState().conversations.find((c) => c.id === "1")).toBeUndefined();
    // 最近群被清空（避免宽屏 /group redirect 回已删群导致死循环）
    expect(useHomeStore.getState().recentGroupId).toBeNull();
    // 跳转到主页
    expect(screen.getByText("主页")).toBeInTheDocument();
  });

  it("确认取消则不执行解散，也不跳转", () => {
    vi.mocked(window.confirm).mockReturnValue(false);
    renderInfoRoutes();
    fireEvent.click(screen.getByRole("button", { name: "解散群聊" }));
    expect(chatApi.dissolveGroup).not.toHaveBeenCalled();
    expect(useChatStore.getState().conversations.some((c) => c.id === "1")).toBe(true);
    expect(screen.queryByText("主页")).not.toBeInTheDocument();
  });
});
