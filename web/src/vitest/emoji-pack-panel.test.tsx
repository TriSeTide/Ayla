/**
 * EmojiPackPanel 测试（任务 03 群内表情包）：
 * - 渲染群表情网格 + 加号框（can_upload 时）；
 * - 无权限（普通成员默认）不显示加号；
 * - 包未创建（404）→ 空态，群主/管理员按 myRole 兜底显示加号；
 * - 点击表情 → sendMessage(type=emoji, mediaId) 并关闭面板；
 * - 加号上传：选图 → uploadMediaFile(kind=emoji) → addGroupEmojiItem → 刷新列表。
 */
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { EmojiPackPanel } from "../components/chat/EmojiPackPanel";
import * as emojiApi from "../api/emoji";
import * as mediaApi from "../api/media";
import * as useChat from "../hooks/useChat";

vi.mock("../api/emoji", () => ({
  getGroupEmojiPack: vi.fn(),
  addGroupEmojiItem: vi.fn(),
  deleteGroupEmojiItem: vi.fn(),
  setGroupEmojiUploadPolicy: vi.fn(),
}));

vi.mock("../hooks/useChat", () => ({ sendMessage: vi.fn() }));

const getPack = vi.mocked(emojiApi.getGroupEmojiPack);
const addItem = vi.mocked(emojiApi.addGroupEmojiItem);
const delItem = vi.mocked(emojiApi.deleteGroupEmojiItem);
const send = vi.mocked(useChat.sendMessage);

function packPayload(over: Partial<import("../api/emoji").GroupEmojiPackPayload> = {}) {
  return {
    pack: {
      id: "1",
      owner_id: null,
      name: "群表情包",
      is_system: false,
      item_count: 1,
      items: [
        {
          id: "i1",
          tag: "",
          created_at: "2026-01-01T00:00:00Z",
          media: {
            media_id: "m1",
            kind: "emoji",
            mime_type: "image/gif",
            size: 100,
            status: "ready",
            width: 32,
            height: 32,
            duration: null,
            thumbnail: null,
            waveform: null,
          },
        },
      ],
      created_at: "2026-01-01T00:00:00Z",
    },
    allow_member_upload: false,
    can_upload: true,
    can_delete: true,
    ...over,
  } as import("../api/emoji").GroupEmojiPackPayload;
}

