/**
 * displayStatus 工具测试（任务 06：在线 → 自动）。
 *
 * - displayStatusOf：纯规则函数（auto 跟随实时 / dnd / away / invisible）；
 * - usePresenceOnline：presence store 已知状态优先，REST 快照兜底；
 * - useDisplayStatus：组合。
 */
import { renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { UserPublic } from "../api/types";
import { usePresenceStore } from "../stores/presence";
import { displayStatusOf, useDisplayStatus, usePresenceOnline } from "../utils/displayStatus";

function user(overrides: Partial<UserPublic> = {}): UserPublic {
  return {
    id: "u1",
    username: "u1",
    nickname: "",
    avatar: "",
    signature: "",
    status: "auto",
    online: false,
    date_joined: "2026-01-01T00:00:00Z",
    ...overrides,
  };
}

beforeEach(() => {
  usePresenceStore.getState().reset();
});

afterEach(() => {
  usePresenceStore.getState().reset();
});

describe("displayStatusOf（纯规则）", () => {
  it("auto 跟随实时在线", () => {
    expect(displayStatusOf(user(), true)).toBe("在线");
    expect(displayStatusOf(user(), false)).toBe("离线");
  });

  it("dnd → 勿扰（不依赖实时）", () => {
    expect(displayStatusOf(user({ status: "dnd" }), true)).toBe("勿扰");
    expect(displayStatusOf(user({ status: "dnd" }), false)).toBe("勿扰");
  });

  it("away → 离开", () => {
    expect(displayStatusOf(user({ status: "away" }), true)).toBe("离开");
  });

  it("invisible → 离线（不暴露在线痕迹）", () => {
    expect(displayStatusOf(user({ status: "invisible" }), true)).toBe("离线");
  });

  it("未知/缺失状态按 auto 兜底", () => {
    expect(displayStatusOf(user({ status: "online" }), true)).toBe("在线");
    expect(displayStatusOf(null, false)).toBe("离线");
  });
});

describe("usePresenceOnline", () => {
  it("presence store 已知 online → 在线（优先于 REST 快照）", () => {
    usePresenceStore.getState().setUser("u1", "online");
    const { result } = renderHook(() => usePresenceOnline(user({ online: false })));
    expect(result.current).toBe(true);
  });

  it("presence store 已知 offline → 离线（优先于 REST 快照）", () => {
    usePresenceStore.getState().setUser("u1", "offline");
    const { result } = renderHook(() => usePresenceOnline(user({ online: true })));
    expect(result.current).toBe(false);
  });

  it("隐身：presence store 有 online 记录也强制离线（不泄漏光环）", () => {
    usePresenceStore.getState().setUser("u1", "online");
    const { result } = renderHook(() =>
      usePresenceOnline(user({ status: "invisible", online: true })),
    );
    expect(result.current).toBe(false);
  });

  it("无记录 → 回退 REST 快照 user.online", () => {
    const { result } = renderHook(() => usePresenceOnline(user({ online: true })));
    expect(result.current).toBe(true);
  });

  it("user 为 null → false", () => {
    const { result } = renderHook(() => usePresenceOnline(null));
    expect(result.current).toBe(false);
  });
});

describe("useDisplayStatus（组合）", () => {
  it("auto + presence 在线 → 在线", () => {
    usePresenceStore.getState().setUser("u1", "online");
    const { result } = renderHook(() => useDisplayStatus(user()));
    expect(result.current).toBe("在线");
  });

  it("dnd + presence 在线 → 勿扰", () => {
    usePresenceStore.getState().setUser("u1", "online");
    const { result } = renderHook(() => useDisplayStatus(user({ status: "dnd" })));
    expect(result.current).toBe("勿扰");
  });

  it("invisible + presence 在线 → 离线", () => {
    usePresenceStore.getState().setUser("u1", "online");
    const { result } = renderHook(() => useDisplayStatus(user({ status: "invisible" })));
    expect(result.current).toBe("离线");
  });
});
