/**
 * MediaContent 契约测试（图片原图渲染 / 查看器 / 语音互斥 / 气泡无占位文案）：
 * - 图片/表情经短时签名 URL 直连原图 content（缩略图是 JPEG 静帧：压画质 + GIF 变静图）；
 * - 点击图片打开全屏查看器（dialog），可关闭、可保存（签名 URL 原生下载）；
 * - 语音气泡带进度条，全局同时只播放一条（新播放抢占旧播放）；
 * - MessageBubble 不再显示媒体消息的「图片/语音」占位文案。
 */
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ChatMessage, MediaDescriptor, UserPublic } from "../api/types";
import { MediaContent } from "../components/chat/MediaContent";
import { MessageBubble } from "../components/chat/MessageBubble";
import { resetAudioPlayback } from "../utils/mediaPlayback";
import { useAuthStore } from "../stores/auth";

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
        thumbnail: `/api/v1/media/${id}/thumbnail`,
      }),
      reply_to: null,
      status: "sent",
      seq: 1,
      created_at: new Date().toISOString(),
    };
  }

  it("有海报帧时气泡渲染封面 img（签名缩略图直连），不挂 video 拉流；点击打开查看器", async () => {
    signedById.set("vd-1|thumb", "/signed/vd-1/thumb");
    render(<MediaContent msg={videoMessage()} />);
    // 封面 img 直连签名缩略图（零视频元数据拉流，秒出）
    await waitFor(() => expect(document.querySelector("img.media-video")).not.toBeNull());
    expect((document.querySelector("img.media-video") as HTMLImageElement).getAttribute("src")).toBe(
      "/signed/vd-1/thumb",
    );
    expect(document.querySelector("video.media-video")).toBeNull();
    expect(screen.getByRole("button", { name: "查看视频" })).toBeInTheDocument();
    // 点击进入查看器：dialog 内是带 controls 的完整播放器
    fireEvent.click(screen.getByRole("button", { name: "查看视频" }));
    const viewerVideo = await screen.findByRole("dialog", { name: /^图片查看/ })
      .then(() => document.querySelector("dialog video, [role=dialog] video"));
    expect(viewerVideo).not.toBeNull();
    expect((viewerVideo as HTMLVideoElement).hasAttribute("controls")).toBe(true);
  });

  it("无海报帧降级首帧 video（签名 original 直连、禁交互）+ 播放键", async () => {
    const msg = videoMessage("vd-0");
    msg.media = mediaDescriptor({
      media_id: "vd-0",
      kind: "video",
      mime_type: "video/mp4",
      width: 1280,
      height: 720,
      thumbnail: null,
    });
    signedById.set("vd-0", "/signed/vd-0");
    render(<MediaContent msg={msg} />);
    await waitFor(() => expect(document.querySelector("video.media-video")).not.toBeNull());
    const bubbleVideo = document.querySelector("video.media-video") as HTMLVideoElement;
    expect(bubbleVideo.hasAttribute("controls")).toBe(false);
    expect(bubbleVideo.getAttribute("src")).toBe("/signed/vd-0");
  });

  it("hover 预热的 detached video 被查看器直接接管（缓冲延续，不重建 src）", async () => {
    signedById.set("vd-warm", "/signed/vd-warm");
    const mediaApi = await import("../api/media");
    mediaApi.warmUpVideoElement("vd-warm");
    render(<MediaContent msg={videoMessage("vd-warm")} />);
    fireEvent.click(await screen.findByRole("button", { name: "查看视频" }));
    await waitFor(() =>
      expect(document.querySelector("video.image-viewer-video")).not.toBeNull(),
    );
    const viewerVideo = document.querySelector("video.image-viewer-video") as HTMLVideoElement;
    // 接管预热元素：src 沿用预热时签发的 URL（缓冲不中断）
    expect(viewerVideo.getAttribute("src")).toBe("/signed/vd-warm");
    expect(viewerVideo.getAttribute("preload")).toBe("auto");
    // 元素已移出预热池（移交查看器，不重复驻留）
    expect(mediaApi.takeWarmVideoElement("vd-warm")).toBeNull();
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

  it("乐观文件消息（descriptor 未就绪）显示本地文件名+大小，不显示加载占位", () => {
    const msg: ChatMessage = {
      id: "tf1", conversation_id: "c1", sender_id: "u1", type: "file",
      content: "报告.pdf", media_id: null, media: null, segments: null,
      reply_to: null, status: "sent", seq: 0, created_at: new Date().toISOString(),
      pending: true,
      localMedia: [
        { id: "lf0", kind: "file", mimeType: "application/pdf", url: "", file: new File(["pdf-body"], "报告.pdf", { type: "application/pdf" }) },
      ],
    };
    render(<MessageBubble message={msg} isSelf />);
    // 本地文件名渲染（不是「文件加载中…」占位）
    expect(screen.getByText("报告.pdf")).toBeInTheDocument();
    expect(screen.queryByText("文件加载中…")).not.toBeInTheDocument();
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

  it("mention 段渲染 @Token 高亮胶囊，「@我」加 is-me 强调、点击跳个人页", async () => {
    useAuthStore.setState({
      currentUser: { id: "u2", username: "zs", nickname: "张三" } as UserPublic,
    });
    try {
      const msg = mixedMessage({
        segments: [
          { type: "text", text: "hi " },
          { type: "mention", user_id: "u2", user: { id: "u2", nickname: "张三", username: "zs" } as UserPublic },
          { type: "text", text: " 看这个 " },
          { type: "mention", user_id: "u3", user: { id: "u3", nickname: "李四", username: "ls" } as UserPublic },
        ],
      });
      render(<MediaContent msg={msg} />);
      // @我（u2）加 is-me 强调
      const meToken = screen.getByRole("button", { name: "@张三" });
      expect(meToken).toHaveClass("mention-token", "is-me");
      expect(meToken.textContent).toBe("@张三");
      // @他人（u3）无 is-me
      const otherToken = screen.getByRole("button", { name: "@李四" });
      expect(otherToken).toHaveClass("mention-token");
      expect(otherToken).not.toHaveClass("is-me");
      // 点击跳个人主页：navigateTo 未注册时 no-op，不抛错
      expect(() => fireEvent.click(otherToken)).not.toThrow();
    } finally {
      useAuthStore.setState({ currentUser: null });
    }
  });

  it("查看器视频秒开：海报帧先行显示，<video> 挂同帧 poster + preload=auto", async () => {
    // original 签名延迟、thumb（海报）即时返回：模拟真实网络时序——
    // 等待期画面必须是海报 <img> 而非骨架屏；video 出现后 poster 同帧衔接
    const { getSignedMediaUrl } = await import("../api/media");
    const impl = vi.mocked(getSignedMediaUrl).getMockImplementation();
    vi.mocked(getSignedMediaUrl).mockImplementation(async (mediaId, variant) => {
      if (variant === "thumb") return `/signed/${mediaId}-poster`;
      await new Promise((r) => setTimeout(r, 20));
      return `/signed/${mediaId}-original`;
    });
    try {
      render(<MediaContent msg={mixedMessage()} />);
      fireEvent.click(await screen.findByRole("button", { name: "查看视频" }));
      await waitFor(() =>
        expect(document.querySelector("img.image-viewer-video-poster")).not.toBeNull(),
      );
      expect(document.querySelector("img.image-viewer-video-poster")).toHaveAttribute(
        "src",
        "/signed/med-v-poster",
      );
      // original 就绪后：<video> 接管，poster 与等待期同一张海报（无跳变）
      await waitFor(() =>
        expect(document.querySelector("video.image-viewer-video")).not.toBeNull(),
      );
      const video = document.querySelector("video.image-viewer-video") as HTMLVideoElement;
      expect(video.getAttribute("poster")).toBe("/signed/med-v-poster");
      expect(video.getAttribute("preload")).toBe("auto");
    } finally {
      vi.mocked(getSignedMediaUrl).mockImplementation(impl!);
    }
  });
});
