/**
 * GroupLive 测试（F4 R-G7）：群内直播切换范围 = 仅该群（filter group === groupId）。
 * LiveRoomBody / liveApi mock，聚焦范围过滤 + 无直播空态。
 */
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as liveApi from "../api/live";
import type { LiveChannelDescriptor } from "../api/types";
import { useGroupStore } from "../stores/group";

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
    stream_key: null,
    rtmp_url: null,
    hls_url: `http://h/${id}.m3u8`,
    flv_url: `http://h/${id}.flv`,
    started_at: null,
    ended_at: null,
    created_at: "2026-01-01T00:00:00Z",
  };
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
  matchMediaMock();
  useGroupStore.getState().reset();
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.clearAllMocks();
});

describe("GroupLive 范围（仅该群）", () => {
  it("混合列表中只取本群的直播间", async () => {
    vi.mocked(liveApi.listLiveChannels).mockResolvedValue([
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
  });

  it("本群直播间把创建入口交给直播侧栏", async () => {
    vi.mocked(liveApi.listLiveChannels).mockResolvedValue([ch(1, "g1")]);
    render(
      <MemoryRouter>
        <GroupLive groupId="g1" onExit={vi.fn()} />
      </MemoryRouter>,
    );
    await waitFor(() => expect(screen.getByRole("button", { name: "新建直播间" })).toBeInTheDocument());
  });

  it("本群无直播 → 空态引导", async () => {
    vi.mocked(liveApi.listLiveChannels).mockResolvedValue([ch(3, null), ch(4, "g9")]);
    render(
      <MemoryRouter>
        <GroupLive groupId="g1" onExit={vi.fn()} />
      </MemoryRouter>,
    );
    await waitFor(() => expect(screen.getByText("群内还没有直播")).toBeInTheDocument());
  });

  it("本群无直播 → 空态提供「创建群内直播」入口并可按群创建", async () => {
    vi.mocked(liveApi.listLiveChannels).mockResolvedValue([ch(3, null), ch(4, "g9")]);
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
    expect(screen.getByText("还没有自己的直播间，先创建一个吧。")).toBeInTheDocument();
    // 走「+ 添加新的直播间」→ 创建归属本群的频道（group=g1）
    screen.getByRole("button", { name: "+ 添加新的直播间" }).click();
    await waitFor(() => {
      expect(liveApi.createLiveChannel).toHaveBeenCalledWith("新直播间", "g1");
    });
  });
});
