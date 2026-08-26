/**
 * useSceneSwipeDirection / sceneDirection 测试：索引差方向计算 + hook 跟踪。
 */
import { renderHook } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import type { GroupScene } from "../stores/group";
import { sceneDirection, sceneOrderIndex, useSceneSwipeDirection } from "../hooks/useSceneSwipeDirection";

describe("sceneOrderIndex", () => {
  it("五子场景按 GROUP_SCENE_ORDER 索引", () => {
    expect(sceneOrderIndex("voice")).toBe(0);
    expect(sceneOrderIndex("live")).toBe(1);
    expect(sceneOrderIndex("chat")).toBe(2);
    expect(sceneOrderIndex("posts")).toBe(3);
    expect(sceneOrderIndex("games")).toBe(4);
  });

  it("info 不在顺序里，按 chat（居中）索引处理", () => {
    expect(sceneOrderIndex("info")).toBe(sceneOrderIndex("chat"));
  });
});

describe("sceneDirection", () => {
  it("索引增大 → 1（左滑切下一个）", () => {
    expect(sceneDirection("chat", "posts")).toBe(1);
    expect(sceneDirection("voice", "live")).toBe(1);
  });

  it("索引减小 → -1（右滑切上一个）", () => {
    expect(sceneDirection("posts", "chat")).toBe(-1);
    expect(sceneDirection("live", "voice")).toBe(-1);
  });

  it("索引相同 → 0（纯淡入）", () => {
    expect(sceneDirection("chat", "chat")).toBe(0);
    expect(sceneDirection("chat", "info")).toBe(0);
    expect(sceneDirection("info", "chat")).toBe(0);
  });

  it("跨多级按符号判定（voice → games = 1）", () => {
    expect(sceneDirection("voice", "games")).toBe(1);
    expect(sceneDirection("games", "voice")).toBe(-1);
  });
});

describe("useSceneSwipeDirection", () => {
  it("挂载首帧无切换 → 0", () => {
    const { result } = renderHook(() => useSceneSwipeDirection("chat"));
    expect(result.current).toBe(0);
  });

  it("activeScene 变化 → 返回本次切换方向", () => {
    const { result, rerender } = renderHook(
      ({ scene }: { scene: GroupScene }) => useSceneSwipeDirection(scene),
      { initialProps: { scene: "chat" } },
    );
    expect(result.current).toBe(0);

    rerender({ scene: "posts" });
    expect(result.current).toBe(1);

    rerender({ scene: "live" });
    expect(result.current).toBe(-1);
  });

  it("chat ↔ info 同索引 → 0", () => {
    const { result, rerender } = renderHook(
      ({ scene }: { scene: GroupScene }) => useSceneSwipeDirection(scene),
      { initialProps: { scene: "chat" } },
    );
    rerender({ scene: "info" });
    expect(result.current).toBe(0);
    rerender({ scene: "chat" });
    expect(result.current).toBe(0);
  });
});
