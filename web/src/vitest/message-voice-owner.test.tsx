import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { MessageInput } from "../components/chat/MessageInput";
import { sendMessage } from "../hooks/useChat";
import { uploadMediaFile } from "../api/media";
import type { ChatMessage } from "../api/types";

const recorder = vi.hoisted(() => ({ recording: true, starting: false, stopping: false, elapsed: 1, error: null,
  start: vi.fn(), stop: vi.fn(), cancel: vi.fn(), clearError: vi.fn() }));
vi.mock("../hooks/useVoiceRecorder", () => ({ useVoiceRecorder: () => recorder,
  isVoiceRecordingSupported: () => true, formatDuration: () => "0:01" }));
vi.mock("../hooks/useTyping", () => ({ useTyping: () => ({ onInput: vi.fn() }) }));
vi.mock("../hooks/useChat", () => ({ sendMessage: vi.fn(), sendOptimistic: vi.fn() }));
vi.mock("../api/media", () => ({ uploadMediaFile: vi.fn(), validateMediaFile: vi.fn() }));
vi.mock("../stores/auth", async () => {
  const { create } = await import("zustand");
  return { useAuthStore: create(() => ({ currentUser: { id: "voice-reader" }, accessToken: "test" })) };
});
const recording = () => ({ blob: new Blob(["recording"]), mimeType: "audio/webm", duration: 1.2 });
const uploaded = { media_id: "voice-media", upload_id: "voice-upload", descriptor: {} as never };
const quote = (id: number) => ({ id: String(id), content: `引用 ${id}`, segments: null } as ChatMessage);
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((yes) => { resolve = yes; });
  return { promise, resolve };
}
const input = (convId = "c1", target: ChatMessage | null = null, clear = vi.fn()) => (
  <MemoryRouter><MessageInput convId={convId} quote={target} onQuoteClear={clear} /></MemoryRouter>
);
beforeEach(() => {
  vi.clearAllMocks();
  recorder.recording = true;
  recorder.starting = false;
  recorder.stopping = false;
  recorder.stop.mockResolvedValue(recording());
  vi.mocked(uploadMediaFile).mockReset().mockResolvedValue(uploaded);
  vi.mocked(sendMessage).mockReset().mockResolvedValue({} as never);
});

describe("voice sending owner", () => {
  it("repeated stop clicks before onstop resolves cannot upload or send twice", async () => {
    const pending = deferred<ReturnType<typeof recording>>();
    recorder.stop.mockReturnValue(pending.promise);
    render(input());
    fireEvent.click(screen.getByRole("button", { name: "停止并发送语音" }));
    fireEvent.click(screen.getByRole("button", { name: "停止并发送语音" }));
    expect(recorder.stop).toHaveBeenCalledTimes(1);
    await act(async () => pending.resolve(recording()));
    await waitFor(() => expect(sendMessage).toHaveBeenCalledTimes(1));
    expect(uploadMediaFile).toHaveBeenCalledTimes(1);
  });

  it("retry reuses the uploaded media, original reply and same idempotency key", async () => {
    vi.mocked(sendMessage).mockRejectedValueOnce(new Error("语音发送暂时失败")).mockResolvedValueOnce({} as never);
    const clear = vi.fn();
    const view = render(input("c1", quote(1), clear));
    fireEvent.click(screen.getByRole("button", { name: "停止并发送语音" }));
    await screen.findByRole("button", { name: "重试语音" });
    const first = vi.mocked(sendMessage).mock.calls[0][2];
    view.rerender(input("c1", quote(2), clear));
    fireEvent.click(screen.getByRole("button", { name: "重试语音" }));
    await waitFor(() => expect(sendMessage).toHaveBeenCalledTimes(2));
    expect(uploadMediaFile).toHaveBeenCalledTimes(1);
    expect(vi.mocked(sendMessage).mock.calls[1][2]).toEqual(first);
    expect(first).toMatchObject({ replyTo: 1, mediaId: "voice-media" });
    expect(clear).not.toHaveBeenCalled();
  });

  it("switching conversation aborts upload ownership and prevents a late upload from sending", async () => {
    const pending = deferred<typeof uploaded>();
    vi.mocked(uploadMediaFile).mockReturnValue(pending.promise);
    const view = render(input());
    fireEvent.click(screen.getByRole("button", { name: "停止并发送语音" }));
    await waitFor(() => expect(uploadMediaFile).toHaveBeenCalledTimes(1));
    const signal = vi.mocked(uploadMediaFile).mock.calls[0][2]!.signal;
    view.rerender(input("c2"));
    expect(signal?.aborted).toBe(true);
    await act(async () => pending.resolve(uploaded));
    expect(sendMessage).not.toHaveBeenCalled();
    expect(screen.queryByText("语音上传中…")).not.toBeInTheDocument();
  });

  it("unmount while stopping discards the late recording without uploading", async () => {
    const pending = deferred<ReturnType<typeof recording>>();
    recorder.stop.mockReturnValue(pending.promise);
    const view = render(input());
    fireEvent.click(screen.getByRole("button", { name: "停止并发送语音" }));
    view.unmount();
    await act(async () => pending.resolve(recording()));
    expect(uploadMediaFile).not.toHaveBeenCalled();
    expect(sendMessage).not.toHaveBeenCalled();
  });

  it("permission waiting visibly disables another start, and a too-short clip is not uploaded", async () => {
    recorder.recording = false;
    recorder.starting = true;
    const view = render(input());
    expect(screen.getByRole("button", { name: "发送语音" })).toBeDisabled();
    expect(screen.getByRole("status")).toHaveTextContent("正在请求麦克风");
    recorder.recording = true;
    recorder.starting = false;
    recorder.stop.mockResolvedValue({ ...recording(), duration: 0.2 });
    view.rerender(input());
    fireEvent.click(screen.getByRole("button", { name: "停止并发送语音" }));
    await act(async () => {});
    expect(uploadMediaFile).not.toHaveBeenCalled();
  });
});
