import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { DanmakuInput } from "../components/live/DanmakuInput";
import { uploadMediaFile } from "../api/media";
import { useAuthStore } from "../stores/auth";

vi.mock("../api/media", () => ({ uploadMediaFile: vi.fn() }));
vi.mock("../hooks/useDanmaku", () => ({ DANMAKU_MAX_LENGTH: 200 }));

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

beforeEach(() => {
  vi.clearAllMocks();
  useAuthStore.setState({ currentUser: { id: "fixture-account" } as never });
});

describe("danmaku draft and uploaded-image ownership", () => {
  it("keeps text edited while an earlier send is pending", async () => {
    const pending = deferred<boolean>();
    const onSend = vi.fn().mockReturnValueOnce(pending.promise);
    render(<DanmakuInput channelId={810} sending={false} error={null} onSend={onSend} />);
    const input = screen.getByPlaceholderText("发条弹幕吧");
    fireEvent.change(input, { target: { value: "先发送这一句" } });
    fireEvent.click(screen.getByRole("button", { name: "发送弹幕" }));
    fireEvent.change(input, { target: { value: "等待期间新写的草稿" } });
    await act(async () => pending.resolve(true));
    expect(onSend).toHaveBeenCalledWith("先发送这一句", undefined);
    expect(input).toHaveValue("等待期间新写的草稿");
  });

  it("retries a failed image send with the already-uploaded media and its original text", async () => {
    vi.mocked(uploadMediaFile).mockResolvedValue({ media_id: "fixture-uploaded-image" } as never);
    const onSend = vi.fn().mockResolvedValueOnce(false).mockResolvedValueOnce(true);
    const { container } = render(<DanmakuInput channelId={810} sending={false} error={null} onSend={onSend} />);
    const input = screen.getByPlaceholderText("发条弹幕吧");
    fireEvent.change(input, { target: { value: "图片原来的说明" } });
    fireEvent.change(container.querySelector("input[type=file]")!, {
      target: { files: [new File(["fixture"], "fixture.png", { type: "image/png" })] },
    });
    const retry = await screen.findByRole("button", { name: "重试图片" });
    fireEvent.change(input, { target: { value: "发送图片以后新写的草稿" } });
    fireEvent.click(retry);
    await waitFor(() => expect(onSend).toHaveBeenCalledTimes(2));
    expect(uploadMediaFile).toHaveBeenCalledTimes(1);
    expect(onSend.mock.calls).toEqual([
      ["图片原来的说明", "fixture-uploaded-image"],
      ["图片原来的说明", "fixture-uploaded-image"],
    ]);
    expect(input).toHaveValue("发送图片以后新写的草稿");
    await waitFor(() => expect(screen.queryByRole("button", { name: "重试图片" })).toBeNull());
  });

  it("blocks same-tick and pending Enter but releases the lock after failure", async () => {
    const pending = deferred<boolean>();
    const onSend = vi.fn().mockReturnValueOnce(pending.promise).mockResolvedValueOnce(true);
    render(<DanmakuInput channelId={810} sending={false} error={null} onSend={onSend} />);
    const input = screen.getByPlaceholderText("发条弹幕吧");
    fireEvent.change(input, { target: { value: "只发送一次" } });
    act(() => {
      input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
      input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    });
    fireEvent.keyDown(input, { key: "Enter" });
    expect(onSend).toHaveBeenCalledTimes(1);
    await act(async () => pending.resolve(false));
    expect(input).toHaveValue("只发送一次");
    fireEvent.keyDown(input, { key: "Enter" });
    await waitFor(() => expect(input).toHaveValue(""));
    expect(onSend).toHaveBeenCalledTimes(2);
  });

  it("keeps an upload failure retryable and blocks Enter until the image attempt finishes", async () => {
    const pending = deferred<Awaited<ReturnType<typeof uploadMediaFile>>>();
    vi.mocked(uploadMediaFile).mockReturnValueOnce(pending.promise)
      .mockResolvedValueOnce({ media_id: "fixture-after-retry" } as never);
    const onSend = vi.fn().mockResolvedValue(true);
    const { container } = render(<DanmakuInput channelId={810} sending={false} error={null} onSend={onSend} />);
    const input = screen.getByPlaceholderText("发条弹幕吧");
    const file = new File(["fixture"], "fixture.png", { type: "image/png" });
    fireEvent.change(input, { target: { value: "上传开始时的说明" } });
    fireEvent.change(container.querySelector("input[type=file]")!, { target: { files: [file] } });
    fireEvent.keyDown(input, { key: "Enter" });
    expect(onSend).not.toHaveBeenCalled();
    expect(container.querySelector("input[type=file]")).toBeDisabled();
    fireEvent.change(input, { target: { value: "上传期间的新草稿" } });
    await act(async () => pending.reject(new Error("合成上传失败")));
    expect(screen.getByRole("alert")).toHaveTextContent("图片上传失败");
    fireEvent.click(screen.getByRole("button", { name: "重试图片" }));
    await waitFor(() => expect(onSend).toHaveBeenCalledWith("上传开始时的说明", "fixture-after-retry"));
    expect(uploadMediaFile).toHaveBeenCalledTimes(2);
    expect(vi.mocked(uploadMediaFile).mock.calls[1][0]).toBe(file);
    expect(input).toHaveValue("上传期间的新草稿");
  });

  it.each(["room", "account"] as const)("does not submit a late upload after %s changes, even after returning", async (changed) => {
    const pending = deferred<Awaited<ReturnType<typeof uploadMediaFile>>>();
    vi.mocked(uploadMediaFile).mockReturnValueOnce(pending.promise);
    const onSend = vi.fn();
    const { container, rerender } = render(<DanmakuInput channelId={810} sending={false} error={null} onSend={onSend} />);
    fireEvent.change(container.querySelector("input[type=file]")!, {
      target: { files: [new File(["fixture"], "late.png", { type: "image/png" })] },
    });
    if (changed === "room") {
      rerender(<DanmakuInput channelId={811} sending={false} error={null} onSend={onSend} />);
      rerender(<DanmakuInput channelId={810} sending={false} error={null} onSend={onSend} />);
    } else {
      act(() => useAuthStore.setState({ currentUser: { id: "other-account" } as never }));
      act(() => useAuthStore.setState({ currentUser: { id: "fixture-account" } as never }));
    }
    const nextInput = screen.getByPlaceholderText("发条弹幕吧");
    fireEvent.change(nextInput, { target: { value: "回来以后新写的草稿" } });
    await act(async () => pending.resolve({ media_id: "fixture-obsolete-media" } as never));
    expect(onSend).not.toHaveBeenCalled();
    expect(nextInput).toHaveValue("回来以后新写的草稿");
    expect(screen.queryByRole("button", { name: "重试图片" })).toBeNull();
  });

  it("does not clear another room's draft when an old send succeeds", async () => {
    const pending = deferred<boolean>();
    const onSend = vi.fn().mockReturnValueOnce(pending.promise);
    const { rerender } = render(<DanmakuInput channelId={810} sending={false} error={null} onSend={onSend} />);
    fireEvent.change(screen.getByPlaceholderText("发条弹幕吧"), { target: { value: "旧房已提交" } });
    fireEvent.keyDown(screen.getByPlaceholderText("发条弹幕吧"), { key: "Enter" });
    rerender(<DanmakuInput channelId={811} sending={false} error={null} onSend={onSend} />);
    const nextInput = screen.getByPlaceholderText("发条弹幕吧");
    fireEvent.change(nextInput, { target: { value: "新房草稿" } });
    await act(async () => pending.resolve(true));
    expect(nextInput).toHaveValue("新房草稿");
  });

  it("drops failed-image retry state when the owner changes", async () => {
    vi.mocked(uploadMediaFile).mockResolvedValue({ media_id: "fixture-old-image" } as never);
    const onSend = vi.fn().mockResolvedValue(false);
    const { container, rerender } = render(<DanmakuInput channelId={810} sending={false} error={null} onSend={onSend} />);
    fireEvent.change(container.querySelector("input[type=file]")!, {
      target: { files: [new File(["fixture"], "old.png", { type: "image/png" })] },
    });
    await screen.findByRole("button", { name: "重试图片" });
    rerender(<DanmakuInput channelId={811} sending={false} error={null} onSend={onSend} />);
    expect(screen.queryByRole("button", { name: "重试图片" })).toBeNull();
    expect(screen.getByPlaceholderText("发条弹幕吧")).toHaveValue("");
  });
});
