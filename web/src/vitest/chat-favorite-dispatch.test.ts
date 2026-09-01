/**
 * chatWS favorite.changed 分发测试（任务 07）：
 * - post 类型 → 更新 posts store（favoriteByPostId）；
 * - 其他类型（live/voice/game/message）→ 调 applyFavoriteChanged 更新 FavoriteButton 缓存。
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { applyFavoriteChanged } from "../components/FavoriteButton";
import { usePostsStore } from "../stores/posts";
import { chatWS } from "../ws/chat";

vi.mock("../components/FavoriteButton", () => ({
  applyFavoriteChanged: vi.fn(),
}));

/** 访问私有 dispatch（测试胶水逻辑用） */
function dispatch(frame: unknown) {
  (chatWS as unknown as { dispatch: (f: unknown) => void }).dispatch(frame);
}

beforeEach(() => {
  usePostsStore.getState().reset();
  vi.mocked(applyFavoriteChanged).mockClear();
});

afterEach(() => {
  usePostsStore.getState().reset();
});

describe("chatWS favorite.changed 分发（任务 07）", () => {
  it("post added → posts store 记录收藏 id", () => {
    dispatch({
      type: "favorite.changed",
      data: { target_type: "post", target_id: "10", favorite_id: 5, action: "added" },
    });
    expect(usePostsStore.getState().favoriteByPostId["10"]).toBe(5);
  });

  it("post removed → posts store 清空收藏态", () => {
    usePostsStore.getState().setFavorite("10", 5);
    dispatch({
      type: "favorite.changed",
      data: { target_type: "post", target_id: "10", favorite_id: 5, action: "removed" },
    });
    expect(usePostsStore.getState().favoriteByPostId["10"]).toBeUndefined();
  });

  it("live added → 调 applyFavoriteChanged 更新 FavoriteButton 缓存", () => {
    dispatch({
      type: "favorite.changed",
      data: { target_type: "live", target_id: "3", favorite_id: 7, action: "added" },
    });
    expect(applyFavoriteChanged).toHaveBeenCalledWith("live", "3", 7);
  });

  it("game removed → 调 applyFavoriteChanged 清空缓存", () => {
    dispatch({
      type: "favorite.changed",
      data: { target_type: "game", target_id: "9", favorite_id: 8, action: "removed" },
    });
    expect(applyFavoriteChanged).toHaveBeenCalledWith("game", "9", null);
  });
});
