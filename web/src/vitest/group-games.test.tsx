/** GroupGames 定向测试：创建事件触发群内列表重新投影 + 多群白名单可见性。 */
import { render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MemoryRouter } from "react-router-dom";
import * as boardgameApi from "../api/boardgame";
import type { GameRoom } from "../api/types";
import { GroupGames } from "../pages/group/GroupGames";
import { useBoardgameStore } from "../stores/boardgame";

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
  // store 是全局单例：不 reset 会让上一用例的 rooms 残留，
  // 导致本用例 load() 不触发（stale 检查）而显示旧数据。
  useBoardgameStore.getState().reset();
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
    // A2 扩展：群内桌游列表在内容就绪后按统一 stagger 浮入。
    const cards = document.querySelectorAll(".game-room-card-wrap");
    expect(cards).toHaveLength(1);
    expect(cards[0]).toHaveClass("reveal-item");
    expect(cards[0]).toHaveStyle({ "--reveal-delay": "0ms" });
  });
});

describe("GroupGames 多群可见性（allowed_group_ids）", () => {
  it("同一多群房间（group=null + 白名单 13/14/15）出现在每个被选群的群内页", async () => {
    const multi = room("多群房间", null);
    multi.allowed_group_ids = ["13", "14", "15"];
    vi.mocked(boardgameApi.listGameRooms).mockResolvedValue([multi]);
    for (const gid of ["13", "14", "15"]) {
      const { unmount } = render(
        <MemoryRouter><GroupGames groupId={gid} onExit={vi.fn()} /></MemoryRouter>,
      );
      expect(await screen.findByText("多群房间")).toBeInTheDocument();
      unmount();
    }
  });

  it("不在白名单的群看不到该房间（空态）", async () => {
    const multi = room("多群房间2", null);
    multi.allowed_group_ids = ["13", "14"];
    vi.mocked(boardgameApi.listGameRooms).mockResolvedValue([multi]);
    render(<MemoryRouter><GroupGames groupId="15" onExit={vi.fn()} /></MemoryRouter>);
    await waitFor(() => expect(screen.getByText("群内还没有桌游室")).toBeInTheDocument());
  });

  it("先看别的群、再看白名单群，多群房间仍在（store 不被单群 scope 覆盖）", async () => {
    // scope 感知的 mock：模拟后端 scope=group:<id> 只回该群房间（不含白名单多群房间）
    const g16 = room("群16房间", "16");
    const multi = room("多群房间3", null);
    multi.allowed_group_ids = ["13", "14", "15"];
    vi.mocked(boardgameApi.listGameRooms).mockImplementation((params) => {
      const scope = params?.scope;
      if (scope?.startsWith("group:")) {
        const gid = scope.split(":")[1];
        return Promise.resolve(
          [g16, multi].filter(
            (r) => String(r.group) === gid || (r.allowed_group_ids ?? []).includes(gid),
          ),
        );
      }
      return Promise.resolve([g16, multi]);
    });

    // 先进群 16（只有群 16 自己的房间）
    const first = render(
      <MemoryRouter><GroupGames groupId="16" onExit={vi.fn()} /></MemoryRouter>,
    );
    expect(await screen.findByText("群16房间")).toBeInTheDocument();
    expect(screen.queryByText("多群房间3")).not.toBeInTheDocument();
    first.unmount();

    // 再进群 13（多群房间白名单）——必须仍能看到它
    render(
      <MemoryRouter><GroupGames groupId="13" onExit={vi.fn()} /></MemoryRouter>,
    );
    expect(await screen.findByText("多群房间3")).toBeInTheDocument();
  });
});
