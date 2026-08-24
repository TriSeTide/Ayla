/**
 * MediaContent 契约测试（图片原图渲染 / 查看器 / 语音互斥 / 气泡无占位文案）：
 * - 图片/表情经短时签名 URL 直连原图 content（缩略图是 JPEG 静帧：压画质 + GIF 变静图）；
 * - 点击图片打开全屏查看器（dialog），可关闭、可保存（签名 URL 原生下载）；
 * - 语音气泡带进度条，全局同时只播放一条（新播放抢占旧播放）；
 * - MessageBubble 不再显示媒体消息的「图片/语音」占位文案。
 */
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ChatMessage, MediaDescriptor } from "../api/types";
import { MediaContent } from "../components/chat/MediaContent";
import { MessageBubble } from "../components/chat/MessageBubble";
import { resetAudioPlayback } from "../utils/mediaPlayback";

/** 语音等小媒体仍走 Bearer blob 通道 */
const blobByPath = new Map<string, Blob>();
/** 图片/视频签名 URL 直连通道：media_id → 签名 URL */
const signedById = new Map<string, string>();

vi.mock("../api/client", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../api/client")>();
  return {
    ...actual,
    apiRequestBlob: vi.fn(async (path: string) => {
      const hit = blobByPath.get(path);
      if (!hit) throw new Error(`no blob stub for ${path}`);
      return hit;
    }),
  };
});

vi.mock("../api/media", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../api/media")>();
  return {
    ...actual,
    getSignedMediaUrl: vi.fn(async (mediaId: string, variant?: string) => {
      const key = variant ? `${mediaId}|${variant}` : mediaId;
      return signedById.get(key) ?? `/signed/${key}`;
    }),
  };
});

function mediaDescriptor(overrides: Partial<MediaDescriptor> = {}): MediaDescriptor {
  return {
    media_id: "med-1",
    kind: "image",
    mime_type: "image/png",
    size: 1024,
    status: "ready",
    width: 640,
    height: 480,
    duration: null,
    thumbnail: "/api/v1/media/med-1/thumbnail",
    waveform: null,
    created_at: "2026-01-01T00:00:00Z",
    ...overrides,
  };
}

function imageMessage(media?: MediaDescriptor): ChatMessage {
  return {
    id: "m1",
    conversation_id: "c1",
    sender_id: "u2",
    type: "image",
    content: "图片",
    media_id: media?.media_id ?? "med-1",
    media: media ?? null,
    reply_to: null,
    status: "sent",
    seq: 1,
    created_at: new Date().toISOString(),
  };
}

beforeEach(() => {
  vi.clearAllMocks();
  resetAudioPlayback();
  blobByPath.clear();
  signedById.clear();
  Object.defineProperty(URL, "createObjectURL", {
    value: vi.fn(() => `blob:mock-${Math.random()}`),
    configurable: true,
  });
  Object.defineProperty(URL, "revokeObjectURL", { value: vi.fn(), configurable: true });
});

describe("ImageMedia 原图渲染", () => {
  it("气泡用缩略图变体签名（QQ 同款），查看器才加载原图", async () => {
    signedById.set("med-1|thumb", "/signed/med-1/thumb");
    render(<MediaContent msg={imageMessage(mediaDescriptor())} />);
    await waitFor(() => {
      const img = document.querySelector("img.media-image") as HTMLImageElement | null;
      expect(img).not.toBeNull();
    });
    // getSignedMediaUrl 以 thumb 变体签发；<img src> 用缩略图签名 URL
    const { getSignedMediaUrl } = await import("../api/media");
    expect(getSignedMediaUrl).toHaveBeenCalledWith("med-1", "thumb");
    expect((document.querySelector("img.media-image") as HTMLImageElement).getAttribute("src")).toBe(
      "/signed/med-1/thumb",
    );
  });

  it("点击图片打开查看器（dialog + 保存按钮），ESC 关闭", async () => {
    signedById.set("med-1", "/signed/med-1");
    render(<MediaContent msg={imageMessage(mediaDescriptor())} />);
    const openBtn = await screen.findByRole("button", { name: "查看图片原图" });
    fireEvent.click(openBtn);
    expect(screen.getByRole("dialog", { name: /^图片查看/ })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /保存/ })).toBeInTheDocument();
    fireEvent.keyDown(window, { key: "Escape" });
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
  });

  it("保存图片走签名 URL 原生下载通道（a[download] 同源生效）", async () => {
    // 独立 media_id：避开签名缓存对调用计数的污染
    const desc = mediaDescriptor({ media_id: "med-save" });
    const msg = imageMessage(desc);
    msg.media_id = "med-save";
    signedById.set("med-save", "/signed/med-save");
    render(<MediaContent msg={msg} />);
    fireEvent.click(await screen.findByRole("button", { name: "查看图片原图" }));
    fireEvent.click(screen.getByRole("button", { name: /保存/ }));
    const { getSignedMediaUrl } = await import("../api/media");
    await waitFor(() => {
      expect(getSignedMediaUrl).toHaveBeenCalledWith("med-save");
    });
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });
});

