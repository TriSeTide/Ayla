import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { ResourceImage } from "../components/ResourceImage";

describe("ResourceImage", () => {
  it("图片失败显示可重试占位", () => {
    const { container } = render(<ResourceImage src="/missing.png" alt="测试图片" />);
    fireEvent.error(container.querySelector("img")!);
    expect(screen.getByRole("button", { name: /图片加载失败/ })).toBeTruthy();
  });
});
