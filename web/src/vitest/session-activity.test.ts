import { beforeEach, describe, expect, it } from "vitest";
import { useSessionActivityStore } from "../stores/sessionActivity";

describe("SessionActivityStore", () => {
  beforeEach(() => useSessionActivityStore.getState().reset());

  it("记录并更新媒体会话状态", () => {
    useSessionActivityStore.getState().upsert({
      kind: "voice",
      sessionId: "v1",
      sourceRoute: "/voice",
      owner: "u1",
      title: "深夜电台",
      status: "connecting",
      lastError: null,
    });
    useSessionActivityStore.getState().setStatus("voice", "connected");
    expect(useSessionActivityStore.getState().voiceSession).toMatchObject({
      sessionId: "v1",
      status: "connected",
    });
  });

  it("清理时保留 ended 事实，显式 idle 才移除", () => {
    useSessionActivityStore.getState().upsert({
      kind: "live",
      sessionId: "3",
      sourceRoute: "/live/3",
      owner: null,
      title: "夜空直播",
      status: "connected",
      lastError: null,
    });
    useSessionActivityStore.getState().clear("live");
    expect(useSessionActivityStore.getState().liveSession?.status).toBe("ended");
    useSessionActivityStore.getState().clear("live", "idle");
    expect(useSessionActivityStore.getState().liveSession).toBeNull();
  });
});
