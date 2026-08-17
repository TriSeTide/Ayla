import { beforeEach, describe, expect, it, vi } from "vitest";
import { AVATAR_MAX_BYTES, uploadMediaFile, validateAvatarFile } from "../api/media";
import * as client from "../api/client";

describe("uploadMediaFile", () => {
  beforeEach(() => vi.restoreAllMocks());

  it("按创建会话、上传二进制、完成顺序提交", async () => {
    const request = vi.spyOn(client, "apiRequest")
      .mockResolvedValueOnce({ upload_id: "u1", kind: "image", max_bytes: 1000, expires_at: "later" })
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

  it("超过服务端声明大小时不上传二进制", async () => {
    const request = vi.spyOn(client, "apiRequest")
      .mockResolvedValueOnce({ upload_id: "u1", kind: "image", max_bytes: 1, expires_at: "later" });
    const file = new File(["hello"], "a.png", { type: "image/png" });
    await expect(uploadMediaFile(file, "image")).rejects.toThrow("文件超过允许大小");
    expect(request).toHaveBeenCalledTimes(1);
  });
});

describe("validateAvatarFile", () => {
  it("合法位图通过", () => {
    expect(validateAvatarFile(new File(["x"], "a.png", { type: "image/png" }))).toBeNull();
    expect(validateAvatarFile(new File(["x"], "a.jpg", { type: "image/jpeg" }))).toBeNull();
    expect(validateAvatarFile(new File(["x"], "a.webp", { type: "image/webp" }))).toBeNull();
  });

  it("非位图类型拒绝", () => {
    expect(validateAvatarFile(new File(["x"], "a.txt", { type: "text/plain" }))).toBe(
      "仅支持 PNG/JPEG/GIF/WebP 图片",
    );
  });

  it("超过 10MB 拒绝", () => {
    const big = new File([new Uint8Array(AVATAR_MAX_BYTES + 1)], "big.png", { type: "image/png" });
    expect(validateAvatarFile(big)).toBe("图片超过 10MB 大小限制");
  });
});
