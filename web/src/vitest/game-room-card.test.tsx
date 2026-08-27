/**
 * GameRoomCard 列表浮入测试（A2 扩展至群内/群外桌游列表）：
 * - revealDelay 存在时，动画挂在 grid item 外层，保留内层卡片交互/hover；
 * - delay 通过 --reveal-delay 交给统一 .reveal-item 原语。
 */
import { render } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import type { GameRoom } from "../api/types";
import { GameRoomCard } from "../components/boardgame/GameRoomCard";

vi.mock("../components/FavoriteButton", () => ({ FavoriteButton: () => null }));

function room(): GameRoom {
  return {
    id: 1,
    name: "浮入测试桌游室",
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

describe("GameRoomCard 列表浮入", () => {
  it("revealDelay 存在时在外层 grid item 挂 reveal-item 与延迟", () => {
    const { container } = render(<GameRoomCard room={room()} onEnter={vi.fn()} revealDelay={80} />);
    const wrap = container.querySelector(".game-room-card-wrap");
    expect(wrap).toHaveClass("reveal-item");
    expect(wrap?.getAttribute("style")).toContain("--reveal-delay: 80ms");
    expect(wrap?.querySelector(".game-room-card")).not.toBeNull();
  });

  it("未给 revealDelay 时保持无动画类，避免非异步路径重复播入场", () => {
    const { container } = render(<GameRoomCard room={room()} onEnter={vi.fn()} />);
    expect(container.querySelector(".game-room-card-wrap")).not.toHaveClass("reveal-item");
  });
});
