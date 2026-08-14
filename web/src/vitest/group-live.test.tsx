/**
 * GroupLive 测试（F4 R-G7）：群内直播切换范围 = 仅该群（filter group === groupId）。
 * LiveRoomBody / liveApi mock，聚焦范围过滤 + 无直播空态。
 */
import { render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as liveApi from "../api/live";
import type { LiveChannelDescriptor } from "../api/types";
import { useGroupStore } from "../stores/group";

vi.mock("../components/live/LiveRoomBody", () => ({
  LiveRoomBody: ({ channelId }: { channelId: number }) => (
    <div data-testid="room-body" data-channelid={channelId}>
      直播间 {channelId}
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
    render(<GroupLive groupId="g1" onExit={vi.fn()} />);
    await waitFor(() =>
      expect(screen.getByTestId("room-body")).toHaveAttribute("data-channelid", "1"),
    );
  });

  it("本群无直播 → 空态引导", async () => {
    vi.mocked(liveApi.listLiveChannels).mockResolvedValue([ch(3, null), ch(4, "g9")]);
    render(<GroupLive groupId="g1" onExit={vi.fn()} />);
    await waitFor(() => expect(screen.getByText("群内还没有直播")).toBeInTheDocument());
  });
});