describe("VoiceMedia 全局互斥与进度条", () => {
  /** 可控 FakeAudio：记录实例以便断言 pause/currentTime */
  function installFakeAudio() {
    const instances: {
      paused: boolean;
      currentTime: number;
      play: ReturnType<typeof vi.fn>;
      pause: ReturnType<typeof vi.fn>;
      listeners: Map<string, (() => void)[]>;
    }[] = [];
    class FakeAudio {
      listeners = new Map<string, (() => void)[]>();
      currentTime = 0;
      duration = 12;
      paused = true;
      play = vi.fn(async () => {
        this.paused = false;
        this.listeners.get("loadedmetadata")?.forEach((fn) => fn());
        this.listeners.get("timeupdate")?.forEach((fn) => fn());
      });
      pause = vi.fn(() => {
        this.paused = true;
      });
      constructor(_src?: string) {
        instances.push(this);
      }
      addEventListener(type: string, fn: () => void) {
        const list = this.listeners.get(type) ?? [];
        list.push(fn);
        this.listeners.set(type, list);
      }
      removeEventListener() {}
    }
    vi.stubGlobal("Audio", FakeAudio);
    return { instances };
  }

  function voiceMessage(id: string): ChatMessage {
    return {
      id,
      conversation_id: "c1",
      sender_id: "u2",
      type: "voice",
      content: "",
      media_id: id,
      media: mediaDescriptor({
        media_id: id,
        kind: "voice",
        mime_type: "audio/webm",
        duration: 12,
      }),
      reply_to: null,
      status: "sent",
      seq: 1,
      created_at: new Date().toISOString(),
    };
  }

  it("同时只能播放一条：第二条开始播放时第一条被暂停归零", async () => {
    const { instances } = installFakeAudio();
    blobByPath.set("/media/v1/content", new Blob(["a"]));
    blobByPath.set("/media/v2/content", new Blob(["b"]));

    render(
      <div>
        <MediaContent msg={voiceMessage("v1")} />
        <MediaContent msg={voiceMessage("v2")} />
      </div>,
    );

    const playButtons = screen.getAllByRole("button", { name: "播放语音" });
    fireEvent.click(playButtons[0]);
    await waitFor(() => expect(instances[0]?.paused).toBe(false));

    // 进度条出现且未禁用（metadata 已触发）
    const seek0 = screen.getAllByLabelText("语音播放进度")[0] as HTMLInputElement;
    expect(seek0.disabled).toBe(false);

    // 第二条开播 → 第一条被抢占暂停
    fireEvent.click(playButtons[1]);
    await waitFor(() => expect(instances[1]?.paused).toBe(false));
    expect(instances[0]?.pause).toHaveBeenCalled();
    expect(instances[0]?.currentTime).toBe(0);
  });

  it("拖动进度条 seek 到指定位置", async () => {
    installFakeAudio();
    blobByPath.set("/media/v1/content", new Blob(["a"]));
    render(<MediaContent msg={voiceMessage("v1")} />);
    fireEvent.click(await screen.findByRole("button", { name: "播放语音" }));
    const seek = await waitFor(() => {
      const el = screen.getByLabelText("语音播放进度") as HTMLInputElement;
      expect(el.disabled).toBe(false);
      return el;
    });
    fireEvent.change(seek, { target: { value: "7.5" } });
    await waitFor(() => expect(seek.value).toBe("7.5"));
  });
});

