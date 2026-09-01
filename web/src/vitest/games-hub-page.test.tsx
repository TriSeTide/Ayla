/**
 * GamesHubPage 测试（A2 扩展至群外桌游 + 任务 07 直达进房）：
 * - 异步列表就绪后，卡片以统一 .reveal-item + 40ms stagger 进入；刷新时的
 *   revealNonce 重挂载会复用相同的卡片配方；
 * - 路由 /games/:roomId 直达进房：自动 join 并渲染房内占位（收藏跳转场景）。
 */
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as boardgameApi from "../api/boardgame";
import type { GameRoom, GameRoomMember } from "../api/types";
import { GamesHubPage } from "../pages/GamesHubPage";
import { useBoardgameStore } from "../stores/boardgame";
import { useShellStore } from "../stores/shell";

vi.mock("../api/boardgame", () => ({
  listGameRooms: vi.fn(),
  getGameRoom: vi.fn(),
  joinGameRoom: vi.fn(),
}));
vi.mock("../components/FavoriteButton", () => ({ FavoriteButton: () => null }));

function room(id: number, name: string): GameRoom {
  return {
    id,
    name,
    owner: {} as GameRoom["owner"],
    owner_id: "owner",
    visibility: "public",
    group: null,
    group_name: null,
    allowed_group_ids: [],
    game_type: "boardgame",
    status: "waiting",
    members: [],
    member_count: 2,
    is_owner: false,
    is_member: false,
    created_at: "2026-01-01T00:00:00Z",
  };
}

function renderHub(initialEntries = ["/games"]) {
  return render(
    <MemoryRouter initialEntries={initialEntries}>
      <Routes>
        <Route path="/games" element={<GamesHubPage />} />
        <Route path="/games/:roomId" element={<GamesHubPage />} />
      </Routes>
    </MemoryRouter>,
  );
}

beforeEach(() => {
  useBoardgameStore.getState().reset();
  useShellStore.setState({ refreshCallback: null });
  vi.mocked(boardgameApi.listGameRooms).mockResolvedValue([
    room(1, "群外桌游一"),
    room(2, "群外桌游二"),
    room(3, "群外桌游三"),
  ]);
  vi.mocked(boardgameApi.joinGameRoom).mockResolvedValue({} as GameRoomMember);
});

afterEach(() => {
  vi.clearAllMocks();
  useBoardgameStore.getState().reset();
  useShellStore.setState({ refreshCallback: null });
});

describe("GamesHubPage 列表逐条浮入", () => {
  it("异步加载完成后为群外桌游卡片应用 40ms stagger", async () => {
    const { container } = renderHub();
    await screen.findByText("群外桌游一");
    await waitFor(() => expect(container.querySelectorAll(".game-room-card-wrap")).toHaveLength(3));

    const cards = container.querySelectorAll(".game-room-card-wrap");
    expect(cards[0]).toHaveClass("reveal-item");
    expect(cards[0]).toHaveStyle({ "--reveal-delay": "0ms" });
    expect(cards[1]).toHaveStyle({ "--reveal-delay": "40ms" });
    expect(cards[2]).toHaveStyle({ "--reveal-delay": "80ms" });
  });
});

describe("GamesHubPage 直达进房（任务 07）", () => {
  it("路由 /games/:roomId → 自动 join 并渲染房内占位（收藏跳转场景）", async () => {
    vi.mocked(boardgameApi.getGameRoom).mockResolvedValue(room(2, "群外桌游二"));
    renderHub(["/games/2"]);

    await waitFor(() => expect(boardgameApi.getGameRoom).toHaveBeenCalledWith(2));
    await waitFor(() => expect(boardgameApi.joinGameRoom).toHaveBeenCalledWith(2));
    expect(await screen.findByText("群外桌游二")).toBeInTheDocument();
  });

  it("房间不存在/无权 → 回大厅并提示，不伪造进房", async () => {
    vi.mocked(boardgameApi.getGameRoom).mockRejectedValue(new Error("404"));
    renderHub(["/games/999"]);

    await waitFor(() => expect(boardgameApi.getGameRoom).toHaveBeenCalledWith(999));
    expect(await screen.findByText("桌游房不存在或无权访问")).toBeInTheDocument();
    // 回大厅：列表正常渲染
    expect(await screen.findByText("群外桌游一")).toBeInTheDocument();
  });
});
