import { beforeEach, describe, expect, it, vi } from "vitest";
import { uploadMediaFile } from "../api/media";
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