describe("EmojiPackPanel 群表情包（任务 03）", () => {
  beforeEach(() => {
    getPack.mockReset();
    addItem.mockReset();
    delItem.mockReset();
    send.mockReset();
    send.mockResolvedValue({} as never);
  });
  afterEach(() => vi.restoreAllMocks());

  it("渲染群表情网格与加号框（有权限）", async () => {
    getPack.mockResolvedValue(packPayload());
    render(<EmojiPackPanel convId="c1" myRole="owner" onClose={vi.fn()} />);
    await waitFor(() => expect(screen.getByLabelText("添加群表情")).toBeInTheDocument());
    expect(screen.getByLabelText("发送表情")).toBeInTheDocument();
    expect(screen.getByLabelText("删除表情")).toBeInTheDocument();
  });

  it("普通成员默认无加号框（can_upload=false）", async () => {
    getPack.mockResolvedValue(packPayload({ can_upload: false, can_delete: false }));
    render(<EmojiPackPanel convId="c1" myRole="member" onClose={vi.fn()} />);
    await waitFor(() => expect(screen.getByLabelText("发送表情")).toBeInTheDocument());
    expect(screen.queryByLabelText("添加群表情")).not.toBeInTheDocument();
    expect(screen.queryByLabelText("删除表情")).not.toBeInTheDocument();
  });

  it("包未创建（404）→ 空态；群主按 myRole 兜底显示加号", async () => {
    getPack.mockRejectedValue(Object.assign(new Error("not found"), { status: 404 }));
    render(<EmojiPackPanel convId="c1" myRole="owner" onClose={vi.fn()} />);
    await waitFor(() => expect(screen.getByLabelText("添加群表情")).toBeInTheDocument());
    expect(screen.getByText("还没有表情，点加号上传")).toBeInTheDocument();
  });

  it("包未创建（404）→ 普通成员无加号", async () => {
    getPack.mockRejectedValue(Object.assign(new Error("not found"), { status: 404 }));
    render(<EmojiPackPanel convId="c1" myRole="member" onClose={vi.fn()} />);
    await waitFor(() => expect(screen.getByText("群内还没有表情包")).toBeInTheDocument());
    expect(screen.queryByLabelText("添加群表情")).not.toBeInTheDocument();
  });

  it("点击表情 → 发送 emoji 消息且不收起面板（可连发）", async () => {
    getPack.mockResolvedValue(packPayload());
    const onClose = vi.fn();
    render(<EmojiPackPanel convId="c1" myRole="owner" onClose={onClose} />);
    await waitFor(() => expect(screen.getByLabelText("发送表情")).toBeInTheDocument());
    fireEvent.click(screen.getByLabelText("发送表情"));
    await waitFor(() => expect(send).toHaveBeenCalledWith("c1", "", { type: "emoji", mediaId: "m1" }));
    // 发送后面板保持打开：表情仍在、onClose 未被调用
    expect(screen.getByLabelText("发送表情")).toBeInTheDocument();
    expect(onClose).not.toHaveBeenCalled();
  });

  it("加号上传：选图 → 上传 kind=emoji → 加入群包 → 刷新列表", async () => {
    getPack.mockResolvedValueOnce(packPayload({ pack: { ...packPayload().pack, items: [] } }))
      .mockResolvedValueOnce(packPayload());
    vi.spyOn(mediaApi, "uploadMediaFile").mockResolvedValue({ media_id: "m2", descriptor: {} as never, upload_id: "u2" });
    addItem.mockResolvedValue({ id: "i2", media: null, tag: "", created_at: "" });
    render(<EmojiPackPanel convId="c1" myRole="owner" onClose={vi.fn()} />);
    await waitFor(() => expect(screen.getByLabelText("添加群表情")).toBeInTheDocument());
    const input = screen.getByRole("dialog", { name: "群表情包" }).querySelector("input[type=file]");
    expect(input).not.toBeNull();
    fireEvent.change(input!, { target: { files: [new File([new Uint8Array([0x89, 0x50, 0x4e, 0x47])], "a.png", { type: "image/png" })] } });
    await waitFor(() => expect(mediaApi.uploadMediaFile).toHaveBeenCalledWith(expect.any(File), "emoji"));
    await waitFor(() => expect(addItem).toHaveBeenCalledWith("c1", "m2"));
    await waitFor(() => expect(getPack).toHaveBeenCalledTimes(2));
  });

  it("加号多选上传：多张图逐张上传并全部加入群包", async () => {
    getPack.mockResolvedValueOnce(packPayload({ pack: { ...packPayload().pack, items: [] } }))
      .mockResolvedValueOnce(packPayload());
    const upload = vi.spyOn(mediaApi, "uploadMediaFile")
      .mockResolvedValueOnce({ media_id: "m2", descriptor: {} as never, upload_id: "u2" })
      .mockResolvedValueOnce({ media_id: "m3", descriptor: {} as never, upload_id: "u3" });
    addItem.mockResolvedValue({ id: "i2", media: null, tag: "", created_at: "" });
    render(<EmojiPackPanel convId="c1" myRole="owner" onClose={vi.fn()} />);
    await waitFor(() => expect(screen.getByLabelText("添加群表情")).toBeInTheDocument());
    const input = screen.getByRole("dialog", { name: "群表情包" }).querySelector("input[type=file]") as HTMLInputElement;
    expect(input.multiple).toBe(true);
    fireEvent.change(input, {
      target: {
        files: [
          new File([new Uint8Array([0x89, 0x50, 0x4e, 0x47])], "a.png", { type: "image/png" }),
          new File([new Uint8Array([0x89, 0x50, 0x4e, 0x47])], "b.png", { type: "image/png" }),
        ],
      },
    });
    await waitFor(() => expect(upload).toHaveBeenCalledTimes(2));
    await waitFor(() => expect(addItem).toHaveBeenCalledTimes(2));
    await waitFor(() => expect(getPack).toHaveBeenCalledTimes(2));
  });

  it("删除表情（群主/管理员）", async () => {
    getPack.mockResolvedValue(packPayload());
    delItem.mockResolvedValue(undefined);
    render(<EmojiPackPanel convId="c1" myRole="owner" onClose={vi.fn()} />);
    await waitFor(() => expect(screen.getByLabelText("删除表情")).toBeInTheDocument());
    fireEvent.click(screen.getByLabelText("删除表情"));
    await waitFor(() => expect(delItem).toHaveBeenCalledWith("c1", "i1"));
    await waitFor(() => expect(getPack).toHaveBeenCalledTimes(2));
  });
});
