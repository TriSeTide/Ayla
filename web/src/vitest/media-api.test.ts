import { beforeEach, describe, expect, it, vi } from "vitest";
import { IMAGE_TYPES, uploadMediaFile, validateImageFile } from "../api/media";
import * as client from "../api/client";

/** XHR 替身：记录请求并允许测试手动触发进度/成功/中止 */
class FakeXHR {
  static instances: FakeXHR[] = [];
  status = 200;
  onload: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onabort: (() => void) | null = null;
  upload: {
    onprogress: ((e: { lengthComputable: boolean; loaded: number; total: number }) => void) | null;
  } = { onprogress: null };
  method = "";
  url = "";
  headers: Record<string, string> = {};
  body: unknown = null;

  open(method: string, url: string) {
    this.method = method;
    this.url = url;
  }
  setRequestHeader(k: string, v: string) {
    this.headers[k] = v;
  }
  send(body: unknown) {
    this.body = body;
    FakeXHR.instances.push(this);
  }
  abort() {
    this.onabort?.();
  }
  succeed(status = 200) {
    this.status = status;
    this.onload?.();
  }
}

async function waitXhr(): Promise<FakeXHR> {
  // POST 会话（apiRequest mock）→ PUT XHR 需要几个微任务推进
  await vi.waitFor(() => {
    if (FakeXHR.instances.length === 0) throw new Error("XHR not sent yet");
  });
  return FakeXHR.instances[0];
}

describe("uploadMediaFile", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    FakeXHR.instances = [];
    vi.stubGlobal("XMLHttpRequest", FakeXHR as unknown as typeof XMLHttpRequest);
  });

  it("按创建会话、上传二进制（XHR）、完成顺序提交", async () => {
    const request = vi.spyOn(client, "apiRequest")
      .mockResolvedValueOnce({ upload_id: "u1", kind: "image", max_bytes: null, expires_at: "later", presigned_url: "http://minio.local/elysia-media/tmp/u1?sig=1" })
      .mockResolvedValueOnce({ media_id: "m1", descriptor: { media_id: "m1" } });
    const file = new File(["hello"], "a.png", { type: "image/png" });
    const pending = uploadMediaFile(file, "image");
    const xhr = await waitXhr();
    expect(xhr.method).toBe("PUT");
    expect(xhr.url).toBe("/minio/elysia-media/tmp/u1?sig=1"); // 预签名 URL 改写为同源代理路径
    expect(xhr.headers["Content-Type"]).toBe("image/png");
    // 预签名 URL 自带鉴权，绝不可再附加 Authorization（破坏签名）
    expect(xhr.headers["Authorization"]).toBeUndefined();
    expect(xhr.body).toBe(file);
    xhr.succeed();
    const result = await pending;
    expect(result.media_id).toBe("m1");
    expect(request.mock.calls.map(([path]) => path)).toEqual([
      "/media/uploads",
      "/media/uploads/u1:complete",
    ]);
  });

  it("上传进度经 onprogress 回调上报", async () => {
    vi.spyOn(client, "apiRequest")
      .mockResolvedValueOnce({ upload_id: "up", kind: "image", max_bytes: null, expires_at: "later", presigned_url: "http://minio.local/elysia-media/tmp/up?sig=2" })
      .mockResolvedValueOnce({ media_id: "m3", descriptor: { media_id: "m3" } });
    const file = new File(["hello"], "a.png", { type: "image/png" });
    const events: Array<{ loaded: number; total: number }> = [];
    const pending = uploadMediaFile(file, "image", {
      onProgress: (p) => events.push(p),
    });
    const xhr = await waitXhr();
    xhr.upload.onprogress?.({ lengthComputable: true, loaded: 2, total: 5 });
    xhr.upload.onprogress?.({ lengthComputable: true, loaded: 5, total: 5 });
    xhr.succeed();
    await pending;
    expect(events).toEqual([
      { loaded: 2, total: 5 },
      { loaded: 5, total: 5 },
    ]);
  });

  it("signal 中止时 abort XHR 并 DELETE 清理临时存储", async () => {
    const request = vi.spyOn(client, "apiRequest")
      .mockResolvedValueOnce({ upload_id: "uc", kind: "image", max_bytes: null, expires_at: "later", presigned_url: "http://minio.local/elysia-media/tmp/uc?sig=3" })
      .mockResolvedValueOnce(undefined); // DELETE 清理
    const controller = new AbortController();
    const file = new File(["hello"], "a.png", { type: "image/png" });
    const pending = uploadMediaFile(file, "image", { signal: controller.signal });
    const xhr = await waitXhr();
    controller.abort();
    await expect(pending).rejects.toMatchObject({ name: "AbortError" });
    // 取消后 fire-and-forget DELETE /media/uploads/{id}
    await vi.waitFor(() => {
      if (!request.mock.calls.some(([path, opts]) => path === "/media/uploads/uc" && (opts as { method?: string })?.method === "DELETE")) {
        throw new Error("DELETE not called yet");
      }
    });
    expect(xhr.body).toBe(file);
  });

  it("max_bytes=null（不设上限）时直接继续上传二进制", async () => {
    vi.spyOn(client, "apiRequest")
      .mockResolvedValueOnce({ upload_id: "u2", kind: "voice", max_bytes: null, expires_at: "later", presigned_url: "http://minio.local/elysia-media/tmp/u2?sig=4" })
      .mockResolvedValueOnce({ media_id: "m2", descriptor: { media_id: "m2" } });
    // 远超旧 30MB 上限的声明体积也照常走三步
    const file = new File([new Uint8Array(1024)], "long.webm", { type: "audio/webm" });
    Object.defineProperty(file, "size", { value: 512 * 1024 * 1024 });
    const pending = uploadMediaFile(file, "voice");
    const xhr = await waitXhr();
    expect(xhr.method).toBe("PUT");
    xhr.succeed();
    const result = await pending;
    expect(result.media_id).toBe("m2");
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
