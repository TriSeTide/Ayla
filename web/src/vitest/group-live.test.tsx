/**
 * GroupLive 测试（F4 R-G7）：以 groupId 请求服务端过滤后的分页目录。
 * LiveRoomBody / liveApi mock，聚焦查询归属、多群白名单和无直播空态。
 */
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as liveApi from "../api/live";
import type { LiveChannelDescriptor } from "../api/types";
import { useGroupStore } from "../stores/group";
import { useLiveStore } from "../stores/live";
import { useAuthStore } from "../stores/auth";
import { disposeDirectoryTracking } from "../stores/directory";

vi.mock("../components/live/LiveRoomBody", () => ({
  LiveRoomBody: ({
    channelId,
    onCreateNewChannel,
  }: { channelId: number; onCreateNewChannel?: () => void }) => (
    <div data-testid="room-body" data-channelid={channelId}>
      直播间 {channelId}
      {onCreateNewChannel && (
        <button type="button" onClick={onCreateNewChannel}>新建直播间</button>
      )}
    </div>
  ),
}));
vi.mock("../api/live", () => ({
  listLiveChannels: vi.fn(),
  listLiveChannelsPage: vi.fn(),
  createLiveChannel: vi.fn(),
  getLiveChannel: vi.fn(),
  listDanmaku: vi.fn(),
  getLiveChannelStatus: vi.fn(),
  sendDanmaku: vi.fn(),
}));

function ch(id: number, group: string | null): LiveChannelDescriptor {
  return {
    id,
    title: `直播${id}`,
    status: "live",
    owner_id: "o1",
    owner_nickname: "主播",
    is_owner: false,
    visibility: group ? "group" : "public",
    group,
    group_name: group ? "目标群" : null,
    allowed_group_ids: group ? [group] : [],
    stream_key: null,
    rtmp_url: null,
    hls_url: `http://h/${id}.m3u8`,
    flv_url: `http://h/${id}.flv`,
    started_at: null,
    ended_at: null,
    created_at: "2026-01-01T00:00:00Z",
  };
}

function mockChannels(channels: LiveChannelDescriptor[]) {
  // 群目录和本人目录必须分别在服务端按 groupId/owner 过滤后分页。
  vi.mocked(liveApi.listLiveChannels).mockResolvedValue(channels);
  vi.mocked(liveApi.listLiveChannelsPage).mockImplementation(async (params) => {
    const results = channels.filter((item) => (!params?.groupId || (item.allowed_group_ids ?? []).includes(params.groupId))
      && (!params?.owner || item.owner_id === params.owner));
    return { results, next_cursor: null, has_more: false, total: results.length };
  });
}

function matchMediaMock() {
  vi.stubGlobal(
    "matchMedia",
    vi.fn(() => ({
      matches: true,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    })),
  );
}

import { GroupLive } from "../pages/group/GroupLive";

beforeEach(() => {
  disposeDirectoryTracking();
  matchMediaMock();
  useGroupStore.getState().reset();
  useAuthStore.setState({ currentUser: { id: "me" } as never });
  // store 是全局单例：不 reset 会让上一用例的 channels 残留，
  // 导致本用例 load() 不触发（stale 检查）而显示旧数据。
  useLiveStore.getState().reset();
});

afterEach(() => {
  cleanup();
  disposeDirectoryTracking();
  vi.unstubAllGlobals();
  vi.clearAllMocks();
});

