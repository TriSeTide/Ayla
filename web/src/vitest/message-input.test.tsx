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

/** contentEditable 编辑器定位（M8 后 textarea 改为 contenteditable div） */
function editor() {
  return screen.getByRole("textbox", { name: "消息输入框" }) as HTMLDivElement;
}

/** 模拟向 contentEditable 输入纯文本并触发 onInput */
function enterText(text: string) {
  const el = editor();
  el.textContent = text;
  fireEvent.input(el);
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
    enterText("看看这俩");
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
    enterText("你好");
    fireEvent.click(screen.getByRole("button", { name: "发送" }));
    await waitFor(() => expect(send).toHaveBeenCalledTimes(1));
    const payload = send.mock.calls[0][1] as import("../api/types").CreateMessagePayload;
    expect(payload.type).toBe("text");
    expect(payload.segments).toBeUndefined();
    await waitFor(() => expect(editor().textContent).toBe(""));
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

  it("可执行文档（HTML/SVG/JS）被本地校验拦截，不上传不发送", async () => {
    render(<MemoryRouter><MessageInput convId="c1" quote={null} onQuoteClear={vi.fn()} /></MemoryRouter>);
    const input = screen.getByLabelText("发送图片或视频").querySelector("input") as HTMLInputElement;
    fireEvent.change(input, { target: { files: [new File(["<html>"], "a.html", { type: "text/html" })] } });
    await screen.findByRole("alert");
    expect(mediaApi.uploadMediaFile).not.toHaveBeenCalled();
    expect(send).not.toHaveBeenCalled();
  });

  it("文件按钮选单个任意格式文件进队列（data-kind=file + 文件名），发送按 type=file 上传", async () => {
    send.mockResolvedValue(serverMessage({ type: "file", content: "报告.pdf" }));
    const upload = vi.spyOn(mediaApi, "uploadMediaFile").mockResolvedValue({ media_id: "media-f", descriptor: {} as never, upload_id: "u-x" });
    render(<MemoryRouter><MessageInput convId="c1" quote={null} onQuoteClear={vi.fn()} /></MemoryRouter>);
    const input = screen.getByLabelText("发送文件").querySelector("input") as HTMLInputElement;
    // 文件按钮不限制扩展名、不允许多选
    expect(input.accept).toBe("");
    expect(input.multiple).toBe(false);
    fireEvent.change(input, { target: { files: [new File(["pdf-body"], "报告.pdf", { type: "application/pdf" })] } });
    await waitFor(() => expect(screen.getByRole("group", { name: "待发送媒体" })).toBeInTheDocument());
    // 队列展示文件名（file 无缩略图）
    expect(screen.getByText("报告.pdf")).toBeInTheDocument();
    expect(mediaApi.uploadMediaFile).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole("button", { name: "发送" }));
    await waitFor(() => expect(upload).toHaveBeenCalledWith(expect.any(File), "file", expect.objectContaining({ signal: expect.any(AbortSignal) })));
    const payload = send.mock.calls[0][1] as import("../api/types").CreateMessagePayload;
    expect(payload.type).toBe("file");
    expect(payload.content).toBe("报告.pdf");
    expect(payload.media_id).toBe("media-f");
    expect(payload.segments).toBeUndefined();
  });

  it("单文件互斥：先选图片再选文件，队列清空图片只保留文件", async () => {
    render(<MemoryRouter><MessageInput convId="c1" quote={null} onQuoteClear={vi.fn()} /></MemoryRouter>);
    const imgInput = screen.getByLabelText("发送图片或视频").querySelector("input") as HTMLInputElement;
    fireEvent.change(imgInput, { target: { files: [new File(["a"], "a.png", { type: "image/png" })] } });
    await waitFor(() => expect(screen.getByRole("group", { name: "待发送媒体" })).toBeInTheDocument());
    expect(screen.getAllByRole("img", { name: "待发送图片" })).toHaveLength(1);

    const fileInput = screen.getByLabelText("发送文件").querySelector("input") as HTMLInputElement;
    fireEvent.change(fileInput, { target: { files: [new File(["z"], "a.zip", { type: "application/zip" })] } });
    await waitFor(() => {
      expect(screen.getByText("a.zip")).toBeInTheDocument();
    });
    // 图片被清空，只剩文件
    expect(screen.queryAllByRole("img", { name: "待发送图片" })).toHaveLength(0);
  });

  it("粘贴剪贴板图片进队列（不自动发送），可移除", async () => {
    send.mockResolvedValue(serverMessage());
    render(<MemoryRouter><MessageInput convId="c1" quote={null} onQuoteClear={vi.fn()} /></MemoryRouter>);
    fireEvent.paste(editor(), {
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

  it("placeholder 响应式（U7）：宽屏含 @ 提示、窄屏短文案（data-placeholder）", () => {
    // 宽屏（jsdom 无 matchMedia → useMediaQuery 回退 false）：完整文案
    const { unmount } = render(
      <MemoryRouter><MessageInput convId="c1" quote={null} onQuoteClear={vi.fn()} /></MemoryRouter>,
    );
    expect(editor().getAttribute("data-placeholder")).toContain("回车发送");
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
    expect(editor().getAttribute("data-placeholder")).toBe("输入消息");
    vi.unstubAllGlobals();
  });
});
