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

  it("恢复在线后清除旧错误，离线不会伪装成失败", () => {
    useRealtimeStore.getState().setStatus("live", "failed", "服务不可用");
    useRealtimeStore.getState().setStatus("live", "online");
    useRealtimeStore.getState().setStatus("voice", "offline");
    expect(useRealtimeStore.getState().statuses.live).toMatchObject({ connection: "online", lastError: null });
    expect(useRealtimeStore.getState().statuses.voice).toMatchObject({ connection: "offline", lastError: null });
  });
});
