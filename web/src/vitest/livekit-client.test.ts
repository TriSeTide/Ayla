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
  type LiveKitEvents,
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
    setLocalVolume: vi.fn().mockResolvedValue(undefined),
    getLocalVolume: vi.fn().mockReturnValue(1),
    remoteParticipants: vi.fn().mockReturnValue([]),
  };
  return Object.assign(base, overrides) as unknown as ReturnType<typeof fakeRoom>;
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
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
    expect(room.disconnect).toHaveBeenCalledTimes(1);
    await expect(client.setMicrophoneEnabled(true)).rejects.toThrow("LiveKit 未连接");
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

  it("Room 工厂收到受当前 owner 约束的事件回调", async () => {
    const events = { onStateChange: vi.fn() };
    client.setEvents(events);
    const factory = vi.fn().mockImplementation((ev) => {
      ev.onStateChange?.("connected");
      return fakeRoom();
    });
    client.setRoomFactory(factory);
    await client.connect("ws://lk", "t");
    expect(factory).toHaveBeenCalled();
    expect(events.onStateChange).toHaveBeenCalledWith("connected");
  });

  it("新 connect 立即取消 pending factory，旧产物只断开自己且不会开始连接", async () => {
    const pending = deferred<LiveKitRoomLike>();
    const oldRoom = fakeRoom();
    const currentRoom = fakeRoom();
    const factory = vi.fn().mockReturnValueOnce(pending.promise).mockReturnValueOnce(currentRoom);
    client.setRoomFactory(factory);
    const oldResult = client.connect("ws://lk", "old").catch((error: unknown) => error);
    await vi.waitFor(() => expect(factory).toHaveBeenCalledTimes(1));

    await client.connect("ws://lk", "current");
    expect(await oldResult).toMatchObject({ name: "AbortError" });
    pending.resolve(oldRoom);
    await vi.waitFor(() => expect(oldRoom.disconnect).toHaveBeenCalledTimes(1));
    expect(oldRoom.connect).not.toHaveBeenCalled();
    expect(currentRoom.disconnect).not.toHaveBeenCalled();
    await client.setMicrophoneEnabled(true);
    expect(currentRoom.setMicrophoneEnabled).toHaveBeenCalledWith(true);
  });

  it("disconnect 在 factory 返回前撤销 owner，取消不等待 factory", async () => {
    const pending = deferred<LiveKitRoomLike>();
    const room = fakeRoom();
    client.setRoomFactory(() => pending.promise);
    const result = client.connect("ws://lk", "old").catch((error: unknown) => error);
    await client.disconnect();
    expect(await result).toMatchObject({ name: "AbortError" });
    pending.resolve(room);
    await vi.waitFor(() => expect(room.disconnect).toHaveBeenCalledTimes(1));
    expect(room.connect).not.toHaveBeenCalled();
  });

  it("迟到 connect 完成会再次清理旧 room，不能断开已连接的新 room", async () => {
    const pendingConnect = deferred<void>();
    const oldRoom = fakeRoom({ connect: vi.fn().mockReturnValue(pendingConnect.promise) });
    const currentRoom = fakeRoom();
    client.setRoomFactory(vi.fn().mockReturnValueOnce(oldRoom).mockReturnValueOnce(currentRoom));
    const oldResult = client.connect("ws://lk", "old").catch((error: unknown) => error);
    await vi.waitFor(() => expect(oldRoom.connect).toHaveBeenCalledTimes(1));

    await client.connect("ws://lk", "current");
    expect(await oldResult).toMatchObject({ name: "AbortError" });
    expect(oldRoom.disconnect).toHaveBeenCalledTimes(1);
    pendingConnect.resolve();
    await vi.waitFor(() => expect(oldRoom.disconnect).toHaveBeenCalledTimes(2));
    expect(currentRoom.disconnect).not.toHaveBeenCalled();
    await client.setMicrophoneEnabled(false);
    expect(currentRoom.setMicrophoneEnabled).toHaveBeenCalledWith(false);
  });

  it("disconnect 中途取消 pending connect，SDK 晚失败不恢复 owner", async () => {
    const pendingConnect = deferred<void>();
    const room = fakeRoom({ connect: vi.fn().mockReturnValue(pendingConnect.promise) });
    client.setRoomFactory(() => room);
    const result = client.connect("ws://lk", "old").catch((error: unknown) => error);
    await vi.waitFor(() => expect(room.connect).toHaveBeenCalledTimes(1));
    await client.disconnect();
    expect(await result).toMatchObject({ name: "AbortError" });
    pendingConnect.reject(new Error("late SDK failure"));
    await vi.waitFor(() => expect(room.disconnect).toHaveBeenCalledTimes(2));
    await expect(client.setMicrophoneEnabled(true)).rejects.toThrow("LiveKit 未连接");
  });

  it("旧 disconnect 晚完成不清空新 owner，旧 close 并发请求合并", async () => {
    const pendingClose = deferred<void>();
    const oldRoom = fakeRoom({ disconnect: vi.fn().mockReturnValue(pendingClose.promise) });
    const currentRoom = fakeRoom();
    client.setRoomFactory(vi.fn().mockReturnValueOnce(oldRoom).mockReturnValueOnce(currentRoom));
    await client.connect("ws://lk", "old");
    const close = client.disconnect();
    await client.disconnect();
    await client.connect("ws://lk", "current");
    pendingClose.resolve();
    await close;
    expect(oldRoom.disconnect).toHaveBeenCalledTimes(1);
    expect(currentRoom.disconnect).not.toHaveBeenCalled();
    await client.setLocalVolume(0.4);
    expect(currentRoom.setLocalVolume).toHaveBeenCalledWith(0.4);
  });

  it("旧 room 全部事件失效，当前 room 只写自己的监听者", async () => {
    const handlers = (): Required<LiveKitEvents> => ({
      onStateChange: vi.fn(), onParticipantJoined: vi.fn(), onParticipantLeft: vi.fn(),
      onTrackMuted: vi.fn(), onActiveSpeakers: vi.fn(), onLocalAudioLevel: vi.fn(), onRemoteAudioLevels: vi.fn(),
    });
    const emit = (events: LiveKitEvents) => {
      events.onStateChange?.("failed");
      events.onParticipantJoined?.("u1");
      events.onParticipantLeft?.("u2");
      events.onTrackMuted?.("u1", true);
      events.onActiveSpeakers?.(["u1"]);
      events.onLocalAudioLevel?.(0.5);
      events.onRemoteAudioLevels?.({ u1: 0.4 });
    };
    const callbacks: LiveKitEvents[] = [];
    client.setRoomFactory((events) => { callbacks.push(events); return fakeRoom(); });
    const oldEvents = handlers();
    const currentEvents = handlers();
    client.setEvents(oldEvents);
    await client.connect("ws://lk", "old");
    client.setEvents(currentEvents);
    await client.connect("ws://lk", "current");
    emit(callbacks[0]!);
    for (const handler of [...Object.values(oldEvents), ...Object.values(currentEvents)]) {
      expect(handler).not.toHaveBeenCalled();
    }
    emit(callbacks[1]!);
    for (const handler of Object.values(currentEvents)) expect(handler).toHaveBeenCalledTimes(1);
    await client.disconnect();
    emit(callbacks[1]!);
    for (const handler of Object.values(currentEvents)) expect(handler).toHaveBeenCalledTimes(1);
  });

  it("旧媒体操作 await 完成不操作新 room，也不向调用者报告旧会话成功", async () => {
    const microphone = deferred<void>();
    const audio = deferred<void>();
    const volume = deferred<void>();
    const oldRoom = fakeRoom({
      setMicrophoneEnabled: vi.fn().mockReturnValue(microphone.promise),
      startAudio: vi.fn().mockReturnValue(audio.promise),
      setLocalVolume: vi.fn().mockReturnValue(volume.promise),
    });
    const currentRoom = fakeRoom();
    client.setRoomFactory(vi.fn().mockReturnValueOnce(oldRoom).mockReturnValueOnce(currentRoom));
    await client.connect("ws://lk", "old");
    const actions = [client.setMicrophoneEnabled(true), client.startAudio(), client.setLocalVolume(0.5)]
      .map((operation) => operation.catch((error: unknown) => error));
    await client.connect("ws://lk", "current");
    microphone.resolve();
    audio.resolve();
    volume.resolve();
    for (const result of await Promise.all(actions)) expect(result).toMatchObject({ name: "AbortError" });
    expect(currentRoom.setMicrophoneEnabled).not.toHaveBeenCalled();
    expect(currentRoom.startAudio).not.toHaveBeenCalled();
    expect(currentRoom.setLocalVolume).not.toHaveBeenCalled();
  });

  it("被撤销的 factory 晚失败不盖掉新 owner，当前工厂失败保留原错误", async () => {
    const pending = deferred<LiveKitRoomLike>();
    const room = fakeRoom();
    client.setRoomFactory(vi.fn().mockReturnValueOnce(pending.promise).mockReturnValueOnce(room));
    const result = client.connect("ws://lk", "old").catch((error: unknown) => error);
    await client.connect("ws://lk", "current");
    expect(await result).toMatchObject({ name: "AbortError" });
    pending.reject(new Error("old factory error"));
    await client.setMicrophoneEnabled(true);
    expect(room.setMicrophoneEnabled).toHaveBeenCalledWith(true);
    client.setRoomFactory(() => { throw new Error("current factory error"); });
    await expect(client.connect("ws://lk", "current")).rejects.toThrow("current factory error");
  });
});
