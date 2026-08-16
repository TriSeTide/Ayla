import { beforeEach, describe, expect, it } from "vitest";
import { useRealtimeStore } from "../stores/realtime";

describe("RealtimeStore", () => {
  beforeEach(() => useRealtimeStore.getState().reset());

  it("分别保存各通道连接事实和错误", () => {
    useRealtimeStore.getState().setStatus("chat", "connecting");
    useRealtimeStore.getState().setStatus("presence", "failed", "403");
    expect(useRealtimeStore.getState().statuses.chat.connection).toBe("connecting");
    expect(useRealtimeStore.getState().statuses.presence).toMatchObject({ connection: "failed", lastError: "403" });
  });
});
