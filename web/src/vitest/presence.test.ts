/**
 * presence store 测试：增量 update 合并/移除、全量替换、连接状态。
 */
import { describe, expect, it, beforeEach } from "vitest";
import { usePresenceStore } from "../stores/presence";

beforeEach(() => {
  usePresenceStore.getState().reset();
});

describe("presence store", () => {
  it("presence.update 增量 → 合并到集合", () => {
    usePresenceStore.getState().setUser("u1", "online");
    usePresenceStore.getState().setUser("u2", "away");
    expect(usePresenceStore.getState().users).toEqual({ u1: "online", u2: "away" });
  });

  it("offline 增量 → 移除", () => {
    usePresenceStore.getState().setUser("u1", "online");
    usePresenceStore.getState().removeUser("u1");
    expect(usePresenceStore.getState().users).toEqual({});
  });

  it("replaceAll → 全量替换", () => {
    usePresenceStore.getState().setUser("u1", "online");
    usePresenceStore.getState().replaceAll({ u3: "dnd" });
    expect(usePresenceStore.getState().users).toEqual({ u3: "dnd" });
  });

  it("连接状态流转", () => {
    const s = usePresenceStore.getState();
    s.setConnection("connecting");
    s.setConnection("online");
    expect(usePresenceStore.getState().connection).toBe("online");
    usePresenceStore.getState().reset();
    expect(usePresenceStore.getState().connection).toBe("offline");
  });
});
