/**
 * FavoriteButton WS 订阅机制测试（任务 07）：
 * applyFavoriteChanged 更新模块缓存并通知挂载中的按钮，
 * 同账号其他界面的收藏操作实时反映到本按钮（live/voice/game/message 类型）。
 */
import { act, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as favoritesApi from "../api/favorites";
import { applyFavoriteChanged, FavoriteButton } from "../components/FavoriteButton";

vi.mock("../api/favorites", () => ({
  listFavorites: vi.fn(),
  addFavorite: vi.fn(),
  removeFavorite: vi.fn(),
}));

beforeEach(() => {
  vi.mocked(favoritesApi.listFavorites).mockResolvedValue([]);
});

afterEach(() => {
  vi.clearAllMocks();
});

describe("FavoriteButton WS 订阅（任务 07）", () => {
  it("applyFavoriteChanged added → 挂载中的按钮实时变为已收藏", async () => {
    render(<FavoriteButton targetType="live" targetId="3" compact />);
    const btn = await screen.findByRole("button", { name: "收藏" });
    expect(btn).toHaveAttribute("aria-pressed", "false");

    act(() => {
      applyFavoriteChanged("live", "3", 55);
    });
    await waitFor(() => expect(btn).toHaveAttribute("aria-pressed", "true"));
    expect(btn).toHaveAttribute("aria-label", "取消收藏");
  });

  it("applyFavoriteChanged removed → 挂载中的按钮实时变为未收藏", async () => {
    // 预置已收藏缓存（模拟其他界面先收藏）
    applyFavoriteChanged("voice", "8", 66);
    render(<FavoriteButton targetType="voice" targetId="8" compact />);
    const btn = await screen.findByRole("button", { name: "取消收藏" });
    expect(btn).toHaveAttribute("aria-pressed", "true");

    act(() => {
      applyFavoriteChanged("voice", "8", null);
    });
    await waitFor(() => expect(btn).toHaveAttribute("aria-pressed", "false"));
    expect(btn).toHaveAttribute("aria-label", "收藏");
  });

  it("其他 target 的变更不影响本按钮", async () => {
    render(<FavoriteButton targetType="game" targetId="1" compact />);
    const btn = await screen.findByRole("button", { name: "收藏" });

    act(() => {
      applyFavoriteChanged("game", "2", 77);
    });
    await waitFor(() => expect(btn).toHaveAttribute("aria-pressed", "false"));
  });
});
