import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import * as mediaApi from "../api/media";
import type { PostComment } from "../api/types";
import { CommentComposer } from "../components/posts/CommentComposer";

vi.mock("../api/media", () => ({ uploadMediaFile: vi.fn(), validateMediaFile: vi.fn(), deleteMedia: vi.fn() }));
vi.mock("../components/ResourceImage", () => ({ ResourceImage: () => <span>待发图片预览</span> }));
const reply = (id: number) => ({ id, author: { nickname: `作者${id}`, username: "test" } } as PostComment);
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((yes) => { resolve = yes; });
  return { promise, resolve };
}
function attach(container: HTMLElement) {
  fireEvent.change(container.querySelector<HTMLInputElement>('input[type="file"]')!, { target: { files: [new File(["image"], "comment.png", { type: "image/png" })] } });
}
beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(mediaApi.validateMediaFile).mockReturnValue({ kind: "image", error: null });
  vi.mocked(mediaApi.uploadMediaFile).mockResolvedValue({ media_id: "comment-media", upload_id: "upload", descriptor: {} } as never);
  vi.mocked(mediaApi.deleteMedia).mockResolvedValue(undefined);
});

describe("CommentComposer async state", () => {
  it("successful send preserves text typed while the request is in flight", async () => {
    const pending = deferred<void>();
    const onSend = vi.fn(() => pending.promise);
    render(<CommentComposer onSend={onSend} replyTarget={null} onReplyClear={vi.fn()} />);
    const input = screen.getByRole("textbox");
    fireEvent.change(input, { target: { value: "本次发送" } });
    fireEvent.click(screen.getByRole("button", { name: "发送" }));
    expect(onSend).toHaveBeenCalledWith("本次发送", null, []);
    fireEvent.change(input, { target: { value: "下一条草稿" } });
    await act(async () => pending.resolve());
    expect(input).toHaveValue("下一条草稿");
  });
  it("failed send keeps the draft and retry only clears the successfully sent draft", async () => {
    const onSend = vi.fn().mockRejectedValueOnce(new Error("评论发送失败")).mockResolvedValueOnce(undefined);
    render(<CommentComposer onSend={onSend} replyTarget={null} onReplyClear={vi.fn()} />);
    const input = screen.getByRole("textbox");
    fireEvent.change(input, { target: { value: "保留我的评论" } });
    fireEvent.click(screen.getByRole("button", { name: "发送" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("评论发送失败");
    expect(input).toHaveValue("保留我的评论");
    fireEvent.click(screen.getByRole("button", { name: "发送" }));
    await waitFor(() => expect(input).toHaveValue(""));
  });
  it("changing reply target during send cannot be cleared by the old response", async () => {
    const pending = deferred<void>();
    const clear = vi.fn();
    const view = render(<CommentComposer onSend={() => pending.promise} replyTarget={reply(1)} onReplyClear={clear} />);
    fireEvent.change(screen.getByRole("textbox"), { target: { value: "回复" } });
    fireEvent.click(screen.getByRole("button", { name: "发送" }));
    view.rerender(<CommentComposer onSend={() => pending.promise} replyTarget={reply(2)} onReplyClear={clear} />);
    await act(async () => pending.resolve());
    expect(clear).not.toHaveBeenCalled();
    expect(screen.getByText("回复 @作者2")).toBeInTheDocument();
  });
  it("pending send disables image deletion and upload so submitted media cannot disappear", async () => {
    const pending = deferred<void>();
    const { container } = render(<CommentComposer onSend={() => pending.promise} replyTarget={null} onReplyClear={vi.fn()} />);
    attach(container);
    const remove = await screen.findByRole("button", { name: "移除图片（同时从服务器删除）" });
    await waitFor(() => expect(screen.getByRole("button", { name: "发送" })).toBeEnabled());
    fireEvent.click(screen.getByRole("button", { name: "发送" }));
    expect(remove).toBeDisabled();
    expect(container.querySelector('input[type="file"]')).toBeDisabled();
    fireEvent.click(remove);
    expect(mediaApi.deleteMedia).not.toHaveBeenCalled();
    await act(async () => pending.resolve());
    expect(screen.queryByText("待发图片预览")).toBeNull();
  });
  it("failed image removal retains the attachment for explicit retry", async () => {
    vi.mocked(mediaApi.deleteMedia).mockRejectedValueOnce(new Error("删除图片暂时失败"));
    const { container } = render(<CommentComposer onSend={vi.fn()} replyTarget={null} onReplyClear={vi.fn()} />);
    attach(container);
    const remove = await screen.findByRole("button", { name: "移除图片（同时从服务器删除）" });
    await waitFor(() => expect(remove).toBeEnabled());
    fireEvent.click(remove);
    expect(await screen.findByRole("alert")).toHaveTextContent("删除图片暂时失败");
    expect(screen.getByText("待发图片预览")).toBeInTheDocument();
    fireEvent.click(remove);
    await waitFor(() => expect(screen.queryByText("待发图片预览")).toBeNull());
  });
  it("failed images remain explicit until retried or removed, never silently discarded by text send", async () => {
    vi.mocked(mediaApi.uploadMediaFile).mockRejectedValueOnce(new Error("upload failed"));
    const { container } = render(<CommentComposer onSend={vi.fn()} replyTarget={null} onReplyClear={vi.fn()} />);
    fireEvent.change(screen.getByRole("textbox"), { target: { value: "只发文字也要先处理失败图片" } });
    attach(container);
    await screen.findByRole("button", { name: "重试图片（1）" });
    expect(screen.getByRole("button", { name: "发送" })).toBeDisabled();
    fireEvent.click(screen.getByRole("button", { name: "移除失败图片" }));
    expect(screen.getByRole("button", { name: "发送" })).toBeEnabled();
  });
});