describe("VideoMedia 首帧气泡与查看器", () => {
  function videoMessage(id = "vd-1"): ChatMessage {
    return {
      id,
      conversation_id: "c1",
      sender_id: "u2",
      type: "video",
      content: "",
      media_id: id,
      media: mediaDescriptor({
        media_id: id,
        kind: "video",
        mime_type: "video/mp4",
        width: 1280,
        height: 720,
      }),
      reply_to: null,
      status: "sent",
      seq: 1,
      created_at: new Date().toISOString(),
    };
  }

  it("气泡渲染首帧 video（签名 URL 直连、禁交互）+ 播放键，点击打开查看器", async () => {
    signedById.set("vd-1", "/signed/vd-1");
    render(<MediaContent msg={videoMessage()} />);
    // 气泡内 video 元素存在且不带 controls（仅首帧展示），src 为签名 URL
    await waitFor(() => expect(document.querySelector("video.media-video")).not.toBeNull());
    const bubbleVideo = document.querySelector("video.media-video") as HTMLVideoElement;
    expect(bubbleVideo.hasAttribute("controls")).toBe(false);
    expect(bubbleVideo.getAttribute("src")).toBe("/signed/vd-1");
    expect(screen.getByRole("button", { name: "查看视频" })).toBeInTheDocument();
    // 点击进入查看器：dialog 内是带 controls 的完整播放器
    fireEvent.click(screen.getByRole("button", { name: "查看视频" }));
    const viewerVideo = await screen.findByRole("dialog", { name: /^图片查看/ })
      .then(() => document.querySelector("dialog video, [role=dialog] video"));
    expect(viewerVideo).not.toBeNull();
    expect((viewerVideo as HTMLVideoElement).hasAttribute("controls")).toBe(true);
  });

  it("查看器保存视频走签名 URL 原生下载通道", async () => {
    signedById.set("vd-2", "/signed/vd-2");
    render(<MediaContent msg={videoMessage("vd-2")} />);
    fireEvent.click(await screen.findByRole("button", { name: "查看视频" }));
    fireEvent.click(await screen.findByRole("button", { name: /保存/ }));
    const { getSignedMediaUrl } = await import("../api/media");
    await waitFor(() => {
      expect(getSignedMediaUrl).toHaveBeenCalledWith("vd-2");
    });
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });
});

describe("MessageBubble 媒体气泡不显示占位文案", () => {
  it("图片消息即使 content=「图片」也不在气泡里渲染文字", async () => {
    signedById.set("med-1", "/signed/med-1");
    render(
      <MessageBubble
        message={imageMessage(mediaDescriptor())}
        isSelf={false}
        senderName="小樱"
        senderAvatarLabel="小"
      />,
    );
    await waitFor(() => expect(document.querySelector("img.media-image")).not.toBeNull());
    // 气泡内没有「图片」二字（列表预览的 [图片] 兜底不受影响）
    expect(screen.queryByText("图片")).not.toBeInTheDocument();
  });

  it("语音消息气泡不渲染「语音」文字，但保留进度控件", async () => {
    blobByPath.set("/media/med-1/content", new Blob(["a"]));
    const msg: ChatMessage = {
      ...imageMessage(mediaDescriptor({ kind: "voice", mime_type: "audio/webm", duration: 8 })),
      type: "voice",
    };
    render(<MessageBubble message={msg} isSelf={false} />);
    await screen.findByRole("button", { name: "播放语音" });
    expect(screen.queryByText("语音")).not.toBeInTheDocument();
    expect(screen.getByLabelText("语音播放进度")).toBeInTheDocument();
  });

  it("自己的乐观消息：发送中左上角 spinner；失败后显示重试/删除", async () => {
    const base: ChatMessage = {
      id: "t1", conversation_id: "c1", sender_id: "u1", type: "text", content: "你好",
      media_id: null, reply_to: null, status: "sent", seq: 1, created_at: new Date().toISOString(),
    };
    const onRetry = vi.fn();
    const onRemove = vi.fn();
    const { rerender } = render(
      <MessageBubble message={{ ...base, pending: true }} isSelf onRetry={onRetry} onRemove={onRemove} />,
    );
    expect(screen.getByRole("status", { name: "发送中" })).toBeInTheDocument();
    rerender(
      <MessageBubble message={{ ...base, pending: false, sendFailed: true }} isSelf onRetry={onRetry} onRemove={onRemove} />,
    );
    fireEvent.click(screen.getByRole("button", { name: "重试发送" }));
    expect(onRetry).toHaveBeenCalledTimes(1);
    fireEvent.click(screen.getByRole("button", { name: "删除消息" }));
    expect(onRemove).toHaveBeenCalledTimes(1);
  });
});

