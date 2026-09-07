import { act, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useVoiceRecorder } from "../hooks/useVoiceRecorder";

const behavior = { startThrows: false, stopThrows: false };
class FakeRecorder {
  static instances: FakeRecorder[] = [];
  static isTypeSupported = () => true;
  state = "inactive";
  mimeType = "audio/webm";
  ondataavailable: ((event: { data: Blob }) => void) | null = null;
  onstop: (() => void) | null = null;
  onerror: (() => void) | null = null;
  start = vi.fn(() => {
    if (behavior.startThrows) throw new DOMException("start failed", "InvalidStateError");
    this.state = "recording";
  });
  stop = vi.fn(() => {
    if (behavior.stopThrows) throw new DOMException("stop failed", "InvalidStateError");
    this.state = "inactive";
  });
  constructor() { FakeRecorder.instances.push(this); }
  complete() { this.ondataavailable?.({ data: new Blob(["recorded audio"]) }); this.onstop?.(); }
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((yes) => { resolve = yes; });
  return { promise, resolve };
}
function stream() {
  const track = { stop: vi.fn() };
  return { value: { getTracks: () => [track] } as unknown as MediaStream, track };
}
const getUserMedia = vi.fn();
beforeEach(() => {
  getUserMedia.mockReset();
  FakeRecorder.instances = [];
  behavior.startThrows = false;
  behavior.stopThrows = false;
  vi.stubGlobal("navigator", { mediaDevices: { getUserMedia } });
  vi.stubGlobal("MediaRecorder", FakeRecorder);
});
afterEach(() => { vi.useRealTimers(); vi.unstubAllGlobals(); });

describe("voice recorder resource ownership", () => {
  it("permission denial is visible state and resolves without an unhandled rejection", async () => {
    getUserMedia.mockRejectedValue(new DOMException("denied", "NotAllowedError"));
    const { result } = renderHook(useVoiceRecorder);
    await act(async () => { await expect(result.current.start()).resolves.toBeUndefined(); });
    expect(result.current.error).toBe("麦克风权限被拒绝");
    expect(result.current.starting).toBe(false);
    expect(result.current.recording).toBe(false);
  });

  it("duplicate start while permission is pending acquires only one stream", async () => {
    const pending = deferred<MediaStream>();
    const acquired = stream();
    getUserMedia.mockReturnValue(pending.promise);
    const { result } = renderHook(useVoiceRecorder);
    let first!: Promise<void>;
    act(() => { first = result.current.start(); void result.current.start(); });
    expect(result.current.starting).toBe(true);
    expect(getUserMedia).toHaveBeenCalledTimes(1);
    await act(async () => { pending.resolve(acquired.value); await first; });
    expect(FakeRecorder.instances).toHaveLength(1);
    expect(result.current.recording).toBe(true);
  });

  it.each(["cancel", "unmount"] as const)("%s before permission resolves releases the late stream without starting a recorder", async (action) => {
    const pending = deferred<MediaStream>();
    const acquired = stream();
    getUserMedia.mockReturnValue(pending.promise);
    const view = renderHook(useVoiceRecorder);
    let request!: Promise<void>;
    act(() => { request = view.result.current.start(); });
    if (action === "cancel") act(() => view.result.current.cancel());
    else view.unmount();
    await act(async () => { pending.resolve(acquired.value); await request; });
    expect(acquired.track.stop).toHaveBeenCalledTimes(1);
    expect(FakeRecorder.instances).toHaveLength(0);
  });

  it("duplicate stop shares its result, calls MediaRecorder once and releases every resource", async () => {
    const acquired = stream();
    getUserMedia.mockResolvedValue(acquired.value);
    const { result } = renderHook(useVoiceRecorder);
    await act(async () => result.current.start());
    let first!: Promise<unknown>, second!: Promise<unknown>;
    act(() => { first = result.current.stop(); second = result.current.stop(); });
    expect(first).toBe(second);
    expect(result.current.stopping).toBe(true);
    expect(FakeRecorder.instances[0].stop).toHaveBeenCalledTimes(1);
    await act(async () => { FakeRecorder.instances[0].complete(); await first; });
    expect(await first).toMatchObject({ mimeType: "audio/webm" });
    expect(acquired.track.stop).toHaveBeenCalledTimes(1);
    expect(result.current.recording).toBe(false);
  });

  it("stop throwing returns null, shows a retryable failure and releases the stream", async () => {
    const acquired = stream();
    getUserMedia.mockResolvedValue(acquired.value);
    const { result } = renderHook(useVoiceRecorder);
    await act(async () => result.current.start());
    behavior.stopThrows = true;
    await act(async () => { await expect(result.current.stop()).resolves.toBeNull(); });
    expect(result.current.error).toBe("停止录音失败，请重试");
    expect(result.current.recording).toBe(false);
    expect(acquired.track.stop).toHaveBeenCalledTimes(1);
  });

  it("missing onstop has a finite deadline and cannot leave the UI recording forever", async () => {
    vi.useFakeTimers();
    const acquired = stream();
    getUserMedia.mockResolvedValue(acquired.value);
    const { result } = renderHook(useVoiceRecorder);
    await act(async () => result.current.start());
    let stopped!: Promise<unknown>;
    act(() => { stopped = result.current.stop(); });
    await act(async () => { await vi.advanceTimersByTimeAsync(5000); });
    expect(await stopped).toBeNull();
    expect(result.current.error).toBe("停止录音超时，请重试");
    expect(acquired.track.stop).toHaveBeenCalledTimes(1);
  });

  it("unmount during stop settles the pending result and detaches late events", async () => {
    const acquired = stream();
    getUserMedia.mockResolvedValue(acquired.value);
    const view = renderHook(useVoiceRecorder);
    await act(async () => view.result.current.start());
    let stopped!: Promise<unknown>;
    act(() => { stopped = view.result.current.stop(); });
    view.unmount();
    expect(await stopped).toBeNull();
    expect(FakeRecorder.instances[0].onstop).toBeNull();
    expect(acquired.track.stop).toHaveBeenCalledTimes(1);
  });

  it("recorder start failure and runtime error both release the acquired stream", async () => {
    const first = stream(), second = stream();
    getUserMedia.mockResolvedValueOnce(first.value).mockResolvedValueOnce(second.value);
    const { result } = renderHook(useVoiceRecorder);
    behavior.startThrows = true;
    await act(async () => result.current.start());
    expect(first.track.stop).toHaveBeenCalledTimes(1);
    expect(result.current.error).toBe("无法启动录音，请重试");
    behavior.startThrows = false;
    await act(async () => result.current.start());
    act(() => FakeRecorder.instances[1].onerror?.());
    expect(second.track.stop).toHaveBeenCalledTimes(1);
    expect(result.current.error).toBe("录音失败，请重试");
  });

  it("cancel discards an otherwise valid recording", async () => {
    getUserMedia.mockResolvedValue(stream().value);
    const { result } = renderHook(useVoiceRecorder);
    await act(async () => result.current.start());
    let stopped!: Promise<unknown>;
    act(() => { stopped = result.current.stop(); result.current.cancel(); });
    await act(async () => { FakeRecorder.instances[0].complete(); await stopped; });
    expect(await stopped).toBeNull();
  });
});
