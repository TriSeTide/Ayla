/**
 * posts store 测试（F6）：游标分页追加去重 + 收藏集合 set/load。
 */
import { beforeEach, describe, expect, it } from "vitest";
import type { Post } from "../api/types";
import { usePostsStore } from "../stores/posts";

function post(id: number): Post {
  return {
    id,
    author: {
      id: "u1",
      username: "alice",
      nickname: "爱丽丝",
      avatar: "",
      signature: "",
      status: "online",
      online: true,
      date_joined: "2026-01-01T00:00:00Z",
    },
    author_id: "u1",
    title: "",
    body: `正文${id}`,
    visibility: "public",
    group: null,
    group_name: null,
    images: [],
    comment_count: 0,
    is_author: true,
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
  };
}

beforeEach(() => {
  usePostsStore.getState().reset();
});

describe("posts store 游标分页", () => {
  it("setPage 重置列表", () => {
    usePostsStore.getState().setPage([post(1), post(2)], "cur", true);
    expect(usePostsStore.getState().posts.map((p) => p.id)).toEqual([1, 2]);
    expect(usePostsStore.getState().hasMore).toBe(true);
  });

  it("appendPage 按 id 去重（重复不分页尾）", () => {
    usePostsStore.getState().setPage([post(1), post(2)], "cur", true);
    usePostsStore.getState().appendPage([post(2), post(3)], "cur2", false);
    expect(usePostsStore.getState().posts.map((p) => p.id)).toEqual([1, 2, 3]);
  });
});

describe("posts store 收藏", () => {
  it("setFavorite 记录 / 取消", () => {
    usePostsStore.getState().setFavorite("1", 5);
    expect(usePostsStore.getState().favoriteByPostId["1"]).toBe(5);
    usePostsStore.getState().setFavorite("1", null);
    expect(usePostsStore.getState().favoriteByPostId["1"]).toBeUndefined();
  });

  it("loadFavorites 批量铺底", () => {
    usePostsStore
      .getState()
      .loadFavorites([
        { id: 1, target_id: "10" },
        { id: 2, target_id: "11" },
      ]);
    expect(usePostsStore.getState().favoriteByPostId).toEqual({ "10": 1, "11": 2 });
  });
});
