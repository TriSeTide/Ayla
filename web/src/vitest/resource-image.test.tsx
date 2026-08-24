import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ResourceImage } from "../components/ResourceImage";
import { getSignedMediaUrl } from "../api/media";

vi.mock("../api/media", async () => {
  const actual = await vi.importActual<typeof import("../api/media")>("../api/media");
  return { ...actual, getSignedMediaUrl: vi.fn(), invalidateSignedMediaUrl: vi.fn() };
});

const mockedSign = vi.mocked(getSignedMediaUrl);

describe("ResourceImage", () => {
  beforeEach(() => {
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
    expect(mockedSign).toHaveBeenCalledWith("m-1");
  });

  it("外部资源保持浏览器原生加载路径，不请求签名", () => {
    render(<ResourceImage src="https://example.com/avatar.png" alt="用户头像" />);
    expect(screen.getByRole("img")).toHaveAttribute("src", "https://example.com/avatar.png");
    expect(mockedSign).not.toHaveBeenCalled();
  });
});
