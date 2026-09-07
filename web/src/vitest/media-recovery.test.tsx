import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ChatMessage, MediaDescriptor } from "../api/types";
import { MediaContent } from "../components/chat/MediaContent";
import { ImageViewer } from "../components/chat/ImageViewer";
import { resetAudioPlayback } from "../utils/mediaPlayback";

const mocks = vi.hoisted(() => ({ sign: vi.fn(), blob: vi.fn(), invalidate: vi.fn() }));
vi.mock("../api/media", async (original) => ({
  ...await original<typeof import("../api/media")>(),
  getSignedMediaUrl: mocks.sign,
  invalidateSignedMediaUrl: mocks.invalidate,
  warmUpVideoElement: vi.fn(),
  takeWarmVideoElement: vi.fn(() => null),
}));
vi.mock("../api/client", async (original) => ({
  ...await original<typeof import("../api/client")>(), apiRequestBlob: mocks.blob,
}));
vi.mock("../components/ResourceImage", () => ({ ResourceImage: () => null }));

function descriptor(kind: "file" | "video" | "voice", id: string = kind): MediaDescriptor {
  return { media_id: id, kind, mime_type: kind === "video" ? "video/mp4" : kind === "voice" ? "audio/webm" : "application/pdf",
    size: 1024, status: "ready", width: 640, height: 480, duration: kind === "voice" ? 12 : null,
    thumbnail: null, waveform: null, created_at: "2026-09-08T00:00:00Z" };
}
function message(kind: "file" | "video" | "voice", id: string = kind): ChatMessage {
  return { id, conversation_id: "fixture-c", sender_id: "fixture-user", type: kind, content: kind === "file" ? "fixture.pdf" : "",
    media_id: id, media: descriptor(kind, id), reply_to: null, status: "sent", seq: 1, created_at: "2026-09-08T00:00:00Z" };
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}
class FakeAudio extends EventTarget {
  static instances: FakeAudio[] = [];
  static nextPlay: Promise<void> | null = null;
  currentTime = 0;
  duration = 12;
  play = vi.fn(() => this.playResult);
  pause = vi.fn();
  playResult: Promise<void>;
  constructor(readonly src: string) {
    super();
    this.playResult = FakeAudio.nextPlay ?? Promise.resolve();
    FakeAudio.nextPlay = null;
    FakeAudio.instances.push(this);
  }
}
beforeEach(() => {
  vi.clearAllMocks();
  mocks.sign.mockReset().mockImplementation(async (id: string) => "/signed/" + id);
  mocks.blob.mockReset().mockResolvedValue(new Blob(["synthetic audio"]));
  FakeAudio.instances = [];
  FakeAudio.nextPlay = null;
  vi.stubGlobal("Audio", FakeAudio);
  vi.spyOn(HTMLMediaElement.prototype, "play").mockResolvedValue();
  vi.spyOn(HTMLMediaElement.prototype, "pause").mockImplementation(() => {});
  vi.spyOn(HTMLMediaElement.prototype, "load").mockImplementation(() => {});
  Object.defineProperty(URL, "createObjectURL", { value: vi.fn(() => "blob:fixture-" + FakeAudio.instances.length), configurable: true });
  Object.defineProperty(URL, "revokeObjectURL", { value: vi.fn(), configurable: true });
});
afterEach(() => { cleanup(); resetAudioPlayback(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

describe("Media failure recovery", () => {
  it("file signing failure is visible and retry creates the original native download link", async () => {
    const pending = deferred<string>();
    mocks.sign.mockReturnValueOnce(pending.promise).mockRejectedValueOnce(new Error("synthetic signing failure"));
    const { unmount } = render(<MediaContent msg={message("file")} />);
    expect(screen.getByRole("button", { name: "附件加载中" })).toBeDisabled();
    unmount();
    render(<MediaContent msg={message("file")} />);
    expect(await screen.findByRole("alert")).toHaveTextContent("附件加载失败");
    expect(screen.queryByRole("link")).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "重试" }));
    const link = await screen.findByRole("link", { name: "下载 fixture.pdf" });
    expect(link).toHaveAttribute("href", "/signed/file");
    expect(link).toHaveAttribute("download", "fixture.pdf");
    expect(mocks.invalidate).toHaveBeenCalledWith("file");
    await act(async () => pending.resolve("/signed/obsolete"));
    expect(link).toHaveAttribute("href", "/signed/file");
  });

  it("posterless bubble video retries signing and a failed native decode replaces the failed element", async () => {
    mocks.sign.mockRejectedValueOnce(new Error("synthetic signing failure"));
    const { container } = render(<MediaContent msg={message("video")} />);
    expect(await screen.findByRole("alert")).toHaveTextContent("视频加载失败");
    fireEvent.click(screen.getByRole("button", { name: "重试" }));
    await waitFor(() => expect(container.querySelector("video")).not.toBeNull());
    const first = container.querySelector("video")!;
    fireEvent.error(first);
    expect(screen.getByRole("alert")).toHaveTextContent("视频加载失败");
    fireEvent.click(screen.getByRole("button", { name: "重试" }));
    await waitFor(() => expect(container.querySelector("video")).not.toBeNull());
    expect(container.querySelector("video")).not.toBe(first);
    expect(mocks.sign).toHaveBeenCalledTimes(3);
    expect(mocks.invalidate).toHaveBeenCalledTimes(2);
  });

  it("viewer video retries signing and native failure, preserving controls and disposing the previous element", async () => {
    mocks.sign.mockRejectedValueOnce(new Error("synthetic signing failure"));
    render(<ImageViewer media={descriptor("video")} alt="fixture video" onClose={() => {}} />);
    expect(await screen.findByRole("alert")).toHaveTextContent("视频加载失败");
    fireEvent.click(screen.getByRole("button", { name: "重试" }));
    await waitFor(() => expect(document.querySelector("video.image-viewer-video")).not.toBeNull());
    const first = document.querySelector("video.image-viewer-video") as HTMLVideoElement;
    expect(first.controls).toBe(true);
    fireEvent.error(first);
    expect(screen.getByRole("alert")).toHaveTextContent("视频加载失败");
    fireEvent.click(screen.getByRole("button", { name: "重试" }));
    await waitFor(() => expect(document.querySelector("video.image-viewer-video")).not.toBe(first));
    const second = document.querySelector("video.image-viewer-video") as HTMLVideoElement;
    expect(second.controls).toBe(true);
    expect(first.isConnected).toBe(false);
    expect(first.hasAttribute("src")).toBe(false);
    fireEvent.error(first);
    expect(screen.queryByRole("alert")).toBeNull();
    expect(mocks.sign).toHaveBeenCalledTimes(3);
  });

  it("voice blob failure remains visible until a successful authenticated retry", async () => {
    mocks.blob.mockRejectedValueOnce(new Error("synthetic fetch failure"));
    render(<MediaContent msg={message("voice")} />);
    fireEvent.click(screen.getByRole("button", { name: "播放语音" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("语音播放失败");
    fireEvent.click(screen.getByRole("button", { name: "重试" }));
    await screen.findByRole("button", { name: "暂停语音" });
    expect(screen.queryByRole("alert")).toBeNull();
    expect(mocks.blob).toHaveBeenCalledTimes(2);
    expect(mocks.blob).toHaveBeenLastCalledWith("/media/voice/content");
  });

  it("voice play rejection and decoder failure are visible; retry releases old URLs and ignores old events", async () => {
    const play = deferred<void>();
    FakeAudio.nextPlay = play.promise.then(() => { throw new Error("synthetic play denial"); });
    render(<MediaContent msg={message("voice")} />);
    fireEvent.click(screen.getByRole("button", { name: "播放语音" }));
    await waitFor(() => expect(FakeAudio.instances).toHaveLength(1));
    await act(async () => play.resolve());
    expect(await screen.findByRole("alert")).toHaveTextContent("语音播放失败");
    const first = FakeAudio.instances[0];
    fireEvent.click(screen.getByRole("button", { name: "重试" }));
    await screen.findByRole("button", { name: "暂停语音" });
    expect(first.pause).toHaveBeenCalled();
    expect(URL.revokeObjectURL).toHaveBeenCalledWith(first.src);
    act(() => first.dispatchEvent(new Event("error")));
    expect(screen.queryByRole("alert")).toBeNull();
    act(() => FakeAudio.instances[1].dispatchEvent(new Event("error")));
    expect(screen.getByRole("alert")).toHaveTextContent("语音播放失败");
    expect(screen.getByRole("button", { name: "播放语音" })).toBeInTheDocument();
  });

  it("unmount during authenticated audio fetch cannot create a late player or object URL", async () => {
    const request = deferred<Blob>();
    mocks.blob.mockReturnValue(request.promise);
    const { unmount } = render(<MediaContent msg={message("voice")} />);
    fireEvent.click(screen.getByRole("button", { name: "播放语音" }));
    unmount();
    await act(async () => request.resolve(new Blob(["late synthetic audio"])));
    expect(FakeAudio.instances).toHaveLength(0);
    expect(URL.createObjectURL).not.toHaveBeenCalled();
  });

  it("late play success does not reactivate a voice already displaced by another message", async () => {
    const oldPlay = deferred<void>();
    FakeAudio.nextPlay = oldPlay.promise;
    render(<><MediaContent msg={message("voice", "first")} /><MediaContent msg={message("voice", "second")} /></>);
    fireEvent.click(screen.getAllByRole("button", { name: "播放语音" })[0]);
    await waitFor(() => expect(FakeAudio.instances).toHaveLength(1));
    fireEvent.click(screen.getAllByRole("button", { name: "播放语音" })[1]);
    await screen.findByRole("button", { name: "暂停语音" });
    await act(async () => oldPlay.resolve());
    expect(screen.getAllByRole("button", { name: "暂停语音" })).toHaveLength(1);
    expect(FakeAudio.instances[0].pause).toHaveBeenCalled();
  });
});