describe("GroupLive 范围（仅该群）", () => {
  it("向服务端请求本群分页目录，房内切换范围不混入其它群", async () => {
    mockChannels([
      ch(1, "g1"),
      ch(2, "g1"),
      ch(3, null), // 公开
      ch(4, "g9"), // 其它群
    ]);
    render(
      <MemoryRouter>
        <GroupLive groupId="g1" onExit={vi.fn()} />
      </MemoryRouter>,
    );
    await waitFor(() =>
      expect(screen.getByTestId("room-body")).toHaveAttribute("data-channelid", "1"),
    );
    expect(liveApi.listLiveChannelsPage).toHaveBeenCalledWith({ groupId: "g1", onlyLive: undefined, limit: 20, cursor: null });
  });

  it("本群直播间把创建入口交给直播侧栏", async () => {
    mockChannels([ch(1, "g1")]);
    render(
      <MemoryRouter>
        <GroupLive groupId="g1" onExit={vi.fn()} />
      </MemoryRouter>,
    );
    await waitFor(() => expect(screen.getByRole("button", { name: "新建直播间" })).toBeInTheDocument());
  });

  it("本群无直播 → 空态引导", async () => {
    mockChannels([ch(3, null), ch(4, "g9")]);
    render(
      <MemoryRouter>
        <GroupLive groupId="g1" onExit={vi.fn()} />
      </MemoryRouter>,
    );
    await waitFor(() => expect(screen.getByText("群内还没有直播")).toBeInTheDocument());
  });

  it("本群无直播 → 空态提供「创建群内直播」入口并可按群创建", async () => {
    mockChannels([ch(3, null), ch(4, "g9")]);
    vi.mocked(liveApi.createLiveChannel).mockResolvedValue(ch(10, "g1"));
    render(
      <MemoryRouter>
        <GroupLive groupId="g1" onExit={vi.fn()} />
      </MemoryRouter>,
    );
    await waitFor(() => expect(screen.getByText("群内还没有直播")).toBeInTheDocument());
    // 空态创建入口按钮存在
    const createBtn = screen.getByRole("button", { name: "创建群内直播" });
    expect(createBtn).toBeInTheDocument();
    // 点击打开「群内开播」选择器弹窗
    createBtn.click();
    await waitFor(() => expect(screen.getByRole("dialog", { name: "群内开播" })).toBeInTheDocument());
    // 空态下当前用户没有自己的直播间 → 选择器展示空引导
    await waitFor(() => expect(screen.getByText("还没有自己的直播间，先创建一个吧。")).toBeInTheDocument());
    // 走「+ 添加新的直播间」→ 创建归属本群的频道（group=g1）
    screen.getByRole("button", { name: "+ 添加新的直播间" }).click();
    await waitFor(() => {
      expect(liveApi.createLiveChannel).toHaveBeenCalledWith("新直播间", "g1");
    });
  });
});

describe("GroupLive 多群可见性（allowed_group_ids）", () => {
  it("同一多群直播（group=null + 白名单 13/14/15）出现在每个被选群的群内页", async () => {
    const multi = ch(50, null);
    multi.allowed_group_ids = ["13", "14", "15"];
    mockChannels([multi]);
    for (const gid of ["13", "14", "15"]) {
      const { unmount } = render(
        <MemoryRouter>
          <GroupLive groupId={gid} onExit={vi.fn()} />
        </MemoryRouter>,
      );
      await waitFor(() =>
        expect(screen.getByTestId("room-body")).toHaveAttribute("data-channelid", "50"),
      );
      expect(liveApi.listLiveChannelsPage).toHaveBeenCalledWith({ groupId: gid, onlyLive: undefined, limit: 20, cursor: null });
      unmount();
    }
  });

  it("不在白名单的群看不到该直播（空态）", async () => {
    const multi = ch(51, null);
    multi.allowed_group_ids = ["13", "14"];
    mockChannels([multi]);
    render(
      <MemoryRouter>
        <GroupLive groupId="15" onExit={vi.fn()} />
      </MemoryRouter>,
    );
    await waitFor(() => expect(screen.getByText("群内还没有直播")).toBeInTheDocument());
  });

  it("先看别的群、再看白名单群，多群直播仍在（store 不被单群 scope 覆盖）", async () => {
    // 服务端按 groupId 过滤 allowed_group_ids；不同群的分页投影互不替换。
    const g16 = ch(60, "16");
    const multi = ch(61, null);
    multi.allowed_group_ids = ["13", "14", "15"];
    mockChannels([g16, multi]);

    // 先进群 16（只有群 16 自己的直播）
    const first = render(
      <MemoryRouter>
        <GroupLive groupId="16" onExit={vi.fn()} />
      </MemoryRouter>,
    );
    await waitFor(() =>
      expect(screen.getByTestId("room-body")).toHaveAttribute("data-channelid", "60"),
    );
    first.unmount();

    // 再进群 13（多群直播白名单）——必须仍能看到 61
    render(
      <MemoryRouter>
        <GroupLive groupId="13" onExit={vi.fn()} />
      </MemoryRouter>,
    );
    await waitFor(() =>
      expect(screen.getByTestId("room-body")).toHaveAttribute("data-channelid", "61"),
    );
  });
});
