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

  it("offline 已知状态保留记录（显示层区分「未收到」与「已离线」）", () => {
    usePresenceStore.getState().setUser("u1", "online");
    usePresenceStore.getState().setUser("u1", "offline");
    expect(usePresenceStore.getState().users).toEqual({ u1: "offline" });
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

  it("presence.status 增量 → 状态模式映射（勿扰/离开/隐身/自动）", () => {
    usePresenceStore.getState().setUserStatus("u1", "dnd");
    usePresenceStore.getState().setUserStatus("u2", "invisible");
    expect(usePresenceStore.getState().statuses).toEqual({
      u1: "dnd",
      u2: "invisible",
    });
  });

  it("reset 清空 statuses", () => {
    usePresenceStore.getState().setUserStatus("u1", "away");
    usePresenceStore.getState().reset();
    expect(usePresenceStore.getState().statuses).toEqual({});
  });
});
