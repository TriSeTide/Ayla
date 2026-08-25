import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MessageInput } from "../components/chat/MessageInput";
import * as chatApi from "../api/chat";
import * as mediaApi from "../api/media";

vi.mock("../hooks/useTyping", () => ({ useTyping: () => ({ onInput: vi.fn() }) }));

// 乐观发送内部走 chatApi.sendMessage（useChat.sendOptimistic）
vi.mock("../api/chat", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../api/chat")>();
  return { ...actual, sendMessage: vi.fn() };
});

const send = vi.mocked(chatApi.sendMessage);

function serverMessage(over: Partial<import("../api/types").ChatMessage> = {}) {
  return {
    id: "m1",
    conversation_id: "c1",
    sender_id: "u1",
    type: "mixed",
    content: "",
    media_id: null,
    segments: null,
    reply_to: null,
    status: "sent",
    seq: 1,
    created_at: new Date().toISOString(),
    ...over,
  } as import("../api/types").ChatMessage;
}

describe("MessageInput 乐观发送（M7）", () => {
  beforeEach(() => {
    send.mockReset();
    vi.spyOn(mediaApi, "uploadMediaFile").mockResolvedValue({ media_id: "media-1", descriptor: {} as never, upload_id: "u-x" });
    // jsdom 无 URL.createObjectURL/revokeObjectURL：stub 供缩略图条与乐观消息使用
    vi.stubGlobal("URL", { ...URL, createObjectURL: () => "blob:stub", revokeObjectURL: vi.fn() });
  });
  afterEach(() => vi.restoreAllMocks());

  it("多选图片进缩略图条（不直接上传），点发送后统一上传并发送混排消息", async () => {
    send.mockResolvedValue(serverMessage({ type: "mixed" }));
    render(<MemoryRouter><MessageInput convId="c1" quote={null} onQuoteClear={vi.fn()} /></MemoryRouter>);
    const input = screen.getByLabelText("发送图片或视频").querySelector("input") as HTMLInputElement;
    fireEvent.change(input, {
      target: {
        files: [
          new File(["a"], "a.png", { type: "image/png" }),
          new File(["b"], "b.png", { type: "image/png" }),
        ],
      },
    });
    // 选择后仅入队（缩略图条 2 个），尚未上传/发送
    await waitFor(() => expect(screen.getByRole("group", { name: "待发送媒体" })).toBeInTheDocument());
    expect(screen.getAllByRole("img", { name: "待发送图片" })).toHaveLength(2);
    expect(mediaApi.uploadMediaFile).not.toHaveBeenCalled();
    expect(send).not.toHaveBeenCalled();

    // 输入文本 → 点发送 → 立即清空队列（乐观进气泡），后台上传+发送
    const textarea = screen.getByPlaceholderText(/输入消息/);
    fireEvent.change(textarea, { target: { value: "看看这俩" } });
    fireEvent.click(screen.getByRole("button", { name: "发送" }));
    await waitFor(() => expect(send).toHaveBeenCalledTimes(1));
    expect(mediaApi.uploadMediaFile).toHaveBeenCalledTimes(2);
    const payload = send.mock.calls[0][1] as import("../api/types").CreateMessagePayload;
    expect(payload.type).toBe("mixed");
    expect(payload.content).toBe("看看这俩");
    expect(payload.segments).toEqual([
      { type: "text", text: "看看这俩" },
      { type: "image", media_id: "media-1" },
      { type: "image", media_id: "media-1" },
    ]);
    await waitFor(() => expect(screen.queryByRole("group", { name: "待发送媒体" })).not.toBeInTheDocument());
  });

  it("纯文本走 text 契约（不构造混排段），且发送后输入框清空", async () => {
    send.mockResolvedValue(serverMessage({ type: "text", content: "你好" }));
    render(<MemoryRouter><MessageInput convId="c1" quote={null} onQuoteClear={vi.fn()} /></MemoryRouter>);
    const textarea = screen.getByPlaceholderText(/输入消息/);
    fireEvent.change(textarea, { target: { value: "你好" } });
    fireEvent.click(screen.getByRole("button", { name: "发送" }));
    await waitFor(() => expect(send).toHaveBeenCalledTimes(1));
    const payload = send.mock.calls[0][1] as import("../api/types").CreateMessagePayload;
    expect(payload.type).toBe("text");
    expect(payload.segments).toBeUndefined();
    await waitFor(() => expect(textarea).toHaveValue(""));
    expect(mediaApi.uploadMediaFile).not.toHaveBeenCalled();
  });

  it("选择视频进队列（data-kind=video + 播放标记），发送按 kind=video 上传", async () => {
    send.mockResolvedValue(serverMessage({ type: "mixed" }));
    const upload = vi.spyOn(mediaApi, "uploadMediaFile").mockResolvedValue({ media_id: "media-v", descriptor: {} as never, upload_id: "u-x" });
    render(<MemoryRouter><MessageInput convId="c1" quote={null} onQuoteClear={vi.fn()} /></MemoryRouter>);
    const input = screen.getByLabelText("发送图片或视频").querySelector("input") as HTMLInputElement;
    expect(input.accept).toContain("video/*");
    fireEvent.change(input, { target: { files: [new File(["mp4"], "a.mp4", { type: "video/mp4" })] } });
    await waitFor(() => expect(screen.getByRole("group", { name: "待发送媒体" })).toBeInTheDocument());
    fireEvent.click(screen.getByRole("button", { name: "发送" }));
    await waitFor(() => expect(upload).toHaveBeenCalledWith(expect.any(File), "video", expect.objectContaining({ signal: expect.any(AbortSignal) })));
    expect(send.mock.calls[0][1]?.segments).toEqual([{ type: "video", media_id: "media-v" }]);
  });

  it("不支持的类型被本地校验拦截，不上传不发送", async () => {
    render(<MemoryRouter><MessageInput convId="c1" quote={null} onQuoteClear={vi.fn()} /></MemoryRouter>);
    const input = screen.getByLabelText("发送图片或视频").querySelector("input") as HTMLInputElement;
    fireEvent.change(input, { target: { files: [new File(["x"], "a.exe", { type: "application/x-msdownload" })] } });
    await screen.findByRole("alert");
    expect(mediaApi.uploadMediaFile).not.toHaveBeenCalled();
    expect(send).not.toHaveBeenCalled();
  });

  it("粘贴剪贴板图片进队列（不自动发送），可移除", async () => {
    send.mockResolvedValue(serverMessage());
    render(<MemoryRouter><MessageInput convId="c1" quote={null} onQuoteClear={vi.fn()} /></MemoryRouter>);
    const textarea = screen.getByPlaceholderText(/输入消息/);
    fireEvent.paste(textarea, {
      clipboardData: {
        items: [
          { kind: "file", type: "image/png", getAsFile: () => new File(["p"], "p.png", { type: "image/png" }) },
          { kind: "string", type: "text/plain", getAsFile: () => null },
        ],
      },
    });
    await waitFor(() => expect(screen.getByRole("group", { name: "待发送媒体" })).toBeInTheDocument());
    expect(send).not.toHaveBeenCalled();
    // 移除缩略图
    fireEvent.click(screen.getByRole("button", { name: "移除媒体" }));
    await waitFor(() => expect(screen.queryByRole("group", { name: "待发送媒体" })).not.toBeInTheDocument());
  });

  it("placeholder 响应式（U7）：宽屏保留完整快捷键说明、窄屏短文案", () => {
    // 宽屏（jsdom 无 matchMedia → useMediaQuery 回退 false）：完整文案
    const { unmount } = render(
      <MemoryRouter><MessageInput convId="c1" quote={null} onQuoteClear={vi.fn()} /></MemoryRouter>,
    );
    expect(
      screen.getByPlaceholderText("输入消息，回车发送（Shift+Enter 换行）；可粘贴图片/视频"),
    ).toBeInTheDocument();
    unmount();

    // 窄屏（matchMedia matches=true）：短文案，不含快捷键说明
    const listeners = new Set<(e: { matches: boolean }) => void>();
    vi.stubGlobal(
      "matchMedia",
      vi.fn(() => ({
        get matches() {
          return true;
        },
        media: "(max-width: 768px)",
        addEventListener: (_type: string, cb: (e: { matches: boolean }) => void) => listeners.add(cb),
        removeEventListener: (_type: string, cb: (e: { matches: boolean }) => void) => listeners.delete(cb),
      })),
    );
    render(<MemoryRouter><MessageInput convId="c1" quote={null} onQuoteClear={vi.fn()} /></MemoryRouter>);
    expect(screen.getByPlaceholderText("输入消息")).toBeInTheDocument();
    expect(
      screen.queryByPlaceholderText("输入消息，回车发送（Shift+Enter 换行）；可粘贴图片/视频"),
    ).not.toBeInTheDocument();
    vi.unstubAllGlobals();
  });
});
