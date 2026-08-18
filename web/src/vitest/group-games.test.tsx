/** GroupGames 定向测试：创建事件触发群内列表重新投影。 */
import { render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MemoryRouter } from "react-router-dom";
import * as boardgameApi from "../api/boardgame";
import type { GameRoom } from "../api/types";
import { GroupGames } from "../pages/group/GroupGames";

vi.mock("../api/boardgame", () => ({
  listGameRooms: vi.fn(),
  joinGameRoom: vi.fn(),
}));
vi.mock("../components/FavoriteButton", () => ({ FavoriteButton: () => null }));

function room(name: string, group: string | null): GameRoom {
  return {
    id: name === "新房间" ? 2 : 1,
    name,
    owner: {} as GameRoom["owner"],
    owner_id: "owner",
    visibility: group ? "group" : "public",
    group,
    group_name: group ? "测试群" : null,
    allowed_group_ids: group ? [group] : [],
    game_type: "boardgame",
    status: "waiting",
    members: [],
    member_count: 0,
    is_owner: false,
    is_member: false,
    created_at: "2026-01-01T00:00:00Z",
  };
}

beforeEach(() => {
  vi.mocked(boardgameApi.listGameRooms).mockResolvedValue([room("旧房间", "other")]);
});

afterEach(() => {
  vi.clearAllMocks();
});

describe("GroupGames 创建后刷新", () => {
  it("收到 room-created 事件后重新加载并显示新房间", async () => {
    render(<MemoryRouter><GroupGames groupId="group-1" onExit={vi.fn()} /></MemoryRouter>);
    await waitFor(() => expect(boardgameApi.listGameRooms).toHaveBeenCalledTimes(1));
    expect(screen.getByText("群内还没有桌游室")).toBeInTheDocument();

    vi.mocked(boardgameApi.listGameRooms).mockResolvedValue([room("新房间", "group-1")]);
    window.dispatchEvent(new CustomEvent("boardgame:room-created", { detail: room("新房间", "group-1") }));

    await waitFor(() => expect(boardgameApi.listGameRooms).toHaveBeenCalledTimes(2));
    expect(await screen.findByText("新房间")).toBeInTheDocument();
  });
});