describe("MixedMedia 图文混排（type=mixed + segments）", () => {
  function mixedMessage(over: Partial<ChatMessage> = {}): ChatMessage {
    return {
      id: "mix-1",
      conversation_id: "c1",
      sender_id: "u1",
      type: "mixed",
      content: "看看这个和视频不错吧",
      media_id: null,
      segments: [
        { type: "text", text: "看看这个" },
        { type: "image", media_id: "med-1", media: mediaDescriptor() },
        { type: "text", text: "和视频" },
        {
          type: "video",
          media_id: "med-v",
          media: mediaDescriptor({ media_id: "med-v", kind: "video", mime_type: "video/mp4" }),
        },
        { type: "text", text: "不错吧" },
      ],
      reply_to: null,
      status: "sent",
      seq: 1,
      created_at: new Date().toISOString(),
      ...over,
    };
  }

  it("文本段与媒体段流式渲染，无占位文案", async () => {
    signedById.set("med-1", "/signed/med-1");
    signedById.set("med-v", "/signed/med-v");
    render(<MediaContent msg={mixedMessage()} />);
    expect(screen.getByText("看看这个")).toBeInTheDocument();
    expect(screen.getByText("和视频")).toBeInTheDocument();
    expect(screen.getByText("不错吧")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "查看图片" })).toBeInTheDocument();
    expect(await screen.findByRole("button", { name: "查看视频" })).toBeInTheDocument();
  });

  it("点击图片打开共享查看器，多图左右切换（计数 1/2 → 2/2）", async () => {
    signedById.set("med-1", "/signed/med-1");
    signedById.set("med-v", "/signed/med-v");
    render(<MediaContent msg={mixedMessage()} />);
    fireEvent.click(await screen.findByRole("button", { name: "查看图片" }));
    expect(screen.getByRole("dialog", { name: "图片查看：1/2" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "下一张" }));
    expect(screen.getByRole("dialog", { name: "图片查看：2/2" })).toBeInTheDocument();
    // 第二项是视频：查看器渲染 <video>
    await waitFor(() => expect(document.querySelector("video.image-viewer-video")).not.toBeNull());
    fireEvent.keyDown(window, { key: "Escape" });
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
  });

  it("乐观消息（pending + localMedia）用本地预览渲染，媒体段无 descriptor 不报错", async () => {
    const msg = mixedMessage({
      pending: true,
      localMedia: [
        { id: "p0", kind: "image", mimeType: "image/png", url: "blob:local-0", file: new File(["a"], "a.png", { type: "image/png" }) },
      ],
    });
    // 覆盖 segments 媒体段：media 为 null（未上传）
    msg.segments = [
      { type: "text", text: "看看" },
      { type: "image", media_id: "", media: null },
    ];
    render(<MediaContent msg={msg} />);
    const img = await screen.findByRole("img", { name: "图片" });
    expect(img).toHaveAttribute("src", "blob:local-0");
    expect(screen.getByText("看看")).toBeInTheDocument();
  });
});
