/**
 * livekit/client.ts 封装单测（mock Room 工厂注入 fake，M5-3 §7.1）：
 * - connect 传 ws_url/token 给 Room；失败向上抛（调用方回滚）
 * - 静音切换：调 setMicrophoneEnabled；失败抛错由调用方回滚 UI
 * - 远端音量：只调对应 identity 的轨道 setVolume（0~1 clamp），不影响他人
 * - 事件归一：Reconnecting/Reconnected/Disconnected → onStateChange 映射
 * - disconnect 幂等
 */
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  VoiceLiveKitClient,
  type LiveKitRoomLike,
  type RemoteAudioTrackLike,
} from "../livekit/client";

function fakeTrack(): RemoteAudioTrackLike & { setVolume: ReturnType<typeof vi.fn> } {
  return { setVolume: vi.fn() };
}

function fakeRoom(overrides: Partial<LiveKitRoomLike> = {}): LiveKitRoomLike & {
  connect: ReturnType<typeof vi.fn>;
  disconnect: ReturnType<typeof vi.fn>;
  setMicrophoneEnabled: ReturnType<typeof vi.fn>;
} {
  const base = {
    connect: vi.fn().mockResolvedValue(undefined),
    disconnect: vi.fn().mockResolvedValue(undefined),
    setMicrophoneEnabled: vi.fn().mockResolvedValue(undefined),
    isMicrophoneEnabled: vi.fn().mockReturnValue(false),
    startAudio: vi.fn().mockResolvedValue(undefined),
    remoteParticipants: vi.fn().mockReturnValue([]),
  };
  return Object.assign(base, overrides) as unknown as ReturnType<typeof fakeRoom>;
}

let client: VoiceLiveKitClient;

beforeEach(() => {
  client = new VoiceLiveKitClient();
});

describe("VoiceLiveKitClient", () => {
  it("connect → 工厂建 Room 并传 ws_url/token；重复 connect 先断开旧 Room", async () => {
    const room1 = fakeRoom();
    const room2 = fakeRoom();
    const factory = vi.fn().mockResolvedValueOnce(room1).mockResolvedValueOnce(room2);
    client.setRoomFactory(factory);

    await client.connect("ws://lk", "token-1");
    expect(room1.connect).toHaveBeenCalledWith("ws://lk", "token-1");

    await client.connect("ws://lk", "token-2");
    expect(room1.disconnect).toHaveBeenCalled();
    expect(room2.connect).toHaveBeenCalledWith("ws://lk", "token-2");
  });

  it("connect 失败向上抛（调用方负责 leave/ 回滚）", async () => {
    const room = fakeRoom({ connect: vi.fn().mockRejectedValue(new Error("token expired")) });
    client.setRoomFactory(() => room);
    await expect(client.connect("ws://lk", "bad-token")).rejects.toThrow("token expired");
  });

  it("静音切换调 setMicrophoneEnabled；失败向上抛（调用方回滚乐观 UI）", async () => {
    const room = fakeRoom({
      setMicrophoneEnabled: vi.fn().mockRejectedValue(new Error("权限被拒")),
    });
    client.setRoomFactory(() => room);
    await client.connect("ws://lk", "t");
    await expect(client.setMicrophoneEnabled(true)).rejects.toThrow("权限被拒");
  });

  it("未连接时 setMicrophoneEnabled 抛错", async () => {
    await expect(client.setMicrophoneEnabled(true)).rejects.toThrow("LiveKit 未连接");
  });

  it("setRemoteVolume 只影响对应 identity 的轨道，音量 clamp 到 0~1", async () => {
    const trackA = fakeTrack();
    const trackB = fakeTrack();
    const room = fakeRoom({
      remoteParticipants: vi.fn().mockReturnValue([
        { identity: "u1", audioTracks: [trackA] },
        { identity: "u2", audioTracks: [trackB] },
      ]),
    });
    client.setRoomFactory(() => room);
    await client.connect("ws://lk", "t");

    client.setRemoteVolume("u1", 0.5);
    expect(trackA.setVolume).toHaveBeenCalledWith(0.5);
    expect(trackB.setVolume).not.toHaveBeenCalled();

    client.setRemoteVolume("u2", 150); // 超界 → clamp 1
    expect(trackB.setVolume).toHaveBeenCalledWith(1);
  });

  it("disconnect 幂等：重复调用不报错", async () => {
    const room = fakeRoom();
    client.setRoomFactory(() => room);
    await client.connect("ws://lk", "t");
    await client.disconnect();
    await client.disconnect();
    expect(room.disconnect).toHaveBeenCalledTimes(1);
  });

  it("Room 工厂收到 events 引用（真实实现据此挂 Reconnecting/Reconnected 等监听）", async () => {
    const events = { onStateChange: vi.fn() };
    client.setEvents(events);
    const factory = vi.fn().mockImplementation((ev) => {
      expect(ev).toBe(events);
      return fakeRoom();
    });
    client.setRoomFactory(factory);
    await client.connect("ws://lk", "t");
    expect(factory).toHaveBeenCalled();
  });
});
