import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";
import { MessageInput } from "../components/chat/MessageInput";
import * as chatHook from "../hooks/useChat";
import * as mediaApi from "../api/media";

vi.mock("../hooks/useTyping", () => ({ useTyping: () => ({ onInput: vi.fn() }) }));

describe("MessageInput 发送失败重试", () => {
  it("选择图片后上传并发送媒体 id，content 为空串（气泡不显示占位文案）", async () => {
    const send = vi.spyOn(chatHook, "sendMessage").mockResolvedValue({
      id: "m2", conversation_id: "c1", sender_id: "u1", type: "image", content: "",
      media_id: "media-1", reply_to: null, status: "sent", seq: 2, created_at: new Date().toISOString(),
    });
    vi.spyOn(mediaApi, "uploadMediaFile").mockResolvedValue({ media_id: "media-1", descriptor: {} as never });
    render(<MemoryRouter><MessageInput convId="c1" quote={null} onQuoteClear={vi.fn()} /></MemoryRouter>);
    const input = screen.getByLabelText("发送图片或视频").querySelector("input") as HTMLInputElement;
    fireEvent.change(input, { target: { files: [new File(["image"], "a.png", { type: "image/png" })] } });
    await waitFor(() => expect(send).toHaveBeenCalledWith("c1", "", expect.objectContaining({ mediaId: "media-1", type: "image" })));
  });

  it("选择视频按 kind=video 上传并发送 type=video 消息", async () => {
    const send = vi.spyOn(chatHook, "sendMessage").mockResolvedValue({
      id: "m3", conversation_id: "c1", sender_id: "u1", type: "video", content: "",
      media_id: "media-v", reply_to: null, status: "sent", seq: 3, created_at: new Date().toISOString(),
    });
    const upload = vi.spyOn(mediaApi, "uploadMediaFile").mockResolvedValue({ media_id: "media-v", descriptor: {} as never });
    render(<MemoryRouter><MessageInput convId="c1" quote={null} onQuoteClear={vi.fn()} /></MemoryRouter>);
    const input = screen.getByLabelText("发送图片或视频").querySelector("input") as HTMLInputElement;
    expect(input.accept).toContain("video/*");
    fireEvent.change(input, { target: { files: [new File(["mp4"], "a.mp4", { type: "video/mp4" })] } });
    await waitFor(() => {
      expect(upload).toHaveBeenCalledWith(expect.any(File), "video");
      expect(send).toHaveBeenCalledWith("c1", "", expect.objectContaining({ mediaId: "media-v", type: "video" }));
    });
  });

  it("不支持的类型被本地校验拦截，不上传", async () => {
    const upload = vi.spyOn(mediaApi, "uploadMediaFile");
    const send = vi.spyOn(chatHook, "sendMessage");
    render(<MemoryRouter><MessageInput convId="c1" quote={null} onQuoteClear={vi.fn()} /></MemoryRouter>);
    const input = screen.getByLabelText("发送图片或视频").querySelector("input") as HTMLInputElement;
    fireEvent.change(input, { target: { files: [new File(["x"], "a.exe", { type: "application/x-msdownload" })] } });
    await screen.findByRole("alert");
    expect(upload).not.toHaveBeenCalled();
    expect(send).not.toHaveBeenCalled();
  });

  it("重试复用同一幂等键", async () => {
    const send = vi.spyOn(chatHook, "sendMessage")
      .mockRejectedValueOnce(new Error("网络失败"))
      .mockResolvedValueOnce({
        id: "m1", conversation_id: "c1", sender_id: "u1", type: "text", content: "你好",
        media_id: null, reply_to: null, status: "sent", seq: 1, created_at: new Date().toISOString(),
      });
    render(<MemoryRouter><MessageInput convId="c1" quote={null} onQuoteClear={vi.fn()} /></MemoryRouter>);
    const input = screen.getByPlaceholderText(/输入消息/);
    fireEvent.change(input, { target: { value: "你好" } });
    fireEvent.click(screen.getByRole("button", { name: "发送" }));
    await screen.findByRole("alert");
    fireEvent.click(screen.getByRole("button", { name: "重试" }));
    await waitFor(() => expect(send).toHaveBeenCalledTimes(2));
    expect(send.mock.calls[0][2]?.idempotencyKey).toBe(send.mock.calls[1][2]?.idempotencyKey);
  });
});
