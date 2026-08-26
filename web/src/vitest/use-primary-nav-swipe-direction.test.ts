/**
 * usePrimaryNavSwipeDirection / primaryTabDirection 测试（方案 §3.1）：
 * 索引差方向计算 + hook 跟踪（与群内 useSceneSwipeDirection 同构）。
 */
import { renderHook } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import {
  isPrimaryTabPath,
  primaryTabDirection,
  primaryTabIndex,
  usePrimaryNavSwipeDirection,
} from "../hooks/usePrimaryNavSwipeDirection";

describe("primaryTabIndex", () => {
  it("五个一级 tab 按视觉顺序（语音|直播|主页|帖子|桌游）索引", () => {
    expect(primaryTabIndex("/voice")).toBe(0);
    expect(primaryTabIndex("/live")).toBe(1);
    expect(primaryTabIndex("/group")).toBe(2);
    expect(primaryTabIndex("/posts")).toBe(3);
    expect(primaryTabIndex("/games")).toBe(4);
  });

  it("/home 是 /group 兼容别名，归主页索引", () => {
    expect(primaryTabIndex("/home")).toBe(primaryTabIndex("/group"));
  });

  it("非一级页返回 -1（子路由/群聊/消息等）", () => {
    expect(primaryTabIndex("/messages")).toBe(-1);
    expect(primaryTabIndex("/group/g1")).toBe(-1);
    expect(primaryTabIndex("/live/42")).toBe(-1);
    expect(primaryTabIndex("/search")).toBe(-1);
  });
});

describe("isPrimaryTabPath", () => {
  it("五个一级 tab 路由命中（含 /home 兼容）", () => {
    for (const path of ["/voice", "/live", "/group", "/home", "/posts", "/games"]) {
      expect(isPrimaryTabPath(path)).toBe(true);
    }
  });

  it("非一级页不命中", () => {
    for (const path of ["/messages", "/search", "/profile", "/group/g1", "/live/42", "/posts/p1"]) {
      expect(isPrimaryTabPath(path)).toBe(false);
    }
  });
});

describe("primaryTabDirection", () => {
  it("索引增大 → 1（左滑切下一个）", () => {
    expect(primaryTabDirection("/voice", "/live")).toBe(1);
    expect(primaryTabDirection("/group", "/posts")).toBe(1);
  });

  it("索引减小 → -1（右滑切上一个）", () => {
    expect(primaryTabDirection("/live", "/voice")).toBe(-1);
    expect(primaryTabDirection("/posts", "/group")).toBe(-1);
  });

  it("索引相同 → 0（含 /home ↔ /group 兼容别名）", () => {
    expect(primaryTabDirection("/group", "/group")).toBe(0);
    expect(primaryTabDirection("/group", "/home")).toBe(0);
    expect(primaryTabDirection("/home", "/group")).toBe(0);
  });

  it("跨多级按符号判定（voice → games = 1）", () => {
    expect(primaryTabDirection("/voice", "/games")).toBe(1);
    expect(primaryTabDirection("/games", "/voice")).toBe(-1);
  });

  it("任一端非一级页 → 0（无横向位移，走普通淡入淡出）", () => {
    expect(primaryTabDirection("/messages", "/voice")).toBe(0);
    expect(primaryTabDirection("/voice", "/messages")).toBe(0);
    expect(primaryTabDirection("/group/g1", "/group")).toBe(0);
  });
});

describe("usePrimaryNavSwipeDirection", () => {
  it("挂载首帧无切换 → 0", () => {
    const { result } = renderHook(() => usePrimaryNavSwipeDirection("/voice"));
    expect(result.current).toBe(0);
  });

  it("pathname 变化 → 返回本次切换方向", () => {
    const { result, rerender } = renderHook(
      ({ path }: { path: string }) => usePrimaryNavSwipeDirection(path),
      { initialProps: { path: "/voice" } },
    );
    expect(result.current).toBe(0);

    rerender({ path: "/live" });
    expect(result.current).toBe(1);

    rerender({ path: "/voice" });
    expect(result.current).toBe(-1);
  });

  it("一级页 ↔ 非一级页 → 0", () => {
    const { result, rerender } = renderHook(
      ({ path }: { path: string }) => usePrimaryNavSwipeDirection(path),
      { initialProps: { path: "/voice" } },
    );
    rerender({ path: "/messages" });
    expect(result.current).toBe(0);
    rerender({ path: "/posts" });
    expect(result.current).toBe(0);
  });
});
