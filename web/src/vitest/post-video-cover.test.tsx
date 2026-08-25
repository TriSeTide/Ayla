/**
 * PostVideoCover 测试 —— 帖子视频封面秒开策略。
 *
 * 契约：
 * - 有海报帧（thumbnail 非空）：渲染签名缩略图 <img>（variant=thumb 直连），
 *   不挂 <video> 元素——信息流视频卡零视频元数据拉流，封面秒出；
 * - 无海报帧（存量 / 浏览器抽帧失败）：降级 SignedVideo，按 original 签发
 *   <video> 首帧预览（历史行为）。
 */
import { render, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { PostVideoCover } from "../components/posts/PostVideoCover";
import { getSignedMediaUrl } from "../api/media";
import type { MediaDescriptor } from "../api/types";

vi.mock("../api/media", async () => {
  const actual = await vi.importActual<typeof import("../api/media")>("../api/media");
  return { ...actual, getSignedMediaUrl: vi.fn(), invalidateSignedMediaUrl: vi.fn() };
});

const mockedSign = vi.mocked(getSignedMediaUrl);

function videoMedia(overrides: Partial<MediaDescriptor> = {}): MediaDescriptor {
  return {
    media_id: "med-v",
    kind: "video",
    mime_type: "video/mp4",
    size: 1024,
    status: "ready",
    width: 1920,
    height: 1080,
    duration: null,
    thumbnail: null,
    waveform: null,
    created_at: "2026-01-01T00:00:00Z",
    ...overrides,
  };
}

describe("PostVideoCover", () => {
  beforeEach(() => {
    mockedSign.mockReset();
  });

  it("有海报帧：渲染签名缩略图封面（variant=thumb），不挂 <video> 元素", async () => {
    mockedSign.mockResolvedValue("/signed/med-v-thumb");
    const { container } = render(
      <PostVideoCover
        media={videoMedia({ thumbnail: "/api/v1/media/med-v/thumbnail" })}
        className="post-card-video-el"
      />,
    );
    await waitFor(() =>
      expect(container.querySelector("img.post-card-video-el")).not.toBeNull(),
    );
    expect(container.querySelector("img.post-card-video-el")).toHaveAttribute(
      "src",
      "/signed/med-v-thumb",
    );
    expect(container.querySelector("video")).toBeNull();
    expect(mockedSign).toHaveBeenCalledWith("med-v", "thumb");
  });

  it("无海报帧：降级 SignedVideo，按 original 签发 <video> 首帧预览", async () => {
    mockedSign.mockResolvedValue("/signed/med-v");
    const { container } = render(
      <PostVideoCover media={videoMedia()} className="post-card-video-el" />,
    );
    await waitFor(() =>
      expect(container.querySelector("video.post-card-video-el")).not.toBeNull(),
    );
    expect(container.querySelector("video")).toHaveAttribute(
      "src",
      "/signed/med-v#t=0.1",
    );
    expect(mockedSign).toHaveBeenCalledWith("med-v");
  });
});
