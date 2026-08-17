import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ResourceImage } from "../components/ResourceImage";
import { apiRequestBlob } from "../api/client";

vi.mock("../api/client", async () => {
  const actual = await vi.importActual<typeof import("../api/client")>("../api/client");
  return { ...actual, apiRequestBlob: vi.fn() };
});

const mockedBlob = vi.mocked(apiRequestBlob);

describe("ResourceImage", () => {
  beforeEach(() => {
    mockedBlob.mockReset();
    vi.stubGlobal("URL", {
      ...URL,
      createObjectURL: vi.fn(() => "blob:avatar"),
      revokeObjectURL: vi.fn(),
    });
  });

  it("图片失败显示可重试占位", () => {
    const { container } = render(<ResourceImage src="/missing.png" alt="测试图片" />);
    fireEvent.error(container.querySelector("img")!);
    expect(screen.getByRole("button", { name: /图片加载失败/ })).toBeTruthy();
  });

  it("通过带鉴权的二进制请求加载内部媒体，而不是直接把 URL 交给 img", async () => {
    mockedBlob.mockResolvedValue(new Blob(["png"], { type: "image/png" }));
    const { container } = render(<ResourceImage src="/api/v1/media/m-1/content" alt="" fallback="头像" />);

    expect(screen.getByText("头像")).toBeInTheDocument();
    await waitFor(() => expect(container.querySelector("img")).toHaveAttribute("src", "blob:avatar"));
    expect(mockedBlob).toHaveBeenCalledWith("/media/m-1/content");
  });

  it("外部资源保持浏览器原生加载路径", () => {
    render(<ResourceImage src="https://example.com/avatar.png" alt="用户头像" />);
    expect(screen.getByRole("img")).toHaveAttribute("src", "https://example.com/avatar.png");
    expect(mockedBlob).not.toHaveBeenCalled();
  });
});