import { beforeEach, describe, expect, it, vi } from "vitest";
import { IMAGE_TYPES, uploadMediaFile, validateImageFile } from "../api/media";
import * as client from "../api/client";

describe("uploadMediaFile", () => {
  beforeEach(() => vi.restoreAllMocks());

  it("按创建会话、上传二进制、完成顺序提交", async () => {
    const request = vi.spyOn(client, "apiRequest")
      .mockResolvedValueOnce({ upload_id: "u1", kind: "image", max_bytes: null, expires_at: "later" })
      .mockResolvedValueOnce({ detail: "ok" })
      .mockResolvedValueOnce({ media_id: "m1", descriptor: { media_id: "m1" } });
    const file = new File(["hello"], "a.png", { type: "image/png" });
    const result = await uploadMediaFile(file, "image");
    expect(result.media_id).toBe("m1");
    expect(request.mock.calls.map(([path]) => path)).toEqual([
      "/media/uploads",
      "/media/uploads/u1",
      "/media/uploads/u1:complete",
    ]);
    expect(request.mock.calls[1][1]).toMatchObject({ method: "PUT", body: file });
  });

  it("max_bytes=null（不设上限）时直接继续上传二进制", async () => {
    const request = vi.spyOn(client, "apiRequest")
      .mockResolvedValueOnce({ upload_id: "u2", kind: "voice", max_bytes: null, expires_at: "later" })
      .mockResolvedValueOnce({ detail: "ok" })
      .mockResolvedValueOnce({ media_id: "m2", descriptor: { media_id: "m2" } });
    // 远超旧 30MB 上限的声明体积也照常走三步
    const file = new File([new Uint8Array(1024)], "long.webm", { type: "audio/webm" });
    Object.defineProperty(file, "size", { value: 512 * 1024 * 1024 });
    const result = await uploadMediaFile(file, "voice");
    expect(result.media_id).toBe("m2");
    expect(request).toHaveBeenCalledTimes(3);
  });

  it("超过服务端声明大小时不上传二进制，并展示具体上限", async () => {
    const request = vi.spyOn(client, "apiRequest")
      .mockResolvedValueOnce({ upload_id: "u1", kind: "file", max_bytes: 1024, expires_at: "later" });
    const file = new File([new Uint8Array(2048)], "a.bin", { type: "application/octet-stream" });
    await expect(uploadMediaFile(file, "file")).rejects.toThrow("文件超过大小上限（1.0 KB）");
    expect(request).toHaveBeenCalledTimes(1);
  });

  it("会话创建 413 时转为可读文案", async () => {
    vi.spyOn(client, "apiRequest").mockRejectedValueOnce(
      new client.ApiError(413, "payload_too_large"),
    );
    const file = new File(["x"], "a.png", { type: "image/png" });
    await expect(uploadMediaFile(file, "image")).rejects.toThrow("文件超过允许的大小上限");
  });
});

describe("validateImageFile", () => {
  it("常见与现代格式均通过，不限制大小", () => {
    for (const type of ["image/png", "image/jpeg", "image/webp", "image/avif", "image/heic", "image/bmp", "image/tiff", "image/svg+xml"]) {
      expect(validateImageFile(new File(["x"], `a.${type.split("/")[1]}`, { type }))).toBeNull();
    }
    // 超大图片不再被本地校验拒绝（大小不设上限）
    const big = new File([new Uint8Array(64)], "big.png", { type: "image/png" });
    Object.defineProperty(big, "size", { value: 100 * 1024 * 1024 });
    expect(validateImageFile(big)).toBeNull();
  });

  it("非图片类型拒绝", () => {
    expect(validateImageFile(new File(["x"], "a.txt", { type: "text/plain" }))).toBe(
      "仅支持图片文件（PNG/JPEG/GIF/WebP/AVIF/HEIC/BMP/TIFF/ICO/SVG）",
    );
  });

  it("空内容拒绝", () => {
    const empty = new File([], "empty.png", { type: "image/png" });
    expect(validateImageFile(empty)).toBe("图片内容为空");
  });

  it("IMAGE_TYPES 白名单与后端 allowlist 对齐（关键格式抽查）", () => {
    for (const t of ["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif", "image/heic", "image/heif", "image/bmp", "image/tiff", "image/x-icon", "image/svg+xml"]) {
      expect(IMAGE_TYPES.has(t)).toBe(true);
    }
    expect(IMAGE_TYPES.has("application/x-msdownload")).toBe(false);
  });
});
