import { ensureFavoriteScope, useFavoriteStatusStore } from "../stores/favoriteStatus";
/**
 * FavoriteButton WS 订阅机制测试（任务 07）：
 * applyFavoriteChanged 更新模块缓存并通知挂载中的按钮，
 * 同账号其他界面的收藏操作实时反映到本按钮（live/voice/game/message 类型）。
 */
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as favoritesApi from "../api/favorites";
import { applyFavoriteChanged, FavoriteButton } from "../components/FavoriteButton";

vi.mock("../api/favorites", () => ({
  listFavorites: vi.fn(),
  getFavoriteStatuses: vi.fn(),
  addFavorite: vi.fn(),
  removeFavorite: vi.fn(),
}));

beforeEach(() => {
  ensureFavoriteScope();
  useFavoriteStatusStore.setState({ entries: new Map() });
  vi.mocked(favoritesApi.getFavoriteStatuses).mockImplementation(async (target_type, ids) => ({ target_type, statuses: Object.fromEntries(ids.map((id) => [id, null])) }));
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

  it("状态失败保持未知；点击只重试状态，不错误地新增收藏", async () => {
    vi.mocked(favoritesApi.getFavoriteStatuses).mockRejectedValueOnce(new Error("暂时离线"));
    render(<FavoriteButton targetType="post" targetId="5" compact />);
    const button = await screen.findByRole("button", { name: "收藏状态加载失败，点击重试" });
    expect(button).not.toHaveAttribute("aria-pressed");
    fireEvent.click(button);
    await screen.findByRole("button", { name: "收藏" });
    expect(favoritesApi.addFavorite).not.toHaveBeenCalled();
    expect(favoritesApi.getFavoriteStatuses).toHaveBeenCalledTimes(2);
  });

  it("延迟状态响应不能清掉读取期间到达的 WS 收藏", async () => {
    let resolve!: (value: favoritesApi.FavoriteStatuses) => void;
    vi.mocked(favoritesApi.getFavoriteStatuses).mockReturnValueOnce(new Promise((yes) => { resolve = yes; }));
    render(<FavoriteButton targetType="post" targetId="6" compact />);
    await waitFor(() => expect(favoritesApi.getFavoriteStatuses).toHaveBeenCalled());
    act(() => applyFavoriteChanged("post", "6", 66));
    const button = await screen.findByRole("button", { name: "取消收藏" });
    await act(async () => resolve({ target_type: "post", statuses: { "6": null } }));
    expect(button).toHaveAttribute("aria-pressed", "true");
  });
});
