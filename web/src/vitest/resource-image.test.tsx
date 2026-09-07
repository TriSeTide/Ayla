import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ResourceImage } from "../components/ResourceImage";
import { getSignedMediaUrl, invalidateSignedMediaUrl } from "../api/media";

vi.mock("../api/media", async () => {
  const actual = await vi.importActual<typeof import("../api/media")>("../api/media");
  return { ...actual, getSignedMediaUrl: vi.fn(), invalidateSignedMediaUrl: vi.fn() };
});

const mockedSign = vi.mocked(getSignedMediaUrl);

describe("ResourceImage", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockedSign.mockReset();
  });

  it("图片失败显示可重试占位", () => {
    const { container } = render(<ResourceImage src="/missing.png" alt="测试图片" />);
    fireEvent.error(container.querySelector("img")!);
    expect(screen.getByRole("button", { name: /图片加载失败/ })).toBeTruthy();
  });

  it("内部媒体通过短时签名 URL 直连（<img> 原生流式加载），而不是 blob 全量下载", async () => {
    mockedSign.mockResolvedValue("/api/v1/media/m-1/content?uid=u&exp=9&sig=s");
    const { container } = render(<ResourceImage src="/api/v1/media/m-1/content" alt="" fallback="头像" />);

    expect(screen.getByText("头像")).toBeInTheDocument();
    await waitFor(() =>
      expect(container.querySelector("img")).toHaveAttribute(
        "src",
        "/api/v1/media/m-1/content?uid=u&exp=9&sig=s",
      ),
    );
    expect(mockedSign).toHaveBeenCalledWith("m-1", undefined);
  });

  it("外部资源保持浏览器原生加载路径，不请求签名", () => {
    render(<ResourceImage src="https://example.com/avatar.png" alt="用户头像" />);
    expect(screen.getByRole("img")).toHaveAttribute("src", "https://example.com/avatar.png");
    expect(mockedSign).not.toHaveBeenCalled();
  });

  it("图片卡片复用外层原生按钮重试，成功后恢复打开动作，不产生嵌套按钮", async () => {
    mockedSign.mockRejectedValueOnce(new Error("签名失败")).mockResolvedValueOnce("/signed-image.png");
    const open = vi.fn();
    const { container } = render(<button type="button" aria-label="查看原图" onClick={open}>
      <ResourceImage src="/api/v1/media/card/content" alt="卡片图片" />
    </button>);
    const retry = await screen.findByRole("button", { name: "卡片图片：图片加载失败，重试" });
    expect(container.querySelector("button button")).toBeNull();
    expect(screen.getAllByRole("button")).toHaveLength(1);
    fireEvent.click(retry);
    expect(open).not.toHaveBeenCalled();
    expect(invalidateSignedMediaUrl).toHaveBeenCalledWith("card");
    await waitFor(() => expect(screen.getByRole("img")).toHaveAttribute("src", "/signed-image.png"));
    fireEvent.click(screen.getByRole("button", { name: "查看原图" }));
    expect(open).toHaveBeenCalledTimes(1);
  });

  it("评论缩略图的自定义加载占位不掩盖签名失败，重试不会打开查看器", async () => {
    mockedSign.mockRejectedValueOnce(new Error("签名失败")).mockResolvedValueOnce("/signed-comment.png");
    const open = vi.fn();
    render(<button type="button" aria-label="查看评论图片" onClick={open}>
      <ResourceImage src="/api/v1/media/comment/thumbnail" alt="评论图片" fallback={<span>占位图</span>} variant="thumb" />
    </button>);
    const retry = await screen.findByRole("button", { name: "评论图片：图片加载失败，重试" });
    expect(screen.getByRole("status")).toHaveTextContent("图片加载失败");
    fireEvent.click(retry);
    await screen.findByRole("img");
    expect(open).not.toHaveBeenCalled();
    expect(mockedSign).toHaveBeenLastCalledWith("comment", "thumb");
  });

  it("独立图片失败时提供独立重试按钮并恢复图片", async () => {
    mockedSign.mockRejectedValueOnce(new Error("签名失败")).mockResolvedValueOnce("/signed-viewer.png");
    render(<ResourceImage src="/api/v1/media/viewer/content" alt="查看器图片" fallback="正在加载" />);
    fireEvent.click(await screen.findByRole("button", { name: "查看器图片：图片加载失败，重试" }));
    expect(await screen.findByRole("img")).toHaveAttribute("src", "/signed-viewer.png");
  });

  it("装饰头像签名失败保留文字占位，不接管搜索结果行的主动作", async () => {
    mockedSign.mockRejectedValue(new Error("头像签名失败"));
    const join = vi.fn();
    const { container } = render(<button type="button" aria-label="加入搜索群组" onClick={join}>
      <ResourceImage src="/api/v1/media/avatar/content" alt="" fallback="群" />
      <span>搜索群组名称</span>
    </button>);
    await waitFor(() => expect(container.querySelector(".resource-image-loading")).toBeNull());
    expect(screen.getByText("群")).toBeInTheDocument();
    expect(container.querySelector("button button")).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "加入搜索群组" }));
    expect(join).toHaveBeenCalledOnce();
    expect(invalidateSignedMediaUrl).not.toHaveBeenCalled();
  });

  it("媒体变体切换会重新签发对应变体而不复用旧缩略图", async () => {
    mockedSign.mockResolvedValue("/signed.png");
    const view = render(<ResourceImage src="/api/v1/media/same/content" alt="图片" variant="thumb" />);
    await screen.findByRole("img");
    view.rerender(<ResourceImage src="/api/v1/media/same/content" alt="图片" />);
    await waitFor(() => expect(mockedSign).toHaveBeenLastCalledWith("same", undefined));
  });
});
